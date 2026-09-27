import AVFoundation
import CryptoKit
import Foundation

struct Tags: Sendable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
}

struct Artwork: Sendable {
    let data: Data
    let mime: String
}

/// What the library index keeps about a song.
struct SongDetails: Sendable {
    var tags: Tags
    var duration: Double
    var artHash: String?     // short fingerprint of its cover, to spot the album's real cover
}

/// Title, artist, album and cover art from a song's tags. AVFoundation reads
/// MP3 (ID3) and M4A (iTunes atoms) through its "common" keys; FLAC and OGG
/// (Vorbis comments) and WAV (RIFF INFO) only through the full metadata list,
/// so both are asked. FLAC cover art isn't exposed at all, so a few lines
/// below read its PICTURE block directly.
enum MetadataReader {
    static func tags(for url: URL) async -> Tags {
        let asset = AVURLAsset(url: url)
        var tags = Tags()
        if let common = try? await asset.load(.commonMetadata) {
            for item in common {
                switch item.commonKey {
                case .commonKeyTitle: if tags.title == nil { tags.title = await string(item) }
                case .commonKeyArtist: if tags.artist == nil { tags.artist = await string(item) }
                case .commonKeyAlbumName: if tags.album == nil { tags.album = await string(item) }
                default: break
                }
            }
        }
        if tags.title == nil || tags.artist == nil || tags.album == nil,
           let all = try? await asset.load(.metadata) {
            for item in all {
                switch fieldName(item) {
                case "title", "info-title": if tags.title == nil { tags.title = await string(item) }
                case "artist", "info-artist": if tags.artist == nil { tags.artist = await string(item) }
                case "album", "info-album": if tags.album == nil { tags.album = await string(item) }
                default: break
                }
            }
        }
        return tags
    }

    /// Tags, length and a cover fingerprint in one go (for the library index).
    static func details(for url: URL) async -> SongDetails {
        async let tags = tags(for: url)
        async let art = artwork(for: url)
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        let hash = await art.map { SHA256.hash(data: $0.data).prefix(6).map { String(format: "%02x", $0) }.joined() }
        return SongDetails(tags: await tags, duration: seconds.isFinite ? seconds : 0, artHash: hash)
    }

    /// Plain (untimed) lyrics stored in the file's tags, if any.
    static func embeddedLyrics(for url: URL) async -> String? {
        guard let text = try? await AVURLAsset(url: url).load(.lyrics) else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    static func artwork(for url: URL) async -> Artwork? {
        let asset = AVURLAsset(url: url)
        if let common = try? await asset.load(.commonMetadata) {
            for item in common where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    return Artwork(data: data, mime: sniffImageType(data))
                }
            }
        }
        if url.pathExtension.lowercased() == "flac", let data = flacPicture(url) {
            return Artwork(data: data, mime: sniffImageType(data))
        }
        // OGG files can carry a FLAC-style picture, base64'd into a comment
        if let all = try? await asset.load(.metadata) {
            for item in all where fieldName(item) == "metadata_block_picture" {
                if let text = await string(item), let block = Data(base64Encoded: text),
                   let data = parsePictureBlock([UInt8](block)) {
                    return Artwork(data: data, mime: sniffImageType(data))
                }
            }
        }
        return nil
    }

    // MARK: - helpers

    /// "vorb/TITLE" -> "title", "caaf/info-title" -> "info-title".
    private static func fieldName(_ item: AVMetadataItem) -> String {
        let raw = item.identifier?.rawValue ?? ""
        let field = raw.split(separator: "/", maxSplits: 1).last.map(String.init) ?? raw
        return (field.removingPercentEncoding ?? field).lowercased()
    }

    private static func string(_ item: AVMetadataItem) async -> String? {
        guard let s = try? await item.load(.stringValue) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sniffImageType(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return "image/jpeg"
    }

    /// The first PICTURE block in a FLAC file's metadata, if any.
    static func flacPicture(_ url: URL) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard (try? fh.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }
        while true {
            guard let header = try? fh.read(upToCount: 4), header.count == 4 else { return nil }
            let h = [UInt8](header)
            let isLast = h[0] & 0x80 != 0
            let type = h[0] & 0x7F
            let length = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            if type == 6 {
                guard let body = try? fh.read(upToCount: length) else { return nil }
                return parsePictureBlock([UInt8](body))
            }
            guard !isLast, (try? fh.seek(toOffset: fh.offset() + UInt64(length))) != nil else { return nil }
        }
    }

    /// FLAC PICTURE layout: type, mime, description, 4 size fields, then the image.
    static func parsePictureBlock(_ b: [UInt8]) -> Data? {
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        }
        guard u32() != nil, let mimeLength = u32() else { return nil }
        i += mimeLength
        guard let descLength = u32() else { return nil }
        i += descLength
        for _ in 0..<4 { guard u32() != nil else { return nil } }
        guard let length = u32(), length > 0, i + length <= b.count else { return nil }
        return Data(b[i..<(i + length)])
    }
}
