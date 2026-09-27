import Foundation

public let audioExtensions: Set<String> = ["mp3", "wav", "flac", "ogg", "m4a"]

/// Songs longer than this still play and can be sorted, but aren't decoded
/// whole for the visualizer (a 2-hour mix would take about 300 MB) or sent to
/// Whisper (it would take ages). Only a song's own length counts: a batch can
/// hold as many songs as you like. (The page's LONG_SONG in core.js matches.)
public let longSongSeconds: Double = 20 * 60

public enum Decision: String, Sendable, Codable {
    case keep, pass, skip
}

/// A song's identity that survives it being copied or moved: the lowercased
/// file name plus its size in bytes ("song a.mp3|4185032"). Two different
/// songs with the same name and size would collide -- a known, accepted limit.
/// The name is NFC-normalized so it matches what Windows stores for the same
/// file (macOS hands out decomposed accents).
public func songKey(for url: URL) -> String {
    let name = url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return "\(name)|\(size)"
}

/// 0:00-style time, like the original's fmt_time.
public func formatTime(_ seconds: Double) -> String {
    let s = seconds.isFinite ? max(0, Int(seconds)) : 0
    return String(format: "%d:%02d", s / 60, s % 60)
}
