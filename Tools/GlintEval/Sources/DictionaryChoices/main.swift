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
            arguments.indices.contains(outputIndex + 1)
        else {
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
        var routes = [
            DictionaryRoute(
                id: "dict-cedict",
                priority: 0,
                role: .authoritative,
                engine: CedictDictionary()
            ),
            DictionaryRoute(
                id: "dict-ecdict",
                priority: 1,
                role: .fallback,
                engine: ECDICTDictionary()
            ),
        ]
        if let wiktionaryIndex = arguments.firstIndex(
            of: "--wiktionary-db"
        ), arguments.indices.contains(wiktionaryIndex + 1) {
            let databaseURL = URL(
                fileURLWithPath: arguments[wiktionaryIndex + 1]
            )
            if let engine = GenericSQLiteDictionary(
                databaseURL: databaseURL,
                sourceLanguage: "zh-Hans",
                targetLanguage: "en"
            ) {
                routes.append(
                    DictionaryRoute(
                        id: "dict-wiktionary-zh-en",
                        priority: 10,
                        role: .fallback,
                        engine: engine
                    )
                )
            }
        }
        let dictionary = DictionaryRouter(routes: routes)

        var entries: [String: ChoicesOutput.Entry] = [:]
        for item in cases {
            let kind = CandidateKind(rawValue: item.kind) ?? .unknown
            let result = await dictionary.lookup(
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
