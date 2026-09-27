import Foundation

/// Backing the library up to a thumb drive, SD card or external disk (the
/// Python app's backup.py): every song goes to
/// "<drive>/Siftr Backup/<album>/<title>.<ext>" plus a playlist file, only
/// new or changed songs are copied, and nothing is ever deleted from the
/// drive.
public enum Backup {
    public static let folderName = "Siftr Backup"
    public static let playlistName = "Siftr"
    /// Before the rename (and still, in the Python apps). A drive that already
    /// has this folder carries on in it, playlist name and all, instead of
    /// getting a second full copy of the library.
    public static let legacyFolderName = "Music Sifter Backup"
    public static let legacyPlaylistName = "Music Sifter"
    /// Which song went to which file. The Python apps read and write the same
    /// file, so its name stays as it was.
    public static let manifestName = ".music-sifter-backup.json"
    /// What Restore needs, beside the songs. Siftr knows a song by its file
    /// name and size, and the backup names files by title, so the map says
    /// where each song was in the library; and a copy of Siftr's database
    /// keeps its plays, lyrics and sorting history with it.
    public static let restoreMapName = ".siftr-restore.json"
    public static let databaseCopyName = ".siftr-library.db"

    public struct RestoreEntry: Codable, Sendable, Equatable {
        public let id: String, title: String
        public let backup: String            // in the backup folder
        public let original: String          // in the library folder, as it was
        public let size: Int
    }

    public struct RestoreSummary: Codable, Sendable {
        public let copied: Int, bytesCopied: Int
        public let alreadyThere: Int
        public let conflicts: [String]       // a different file already had that name: left alone
        public let missing: [String]         // not on the drive any more
    }

    /// The backup folder on `drive`, and what its playlist is called.
    public static func destination(on drive: URL) -> (folder: URL, playlist: String) {
        let fm = FileManager.default
        let current = drive.appendingPathComponent(folderName, isDirectory: true)
        let legacy = drive.appendingPathComponent(legacyFolderName, isDirectory: true)
        if !fm.fileExists(atPath: current.path) && fm.fileExists(atPath: legacy.path) {
            return (legacy, legacyPlaylistName)
        }
        return (current, playlistName)
    }

    public struct Song: Sendable {
        public let id: String, title: String, artist: String, album: String
        public let duration: Double
        public let path: URL?
        public init(id: String, title: String, artist: String, album: String, duration: Double, path: URL?) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.path = path
        }
    }

    public struct Entry: Sendable {
        public let song: Song
        public let source: URL
        public let rel: String
        public let size: Int
    }

    public struct Unavailable: Codable, Sendable, Equatable {
        public let title: String, why: String
    }

    public struct Plan: Sendable {
        public var toCopy: [Entry] = []
        public var upToDate: [Entry] = []
        public var unavailable: [Unavailable] = []
        public var manifest: [String: String] = [:]
    }

    public struct Summary: Codable, Sendable {
        public let folder: String
        public let copied: Int
        public let bytesCopied: Int
        public let upToDate: Int
        public let unavailable: [Unavailable]
        public let notInLibraryAnymore: [String]
    }

    public struct BackupError: LocalizedError {
        public let errorDescription: String?
    }

    /// A file or folder name that works on FAT32 / exFAT cards too.
    public static func safeName(_ text: String, limit: Int = 120) -> String {
        let banned = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        var s = String(String.UnicodeScalarView(text.unicodeScalars.map { banned.contains($0) ? "_" : $0 }))
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix(".") { s.removeLast() }
        s = String(s.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Untitled" : s
    }

    /// Where each song goes on the drive, and what needs copying.
    public static func plan(_ songs: [Song], dest: URL) -> Plan {
        var plan = Plan()
        if let data = try? Data(contentsOf: dest.appendingPathComponent(manifestName)),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            plan.manifest = saved
        }
        var used = Set(plan.manifest.values)
        for song in songs {
            guard let src = song.path, FileManager.default.fileExists(atPath: src.path) else {
                plan.unavailable.append(Unavailable(title: song.title, why: "no audio file on this Mac"))
                continue
            }
            let ext = src.pathExtension.lowercased()
            if ext == "m4p" {
                plan.unavailable.append(Unavailable(title: song.title, why: "copy-protected Apple Music file"))
                continue
            }
            var rel = plan.manifest[song.id]
            if rel == nil {
                let base = "\(safeName(song.album.isEmpty ? "Unknown Album" : song.album))/\(safeName(song.title))"
                var candidate = "\(base).\(ext)"
                var n = 2
                while used.contains(candidate) {             // two different songs, same album and title
                    candidate = "\(base) (\(n)).\(ext)"
                    n += 1
                }
                used.insert(candidate)
                rel = candidate
            }
            // sizes straight from the disk (a URL can hold on to an old answer)
            let size = fileSize(src.path) ?? 0
            let entry = Entry(song: song, source: src, rel: rel!, size: size)
            let targetSize = fileSize(dest.appendingPathComponent(rel!).path)
            if targetSize == size { plan.upToDate.append(entry) } else { plan.toCopy.append(entry) }
        }
        return plan
    }

    static func fileSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
    }

    /// An .m3u8 playlist, in library order, with paths relative to the backup folder.
    public static func playlist(_ entries: [Entry]) -> String {
        var lines = ["#EXTM3U"]
        for e in entries {
            let who = e.song.artist.isEmpty ? e.song.title : "\(e.song.artist) - \(e.song.title)"
            lines.append("#EXTINF:\(Int(e.song.duration)),\(who)")
            lines.append(e.rel)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Backs `songs` up to `drive`, calling progress(done, total, title) as
    /// files are copied. Each file is copied under a temporary name first, so
    /// a yanked card never leaves a half-copied song that looks finished.
    public static func run(_ songs: [Song], drive: URL, library: URL? = nil,
                           progress: (Int, Int, String?) -> Void) throws -> Summary {
        let fm = FileManager.default
        let (dest, playlistName) = destination(on: drive)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var p = plan(songs, dest: dest)
        let needed = p.toCopy.reduce(0) { $0 + $1.size }
        if let free = try? dest.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           needed > free {
            throw BackupError(errorDescription: String(format: "Not enough space: this needs %.2f GB, the drive has %.2f GB free.",
                                                       Double(needed) / 1e9, Double(free) / 1e9))
        }
        func saveManifest() throws {
            let data = try JSONEncoder().encode(p.manifest)
            try data.write(to: dest.appendingPathComponent(manifestName), options: .atomic)
        }
        for (i, e) in p.toCopy.enumerated() {
            progress(i, p.toCopy.count, e.song.title)
            let target = dest.appendingPathComponent(e.rel)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".part")
            try? fm.removeItem(at: partial)
            // the song's data only: Mac metadata would litter the card with "._" files
            guard copyfile(e.source.path, partial.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                throw BackupError(errorDescription: "Couldn't copy \(e.song.title): \(String(cString: strerror(errno)))")
            }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: partial, to: target)
            p.manifest[e.song.id] = e.rel
            try saveManifest()                             // progress survives an interruption
        }
        for e in p.upToDate { p.manifest[e.song.id] = e.rel }
        try saveManifest()
        let byID = Dictionary((p.upToDate + p.toCopy).map { ($0.song.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = songs.compactMap { byID[$0.id] }
        try Data(playlist(ordered).utf8).write(to: dest.appendingPathComponent("\(safeName(playlistName)).m3u8"), options: .atomic)
        if let library {                                   // where each song was, for Restore
            let root = library.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let map = ordered.map { e -> RestoreEntry in
                let path = e.source.standardizedFileURL.resolvingSymlinksInPath().path
                return RestoreEntry(id: e.song.id, title: e.song.title, backup: e.rel,
                                    original: path.hasPrefix(root) ? String(path.dropFirst(root.count)) : e.rel, size: e.size)
            }
            try JSONEncoder().encode(map).write(to: dest.appendingPathComponent(restoreMapName), options: .atomic)
        }
        progress(p.toCopy.count, p.toCopy.count, nil)
        let current = Set(songs.map(\.id))
        return Summary(folder: dest.path, copied: p.toCopy.count, bytesCopied: needed, upToDate: p.upToDate.count,
                       unavailable: p.unavailable,
                       notInLibraryAnymore: p.manifest.filter { !current.contains($0.key) }.map(\.value).sorted())
    }

    /// The restore map on `drive`, if its backup has one (backups made before
    /// Restore existed don't).
    public static func restoreEntries(on drive: URL) -> [RestoreEntry]? {
        let folder = destination(on: drive).folder
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(restoreMapName)) else { return nil }
        return try? JSONDecoder().decode([RestoreEntry].self, from: data)
    }

    /// Copies the backed-up songs on `drive` back into `library` under their
    /// original names (so Siftr knows them again). Never replaces anything:
    /// a song already there is left, and a different file that has the name
    /// is left and reported. Each song is copied under a temporary name
    /// first, so a yanked drive never leaves a half-copied song behind.
    public static func restore(from drive: URL, into library: URL,
                               progress: (Int, Int, String?) -> Void) throws -> RestoreSummary {
        let fm = FileManager.default
        let folder = destination(on: drive).folder
        guard let map = restoreEntries(on: drive) else {
            throw BackupError(errorDescription: "This backup was made before Siftr could restore. Update it from the Mac that has your library first.")
        }
        var copies: [(RestoreEntry, URL, URL)] = []
        var already = 0
        var conflicts: [String] = [], missing: [String] = []
        for e in map {
            let src = folder.appendingPathComponent(e.backup), dst = library.appendingPathComponent(e.original)
            guard fileSize(src.path) == e.size else { missing.append(e.title); continue }
            if let there = fileSize(dst.path) {
                if there == e.size { already += 1 } else { conflicts.append(e.title) }
                continue
            }
            copies.append((e, src, dst))
        }
        let needed = copies.reduce(0) { $0 + $1.0.size }
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        if let free = try? library.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           Int64(needed) > free {
            throw BackupError(errorDescription: String(format: "Not enough space: this needs %.2f GB, the Mac has %.2f GB free.",
                                                       Double(needed) / 1e9, Double(free) / 1e9))
        }
        for (i, (e, src, dst)) in copies.enumerated() {
            progress(i, copies.count, e.title)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = dst.deletingLastPathComponent().appendingPathComponent(dst.lastPathComponent + ".part")
            try? fm.removeItem(at: partial)
            guard copyfile(src.path, partial.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                throw BackupError(errorDescription: "Couldn't copy \(e.title): \(String(cString: strerror(errno)))")
            }
            try fm.moveItem(at: partial, to: dst)
        }
        progress(copies.count, copies.count, nil)
        return RestoreSummary(copied: copies.count, bytesCopied: needed, alreadyThere: already,
                              conflicts: conflicts.sorted(), missing: missing.sorted())
    }
}
