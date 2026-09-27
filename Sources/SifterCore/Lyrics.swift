import Foundation

/// One sung word and when it's sung (seconds into the song).
public struct LyricWord: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// One line of lyrics. `edited` marks a line someone corrected by hand.
public struct LyricLine: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [LyricWord]
    public var edited: Bool
    public init(start: Double, end: Double, text: String, words: [LyricWord], edited: Bool = false) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.edited = edited
    }
}

/// The stored form: the Python app's segment format, so transcripts look the
/// same in both databases --
/// [[start, end, text, [[word_start, word_end, word], ...], edited?], ...]
public enum LyricsFormat {
    public static func decode(_ json: String) -> [LyricLine] {
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[Any]] else { return [] }
        return rows.compactMap { row in
            guard row.count >= 4, let start = num(row[0]), let end = num(row[1]),
                  let text = row[2] as? String, let rawWords = row[3] as? [[Any]] else { return nil }
            let words = rawWords.compactMap { w -> LyricWord? in
                guard w.count >= 3, let s = num(w[0]), let e = num(w[1]), let t = w[2] as? String else { return nil }
                return LyricWord(start: s, end: e, text: t)
            }
            let edited = row.count > 4 ? (row[4] as? Bool ?? false) : false
            return LyricLine(start: start, end: end, text: text, words: words, edited: edited)
        }
    }

    public static func encode(_ lines: [LyricLine]) -> String {
        let rows: [[Any]] = lines.map { line in
            var row: [Any] = [round2(line.start), round2(line.end), line.text,
                              line.words.map { [round2($0.start), round2($0.end), $0.text] as [Any] }]
            if line.edited { row.append(true) }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func num(_ v: Any) -> Double? { (v as? NSNumber)?.doubleValue }
    public static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

/// Synced lyrics from an .lrc file beside the song ("[01:23.45] a line").
/// LRC times lines, not words, so each line's words share its time --
/// longer words get more of it -- which is close enough to light them up.
public enum LRC {
    public static func parse(_ text: String, duration: Double? = nil) -> [LyricLine] {
        var timed: [(Double, String)] = []
        var offset = 0.0
        let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("[offset:") {   // milliseconds; positive = earlier
                let v = line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)
                offset = (Double(v) ?? 0) / 1000
                continue
            }
            let ns = line as NSString
            let matches = tag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let words = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                timed.append((max(0, minutes * 60 + seconds - offset), words))
            }
        }
        timed.sort { $0.0 < $1.0 }
        var lines: [LyricLine] = []
        for (i, (start, text)) in timed.enumerated() where !text.isEmpty {
            let next = i + 1 < timed.count ? timed[i + 1].0 : (duration ?? start + 4)
            // a line holds at most ~6 s (a long instrumental gap isn't part of it)
            let end = max(start + 0.3, min(next - 0.05, start + max(2, min(6, Double(text.count) * 0.12))))
            let words = LyricEdit.spread(text.split(separator: " ").map(String.init), start, end)
            lines.append(LyricLine(start: start, end: end, text: text, words: words))
        }
        return lines
    }
}

/// Fixing a line by hand without breaking karaoke (the Python app's
/// lyrics_edit.py): the old and new versions of the line are lined up word
/// by word, unchanged words keep their exact timing, and changed or added
/// words take over the time of the words they replace.
public enum LyricEdit {
    public static let maxLineLength = 500

    static func normalize(_ word: String) -> String {
        let w = word.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'", with: "")
        return String(w.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    /// Fits words into [start, end], giving longer words more of the time.
    static func spread(_ words: [String], _ start: Double, _ end: Double) -> [LyricWord] {
        let weights = words.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        var t = start
        return zip(words, weights).map { word, weight in
            let d = total > 0 ? (end - start) * weight / total : 0
            defer { t += d }
            return LyricWord(start: LyricsFormat.round2(t), end: LyricsFormat.round2(t + d), text: word)
        }
    }

    public static func retimeLine(_ old: [LyricWord], _ newText: String, lineStart: Double, lineEnd: Double) -> [LyricWord] {
        let newWords = newText.split(separator: " ").map(String.init)
        guard !old.isEmpty else { return spread(newWords, lineStart, lineEnd) }
        let matcher = SequenceMatcher(old.map { normalize($0.text) }, newWords.map(normalize), autojunk: false)
        var timed: [LyricWord] = []
        for op in matcher.opcodes() {
            switch op.tag {
            case .equal:
                // the same word (maybe new capitals or punctuation): keep its timing
                for k in 0..<(op.j2 - op.j1) {
                    timed.append(LyricWord(start: old[op.i1 + k].start, end: old[op.i1 + k].end, text: newWords[op.j1 + k]))
                }
            case .replace, .insert:
                let start: Double, end: Double
                if op.i2 > op.i1 {           // replaced words take over the old ones' time
                    start = old[op.i1].start
                    end = old[op.i2 - 1].end
                } else {                     // inserted words fit the gap between neighbours
                    start = op.i1 > 0 ? old[op.i1 - 1].end : lineStart
                    end = max(op.i1 < old.count ? old[op.i1].start : lineEnd, start)
                }
                timed += spread(Array(newWords[op.j1..<op.j2]), start, end)
            case .delete:
                break                        // the old words simply drop out
            }
        }
        return timed
    }

    /// The lines with one corrected (re-timed and marked edited), or removed
    /// if the new text is blank.
    public static func apply(_ lines: [LyricLine], line index: Int, text newText: String) -> [LyricLine] {
        guard lines.indices.contains(index) else { return lines }
        var out = lines
        let clean = newText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if clean.isEmpty {
            out.remove(at: index)
            return out
        }
        let old = lines[index]
        let words = retimeLine(old.words, String(clean.prefix(maxLineLength)), lineStart: old.start, lineEnd: old.end)
        guard let first = words.first, let last = words.last else { return lines }
        out[index] = LyricLine(start: first.start, end: last.end, text: clean, words: words, edited: true)
        return out
    }
}

/// Forgiving search through lyrics (the Python app's lyrics_search.py):
/// case and punctuation ignored, any word order, the last word can be
/// partial, near-miss spellings count, a phrase can straddle two lines, and
/// with 3+ words one can be wrong.
public enum LyricSearch {
    public static let minScore = 0.6
    static let exact = 1.0, prefix = 0.9, fuzzy = 0.75

    public struct Song: Sendable {
        public let id: String, title: String, artist: String
        public let lines: [LyricLine]
        public init(id: String, title: String, artist: String, lines: [LyricLine]) {
            self.id = id
            self.title = title
            self.artist = artist
            self.lines = lines
        }
    }

    public struct Hit: Codable, Sendable, Equatable {
        public let time: Double
        public let text: String
        public let hits: [String]
    }

    public struct Result: Codable, Sendable {
        public let id: String, title: String, artist: String
        public let score: Double
        public let lines: [Hit]
    }

    public static func normalize(_ text: String) -> [String] {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'", with: "")
        var words: [String] = []
        var current = ""
        for scalar in t.unicodeScalars {
            if scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    public static func search(_ songs: [Song], query: String, limit: Int = 25) -> [Result] {
        let queryWords = normalize(query)
        guard !queryWords.isEmpty else { return [] }
        let prepared = songs.map { song in
            (song, song.lines.map { ($0.start, $0.text, normalize($0.text)) })
        }
        var vocab = Set<String>()
        for (_, lines) in prepared { for line in lines { vocab.formUnion(line.2) } }

        // per query word: {transcript word -> weight}, worked out once
        let variants: [[String: Double]] = queryWords.enumerated().map { i, q in
            let isLast = i == queryWords.count - 1
            var matches: [String: Double] = [:]
            for w in vocab {
                if w == q {
                    matches[w] = exact
                } else if isLast && q.count >= 3 && w.hasPrefix(q) {
                    matches[w] = prefix
                } else if q.count >= 4 && abs(w.count - q.count) <= 2 && SequenceMatcher(q, w).ratio() >= 0.8 {
                    matches[w] = fuzzy
                }
            }
            return matches
        }
        let phrase = queryWords.joined(separator: " ")

        func score(_ tokens: [String]) -> (Double, Set<String>) {
            let tokenSet = Set(tokens)
            var total = 0.0
            var hits = Set<String>()
            for matches in variants {
                let found = tokenSet.filter { matches[$0] != nil }
                if let best = found.map({ matches[$0]! }).max() {
                    total += best
                    hits.formUnion(found)
                }
            }
            var s = total / Double(variants.count)
            if tokens.joined(separator: " ").contains(phrase) { s += 0.25 }   // together, in order
            return (s, hits)
        }

        var results: [Result] = []
        for (song, lines) in prepared {
            var best: [Int: (Double, Int, Hit)] = [:]
            for i in lines.indices {
                for span in [1, 2] where i + span <= lines.count {   // a phrase can straddle two lines
                    let window = lines[i..<(i + span)]
                    var (s, hits) = score(window.flatMap { $0.2 })
                    if span == 2 { s -= 0.05 }                      // prefer a one-line match
                    if s >= minScore && s > (best[i]?.0 ?? 0) {
                        let text = window.map { $0.1 }.joined(separator: " / ")
                        best[i] = (s, span, Hit(time: window.first!.0, text: text, hits: hits.sorted()))
                    }
                }
            }
            guard !best.isEmpty else { continue }
            // best first; on a tie, the earlier line (as Python's stable sort does)
            let ranked = best.sorted { $0.value.0 != $1.value.0 ? $0.value.0 > $1.value.0 : $0.key < $1.key }
            var picked: [Hit] = []
            var used = Set<Int>()
            for (i, (_, span, hit)) in ranked {
                let covers = Set(i..<(i + span))
                if !covers.isDisjoint(with: used) { continue }       // don't show the same lyric twice
                picked.append(hit)
                used.formUnion(covers)
                if picked.count == 2 { break }
            }
            results.append(Result(id: song.id, title: song.title.trimmingCharacters(in: .whitespaces), artist: song.artist,
                                  score: (ranked[0].value.0 * 1000).rounded() / 1000, lines: picked))
        }
        results.sort { $0.score != $1.score ? $0.score > $1.score : $0.title.lowercased() < $1.title.lowercased() }
        return Array(results.prefix(limit))
    }
}
