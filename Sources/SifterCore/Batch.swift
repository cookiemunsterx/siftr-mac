import Foundation

/// Finishing a batch (the Python app's Finish batch): once every kept song is
/// verified safe in the library, the batch folder goes to the Trash -- where
/// it can still be taken back out. Never a folder that isn't a batch.
public enum Batch {
    public struct Summary: Sendable, Equatable {
        public let name: String
        public let kept: Int
        public let passed: Int
        public let unsorted: [String]      // songs not decided yet (their names)
        public let problems: [String]      // any of these and the batch can't be finished
        public let bytes: Int              // everything in the folder
    }

    static func standardized(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    static func isInside(_ a: URL, _ b: URL) -> Bool {
        let a = standardized(a).path, b = standardized(b).path
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// Why a folder can't be sifted (nil if it can): the home folder, a whole
    /// drive, or a folder that is, is inside, or holds the library.
    public static func siftRefusal(_ folder: URL, library: URL,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let f = standardized(folder)
        if f.path == standardized(home).path || f.path == "/" || isVolumeRoot(f) {
            return "That's a whole drive or your whole home folder. Pick the folder your new songs are in."
        }
        if isInside(f, library) || isInside(library, f) {
            return "That folder is (or holds) your library. Pick the folder your new songs are in."
        }
        return nil
    }

    /// Why a folder must never be thrown away as a batch (nil if it can be):
    /// everything siftRefusal refuses, plus the Mac's own folders -- Downloads
    /// can be sifted, but "finishing" it would bin everything in it.
    public static func finishRefusal(_ folder: URL, library: URL,
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        if let reason = siftRefusal(folder, library: library, home: home) { return reason }
        let f = standardized(folder)
        let own = ["Desktop", "Documents", "Downloads", "Music", "Movies", "Pictures", "Library", "Public", "Applications"]
        if own.contains(where: { standardized(home.appendingPathComponent($0)).path == f.path }) {
            return "“\(f.lastPathComponent)” is one of your Mac's own folders, so Finish batch won't throw it away. It's for a folder made just for a batch of new songs."
        }
        if ["/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/usr", "/opt"].contains(f.path) {
            return "That's one of your Mac's system folders, so Finish batch won't touch it."
        }
        return nil
    }

    static func isVolumeRoot(_ url: URL) -> Bool {
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return standardized(volume).path == standardized(url).path
    }

    /// What finishing would do, after checking every kept song: its library
    /// copy has to exist and match the song in the batch (which is about to go
    /// to the Trash). `libraryKeys`: song keys of what's in the library, for
    /// kept songs whose recorded copy has since moved within it.
    public static func summary(_ folder: URL, store: LibraryStore, libraryKeys: Set<String>) -> Summary {
        var kept = 0, passed = 0
        var unsorted: [String] = []
        var problems: [String] = []
        for song in FolderScanner.scan(folder) {
            let key = songKey(for: song)
            let title = song.deletingPathExtension().lastPathComponent
            switch store.decision(for: key) {
            case "keep":
                let size = fileSize(song)
                let copy = store.copiedPath(for: key).map { URL(fileURLWithPath: $0) }
                if let copy, FileManager.default.fileExists(atPath: copy.path), fileSize(copy) == size {
                    kept += 1
                } else if libraryKeys.contains(key) {
                    kept += 1                                  // the copy's elsewhere in the library now
                } else if let copy, FileManager.default.fileExists(atPath: copy.path) {
                    problems.append("\(title): its copy in your library doesn't match this one")
                } else {
                    problems.append("\(title): its copy isn't in your library any more")
                }
            case "pass": passed += 1
            default: unsorted.append(title)
            }
        }
        return Summary(name: folder.lastPathComponent, kept: kept, passed: passed, unsorted: unsorted,
                       problems: problems, bytes: folderSize(folder))
    }

    static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
    }

    static func folderSize(_ folder: URL) -> Int {
        var total = 0
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        while let url = walker?.nextObject() as? URL {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
