import Foundation
import GlintCore
import GlintDictionary

private struct InputCase: Decodable {
    let id: String
    let target: String
    let kind: String
}

private struct ChoicesOutput: Encodable {
    struct Entry: Encodable {
        let target: String
        let kind: String
        let choices: [String]
    }

    let generatedAt: String
    let entries: [String: Entry]
}

@main
struct DictionaryChoices {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard let casesIndex = arguments.firstIndex(of: "--cases"),
              arguments.indices.contains(casesIndex + 1),
              let outputIndex = arguments.firstIndex(of: "--output"),
              arguments.indices.contains(outputIndex + 1) else {
            fputs(
                "usage: DictionaryChoices --cases <json> --output <json>\n",
                stderr
            )
            exit(2)
        }

        let casesURL = URL(fileURLWithPath: arguments[casesIndex + 1])
        let outputURL = URL(fileURLWithPath: arguments[outputIndex + 1])
        let data = try Data(contentsOf: casesURL)
        let cases = try JSONDecoder().decode([InputCase].self, from: data)
        let dictionary = DictionaryRouter(
            routes: [
                DictionaryRoute(
                    id: "dict-cedict",
                    priority: 0,
                    engine: CedictDictionary()
                ),
                DictionaryRoute(
                    id: "dict-ecdict",
                    priority: 1,
                    engine: ECDICTDictionary()
                ),
            ],
            blocked: ["打", "尼", "你号"]
        )

        var entries: [String: ChoicesOutput.Entry] = [:]
        for item in cases {
            let kind = CandidateKind(rawValue: item.kind) ?? .unknown
            let result = try await dictionary.lookup(
                Candidate(text: item.target, kind: kind)
            )
            entries[item.id] = ChoicesOutput.Entry(
                target: item.target,
                kind: item.kind,
                choices: result.map {
                    Array($0.options.prefix(6)).map(\.text)
                } ?? []
            )
        }

        let formatter = ISO8601DateFormatter()
        let output = ChoicesOutput(
            generatedAt: formatter.string(from: Date()),
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output).write(
            to: outputURL,
            options: .atomic
        )
    }
}
