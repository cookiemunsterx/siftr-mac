import Foundation

/// Python's difflib.SequenceMatcher (Ratcliff/Obershelp), ported so lyric
/// search and lyric editing line things up exactly the way the Python app
/// does: ratio() for near-miss spellings, opcodes() for re-timing an edited
/// line word by word.
public struct SequenceMatcher<Element: Hashable> {
    public enum Tag: String, Sendable { case equal, replace, delete, insert }
    public struct Opcode: Equatable, Sendable {
        public let tag: Tag
        public let i1: Int, i2: Int, j1: Int, j2: Int
    }

    private let a: [Element]
    private let b: [Element]
    private var b2j: [Element: [Int]] = [:]

    public init(_ a: [Element], _ b: [Element], autojunk: Bool = true) {
        self.a = a
        self.b = b
        for (j, element) in b.enumerated() { b2j[element, default: []].append(j) }
        // difflib's "autojunk": in long sequences, elements that make up more
        // than 1% of b are treated as noise when looking for matches
        if autojunk && b.count >= 200 {
            let popular = b.count / 100 + 1
            for (element, positions) in b2j where positions.count > popular { b2j[element] = nil }
        }
    }

    private func longestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (i: Int, j: Int, size: Int) {
        var (besti, bestj, bestsize) = (alo, blo, 0)
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var next: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                next[j] = k
                if k > bestsize { (besti, bestj, bestsize) = (i - k + 1, j - k + 1, k) }
            }
            j2len = next
        }
        // extend over equal elements the index skipped (the "popular" ones)
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
            besti -= 1; bestj -= 1; bestsize += 1
        }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return (besti, bestj, bestsize)
    }

    /// (i, j, n): a[i..<i+n] == b[j..<j+n], in order, ending with (count, count, 0).
    public func matchingBlocks() -> [(Int, Int, Int)] {
        var queue = [(0, a.count, 0, b.count)]
        var blocks: [(Int, Int, Int)] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longestMatch(alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            blocks.append((i, j, k))
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        blocks.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        // merge blocks that touch
        var merged: [(Int, Int, Int)] = []
        var (i1, j1, k1) = (0, 0, 0)
        for (i2, j2, k2) in blocks {
            if i1 + k1 == i2 && j1 + k1 == j2 {
                k1 += k2
            } else {
                if k1 > 0 { merged.append((i1, j1, k1)) }
                (i1, j1, k1) = (i2, j2, k2)
            }
        }
        if k1 > 0 { merged.append((i1, j1, k1)) }
        merged.append((a.count, b.count, 0))
        return merged
    }

    public func opcodes() -> [Opcode] {
        var i = 0, j = 0
        var out: [Opcode] = []
        for (ai, bj, size) in matchingBlocks() {
            let tag: Tag? = i < ai && j < bj ? .replace : i < ai ? .delete : j < bj ? .insert : nil
            if let tag { out.append(Opcode(tag: tag, i1: i, i2: ai, j1: j, j2: bj)) }
            i = ai + size
            j = bj + size
            if size > 0 { out.append(Opcode(tag: .equal, i1: ai, i2: i, j1: bj, j2: j)) }
        }
        return out
    }

    /// 2 * matches / total length: 1.0 identical, 0.0 nothing in common.
    public func ratio() -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 1 }
        let matches = matchingBlocks().reduce(0) { $0 + $1.2 }
        return 2 * Double(matches) / Double(total)
    }
}

extension SequenceMatcher where Element == Character {
    public init(_ a: String, _ b: String, autojunk: Bool = true) {
        self.init(Array(a), Array(b), autojunk: autojunk)
    }
}
