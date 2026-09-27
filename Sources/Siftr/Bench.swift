import AppKit
import SifterCore

/// `Siftr --self-test <folder> <report.txt> --bench`: holds the app in
/// each everyday state for a while -- sifting, paused, lyrics, the big
/// visualizer, browsing, minimized -- so scripts/bench.sh can measure memory
/// and CPU in each. Same throwaway preferences and volume 0 as the self-test.
@MainActor
final class Bench {
    private let app: AppController
    private let folder: URL
    private let report: URL
    private var lines: [String] = []
    private let hold = Double(ProcessInfo.processInfo.environment["SIFTER_BENCH_HOLD"] ?? "") ?? 12

    init(app: AppController, folder: URL, report: URL) {
        self.app = app
        self.folder = folder
        self.report = report
    }

    func start() {
        app.window.level = .floating
        app.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        Task {
            await run()
            try? (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    private func run() async {
        guard await waitFor(10, { self.app.isReady }) else { return log("FAIL page never loaded") }
        app.window.orderFrontRegardless()
        placeWindow()
        _ = await waitFor(60, { !self.app.library.scanning && !self.app.library.rows.isEmpty })
        log("library: \(app.library.rows.count) songs")

        await phase("idle")                                         // nothing loaded yet

        app.open(folder)
        _ = await waitFor(10, { self.app.playback.sift.isPlaying })
        await phase("sifting")                                      // the visualizer, 30 a second
        _ = try? await app.webView.evaluateJavaScript("sifter.test.setting({ vizCalm: true }); 1")
        await phase("sifting-calm")                                 // Settings -> Visualizer -> Calm: 15 a second
        _ = try? await app.webView.evaluateJavaScript("sifter.test.setting({ vizCalm: false }); 1")

        app.playback.toggle()
        await phase("sift-paused")

        // SIFTER_BENCH_LYRICS_ID=<library id> [SIFTER_BENCH_AT=<seconds>]: another song for the lyrics states
        let env = ProcessInfo.processInfo.environment
        guard let lyr = env["SIFTER_BENCH_LYRICS_ID"].flatMap({ id in app.library.rows.first { $0.id == id } })
                ?? app.library.rows.first(where: { LibraryService.title($0).hasPrefix("Long L") }),
              let plain = app.library.rows.first(where: { LibraryService.title($0).hasPrefix("Long N") }) else {
            return log("FAIL the bench songs aren't in the library")
        }
        app.playback.playLibrary(lyr.id, queue: [lyr.id, plain.id], at: Double(env["SIFTER_BENCH_AT"] ?? "") ?? 0)
        app.showPage(.now)
        _ = await waitFor(10, { self.app.playback.frameMode == .lyrics })
        await phase("now-lyrics")                                   // the lyrics wheel
        _ = try? await app.webView.evaluateJavaScript("sifter.test.setting({ letterFill: false }); 1")
        await phase("now-lyrics-whole")                             // Settings -> Lyrics: words light up whole
        _ = try? await app.webView.evaluateJavaScript("sifter.test.setting({ letterFill: true }); 1")

        app.playback.playLibrary(plain.id, queue: [plain.id])
        await wait(1)
        _ = try? await app.webView.evaluateJavaScript("document.querySelector('#page-now .ask-card [data-answer=\"no\"]')?.click()")
        _ = await waitFor(10, { self.app.playback.frameMode == .full })
        await phase("now-visualizer")                               // no lyrics: the big visualizer

        app.showPage(.library)
        await phase("library")                                      // browsing, with the mini player

        app.window.miniaturize(nil)
        await phase("minimized")

        // put away a while: the page rests (bench.sh makes that 30 s, not 10 minutes)
        if only?.contains("resting") ?? true {
            log("page rests: " + (await waitFor(60, { self.app.resting }) ? "yes" : "no (FAIL)"))
        }
        await phase("resting")
        let t0 = Date()
        app.window.deminiaturize(nil)
        if await waitFor(15, { self.app.isReady && self.app.window.contentView === self.app.webView }) {
            log(String(format: "page back %.2f s after the window", Date().timeIntervalSince(t0)))
        }
    }

    /// One known screen, so runs compare: a 2x screen has 4 times the pixels
    /// to draw, and a 120 Hz one twice the frames. The one with the menu bar,
    /// or SIFTER_BENCH_SCREEN=2 for the next one. Once the window is showing
    /// (AppKit places a window again when it first appears).
    private func placeWindow() {
        let n = Int(ProcessInfo.processInfo.environment["SIFTER_BENCH_SCREEN"] ?? "") ?? 1
        guard NSScreen.screens.indices.contains(n - 1) else { return log("no screen \(n): staying put") }
        let area = NSScreen.screens[n - 1].visibleFrame
        var f = app.window.frame
        f.size = NSSize(width: min(f.width, area.width), height: min(f.height, area.height))
        f.origin = NSPoint(x: area.midX - f.width / 2, y: area.midY - f.height / 2)
        app.window.setFrame(f, display: true)
    }

    /// SIFTER_BENCH_ONLY=sifting,now-lyrics: measure just those states (quicker experiments).
    private let only = ProcessInfo.processInfo.environment["SIFTER_BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }

    /// Settles for 3 s, then holds; bench.sh measures between START and END.
    private func phase(_ name: String) async {
        if let only, !only.contains(name) { return await wait(1) }
        // SIFTER_BENCH_CSS: extra page styles for an experiment (switching parts off to find a cost)
        if let css = ProcessInfo.processInfo.environment["SIFTER_BENCH_CSS"] {
            // through the style sheet API: the page's security rules block added <style> tags
            let js = "(() => { const sh = document.styleSheets[document.styleSheets.length - 1]; for (const r of \(String(reflecting: css)).split('}')) if (r.trim()) sh.insertRule(r + '}', sh.cssRules.length); })()"
            do { _ = try await app.webView.evaluateJavaScript(js + "; 1") } catch { log("css failed: \(error)") }
            let check = try? await app.webView.evaluateJavaScript("getComputedStyle(document.getElementById('page-now')).display")
            log("page-now display: \(check ?? "nil")")
        }
        await wait(3)
        let shots = ProcessInfo.processInfo.environment["SIFTER_BENCH_SHOTS"].map { URL(fileURLWithPath: $0) }
        // SIFTER_BENCH_BURST=20: that many window pictures 0.15 s apart first, to see motion (the lyrics gliding);
        // SIFTER_BENCH_GAP=0.02 packs them closer, to catch a flash that lasts a frame or two
        if let shots, let burst = Int(ProcessInfo.processInfo.environment["SIFTER_BENCH_BURST"] ?? "") {
            let gap = Double(ProcessInfo.processInfo.environment["SIFTER_BENCH_GAP"] ?? "") ?? 0.15
            for k in 0..<burst {
                shot(shots.appendingPathComponent(String(format: "%@-%03d.png", name, k)))
                await wait(gap)
            }
        }
        log(String(format: "START %@ %.3f visible=%@ screen=%@ page=%d", name, Date().timeIntervalSince1970, app.windowVisible ? "yes" : "no", screen, pagePID))
        if let shots { shot(shots.appendingPathComponent("\(name).png")) }
        let f0 = app.playback.framesSent
        await wait(hold)
        log(String(format: "END %@ %.3f mode=%@ updates=%.1f/s screen=%@", name, Date().timeIntervalSince1970,
                   "\(app.playback.frameMode)", Double(app.playback.framesSent - f0) / hold, screen))
    }

    /// The window as it really shows on screen -- the page and the native bars
    /// together (a web view snapshot has only the page).
    private func shot(_ url: URL) {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(app.window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else { return log("no window image") }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The page's own WebContent process, so bench.sh measures that one and
    /// not another app's (it changes when the page loads again after resting).
    /// A private WebKit property, read only here, in the bench.
    private var pagePID: Int32 {
        let key = "_webProcessIdentifier"
        guard app.webView.responds(to: NSSelectorFromString(key)) else { return 0 }
        return (app.webView.value(forKey: key) as? NSNumber)?.int32Value ?? 0
    }

    /// Which screen the window is on: "2x@60Hz".
    private var screen: String {
        guard let s = app.window.screen else { return "none" }
        return String(format: "%.0fx@%dHz", s.backingScaleFactor, s.maximumFramesPerSecond)
    }

    private func log(_ s: String) {
        lines.append(s)
        print(s)
        fflush(stdout)
    }

    private func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func waitFor(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            await wait(0.1)
        }
        return condition()
    }
}
