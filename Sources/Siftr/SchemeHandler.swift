import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Answers the web view's requests for sifter://app/... -- the page's own
/// files and cover art (/art/sift/<id>, /art/lib/<id>, optionally ?s=<size>
/// for a small thumbnail). Nothing goes over a network, and the page can
/// only ask for art by a number the app handed it, never by path.
@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "sifter"
    static let origin = "sifter://app"

    private let webRoot: URL
    private let artwork: (String, String) async -> Artwork?     // (sift|lib, id)
    private var live = Set<ObjectIdentifier>()                   // requests WebKit hasn't cancelled
    private let thumbs = NSCache<NSString, NSData>()
    private var noArt = Set<String>()

    init(webRoot: URL, artwork: @escaping (String, String) async -> Artwork?) {
        self.webRoot = webRoot
        self.artwork = artwork
        thumbs.countLimit = 400
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        live.insert(ObjectIdentifier(task))
        guard let url = task.request.url, url.host == "app" else { return respond(task, 400) }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "art", ["sift", "lib"].contains(parts[1]) {
            let size = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "s" })?.value.flatMap(Int.init)
            serveArt(task, kind: parts[1], id: parts[2], size: size)
        } else {
            serveStatic(task, parts.isEmpty ? "index.html" : parts.joined(separator: "/"))
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    private func serveArt(_ task: any WKURLSchemeTask, kind: String, id: String, size: Int?) {
        let key = "\(kind)/\(id)/\(size ?? 0)"
        if noArt.contains("\(kind)/\(id)") { return respond(task, 404) }
        if let cached = thumbs.object(forKey: key as NSString) {
            return respond(task, 200, cached as Data, ["Content-Type": "image/jpeg"])
        }
        let taskID = ObjectIdentifier(task)
        nonisolated(unsafe) let pending = task
        Task {
            let art = await artwork(kind, id)
            var body = art?.data
            var mime = art?.mime ?? "image/jpeg"
            if let data = body, let size {
                // a list thumbnail: shrink it here rather than hand the page a big cover
                body = await Task.detached(priority: .utility) { Self.thumbnail(data, pixels: size * 2) }.value ?? data
                mime = "image/jpeg"
                if let body { thumbs.setObject(body as NSData, forKey: key as NSString) }
            }
            guard live.contains(taskID) else { return }         // talking to a cancelled request crashes
            if let body {
                respond(pending, 200, body, ["Content-Type": mime])
            } else {
                noArt.insert("\(kind)/\(id)")
                respond(pending, 404)
            }
        }
    }

    nonisolated static func thumbnail(_ data: Data, pixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// A song's art changed (or it arrived): forget what was cached for it.
    func forget(kind: String, id: String) {
        noArt.remove("\(kind)/\(id)")
    }

    /// Only plain files sitting directly in web/.
    private func serveStatic(_ task: any WKURLSchemeTask, _ name: String) {
        guard !name.contains("/"), !name.hasPrefix("."),
              let data = try? Data(contentsOf: webRoot.appendingPathComponent(name)) else { return respond(task, 404) }
        var headers = ["Content-Type": Self.mimeType(name)]
        if name.hasSuffix(".html") {
            headers["Content-Security-Policy"] =
                "default-src 'self'; img-src 'self' data:; connect-src 'none'; media-src 'none'; object-src 'none'; base-uri 'none'"
        }
        respond(task, 200, data, headers)
    }

    private func respond(_ task: any WKURLSchemeTask, _ status: Int, _ data: Data = Data(), _ headers: [String: String] = [:]) {
        guard let url = task.request.url else { return }
        var h = headers
        h["Content-Length"] = "\(data.count)"
        h["Cache-Control"] = "no-store"
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!)
        if !data.isEmpty { task.didReceive(data) }
        live.remove(ObjectIdentifier(task))
        task.didFinish()
    }

    nonisolated static func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }
}
