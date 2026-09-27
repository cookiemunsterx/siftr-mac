import Foundation

public enum FolderScanner {
    /// Every audio file under `folder`, subfolders included, sorted by full
    /// path. Hidden folders (".something") are skipped, and so are hidden
    /// files -- on a Mac that also drops the "._song.mp3" shadow files macOS
    /// leaves on USB sticks, which aren't songs.
    public static func scan(_ folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walker = FileManager.default.enumerator(
            at: folder.standardizedFileURL, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in true })  // an unreadable subfolder shouldn't stop the scan
        else { return [] }

        var found: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if name.hasPrefix(".") {
                if isDir { walker.skipDescendants() }
                continue
            }
            if !isDir && audioExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}
