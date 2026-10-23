import Foundation

public struct TranslationMemoKey: Hashable, Sendable {
    public let text: String
    public let mode: TranslationMode
    public let configuration: String
    public let includesAlternatives: Bool

    public init(
        text: String,
        mode: TranslationMode,
        configuration: String,
        includesAlternatives: Bool = true
    ) {
        self.text = text
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = mode
        self.configuration = configuration
        self.includesAlternatives = includesAlternatives
    }
}

private struct LRUCache<Key: Hashable, Value> {
    private struct Node {
        let key: Key
        let value: Value
        let cost: Int
        var previous: Key?
        var next: Key?
    }

    private let capacity: Int
    private let maximumCost: Int
    private var nodes: [Key: Node] = [:]
    private var oldest: Key?
    private var newest: Key?
    private var totalCost = 0
    private(set) var evictionCount = 0

    init(capacity: Int, maximumCost: Int) {
        self.capacity = max(0, capacity)
        self.maximumCost = max(0, maximumCost)
    }

    var count: Int { nodes.count }
    var estimatedBytes: Int { totalCost }

    mutating func value(for key: Key) -> Value? {
        guard let value = nodes[key]?.value else { return nil }
        moveToNewest(key)
        return value
    }

    @discardableResult
    mutating func insert(
        _ value: Value,
        for key: Key,
        cost: Int
    ) -> Bool {
        guard capacity > 0,
            maximumCost > 0,
            cost > 0,
            cost <= maximumCost
        else {
            return false
        }
        if nodes[key] != nil {
            remove(key)
        }

        let node = Node(
            key: key,
            value: value,
            cost: cost,
            previous: newest,
            next: nil
        )
        nodes[key] = node
        if let newest {
            nodes[newest]?.next = key
        } else {
            oldest = key
        }
        newest = key
        totalCost += cost

        while nodes.count > capacity || totalCost > maximumCost {
            guard let evicted = oldest else { break }
            remove(evicted)
            evictionCount += 1
        }
        return nodes[key] != nil
    }

    @discardableResult
    mutating func remove(_ key: Key) -> Value? {
        guard let node = nodes.removeValue(forKey: key) else {
            return nil
        }
        if let previous = node.previous {
            nodes[previous]?.next = node.next
        } else {
            oldest = node.next
        }
        if let next = node.next {
            nodes[next]?.previous = node.previous
        } else {
            newest = node.previous
        }
        totalCost -= node.cost
        return node.value
    }

    mutating func removeAll() {
        nodes.removeAll(keepingCapacity: false)
        oldest = nil
        newest = nil
        totalCost = 0
        evictionCount = 0
    }

    private mutating func moveToNewest(_ key: Key) {
        guard newest != key,
            let node = nodes[key]
        else {
            return
        }
        if let previous = node.previous {
            nodes[previous]?.next = node.next
        } else {
            oldest = node.next
        }
        if let next = node.next {
            nodes[next]?.previous = node.previous
        } else {
            newest = node.previous
        }

        let previousNewest = newest
        nodes[key]?.previous = previousNewest
        nodes[key]?.next = nil
        if let previousNewest {
            nodes[previousNewest]?.next = key
        }
        newest = key
        if oldest == nil {
            oldest = key
        }
    }
}

public struct TranslationMemoStatistics: Sendable, Equatable {
    public let entries: Int
    public let estimatedBytes: Int
    public let maximumEntries: Int
    public let maximumEstimatedBytes: Int
    public let hits: Int
    public let misses: Int
    public let inFlightHits: Int
    public let insertions: Int
    public let evictions: Int
    public let rejectedEntries: Int
}

/// Exact-result, memory-only translation memoization with request coalescing.
public actor TranslationMemo {
    private final class WaiterLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var didDetach = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didDetach else { return false }
            didDetach = true
            return true
        }
    }

    private struct InFlightRequest {
        let task: Task<TranslationResult?, Error>
        var waiterCount: Int
    }

    private let capacity: Int
    private let maximumCost: Int
    private var cache: LRUCache<TranslationMemoKey, TranslationResult>
    private var inFlight: [TranslationMemoKey: InFlightRequest] = [:]
    private var hitCount = 0
    private var missCount = 0
    private var inFlightHitCount = 0
    private var insertionCount = 0
    private var rejectedEntryCount = 0

    public init(
        capacity: Int = 2_048,
        maximumCost: Int = 16 * 1_024 * 1_024
    ) {
        let capacity = max(0, capacity)
        let maximumCost = max(0, maximumCost)
        self.capacity = capacity
        self.maximumCost = maximumCost
        self.cache = LRUCache(
            capacity: capacity,
            maximumCost: maximumCost
        )
    }

    public func resolve(
        for key: TranslationMemoKey,
        operation: @escaping @Sendable () async throws -> TranslationResult?
    ) async throws -> TranslationResult? {
        try Task.checkCancellation()
        guard !key.text.isEmpty else {
            return try await operation()
        }
        if let result = cache.value(for: key) {
            hitCount += 1
            return result
        }
        if var request = inFlight[key] {
            inFlightHitCount += 1
            request.waiterCount += 1
            inFlight[key] = request
            return try await waitForTask(request.task, key: key)
        }

        missCount += 1
        let task = Task.detached(priority: .userInitiated) {
            try await operation()
        }
        inFlight[key] = InFlightRequest(task: task, waiterCount: 1)

        let result = try await waitForTask(task, key: key)
        if let result,
            !result.displayText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            cache.value(for: key) == nil
        {
            store(result, for: key)
        }
        return result
    }

    public func peek(for key: TranslationMemoKey) -> TranslationResult? {
        if let result = cache.value(for: key) {
            hitCount += 1
            return result
        }
        return nil
    }

    public func statistics() -> TranslationMemoStatistics {
        TranslationMemoStatistics(
            entries: cache.count,
            estimatedBytes: cache.estimatedBytes,
            maximumEntries: capacity,
            maximumEstimatedBytes: maximumCost,
            hits: hitCount,
            misses: missCount,
            inFlightHits: inFlightHitCount,
            insertions: insertionCount,
            evictions: cache.evictionCount,
            rejectedEntries: rejectedEntryCount
        )
    }

    public func clear() {
        cache.removeAll()
        for request in inFlight.values {
            request.task.cancel()
        }
        inFlight.removeAll()
        hitCount = 0
        missCount = 0
        inFlightHitCount = 0
        insertionCount = 0
        rejectedEntryCount = 0
    }

    private func waitForTask(
        _ task: Task<TranslationResult?, Error>,
        key: TranslationMemoKey
    ) async throws -> TranslationResult? {
        let latch = WaiterLatch()
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task {
                    await self.detachWaiter(for: key, latch: latch)
                }
            }
            detachWaiter(for: key, latch: latch)
            return result
        } catch {
            detachWaiter(for: key, latch: latch)
            throw error
        }
    }

    private func detachWaiter(
        for key: TranslationMemoKey,
        latch: WaiterLatch
    ) {
        guard latch.claim() else { return }
        guard var request = inFlight[key] else { return }
        request.waiterCount -= 1
        if request.waiterCount <= 0 {
            request.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = request
        }
    }

    private func store(
        _ result: TranslationResult,
        for key: TranslationMemoKey
    ) {
        let cost = Self.estimatedCost(for: key, result: result)
        guard cost <= maximumCost else {
            rejectedEntryCount += 1
            return
        }
        if cache.insert(result, for: key, cost: cost) {
            insertionCount += 1
        } else {
            rejectedEntryCount += 1
        }
    }

    private static func estimatedCost(
        for key: TranslationMemoKey,
        result: TranslationResult
    ) -> Int {
        let keyBytes =
            key.text.utf8.count
            + key.configuration.utf8.count
            + 96
        let optionBytes = result.options.reduce(0) { partial, option in
            partial + option.text.utf8.count + 32
        }
        return keyBytes + optionBytes
    }
}
