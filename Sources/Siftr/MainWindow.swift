import AppKit
import WebKit

/// The window: a native toolbar (the Siftr wordmark, the page switcher, Open
/// Folder, Settings) over the web view that draws each page. The toolbar blends
/// into the page's background, so it reads as one surface.
@MainActor
final class MainWindow: NSWindow, NSToolbarDelegate {
    var onOpenFolder: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPage: ((Int) -> Void)?
    /// Sees every key press before the page does; true = handled.
    var keyHandler: ((NSEvent) -> Bool)?
    private var shown = false

    static let pageTitles = ["Sifting", "Library", "Now Playing", "Leaderboard", "Trends", "Backup"]
    private let pages = NSSegmentedControl(labels: MainWindow.pageTitles, trackingMode: .selectOne, target: nil, action: nil)
    let wordmark: Wordmark

    private nonisolated static let wordmarkID = NSToolbarItem.Identifier("wordmark")

    private nonisolated static let pagesID = NSToolbarItem.Identifier("pages")
    private nonisolated static let openID = NSToolbarItem.Identifier("open")
    private nonisolated static let settingsID = NSToolbarItem.Identifier("settings")

    /// The page's top color, light and dark.
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x12 / 255, green: 0x13 / 255, blue: 0x1c / 255, alpha: 1)
            : NSColor(srgbRed: 0xF4 / 255, green: 0xF5 / 255, blue: 0xF9 / 255, alpha: 1)
    }

    init(content: NSView, colors: [String]) {
        wordmark = Wordmark(colors: colors)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = Wordmark.name                   // for the Window menu, Mission Control and VoiceOver
        titleVisibility = .hidden               // the wordmark shows it
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        backgroundColor = Self.background
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: 900, height: 568)
        tabbingMode = .disallowed

        pages.target = self
        pages.action = #selector(pagePicked)
        pages.selectedSegment = 0
        pages.segmentDistribution = .fit
        for i in 0..<Self.pageTitles.count {
            pages.setToolTip("\(Self.pageTitles[i]) (⌘\(i + 1))", forSegment: i)
        }

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.pagesID]
        self.toolbar = toolbar
        toolbarStyle = .unified

        contentView = content
        center()
        setFrameAutosaveName("MusicSifterMain")   // remembers size and place (the name from before Siftr, so it still does)
    }

    func selectPage(_ index: Int) {
        pages.selectedSegment = index
    }

    /// Shown once the page has drawn, so there's no white flash at launch.
    func pageDidLoad() {
        guard !shown else { return }
        shown = true
        makeKeyAndOrderFront(nil)
    }

    func showSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.pageDidLoad() }
    }

    // Keys reach the window before the web view (which would otherwise keep
    // Space and letters for itself), whichever route AppKit sends them by.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    @objc private func pagePicked() { onPage?(pages.selectedSegment) }
    @objc private func openFolderPressed() { onOpenFolder?() }
    @objc private func settingsPressed() { onSettings?() }

    // MARK: - toolbar

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.wordmarkID, .flexibleSpace, Self.pagesID, .flexibleSpace, Self.openID, Self.settingsID]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    nonisolated func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            let item = NSToolbarItem(itemIdentifier: id)
            switch id {
            case Self.wordmarkID:
                item.view = wordmark
                item.label = Wordmark.name
            case Self.pagesID:
                item.view = pages
                item.label = "Pages"
            case Self.openID:
                let button = NSButton(title: "Open Folder",
                                      image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!,
                                      target: self, action: #selector(openFolderPressed))
                button.imagePosition = .imageLeading
                button.bezelStyle = .toolbar
                button.toolTip = "Choose a folder of music to sift (⌘O) — or drop one on the window"
                item.view = button
                item.label = "Open Folder"
            case Self.settingsID:
                let button = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
                                      target: self, action: #selector(settingsPressed))
                button.bezelStyle = .toolbar
                button.toolTip = "Settings (⌘,)"
                item.view = button
                item.label = "Settings"
            default:
                return nil
            }
            return item
        }
    }
}

/// The web view, plus folder drag-and-drop handled natively (so a dropped
/// folder is opened rather than the page navigating to it).
final class SifterWebView: WKWebView {
    var onFolderDrop: ((URL) -> Void)?
    var onDragHover: ((Bool) -> Void)?

    private func folder(in info: any NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = folder(in: sender) != nil
        onDragHover?(ok)
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        folder(in: sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragHover?(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        folder(in: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDragHover?(false)
        guard let url = folder(in: sender) else { return false }
        onFolderDrop?(url)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {}

    // the page draws its own right-click behavior (none)
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }
}
