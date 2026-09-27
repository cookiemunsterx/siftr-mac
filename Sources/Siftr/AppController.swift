import AppKit
import SifterCore
import WebKit

/// Where preferences are kept: the Mac's normal defaults, or a throwaway
/// set for the self-test (so a test run never changes the listener's own).
enum Prefs {
    nonisolated(unsafe) static var store: UserDefaults = .standard
}

/// The app: the window and its web view, the pages, and the services behind
/// them. The page (web/*.js) draws what it's sent and asks for what it
/// needs; every rule and all the playback live here, so music keeps playing
/// while the window is hidden.
@MainActor
final class AppController: NSObject {
    enum Page: Int, CaseIterable {
        case sift, library, now, top, trends, backup
        static let names = ["sift", "library", "now", "top", "trends", "backup"]
        var name: String { Self.names[rawValue] }
        init?(name: String) {
            guard let i = Self.names.firstIndex(of: name) else { return nil }
            self.init(rawValue: i)
        }
    }

    let window: MainWindow
    let webView: SifterWebView
    let store: LibraryStore?
    let playback = Playback(remoteControls: !CommandLine.arguments.contains("--self-test"))
    let sift: SiftController
    let library: LibraryService
    let lyrics: LyricsService
    let backup: BackupService
    private let schemes: SchemeHandler
    private(set) var page: Page = .sift
    private var pageReady = false
    private var pendingFolder: URL?
    private(set) var typing = false
    private var nowShowsLyrics = false        // Now Playing's lyrics wheel is up (no visualizer showing)
    private var vizShown = false              // the page has a visualizer spot showing, uncovered
    let bars = BarsView()
    private let restView = NSView()           // the window's plain background, while the page rests
    private var restTimer: Timer?
    private(set) var resting = false
    /// How long the window stays put away before the page rests (SIFTER_REST_AFTER for tests).
    static let restAfter = Double(ProcessInfo.processInfo.environment["SIFTER_REST_AFTER"] ?? "") ?? 600
    private var siftPushQueued = false
    private var nowPushQueued = false

    var isReady: Bool { pageReady }
    var windowVisible: Bool { window.occlusionState.contains(.visible) }

    init(webRoot: URL) {
        if let chosen = Prefs.store.string(forKey: "libraryFolder") {
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: chosen, isDirectory: &dir), dir.boolValue {
                Paths.libraryChoice = URL(fileURLWithPath: chosen, isDirectory: true)
            }
        }
        var opened: LibraryStore?
        var problem: String?
        do { opened = try LibraryStore() } catch { problem = "\(error)" }
        store = opened
        library = LibraryService(store: opened)
        lyrics = LyricsService(store: opened, library: library)
        backup = BackupService(library: library)
        sift = SiftController(store: opened, playback: playback)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()          // nothing written to disk
        let bridge = ScriptBridge()
        config.userContentController.add(bridge, name: "sifter")
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "api")
        var artLookup: (String, String) async -> Artwork? = { _, _ in nil }
        schemes = SchemeHandler(webRoot: webRoot, artwork: { await artLookup($0, $1) })
        config.setURLSchemeHandler(schemes, forURLScheme: SchemeHandler.scheme)
        webView = SifterWebView(frame: .zero, configuration: config)
        window = MainWindow(content: webView, colors: Prefs.store.stringArray(forKey: "colors") ?? Self.auroraColors)
        super.init()

        artLookup = { [weak self] kind, id in
            guard let self else { return nil }
            let url = kind == "sift" ? Int(id).flatMap { self.sift.url(forArt: $0) } : self.library.url(id)
            guard let url else { return nil }
            return await MetadataReader.artwork(for: url)
        }
        bridge.app = self
        wire()
        playback.volume = Prefs.store.object(forKey: "volume") as? Int ?? 70
        page = Page(name: Prefs.store.string(forKey: "page") ?? "") ?? .sift
        if page == .backup { page = .library }
        if let problem { sift.alert?("The decisions database couldn't be opened", problem, true) }
        webView.load(URLRequest(url: URL(string: SchemeHandler.origin + "/index.html")!))
        library.refresh()
    }

    private func wire() {
        webView.navigationDelegate = self
        webView.onFolderDrop = { [weak self] url in self?.open(url) }
        webView.onDragHover = { [weak self] on in self?.call("sifter.dragHover(\(on))") }
        window.onOpenFolder = { [weak self] in self?.chooseFolder() }
        window.onSettings = { [weak self] in self?.call("sifter.openSettings()") }
        window.onPage = { [weak self] i in self?.showPage(Page(rawValue: i) ?? .sift) }
        window.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }

        playback.store = store
        playback.attachClock(to: webView)
        bars.isHidden = true
        bars.heightScale = CGFloat(Self.vizHeight) / 100
        playback.setBarCount(Self.vizBars)
        playback.calm = Self.vizCalm
        webView.addSubview(bars)
        playback.librarySong = { [weak self] id in self?.library.song(id) }
        playback.onChange = { [weak self] in
            self?.queueNowPush()
            self?.queueSiftPush()
            self?.updateFrameMode()
        }
        // Frames go to one fixed bit of page code with the numbers as arguments:
        // new code text every frame had the page compiling (and keeping) it 60 times a second.
        playback.onFrame = { [weak self] kind, pos, dur, playing in
            guard let self, self.pageReady else { return }
            let args: [String: Any] = ["k": kind.rawValue, "p": pos, "d": dur, "pl": playing]
            self.webView.callAsyncJavaScript("sifter.frame(k, p, d, pl, null)", arguments: args, in: nil, in: .page, completionHandler: nil)
        }
        playback.onBars = { [weak self] levels in self?.bars.show(levels) }
        playback.onPlayCounted = { [weak self] id in self?.event("played", id) }

        sift.onChange = { [weak self] in self?.queueSiftPush() }
        sift.onLibraryChanged = { [weak self] in self?.library.refresh() }
        sift.onFlash = { [weak self] d in self?.call("sifter.flash('\(d.rawValue)')") }
        sift.onFolder = { [weak self] url in self?.window.subtitle = url.lastPathComponent }
        sift.onFolderClosed = { [weak self] in self?.window.subtitle = "" }
        sift.alert = { [weak self] title, text, critical in self?.alert(title, text, critical: critical) }

        library.onChange = { [weak self] in
            self?.event("library", self?.library.scanning ?? false)
            self?.lyrics.kick()
        }
        lyrics.onChange = { [weak self] in
            guard let self else { return }
            self.event("lyrics", self.lyrics.status())
        }
        lyrics.onSaved = { [weak self] id in self?.event("lyricsSaved", id) }
        backup.onChange = { [weak self] in
            guard let self else { return }
            self.event("backup", self.backup.status)
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.resting && self.windowVisible { self.wake() }     // coming back: start loading straight away
                self.updateFrameMode()
            }
        }
        for (name, object) in [(NSWindow.didMiniaturizeNotification, window as AnyObject), (NSWindow.didDeminiaturizeNotification, window),
                               (NSApplication.didHideNotification, NSApp), (NSApplication.didUnhideNotification, NSApp)] {
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.putAwayChanged() }
            }
        }
    }

    // MARK: - resting while put away

    // Put away for a while (minimized, or the app hidden), the page is let go:
    // its pictures of itself and its memory, 100 MB and more on a Retina
    // screen, which WebKit keeps otherwise. The music plays on (it's native);
    // the window shows its plain background, and when it comes back the page
    // loads again from the app's state, as at launch.

    private var putAway: Bool { window.isMiniaturized || NSApp.isHidden }

    private func putAwayChanged() {
        restTimer?.invalidate()
        restTimer = nil
        if !putAway { return wake() }
        guard !resting else { return }
        restTimer = Timer.scheduledTimer(withTimeInterval: Self.restAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rest() }
        }
    }

    private func rest() {
        guard putAway, !resting, pageReady else { return }
        resting = true
        pageReady = false
        updateFrameMode()
        window.contentView = restView
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        trace("page resting")
    }

    /// The page again: it loads behind the plain background and is shown once it's ready.
    private func wake() {
        guard resting else { return }
        resting = false
        trace("page waking")
        webView.load(URLRequest(url: URL(string: SchemeHandler.origin + "/index.html")!))
    }

    // MARK: - folders and pages

    func chooseFolder() {
        guard window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of music to sift"
        panel.prompt = "Sift"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    func open(_ url: URL) {
        guard pageReady else { pendingFolder = url; wake(); return }
        showPage(.sift)
        sift.open(url)
    }

    func showPage(_ p: Page, tellPage: Bool = true) {
        page = p
        window.selectPage(p.rawValue)
        if tellPage { call("sifter.showPage('\(p.name)')") }
        Prefs.store.set(p.name, forKey: "page")
        updateFrameMode()
    }

    /// How often the page hears about playback: every screen refresh while
    /// a visualizer or lyrics are on screen, 4 times a second for the mini
    /// player, never while the window's hidden.
    func updateFrameMode() {
        let visible = pageReady && windowVisible
        let libraryPlaying = playback.active == .library && playback.lib.isLoaded
        let mode: Playback.FrameMode
        switch page {
        case .sift: mode = !visible ? .off : playback.active == .sift ? (vizShown ? .full : .slow) : libraryPlaying ? .slow : .off
        case .now: mode = !visible ? .off : vizShown ? .full : nowShowsLyrics ? .lyrics : .slow
        default: mode = visible && playback.activePlayer.isLoaded ? .slow : .off
        }
        if playback.frameMode != mode { trace("frameMode \(mode) page=\(page.name) visible=\(windowVisible) ready=\(pageReady)") }
        playback.frameMode = mode
    }

    /// The page says where its visualizer spot is (in page points, from the
    /// top left) -- or that none is showing -- and the native bars go there.
    private func placeBars(_ body: [String: Any]) {
        let n = { (k: String) in (body[k] as? NSNumber)?.doubleValue }
        if let x = n("x"), let y = n("y"), let w = n("w"), let h = n("h"), w > 0, h > 0 {
            bars.frame = webView.isFlipped ? NSRect(x: x, y: y, width: w, height: h)
                                           : NSRect(x: x, y: webView.bounds.height - y - h, width: w, height: h)
            bars.reflection = body["reflection"] as? Bool ?? true
            if let colors = body["colors"] as? [String] { bars.setColors(colors) }
            bars.isHidden = false
            vizShown = true
        } else {
            bars.isHidden = true
            vizShown = false
        }
        updateFrameMode()
    }

    // MARK: - finishing a batch, and the library folder

    /// Finish batch: every kept song checked safe in the library, then the
    /// folder to the Trash -- after a clear yes, and an explicit one for any
    /// songs not sorted yet.
    func finishBatch() {
        guard window.attachedSheet == nil, let result = sift.batchSummary(libraryKeys: library.songKeys()) else { return }
        let summary: Batch.Summary
        switch result {
        case .failure(let refusal): return alert("This folder can't be finished", refusal.reason, critical: false)
        case .success(let s): summary = s
        }
        if !summary.problems.isEmpty {
            let list = summary.problems.prefix(8).joined(separator: "\n")
            return alert(summary.problems.count == 1 ? "A kept song isn't safe in your library yet" : "Some kept songs aren't safe in your library yet",
                         "\(list)\n\nUndo and keep \(summary.problems.count == 1 ? "it" : "them") again, or put the copies back, then finish the batch.",
                         critical: true)
        }
        let a = NSAlert()
        a.messageText = "Finish “\(summary.name)”?"
        let size = ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file)
        var text = "\(summary.kept) kept (checked: safe in your library) · \(summary.passed) passed\n\n" +
            "The folder and everything in it (\(size)) goes to the Trash. You can take it back out from there."
        if !summary.unsorted.isEmpty {
            let names = summary.unsorted.prefix(4).joined(separator: ", ") + (summary.unsorted.count > 4 ? "…" : "")
            text += "\n\nNot sorted yet: \(names)"
        }
        a.informativeText = text
        let go = a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        var enabler: CheckboxEnabler?
        if !summary.unsorted.isEmpty {
            let n = summary.unsorted.count
            let box = NSButton(checkboxWithTitle: "Also throw away the \(n) song\(n == 1 ? "" : "s") I haven't sorted", target: nil, action: nil)
            enabler = CheckboxEnabler(button: go)
            box.target = enabler
            box.action = #selector(CheckboxEnabler.toggled(_:))
            a.accessoryView = box
            go.isEnabled = false
        }
        a.beginSheetModal(for: window) { [weak self] response in
            _ = enabler                                     // kept alive while the sheet is up
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.sift.finishBatch()
            } catch {
                self.alert("The batch couldn't go to the Trash", error.localizedDescription, critical: true)
            }
        }
    }

    /// Backup -> Restore: what comes back, then a clear yes.
    func confirmRestore(_ path: String) {
        let drive = URL(fileURLWithPath: path, isDirectory: true)
        guard window.attachedSheet == nil, let entries = Backup.restoreEntries(on: drive) else { return }
        let a = NSAlert()
        a.messageText = "Restore your library from “\(drive.lastPathComponent)”?"
        a.informativeText = "\(entries.count) song\(entries.count == 1 ? "" : "s") go back into your library folder under their original names, "
            + "with their plays, lyrics and sorting history. Songs already in your library are left as they are: nothing is replaced or deleted."
        a.addButton(withTitle: "Restore")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.backup.restore(path) }
        }
    }

    /// Settings -> Library -> Change: one folder is the library. Nothing is
    /// moved or copied; the app just lists (and keeps into) that folder instead.
    func chooseLibraryFolder() {
        guard window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = library.folder
        panel.message = "Choose the one folder that holds your music library"
        panel.prompt = "Use This Folder"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            if url.standardizedFileURL.path == home || url.path == "/" {
                return self.alert("Pick a folder of music", "Your whole home folder or a whole drive can't be the library.", critical: false)
            }
            if Paths.dataDir().standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") {
                return self.alert("Pick a folder of music", "That folder holds the app's own data.", critical: false)
            }
            Paths.libraryChoice = url
            Prefs.store.set(url.path, forKey: "libraryFolder")
            self.library.refresh()
            self.event("settings", self.settings())
        }
    }

    // MARK: - keys

    /// The single-key shortcuts, before the page sees them -- except while
    /// typing in a text box, and never with a sheet or ⌘ involved.
    func handleKey(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown, !typing, window.attachedSheet == nil else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        guard mods.isEmpty else { return false }
        switch e.keyCode {
        case 49: if !e.isARepeat { spaceBar() }; return true
        case 123: seekKey(-5); return true
        case 124: seekKey(5); return true
        case 125: setVolume(playback.volume - 5); return true
        case 126: setVolume(playback.volume + 5); return true
        default: break
        }
        guard canJudge, let c = e.charactersIgnoringModifiers?.lowercased(),
              let d = ["k": Decision.keep, "p": .pass, "s": .skip][c] else { return false }
        if !e.isARepeat { sift.judge(d) }
        return true
    }

    /// K / P / S apply on the Sifting page, or Now Playing while it's showing the song being sifted.
    var canJudge: Bool {
        sift.queue.current != nil && (page == .sift || (page == .now && playback.active == .sift))
    }

    func spaceBar() {
        page == .sift ? playback.toggle(.sift) : playback.toggle()
    }

    func seekKey(_ seconds: Double) {
        if page == .sift {
            playback.seek(to: playback.sift.currentTime + seconds, kind: .sift)
        } else {
            playback.seek(by: seconds)
        }
    }

    func setVolume(_ value: Int) {
        playback.volume = min(100, max(0, value))
        Prefs.store.set(playback.volume, forKey: "volume")
        call("sifter.setVolume(\(playback.volume))")
    }

    // MARK: - talking to the page

    private func call(_ js: String) {
        guard pageReady else { return }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Tells the page something happened: sifter.event(name, data).
    func event<T: Encodable>(_ name: String, _ payload: T) {
        call("sifter.event('\(name)',\(encode(payload)))")
    }

    private func queueSiftPush() {
        guard !siftPushQueued else { return }
        siftPushQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.siftPushQueued = false
            self.call("sifter.receive(\(self.encode(self.sift.state())))")
        }
    }

    private func queueNowPush() {
        guard !nowPushQueued else { return }
        nowPushQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nowPushQueued = false
            self.event("now", self.nowState())
        }
    }

    struct NowState: Encodable {
        var kind: String?
        var id: String?
        var title = "", artist = "", album = ""
        var art = ""
        var duration = 0.0, position = 0.0
        var playing = false
        var canPrev = false, canNext = false
        var error = false
        var lyrics: String?          // library songs: where their lyrics came from, if they have some
    }

    func nowState() -> NowState {
        guard let song = playback.activeSong else { return NowState() }
        let p = playback.activePlayer
        var s = NowState(kind: song.kind.rawValue, id: song.id, title: song.title, artist: song.artist ?? "",
                         album: song.album ?? "", duration: p.duration, position: p.currentTime, playing: p.isPlaying)
        if song.kind == .sift {
            s.art = "\(SchemeHandler.origin)/art/sift/\(song.id)"
            s.canPrev = sift.queue.index > 0
            s.canNext = sift.queue.index < sift.queue.count - 1
            s.error = sift.playError
        } else {
            s.art = "\(SchemeHandler.origin)/art/lib/\(song.id)"
            s.canPrev = true
            s.canNext = playback.libIndex < playback.libQueue.count - 1
            s.error = playback.libError
            s.lyrics = store?.lyrics(id: song.id)?.source
        }
        return s
    }

    /// Fire-and-forget messages from the page (web/core.js post()).
    func handle(_ type: String, _ body: [String: Any]) {
        let kind = (body["kind"] as? String).flatMap(Playback.Kind.init)
        switch type {
        case "ready":
            pageReady = true
            trace("page ready")
            sift.resend()
            call("sifter.setVolume(\(playback.volume))")
            event("settings", settings())
            event("lyrics", lyrics.status())
            showPage(page)
            queueSiftPush()
            queueNowPush()
            window.pageDidLoad()
            if window.contentView !== webView {        // back from resting
                window.contentView = webView
                window.makeFirstResponder(webView)
                trace("page back")
            }
            if let folder = pendingFolder {
                pendingFolder = nil
                open(folder)
            }
            if putAway { putAwayChanged() }             // woken while still put away (a folder dropped on the Dock)
        case "page": if let p = (body["name"] as? String).flatMap(Page.init(name:)) { showPage(p, tellPage: false) }
        case "typing": typing = body["on"] as? Bool ?? false
        case "open": chooseFolder()
        case "judge": if let d = (body["decision"] as? String).flatMap(Decision.init) { sift.judge(d) }
        case "siftPrev": sift.previous()
        case "siftNext": sift.next()
        case "jump": if let i = body["index"] as? Int { sift.jump(to: i) }
        case "undo": if let id = body["id"] as? Int { sift.undo(entry: id) }
        case "toggle": playback.toggle(kind)
        case "seek":
            if let f = body["fraction"] as? Double {
                let p = playback.player(kind ?? playback.active)
                playback.seek(to: f * p.duration, kind: kind)
            }
        case "seekTo": if let t = body["seconds"] as? Double { playback.seek(to: t, kind: kind) }
        case "skipBy":                                      // the back / forward 10 seconds buttons
            if let s = (body["seconds"] as? NSNumber)?.doubleValue {
                let p = playback.player(kind ?? playback.active)
                playback.seek(to: min(max(p.currentTime + s, 0), max(p.duration - 0.05, 0)), kind: kind)
            }
        case "volume": if let v = body["value"] as? Int { setVolume(v) }
        case "prev": playback.previous()
        case "next": playback.next()
        case "play":
            if let id = body["id"] as? String {
                playback.playLibrary(id, queue: body["queue"] as? [String] ?? [id], at: body["at"] as? Double ?? 0)
                if body["show"] as? Bool == true { showPage(.now) }
            }
        case "reveal": library.reveal(body["id"] as? String)
        case "lyricsAnswer":                                // the one-time question: yes (and which quality) or no
            let yes = body["yes"] as? Bool ?? false
            if let q = (body["quality"] as? String).flatMap(LyricsService.Quality.init) {
                Task { await lyrics.setQuality(q); lyrics.answer(yes) }   // the quality first, so the right model downloads
            } else {
                lyrics.answer(yes)
            }
        case "removeModel": Task { await lyrics.removeModel() }
        case "lyricsQuality":
            if let q = (body["quality"] as? String).flatMap(LyricsService.Quality.init) { Task { await lyrics.setQuality(q) } }
        case "redoLyrics": Task { await lyrics.redo() }
        case "backup": if let path = body["path"] as? String { backup.start(path) }
        case "restore": if let path = body["path"] as? String { confirmRestore(path) }
        case "saveSettings": saveSettings(body)
        case "finishBatch": finishBatch()
        case "chooseLibrary": chooseLibraryFolder()
        case "viz": placeBars(body)
        case "colors": if let colors = body["colors"] as? [String] { window.wordmark.setColors(colors) }
        case "lyricsView":
            nowShowsLyrics = body["on"] as? Bool ?? false
            updateFrameMode()
        default: break
        }
    }

    /// Questions from the page, answered with JSON (web/core.js api()).
    func api(_ name: String, _ args: [String: Any]) async -> String {
        let id = args["id"] as? String ?? ""
        switch name {
        case "library": return encode(library.payload())
        case "lyrics": return encode(await lyrics.lyrics(for: id))
        case "search": return encode(lyrics.search(args["q"] as? String ?? ""))
        case "editLyric":
            return encode(await lyrics.edit(id, line: args["line"] as? Int ?? -1, text: args["text"] as? String ?? ""))
        case "timing":
            lyrics.setTiming(id, seconds: args["seconds"] as? Double ?? 0)
            return "true"
        case "leaderboard": return encode(leaderboard())
        case "trends": return encode(trends())
        case "drives":
            return encode(DrivesPayload(drives: backup.drives(), librarySize: backup.librarySize(),
                                        songs: library.rows.count, status: backup.status))
        case "eject": return encode(["error": backup.eject(args["path"] as? String ?? "")])
        case "lyricsStatus": return encode(lyrics.status())
        case "settings": return encode(settings())
        default: return "null"
        }
    }

    struct DrivesPayload: Encodable {
        let drives: [BackupService.Drive]
        let librarySize: Int
        let songs: Int
        let status: BackupService.Status
    }

    // MARK: - Leaderboard and Trends

    struct LeaderRow: Encodable {
        let rank: Int
        let id: String, title: String, artist: String
        let plays: Int
        let duration: Double
        let lastPlayed: Double?
    }

    func leaderboard() -> [LeaderRow] {
        let stats = store?.playStats() ?? [:]
        let played = library.rows.filter { (stats[$0.id]?.plays ?? 0) > 0 }.sorted {
            let a = stats[$0.id]!, b = stats[$1.id]!
            return a.plays != b.plays ? a.plays > b.plays : (a.lastPlayed ?? 0) > (b.lastPlayed ?? 0)
        }
        return played.enumerated().map { i, r in
            LeaderRow(rank: i + 1, id: r.id, title: LibraryService.title(r), artist: r.artist ?? "",
                      plays: stats[r.id]!.plays, duration: r.duration, lastPlayed: stats[r.id]!.lastPlayed)
        }
    }

    func trends() -> Trends.Result {
        let stats = store?.playStats() ?? [:]
        let day = { (t: Double) in Day(Date(timeIntervalSince1970: t)) }
        let tracks = library.rows.map { r in
            Trends.Track(id: r.id, title: LibraryService.title(r), artist: r.artist ?? "", plays: stats[r.id]?.plays ?? 0,
                         skips: stats[r.id]?.skips ?? 0, duration: r.duration,
                         lastPlayed: stats[r.id]?.lastPlayed.map(day), added: day(r.added))
        }
        let today = Day(Date())
        let (snapshots, days) = Trends.playHistory(added: Dictionary(library.rows.map { ($0.id, day($0.added)) },
                                                                     uniquingKeysWith: { a, _ in a }),
                                                   plays: (store?.playLog() ?? []).map { ($0.0, day($0.1)) }, today: today)
        let albums = Dictionary(library.rows.map { ($0.id, $0.album ?? "") }, uniquingKeysWith: { a, _ in a })
        return Trends.all(tracks, albums: albums, snapshots: snapshots, today: today, daysRecorded: days)
    }

    // MARK: - settings

    struct SettingsPayload: Encodable {
        let look: String?
        let colors: [String]?
        let customLooks: [[String]]
        let lyrics: Bool?
        let libraryFolder: String
        let vizBars: Int
        let vizHeight: Int
        let vizCalm: Bool
        let letterFill: Bool
        let version: String
    }

    func settings() -> SettingsPayload {
        SettingsPayload(look: Prefs.store.string(forKey: "look"), colors: Prefs.store.stringArray(forKey: "colors"),
                        customLooks: Prefs.store.array(forKey: "customLooks") as? [[String]] ?? [],
                        lyrics: lyrics.choice, libraryFolder: library.folder.path,
                        vizBars: Self.vizBars, vizHeight: Self.vizHeight, vizCalm: Self.vizCalm, letterFill: Self.letterFill,
                        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
    }

    private func saveSettings(_ body: [String: Any]) {
        if let look = body["look"] as? String { Prefs.store.set(look, forKey: "look") }
        if let colors = body["colors"] as? [String], colors.count == 3 { Prefs.store.set(colors, forKey: "colors") }
        if let looks = body["customLooks"] as? [[String]] { Prefs.store.set(looks, forKey: "customLooks") }
        if let on = body["lyrics"] as? Bool { lyrics.answer(on) }
        if let n = (body["vizBars"] as? NSNumber)?.intValue {
            Prefs.store.set(min(max(n, 24), 128), forKey: "vizBars")
            playback.setBarCount(Self.vizBars)
        }
        if let h = (body["vizHeight"] as? NSNumber)?.intValue {
            Prefs.store.set(min(max(h, 40), 100), forKey: "vizHeight")
            bars.heightScale = CGFloat(Self.vizHeight) / 100
        }
        if let calm = body["vizCalm"] as? Bool {
            Prefs.store.set(calm, forKey: "vizCalm")
            playback.calm = calm
        }
        if let fill = body["letterFill"] as? Bool { Prefs.store.set(fill, forKey: "letterFill") }
    }

    /// The Aurora look, until the page says which one is picked.
    static let auroraColors = ["#5478ff", "#966eff", "#ff78be"]

    // the visualizer's settings (Settings -> Visualizer), within limits
    static var vizBars: Int { min(max(Prefs.store.object(forKey: "vizBars") as? Int ?? 96, 24), 128) }
    static var vizHeight: Int { min(max(Prefs.store.object(forKey: "vizHeight") as? Int ?? 85, 40), 100) }
    static var vizCalm: Bool { Prefs.store.object(forKey: "vizCalm") as? Bool ?? false }
    /// Settings -> Lyrics: words fill letter by letter as they're sung (off: each lights up whole).
    static var letterFill: Bool { Prefs.store.object(forKey: "letterFill") as? Bool ?? true }

    private func alert(_ title: String, _ text: String, critical: Bool) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = critical ? .critical : .informational
        a.beginSheetModal(for: window)
    }
}

// MARK: - web view housekeeping

extension AppController: WKNavigationDelegate {
    /// Only the app's own page (or the blank one it rests on), never anything else (a dropped file, a link).
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        decisionHandler(url?.scheme == SchemeHandler.scheme || url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    /// If the page's process ever dies, reload it and redraw.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        updateFrameMode()
        if !resting { webView.reload() }             // resting: it loads again on waking
    }
}

/// Carries the page's messages to the app: post() (no answer needed) and
/// api() (answered with JSON). Separate so the web view doesn't keep the app
/// alive in a loop.
final class ScriptBridge: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    weak var app: AppController?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        app?.handle(type, body)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let name = body["name"] as? String else {
            return replyHandler(nil, "bad request")
        }
        let args = body["args"] as? [String: Any] ?? [:]
        Task { @MainActor in
            let json = await self.app?.api(name, args) ?? "null"
            replyHandler(json, nil)
        }
    }
}

/// Enables a sheet's button while its checkbox is ticked.
final class CheckboxEnabler: NSObject {
    weak var button: NSButton?
    init(button: NSButton) { self.button = button }
    @MainActor @objc func toggled(_ sender: NSButton) { button?.isEnabled = sender.state == .on }
}
