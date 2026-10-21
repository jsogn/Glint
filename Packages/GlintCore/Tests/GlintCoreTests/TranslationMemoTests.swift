import XCTest
@testable import GlintCore

final class TranslationMemoTests: XCTestCase {
    private actor Counter {
        private(set) var value = 0

        func increment() -> Int {
            value += 1
            return value
        }
    }

    func testExactResultIsCached() async throws {
        let memo = TranslationMemo()
        let counter = Counter()
        let key = TranslationMemoKey(
            text: "你好",
            mode: .dictionaryFirst,
            configuration: "model-a"
        )

        let first = try await memo.resolve(for: key) {
            _ = await counter.increment()
            return TranslationResult(
                text: "hello",
                source: .dictionary,
                confidence: 0.9
            )
        }
        let second = try await memo.resolve(for: key) {
            _ = await counter.increment()
            return TranslationResult(
                text: "unexpected",
                source: .translation,
                confidence: 0.5
            )
        }

        XCTAssertEqual(first?.text, "hello")
        XCTAssertEqual(second?.text, "hello")
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testConfigurationChangesBypassCachedResult() async throws {
        let memo = TranslationMemo()
        let counter = Counter()

        for configuration in ["model-a", "model-b"] {
            _ = try await memo.resolve(
                for: TranslationMemoKey(
                    text: "你好",
                    mode: .dictionaryFirst,
                    configuration: configuration
                )
            ) {
                let value = await counter.increment()
                return TranslationResult(
                    text: "result-\(value)",
                    source: .translation,
                    confidence: 0.9
                )
            }
        }

        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    func testConcurrentRequestsAreCoalesced() async throws {
        let memo = TranslationMemo()
        let counter = Counter()
        let key = TranslationMemoKey(
            text: "今天天气不错",
            mode: .dictionaryFirst,
            configuration: "model-a"
        )

        async let first = memo.resolve(for: key) {
            _ = await counter.increment()
            try await Task.sleep(nanoseconds: 30_000_000)
            return TranslationResult(
                text: "It's a nice day.",
                source: .translation,
                confidence: 0.9
            )
        }
        async let second = memo.resolve(for: key) {
            _ = await counter.increment()
            return TranslationResult(
                text: "unexpected",
                source: .translation,
                confidence: 0.5
            )
        }

        let firstResult = try await first
        let secondResult = try await second

        XCTAssertNotNil(firstResult)
        XCTAssertEqual(firstResult, secondResult)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testLRUEvictionKeepsNewestEntry() async throws {
        let memo = TranslationMemo(capacity: 1)
        let counter = Counter()

        for text in ["你好", "再见"] {
            _ = try await memo.resolve(
                for: TranslationMemoKey(
                    text: text,
                    mode: .dictionaryFirst,
                    configuration: "model-a"
                )
            ) {
                let value = await counter.increment()
                return TranslationResult(
                    text: "result-\(value)",
                    source: .dictionary,
                    confidence: 0.9
                )
            }
        }

        _ = try await memo.resolve(
            for: TranslationMemoKey(
                text: "你好",
                mode: .dictionaryFirst,
                configuration: "model-a"
            )
        ) {
            let value = await counter.increment()
            return TranslationResult(
                text: "result-\(value)",
                source: .dictionary,
                confidence: 0.9
            )
        }

        let count = await counter.value
        XCTAssertEqual(count, 3)
    }
}
