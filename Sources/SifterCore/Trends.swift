import Foundation

/// A calendar day, for "this week" arithmetic that never trips over time zones.
public struct Day: Hashable, Comparable, Sendable {
    public let ordinal: Int   // days since 1970-01-01

    public init(ordinal: Int) { self.ordinal = ordinal }

    public init(year: Int, month: Int, day: Int) {
        // days-from-civil (proleptic Gregorian)
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        ordinal = era * 146_097 + doe - 719_468
    }

    /// The local calendar day `date` falls on.
    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public var components: (year: Int, month: Int, day: Int) {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    public var iso: String {
        let c = components
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    /// "Sep 3"
    public var shortLabel: String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let c = components
        return "\(months[c.month - 1]) \(c.day)"
    }

    public func adding(_ days: Int) -> Day { Day(ordinal: ordinal + days) }
    public static func - (a: Day, b: Day) -> Int { a.ordinal - b.ordinal }
    public static func < (a: Day, b: Day) -> Bool { a.ordinal < b.ordinal }
}

/// Listening trends for the Trends page -- the Python app's trends.py, fed by
/// this app's own play log. Plain calculation over data passed in, so it's
/// testable with made-up histories.
public enum Trends {
    public static let sectionSize = 8

    public struct Track: Sendable {
        public let id: String, title: String, artist: String
        public let plays: Int, skips: Int
        public let duration: Double
        public let lastPlayed: Day?
        public let added: Day?
        public init(id: String, title: String, artist: String, plays: Int, skips: Int, duration: Double,
                    lastPlayed: Day?, added: Day?) {
            self.id = id
            self.title = title
            self.artist = artist
            self.plays = plays
            self.skips = skips
            self.duration = duration
            self.lastPlayed = lastPlayed
            self.added = added
        }
    }

    public struct Song: Codable, Sendable, Equatable {
        public let id: String, title: String, artist: String, detail: String
    }

    public struct Era: Codable, Sendable, Equatable {
        public let album: String
        public let plays: Int
        public let seconds: Double
        public let songs: Int
    }

    public struct History: Codable, Sendable {
        public var window: String?
        public var recordingSince: String?
        public var daysRecorded: Int?
        public var plays: Int?
        public var seconds: Double?
        public var mostPlayed: [Song]?
        public var heatingUp: [Song]?
        public var coolingOff: [Song]?
        public var comparisonUnlocks: String?
    }

    public struct Result: Codable, Sendable {
        public let history: History
        public let forgottenFavorites: [Song]
        public let skipMagnets: [Song]
        public let eras: [Era]
        public let freshAdds: [Song]
    }

    /// "1 play", "3 plays"
    static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    static func ago(_ days: Int) -> String {
        days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    }

    static func song(_ t: Track, _ detail: String) -> Song {
        Song(id: t.id, title: t.title, artist: t.artist, detail: detail)
    }

    /// Songs in your top quarter by plays that you haven't played in a month.
    public static func forgottenFavorites(_ tracks: [Track], today: Day, idleDays: Int = 30) -> [Song] {
        guard !tracks.isEmpty else { return [] }
        let byPlays = tracks.map(\.plays).sorted()
        let topQuarter = max(byPlays[Int(Double(byPlays.count) * 0.75)], 1)
        let picks: [(Int, Song)] = tracks.compactMap { t in
            guard let last = t.lastPlayed, t.plays >= topQuarter else { return nil }
            let idle = today - last
            guard idle >= idleDays else { return nil }
            return (t.plays, song(t, "\(count(t.plays, "play")) · last played \(ago(idle))"))
        }
        return Array(stableSorted(picks) { $0.0 > $1.0 }.map(\.1).prefix(sectionSize))
    }

    /// Songs skipped a lot compared with how often they're finished.
    public static func skipMagnets(_ tracks: [Track], minSkips: Int = 3, minRate: Double = 0.4) -> [Song] {
        let picks: [(Double, Int, Song)] = tracks.compactMap { t in
            let total = t.plays + t.skips
            guard t.skips >= minSkips, total > 0 else { return nil }
            let rate = Double(t.skips) / Double(total)
            guard rate >= minRate else { return nil }
            return (rate, t.skips, song(t, "\(count(t.skips, "skip")) vs \(count(t.plays, "play")) (\(String(format: "%.0f", rate * 100))% skipped)"))
        }
        return Array(stableSorted(picks) { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 > $1.1 }.map(\.2).prefix(sectionSize))
    }

    /// Listening time by album -- which eras you actually play.
    public static func eras(_ tracks: [Track], albums: [String: String], limit: Int = 10) -> [Era] {
        var order: [String] = []
        var groups: [String: (plays: Int, seconds: Double, songs: Int)] = [:]
        for t in tracks {
            let name = albums[t.id].flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown album"
            if groups[name] == nil { order.append(name); groups[name] = (0, 0, 0) }
            groups[name]!.plays += t.plays
            groups[name]!.seconds += Double(t.plays) * t.duration
            groups[name]!.songs += 1
        }
        let rows = order.map { Era(album: $0, plays: groups[$0]!.plays, seconds: groups[$0]!.seconds, songs: groups[$0]!.songs) }
        return Array(stableSorted(rows) { $0.seconds > $1.seconds }.prefix(limit))
    }

    /// How the songs added in the last month are doing.
    public static func freshAdds(_ tracks: [Track], today: Day, withinDays: Int = 30) -> [Song] {
        let picks: [(Int, Int, Song)] = tracks.compactMap { t in
            guard let added = t.added else { return nil }
            let age = today - added
            guard age <= withinDays else { return nil }
            return (t.plays, age, song(t, "added \(ago(age)) · \(count(t.plays, "play"))"))
        }
        return Array(stableSorted(picks) { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2).prefix(sectionSize))
    }

    /// How many plays a song had at the start of `day` (see trends.py).
    static func plays(at day: Day, _ t: Track, _ snapshots: [Day: [String: Int]], _ days: [Day]) -> Int? {
        if let n = snapshots[day]?[t.id] { return n }
        if let added = t.added, added >= day { return 0 }
        for later in days where later > day {
            if let n = snapshots[later]?[t.id] { return n }
        }
        return nil
    }

    /// Plays and listening time over the last week, plus heating up /
    /// cooling off once there are two weeks to compare.
    public static func history(_ tracks: [Track], snapshots: [Day: [String: Int]], today: Day,
                               daysRecorded: Int? = nil) -> History {
        guard !snapshots.isEmpty else { return History() }
        let days = snapshots.keys.sorted()
        let weekAgo = today.adding(-7)
        let baseDay = days.last(where: { $0 <= weekAgo }) ?? days[0]
        var h = History()
        h.window = baseDay == today ? "today" : baseDay <= weekAgo ? "this week" : "since \(baseDay.shortLabel)"

        var byID: [String: Track] = [:]
        var ids: [String] = []
        for t in tracks {
            if byID[t.id] == nil { ids.append(t.id) }
            byID[t.id] = t
        }
        let start = Dictionary(uniqueKeysWithValues: ids.map { ($0, plays(at: baseDay, byID[$0]!, snapshots, days)) })
        let gainedIDs = ids.filter { start[$0]! != nil }
        let gained = Dictionary(uniqueKeysWithValues: gainedIDs.map { ($0, byID[$0]!.plays - start[$0]!!) })
        let top = stableSorted(gainedIDs.filter { gained[$0]! > 0 }) { gained[$0]! > gained[$1]! }
        h.recordingSince = days[0].iso
        h.daysRecorded = daysRecorded ?? days.count
        h.plays = gainedIDs.reduce(0) { $0 + max(0, gained[$1]!) }
        h.seconds = gainedIDs.reduce(0.0) { gained[$1]! > 0 ? $0 + Double(gained[$1]!) * byID[$1]!.duration : $0 }
        h.mostPlayed = top.prefix(sectionSize).map { song(byID[$0]!, "+\(count(gained[$0]!, "play"))") }

        let twoWeeksAgo = today.adding(-14)
        guard let earlierDay = days.last(where: { $0 <= twoWeeksAgo }), baseDay <= weekAgo else {
            h.comparisonUnlocks = days[0].adding(14).iso
            return h
        }
        let earlier = Dictionary(uniqueKeysWithValues: ids.map { ($0, plays(at: earlierDay, byID[$0]!, snapshots, days)) })
        let comparable = ids.filter { start[$0]! != nil && earlier[$0]! != nil }
        let thisWeek = Dictionary(uniqueKeysWithValues: comparable.map { ($0, byID[$0]!.plays - start[$0]!!) })
        let lastWeek = Dictionary(uniqueKeysWithValues: comparable.map { ($0, start[$0]!! - earlier[$0]!!) })
        func compare(_ id: String) -> String { "\(count(thisWeek[id]!, "play")) this week vs \(lastWeek[id]!) the week before" }
        let heating = stableSorted(comparable.filter { thisWeek[$0]! >= 3 && thisWeek[$0]! > lastWeek[$0]! }) {
            thisWeek[$0]! - lastWeek[$0]! > thisWeek[$1]! - lastWeek[$1]!
        }
        let cooling = stableSorted(comparable.filter { lastWeek[$0]! >= 3 && lastWeek[$0]! > thisWeek[$0]! }) {
            lastWeek[$0]! - thisWeek[$0]! > lastWeek[$1]! - thisWeek[$1]!
        }
        h.heatingUp = heating.prefix(sectionSize).map { song(byID[$0]!, compare($0)) }
        h.coolingOff = cooling.prefix(sectionSize).map { song(byID[$0]!, compare($0)) }
        return h
    }

    public static func all(_ tracks: [Track], albums: [String: String], snapshots: [Day: [String: Int]],
                           today: Day, daysRecorded: Int? = nil) -> Result {
        Result(history: history(tracks, snapshots: snapshots, today: today, daysRecorded: daysRecorded),
               forgottenFavorites: forgottenFavorites(tracks, today: today),
               skipMagnets: skipMagnets(tracks),
               eras: eras(tracks, albums: albums),
               freshAdds: freshAdds(tracks, today: today))
    }

    /// The play log turned into what history() reads: {day: {song: plays
    /// before that day}} for the first day, two weeks ago, a week ago and
    /// today, plus how many days the log covers (library.py's play_history).
    public static func playHistory(added: [String: Day?], plays: [(String, Day)], today: Day) -> ([Day: [String: Int]], Int) {
        let starts = added.values.compactMap { $0 } + plays.map(\.1)
        guard let first = starts.min() else { return ([:], 0) }
        var days: Set<Day> = [first]
        for n in [14, 7, 0] { days.insert(max(first, today.adding(-n))) }
        var history: [Day: [String: Int]] = [:]
        for day in days {
            var counts: [String: Int] = [:]
            for (id, when) in added { if let when, when <= day { counts[id] = 0 } }
            for (id, played) in plays where played < day {
                if counts[id] != nil { counts[id]! += 1 }
            }
            history[day] = counts
        }
        return (history, (today - first) + 1)
    }

    /// Sorts like Python's sorted(): ties keep their original order.
    static func stableSorted<T>(_ items: [T], by before: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            before(a.element, b.element) ? true : before(b.element, a.element) ? false : a.offset < b.offset
        }.map(\.element)
    }
}

/// Groups the library into albums for the Albums view (the Python app's
/// albums.py): newest album first, one-song albums gathered into "Singles".
public enum Albums {
    public static let singles = "Singles"

    public struct Album: Codable, Sendable, Equatable {
        public let name: String
        public let ids: [String]
        public let cover: String?
    }

    /// The song whose cover the album shows: the first whose cover appears
    /// more than once (a one-off is often a variant), else the first with any.
    public static func pickCover(_ ids: [String], coverOf: (String) -> String?) -> String? {
        let covers = ids.map { ($0, coverOf($0)) }
        var counts: [String: Int] = [:]
        for (_, c) in covers { if let c { counts[c, default: 0] += 1 } }
        if let shared = covers.first(where: { $0.1 != nil && counts[$0.1!]! > 1 }) { return shared.0 }
        return covers.first(where: { $0.1 != nil })?.0
    }

    /// tracks: (song id, album tag), oldest first.
    public static func group(_ tracks: [(id: String, album: String?)], coverOf: (String) -> String?) -> [Album] {
        var songsByAlbum: [String: [String]] = [:]
        var newest: [String: Int] = [:]
        var seen = Set<String>()
        for (position, t) in tracks.enumerated() where !seen.contains(t.id) {
            seen.insert(t.id)
            let name = (t.album ?? "").trimmingCharacters(in: .whitespaces)
            songsByAlbum[name, default: []].append(t.id)
            newest[name] = position
        }
        var albums: [Album] = []
        var singleIDs: [String] = []
        for name in songsByAlbum.keys.sorted(by: { newest[$0]! > newest[$1]! }) {
            let ids = songsByAlbum[name]!
            if !name.isEmpty && ids.count > 1 {
                albums.append(Album(name: name, ids: ids, cover: pickCover(ids, coverOf: coverOf)))
            } else {
                singleIDs += ids
            }
        }
        if !singleIDs.isEmpty {
            albums.append(Album(name: singles, ids: singleIDs, cover: pickCover(singleIDs, coverOf: coverOf)))
        }
        return albums
    }
}
