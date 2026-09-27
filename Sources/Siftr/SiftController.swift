import AppKit
import SifterCore

/// One decision made this session (newest last), for the "Sorted this
/// session" list and undo.
struct SessionEntry {
    let id: Int
    let key: String
    let decision: Decision
    let title: String
    let copied: String?
    let source: URL
    let batch: Int
}

/// Sifting: the folder's queue, keep / pass / skip / undo, and what the
/// Sifting page shows. It plays through Playback's sifting player.
@MainActor
final class SiftController {
    let store: LibraryStore?
    let playback: Playback
    private(set) var queue = SifterQueue()
    private(set) var session: [SessionEntry] = []
    private(set) var busy = false            // a keep is copying
    private(set) var status = "Ready"
    private(set) var playError = false
    private(set) var folder: URL?

    private var ids: [URL: Int] = [:]
    private var urls: [Int: URL] = [:]
    private var nextID = 0
    private var nextEntryID = 0
    private var keys: [URL: String] = [:]
    private var tags: [URL: Tags] = [:]
    private var tagTask: Task<Void, Never>?
    private var gen = 0                      // bumps per loaded song
    private var batch = 0                    // bumps per opened folder
    private var headline = ("Nothing loaded", "Open a folder of music to begin")
    private var queueDirty = true
    private var sentWindow: Range<Int>?          // the part of the queue the page has (a big batch isn't sent whole)
    /// How many rows of Up next the page gets (SIFTER_QUEUE_WINDOW, for measuring against the whole queue).
    static let window = Int(ProcessInfo.processInfo.environment["SIFTER_QUEUE_WINDOW"] ?? "") ?? 250
    private var sessionDirty = true
    private var metaPushScheduled = false

    var onChange: (() -> Void)?
    var onLibraryChanged: (() -> Void)?
    var onFlash: ((Decision) -> Void)?
    var alert: ((String, String, Bool) -> Void)?
    var onFolder: ((URL) -> Void)?
    var onFolderClosed: (() -> Void)?

    init(store: LibraryStore?, playback: Playback) {
        self.store = store
        self.playback = playback
        playback.onSiftFinished = { [weak self] in self?.trackEnded() }
        playback.onSiftNext = { [weak self] in self?.next() }
        playback.onSiftPrevious = { [weak self] in self?.previous() }
    }

    // MARK: - folders

    func open(_ url: URL) {
        guard !busy else { return }
        if let reason = Batch.siftRefusal(url, library: Paths.libraryDir()) {
            alert?("That folder can't be sifted", reason, false)
            return
        }
        batch += 1
        let thisBatch = batch
        let previousStatus = status
        status = "Looking for songs in \(url.lastPathComponent)…"
        changed()
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                FolderScanner.scan(url).map { ($0, songKey(for: $0)) }
            }.value
            guard thisBatch == self.batch else { return }   // a newer folder won
            self.folderScanned(url, found, previousStatus: previousStatus)
        }
    }

    private func folderScanned(_ folder: URL, _ found: [(URL, String)], previousStatus: String) {
        if found.isEmpty {
            status = previousStatus
            changed()
            alert?("Nothing to play", "No audio files were found in that folder.", false)
            return
        }
        let judged = store?.allKeys() ?? []                 // one query for the whole folder
        trace("folder \(folder.lastPathComponent): \(found.count) songs found")
        var fresh: [URL] = []
        for (url, key) in found {
            keys[url] = key
            if !judged.contains(key) { fresh.append(url) }
        }
        let already = found.count - fresh.count
        self.folder = folder
        onFolder?(folder)
        tagTask?.cancel()
        tags.removeAll()
        queue = SifterQueue(fresh)
        queueDirty = true
        if fresh.isEmpty {
            headline = ("All sorted", "Every track here has been judged already")
            status = "\(plural(found.count, "file")), all previously sorted."
            loadCurrent(announceEnd: false)
            return
        }
        status = "\(plural(fresh.count, "track")) to sort"
        if already > 0 { status += "  •  \(already) skipped (already sorted)" }
        loadCurrent()
        loadAllTags()
    }

    // MARK: - playing

    private func loadCurrent(announceEnd: Bool = true) {
        gen += 1
        playError = false
        if let url = queue.current {
            let thisGen = gen
            let song = Playback.Song(kind: .sift, id: String(id(for: url)), url: url, title: displayTitle(url),
                                     artist: tags[url]?.artist, album: tags[url]?.album)
            playback.loadSift(song) { [weak self] in
                guard let self, thisGen == self.gen else { return }
                self.playError = true
                self.status = "Could not play \(url.lastPathComponent) — it may be damaged or in a format macOS can't read"
                self.changed()
            }
            if tags[url] == nil {
                Task {
                    let t = await MetadataReader.tags(for: url)
                    self.tagsLoaded(url, t, pushNow: thisGen == self.gen)
                }
            }
        } else {
            playback.loadSift(nil) {}
            if announceEnd {
                headline = ("Batch complete", "Nothing left to sort in this folder")
                status = "Batch complete."
            }
        }
        changed()
    }

    func next() {
        guard !busy, queue.next() else { return }
        loadCurrent()
    }

    func previous() {
        guard !busy, queue.previous() else { return }
        loadCurrent()
    }

    func jump(to index: Int) {
        guard !busy, queue.jump(to: index) else { return }
        loadCurrent()
    }

    /// The song ran off its end: on to the next, or stop at the end of the queue.
    private func trackEnded() {
        guard !busy, queue.next() else { return changed() }
        loadCurrent()
    }

    // MARK: - judging

    func judge(_ decision: Decision) {
        guard !busy, let url = queue.current else { return }
        let key = keys[url] ?? songKey(for: url)
        let title = displayTitle(url)
        onFlash?(decision)
        switch decision {
        case .keep:
            busy = true
            let library = Paths.libraryDir()
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try Keeper.copy(url, into: library) }
                }.value
                self.busy = false
                switch result {
                case .success(let copy):
                    self.commit(.keep, url, key, title, copied: copy.path)
                case .failure(let error):
                    self.changed()   // not recorded: the song stays put
                    self.alert?("Could not copy", "Keeping failed:\n\(error.localizedDescription)", true)
                }
            }
        case .pass:
            commit(.pass, url, key, title, copied: nil)
        case .skip:
            queue.judgeCurrent(.skip)
            queueDirty = true
            status = "Skipped for now  •  \(title)"
            loadCurrent()
        }
    }

    private func commit(_ decision: Decision, _ url: URL, _ key: String, _ title: String, copied: String?) {
        do {
            try store?.record(key: key, decision: decision, title: title, source: url.path, copied: copied)
        } catch {
            if let copied { _ = try? Keeper.removeCopy(atPath: copied, library: Paths.libraryDir()) }
            changed()
            alert?("Couldn't save that", "The decision couldn't be written to the database:\n\(error)", true)
            return
        }
        nextEntryID += 1
        session.append(SessionEntry(id: nextEntryID, key: key, decision: decision, title: title,
                                    copied: copied, source: url, batch: batch))
        sessionDirty = true
        queueDirty = true
        status = (decision == .keep ? "Kept — copied to your library" : "Passed") + "  •  \(title)"
        if decision == .keep { onLibraryChanged?() }
        if queue.current == url {
            queue.judgeCurrent(decision)
            loadCurrent()
        } else {
            queue.remove(url)
            changed()
        }
    }

    /// Takes a decision back: forgets it, trashes a keep's library copy, and
    /// puts the song back in the queue as the current song.
    func undo(entry id: Int) {
        guard !busy, let i = session.firstIndex(where: { $0.id == id }) else { return }
        let entry = session.remove(at: i)
        sessionDirty = true
        var copied = entry.copied
        do {
            if let fromDB = try store?.forget(key: entry.key) { copied = fromDB }
        } catch {
            status = "Couldn't update the database: \(error)"
        }
        var note = ""
        if entry.decision == .keep, let copied {
            do {
                if try !Keeper.removeCopy(atPath: copied, library: Paths.libraryDir()) {
                    note = " (its library copy was already gone)"
                }
            } catch {
                note = " — its library copy couldn't be moved to the Trash: \(error.localizedDescription)"
            }
            onLibraryChanged?()
        }
        status = "Undid \(entry.decision.rawValue)  •  \(entry.title)\(note)"
        if FileManager.default.fileExists(atPath: entry.source.path), !queue.contains(entry.source) {
            queue.reinsertAtCurrent(entry.source)
            queueDirty = true
            loadCurrent()
        } else {
            changed()
        }
    }

    func undoLast() {
        if let last = session.last { undo(entry: last.id) }
    }

    // MARK: - finishing the batch

    /// What Finish batch would do with the open folder -- or why it can't.
    func batchSummary(libraryKeys: Set<String>) -> Result<Batch.Summary, BatchRefusal>? {
        guard let folder, let store else { return nil }
        if let reason = Batch.finishRefusal(folder, library: Paths.libraryDir()) { return .failure(BatchRefusal(reason: reason)) }
        return .success(Batch.summary(folder, store: store, libraryKeys: libraryKeys))
    }

    struct BatchRefusal: Error { let reason: String }

    /// Sends the open folder to the Trash (the checks already passed) and
    /// clears the Sifting page. Decisions are kept, so its songs stay sorted
    /// if they ever turn up again.
    func finishBatch() throws {
        guard let folder else { return }
        playback.loadSift(nil) {}               // let go of the song first
        try Keeper.moveToTrash(folder)
        self.folder = nil
        batch += 1
        tagTask?.cancel()
        queue = SifterQueue()
        queueDirty = true
        headline = ("Batch finished", "“\(folder.lastPathComponent)” is in the Trash. Open another folder to keep going.")
        status = "Finished “\(folder.lastPathComponent)”: moved to the Trash."
        gen += 1
        onFolderClosed?()
        changed()
    }

    // MARK: - tags and art

    private func loadAllTags() {
        let pending = queue.items.filter { tags[$0] == nil }
        tagTask = Task {
            await withTaskGroup(of: (URL, Tags).self) { group in
                var iterator = pending.makeIterator()
                func addNext() {
                    guard let url = iterator.next() else { return }
                    group.addTask { (url, await MetadataReader.tags(for: url)) }
                }
                for _ in 0..<4 { addNext() }          // a few at a time
                for await (url, t) in group {
                    if Task.isCancelled { group.cancelAll(); return }
                    self.tagsLoaded(url, t, pushNow: false)
                    addNext()
                }
            }
        }
    }

    private func tagsLoaded(_ url: URL, _ t: Tags, pushNow: Bool) {
        guard tags[url] != t else { return }
        tags[url] = t
        if url == queue.current {
            playback.updateSiftTags(title: displayTitle(url), artist: t.artist, album: t.album)
        }
        guard queue.contains(url) else { return }
        queueDirty = true
        if pushNow { return changed() }
        // many songs' tags arrive at once: redraw the list a few times a second
        guard !metaPushScheduled else { return }
        metaPushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.metaPushScheduled = false
            self?.changed()
        }
    }

    func displayTitle(_ url: URL) -> String {
        tags[url]?.title ?? url.deletingPathExtension().lastPathComponent
    }

    private func subtitle(_ url: URL) -> String {
        let parts = [tags[url]?.artist, tags[url]?.album].compactMap { $0 }
        return parts.isEmpty ? url.lastPathComponent : parts.joined(separator: "  •  ")
    }

    private func id(for url: URL) -> Int {
        if let id = ids[url] { return id }
        nextID += 1
        ids[url] = nextID
        urls[nextID] = url
        return nextID
    }

    func url(forArt id: Int) -> URL? { urls[id] }

    // MARK: - what the Sifting page shows

    struct NowPayload: Encodable {
        let gen: Int, id: Int
        let art: String
        let title: String, sub: String
        let error: Bool
    }
    struct RowPayload: Encodable { let id: Int; let title: String; let artist: String? }
    struct SessionPayload: Encodable { let id: Int; let decision: String; let title: String }
    struct Progress: Encodable { let kept: Int, passed: Int, total: Int }
    struct Counts: Encodable { let kept: Int, passed: Int }
    struct State: Encodable {
        let now: NowPayload
        let hasTrack: Bool, playing: Bool, active: Bool
        let position: Double, duration: Double
        let canPrev: Bool, canNext: Bool
        let index: Int
        let status: String
        let progress: Progress
        let counts: Counts
        let folder: String?
        let busy: Bool
        var queue: [RowPayload]?
        var queueStart: Int?                  // where those rows start in the queue
        var queueTotal = 0
        var session: [SessionPayload]?
    }

    func state() -> State {
        let now: NowPayload
        if let url = queue.current {
            let id = id(for: url)
            now = NowPayload(gen: gen, id: id, art: "\(SchemeHandler.origin)/art/sift/\(id)?g=\(gen)&s=400",
                             title: displayTitle(url), sub: playError ? "Could not play this file" : subtitle(url),
                             error: playError)
        } else {
            now = NowPayload(gen: gen, id: -1, art: "", title: headline.0, sub: headline.1, error: false)
        }
        let mine = session.filter { $0.batch == batch }
        let kept = mine.filter { $0.decision == .keep }.count
        let passed = mine.count - kept
        let lifetime = store?.counts() ?? [:]
        let p = playback.sift
        var s = State(now: now, hasTrack: queue.current != nil, playing: p.isPlaying, active: playback.active == .sift,
                      position: p.currentTime, duration: p.duration,
                      canPrev: queue.index > 0, canNext: queue.index < queue.count - 1,
                      index: queue.index, status: status,
                      progress: Progress(kept: kept, passed: passed, total: kept + passed + queue.count),
                      counts: Counts(kept: lifetime["keep"] ?? 0, passed: lifetime["pass"] ?? 0),
                      folder: folder?.lastPathComponent, busy: busy)
        // Up next: the part around the current song (250 rows), sent again when the queue changes or
        // the current song nears its edge. A 3,000-song batch would otherwise be sent, and drawn, whole
        // after every Keep or Pass.
        let near = max(0, queue.index - 5)..<min(queue.count, queue.index + 30)
        if queueDirty || !(sentWindow.map { $0.lowerBound <= near.lowerBound && near.upperBound <= $0.upperBound } ?? false) {
            let start = max(0, queue.index - 20), end = min(queue.count, start + Self.window)
            s.queue = queue.items[start..<end].map { RowPayload(id: id(for: $0), title: displayTitle($0), artist: tags[$0]?.artist) }
            s.queueStart = start
            sentWindow = start..<end
            queueDirty = false
        }
        s.queueTotal = queue.count
        if sessionDirty {
            s.session = session.reversed().map { SessionPayload(id: $0.id, decision: $0.decision.rawValue, title: $0.title) }
            sessionDirty = false
        }
        return s
    }

    /// The page reloaded: send everything again next time.
    func resend() {
        queueDirty = true
        sessionDirty = true
    }

    private func changed() { onChange?() }

    private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}
