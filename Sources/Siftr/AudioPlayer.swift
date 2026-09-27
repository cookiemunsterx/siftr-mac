import AVFoundation
import AppKit
import SifterCore

/// Plays one song at a time (AVAudioPlayer: MP3, M4A, FLAC, WAV and OGG all
/// play natively on current macOS) and says when it ends. Times in seconds.
@MainActor
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private(set) var url: URL?
    var onFinish: (() -> Void)?

    var volume: Int = 70 {
        didSet { player?.volume = Float(volume) / 100 }
    }
    var duration: Double { player?.duration ?? 0 }
    var currentTime: Double { player?.currentTime ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var isLoaded: Bool { player != nil }

    /// A song opened and ready to start, made off the main thread: if the
    /// Mac's audio system is slow (headphones connecting, a sleeping
    /// display's speakers), that wait never freezes the window.
    final class Prepared: @unchecked Sendable {
        fileprivate let player: AVAudioPlayer
        let url: URL
        fileprivate init(_ player: AVAudioPlayer, _ url: URL) {
            self.player = player
            self.url = url
        }
    }

    /// Throws for files that can't be played.
    nonisolated static func prepare(_ url: URL) async throws -> Prepared {
        try await Task.detached(priority: .userInitiated) {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            return Prepared(p, url)
        }.value
    }

    /// Makes a prepared song the current one (stopping the last).
    func install(_ prepared: Prepared) {
        close()
        let p = prepared.player
        p.delegate = self
        p.volume = Float(volume) / 100
        player = p
        url = prepared.url
    }

    func play() { player?.play() }
    func pause() { player?.pause() }

    /// Jumps to `seconds`, kept inside [0, duration - 0.05] like the original.
    func seek(to seconds: Double) {
        guard let p = player, seconds.isFinite else { return }
        p.currentTime = min(max(seconds, 0), max(p.duration - 0.05, 0))
    }

    func close() {
        player?.stop()
        player = nil
        url = nil
    }

    /// A file that turns out to be damaged partway through: treat it as over.
    nonisolated func audioPlayerDecodeErrorDidOccur(_ broken: AVAudioPlayer, error: (any Error)?) {
        let id = ObjectIdentifier(broken)
        let message = error?.localizedDescription ?? "unknown"
        Task { @MainActor in
            trace("decode error: \(message)")
            guard let p = self.player, ObjectIdentifier(p) == id else { return }
            self.onFinish?()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(finished)
        Task { @MainActor in
            guard let p = self.player, ObjectIdentifier(p) == id else { return }   // an old song
            self.onFinish?()
        }
    }
}

/// Decodes a whole song to mono 16-bit samples at 22050 Hz for the
/// visualizer (about 10 MB for a 4-minute song), off the main thread.
enum AudioDecoder {
    static func decodeForVisualizer(_ url: URL) -> [Int16]? {
        guard let file = try? AVAudioFile(forReading: url),
              Double(file.length) / file.processingFormat.sampleRate <= longSongSeconds,   // a long mix: the bars rest
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Spectrum.rate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        converter.downmix = true
        let chunk: AVAudioFrameCount = 32_768
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk) else { return nil }
        var samples: [Int16] = []
        samples.reserveCapacity(Int(Double(file.length) * Spectrum.rate / file.processingFormat.sampleRate) + 1024)
        var finished = false
        while !finished {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                do {
                    try file.read(into: input, frameCount: chunk)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { return samples.isEmpty ? nil : samples }
            if let data = output.int16ChannelData, output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            finished = status == .endOfStream || (status == .inputRanDry && output.frameLength == 0)
            if Task.isCancelled { return nil }
        }
        return samples
    }
}

/// Calls back once per screen refresh (at most 60 times a second) while
/// running -- only while something on screen is animating.
@MainActor
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private let tick: (Double) -> Void
    private var last: CFTimeInterval = 0

    init(view: NSView, tick: @escaping (_ dt: Double) -> Void) {
        self.tick = tick
        super.init()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        // 30 a second, like the Windows original (and all a Low Power Mode page draws);
        // the bars' motion is scaled by the time between frames, so it moves the same
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Frames a second: 30, or 15 when the visualizer is calm (Settings -> Visualizer).
    var fps: Float = 30 {
        didSet { link?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps) }
    }

    var isRunning: Bool {
        get { !(link?.isPaused ?? true) }
        set {
            guard newValue != isRunning else { return }
            if newValue { last = 0 }
            link?.isPaused = !newValue
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt = last > 0 ? min(link.timestamp - last, 0.1) : 1.0 / 60
        last = link.timestamp
        tick(dt)
    }
}
