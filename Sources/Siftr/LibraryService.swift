import AppKit
import CryptoKit
import SifterCore

/// The library: every song in the library folder (~/Music/Siftr,
/// subfolders too), indexed with its tags in the database so the Library
/// page opens instantly, and kept in step with the folder by rescanning it.
@MainActor
final class LibraryService {
    let store: LibraryStore?
    private(set) var rows: [LibraryStore.LibraryRow] = []   // oldest first
    private var byID: [String: LibraryStore.LibraryRow] = [:]
    private(set) var scanning = false
    private var rescan = false
    var onChange: (() -> Void)?

    init(store: LibraryStore?) {
        self.store = store
        load()
    }

    var folder: URL { Paths.libraryDir() }

    private func load() {
        rows = store?.libraryRows() ?? []
        byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func row(_ id: String) -> LibraryStore.LibraryRow? { byID[id] }
    func url(_ id: String) -> URL? { byID[id].map { URL(fileURLWithPath: $0.path) } }

    static func title(_ r: LibraryStore.LibraryRow) -> String {
        r.title ?? URL(fileURLWithPath: r.path).deletingPathExtension().lastPathComponent
    }

    func song(_ id: String) -> Playback.Song? {
        guard let r = byID[id] else { return nil }
        return Playback.Song(kind: .library, id: id, url: URL(fileURLWithPath: r.path), title: Self.title(r),
                             artist: r.artist, album: r.album)
    }

    /// A song's library ID: 16 hex digits made from its file name and size,
    /// so it survives the file moving between subfolders.
    nonisolated static func id(for url: URL) -> String {
        SHA256.hash(data: Data(songKey(for: url).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private struct Found: Sendable {
        let id: String, url: URL, size: Int, mtime: Double, created: Double
    }

    /// Rescans the folder: new or changed songs get their tags read (a few
    /// at a time, off the main thread), vanished ones leave the index.
    func refresh() {
        guard !scanning else { rescan = true; return }
        scanning = true
        onChange?()
        let folder = self.folder
        let known = byID
        let firstIndex = rows.isEmpty
        Task {
            let found: [Found] = await Task.detached(priority: .utility) {
                FolderScanner.scan(folder).map { url in
                    let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
                    return Found(id: Self.id(for: url), url: url, size: v?.fileSize ?? 0,
                                 mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                 created: v?.creationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
                }
            }.value

            var seen = Set<String>()
            var toRead: [Found] = []
            var moved: [LibraryStore.LibraryRow] = []
            for f in found where !seen.contains(f.id) {        // the same song twice: the first one counts
                seen.insert(f.id)
                if var old = known[f.id], old.size == f.size, old.mtime == f.mtime {
                    if old.path != f.url.path {                // moved to another subfolder
                        old.path = f.url.path
                        moved.append(old)
                    }
                } else {
                    toRead.append(f)
                }
            }
            let gone = known.keys.filter { !seen.contains($0) }
            try? self.store?.removeLibrary(ids: gone)
            try? self.store?.saveLibrary(moved)
            if !gone.isEmpty || !moved.isEmpty {
                self.load()
                self.onChange?()
            }

            // read tags, saving and redrawing in batches (a first index can be big)
            let now = Date().timeIntervalSince1970
            var batch: [LibraryStore.LibraryRow] = []
            await withTaskGroup(of: (Found, SongDetails).self) { group in
                var iterator = toRead.makeIterator()
                func addNext() {
                    guard let f = iterator.next() else { return }
                    group.addTask { (f, await MetadataReader.details(for: f.url)) }
                }
                for _ in 0..<4 { addNext() }
                for await (f, d) in group {
                    // a song that's been here before keeps its "added" date; a first
                    // index uses the files' dates, anything later arrived just now
                    let added = known[f.id]?.added ?? (firstIndex ? f.created : now)
                    batch.append(LibraryStore.LibraryRow(id: f.id, path: f.url.path, title: d.tags.title, artist: d.tags.artist,
                                                         album: d.tags.album, duration: d.duration, size: f.size,
                                                         mtime: f.mtime, added: added, art: d.artHash))
                    if batch.count >= 40 {
                        try? self.store?.saveLibrary(batch)
                        batch.removeAll()
                        self.load()
                        self.onChange?()
                    }
                    addNext()
                }
            }
            try? self.store?.saveLibrary(batch)
            self.load()
            self.scanning = false
            self.onChange?()
            Memory.giveBack()                                // reading tags churned through memory
            if self.rescan {
                self.rescan = false
                self.refresh()
            }
        }
    }

    // MARK: - what the Library page shows

    struct SongPayload: Encodable {
        let id: String, title: String, artist: String, album: String
        let duration: Double
        let added: Double
        let plays: Int, skips: Int
        let lastPlayed: Double?
        let lyrics: String?          // whisper / lrc / none, or nil (not yet)
        let art: Bool
    }

    struct Payload: Encodable {
        let songs: [SongPayload]
        let albums: [Albums.Album]
        let folder: String
        let scanning: Bool
    }

    func payload() -> Payload {
        let stats = store?.playStats() ?? [:]
        let lyrics = store?.lyricsSources() ?? [:]
        let songs = rows.map { r in
            SongPayload(id: r.id, title: Self.title(r), artist: r.artist ?? "", album: r.album ?? "",
                        duration: r.duration, added: r.added, plays: stats[r.id]?.plays ?? 0, skips: stats[r.id]?.skips ?? 0,
                        lastPlayed: stats[r.id]?.lastPlayed, lyrics: lyrics[r.id], art: r.art != nil)
        }
        let albums = Albums.group(rows.map { ($0.id, $0.album) }) { self.byID[$0]?.art }
        return Payload(songs: songs, albums: albums, folder: folder.path, scanning: scanning)
    }

    /// Song keys (name + size) of everything in the library.
    func songKeys() -> Set<String> {
        Set(rows.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased())|\($0.size)" })
    }

    func reveal(_ id: String?) {
        if let id, let url = url(id) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }
}
