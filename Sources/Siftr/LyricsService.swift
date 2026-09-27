import AppKit
import SifterCore
@preconcurrency import WhisperKit

/// Runs Whisper on this Mac -- WhisperKit, the Core ML version of OpenAI's
/// open-source speech-to-text model, which runs on Apple's Neural Engine
/// (easy on the graphics chip). An actor: WhisperKit handles one song at a time.
actor Transcriber {
    private var kit: WhisperKit?

    var isLoaded: Bool { kit != nil }

    /// Loading is quick after the first time; the very first load has Core ML
    /// prepare the model for this Mac, which takes a few minutes.
    func load(model: URL, tokenizers: URL) async throws {
        guard kit == nil else { return }
        let config = WhisperKitConfig(modelFolder: model.path, tokenizerFolder: tokenizers, verbose: false,
                                      logLevel: .error, prewarm: true, load: true, download: false)
        kit = try await WhisperKit(config)
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }

    /// A song's lyrics as lines of timed words ([] if nobody's singing).
    /// `wholeSong`: read it straight through, 30 s at a time, as the Python
    /// app does -- slower, but nothing is cut mid-line. Otherwise it's split
    /// where voice detection hears quiet and four parts run at once, which is
    /// quick but, in music (never really quiet), cuts lines and loses words.
    func transcribe(_ url: URL, wholeSong: Bool) async throws -> [LyricLine] {
        guard let kit else { return [] }
        let options = DecodingOptions(task: .transcribe, language: "en", temperature: 0, usePrefillPrompt: true,
                                      skipSpecialTokens: true, wordTimestamps: true, concurrentWorkerCount: 4,
                                      chunkingStrategy: wholeSong ? ChunkingStrategy.none : .vad)
        let results = try await kit.transcribe(audioPath: url.path, decodeOptions: options)
        var lines: [LyricLine] = []
        for segment in results.flatMap(\.segments) {
            let words = (segment.words ?? []).compactMap { w -> LyricWord? in
                let text = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : LyricWord(start: LyricsFormat.round2(Double(w.start)),
                                                      end: LyricsFormat.round2(Double(w.end)), text: text)
            }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Whisper marks instrumental stretches as "[Music]", "(upbeat music)", "♪"
            guard let first = words.first, let last = words.last, !Self.isNoise(text) else { continue }
            lines.append(LyricLine(start: first.start, end: last.end, text: text, words: words))
        }
        return lines
    }

    static func isNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: "♪♫🎵🎶 .").union(.whitespaces))
        if t.isEmpty { return true }
        return (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")"))
    }
}

/// Lyrics for the library: a synced .lrc file beside a song if there is
/// one; otherwise, once the listener has said yes, Whisper writes them out,
/// newest songs first, in the background while the app is open. Asked once;
/// "no" hides lyrics everywhere until it's turned on in Settings.
@MainActor
final class LyricsService {
    /// Settings -> Lyrics -> Quality: two versions of the same model,
    /// large-v3-turbo (the one the Python app uses). Standard is compressed to
    /// 646 MB and quick; Best is the full-precision model (1.6 GB), read
    /// through each song whole, and hears busy songs far better. Neither is in
    /// the app: only the chosen one is downloaded, and only after a yes.
    enum Quality: String, Encodable, CaseIterable {
        case standard, best
        var variant: String { self == .best ? "openai_whisper-large-v3-v20240930_turbo" : "openai_whisper-large-v3-v20240930_turbo_632MB" }
        var size: String { self == .best ? "1.6 GB" : "646 MB" }
        var label: String { self == .best ? "Whisper large-v3-turbo, full precision" : "Whisper large-v3-turbo, compressed" }
    }
    var quality: Quality {
        get { Quality(rawValue: Prefs.store.string(forKey: "lyricsQuality") ?? "") ?? .standard }
        set { Prefs.store.set(newValue.rawValue, forKey: "lyricsQuality") }
    }
    /// The model in use (SIFTER_LYRICS_MODEL, for tests, wins over either).
    var model: String { ProcessInfo.processInfo.environment["SIFTER_LYRICS_MODEL"] ?? quality.variant }
    static let repo = "argmaxinc/whisperkit-coreml"

    enum Phase: String, Encodable { case off, ask, idle, downloading, preparing, working, error }

    let store: LibraryStore?
    let library: LibraryService
    private let transcriber = Transcriber()
    private(set) var phase: Phase = .ask
    private(set) var progress = 0.0               // download, 0...1
    private(set) var current: String?             // the song being transcribed
    private(set) var message: String?
    private var worker: Task<Void, Never>?
    var onChange: (() -> Void)?
    var onSaved: ((String) -> Void)?

    init(store: LibraryStore?, library: LibraryService) {
        self.store = store
        self.library = library
        phase = choice == nil ? .ask : choice == true ? .idle : .off
    }

    /// nil until the listener answers; then yes or no (changeable in Settings).
    var choice: Bool? {
        get { Prefs.store.object(forKey: "lyrics") as? Bool }
        set { Prefs.store.set(newValue, forKey: "lyrics") }
    }

    var modelsDir: URL { Paths.dataDir().appendingPathComponent("Models", isDirectory: true) }
    var modelFolder: URL {
        modelsDir.appendingPathComponent("models/\(Self.repo)/\(model)", isDirectory: true)
    }
    var modelDownloaded: Bool {
        ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent($0).path)
        }
    }

    func answer(_ yes: Bool) {
        choice = yes
        if yes {
            phase = .idle
            kick()
        } else {
            worker?.cancel()
            phase = .off
        }
        onChange?()
    }

    /// Starts writing lyrics for songs that have none, if that's wanted and
    /// isn't already happening.
    func kick() {
        guard choice == true, worker == nil else { return }
        let sources = store?.lyricsSources() ?? [:]
        guard library.rows.contains(where: { sources[$0.id] == nil }) else { return }
        worker = Task { await work() }
    }

    private func work() async {
        defer { worker = nil }
        message = nil
        while choice == true, !Task.isCancelled {
            let sources = store?.lyricsSources() ?? [:]
            guard let next = library.rows.reversed().first(where: { sources[$0.id] == nil }) else { break }
            let url = URL(fileURLWithPath: next.path)
            if let lines = Self.sidecar(for: url, duration: next.duration) {   // a synced .lrc needs no model
                save(next.id, lines, source: "lrc")
                continue
            }
            if next.duration > longSongSeconds {                                  // a long mix: not worth hours of Whisper
                save(next.id, [], source: "long")
                continue
            }
            do {
                if !modelDownloaded {
                    phase = .downloading
                    progress = 0
                    onChange?()
                    try await download()
                }
                if !(await transcriber.isLoaded) {
                    phase = .preparing
                    onChange?()
                    try await transcriber.load(model: modelFolder, tokenizers: modelsDir)
                }
            } catch {
                phase = .error
                message = "Couldn't get the lyrics model ready: \(error.localizedDescription)"
                onChange?()
                return
            }
            phase = .working
            current = LibraryService.title(next)
            onChange?()
            do {
                let lines = try await transcriber.transcribe(url, wholeSong: quality == .best)
                save(next.id, lines, source: lines.isEmpty ? "none" : "whisper")
            } catch {
                save(next.id, [], source: "none")     // unreadable: don't try it again every time
            }
        }
        await transcriber.unload()                    // nothing left to do: give the memory back
        current = nil
        phase = choice == true ? .idle : .off
        onChange?()
    }

    private func download() async throws {
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        _ = try await WhisperKit.download(variant: model, downloadBase: modelsDir, from: Self.repo) { p in
            let fraction = p.fractionCompleted
            Task { @MainActor [weak self] in
                guard let self, fraction - self.progress >= 0.01 || fraction >= 1 else { return }
                self.progress = fraction
                self.onChange?()
            }
        }
    }

    private func save(_ id: String, _ lines: [LyricLine], source: String) {
        try? store?.saveLyrics(id: id, segments: LyricsFormat.encode(lines), source: source)
        onSaved?(id)
        onChange?()
    }

    /// Synced lyrics from "<song name>.lrc" next to the song, if there's one.
    static func sidecar(for url: URL, duration: Double?) -> [LyricLine]? {
        let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
        guard let text = try? String(contentsOf: lrc, encoding: .utf8) else { return nil }
        let lines = LRC.parse(text, duration: duration)
        return lines.isEmpty ? nil : lines
    }

    /// Switches quality. The other version's download goes (it's big: only
    /// one is ever kept), the model in memory is put away, and songs without
    /// lyrics are written with the new one; lyrics already written stay until
    /// "Write them again".
    func setQuality(_ q: Quality) async {
        guard q != quality else { return }
        worker?.cancel()
        await worker?.value                           // the song being written finishes first
        await transcriber.unload()
        let old = modelFolder
        quality = q
        try? FileManager.default.removeItem(at: old)
        phase = choice == true ? .idle : choice == false ? .off : .ask
        onChange?()
        kick()
    }

    /// Settings -> Lyrics -> "Write them again": every song Whisper wrote out
    /// (or found no words in) is written again with the model chosen now.
    /// Lyrics from .lrc files stay; lines fixed by hand are written again too.
    func redo() async {
        worker?.cancel()
        await worker?.value
        let ids = (try? store?.forgetLyrics(sources: ["whisper", "none"])) ?? []
        for id in ids { onSaved?(id) }                // the pages show them as waiting
        onChange?()
        kick()
    }

    func removeModel() async {
        worker?.cancel()
        await transcriber.unload()
        try? FileManager.default.removeItem(at: modelsDir)
        phase = choice == true ? .idle : .off
        onChange?()
    }

    // MARK: - for the pages

    struct Status: Encodable {
        let phase: Phase
        let choice: Bool?
        let progress: Double
        let current: String?
        let done: Int, total: Int
        let message: String?
        let modelDownloaded: Bool
        let model: String, size: String, source: String, folder: String
        let quality: Quality, sizes: [String: String]
        let written: Int                              // songs with Whisper lyrics ("Write them again")
    }

    func status() -> Status {
        let sources = store?.lyricsSources() ?? [:]
        let done = library.rows.filter { sources[$0.id] != nil }.count
        return Status(phase: phase, choice: choice, progress: progress, current: current, done: done,
                      total: library.rows.count, message: message, modelDownloaded: modelDownloaded,
                      model: quality.label, size: quality.size,
                      source: "Hugging Face (\(Self.repo))", folder: modelsDir.path,
                      quality: quality, sizes: Dictionary(uniqueKeysWithValues: Quality.allCases.map { ($0.rawValue, $0.size) }),
                      written: sources.values.filter { $0 == "whisper" || $0 == "none" }.count)
    }

    struct Payload: Encodable {
        let id: String
        let source: String       // whisper, lrc, tags (plain text, no timing), none, missing
        let synced: Bool
        let offset: Double
        let lines: [LyricLine]
        let queued: Bool         // waiting to be written
    }

    func lyrics(for id: String) async -> Payload {
        let offset = store?.timing(id: id) ?? 0
        if let row = store?.lyrics(id: id) {
            return Payload(id: id, source: row.source, synced: row.source != "none", offset: offset,
                           lines: LyricsFormat.decode(row.segments), queued: false)
        }
        guard let url = library.url(id) else {
            return Payload(id: id, source: "missing", synced: false, offset: 0, lines: [], queued: false)
        }
        if let lines = Self.sidecar(for: url, duration: library.row(id)?.duration) {
            save(id, lines, source: "lrc")
            return Payload(id: id, source: "lrc", synced: true, offset: offset, lines: lines, queued: false)
        }
        if let text = await MetadataReader.embeddedLyrics(for: url) {   // untimed words in the tags
            let lines = text.components(separatedBy: .newlines).map {
                LyricLine(start: 0, end: 0, text: $0.trimmingCharacters(in: .whitespaces), words: [])
            }
            return Payload(id: id, source: "tags", synced: false, offset: 0, lines: lines, queued: choice == true)
        }
        return Payload(id: id, source: "missing", synced: false, offset: 0, lines: [], queued: choice == true)
    }

    func edit(_ id: String, line: Int, text: String) async -> Payload? {
        guard let row = store?.lyrics(id: id) else { return nil }
        let lines = LyricEdit.apply(LyricsFormat.decode(row.segments), line: line, text: text)
        try? store?.saveLyrics(id: id, segments: LyricsFormat.encode(lines), source: row.source)
        return await lyrics(for: id)
    }

    func setTiming(_ id: String, seconds: Double) {
        try? store?.setTiming(id: id, seconds: (seconds * 10).rounded() / 10)
    }

    struct SearchPayload: Encodable {
        let transcribed: Int
        let results: [LyricSearch.Result]
    }

    func search(_ query: String) -> SearchPayload {
        let all = store?.allLyrics() ?? []
        let songs = all.compactMap { entry -> LyricSearch.Song? in
            guard let r = library.row(entry.id) else { return nil }
            return LyricSearch.Song(id: entry.id, title: LibraryService.title(r), artist: r.artist ?? "",
                                    lines: LyricsFormat.decode(entry.segments))
        }
        return SearchPayload(transcribed: songs.count, results: LyricSearch.search(songs, query: query))
    }
}
