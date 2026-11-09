import Foundation

/// What `ui_snapshot` recorded about one ref, so `ui_action` can check that the
/// element is still the one the caller saw (#67 phase 2). Never a guess: a ref that
/// no longer matches its record is stale.
struct UIRefRecord {
    let element: any UIElement
    /// Role and subrole as read during the snapshot. A nil role was never verified.
    let role: String?
    let subrole: String?
    /// Capped like the snapshot's title. Display only; not compared (titles change).
    let title: String?
    /// The snapshot treated the node as secure.
    let masked: Bool
    /// The root it was walked from: a window, or the menu bar.
    let root: any UIElement
    let rootRole: String?
    /// Identities from the root down to the element itself. The element's `AXWindow`,
    /// or else its nearest window, sheet, drawer or popover, must be one of these, else
    /// it left its window.
    let path: [AnyHashable]
}

/// One cached snapshot: the refs of a `ui_snapshot` result, kept for `ui_action`.
struct UICachedSnapshot {
    let id: String
    let app: UIRunningApp
    let createdAt: TimeInterval
    let records: [String: UIRefRecord]
}

/// The last few snapshots' element handles, process-wide. Bounded both ways: at most
/// `capacity` snapshots (oldest dropped first) and `ttl` seconds each, so a ref cannot
/// outlive the UI it described by much, and memory stays at most capacity × 2000 refs.
/// Not scoped per caller: both tools are `owner`-only, and owner is everything.
final class UISnapshotCache: @unchecked Sendable {
    static let defaultCapacity = 4
    static let defaultTTL: TimeInterval = 300
    static let shared = UISnapshotCache()

    let capacity: Int
    let ttl: TimeInterval
    private let lock = NSLock()
    /// Oldest first.
    private var entries: [UICachedSnapshot] = []

    init(capacity: Int = UISnapshotCache.defaultCapacity, ttl: TimeInterval = UISnapshotCache.defaultTTL) {
        self.capacity = max(1, capacity)
        self.ttl = ttl
    }

    func store(_ r: UISnapshotResult, at now: TimeInterval) {
        let entry = UICachedSnapshot(id: r.snapshot.snapshotID, app: r.snapshot.app, createdAt: now, records: r.records)
        lock.lock(); defer { lock.unlock() }
        purge(now)
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// nil when the snapshot was never taken, was evicted, or is older than `ttl`.
    func lookup(_ id: String, at now: TimeInterval) -> UICachedSnapshot? {
        lock.lock(); defer { lock.unlock() }
        purge(now)
        return entries.first { $0.id == id }
    }

    func count(at now: TimeInterval) -> Int {
        lock.lock(); defer { lock.unlock() }
        purge(now)
        return entries.count
    }

    private func purge(_ now: TimeInterval) {
        entries.removeAll { now - $0.createdAt >= ttl }
    }
}
