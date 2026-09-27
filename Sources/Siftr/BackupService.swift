import AppKit
import SifterCore

/// The Backup page: drives plugged into this Mac, backing the library up to
/// one (SifterCore's Backup does the copying) with a copy of Siftr's history,
/// restoring from one, and ejecting it afterwards.
@MainActor
final class BackupService {
    let library: LibraryService
    var onChange: (() -> Void)?

    struct Drive: Encodable {
        let name: String, path: String
        let free: Int, total: Int
        let songsBackedUp: Int
        let canRestore: Bool                  // its backup has the map Restore needs
    }

    struct Restored: Encodable {
        let files: Backup.RestoreSummary
        let history: LibraryStore.MergeSummary?
    }

    struct Status: Encodable {
        var running = false
        var drive: String?
        var done = 0, total = 0
        var current: String?
        var result: Backup.Summary?
        var error: String?
        var mode = "backup"                   // or "restore"
        var restored: Restored?
    }

    private(set) var status = Status()

    init(library: LibraryService) {
        self.library = library
    }

    /// Writable drives plugged in -- USB sticks, SD cards, external disks --
    /// never the disk this Mac runs from.
    func drives() -> [Drive] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsLocalKey,
                                      .volumeIsReadOnlyKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsRootFileSystem != true, v.volumeIsBrowsable == true, v.volumeIsLocal == true,
                  v.volumeIsReadOnly != true,
                  v.volumeIsRemovable == true || v.volumeIsEjectable == true || v.volumeIsInternal == false,
                  FileManager.default.isWritableFile(atPath: url.path) else { return nil }
            let manifest = Backup.destination(on: url).folder.appendingPathComponent(Backup.manifestName)
            let backedUp = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?.count ?? 0
            return Drive(name: v.volumeName ?? url.lastPathComponent, path: url.path, free: v.volumeAvailableCapacity ?? 0,
                         total: v.volumeTotalCapacity ?? 0, songsBackedUp: backedUp, canRestore: Backup.restoreEntries(on: url) != nil)
        }
    }

    /// Bytes a full backup takes.
    func librarySize() -> Int { library.rows.reduce(0) { $0 + $1.size } }

    func songs() -> [Backup.Song] {
        library.rows.map { r in
            Backup.Song(id: r.id, title: LibraryService.title(r), artist: r.artist ?? "", album: r.album ?? "",
                        duration: r.duration, path: URL(fileURLWithPath: r.path))
        }
    }

    func start(_ path: String) {
        guard !status.running else { return }
        status = Status(running: true, drive: path)
        onChange?()
        let songs = songs()
        let drive = URL(fileURLWithPath: path, isDirectory: true)
        let libraryFolder = library.folder
        Task {
            let outcome: Result<Backup.Summary, Error> = await Task.detached(priority: .utility) {
                Result {
                    let summary = try Backup.run(songs, drive: drive, library: libraryFolder) { done, total, title in
                        Task { @MainActor [weak self] in self?.progress(done, total, title) }
                    }
                    Self.cleanUpMacFiles(URL(fileURLWithPath: summary.folder).lastPathComponent, on: drive)
                    return summary
                }
            }.value
            if case .success(let summary) = outcome {
                // the history goes with the songs: a copy of the database, for Restore
                let copy = URL(fileURLWithPath: summary.folder).appendingPathComponent(Backup.databaseCopyName)
                do { try self.library.store?.snapshot(to: copy) } catch { self.status.error = "The songs are backed up, but Siftr's history couldn't be copied: \(error.localizedDescription)" }
            }
            self.status.running = false
            self.status.current = nil
            switch outcome {
            case .success(let summary): self.status.result = summary
            case .failure(let error): self.status.error = error.localizedDescription
            }
            self.onChange?()
        }
    }

    /// Puts the library back from a drive (after the Mac lost it, or on a new
    /// Mac): the songs under their original names, then their history --
    /// plays, lyrics, sorting decisions -- merged in. Nothing here is replaced.
    func restore(_ path: String) {
        guard !status.running else { return }
        status = Status(running: true, drive: path, mode: "restore")
        onChange?()
        let drive = URL(fileURLWithPath: path, isDirectory: true)
        let into = library.folder
        Task {
            let outcome: Result<Backup.RestoreSummary, Error> = await Task.detached(priority: .utility) {
                Result {
                    try Backup.restore(from: drive, into: into) { done, total, title in
                        Task { @MainActor [weak self] in self?.progress(done, total, title) }
                    }
                }
            }.value
            var history: LibraryStore.MergeSummary?
            if case .success = outcome {
                // merged from a copy on this Mac (the drive can be slow, or unplugged mid-way)
                let saved = Backup.destination(on: drive).folder.appendingPathComponent(Backup.databaseCopyName)
                let local = FileManager.default.temporaryDirectory.appendingPathComponent("siftr-restore-\(UUID().uuidString).db")
                if (try? FileManager.default.copyItem(at: saved, to: local)) != nil {
                    history = try? self.library.store?.merge(from: local)
                    try? FileManager.default.removeItem(at: local)
                }
            }
            self.status.running = false
            self.status.current = nil
            switch outcome {
            case .success(let files): self.status.restored = Restored(files: files, history: history)
            case .failure(let error): self.status.error = error.localizedDescription
            }
            self.library.refresh()
            self.onChange?()
        }
    }

    private func progress(_ done: Int, _ total: Int, _ title: String?) {
        guard status.running else { return }
        status.done = done
        status.total = total
        status.current = title
        onChange?()
    }

    /// Cards formatted FAT32/exFAT keep macOS's hidden metadata as "._" files
    /// beside each song -- junk to a car stereo -- so macOS's own dot_clean
    /// tidies them away.
    nonisolated static func cleanUpMacFiles(_ folder: String, on drive: URL) {
        let tool = "/usr/sbin/dot_clean"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-m", drive.appendingPathComponent(folder).path]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: drive.appendingPathComponent("._\(folder)"))
    }

    func eject(_ path: String) -> String? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
