import Foundation

/// The queue of songs still to judge and which one is current -- the
/// original's queue/index rules, kept free of any UI so they can be tested.
public struct SifterQueue: Sendable {
    public private(set) var items: [URL] = []
    public private(set) var index = 0

    public init(_ items: [URL] = []) { self.items = items }

    public var current: URL? { items.indices.contains(index) ? items[index] : nil }
    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public func contains(_ url: URL) -> Bool { items.contains(url) }

    /// Keep and Pass take the song out; Skip sends it to the back. Either way
    /// the song now at the same position becomes current (clamped to the last).
    public mutating func judgeCurrent(_ decision: Decision) {
        guard let url = current else { return }
        items.remove(at: index)
        if decision == .skip { items.append(url) }
        if index >= items.count { index = max(0, items.count - 1) }
    }

    /// Next / previous without judging. Returns false at either end.
    public mutating func next() -> Bool {
        guard index < items.count - 1 else { return false }
        index += 1
        return true
    }

    public mutating func previous() -> Bool {
        guard index > 0 else { return false }
        index -= 1
        return true
    }

    public mutating func jump(to i: Int) -> Bool {
        guard items.indices.contains(i) else { return false }
        index = i
        return true
    }

    /// Takes out a song that isn't necessarily current; the current song
    /// stays current.
    public mutating func remove(_ url: URL) {
        guard let i = items.firstIndex(of: url) else { return }
        if i == index { return judgeCurrent(.pass) }
        items.remove(at: i)
        if i < index { index -= 1 }
    }

    /// Undo puts a song back where the listener is, as the current song.
    public mutating func reinsertAtCurrent(_ url: URL) {
        if items.isEmpty { index = 0 }
        items.insert(url, at: min(index, items.count))
    }
}
