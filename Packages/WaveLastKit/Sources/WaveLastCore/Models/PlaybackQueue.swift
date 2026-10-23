// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one
}

/// A queue entry. Entries have their own identity so the same track can be
/// queued twice and still be moved or removed individually.
public struct QueueEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var track: Track

    public init(id: UUID = UUID(), track: Track) {
        self.id = id
        self.track = track
    }
}

/// The play queue: pure value type, no audio. All mutations keep
/// `currentIndex` pointing at the same entry the user is listening to.
public struct PlaybackQueue: Codable, Equatable, Sendable {
    public private(set) var entries: [QueueEntry] = []
    /// Index into `entries` of the current entry, or nil when nothing is selected.
    public private(set) var currentIndex: Int?
    public var repeatMode: RepeatMode = .off
    public private(set) var isShuffled = false
    /// Entry order before shuffle, so turning shuffle off restores it.
    private var unshuffledOrder: [UUID]?

    public init() {}

    public init(tracks: [Track], startAt index: Int = 0) {
        entries = tracks.map { QueueEntry(track: $0) }
        currentIndex = entries.indices.contains(index) ? index : (entries.isEmpty ? nil : 0)
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var current: QueueEntry? { currentIndex.map { entries[$0] } }
    /// Entries after the current one, in play order.
    public var upNext: ArraySlice<QueueEntry> {
        guard let i = currentIndex else { return entries[...] }
        return entries[(i + 1)...]
    }

    // MARK: Replacing

    public mutating func replace(with tracks: [Track], startAt index: Int = 0) {
        let mode = repeatMode
        self = PlaybackQueue(tracks: tracks, startAt: index)
        repeatMode = mode
    }

    public mutating func clear() {
        entries.removeAll()
        currentIndex = nil
        isShuffled = false
        unshuffledOrder = nil
    }

    // MARK: Adding

    /// Appends to the end of the queue.
    @discardableResult
    public mutating func append(_ tracks: [Track]) -> [QueueEntry] {
        let new = tracks.map { QueueEntry(track: $0) }
        entries.append(contentsOf: new)
        unshuffledOrder?.append(contentsOf: new.map(\.id))
        if currentIndex == nil, !entries.isEmpty { currentIndex = 0 }
        return new
    }

    /// Inserts directly after the current entry ("Play Next").
    @discardableResult
    public mutating func playNext(_ tracks: [Track]) -> [QueueEntry] {
        let new = tracks.map { QueueEntry(track: $0) }
        let insertAt = (currentIndex.map { $0 + 1 }) ?? entries.count
        entries.insert(contentsOf: new, at: insertAt)
        if var order = unshuffledOrder {
            // Keep the same "right after current" position in the unshuffled order.
            let anchor = current.flatMap { c in order.firstIndex(of: c.id) }.map { $0 + 1 } ?? order.count
            order.insert(contentsOf: new.map(\.id), at: anchor)
            unshuffledOrder = order
        }
        if currentIndex == nil, !entries.isEmpty { currentIndex = 0 }
        return new
    }

    // MARK: Removing / moving

    /// Removes entries. If the current entry is removed, the next entry becomes
    /// current (or the previous one when it was last).
    public mutating func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let currentID = current?.id
        // If the current entry goes, the first surviving entry after it
        // becomes current; failing that, the last surviving entry before it.
        var fallbackID: UUID?
        if let i = currentIndex, let id = currentID, ids.contains(id) {
            fallbackID =
                entries[(i + 1)...].first { !ids.contains($0.id) }?.id
                ?? entries[..<i].last { !ids.contains($0.id) }?.id
        }
        entries.removeAll { ids.contains($0.id) }
        unshuffledOrder?.removeAll { ids.contains($0) }

        if entries.isEmpty {
            currentIndex = nil
        } else if let target = fallbackID ?? currentID {
            currentIndex = entries.firstIndex { $0.id == target }
        }
    }

    public mutating func remove(atOffsets offsets: IndexSet) {
        remove(ids: Set(offsets.compactMap { entries.indices.contains($0) ? entries[$0].id : nil }))
    }

    /// Moves entries using SwiftUI `onMove` semantics.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let currentID = current?.id
        let moving = source.sorted().filter { entries.indices.contains($0) }.map { entries[$0] }
        guard !moving.isEmpty else { return }
        let movingIDs = Set(moving.map(\.id))
        let before = source.filter { $0 < destination }.count
        entries.removeAll { movingIDs.contains($0.id) }
        let insertAt = max(0, min(entries.count, destination - before))
        entries.insert(contentsOf: moving, at: insertAt)
        if let currentID { currentIndex = entries.firstIndex { $0.id == currentID } }
    }

    // MARK: Navigation

    /// Selects an entry directly (user tapped it).
    public mutating func select(id: UUID) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        currentIndex = i
        return true
    }

    /// The index `advance()` would move to, without changing state.
    public func nextIndex(userInitiated: Bool) -> Int? {
        guard let i = currentIndex, !entries.isEmpty else { return nil }
        if repeatMode == .one && !userInitiated { return i }
        if i + 1 < entries.count { return i + 1 }
        return repeatMode == .off ? nil : 0
    }

    /// Moves to the next entry. Returns false at the end of a non-repeating queue.
    /// `userInitiated` skips ignore repeat-one (pressing Next always moves on).
    @discardableResult
    public mutating func advance(userInitiated: Bool = false) -> Bool {
        guard let n = nextIndex(userInitiated: userInitiated) else { return false }
        currentIndex = n
        return true
    }

    /// Moves to the previous entry; wraps when repeating all.
    @discardableResult
    public mutating func goBack() -> Bool {
        guard let i = currentIndex, !entries.isEmpty else { return false }
        if i > 0 {
            currentIndex = i - 1
            return true
        }
        if repeatMode == .all {
            currentIndex = entries.count - 1
            return true
        }
        return false
    }

    // MARK: Shuffle

    /// Shuffles everything after the current entry. The current entry stays
    /// first so playback is not interrupted.
    public mutating func setShuffle<G: RandomNumberGenerator>(_ on: Bool, using rng: inout G) {
        guard on != isShuffled else { return }
        if on {
            unshuffledOrder = entries.map(\.id)
            if let i = currentIndex {
                let cur = entries[i]
                var rest = entries
                rest.remove(at: i)
                rest.shuffle(using: &rng)
                entries = [cur] + rest
                currentIndex = 0
            } else {
                entries.shuffle(using: &rng)
            }
            isShuffled = true
        } else {
            if let order = unshuffledOrder {
                let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
                let currentID = current?.id
                var restored = order.compactMap { byID[$0] }
                // Anything not in the saved order (should not happen) goes last.
                let known = Set(order)
                restored.append(contentsOf: entries.filter { !known.contains($0.id) })
                entries = restored
                if let currentID { currentIndex = entries.firstIndex { $0.id == currentID } }
            }
            unshuffledOrder = nil
            isShuffled = false
        }
    }

    public mutating func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffle(on, using: &rng)
    }
}
