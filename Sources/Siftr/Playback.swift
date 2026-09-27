import AppKit
import MediaPlayer
import SifterCore

/// The two players -- the song being sifted, and a song from the library --
/// with one playing at a time; the visualizer; Control Center and the media
/// keys; and play / skip counting for the Leaderboard and Trends.
@MainActor
final class Playback {
    enum Kind: String, Codable, Sendable { case sift, library }

    /// How often the page needs to hear about playback: every screen refresh
    /// (a visualizer or lyrics are showing), 4 times a second (just the mini
    /// player's progress), or not at all (hidden).
    enum FrameMode { case off, slow, lyrics, full }

    struct Song {
        let kind: Kind
        let id: String
        let url: URL
        var title: String
        var artist: String?
        var album: String?
    }

    let sift = AudioPlayer()
    let lib = AudioPlayer()
    private(set) var active: Kind = .sift
    private(set) var siftSong: Song?
    private(set) var libSong: Song?
    private(set) var libQueue: [String] = []
    private(set) var libIndex = 0
    private(set) var libError = false
    private var siftGen = 0
    private var libGen = 0

    var volume = 70 {
        didSet { sift.volume = volume; lib.volume = volume }
    }

    // wiring (set by the app)
    var store: LibraryStore?
    var librarySong: (String) -> Song? = { _ in nil }
    var onSiftFinished: (() -> Void)?
    var onSiftNext: (() -> Void)?
    var onSiftPrevious: (() -> Void)?
    var onChange: (() -> Void)?                     // what's playing, or whether, changed
    var onPlayCounted: ((String) -> Void)?
    var onFrame: ((Kind, Double, Double, Bool) -> Void)?   // the page: where the song is (4 a second at most)
    var onBars: (([Float]) -> Void)?                        // the native bars: every frame while they show

    // the visualizer
    // more bars than viz.py's 56 (Settings -> Visualizer), and livelier: quiet parts reach higher (-60 dB up)
    private var spectrum = Spectrum(bars: 96, floorDB: 60, rangeDB: 34)
    var barCount: Int { spectrum.count }

    func setBarCount(_ n: Int) {
        guard n != spectrum.count else { return }
        spectrum = Spectrum(bars: n, floorDB: 60, rangeDB: 34)
        onBars?(spectrum.level)
    }
    private var pcm: [Int16] = []                   // the playing song, decoded for the bars
    private var pcmFor: URL?
    private var pcmTask: Task<Void, Never>?
    private var clock: FrameClock?
    private var slowTimer: Timer?
    private var slowInterval: Double?
    private(set) var framesSent = 0
    private(set) var barsDrawn = 0
    private var lastPageFrame: CFTimeInterval = 0
    var frameMode: FrameMode = .off {
        didSet { if frameMode != oldValue { updateClock(); decodeIfNeeded() } }
    }

    /// Control Center and the media keys (off for the self-test, so a test
    /// run neither takes over the listener's own play/pause key nor gets
    /// paused by it).
    private let remoteControls: Bool

    init(remoteControls: Bool = true) {
        self.remoteControls = remoteControls
        sift.onFinish = { [weak self] in
            trace("sifting song finished")
            self?.changed()
            self?.onSiftFinished?()
        }
        lib.onFinish = { [weak self] in self?.libraryFinished() }
        if remoteControls { setUpRemoteCommands() }
    }

    func attachClock(to view: NSView) {
        clock = FrameClock(view: view) { [weak self] dt in self?.tick(dt) }
        clock?.fps = calm ? 15 : 30
    }

    /// Settings -> Visualizer -> Calm: the bars at 15 frames a second, not 30.
    /// About half the work for macOS's window compositor, which redraws the
    /// window for every frame (the bars move by the time between frames, so
    /// they keep their speed).
    var calm = false { didSet { clock?.fps = calm ? 15 : 30 } }

    func player(_ kind: Kind) -> AudioPlayer { kind == .sift ? sift : lib }
    var activePlayer: AudioPlayer { player(active) }
    var activeSong: Song? { active == .sift ? siftSong : libSong }
    var isPlaying: Bool { activePlayer.isPlaying }

    // MARK: - the song being sifted

    /// Loads (and starts) the song being sifted, or clears it with nil.
    func loadSift(_ song: Song?, failed: @escaping () -> Void) {
        trace("load sifting song: \(song?.title ?? "none")")
        siftGen += 1
        let g = siftGen
        sift.close()
        siftSong = song
        guard let song else { return changed() }
        makeActive(.sift)
        changed()
        Task {
            do {
                let prepared = try await AudioPlayer.prepare(song.url)
                guard g == self.siftGen else { return }      // moved on meanwhile
                self.sift.install(prepared)
                if self.active == .sift { self.sift.play() }
            } catch {
                guard g == self.siftGen else { return }
                failed()
            }
            self.changed()
        }
    }

    func updateSiftTags(title: String, artist: String?, album: String?) {
        siftSong?.title = title
        siftSong?.artist = artist
        siftSong?.album = album
        publishNowPlaying()
    }

    // MARK: - library songs

    /// Plays a library song; `queue` is the list it was picked from (the
    /// next one plays when it ends).
    func playLibrary(_ id: String, queue: [String], at start: Double = 0) {
        countSkipIfLeftEarly()
        libQueue = queue.contains(id) ? queue : [id]
        libIndex = libQueue.firstIndex(of: id) ?? 0
        startLibrarySong(at: start)
    }

    private func startLibrarySong(at start: Double = 0) {
        libGen += 1
        let g = libGen
        lib.close()
        libError = false
        guard libQueue.indices.contains(libIndex), let song = librarySong(libQueue[libIndex]) else {
            libSong = nil
            return changed()
        }
        libSong = song
        makeActive(.library)
        changed()
        Task {
            do {
                let prepared = try await AudioPlayer.prepare(song.url)
                guard g == self.libGen else { return }
                self.lib.install(prepared)
                if start > 0 { self.lib.seek(to: start) }
                if self.active == .library { self.lib.play() }
            } catch {
                guard g == self.libGen else { return }
                self.libError = true
            }
            self.changed()
        }
    }

    func libNext() {
        guard libIndex < libQueue.count - 1 else { return }
        countSkipIfLeftEarly()
        libIndex += 1
        startLibrarySong()
    }

    /// Back to the start of the song, or (in its first 3 seconds) the one before.
    func libPrevious() {
        if lib.currentTime > 3 || libIndex == 0 {
            lib.seek(to: 0)
            sendFrame()
            publishNowPlaying()
        } else {
            libIndex -= 1
            startLibrarySong()
        }
    }

    private func libraryFinished() {
        if let id = libSong?.id {
            try? store?.recordPlay(id: id)                   // a play counts once the song finishes
            onPlayCounted?(id)
        }
        if libIndex < libQueue.count - 1 {
            libIndex += 1
            startLibrarySong()
        } else {
            changed()
        }
    }

    /// A skip: leaving a library song for another between 2 seconds in and halfway.
    private func countSkipIfLeftEarly() {
        guard let id = libSong?.id, lib.isLoaded else { return }
        let t = lib.currentTime, d = lib.duration
        if t >= 2 && d > 0 && t < d / 2 { try? store?.recordSkip(id: id) }
    }

    func stopLibrary() {
        libGen += 1
        lib.close()
        libSong = nil
        libQueue = []
        if active == .library { active = .sift }
        changed()
    }

    // MARK: - controls (for whichever is playing, unless told which)

    func toggle(_ kind: Kind? = nil) {
        let k = kind ?? active
        let p = player(k)
        guard p.isLoaded else { return }
        if p.isPlaying {
            p.pause()
        } else {
            makeActive(k)
            p.play()
        }
        changed()
    }

    func seek(by seconds: Double) { seek(to: activePlayer.currentTime + seconds) }

    func seek(to seconds: Double, kind: Kind? = nil) {
        let p = player(kind ?? active)
        guard p.isLoaded else { return }
        p.seek(to: seconds)
        sendFrame()
        publishNowPlaying()
        updateClock()
    }

    func next() { active == .sift ? onSiftNext?() : libNext() }
    func previous() { active == .sift ? onSiftPrevious?() : libPrevious() }

    /// Only one plays at a time: starting one pauses the other.
    private func makeActive(_ kind: Kind) {
        if active != kind { player(active).pause() }
        active = kind
    }

    private func changed() {
        publishNowPlaying()
        decodeIfNeeded()
        updateClock()
        sendFrame()
        onChange?()
    }

    // MARK: - the visualizer and progress

    private func tick(_ dt: Double) {
        let p = activePlayer
        spectrum.step(toward: spectrum.target(samples: pcm, at: p.currentTime, playing: p.isPlaying), dt: dt)
        if !p.isPlaying && (spectrum.level.max() ?? 0) < 0.003 {
            spectrum.reset()                             // settled: stop until something moves
            clock?.isRunning = false
        }
        barsDrawn += 1
        onBars?(spectrum.level)
        // the page only needs the progress bar and the time: 4 updates a second
        if CACurrentMediaTime() - lastPageFrame >= 0.25 || clock?.isRunning != true { sendFrame() }
    }

    func sendFrame() {
        guard frameMode != .off else { return }
        framesSent += 1
        lastPageFrame = CACurrentMediaTime()
        let p = activePlayer
        onFrame?(active, p.currentTime, p.duration, p.isPlaying)
    }

    private func updateClock() {
        let p = activePlayer
        let settling = spectrum.level.contains { $0 > 0.003 }
        clock?.isRunning = frameMode == .full && (p.isPlaying || settling)
        // the mini player and the lyrics: 4 updates a second (the page counts forward in between)
        let interval: Double? = !p.isPlaying ? nil : frameMode == .slow || frameMode == .lyrics ? 0.25 : nil
        if interval != slowInterval {
            slowTimer?.invalidate()
            slowTimer = nil
            slowInterval = interval
            if let interval {
                slowTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sendFrame() }
                }
            }
        }
        if frameMode != .full && !p.isPlaying { spectrum.reset() }
        if frameMode != .full { onBars?([Float](repeating: 0, count: spectrum.count)) }   // the bars at rest
    }

    /// The bars need the playing song decoded -- only worked out when bars are showing.
    private func decodeIfNeeded() {
        guard frameMode == .full, let url = activePlayer.url ?? activeSong?.url, pcmFor != url else { return }
        pcmFor = url
        pcm = []
        pcmTask?.cancel()
        pcmTask = Task.detached(priority: .utility) { [weak self] in
            let samples = AudioDecoder.decodeForVisualizer(url)
            await self?.decoded(samples, for: url)
        }
    }

    private func decoded(_ samples: [Int16]?, for url: URL) {
        defer { Memory.giveBack() }                      // decoding churned through a lot of memory
        guard pcmFor == url, let samples else { return }
        pcm = samples
    }

    // MARK: - Control Center, media keys, headphone buttons

    private func setUpRemoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        func hook(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.addTarget { event in
                MainActor.assumeIsolated { action(event) }
                return .success
            }
        }
        hook(rc.togglePlayPauseCommand) { [weak self] _ in self?.toggle() }
        hook(rc.playCommand) { [weak self] _ in if self?.isPlaying == false { self?.toggle() } }
        hook(rc.pauseCommand) { [weak self] _ in if self?.isPlaying == true { self?.toggle() } }
        hook(rc.nextTrackCommand) { [weak self] _ in self?.next() }
        hook(rc.previousTrackCommand) { [weak self] _ in self?.previous() }
        hook(rc.changePlaybackPositionCommand) { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) }
        }
    }

    private func publishNowPlaying() {
        guard remoteControls else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let song = activeSong, activePlayer.isLoaded else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        let p = activePlayer
        var info: [String: Any] = [MPMediaItemPropertyTitle: song.title,
                                   MPMediaItemPropertyPlaybackDuration: p.duration,
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: p.currentTime,
                                   MPNowPlayingInfoPropertyPlaybackRate: p.isPlaying ? 1.0 : 0.0]
        if let a = song.artist { info[MPMediaItemPropertyArtist] = a }
        if let a = song.album { info[MPMediaItemPropertyAlbumTitle] = a }
        center.nowPlayingInfo = info
        center.playbackState = p.isPlaying ? .playing : .paused
    }
}
