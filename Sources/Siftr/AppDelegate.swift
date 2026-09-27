import AppKit
import SifterCore

@main
@MainActor
enum SiftrApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var app: AppController!
    private var selfTest: SelfTest?
    private var bench: Bench?
    private var lock: InstanceLock?                // one Siftr per data folder, while this one runs

    func applicationWillFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            // a throwaway set of preferences: a test run never changes the listener's own
            let suite = "com.musicsifter.lite.selftest"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            Prefs.store = UserDefaults(suiteName: suite) ?? .standard
            Prefs.store.set(0, forKey: "volume")
            Prefs.store.set("sift", forKey: "page")
        } else if let suite = ProcessInfo.processInfo.environment["SIFTER_PREFS"], !suite.isEmpty {
            // a separate set of preferences that's kept (scripts/demo-setup.sh): a clean profile
            Prefs.store = UserDefaults(suiteName: suite) ?? .standard
        }
        // Another Siftr already using this data folder: hand over to it (with any folder
        // this one was asked to open) and quit, so two never write the same database.
        switch InstanceLock.acquire(in: Paths.dataDir()) {
        case .acquired(let held): lock = held
        case .unavailable: break
        case .heldBy(let pid):
            Self.handOver(to: pid, folder: args.dropFirst().first(where: Self.isFolder).map { URL(fileURLWithPath: $0) })
            exit(0)
        }
        trace("launching")
        app = AppController(webRoot: Self.webRoot())
        trace("controller ready")
        NSApp.mainMenu = buildMenu()
        // test runs and other profiles leave the window's saved size and place alone (it's kept in the real preferences)
        if Prefs.store !== UserDefaults.standard { app.window.setFrameAutosaveName("") }
        if let i = args.firstIndex(of: "--self-test"), i + 2 < args.count, args.contains("--bench") {
            bench = Bench(app: app, folder: URL(fileURLWithPath: args[i + 1]), report: URL(fileURLWithPath: args[i + 2]))
        } else if let i = args.firstIndex(of: "--self-test"), i + 2 < args.count {
            selfTest = SelfTest(app: app, folder: URL(fileURLWithPath: args[i + 1]), report: URL(fileURLWithPath: args[i + 2]))
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        trace("finished launching")
        app.window.showSoon()
        // `Siftr /path/to/folder` from a terminal
        if selfTest == nil && bench == nil, let dir = CommandLine.arguments.dropFirst().first(where: Self.isFolder) {
            app.open(URL(fileURLWithPath: dir))
        }
        NSApp.activate()
        selfTest?.start()
        bench?.start()
    }

    /// A folder dropped on the Dock icon, or `open -a Siftr <folder>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let folder = urls.first(where: { Self.isFolder($0.path) }) { app.open(folder) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ application: NSApplication) -> Bool { true }

    private static func handOver(to pid: pid_t?, folder: URL?) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.musicsifter.lite")
        guard let other = pid.flatMap(NSRunningApplication.init(processIdentifier:))
                ?? others.first(where: { $0.processIdentifier != getpid() }) else { return }
        if let folder, let app = other.bundleURL {
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 3)
        } else {
            other.activate()
        }
    }

    private static func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// web/ inside the app, or next to the sources when run with `swift run`.
    private static func webRoot() -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        #if DEBUG
        // debug builds only: #filePath writes this Mac's folder names into the program
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/web")
        #else
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/web")
        #endif
    }

    // MARK: - menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Siftr", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        item(appMenu, "Settings…", #selector(openSettings), ",", [.command])
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Siftr", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Siftr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: "Siftr", to: main)

        let file = NSMenu(title: "File")
        item(file, "Open Folder to Sift…", #selector(openFolder), "o", [.command])
        item(file, "Finish Batch…", #selector(finishBatch), "")
        item(file, "Show Library in Finder", #selector(revealLibrary), "")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, titled: "File", to: main)

        let edit = NSMenu(title: "Edit")
        item(edit, "Undo Last Decision", #selector(undoLast), "z", [.command])
        edit.addItem(.separator())
        // the standard text commands, for the search box and lyric editing
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        let view = NSMenu(title: "View")
        for (i, title) in MainWindow.pageTitles.enumerated() {
            let it = item(view, title, #selector(showPage(_:)), "\(i + 1)", [.command])
            it.tag = i
        }
        add(view, titled: "View", to: main)

        // Single keys, like the original. The window hands them over first,
        // so they work whatever has focus (except a text box being typed in).
        let controls = NSMenu(title: "Controls")
        item(controls, "Keep", #selector(keep), "k")
        item(controls, "Pass", #selector(pass), "p")
        item(controls, "Skip", #selector(skip), "s")
        controls.addItem(.separator())
        item(controls, "Play", #selector(togglePlay), " ")
        item(controls, "Previous Song", #selector(previous), Self.key(NSLeftArrowFunctionKey), [.command])
        item(controls, "Next Song", #selector(next), Self.key(NSRightArrowFunctionKey), [.command])
        controls.addItem(.separator())
        item(controls, "Back 5 Seconds", #selector(back), Self.key(NSLeftArrowFunctionKey))
        item(controls, "Forward 5 Seconds", #selector(forward), Self.key(NSRightArrowFunctionKey))
        item(controls, "Volume Up", #selector(volumeUp), Self.key(NSUpArrowFunctionKey))
        item(controls, "Volume Down", #selector(volumeDown), Self.key(NSDownArrowFunctionKey))
        add(controls, titled: "Controls", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window
        return main
    }

    private func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }

    @discardableResult
    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        return item
    }

    private static func key(_ code: Int) -> String { String(Character(UnicodeScalar(UInt16(code))!)) }

    /// Holding K down must not judge a whole run of songs.
    private var isKeyRepeat: Bool {
        guard let e = NSApp.currentEvent, e.type == .keyDown else { return false }
        return e.isARepeat
    }

    @objc func openSettings() { app.window.onSettings?() }
    @objc func openFolder() { app.chooseFolder() }
    @objc func finishBatch() { app.finishBatch() }
    @objc func revealLibrary() { app.library.reveal(nil) }
    @objc func undoLast() { app.sift.undoLast() }
    @objc func showPage(_ sender: NSMenuItem) { app.showPage(AppController.Page(rawValue: sender.tag) ?? .sift) }
    @objc func keep() { if !isKeyRepeat { app.sift.judge(.keep) } }
    @objc func pass() { if !isKeyRepeat { app.sift.judge(.pass) } }
    @objc func skip() { if !isKeyRepeat { app.sift.judge(.skip) } }
    @objc func togglePlay() { if !isKeyRepeat { app.spaceBar() } }
    @objc func previous() { app.page == .sift ? app.sift.previous() : app.playback.previous() }
    @objc func next() { app.page == .sift ? app.sift.next() : app.playback.next() }
    @objc func back() { app.seekKey(-5) }
    @objc func forward() { app.seekKey(5) }
    @objc func volumeUp() { app.setVolume(app.playback.volume + 5) }
    @objc func volumeDown() { app.setVolume(app.playback.volume - 5) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let a = app!
        // The single-key shortcuts stand down while a sheet or panel is in
        // front, or a text box is being typed in, so those keys type instead.
        let keysFree = !a.typing && a.window.attachedSheet == nil && (NSApp.keyWindow == nil || NSApp.keyWindow === a.window)
        let player = a.page == .sift ? a.playback.sift : a.playback.activePlayer
        switch item.action {
        case #selector(keep), #selector(pass), #selector(skip): return keysFree && a.canJudge && !a.sift.busy
        case #selector(togglePlay):
            item.title = player.isPlaying ? "Pause" : "Play"
            return keysFree && player.isLoaded
        case #selector(back), #selector(forward): return keysFree && player.isLoaded
        case #selector(volumeUp), #selector(volumeDown): return keysFree
        case #selector(undoLast): return !a.sift.session.isEmpty && !a.sift.busy
        case #selector(openFolder): return a.window.attachedSheet == nil
        case #selector(finishBatch): return a.window.attachedSheet == nil && a.sift.folder != nil && !a.sift.busy
        case #selector(showPage(_:)):
            item.state = a.page.rawValue == item.tag ? .on : .off
            return true
        default: return true
        }
    }
}

/// SIFTER_TRACE=1: prints how long startup steps take (ms since the process began).
@MainActor func trace(_ step: String) {
    guard ProcessInfo.processInfo.environment["SIFTER_TRACE"] != nil else { return }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
    let start = info.kp_proc.p_un.__p_starttime
    let ms = (Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1e6)) * 1000
    print(String(format: "trace %6.0f ms  %@", ms, step))
    fflush(stdout)
}
