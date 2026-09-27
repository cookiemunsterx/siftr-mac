import Accelerate
import Foundation

/// The visualizer's math, ported line for line from the original viz.py:
/// the song decoded once to mono at 22050 Hz; each frame, an FFT of the
/// 2048 samples at the playback position, summed into 56 log-spaced bars,
/// mapped from decibels to 0...1 and smoothed (fast rise, slow fall).
public final class Spectrum {
    public static let rate = 22050.0
    public static let window = 2048
    public static let bars = 56                    // viz.py's count (the app can ask for more)
    private static let half = window / 2

    /// viz.py's bar edges, for its 56 bars.
    public static let edges = makeEdges(bars)

    /// FFT bin where each bar starts: log-spaced from 3 to 1024, strictly
    /// increasing so no two bars share a bin (viz.py's _make_edges).
    public static func makeEdges(_ bars: Int) -> [Int] {
        let lo = log10(3.0), hi = log10(Double(half))
        var e = (0...bars).map { i in
            Int(pow(10, lo + (hi - lo) * Double(i) / Double(bars)).rounded(.toNearestOrEven))
        }
        for i in 1..<e.count { e[i] = max(e[i], e[i - 1]) }                     // cumulative max
        for i in 1..<e.count where e[i] <= e[i - 1] { e[i] = e[i - 1] + 1 }
        return e.map { min(max($0, 0), half) }
    }

    public let count: Int
    private let e: [Int]
    private let floorDB: Float, rangeDB: Float
    private let counts: [Float]
    private let lift: [Float]
    private let hann: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>
    private var frame = [Float](repeating: 0, count: window)
    private var real = [Float](repeating: 0, count: half)
    private var imag = [Float](repeating: 0, count: half)
    private var magnitudes = [Float](repeating: 0, count: half + 1)
    public private(set) var level: [Float]

    /// viz.py's settings by default: 56 bars, and -56 dB (silent) to -22 dB
    /// (full height). The app uses more bars and a more sensitive range.
    public init(bars: Int = Spectrum.bars, floorDB: Float = 56, rangeDB: Float = 34) {
        count = bars
        e = bars == Self.bars ? Self.edges : Self.makeEdges(bars)
        self.floorDB = floorDB
        self.rangeDB = rangeDB
        level = [Float](repeating: 0, count: bars)
        let e = self.e
        counts = (0..<bars).map { Float(max(e[$0 + 1] - e[$0], 1)) }
        lift = (0..<bars).map { 1 + 0.28 * Float($0) / Float(bars - 1) }   // lift the quiet highs
        // numpy.hanning: the symmetric version (N - 1 in the denominator)
        hann = (0..<Self.window).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(Self.window - 1)) }
        fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)!
    }

    /// Where every bar wants to be for the window at `seconds` (all zeros
    /// when not playing, so the bars fall away when paused).
    public func target(samples: [Int16], at seconds: Double, playing: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        guard playing, samples.count > Self.window else { return out }
        let start = min(max(Int(seconds * Self.rate), 0), samples.count - Self.window - 1)

        samples.withUnsafeBufferPointer { s in
            vDSP.convertElements(of: UnsafeBufferPointer(rebasing: s[start..<(start + Self.window)]), to: &frame)
        }
        vDSP.multiply(1 / 32768, frame, result: &frame)
        vDSP.multiply(frame, hann, result: &frame)

        // real FFT; vDSP's packed result is twice numpy's rfft, with the
        // Nyquist bin tucked into imag[0]
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.half))
                }
                fft.forward(input: split, output: &split)
            }
        }
        magnitudes[0] = abs(real[0]) / 2
        magnitudes[Self.half] = abs(imag[0]) / 2
        for k in 1..<Self.half { magnitudes[k] = hypot(real[k], imag[k]) / 2 }

        let e = self.e
        for b in 0..<count {
            // numpy reduceat: the last bar runs to the end of the spectrum
            let lo = e[b], hi = b < count - 1 ? e[b + 1] : Self.half + 1
            var sum: Float = 0
            if hi > lo { for k in lo..<hi { sum += magnitudes[k] } } else { sum = magnitudes[lo] }
            let mean = sum / counts[b] / Float(Self.window / 4)
            let db = 20 * log10(mean + 1e-6)
            out[b] = min(min(max((db + floorDB) / rangeDB, 0), 1) * lift[b], 1)
        }
        return out
    }

    /// Moves the bars toward `target`. The original stepped 0.55 up / 0.16
    /// down every 1/30 s; scaled by `dt` it feels the same at any frame rate.
    @discardableResult
    public func step(toward target: [Float], dt: Double) -> [Float] {
        let k = Float(dt * 30)
        let up = 1 - pow(0.45, k), down = 1 - pow(0.84, k)
        for b in 0..<count {
            let d = target[b] - level[b]
            level[b] += d * (d > 0 ? up : down)
        }
        return level
    }

    public func reset() {
        level = [Float](repeating: 0, count: count)
    }
}
