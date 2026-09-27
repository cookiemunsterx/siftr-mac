import Foundation
import Testing
@testable import SifterCore

// The Python app's tests (tests/test_lyrics_search.py, test_lyrics_edit.py,
// test_trends.py, test_albums.py, test_backup.py), ported case for case, so
// the Swift versions are held to exactly the same answers.

@Suite struct SequenceMatcherTests {
    @Test func ratiosMatchPythonsDifflib() {
        // difflib.SequenceMatcher(None, a, b).ratio() in Python
        #expect(abs(SequenceMatcher("highwey", "highway").ratio() - 0.857142857) < 1e-6)
        #expect(abs(SequenceMatcher("stance", "zance").ratio() - 0.727272727) < 1e-6)
        #expect(SequenceMatcher("", "").ratio() == 1)
        #expect(SequenceMatcher("abc", "xyz").ratio() == 0)
    }

    @Test func opcodesMatchPythonsDifflib() {
        // list(SequenceMatcher(None, "qabxcd", "abycdf").get_opcodes())
        let ops = SequenceMatcher("qabxcd", "abycdf").opcodes().map { "\($0.tag.rawValue) \($0.i1) \($0.i2) \($0.j1) \($0.j2)" }
        #expect(ops == ["delete 0 1 0 0", "equal 1 3 0 2", "replace 3 4 2 3", "equal 4 6 3 5", "insert 6 6 5 6"])
    }
}

@Suite struct LyricSearchTests {
    /// Made-up songs; each line lasts 5 s: line 0 at 0 s, line 1 at 5 s...
    static let songs: [LyricSearch.Song] = {
        func song(_ id: String, _ title: String, _ lines: [String]) -> LyricSearch.Song {
            LyricSearch.Song(id: id, title: title, artist: "Test Artist", lines: lines.enumerated().map {
                LyricLine(start: Double($0.offset) * 5, end: Double($0.offset) * 5 + 4, text: $0.element, words: [])
            })
        }
        return [
            song("A", "Sample Song 01", ["Riding through the city all night", "Headlights burning on the highway", "I ain't tired, I can't sleep"]),
            song("B", "Sample Song 02", ["Clouds rolling past my window", "Hold a zance by the water", "Paper lanterns over the harbor"]),
            song("C", "Sample Song 03", ["Everything I counted", "slipping past the gate"]),
            song("D", "Sample Song 04", ["Night falls on all of us"]),
            song("E", "Sample Song 05", ["Echo echo", "echo in the hall", "echo again", "one more echo"]),
        ]
    }()

    func titles(_ q: String) -> [String] { LyricSearch.search(Self.songs, query: q).map(\.title) }

    @Test func normalizeIgnoresCasePunctuationAndApostrophes() {
        #expect(LyricSearch.normalize("I AIN'T tired... right?") == ["i", "aint", "tired", "right"])
        #expect(LyricSearch.normalize("ain’t") == ["aint"])
    }

    @Test func exactPhraseFindsTheLineAndWhenItStarts() {
        let r = LyricSearch.search(Self.songs, query: "headlights burning")
        #expect(r.map(\.title) == ["Sample Song 01"])
        #expect(r[0].lines[0] == LyricSearch.Hit(time: 5, text: "Headlights burning on the highway", hits: ["burning", "headlights"]))
    }

    @Test func forgivingMatches() {
        #expect(titles("highway headlights").first == "Sample Song 01")        // any order
        #expect(titles("paper lan") == ["Sample Song 02"])                      // half-typed last word
        let typo = LyricSearch.search(Self.songs, query: "highwey headlights")  // 86% alike: counts
        #expect(typo.first?.title == "Sample Song 01" && typo[0].lines[0].hits.contains("highway"))
        #expect(titles("stance").isEmpty)                                       // 73%: too far on its own...
        #expect(titles("hold a stance") == ["Sample Song 02"])                  // ...but forgiven among 3 words
        #expect(titles("lanterns banana").isEmpty)                              // with 2 words, both must match
        #expect(titles("submarine volcano").isEmpty)
        #expect(titles("  ?! ").isEmpty)
    }

    @Test func aPhraseCanStraddleTwoLines() {
        let r = LyricSearch.search(Self.songs, query: "counted slipping")
        #expect(r.map(\.title) == ["Sample Song 03"])
        #expect(r[0].lines[0].text == "Everything I counted / slipping past the gate")
    }

    @Test func wordsTogetherRankAboveScatteredWords() {
        let r = LyricSearch.search(Self.songs, query: "all night")
        #expect(r.map(\.title) == ["Sample Song 01", "Sample Song 04"])
        #expect(r[0].score > r[1].score)
    }

    @Test func atMostTwoLinesPerSongNeverTheSameTwice() {
        let r = LyricSearch.search(Self.songs, query: "echo")
        #expect(r.map(\.title) == ["Sample Song 05"])
        #expect(r[0].lines.count == 2 && Set(r[0].lines.map(\.text)).count == 2)
    }
}

@Suite struct LyricEditTests {
    // "I been riding through the city", sung from 10.0 s to 12.0 s
    static let old = [LyricWord(start: 10.0, end: 10.2, text: "I"), LyricWord(start: 10.2, end: 10.5, text: "been"),
                      LyricWord(start: 10.5, end: 11.0, text: "riding"), LyricWord(start: 11.0, end: 11.3, text: "through"),
                      LyricWord(start: 11.3, end: 11.5, text: "the"), LyricWord(start: 11.5, end: 12.0, text: "city")]
    static let line = LyricLine(start: 10, end: 12, text: "I been riding through the city", words: old)
    static let next = LyricLine(start: 12.5, end: 14, text: "Second line",
                                words: [LyricWord(start: 12.5, end: 13.2, text: "Second"), LyricWord(start: 13.2, end: 14, text: "line")])

    func retime(_ text: String) -> [LyricWord] { LyricEdit.retimeLine(Self.old, text, lineStart: 10, lineEnd: 12) }

    @Test func fixingOneWordKeepsEveryOtherWordsTiming() {
        let w = retime("I been riding through the town")
        #expect(Array(w.prefix(5)) == Array(Self.old.prefix(5)))
        #expect(w[5] == LyricWord(start: 11.5, end: 12.0, text: "town"))
    }

    @Test func capitalizationAndPunctuationFixesKeepAllTimings() {
        let w = retime("i BEEN riding, through the city!")
        #expect(w.map(\.start) == Self.old.map(\.start) && w.map(\.end) == Self.old.map(\.end))
        #expect(w.map(\.text) == ["i", "BEEN", "riding,", "through", "the", "city!"])
    }

    @Test func oneWordReplacedByTwoSplitsItsTimeByLength() {
        let w = retime("I been riding through the big town")
        let (big, town) = (w[5], w[6])
        #expect(big.start == 11.5 && town.end == 12.0 && big.end == town.start)
        #expect(town.end - town.start > big.end - big.start)
    }

    @Test func addedWordsFitTheGapAndRemovedWordsDropOut() {
        let added = LyricEdit.retimeLine([LyricWord(start: 0, end: 0.5, text: "hello"), LyricWord(start: 1, end: 1.5, text: "world")],
                                         "hello big world", lineStart: 0, lineEnd: 1.5)
        #expect(added == [LyricWord(start: 0, end: 0.5, text: "hello"), LyricWord(start: 0.5, end: 1, text: "big"),
                          LyricWord(start: 1, end: 1.5, text: "world")])
        let removed = retime("I been riding through city")
        #expect(removed.map(\.text) == ["I", "been", "riding", "through", "city"])
        #expect(removed.last == LyricWord(start: 11.5, end: 12.0, text: "city"))
        #expect(LyricEdit.retimeLine([], "a bbb", lineStart: 0, lineEnd: 6) ==
                [LyricWord(start: 0, end: 2, text: "a"), LyricWord(start: 2, end: 6, text: "bbb")])
    }

    @Test func applyMarksTheLineTidiesSpacesAndBlankRemovesIt() {
        let edited = LyricEdit.apply([Self.line, Self.next], line: 0, text: "  I   been riding   through the town ")
        #expect(edited[0].text == "I been riding through the town" && edited[0].edited)
        #expect(edited[0].start == 10 && edited[0].end == 12 && edited[0].words.last?.text == "town")
        #expect(edited[1] == Self.next)
        #expect(LyricEdit.apply([Self.line, Self.next], line: 0, text: "   ") == [Self.next])
        for i in [0, 1] {
            let e = LyricEdit.apply([Self.line, Self.next], line: i, text: "new words here")[i]
            #expect(e.start == e.words.first!.start && e.end == e.words.last!.end)
        }
    }

    @Test func storedFormatRoundTripsThePythonShape() {
        let json = #"[[10.0,12.0,"a b",[[10.0,11.0,"a"],[11.0,12.0,"b"]]],[12.5,14.0,"c",[[12.5,14.0,"c"]],true]]"#
        let lines = LyricsFormat.decode(json)
        #expect(lines.count == 2 && lines[1].edited && !lines[0].edited && lines[0].words[1].text == "b")
        #expect(LyricsFormat.decode(LyricsFormat.encode(lines)) == lines)
        #expect(LyricsFormat.decode("not json").isEmpty)
    }
}

@Suite struct LRCTests {
    @Test func linesWithTimesAndWordsSpreadAcrossThem() {
        let text = """
        [ti:Song A]
        [offset:+500]
        [00:05.00]First line here
        [00:10.50][01:00.00]Chorus again
        [00:08.25]
        not a lyric
        """
        let lines = LRC.parse(text, duration: 90)
        #expect(lines.map(\.text) == ["First line here", "Chorus again", "Chorus again"])
        #expect(lines[0].start == 4.5)                         // the offset moves lines earlier
        #expect(lines[1].start == 10.0 && lines[2].start == 59.5)
        #expect(lines[0].words.count == 3 && lines[0].words[0].start == 4.5)
        #expect(lines[0].end <= 7.75 - 0.05 + 1e-9)           // ends before the next timestamp (the blank one)
    }
}

@Suite struct TrendsTests {
    static let today = Day(year: 2026, month: 9, day: 24)

    func track(_ id: String, plays: Int = 0, skips: Int = 0, last: Int? = nil, added: Int? = 365,
               duration: Double = 200) -> Trends.Track {
        Trends.Track(id: id, title: "Song \(id)", artist: "Test Artist", plays: plays, skips: skips, duration: duration,
                     lastPlayed: last.map { Self.today.adding(-$0) }, added: added.map { Self.today.adding(-$0) })
    }

    @Test func days() {
        #expect(Self.today.iso == "2026-09-24" && Self.today.adding(-3).shortLabel == "Sep 21")
        #expect(Day(year: 2024, month: 3, day: 1).adding(-1).iso == "2024-02-29")
        #expect(Day(year: 1970, month: 1, day: 1).ordinal == 0)
    }

    @Test func forgottenFavorites() {
        let tracks = (1...6).map { track("\($0)", plays: $0) } +
            [track("fav-idle", plays: 60, last: 40), track("fav-recent", plays: 50, last: 1), track("low-idle", plays: 2, last: 100)]
        let picks = Trends.forgottenFavorites(tracks, today: Self.today)
        #expect(picks.map(\.id) == ["fav-idle"])
        #expect(picks[0].detail == "60 plays · last played 40 days ago")
        #expect(Trends.forgottenFavorites([], today: Self.today).isEmpty)
    }

    @Test func skipMagnets() {
        let picks = Trends.skipMagnets([track("mostly-skipped", plays: 2, skips: 8), track("borderline", plays: 6, skips: 4),
                                        track("few-skips", plays: 1, skips: 2), track("loved", plays: 20, skips: 5),
                                        track("never-played")])
        #expect(picks.map(\.id) == ["mostly-skipped", "borderline"])
        #expect(picks[0].detail == "8 skips vs 2 plays (80% skipped)")
    }

    @Test func eras() {
        let tracks = [track("a", plays: 10, duration: 100), track("b", plays: 1, duration: 300),
                      track("c", plays: 5, duration: 400), track("d", plays: 3, duration: 100)]
        #expect(Trends.eras(tracks, albums: ["a": "Era X", "b": "Era X", "c": "Era Y", "d": ""]) == [
            Trends.Era(album: "Era Y", plays: 5, seconds: 2000, songs: 1),
            Trends.Era(album: "Era X", plays: 11, seconds: 1300, songs: 2),
            Trends.Era(album: "Unknown album", plays: 3, seconds: 300, songs: 1),
        ])
    }

    @Test func freshAdds() {
        let picks = Trends.freshAdds([track("today", plays: 3, added: 0), track("last-week", plays: 7, added: 10),
                                      track("old", plays: 50, added: 40), track("no-date", plays: 9, added: nil)], today: Self.today)
        #expect(picks.map(\.id) == ["last-week", "today"])
        #expect(picks[1].detail == "added today · 3 plays")
    }

    @Test func historyWindows() {
        #expect(Trends.history([track("a", plays: 5)], snapshots: [:], today: Self.today).window == nil)

        let first = Trends.history([track("a", plays: 7)], snapshots: [Self.today: ["a": 5]], today: Self.today)
        #expect(first.window == "today" && first.plays == 2 && first.mostPlayed?.first?.detail == "+2 plays")
        #expect(first.daysRecorded == 1 && first.comparisonUnlocks == Self.today.adding(14).iso)

        let short = Trends.history([track("a", plays: 9)], snapshots: [Self.today.adding(-3): ["a": 4]], today: Self.today)
        #expect(short.window == "since Sep 21" && short.plays == 5)

        let week = Trends.history([track("a", plays: 12, duration: 100), track("b", plays: 11, duration: 300)],
                                  snapshots: [Self.today.adding(-8): ["a": 1, "b": 1], Self.today.adding(-7): ["a": 2, "b": 10],
                                              Self.today.adding(-3): ["a": 5, "b": 10]], today: Self.today)
        #expect(week.window == "this week" && week.plays == 11 && week.seconds == 1300)
        #expect(week.mostPlayed?.map(\.id) == ["a", "b"])
    }

    @Test func historyGapsAreHandledCarefully() {
        let weekAgo = Self.today.adding(-7)
        #expect(Trends.history([track("new", plays: 4, added: 2)], snapshots: [weekAgo: [:]], today: Self.today).plays == 4)
        #expect(Trends.history([track("old", plays: 43)], snapshots: [weekAgo: [:], Self.today.adding(-5): ["old": 40]],
                               today: Self.today).plays == 3)
        let unknown = Trends.history([track("old", plays: 500)], snapshots: [weekAgo: [:]], today: Self.today)
        #expect(unknown.plays == 0 && unknown.mostPlayed == [])
    }

    @Test func heatingUpAndCoolingOffAfterTwoWeeks() {
        let r = Trends.history([track("hot", plays: 10), track("cold", plays: 11), track("steady", plays: 10)],
                               snapshots: [Self.today.adding(-14): ["hot": 0, "cold": 0, "steady": 0],
                                           Self.today.adding(-7): ["hot": 1, "cold": 10, "steady": 5]], today: Self.today)
        #expect(r.comparisonUnlocks == nil)
        #expect(r.heatingUp?.map(\.id) == ["hot"] && r.coolingOff?.map(\.id) == ["cold"])
        #expect(r.heatingUp?.first?.detail == "9 plays this week vs 1 the week before")
    }

    @Test func playHistoryFromTheLog() {
        let t = Self.today
        let (snapshots, days) = Trends.playHistory(added: ["a": t.adding(-20), "b": t.adding(-3)],
                                                   plays: [("a", t.adding(-10)), ("a", t.adding(-2)), ("a", t), ("b", t.adding(-1))],
                                                   today: t)
        #expect(days == 21)
        #expect(snapshots.keys.sorted() == [t.adding(-20), t.adding(-14), t.adding(-7), t])
        #expect(snapshots[t.adding(-7)] == ["a": 1])            // b wasn't in the library yet
        #expect(snapshots[t] == ["a": 2, "b": 1])               // today's play isn't "before today"
        #expect(Trends.playHistory(added: [:], plays: [], today: t).1 == 0)
    }
}

@Suite struct AlbumsTests {
    static let covers: [String: String] = ["a": "shared", "b": "variant", "c": "shared"]
    let cover: (String) -> String? = { covers[$0] }

    @Test func coverPicking() {
        #expect(Albums.pickCover(["b", "a", "c"], coverOf: cover) == "a")
        #expect(Albums.pickCover(["d", "b", "a"], coverOf: cover) == "b")
        #expect(Albums.pickCover(["d"], coverOf: cover) == nil)
    }

    @Test func grouping() {
        let none: (String) -> String? = { _ in nil }
        #expect(Albums.group([("1", "Album A"), ("2", "Album A"), ("3", "Album B"), ("4", "Album B"), ("5", "Album A")],
                             coverOf: none).map { "\($0.name):\($0.ids.joined(separator: ","))" } == ["Album A:1,2,5", "Album B:3,4"])
        #expect(Albums.group([("1", "Single One"), ("2", "Session"), ("3", "Session"), ("4", "Single Two"), ("5", "")],
                             coverOf: none).map { "\($0.name):\($0.ids.joined(separator: ","))" } == ["Session:2,3", "Singles:5,4,1"])
        #expect(Albums.group([("1", "Session "), ("2", " Session"), ("1", "Session")], coverOf: none) ==
                [Albums.Album(name: "Session", ids: ["1", "2"], cover: nil)])
        #expect(Albums.group([("b", "Session"), ("a", "Session"), ("c", "Session")], coverOf: cover)[0].cover == "a")
    }
}

@Suite struct BackupTests {
    @Test func safeNamesWorkOnCards() {
        #expect(Backup.safeName("Sample Artist/Band: Live?") == "Sample Artist_Band_ Live_")
        #expect(Backup.safeName("  trailing dots... ") == "trailing dots")
        #expect(Backup.safeName("") == "Untitled")
        #expect(Backup.safeName(String(repeating: "x", count: 300)).count == 120)
    }

    @Test func backsUpOnlyWhatsNewAndNeverDeletes() throws {
        let s = try Scratch()
        let lib = s.url.appendingPathComponent("lib")
        let a = try s.file("lib/a.mp3", bytes: 1000), b = try s.file("lib/other/a.mp3", bytes: 2000), c = try s.file("lib/c.mp3", bytes: 10)
        let drive = s.url.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        func song(_ id: String, _ title: String, _ album: String, _ path: URL?) -> Backup.Song {
            Backup.Song(id: id, title: title, artist: "Test Artist", album: album, duration: 61.9, path: path)
        }
        var songs = [song("1", "Song A", "Album A", a), song("2", "Song A", "Album A", b),   // same album, title and type
                     song("3", "What?", "", c), song("4", "Gone", "Album A", lib.appendingPathComponent("gone.mp3"))]
        var progress: [Int] = []
        let first = try Backup.run(songs, drive: drive) { done, _, _ in progress.append(done) }
        let root = drive.appendingPathComponent(Backup.folderName)
        #expect(first.copied == 3 && first.bytesCopied == 3010 && first.upToDate == 0)
        #expect(first.unavailable == [Backup.Unavailable(title: "Gone", why: "no audio file on this Mac")])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Album A/Song A.mp3").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Album A/Song A (2).mp3").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Unknown Album/What_.mp3").path))
        #expect(progress == [0, 1, 2, 3])
        let m3u = try String(contentsOf: root.appendingPathComponent("Siftr.m3u8"), encoding: .utf8)
        #expect(m3u == "#EXTM3U\n#EXTINF:61,Test Artist - Song A\nAlbum A/Song A.mp3\n#EXTINF:61,Test Artist - Song A\nAlbum A/Song A (2).mp3\n#EXTINF:61,Test Artist - What?\nUnknown Album/What_.mp3\n")

        // again: nothing new; a song removed from the library stays on the drive
        songs.removeFirst()
        let second = try Backup.run(songs, drive: drive) { _, _, _ in }
        #expect(second.copied == 0 && second.upToDate == 2)
        #expect(second.notInLibraryAnymore == ["Album A/Song A.mp3"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Album A/Song A.mp3").path))
        // a changed song is copied again, under the same name as before
        try Data(repeating: 1, count: 2500).write(to: b)
        let third = try Backup.run(songs, drive: drive) { _, _, _ in }
        #expect(third.copied == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent("Album A/Song A (2).mp3")).count == 2500)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Album A/Song A (2).mp3.part").path))
    }

    @Test func aDriveBackedUpBeforeTheRenameCarriesOn() throws {
        let s = try Scratch()
        let a = try s.file("lib/a.mp3", bytes: 1000), b = try s.file("lib/b.mp3", bytes: 2000)
        let drive = s.url.appendingPathComponent("drive")
        let legacy = drive.appendingPathComponent(Backup.legacyFolderName)
        func song(_ id: String, _ path: URL) -> Backup.Song {
            Backup.Song(id: id, title: "Song \(id)", artist: "", album: "Album A", duration: 60, path: path)
        }
        // backed up once under the old name: song 1 is already there
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Album A"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: a, to: legacy.appendingPathComponent("Album A/Song 1.mp3"))
        try JSONEncoder().encode(["1": "Album A/Song 1.mp3"]).write(to: legacy.appendingPathComponent(Backup.manifestName))

        let summary = try Backup.run([song("1", a), song("2", b)], drive: drive) { _, _, _ in }
        #expect(summary.folder == legacy.path)
        #expect(summary.copied == 1 && summary.upToDate == 1)                // only the new song
        #expect(!FileManager.default.fileExists(atPath: drive.appendingPathComponent(Backup.folderName).path))
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Music Sifter.m3u8").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Siftr.m3u8").path))

        // a fresh drive gets the new name
        let fresh = s.url.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        #expect(try Backup.run([song("1", a)], drive: fresh) { _, _, _ in }.folder == fresh.appendingPathComponent("Siftr Backup").path)
    }
}

@Suite struct LibraryTablesTests {
    @Test func libraryPlaysLyricsAndTiming() throws {
        let s = try Scratch()
        let store = try LibraryStore(url: s.url.appendingPathComponent("library.db"))
        let row = LibraryStore.LibraryRow(id: "abc", path: "/m/a.mp3", title: "Song A", artist: nil, album: "Album A",
                                          duration: 61.5, size: 10, mtime: 5, added: 100, art: "h1")
        try store.saveLibrary([row, LibraryStore.LibraryRow(id: "def", path: "/m/b.mp3", title: nil, artist: nil, album: nil,
                                                            duration: 0, size: 0, mtime: 0, added: 50, art: nil)])
        #expect(store.libraryRows().map(\.id) == ["def", "abc"])      // oldest first
        #expect(store.libraryRows().last == row)
        try store.removeLibrary(ids: ["def"])
        #expect(store.libraryRows() == [row])

        try store.recordPlay(id: "abc", at: Date(timeIntervalSince1970: 1000))
        try store.recordPlay(id: "abc", at: Date(timeIntervalSince1970: 2000))
        try store.recordSkip(id: "abc")
        #expect(store.playStats()["abc"] == LibraryStore.PlayStats(plays: 2, skips: 1, lastPlayed: 2000))
        #expect(store.playLog().count == 2)

        try store.saveLyrics(id: "abc", segments: "[]", source: "whisper")
        try store.saveLyrics(id: "zzz", segments: "[]", source: "none")
        #expect(store.lyrics(id: "abc")?.source == "whisper")
        #expect(store.lyricsSources() == ["abc": "whisper", "zzz": "none"])
        #expect(store.allLyrics().map(\.id) == ["abc"])                // "none" has nothing to search
        #expect(store.timing(id: "abc") == 0)
        try store.setTiming(id: "abc", seconds: 0.3)
        #expect(store.timing(id: "abc") == 0.3)

        // written again with another model: Whisper's lyrics and "no words" go, .lrc lyrics stay
        try store.saveLyrics(id: "lrc1", segments: "[]", source: "lrc")
        #expect(try store.forgetLyrics(sources: ["whisper", "none"]) == ["abc", "zzz"])
        #expect(store.lyricsSources() == ["lrc1": "lrc"])
    }
}

@Suite struct BatchTests {
    @Test func whatCanBeSiftedAndWhatCanBeFinished() throws {
        let s = try Scratch()
        let home = s.url.appendingPathComponent("home")
        let library = home.appendingPathComponent("Music/Siftr")
        let batch = home.appendingPathComponent("Downloads/batch_1")
        for d in [library, batch] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        #expect(Batch.siftRefusal(batch, library: library, home: home) == nil)
        #expect(Batch.finishRefusal(batch, library: library, home: home) == nil)
        #expect(Batch.siftRefusal(home, library: library, home: home) != nil)                       // the whole home folder
        #expect(Batch.siftRefusal(URL(fileURLWithPath: "/"), library: library, home: home) != nil)   // a whole drive
        #expect(Batch.siftRefusal(library, library: library, home: home) != nil)                    // the library itself
        #expect(Batch.siftRefusal(library.appendingPathComponent("Album"), library: library, home: home) != nil)
        #expect(Batch.siftRefusal(home.appendingPathComponent("Music"), library: library, home: home) != nil)  // holds it
        // Downloads can be sifted, but never "finished" (thrown away)
        let downloads = home.appendingPathComponent("Downloads")
        #expect(Batch.siftRefusal(downloads, library: library, home: home) == nil)
        #expect(Batch.finishRefusal(downloads, library: library, home: home)?.contains("Mac's own folders") == true)
        #expect(Batch.finishRefusal(home.appendingPathComponent("Desktop"), library: library, home: home) != nil)
    }

    @Test func summaryChecksEveryKeptSongsCopy() throws {
        let s = try Scratch()
        let store = try LibraryStore(url: s.url.appendingPathComponent("library.db"))
        let lib = s.url.appendingPathComponent("library")
        let kept = try s.file("batch/kept.mp3", bytes: 300)
        let moved = try s.file("batch/moved.mp3", bytes: 310)
        let lost = try s.file("batch/lost.mp3", bytes: 320)
        let passed = try s.file("batch/passed.mp3", bytes: 330)
        try s.file("batch/sub/unsorted.flac", bytes: 340)
        try s.file("batch/cover.jpg", bytes: 50)
        let copy = try Keeper.copy(kept, into: lib)
        try store.record(key: songKey(for: kept), decision: .keep, title: "kept", source: kept.path, copied: copy.path)
        try store.record(key: songKey(for: moved), decision: .keep, title: "moved", source: moved.path,
                         copied: lib.appendingPathComponent("gone/moved.mp3").path)
        try store.record(key: songKey(for: lost), decision: .keep, title: "lost", source: lost.path,
                         copied: lib.appendingPathComponent("lost.mp3").path)
        try store.record(key: songKey(for: passed), decision: .pass, title: "passed", source: passed.path, copied: nil)

        let summary = Batch.summary(s.url.appendingPathComponent("batch"), store: store,
                                    libraryKeys: [songKey(for: moved)])   // moved elsewhere in the library
        #expect(summary.kept == 2 && summary.passed == 1)
        #expect(summary.unsorted == ["unsorted"])
        #expect(summary.problems == ["lost: its copy isn't in your library any more"])
        #expect(summary.bytes == 300 + 310 + 320 + 330 + 340 + 50)
    }

    @Test func movingToTheTrashStandIn() throws {
        let s = try Scratch()
        let trash = useTestTrash()
        try s.file("a batch folder/a.mp3")
        try Keeper.moveToTrash(s.url.appendingPathComponent("a batch folder"))
        #expect(!FileManager.default.fileExists(atPath: s.url.appendingPathComponent("a batch folder").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).filter { $0.hasSuffix(" a batch folder") }.count == 1)
    }
}
