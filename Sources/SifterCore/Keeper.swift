import Foundation

/// Copying a kept song into the library, and taking it back out on undo.
/// Nothing here ever writes to, moves or deletes a source file.
public enum Keeper {
    /// Copies `source` into `library` under its own name, or "name (2).ext",
    /// "name (3).ext"... if that's taken. The copy keeps the original's dates.
    /// Returns where the copy went.
    public static func copy(_ source: URL, into library: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = n == 1 ? source.lastPathComponent : "\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            let dest = library.appendingPathComponent(name)
            n += 1
            if fm.fileExists(atPath: dest.path) { continue }
            do {
                // copyItem never overwrites: if another copy grabbed this name
                // a moment ago it fails, and the loop tries the next name.
                try fm.copyItem(at: source, to: dest)
            } catch CocoaError.fileWriteFileExists {
                continue
            }
            // like Python's copy2: the copy carries the original's dates. A Mac
            // copy normally keeps them exactly; only fix them up if it didn't
            // (rewriting them anyway would round off the nanoseconds).
            if let src = try? fm.attributesOfItem(atPath: source.path),
               let made = try? fm.attributesOfItem(atPath: dest.path) {
                var fix: [FileAttributeKey: Any] = [:]
                for key in [FileAttributeKey.modificationDate, .creationDate] {
                    if let want = src[key] as? Date, let got = made[key] as? Date,
                       abs(want.timeIntervalSince(got)) > 0.001 { fix[key] = want }
                }
                if !fix.isEmpty { try? fm.setAttributes(fix, ofItemAtPath: dest.path) }
            }
            return dest
        }
    }

    /// Undo of a keep: moves the app's own library copy to the Trash. Refuses
    /// anything outside the library folder, so a bad database row can never
    /// touch another file. Returns false if there was nothing to remove.
    @discardableResult
    public static func removeCopy(atPath path: String, library: URL) throws -> Bool {
        let copy = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = library.standardizedFileURL.resolvingSymlinksInPath()
        guard copy.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "\(copy.lastPathComponent) isn't in the library folder, so it was left alone."])
        }
        guard FileManager.default.fileExists(atPath: copy.path) else { return false }
        try moveToTrash(copy)
        return true
    }

    /// Moves a file or folder to the Trash, where it can be taken back out.
    /// (SIFTER_TRASH: tests and experiments use a scratch folder instead.)
    public static func moveToTrash(_ url: URL) throws {
        if let trash = ProcessInfo.processInfo.environment["SIFTER_TRASH"], !trash.isEmpty {
            let dir = URL(fileURLWithPath: trash, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(UUID().uuidString.prefix(8)) \(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: dest)
        } else {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }
}
