import AppKit
import SifterCore
import WebKit

/// `Siftr --self-test <folder> <report.txt>`: drives the real app
/// with real key presses -- sifting the test folder, then every page --
/// and checks what happened on screen, on disk and in the database. Saves
/// screenshots of each page; exits 0 only if every check passed. Run by
/// scripts/self_test.sh with SIFTER_DATA / SIFTER_LIBRARY / SIFTER_TRASH
/// pointing at scratch folders (the library starts with three test songs);
/// it plays at volume 0 with its own throwaway preferences.
@MainActor
final class SelfTest {
    private let app: AppController
    private let folder: URL
    private let report: URL
    private var lines: [String] = []
    private var failures = 0
    private var patience: Double = 3
    private var sift: SiftController { app.sift }
    private var p: AudioPlayer { app.playback.sift }

    init(app: AppController, folder: URL, report: URL) {
        self.app = app
        self.folder = folder
        self.report = report
    }

    func start() {
        // on top and on whichever desktop Space is showing, so it can be seen
        app.window.level = .floating
        app.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        Task {
            await run()
            let text = lines.joined(separator: "\n") + "\n\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")\n"
            try? text.write(to: report, atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// SIFTER_BIG_BATCH=<folder>: does a big batch keep up? Opens it, passes 20 songs, and says how
    /// long each took to show the next one, and how many rows the page drew.
    private func bigBatch(_ folder: URL) async {
        app.open(folder)
        check(await waitFor(60, { self.sift.queue.count > 1000 && self.app.isReady }), "the big batch is queued (\(sift.queue.count) songs)")
        await wait(2)
        var times: [Double] = []
        for _ in 0..<20 {
            let before = await js("current") as? String
            let t0 = Date()
            sift.judge(.pass)
            _ = await waitFor(5, { (await self.js("current") as? String) != before })
            times.append(Date().timeIntervalSince(t0))
        }
        let sorted = times.sorted(), rows = await js("queueRows") as? Int ?? -1
        log(String(format: "big batch: %d songs; a Pass shows the next song in %.0f ms (median), %.0f ms at the slowest; %d rows drawn",
                   sift.queue.count, sorted[sorted.count / 2] * 1000, sorted.last! * 1000, rows))
    }

    private func run() async {
        if let big = ProcessInfo.processInfo.environment["SIFTER_BIG_BATCH"] { return await bigBatch(URL(fileURLWithPath: big)) }
        log(String(format: "app launched, %.0f ms after the process started", msSinceLaunch()))
        guard await waitFor(10, { self.app.isReady }) else { return check(false, "page loaded") }
        app.window.orderFrontRegardless()
        log(String(format: "page ready %.0f ms after the app started", msSinceLaunch()))
        await wait(0.4)
        let visible = app.windowVisible
        log("window visible: \(visible)\(visible ? "" : " (screen locked or window hidden: on-screen checks skipped)")")

        await libraryIndex()
        let audio = await sifting(visible: visible)
        await pages(audio: audio, visible: visible)
    }

    // MARK: - the library folder

    private func libraryIndex() async {
        check(await waitFor(15, { self.app.library.rows.count == 3 && !self.app.library.scanning }),
              "the library's 3 test songs were indexed (\(app.library.rows.count))")
        let titles = Set(app.library.rows.map { LibraryService.title($0) })
        check(titles == ["Song L", "Song M", "Song N"], "library titles from tags: \(titles.sorted())")
        let albums = app.library.payload().albums
        check(albums.first?.name == "Album L" && albums.first?.ids.count == 2, "Album L groups its two songs")
        check(albums.contains { $0.name == "Singles" }, "a one-song album goes under Singles")
    }

    // MARK: - sifting (the original app's whole flow)

    private func sifting(visible: Bool) async -> Bool {
        let spectrum = Spectrum()
        for name in ["01 Song A.mp3", "02 Song B.m4a", "03 Song C.flac", "04 Song D.ogg", "06 Song E.wav"] {
            let url = folder.appendingPathComponent(name)
            let samples = await Task.detached { AudioDecoder.decodeForVisualizer(url) }.value ?? []
            let seconds = Double(samples.count) / Spectrum.rate
            let peak = spectrum.target(samples: samples, at: 5, playing: true).max() ?? 0
            check(abs(seconds - 30) < 0.5 && peak > 0.2, String(format: "%@ decodes for the visualizer (%.1f s, loudest bar %.2f)", name, seconds, peak))
        }

        app.open(folder)
        check(await waitFor(5, { await self.js("title") as? String == "Song A" }), "first song loaded, title from its tags")
        let audio = await waitFor(25, { self.p.isPlaying && self.p.currentTime > 0.4 })
        if audio {
            check(true, "first song plays on its own")
        } else {
            log("SKIP  no sound available on this Mac right now (a locked screen blocks audio for every app): playback checks skipped")
            patience = 20
        }
        var s = await state()
        check(s["sub"] as? String == "Test Artist  •  Album A", "artist • album: \(s["sub"] ?? "nil")")
        check(s["queueRows"] as? Int == 6, "6 songs queued; hidden folder, ._ file and notes.txt skipped (\(s["queueRows"] ?? "nil"))")
        check(s["current"] as? String == "Song A", "current song marked in Up next")
        check((s["status"] as? String)?.hasPrefix("6 tracks to sort") == true, "status: \(s["status"] ?? "")")
        check(await waitFor(3, { await self.js("artShown") as? Bool == true }), "embedded cover art shown")

        if audio && seen("the song's length") { check(await waitFor(3, { await self.js("dur") as? String == "0:30" }), "duration shown") }
        if audio && seen("the Sifting page's frame rate") {
            let fps = await frameRate { self.app.playback.barsDrawn }
            check(fps > 25 && fps < 36, String(format: "Sifting page: visualizer at %.0f fps (30, like the Windows app)", fps))
            check(app.bars.peak > 0.1, "visualizer moving")
            let pageRate = await frameRate { self.app.playback.framesSent }
            check(pageRate > 2.5 && pageRate < 6, String(format: "the page itself: %.1f updates a second (the bars are drawn natively)", pageRate))
            // the native bars sit exactly on the page's spot for them
            let spot = await evaluate("JSON.stringify(document.getElementById('s-viz').getBoundingClientRect())")
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Double] } ?? [:]
            let f = app.bars.frame
            let y = app.webView.isFlipped ? f.minY : app.webView.bounds.height - f.maxY
            check(!app.bars.isHidden && abs(f.minX - (spot["left"] ?? -99)) < 1.5 && abs(y - (spot["top"] ?? -99)) < 1.5
                  && abs(f.width - (spot["width"] ?? -99)) < 1.5,
                  String(format: "the bars are drawn right on the visualizer's spot (%.0f,%.0f %.0f×%.0f)", f.minX, y, f.width, f.height))
            await run("sifter.openSettings()")
            check(await waitFor(2, { self.app.bars.isHidden }), "they step aside while Settings is open")
            await run("document.getElementById('viz-bars').value = 48; document.getElementById('viz-bars').dispatchEvent(new Event('input'));"
                      + "document.getElementById('viz-height').value = 60; document.getElementById('viz-height').dispatchEvent(new Event('input'))")
            check(await waitFor(2, { self.app.playback.barCount == 48 && abs(self.app.bars.heightScale - 0.6) < 0.001 }),
                  "Settings -> Visualizer: 48 bars at 60% height")
            await run("document.getElementById('viz-reset').click()")
            check(await waitFor(2, { self.app.playback.barCount == 96 && abs(self.app.bars.heightScale - 0.85) < 0.001 }), "and Reset puts back 96 at 85%")
            await run("document.getElementById('viz-calm').click()")
            check(await waitFor(2, { self.app.playback.calm && Prefs.store.object(forKey: "vizCalm") as? Bool == true }),
                  "Settings -> Visualizer -> Calm, remembered")
            await run("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))")
            check(await waitFor(2, { !self.app.bars.isHidden }), "and come back when it closes")
            let calmFps = await frameRate { self.app.playback.barsDrawn }
            check(calmFps > 11 && calmFps < 19, String(format: "calm: the bars at %.0f fps (15)", calmFps))
            await run("sifter.test.setting({ vizCalm: false })")
            check(await waitFor(2, { !self.app.playback.calm }), "and back to 30 when it's off")
        }
        await snapshot("1-sifting-dark.png")
        check(app.playback.volume == 0, "starts silent for the test")

        // volume keys
        key(arrow: NSUpArrowFunctionKey, 126); key(arrow: NSUpArrowFunctionKey, 126); key(arrow: NSDownArrowFunctionKey, 125)
        await wait(0.3)
        let slider = await js("volume") as? Int
        check(app.playback.volume == 5 && slider == 5, "Up, Up, Down -> volume 5 (\(app.playback.volume), slider \(slider ?? -1))")
        key(arrow: NSDownArrowFunctionKey, 125); key(arrow: NSDownArrowFunctionKey, 125)
        check(app.playback.volume == 0, "volume stops at 0")

        if audio {
            key(" ", 49)
            check(!p.isPlaying, "Space pauses (straight away)")
            key(" ", 49)
            check(p.isPlaying, "Space plays again")
            let before = p.currentTime
            key(arrow: NSRightArrowFunctionKey, 124)
            check(abs(p.currentTime - before - 5) < 0.3, String(format: "Right jumps 5 s (%.2f)", p.currentTime - before))
            key(arrow: NSLeftArrowFunctionKey, 123); key(arrow: NSLeftArrowFunctionKey, 123); key(arrow: NSLeftArrowFunctionKey, 123)
            check(p.currentTime < 0.3, "Left stops at 0:00")

            phase("playing")
            await wait(8)
            phase("paused-start")
            key(" ", 49)
            await wait(9)
            phase("paused-end")
            let f0 = app.playback.framesSent, b0 = app.playback.barsDrawn
            await wait(1)
            check(app.playback.framesSent == f0 && app.playback.barsDrawn == b0, "paused and settled: no frames at all")
            key(" ", 49)

            app.window.miniaturize(nil)
            let t1 = p.currentTime
            await wait(0.5)
            let f1 = app.playback.framesSent, b1 = app.playback.barsDrawn
            await wait(1.5)
            check(p.isPlaying && p.currentTime - t1 > 1.5, String(format: "keeps playing while minimized (+%.1f s)", p.currentTime - t1))
            check(app.playback.framesSent == f1 && app.playback.barsDrawn == b1, "no frames while minimized")
            app.window.deminiaturize(nil)
            app.window.orderFrontRegardless()
            await wait(0.8)

            let dur = p.duration
            let startT = p.currentTime
            await run("sifter.test.seek('s-seek', 'down', 0.1)")
            await run("sifter.test.seek('s-seek', 'move', 0.4)")
            await wait(0.3)
            check(abs(p.currentTime - startT) < 1.0, "no jump while dragging")
            let shown = parseTime(await js("pos") as? String)
            check(abs(shown - 0.4 * dur) <= 1.01, "the time follows the pointer while dragging (\(shown) s)")
            await run("sifter.test.seek('s-seek', 'up', 0.5)")
            await wait(0.2)
            check(abs(p.currentTime - 0.5 * dur) < 0.8, String(format: "jumps on release (%.1f of %.1f)", p.currentTime, dur))

            await run("sifter.test.seek('s-seek', 'down', 1.0)")
            await run("sifter.test.seek('s-seek', 'up', 1.0)")
            await wait(0.02)
            check(p.currentTime <= dur - 0.04 || !p.isPlaying, String(format: "seek clamps before the end (%.2f of %.2f)", p.currentTime, dur))
            check(await waitFor(3, { await self.js("title") as? String == "Song B" }), "song end -> next song plays")
            check(await waitFor(5, { self.p.isPlaying }), "and it's playing")
        } else {
            key(arrow: NSRightArrowFunctionKey, 124, [.command])
            check(await waitFor(3, { await self.js("title") as? String == "Song B" }), "⌘→ next song")
        }

        // keep: copies into the library (which then lists it), records, source untouched
        let source = folder.appendingPathComponent("02 Song B.m4a")
        let bytes = try? Data(contentsOf: source)
        key("k", 40)
        check(await waitFor(patience, { await self.js("title") as? String == "Song C" }), "Keep -> next song")
        let copy = Paths.libraryDir().appendingPathComponent("02 Song B.m4a")
        check(FileManager.default.fileExists(atPath: copy.path), "Keep copied into the library")
        check(bytes != nil && (try? Data(contentsOf: source)) == bytes, "source file unchanged")
        check((try? Data(contentsOf: copy)) == bytes, "copy is identical")
        let srcDate = try? FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        let copyDate = try? FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date
        check(srcDate != nil && srcDate == copyDate, "copy keeps the file's date")
        check(sift.store?.decision(for: songKey(for: source)) == "keep", "keep recorded")
        check(await waitFor(3, { (await self.js("lifetime") as? String)?.hasPrefix("All time: 1 kept · 0 passed") == true }), "lifetime totals")
        check(await waitFor(8, { self.app.library.rows.count == 4 }), "the kept song joins the library")
        if audio { check(await waitFor(5, { self.p.isPlaying }), "FLAC plays") }

        key("k", 40, repeat: true)
        await wait(0.4)
        check(sift.session.count == 1, "a repeated K is ignored")

        key("p", 35)
        check(await waitFor(patience, { await self.js("title") as? String == "Song D" }), "Pass -> next song")
        if audio { check(await waitFor(5, { self.p.isPlaying }), "OGG Vorbis plays") }
        key("s", 1)
        check(await waitFor(patience, { await self.js("title") as? String == "05 broken" }), "Skip -> next song")
        check(sift.queue.items.last?.lastPathComponent == "04 Song D.ogg", "Skip sent it to the back")

        _ = await waitFor(20, { await self.js("subError") as? Bool == true })
        s = await state()
        check(s["subError"] as? Bool == true && s["sub"] as? String == "Could not play this file", "broken file: 'Could not play this file'")
        check(s["keepDisabled"] as? Bool == false, "verdict buttons stay on for it")
        key("p", 35)
        check(await waitFor(patience, { await self.js("title") as? String == "Song E" }), "passed the broken file")
        if audio { check(await waitFor(5, { self.p.isPlaying }), "WAV plays") }
        await snapshot("2-sifting-sorting.png")

        key("z", 6, [.command])
        check(await waitFor(patience, { await self.js("title") as? String == "05 broken" }), "⌘Z puts the last song back as current")
        check(sift.session.count == 2, "and forgets it")
        await run("sifter.test.dblclick('session', 1)")        // newest first: [pass C, keep B]
        check(await waitFor(patience, { await self.js("title") as? String == "Song B" }), "undoing the keep brings Song B back")
        check(!FileManager.default.fileExists(atPath: copy.path), "its library copy is gone (to the Trash)")
        check(FileManager.default.fileExists(atPath: source.path), "the source is still there")
        check(sift.store?.decision(for: songKey(for: source)) == nil, "the keep is forgotten")
        check(await waitFor(8, { self.app.library.rows.count == 3 }), "and it leaves the library")
        if audio { check(await waitFor(5, { self.p.isPlaying }), "M4A plays") }

        await run("sifter.test.dblclick('queue', 0)")
        check(await waitFor(patience, { await self.js("title") as? String == "Song A" }), "double-click in Up next jumps")
        key(arrow: NSRightArrowFunctionKey, 124, [.command])
        check(await waitFor(patience, { await self.js("title") as? String == "Song B" }), "⌘→ next song")
        key(arrow: NSLeftArrowFunctionKey, 123, [.command])
        check(await waitFor(patience, { await self.js("title") as? String == "Song A" }), "⌘← previous song")
        if audio { check(await waitFor(5, { self.p.isPlaying }), "MP3 plays") }

        app.open(folder)
        check(await waitFor(5, { (await self.js("status") as? String)?.contains("1 skipped (already sorted)") == true }),
              "reopened: status says 1 skipped (already sorted)")
        check(await js("queueRows") as? Int == 5, "and the passed song is filtered out of the queue")

        key("k", 40)
        _ = await waitFor(patience, { self.sift.session.count == 2 })
        for _ in 0..<4 {
            let n = sift.queue.count
            key("p", 35)
            _ = await waitFor(patience, { self.sift.queue.count == n - 1 })
        }
        check(await waitFor(patience, { await self.js("title") as? String == "Batch complete" }), "empty queue -> Batch complete")
        s = await state()
        check(s["keepDisabled"] as? Bool == true && !p.isLoaded, "controls off, player closed")
        app.open(folder)
        check(await waitFor(5, { await self.js("title") as? String == "All sorted" }), "reopened after sorting all: All sorted")
        check(await waitFor(3, { (await self.js("lifetime") as? String)?.hasPrefix("All time: 1 kept · 5 passed") == true }), "final totals")
        check(await waitFor(8, { self.app.library.rows.count == 4 }), "the library now has the kept Song A too")

        // Finish batch: every kept song checked safe in the library, then the folder to the (scratch) Trash
        check(await js("finishDisabled") as? Bool == false, "Finish batch is on while a folder is open")
        if case .success(let sum)? = sift.batchSummary(libraryKeys: app.library.songKeys()) {
            check(sum.kept == 1 && sum.passed == 5 && sum.unsorted.isEmpty && sum.problems.isEmpty,
                  "Finish batch checks first: 1 kept (safe in the library), 5 passed, nothing unsorted")
        } else {
            check(false, "Finish batch summary")
        }
        do { try sift.finishBatch() } catch { check(false, "Finish batch: \(error.localizedDescription)") }
        check(!FileManager.default.fileExists(atPath: folder.path), "the batch folder went to the Trash")
        let trash = ProcessInfo.processInfo.environment["SIFTER_TRASH"].map { URL(fileURLWithPath: $0) }
        let binned = trash.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        check(binned.contains { $0.hasSuffix(" " + folder.lastPathComponent) }, "and it's in the Trash, songs and all")
        check(await waitFor(3, { await self.js("title") as? String == "Batch finished" }), "the page says Batch finished")
        check(await js("finishDisabled") as? Bool == true && app.window.subtitle.isEmpty, "and Finish batch is off again")
        check(app.library.rows.count == 4, "the library keeps its copy of Song A")
        return audio
    }

    // MARK: - the other pages

    private func pages(audio: Bool, visible: Bool) async {
        // Library
        app.showPage(.library)
        check(await waitFor(5, { await self.js("libraryRows") as? Int == 4 }), "Library lists all 4 songs")
        check(await js("page") as? String == "library", "the page switched")
        await snapshot("3-library-dark.png")

        // typing in the search box: letters type there, they don't judge or play
        await run("document.getElementById('lib-search').focus()")
        _ = await waitFor(2, { self.app.typing })
        check(app.typing, "the app knows a text box is being typed in")
        let decisions = sift.session.count
        let playing = app.playback.isPlaying
        key("p", 35)
        key(" ", 49)
        await wait(0.3)
        check(sift.session.count == decisions && app.playback.isPlaying == playing, "P and Space in the search box don't judge or play")
        let typed = await js("librarySearchText") as? String ?? ""
        check(typed.lowercased().hasPrefix("p"), "the letters went into the search box instead (\"\(typed)\")")
        await run("sifter.test.librarySearch(''); document.getElementById('lib-search').blur()")
        _ = await waitFor(2, { !self.app.typing })
        check(!app.typing, "and the shortcuts come back when it loses focus")

        await run("sifter.test.libraryMode('albums')")
        check(await waitFor(3, { await self.js("albumCards") as? Int == 2 }), "Albums shows 2 albums (Album L, and Singles)")
        await snapshot("4-albums-dark.png")
        await run("sifter.test.libraryMode('songs')")

        // one click anywhere on a row plays it, and the Library stays up (Now Playing is the mini player's button)
        let firstRow = await evaluate("document.querySelector('#lib-rows .song-row').dataset.id") ?? ""
        await run("document.querySelector('#lib-rows .song-row .num').click()")
        check(await waitFor(3, { self.app.playback.libSong?.id == firstRow && self.app.playback.active == .library }),
              "one click on a Library row plays that song")
        await wait(0.3)
        check(await js("page") as? String == "library", "and the Library stays up")
        check(await waitFor(2, { await self.js("mini") as? Bool == true }), "with the mini player there to go to Now Playing")

        // Now Playing: a library song with a synced .lrc beside it
        guard let lrcSong = app.library.rows.first(where: { LibraryService.title($0) == "Song L" }) else {
            return check(false, "Song L in the library")
        }
        let queue = app.library.rows.map(\.id)
        app.playback.playLibrary(lrcSong.id, queue: queue)
        app.showPage(.now)
        check(await waitFor(5, { await self.js("npTitle") as? String == "Song L" }), "Now Playing shows the library song")
        check(await waitFor(5, { await self.js("npSource") as? String == "lrc" }), "its synced .lrc lyrics were found")
        check((await js("npLines") as? Int ?? 0) >= 5, "the lyrics wheel has its lines")
        check(app.playback.active == .library, "the library player took over from sifting")
        if audio && seen("the lyrics lighting up") {
            check(await waitFor(8, { (await self.js("npActive") as? String)?.isEmpty == false }), "a line lights up as it's sung")
            check(await waitFor(5, { (await self.js("npSung") as? Int ?? 0) > 0 }), "and its words sweep on")
            // Settings -> Lyrics -> letter by letter off: each word lights up whole, nothing animating
            await run("sifter.openSettings(); document.getElementById('lyrics-fill').click();"
                      + "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))")
            check(await waitFor(4, { await self.js("letterFill") as? Bool == false && Prefs.store.object(forKey: "letterFill") as? Bool == false }),
                  "Settings -> Lyrics: letter by letter off, remembered")
            check(await waitFor(6, {
                      let lit = await self.js("npLit") as? Int ?? -1, sung = await self.js("npSung") as? Int ?? 0
                      return lit == 0 && sung > 0 }),
                  "sung words light up whole (no fill copies)")
            await run("sifter.test.setting({ letterFill: true })")
            check(await waitFor(6, { (await self.js("npLit") as? Int ?? 0) > 0 }), "and back on, they fill letter by letter again")
            // lyrics need only the position (4 a second); the page counts forward in between
            // the bars move to the corner under the controls (if the window leaves room for them)
            check(await waitFor(3, { (!self.app.bars.isHidden && self.app.bars.frame.width < 460) || self.app.playback.frameMode == .lyrics }),
                  "lyrics showing: the bars sit in the corner under the controls (or step aside in a short window)")
            let rate = await frameRate { self.app.playback.framesSent }
            check(rate > 2.5 && rate < 6, String(format: "Now Playing lyrics: %.1f page updates a second", rate))
            app.playback.seek(to: 2)
            await wait(0.5)
            await run("sifter.test.resetJank()")
            await wait(3)
            let frames = await js("npFrames") as? Int ?? 0, jank = await js("npJank") as? Double ?? 1, pace = await js("npFps") as? Int ?? 0
            if app.windowVisible {
                // Low Power Mode: macOS's web engine deliberately animates at 30 a second
                let low = ProcessInfo.processInfo.isLowPowerModeEnabled
                // the glides are the compositor's; the page's own frames (a 3 s probe) must stay even through them
                check(frames > 15 && jank < 0.05,
                      String(format: "the page keeps pace while the lyrics glide: %d frames at %d a second%@, %.1f%% dropped",
                             frames, pace, low ? " (Low Power Mode)" : "", jank * 100))
            }
            // away and back: the lyrics pick up where the song is instead of freezing
            app.showPage(.top)
            await wait(2.5)
            app.showPage(.now)
            check(await waitFor(3, { abs(await self.js("npAlign") as? Int ?? 999) < 30 }),
                  "back on Now Playing, the line being sung is in place again (\(await js("npAlign") ?? "nil") px off)")
            let line = await js("npActive") as? String ?? ""
            check(await waitFor(5, { (await self.js("npActive") as? String ?? line) != line }), "and the lyrics keep moving")
        }

        // the Edit menu: timing and fixing, in one place
        check(await js("npEdit") as? Bool == true, "one Edit button for the lyrics")
        await run("sifter.test.editMenu('open')")
        check(await waitFor(2, { await self.js("npMenu") as? Bool == true }), "Edit opens its menu")
        await run("sifter.test.editMenu('earlier')")
        check(await waitFor(3, { self.app.store?.timing(id: lrcSong.id) == 0.1 }), "Earlier saves the timing (0.1 s)")
        check(await js("npMenu") as? Bool == true, "and the menu stays open for another click")
        await run("sifter.test.editMenu('reset')")
        check(await waitFor(3, { self.app.store?.timing(id: lrcSong.id) == 0 }), "Reset timing puts it back")
        check(await js("npMenu") as? Bool == false, "and closes the menu")
        await run("sifter.test.editMenu('open'); sifter.test.editMenu('fix')")
        check(await waitFor(2, { await self.js("npEditing") as? Bool == true }), "Fix a line… turns on fixing")
        await run("sifter.test.editMenu('done')")
        check(await waitFor(2, { await self.js("npEditing") as? Bool == false }), "Done fixing turns it off")
        await wait(1.0)
        await snapshot("5-now-playing-dark.png")
        phase("now-playing")                        // the harness measures memory here
        await wait(5)

        // a play counts once the song reaches its end
        if audio {
            app.playback.seek(to: app.playback.lib.duration - 0.3)
            check(await waitFor(5, { (self.app.store?.playStats()[lrcSong.id]?.plays ?? 0) == 1 }), "a song that finishes counts as a play")
            check(await waitFor(5, { self.app.playback.libSong?.id != lrcSong.id && self.app.playback.lib.isPlaying }),
                  "then the next song in the list plays")
        } else {
            try? app.store?.recordPlay(id: lrcSong.id)
        }

        // the lyrics question, for a song without lyrics (answered "no thanks": nothing downloads)
        if let plain = app.library.rows.first(where: { LibraryService.title($0) == "Song N" }) {
            app.playback.playLibrary(plain.id, queue: [plain.id])
            check(await waitFor(5, { await self.js("npAsk") as? Bool == true }), "no lyrics yet: the one-time question shows, with the facts")
            await snapshot("6-lyrics-question-dark.png")
            await run("document.querySelector('#page-now .ask-card [data-answer=\"no\"]').click()")
            check(await waitFor(3, { self.app.lyrics.choice == false }), "'No thanks' is remembered")
            check(await waitFor(3, { await self.js("noLyrics") as? Bool == true }), "and lyrics are hidden everywhere")
            // Settings -> Lyrics -> Quality: remembered, and nothing downloads while lyrics are off
            await run("sifter.openSettings(); document.querySelector('#lyrics-settings [data-quality=\"best\"]').click()")
            check(await waitFor(3, { self.app.lyrics.quality == .best }), "Settings -> Lyrics -> Quality: Best, remembered")
            check(app.lyrics.phase == .off && !FileManager.default.fileExists(atPath: app.lyrics.modelsDir.appendingPathComponent("models").path),
                  "and nothing downloads while lyrics are off")
            await run("document.querySelector('#lyrics-settings [data-quality=\"standard\"]').click()")
            check(await waitFor(3, { self.app.lyrics.quality == .standard }), "and back to Standard")
            await run("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))")
            check(await waitFor(3, { await self.js("npBigViz") as? Bool == true }), "a big visualizer instead")
            if seen("the big visualizer's spot") {           // a hidden window draws nothing, so there's no spot to check
                check(await waitFor(3, { !self.app.bars.isHidden && self.app.bars.frame.width > 300 }), "drawn natively on its big spot")
            }
        }

        // the mini player, and its lighter update rate
        app.showPage(.library)
        check(await waitFor(3, { await self.js("mini") as? Bool == true }), "the mini player shows while browsing")
        if audio && seen("the mini player's update rate") {
            let f0 = app.playback.framesSent, t0 = ProcessInfo.processInfo.systemUptime
            await wait(2)
            let rate = Double(app.playback.framesSent - f0) / (ProcessInfo.processInfo.systemUptime - t0)
            check(app.playback.frameMode == .slow && rate < 6, String(format: "browsing: %.1f updates a second (not 60)", rate))
        }

        // Leaderboard and Trends
        app.showPage(.top)
        check(await waitFor(5, { (await self.js("leaderRows") as? Int ?? 0) >= 1 }), "Leaderboard lists the played song")
        await snapshot("7-leaderboard-dark.png")
        app.showPage(.trends)
        check(await waitFor(5, { await self.js("trendCards") as? Int == 7 }), "Trends shows its 7 cards")
        await snapshot("8-trends-dark.png")

        // Backup, to a scratch "drive"
        app.showPage(.backup)
        check(await waitFor(5, { (await self.js("drives") as? Int ?? -1) >= 0 }), "Backup lists drives")
        await snapshot("9-backup-dark.png")
        let drive = report.deletingLastPathComponent().appendingPathComponent("fake drive", isDirectory: true)
        try? FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        app.backup.start(drive.path)
        check(await waitFor(10, { !self.app.backup.status.running && (self.app.backup.status.result != nil || self.app.backup.status.error != nil) }),
              "a backup runs")
        check(app.backup.status.result?.copied == 4, "all 4 library songs copied (\(app.backup.status.result?.copied ?? -1))")
        let m3u = drive.appendingPathComponent("\(Backup.folderName)/\(Backup.playlistName).m3u8")
        check(FileManager.default.fileExists(atPath: m3u.path), "with a playlist file")
        app.backup.start(drive.path)
        _ = await waitFor(10, { !self.app.backup.status.running })
        check(app.backup.status.result?.copied == 0 && app.backup.status.result?.upToDate == 4, "a second backup copies nothing new")
        // Restore, as if this Mac had lost its library: into a new library and a new database. The songs
        // come back under their own names (so Siftr knows them again), and their history with them.
        let savedHistory = drive.appendingPathComponent("\(Backup.folderName)/\(Backup.databaseCopyName)")
        check(FileManager.default.fileExists(atPath: savedHistory.path), "the backup holds a copy of Siftr's history")
        let restoredLibrary = report.deletingLastPathComponent().appendingPathComponent("restored library", isDirectory: true)
        let restored = try? Backup.restore(from: drive, into: restoredLibrary) { _, _, _ in }
        check(restored?.copied == 4, "Restore puts all 4 songs back (\(restored?.copied ?? -1))")
        check(Set(FolderScanner.scan(restoredLibrary).map { LibraryService.id(for: $0) }) == Set(app.library.rows.map(\.id)),
              "under their own names: Siftr knows every one of them again")
        if let fresh = try? LibraryStore(url: report.deletingLastPathComponent().appendingPathComponent("restored.db")),
           let merged = try? fresh.merge(from: savedHistory) {
            check((fresh.playStats()[lrcSong.id]?.plays ?? 0) >= 1 && merged.lyrics >= 1,
                  "with their history: \(merged.plays) plays, lyrics for \(merged.lyrics) songs")
        } else {
            check(false, "the backup's copy of the history opens")
        }

        // Settings: a look changes every color
        await run("sifter.openSettings()")
        check(await waitFor(2, { await self.js("settingsOpen") as? Bool == true }), "Settings opens")
        await wait(0.4)                             // past its fade-in, for the picture
        await snapshot("10-settings-dark.png")
        await run("[...document.querySelectorAll('#looks .look')].find(b => b.textContent.includes('Sunset')).click()")
        check(await waitFor(2, { (await self.js("colors") as? [String])?.first == "#7a00ff" }), "picking the Sunset look recolors the app")
        check(await waitFor(2, { Prefs.store.string(forKey: "look") == "Sunset" }), "and it's remembered")
        await run("document.querySelector('#settings [data-close]').click()")

        // light mode
        NSApp.appearance = NSAppearance(named: .aqua)
        app.showPage(.now)
        await wait(0.6)
        await snapshot("11-now-playing-light.png")
        app.showPage(.library)
        await wait(0.5)
        await snapshot("12-library-light.png")
        NSApp.appearance = nil

        // hidden: nothing at all
        app.window.miniaturize(nil)
        await wait(0.6)
        let f2 = app.playback.framesSent
        await wait(1.5)
        check(app.playback.framesSent == f2, "minimized: no updates at all")
        app.window.deminiaturize(nil)

        // put away for a while (SIFTER_REST_AFTER, 10 minutes for real): the page is let go, and comes back with the window
        if ProcessInfo.processInfo.environment["SIFTER_REST_AFTER"] != nil {
            _ = await waitFor(3, { self.app.windowVisible })
            let pageBefore = await js("page") as? String
            let wasPlaying = app.playback.isPlaying
            app.window.miniaturize(nil)
            check(await waitFor(20, { self.app.resting }), "minimized a while: the page is let go")
            check(app.window.contentView !== app.webView && !app.isReady, "the window holds its plain background meanwhile")
            await wait(1)
            check(app.playback.isPlaying == wasPlaying, "and the music carries on without it")
            let t0 = Date()
            app.window.deminiaturize(nil)
            check(await waitFor(10, { self.app.isReady && self.app.window.contentView === self.app.webView }),
                  String(format: "back with the window (the page ready in %.1f s)", Date().timeIntervalSince(t0)))
            check(await waitFor(5, { await self.js("page") as? String == pageBefore }), "on the same page as before (\(pageBefore ?? "?"))")
            check(app.playback.isPlaying == wasPlaying, "still playing")
        }

        if let spoken = ProcessInfo.processInfo.environment["SIFTER_SPOKEN"] { await whisper(URL(fileURLWithPath: spoken)) }
    }

    /// SIFTER_SPOKEN=<a spoken clip> (scripts/self_test.sh --whisper): lyrics
    /// switched on for real -- the model downloaded into the scratch data
    /// folder, a song transcribed, its timed words on Now Playing.
    private func whisper(_ clip: URL) async {
        log("Lyrics with Whisper (\(app.lyrics.model))…")
        let dest = Paths.libraryDir().appendingPathComponent("Spoken Word.m4a")
        try? FileManager.default.copyItem(at: clip, to: dest)
        app.library.refresh()
        let id = LibraryService.id(for: dest)
        check(await waitFor(15, { self.app.library.row(id) != nil }), "the spoken song joins the library")
        app.lyrics.answer(true)
        check(await waitFor(600, { self.app.store?.lyrics(id: id)?.source == "whisper" || self.app.lyrics.phase == .error }),
              "Whisper wrote its lyrics (\(app.lyrics.message ?? "no errors"))")
        let lines = LyricsFormat.decode(app.store?.lyrics(id: id)?.segments ?? "[]")
        let text = lines.map(\.text).joined(separator: " ").lowercased()
        log("  heard: \(text)")
        check(text.contains("city") && text.contains("tonight"), "the words are right")
        let words = lines.flatMap(\.words)
        check(!words.isEmpty && zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start }, "every word has its time, in order (\(words.count) words)")
        check(await waitFor(30, { self.app.lyrics.phase == .idle }), "the model is put away once there's nothing left to do")
        app.playback.playLibrary(id, queue: [id])
        app.showPage(.now)
        check(await waitFor(5, { await self.js("npSource") as? String == "whisper" }), "Now Playing shows the Whisper lyrics")
        await snapshot("13-whisper-lyrics.png")
    }

    // MARK: - helpers

    private func log(_ s: String) {
        lines.append(s)
        print(s)
        fflush(stdout)
    }

    private func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        log((ok ? "PASS  " : "FAIL  ") + what)
    }

    private func phase(_ name: String) {
        log(String(format: "PHASE %@ %.3f", name, Date().timeIntervalSince1970))
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitFor(_ timeout: Double, _ condition: () async -> Bool) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < end {
            if await condition() { return true }
            await wait(0.1)
        }
        return await condition()
    }

    /// Frames a second over 1.5 s -- or 60 if the window got covered partway
    /// (then drawing rightly stopped, and there's nothing to measure).
    private func frameRate(_ count: () -> Int) async -> Double {
        let start = count()
        _ = await waitFor(2, { count() > start + 3 })
        let f0 = count(), t0 = ProcessInfo.processInfo.systemUptime
        await wait(1.5)
        let fps = Double(count() - f0) / (ProcessInfo.processInfo.systemUptime - t0)
        if !app.windowVisible {
            log(String(format: "SKIP  frame rate (%.0f fps measured): the window was covered partway through", fps))
            return 60
        }
        return fps
    }

    private func run(_ code: String) async {
        _ = await evaluate(code)
    }

    /// Runs page code, giving up after a few seconds: macOS can pause a page
    /// completely (screen locked), and then the test would wait forever.
    private func evaluate(_ code: String, timeout: Double = 5) async -> String? {
        let answered = Once()
        let value: String? = await withCheckedContinuation { c in
            app.webView.evaluateJavaScript(code) { value, _ in
                guard !answered.done else { return }
                answered.done = true
                c.resume(returning: value as? String)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !answered.done else { return }
                answered.done = true
                c.resume(returning: nil)
            }
        }
        return value
    }

    private func state() async -> [String: Any] {
        guard let text = await evaluate("sifter.debugState()"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
        return obj
    }

    private func js(_ field: String) async -> Any? { await state()[field] }

    private func parseTime(_ text: String?) -> Double {
        let parts = (text ?? "").split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
    }

    /// A key press, the way the keyboard delivers it: plain keys to the
    /// window (whether or not another app is in front just now), ⌘ keys
    /// through the app, which hands them to the menu.
    private func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: app.window.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: isRepeat, keyCode: code) else { continue }
            if mods.contains(.command) { NSApp.sendEvent(e) } else { app.window.sendEvent(e) }
        }
    }

    /// On-screen measurements only mean something while the window can be seen.
    private func seen(_ what: String) -> Bool {
        if app.windowVisible { return true }
        log("SKIP  \(what): the window isn't visible right now (another app or desktop in front)")
        return false
    }

    private func key(arrow: Int, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        key(String(Character(UnicodeScalar(UInt16(arrow))!)), code, mods.union([.numericPad, .function]))
    }

    /// Milliseconds since this process started.
    private func msSinceLaunch() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_un.__p_starttime
        return (Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1e6)) * 1000
    }

    /// The whole window as a PNG: the native toolbar plus the page.
    private func snapshot(_ name: String) async {
        // SIFTER_NO_SNAPSHOTS=1: skip them, for clean memory measurements
        if ProcessInfo.processInfo.environment["SIFTER_NO_SNAPSHOTS"] != nil { return }
        guard let page = try? await app.webView.takeSnapshot(configuration: nil),
              let frameView = app.window.contentView?.superview else { return log("snapshot failed") }
        let bounds = frameView.bounds
        guard let chrome = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: chrome)
        let pageRect = app.webView.convert(app.webView.bounds, to: frameView)
        let image = NSImage(size: bounds.size, flipped: frameView.isFlipped) { rect in
            chrome.draw(in: rect)
            page.draw(in: pageRect)
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: report.deletingLastPathComponent().appendingPathComponent(name))
        log("saved \(name)")
    }
}

@MainActor private final class Once { var done = false }
