import Foundation
import CryptoKit
import Testing
@testable import SifterCore

/// A fresh scratch folder per test, removed afterwards.
final class Scratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ path: String, bytes: Int = 100) throws -> URL {
        let f = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: f)
        return f
    }
}

func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

@Suite struct ScannerTests {
    @Test func findsOnlyVisibleAudioSortedByPath() throws {
        let s = try Scratch()
        try s.file("b/song2.MP3")
        try s.file("a/deeper/song3.flac")
        try s.file("song1.m4a")
        try s.file("notes.txt")
        try s.file("cover.jpg")
        try s.file(".hidden/secret.mp3")            // hidden folder
        try s.file("a/.cache/deeper/also.wav")      // inside a hidden folder, deeper
        try s.file("b/._song2.MP3")                 // macOS shadow file
        try s.file("c/tune.ogg")
        try s.file("c/tune.wav")

        let root = s.url.resolvingSymlinksInPath().path + "/"   // /var is really /private/var
        let names = FolderScanner.scan(s.url).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: "") }
        #expect(names == ["a/deeper/song3.flac", "b/song2.MP3", "c/tune.ogg", "c/tune.wav", "song1.m4a"])
    }

    @Test func emptyOrMissingFolder() throws {
        let s = try Scratch()
        #expect(FolderScanner.scan(s.url).isEmpty)
        #expect(FolderScanner.scan(s.url.appendingPathComponent("nope")).isEmpty)
    }
}

@Suite struct KeyTests {
    @Test func keyIsLowercaseNamePlusSize() throws {
        let s = try Scratch()
        let f = try s.file("Song A.MP3", bytes: 1234)
        #expect(songKey(for: f) == "song a.mp3|1234")
    }

    @Test func keySurvivesMovingTheFile() throws {
        let s = try Scratch()
        let a = try s.file("one/Track.mp3", bytes: 50)
        let b = try s.file("two/elsewhere/Track.mp3", bytes: 50)
        #expect(songKey(for: a) == songKey(for: b))
    }

    @Test func decomposedAccentsMatchComposed() throws {
        let s = try Scratch()
        let f = try s.file("Cafe\u{301}.mp3", bytes: 10)  // e + combining accent
        #expect(songKey(for: f) == "caf\u{e9}.mp3|10")
    }

    @Test func timeFormat() {
        #expect(formatTime(0) == "0:00")
        #expect(formatTime(65.9) == "1:05")
        #expect(formatTime(-3) == "0:00")
        #expect(formatTime(.nan) == "0:00")
    }
}

@Suite struct StoreTests {
    @Test func recordCountForgetAndKeys() throws {
        let s = try Scratch()
        let store = try LibraryStore(url: s.url.appendingPathComponent("library.db"))
        try store.record(key: "a|1", decision: .keep, title: "A", source: "/x/a.mp3", copied: "/lib/a.mp3")
        try store.record(key: "b|2", decision: .pass, title: "B", source: "/x/b.mp3", copied: nil)
        try store.record(key: "c|3", decision: .pass, title: "C", source: "/x/c.mp3", copied: nil)
        #expect(store.counts() == ["keep": 1, "pass": 2])
        #expect(store.allKeys() == ["a|1", "b|2", "c|3"])
        #expect(store.decision(for: "b|2") == "pass")
        #expect(store.keptPaths() == ["/lib/a.mp3"])

        #expect(try store.forget(key: "a|1") == "/lib/a.mp3")
        #expect(try store.forget(key: "b|2") == nil)
        #expect(store.counts() == ["pass": 1])
        #expect(store.decision(for: "a|1") == nil)
    }

    @Test func recordReplaces() throws {
        let s = try Scratch()
        let store = try LibraryStore(url: s.url.appendingPathComponent("library.db"))
        try store.record(key: "a|1", decision: .pass, title: "A", source: "/x/a.mp3", copied: nil)
        try store.record(key: "a|1", decision: .keep, title: "A", source: "/x/a.mp3", copied: "/lib/a.mp3")
        #expect(store.counts() == ["keep": 1])
    }

    @Test func decisionsSurviveReopening() throws {
        let s = try Scratch()
        let db = s.url.appendingPathComponent("library.db")
        do {
            let store = try LibraryStore(url: db)
            try store.record(key: "k|9", decision: .keep, title: "K", source: "/x", copied: nil)
        }
        let again = try LibraryStore(url: db)
        #expect(again.allKeys() == ["k|9"])
    }

    @Test func titlesWithQuotesAndUnicode() throws {
        let s = try Scratch()
        let store = try LibraryStore(url: s.url.appendingPathComponent("library.db"))
        try store.record(key: "it's|1", decision: .keep, title: "It's \"Song\" – 日本", source: "/x", copied: nil)
        #expect(store.decision(for: "it's|1") == "keep")
    }
}

@Suite struct KeeperTests {
    @Test func copiesWithCollisionNamesAndLeavesSourceAlone() throws {
        let s = try Scratch()
        let src = try s.file("batch/Song A.mp3", bytes: 4096)
        let lib = s.url.appendingPathComponent("library")
        let before = try sha256(src)
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: src.path)

        let first = try Keeper.copy(src, into: lib)
        let second = try Keeper.copy(src, into: lib)
        let third = try Keeper.copy(src, into: lib)
        #expect(first.lastPathComponent == "Song A.mp3")
        #expect(second.lastPathComponent == "Song A (2).mp3")
        #expect(third.lastPathComponent == "Song A (3).mp3")

        #expect(try sha256(src) == before)                    // source untouched
        #expect(FileManager.default.fileExists(atPath: src.path))
        #expect(try sha256(first) == before)                   // copy identical
        let copiedDate = try FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date
        #expect(copiedDate == old)                             // dates carried over
    }

    @Test func removeCopyUsesTheTrashStandInAndOnlyInsideTheLibrary() throws {
        let s = try Scratch()
        let trash = useTestTrash()
        let src = try s.file("batch/Song.mp3")
        let lib = s.url.appendingPathComponent("library")
        let copy = try Keeper.copy(src, into: lib)

        #expect(try Keeper.removeCopy(atPath: copy.path, library: lib))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: src.path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        #expect(trashed.filter { $0.hasSuffix(" Song.mp3") }.count == 1)

        // already gone: nothing to do
        #expect(try Keeper.removeCopy(atPath: copy.path, library: lib) == false)
        // outside the library: refused, and the file stays
        #expect(throws: (any Error).self) { try Keeper.removeCopy(atPath: src.path, library: lib) }
        #expect(FileManager.default.fileExists(atPath: src.path))
        // a sneaky path that only looks like it's inside
        #expect(throws: (any Error).self) { try Keeper.removeCopy(atPath: lib.path + "/../batch/Song.mp3", library: lib) }
        #expect(FileManager.default.fileExists(atPath: src.path))
    }
}

@Suite struct PathsTests {
    /// The folders from before the rename to Siftr: the app's data folder is
    /// moved, the library is used where it is, and neither ever loses a file.
    @Test func foldersFromBeforeTheRename() throws {
        let s = try Scratch()
        let fm = FileManager.default
        let old = s.url.appendingPathComponent("Music Sifter Lite"), new = s.url.appendingPathComponent("Siftr")

        // nothing yet: the new name
        #expect(Paths.renamed(old, to: new, move: true) == new)
        #expect(!fm.fileExists(atPath: new.path))                     // deciding creates nothing

        // only the old one (the library): used where it is, not moved
        let db = try s.file("Music Sifter Lite/library.db", bytes: 321)
        #expect(Paths.renamed(old, to: new, move: false) == old)
        #expect(fm.fileExists(atPath: db.path))

        // only the old one (the data folder): moved, contents and all
        try s.file("Music Sifter Lite/Models/model.bin", bytes: 50)
        #expect(Paths.renamed(old, to: new, move: true) == new)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(try Data(contentsOf: new.appendingPathComponent("library.db")).count == 321)
        #expect(fm.fileExists(atPath: new.appendingPathComponent("Models/model.bin").path))

        // both there: the new one wins, and the old one is left alone
        try s.file("Music Sifter Lite/stray.txt")
        #expect(Paths.renamed(old, to: new, move: true) == new)
        #expect(Paths.renamed(old, to: new, move: false) == new)
        #expect(fm.fileExists(atPath: old.appendingPathComponent("stray.txt").path))
    }

    @Test func aMoveThatFailsKeepsTheOldFolder() throws {
        let s = try Scratch()
        try s.file("locked/Music Sifter Lite/library.db")
        let parent = s.url.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)   // can't rename inside
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let old = parent.appendingPathComponent("Music Sifter Lite")
        #expect(Paths.renamed(old, to: parent.appendingPathComponent("Siftr"), move: true) == old)
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("library.db").path))
    }
}

@Suite struct InstanceLockTests {
    @Test func oneCopyPerDataFolder() throws {
        let s = try Scratch()
        do {
            guard case .acquired(let first) = InstanceLock.acquire(in: s.url) else { Issue.record("first copy didn't get the lock"); return }
            guard case .heldBy(let pid) = InstanceLock.acquire(in: s.url) else { Issue.record("a second copy got the lock too"); return }
            #expect(pid == getpid())                               // it says who has it
            withExtendedLifetime(first) {}
        }                                                          // the first copy quits: it lets go
        guard case .acquired = InstanceLock.acquire(in: s.url) else { Issue.record("the lock wasn't let go"); return }
        let other = try Scratch()                                  // another data folder: its own lock
        guard case .acquired = InstanceLock.acquire(in: other.url) else { Issue.record("another folder was locked too"); return }
    }
}

@Suite struct RestoreTests {
    /// Backups name songs by title; Restore puts them back under their own
    /// names, so Siftr knows them again, and never replaces anything.
    @Test func restoredSongsKeepTheirNames() throws {
        let s = try Scratch()
        let lib = s.url.appendingPathComponent("lib")
        let a = try s.file("lib/Artist/01 first.mp3", bytes: 1000), b = try s.file("lib/02 second.m4a", bytes: 2000)
        let drive = s.url.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let songs = [Backup.Song(id: "a", title: "First", artist: "", album: "Album", duration: 60, path: a),
                     Backup.Song(id: "b", title: "Second", artist: "", album: "Album", duration: 60, path: b)]
        _ = try Backup.run(songs, drive: drive, library: lib) { _, _, _ in }
        #expect(Backup.restoreEntries(on: drive)?.map(\.original) == ["Artist/01 first.mp3", "02 second.m4a"])

        // the Mac's library is gone: into a new one
        let fresh = s.url.appendingPathComponent("new lib")
        let r = try Backup.restore(from: drive, into: fresh) { _, _, _ in }
        #expect(r.copied == 2 && r.alreadyThere == 0 && r.conflicts.isEmpty && r.missing.isEmpty)
        #expect(songKey(for: fresh.appendingPathComponent("Artist/01 first.mp3")) == songKey(for: a))   // the same song again
        // again: nothing to copy; a different file under a song's name is left alone
        try Data(repeating: 9, count: 5).write(to: fresh.appendingPathComponent("02 second.m4a"))
        let again = try Backup.restore(from: drive, into: fresh) { _, _, _ in }
        #expect(again.copied == 0 && again.alreadyThere == 1 && again.conflicts == ["Second"])
        #expect(try Data(contentsOf: fresh.appendingPathComponent("02 second.m4a")).count == 5)
    }

    @Test func historyComesBackOnceAndNothingHereIsLost() throws {
        let s = try Scratch()
        let old = try LibraryStore(url: s.url.appendingPathComponent("old.db"))
        try old.record(key: "a|1", decision: .keep, title: "A", source: "/x", copied: nil)
        try old.recordPlay(id: "a", at: Date(timeIntervalSince1970: 100))
        try old.saveLyrics(id: "a", segments: "[]", source: "whisper")
        let copy = s.url.appendingPathComponent("copy.db")
        try old.snapshot(to: copy)
        let new = try LibraryStore(url: s.url.appendingPathComponent("new.db"))
        try new.recordPlay(id: "b", at: Date(timeIntervalSince1970: 200))          // already here: stays
        let m = try new.merge(from: copy)
        #expect(m.decisions == 1 && m.plays == 1 && m.lyrics == 1)
        #expect(new.decision(for: "a|1") == "keep" && new.playLog().count == 2 && new.lyricsSources()["a"] == "whisper")
        #expect(try new.merge(from: copy) == LibraryStore.MergeSummary())         // twice: nothing more
    }
}

@Suite struct QueueTests {
    let a = URL(fileURLWithPath: "/m/a.mp3"), b = URL(fileURLWithPath: "/m/b.mp3")
    let c = URL(fileURLWithPath: "/m/c.mp3"), d = URL(fileURLWithPath: "/m/d.mp3")

    @Test func keepAndPassRemoveAndLoadTheSameIndex() {
        var q = SifterQueue([a, b, c])
        #expect(q.current == a)
        q.judgeCurrent(.keep)
        #expect(q.items == [b, c] && q.current == b)
        _ = q.next()
        q.judgeCurrent(.pass)                    // last one: clamp to the new last
        #expect(q.items == [b] && q.current == b)
        q.judgeCurrent(.keep)
        #expect(q.isEmpty && q.current == nil)
    }

    @Test func skipSendsToTheBack() {
        var q = SifterQueue([a, b, c])
        q.judgeCurrent(.skip)
        #expect(q.items == [b, c, a] && q.current == b)
        var one = SifterQueue([a])
        one.judgeCurrent(.skip)                 // alone: it comes straight back
        #expect(one.items == [a] && one.current == a)
    }

    @Test func prevNextJumpStopAtTheEnds() {
        var q = SifterQueue([a, b])
        var moved = q.previous()
        #expect(!moved)
        moved = q.next()
        #expect(moved && q.current == b)
        moved = q.next()
        #expect(!moved)
        moved = q.jump(to: 0)
        #expect(moved && q.current == a)
        moved = q.jump(to: 5)
        #expect(!moved && q.current == a)
    }

    @Test func undoReinsertsAtTheCurrentPosition() {
        var q = SifterQueue([a, b, c])
        _ = q.next()                             // on b
        q.reinsertAtCurrent(d)
        #expect(q.items == [a, d, b, c] && q.current == d)
        var empty = SifterQueue([])
        empty.reinsertAtCurrent(a)
        #expect(empty.items == [a] && empty.current == a)
    }
}

/// Reference values printed by the original viz.py (numpy) for the same signal.
@Suite struct SpectrumTests {
    static let numpyEdges = [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 24, 27, 30, 33, 37, 41, 45, 50, 55, 62, 68, 76, 84, 93, 104, 115, 128, 142, 157, 174, 193, 215, 238, 264, 293, 326, 361, 401, 445, 494, 548, 608, 675, 749, 831, 923, 1024]
    // bars 5, 6, 7, 24, 25, 43 light up; the rest are 0
    static let lit: [Int: (target: Float, level3: Float, decay2: Float)] = [
        5: (0.63742, 0.57933, 0.40878), 6: (0.82657, 0.75125, 0.53008), 7: (0.65116, 0.59182, 0.41759),
        24: (0.83474, 0.75868, 0.53532), 25: (1.00000, 0.90887, 0.64130), 43: (0.44737, 0.40660, 0.28690),
    ]

    /// 3 s of 440 Hz + 3 kHz + 97 Hz at 22050 Hz, as int16 -- the same signal the numpy run used.
    static let signal: [Int16] = (0..<66_150).map { n in
        let t = Double(n) / 22050
        let v = 0.5 * sin(2 * .pi * 440 * t) + 0.25 * sin(2 * .pi * 3000 * t) + 0.1 * sin(2 * .pi * 97 * t)
        return Int16((v * 12000).rounded(.toNearestOrEven))
    }

    @Test func edgesMatchNumpy() {
        #expect(Spectrum.edges == Self.numpyEdges)
    }

    @Test func moreBarsStillEachGetTheirOwnBins() {
        let e = Spectrum.makeEdges(96)
        #expect(e.count == 97 && e.first == 3 && e.last == Spectrum.window / 2)
        #expect(zip(e, e.dropFirst()).allSatisfy { $0 < $1 })
        let s = Spectrum(bars: 96, floorDB: 60, rangeDB: 34)
        let t = s.target(samples: Self.signal, at: 1.0, playing: true)
        #expect(t.count == 96 && t.allSatisfy { $0 >= 0 && $0 <= 1 } && (t.max() ?? 0) > 0.3)
    }

    @Test func targetMatchesNumpy() {
        let t = Spectrum().target(samples: Self.signal, at: 1.0, playing: true)
        for b in 0..<Spectrum.bars {
            let want = Self.lit[b]?.target ?? 0
            #expect(abs(t[b] - want) < 0.002, "bar \(b): \(t[b]) vs numpy \(want)")
        }
    }

    @Test func smoothingMatchesTheOriginalAt30fps() {
        let s = Spectrum()
        for _ in 0..<3 { s.step(toward: s.target(samples: Self.signal, at: 1.0, playing: true), dt: 1.0 / 30) }
        for b in 0..<Spectrum.bars { #expect(abs(s.level[b] - (Self.lit[b]?.level3 ?? 0)) < 0.002, "rise, bar \(b)") }
        for _ in 0..<2 { s.step(toward: s.target(samples: Self.signal, at: 1.0, playing: false), dt: 1.0 / 30) }
        for b in 0..<Spectrum.bars { #expect(abs(s.level[b] - (Self.lit[b]?.decay2 ?? 0)) < 0.002, "fall, bar \(b)") }
    }

    @Test func sameFeelAt60fps() {
        // two 1/60 s steps land where one 1/30 s step does
        let a = Spectrum(), b = Spectrum()
        let t = a.target(samples: Self.signal, at: 1.0, playing: true)
        a.step(toward: t, dt: 1.0 / 30)
        b.step(toward: t, dt: 1.0 / 60); b.step(toward: t, dt: 1.0 / 60)
        for i in 0..<Spectrum.bars { #expect(abs(a.level[i] - b.level[i]) < 1e-4) }
    }

    @Test func silentWhenPausedOrTooShort() {
        let s = Spectrum()
        #expect(s.target(samples: Self.signal, at: 1.0, playing: false).allSatisfy { $0 == 0 })
        #expect(s.target(samples: [Int16](repeating: 9, count: 100), at: 0, playing: true).allSatisfy { $0 == 0 })
        // past the end: clamped to the last full window, no crash
        #expect(s.target(samples: Self.signal, at: 999, playing: true).contains { $0 > 0 })
    }
}

/// One scratch Trash for the whole test run. SIFTER_TRASH is shared by the
/// whole process and tests run side by side, so it's set once, to the same
/// place, and never unset (each test looks for its own file in it).
func useTestTrash() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sifter-tests-trash-\(getpid())", isDirectory: true)
    setenv("SIFTER_TRASH", url.path, 1)
    return url
}
