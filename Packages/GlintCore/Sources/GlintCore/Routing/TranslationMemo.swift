import Foundation

public struct TranslationMemoKey: Hashable, Sendable {
    public let text: String
    public let mode: TranslationMode
    public let configuration: String

    public init(
        text: String,
        mode: TranslationMode,
        configuration: String
    ) {
        self.text = text
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = mode
        self.configuration = configuration
    }
}

/// Exact-result, memory-only translation memoization with request coalescing.
public actor TranslationMemo {
    private struct Entry {
        let result: TranslationResult
        let cost: Int
    }

    private let capacity: Int
    private let maximumCost: Int
    private var entries: [TranslationMemoKey: Entry] = [:]
    private var recency: [TranslationMemoKey] = []
    private var inFlight: [
        TranslationMemoKey: Task<TranslationResult?, Error>
    ] = [:]
    private var totalCost = 0

    public init(
        capacity: Int = 512,
        maximumCost: Int = 4 * 1_024 * 1_024
    ) {
        self.capacity = max(0, capacity)
        self.maximumCost = max(0, maximumCost)
    }

    public func resolve(
        for key: TranslationMemoKey,
        operation: @escaping @Sendable () async throws -> TranslationResult?
    ) async throws -> TranslationResult? {
        guard !key.text.isEmpty else {
            return try await operation()
        }
        if let result = cachedResult(for: key) {
            return result
        }
        if let task = inFlight[key] {
            return try await waitForTask(task, key: key)
        }

        let task = Task.detached(priority: .userInitiated) {
            try await operation()
        }
        inFlight[key] = task

        do {
            let result = try await waitForTask(task, key: key)
            if let result,
               !result.displayText.trimmingCharacters(
                    in: .whitespacesAndNewlines
               ).isEmpty {
                store(result, for: key)
            }
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    public func clear() {
        entries.removeAll()
        recency.removeAll()
        totalCost = 0
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
    }

    private func waitForTask(
        _ task: Task<TranslationResult?, Error>,
        key: TranslationMemoKey
    ) async throws -> TranslationResult? {
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            inFlight[key] = nil
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    private func cachedResult(
        for key: TranslationMemoKey
    ) -> TranslationResult? {
        guard let entry = entries[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.result
    }

    private func store(
        _ result: TranslationResult,
        for key: TranslationMemoKey
    ) {
        guard capacity > 0, maximumCost > 0 else { return }
        if let old = entries.removeValue(forKey: key) {
            totalCost -= old.cost
            recency.removeAll { $0 == key }
        }

        let cost = key.text.utf8.count
            + result.displayText.utf8.count
            + 64
        guard cost <= maximumCost else { return }

        entries[key] = Entry(result: result, cost: cost)
        recency.append(key)
        totalCost += cost

        while entries.count > capacity
            || totalCost > maximumCost
            || recency.count > capacity {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalCost -= removed.cost
            }
        }
    }
}
