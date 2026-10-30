import Foundation

public struct EvaluationCase: Decodable, Equatable, Sendable {
    public let text: String
    public let category: String
    public let expected: [String]
    public let forbidden: [String]

    public init(
        text: String,
        category: String,
        expected: [String],
        forbidden: [String] = []
    ) {
        self.text = text
        self.category = category
        self.expected = expected
        self.forbidden = forbidden
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case category
        case expected
        case forbidden
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        text = try container.decode(String.self, forKey: .text)
        category = try container.decode(
            String.self,
            forKey: .category
        )
        expected = try container.decode(
            [String].self,
            forKey: .expected
        )
        forbidden =
            try container.decodeIfPresent(
                [String].self,
                forKey: .forbidden
            ) ?? []
    }

    public static func load(paths: [String]) throws -> [EvaluationCase] {
        var casesByText: [String: EvaluationCase] = [:]
        var order: [String] = []

        for path in paths {
            let data = try Data(
                contentsOf: URL(fileURLWithPath: path)
            )
            let decoded = try JSONDecoder().decode(
                [EvaluationCase].self,
                from: data
            )
            for item in decoded where !item.expected.isEmpty {
                if let existing = casesByText[item.text] {
                    let expected = Array(
                        Set(existing.expected + item.expected)
                    ).sorted()
                    let forbidden = Array(
                        Set(existing.forbidden + item.forbidden)
                    ).sorted()
                    casesByText[item.text] = EvaluationCase(
                        text: existing.text,
                        category: existing.category,
                        expected: expected,
                        forbidden: forbidden
                    )
                } else {
                    order.append(item.text)
                    casesByText[item.text] = item
                }
            }
        }

        return order.compactMap { casesByText[$0] }
    }
}
