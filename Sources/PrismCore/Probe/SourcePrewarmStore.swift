import Foundation

/// Source bytes fetched ahead of a play, held in memory until they are
/// evicted or discarded.
///
/// A reader that adopts an entry copies its blocks and leaves it here, so a
/// second open of the same source (a retry, a reopen after a failed start)
/// adopts it too, after its own confirmation. That costs the copy's worth of
/// memory while both are alive; the capacity below is what bounds it.
///
/// Process-wide on purpose: the host prewarms from its browsing UI and plays
/// from a session built seconds later, and nothing but the URL and headers
/// connects the two. The key is exactly those — the transport identity of a
/// request — and the **validator** rides in the entry rather than the key,
/// because it is the one part of the identity only the origin can state, and
/// the origin is asked again before any of these bytes is delivered (see
/// `HTTPRangeInput.adoptPrewarm`).
///
/// Two bounds, both hard, because every byte here is speculative and a tvOS
/// host is one allocation away from Jetsam (3.2.2): a byte `capacity` across
/// all entries, evicting least-recently-prewarmed first, and a memory-pressure
/// source that drops everything on the first warning. Dropping is always safe
/// — a reader that finds nothing reads the network, exactly as it does for a
/// source nobody prewarmed.
final class SourcePrewarmStore: @unchecked Sendable {

    /// Eight sources at the default 2 MB per-source budget: the next episode,
    /// a row of items under the cursor. Deliberately small — a
    /// prewarm buys one startup's worth of round trips, not a cache.
    static let defaultCapacity = 16 << 20

    static let shared = SourcePrewarmStore(capacity: defaultCapacity, observesMemoryPressure: true)

    struct Key: Hashable {
        let url: String
        let headers: [String: String]

        init(url: URL, headers: [String: String]) {
            // The URL's full spelling, query included: a signed URL whose
            // token changed is a different request, and possibly a different
            // authorisation, even when it names the same file.
            self.url = url.absoluteString
            self.headers = headers
        }
    }

    struct Block {
        let start: Int64
        let data: Data
    }

    struct Entry {
        /// The strong `ETag` the origin reported on every response the blocks
        /// came from. Never optional, and never a `Last-Modified` date: bytes
        /// that cannot be bound to one representation are not stored at all
        /// (see `HTTPRangeInput.strongETag(of:)`).
        let validator: String
        let length: Int64
        /// Disjoint ranges, head first. The head always starts at byte 0.
        let blocks: [Block]
        var bytes: Int { blocks.reduce(0) { $0 + $1.data.count } }
    }

    let capacity: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// Least recently stored or looked up first.
    private var order: [Key] = []
    private var pressureSource: DispatchSourceMemoryPressure?

    init(capacity: Int, observesMemoryPressure: Bool = false) {
        self.capacity = max(0, capacity)
        if observesMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: DispatchQueue(label: "cz.zmrhal.prismcore.prewarm.pressure", qos: .utility)
            )
            source.setEventHandler { [weak self] in self?.handleMemoryPressure() }
            source.activate()
            pressureSource = source
        }
    }

    deinit { pressureSource?.cancel() }

    var residentBytes: Int { lock.withLock { entries.values.reduce(0) { $0 + $1.bytes } } }

    /// Store `entry`, evicting older ones until it fits. Returns `false` —
    /// storing nothing — for an entry larger than the whole capacity, rather
    /// than emptying the store for something that still would not fit.
    @discardableResult
    func insert(_ entry: Entry, for key: Key) -> Bool {
        let size = entry.bytes
        guard size <= capacity else { return false }
        lock.withLock {
            removeLocked(key)
            var resident = entries.values.reduce(0) { $0 + $1.bytes }
            while resident + size > capacity, let oldest = order.first {
                resident -= entries[oldest]?.bytes ?? 0
                removeLocked(oldest)
            }
            entries[key] = entry
            order.append(key)
        }
        return true
    }

    func entry(for key: Key) -> Entry? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return entry
        }
    }

    func remove(_ key: Key) { lock.withLock { removeLocked(key) } }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            order.removeAll()
        }
    }

    /// Everything goes, on the first warning. A partial trim would keep bytes
    /// whose only value is a faster start of something the user may never
    /// play, at the moment the system is deciding what to kill.
    func handleMemoryPressure() {
        let dropped = residentBytes
        removeAll()
        if dropped > 0 {
            PrismCoreLog.notice("memory pressure: discarded \(dropped) prewarmed source bytes")
        }
    }

    private func removeLocked(_ key: Key) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }
}
