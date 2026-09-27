import Foundation

/// Where the app keeps things. Both folders are created on first use.
public enum Paths {
    /// ~/Library/Application Support/Siftr. Before the rename it was "Music
    /// Sifter Lite" (the Windows app's name for it); the first launch after
    /// the rename moves that folder here, database and lyrics model included.
    /// Not plain "Music Sifter": the bigger Python app keeps a different
    /// library.db there. `SIFTER_DATA` overrides it (tests, experiments).
    public static func dataDir() -> URL {
        let url: URL
        if let env = ProcessInfo.processInfo.environment["SIFTER_DATA"], !env.isEmpty {
            url = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            let support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            url = renamed(support.appendingPathComponent("Music Sifter Lite", isDirectory: true),
                          to: support.appendingPathComponent("Siftr", isDirectory: true), move: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The folder the listener picked in Settings to be their library, if any.
    nonisolated(unsafe) public static var libraryChoice: URL?

    /// The library: ~/Music/Siftr unless another folder was picked in
    /// Settings, or ~/Music/Music Sifter is there from before the rename. That
    /// one is used where it is and never moved: the database remembers every
    /// song by its path, and the Python apps keep their library there too.
    /// Keep copies songs here, and the Library page lists what's in it.
    /// `SIFTER_LIBRARY` overrides it (tests, experiments).
    public static func libraryDir() -> URL {
        let url: URL
        if let env = ProcessInfo.processInfo.environment["SIFTER_LIBRARY"], !env.isEmpty {
            url = URL(fileURLWithPath: env, isDirectory: true)
        } else if let choice = libraryChoice {
            url = choice
        } else {
            let music = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
            url = renamed(music.appendingPathComponent("Music Sifter", isDirectory: true),
                          to: music.appendingPathComponent("Siftr", isDirectory: true), move: false)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A folder that had another name before the rename to Siftr: the new one
    /// if it's there, else the old one if it's there (moved to the new name
    /// first when `move`), else the new one. The new name wins once it exists,
    /// so the answer never flips back later. A move that fails leaves the old
    /// folder in use as it is: nothing is lost or split in two.
    public static func renamed(_ old: URL, to new: URL, move: Bool) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: new.path) { return new }
        guard fm.fileExists(atPath: old.path) else { return new }
        guard move else { return old }
        do {
            try fm.moveItem(at: old, to: new)
            return new
        } catch {
            return old
        }
    }

    public static func databaseURL() -> URL {
        dataDir().appendingPathComponent("library.db")
    }
}
