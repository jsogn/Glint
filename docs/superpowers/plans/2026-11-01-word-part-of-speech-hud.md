# Word Part-of-Speech HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在“选中”模式 HUD 中为可靠的单词译项显示最多两个标准英文词性缩写，同时保持单行、隐私、插入和朗读行为不变。

**Architecture:** ECDICT builder 逐条解析 `translation` 释义行开头的词性标签，按英文词构建全局词性索引。任何翻译来源得到最终英文单词后，由 `SmartRouter` 统一查询并补充词性；宽度不足时先移除词性。

**Tech Stack:** Swift 6、SwiftUI、AppKit、SQLite3、XCTest、Swift Package Manager、XcodeGen。

**Spec:** `docs/superpowers/specs/2026-11-01-word-part-of-speech-hud-design.md`

## Global Constraints

- 最低系统为 macOS 15，第一版仅支持 Apple Silicon arm64。
- 固定 ECDICT revision 为 `9c46923fb81a2eb6c264a3a1689562ea7bc56b6a`，源 CSV SHA256 为 `d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc`。
- 当前 ECDICT `pos` 比例列为空，禁止依赖该列或重新引入比例阈值。
- 词性只在“选中”模式显示；“一栏”模式不得显示。
- “显示与触发”提供持久化开关，默认开启。
- 最多显示两个词性，按释义行首次出现顺序择取，再按固定顺序显示。
- 视觉顺序固定为 `n.`、`v.`、`adj.`、`adv.`、`prep.`、`pron.`、`conj.`、`det.`、`num.`、`interj.`。
- 视觉只使用英文缩写，不使用中文词性名称。
- 只处理不含空白的英文单词；短语、句子和多词译项不显示词性。
- 不根据模型、词尾或上下文猜测词性。
- 词性不得进入英文译文正文、插入内容、朗读内容、日志或持久化候选数据。
- HUD 保持单行和现有高度；宽度不足时先移除全部词性。
- 不新增第三方依赖、网络请求、键盘监听、OCR、截图或候选持久化。
- 不在未获用户明确授权时 commit、push、创建 PR 或创建线程。
- 每个任务开始前运行 `git status --short --branch`，不使用 `git reset --hard` 或覆盖用户改动。

---

## File Structure

### GlintCore

- Create `Packages/GlintCore/Sources/GlintCore/Domain/PartOfSpeech.swift`
- Modify `Packages/GlintCore/Sources/GlintCore/Domain/Candidate.swift`
- Modify `Packages/GlintCore/Sources/GlintCore/Routing/TranslationMemo.swift`
- Create `Packages/GlintCore/Tests/GlintCoreTests/PartOfSpeechTests.swift`
- Modify `Packages/GlintCore/Tests/GlintCoreTests/TranslationResultTests.swift`
- Modify `Packages/GlintCore/Tests/GlintCoreTests/TranslationMemoTests.swift`
- Modify `Packages/GlintCore/Tests/GlintCoreTests/SmartRouterTests.swift`

### GlintDictionary

- Create `Packages/GlintDictionary/Sources/GlintDictionary/ECDICTPartOfSpeech.swift`
- Modify `Packages/GlintDictionary/Sources/GlintDictionary/ECDICTRankBuilder.swift`
- Modify `Packages/GlintDictionary/Sources/GlintDictionary/ECDICTRanker.swift`
- Modify `Packages/GlintDictionary/Sources/GlintDictionary/CedictDictionary.swift`
- Modify `Packages/GlintDictionary/Sources/GlintDictionary/ECDICTDictionary.swift`
- Modify `Packages/GlintDictionary/Sources/GlintDictionary/GenericSQLiteDictionary.swift`
- Modify `Packages/GlintDictionary/Sources/GlintDictionaryBuilder/main.swift`
- Create `Packages/GlintDictionary/Tests/GlintDictionaryTests/ECDICTPartOfSpeechTests.swift`
- Modify `Packages/GlintDictionary/Tests/GlintDictionaryTests/ECDICTRankBuilderTests.swift`
- Modify `Packages/GlintDictionary/Tests/GlintDictionaryTests/CedictDictionaryTests.swift`
- Modify `Packages/GlintDictionary/Tests/GlintDictionaryTests/GenericSQLiteDictionaryTests.swift`

### GlintPlugins

- Modify `Packages/GlintPlugins/Sources/GlintPlugins/Manager/ECDICTUpdateService.swift`
- Modify `Packages/GlintPlugins/Tests/GlintPluginsTests/ECDICTUpdateServiceTests.swift`

### GlintMac

- Modify `Packages/GlintMac/Sources/GlintMac/MonitoringController.swift`
- Modify `Packages/GlintMac/Sources/GlintMac/CandidateTranslationPipeline.swift`
- Modify `Packages/GlintMac/Tests/GlintMacTests/GlintMacTests.swift`

### GlintUI and App

- Modify `Packages/GlintUI/Sources/GlintUI/HUD/HUDView.swift`
- Modify `Packages/GlintUI/Sources/GlintUI/HUD/HUDLayoutPlan.swift`
- Modify `Packages/GlintUI/Sources/GlintUI/HUD/HUDGeometryResolver.swift`
- Modify `Packages/GlintUI/Tests/GlintUITests/HUDLayoutTests.swift`
- Modify `App/Glint/HUDEventCoordinator.swift`

### Resources and Documentation

- Modify `Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3`
- Modify `Resources/Plugins/dict-ecdict/manifest.json`
- Modify `AGENTS.md`
- Modify `docs/ARCHITECTURE.md`
- Modify `docs/DICTIONARY-SOURCES.md`

---

### Task 1: Core Part-of-Speech Metadata

**Files:**
- Create: `Packages/GlintCore/Sources/GlintCore/Domain/PartOfSpeech.swift`
- Modify: `Packages/GlintCore/Sources/GlintCore/Domain/Candidate.swift`
- Modify: `Packages/GlintCore/Sources/GlintCore/Routing/TranslationMemo.swift`
- Create: `Packages/GlintCore/Tests/GlintCoreTests/PartOfSpeechTests.swift`
- Modify: `Packages/GlintCore/Tests/GlintCoreTests/TranslationResultTests.swift`
- Modify: `Packages/GlintCore/Tests/GlintCoreTests/TranslationMemoTests.swift`

**Interfaces:**
- Consumes: existing `TranslationOption(text:score:)`.
- Produces: `PartOfSpeech`, `PartOfSpeech.abbreviation`, `PartOfSpeech.accessibilityName`, `PartOfSpeech.normalized(_:)`, and `TranslationOption.partsOfSpeech`.

- [ ] **Step 1: Write failing domain tests**

Create `PartOfSpeechTests.swift`:

```swift
import XCTest
@testable import GlintCore

final class PartOfSpeechTests: XCTestCase {
    func testCanonicalOrderDeduplicatesAndLimitsToTwo() {
        XCTAssertEqual(
            PartOfSpeech.normalized([
                .verb, .adjective, .noun, .verb,
            ]),
            [.noun, .verb]
        )
    }

    func testAccessibilityNamesAndDictionaryTokens() {
        XCTAssertEqual(
            PartOfSpeech.preposition.accessibilityName,
            "preposition"
        )
        XCTAssertEqual(PartOfSpeech("prep."), .preposition)
        XCTAssertEqual(PartOfSpeech("ADJECTIVE"), .adjective)
        XCTAssertNil(PartOfSpeech("unknown"))
    }
}
```

Append to `TranslationResultTests.swift`:

```swift
func testEquivalentSurfacesMergePartsOfSpeech() {
    let result = TranslationResult(options: [
        TranslationOption(
            text: "design",
            score: 0.9,
            partsOfSpeech: [.verb]
        ),
        TranslationOption(
            text: "Design",
            score: 0.5,
            partsOfSpeech: [.noun, .verb]
        ),
    ])

    XCTAssertEqual(result.options.count, 1)
    XCTAssertEqual(result.text, "design")
    XCTAssertEqual(result.options[0].partsOfSpeech, [.noun, .verb])
}

func testPrimaryOnlyKeepsPartsOfSpeech() {
    let result = TranslationResult(options: [
        TranslationOption(
            text: "design",
            score: 0.9,
            partsOfSpeech: [.noun, .verb]
        ),
        TranslationOption(text: "plan", score: 0.8),
    ])

    XCTAssertEqual(
        result.primaryOnly.options.first?.partsOfSpeech,
        [.noun, .verb]
    )
}
```

Append to `TranslationMemoTests.swift`:

```swift
func testCachePreservesAndAccountsForPartsOfSpeech() async throws {
    let memo = TranslationMemo()
    let memoWithoutPOS = TranslationMemo()
    let key = TranslationMemoKey(
        text: "设计",
        mode: .dictionaryFirst,
        configuration: "model-a"
    )

    _ = try await memoWithoutPOS.resolve(for: key) {
        TranslationResult(text: "design")
    }
    _ = try await memo.resolve(for: key) {
        TranslationResult(options: [
            TranslationOption(
                text: "design",
                score: 1,
                partsOfSpeech: [.noun, .verb]
            )
        ])
    }
    let cached = try await memo.resolve(for: key) {
        TranslationResult(text: "unexpected")
    }

    XCTAssertEqual(cached?.text, "design")
    XCTAssertEqual(cached?.options.first?.partsOfSpeech, [.noun, .verb])
    let withPOS = await memo.statistics()
    let withoutPOS = await memoWithoutPOS.statistics()
    XCTAssertGreaterThan(
        withPOS.estimatedBytes,
        withoutPOS.estimatedBytes
    )
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
swift test --package-path Packages/GlintCore --filter PartOfSpeechTests
swift test --package-path Packages/GlintCore --filter TranslationResultTests
swift test --package-path Packages/GlintCore --filter TranslationMemoTests
```

Expected: compilation fails because `PartOfSpeech` and `partsOfSpeech` do not exist.

- [ ] **Step 3: Implement the domain model**

Create `PartOfSpeech.swift`:

```swift
public enum PartOfSpeech:
    String, CaseIterable, Sendable, Equatable, Hashable
{
    case noun
    case verb
    case adjective
    case adverb
    case preposition
    case pronoun
    case conjunction
    case determiner
    case numeral
    case interjection

    public var abbreviation: String {
        switch self {
        case .noun: "n."
        case .verb: "v."
        case .adjective: "adj."
        case .adverb: "adv."
        case .preposition: "prep."
        case .pronoun: "pron."
        case .conjunction: "conj."
        case .determiner: "det."
        case .numeral: "num."
        case .interjection: "interj."
        }
    }

    public var accessibilityName: String {
        rawValue
    }

    public init?(_ token: String) {
        let value = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "n", "n.", "noun": self = .noun
        case "v", "v.", "verb": self = .verb
        case "adj", "adj.", "adjective": self = .adjective
        case "adv", "adv.", "adverb": self = .adverb
        case "prep", "prep.", "preposition": self = .preposition
        case "pron", "pron.", "pronoun": self = .pronoun
        case "conj", "conj.", "conjunction": self = .conjunction
        case "det", "det.", "determiner": self = .determiner
        case "num", "num.", "numeral": self = .numeral
        case "interj", "interj.", "interjection": self = .interjection
        default: return nil
        }
    }

    public static func normalized(
        _ values: [PartOfSpeech],
        limit: Int = 2
    ) -> [PartOfSpeech] {
        Array(
            allCases
                .filter(values.contains)
                .prefix(max(0, limit))
        )
    }
}
```

Modify `TranslationOption`:

```swift
public struct TranslationOption: Sendable, Equatable {
    public let text: String
    public let score: Double
    public let partsOfSpeech: [PartOfSpeech]

    public init(
        text: String,
        score: Double,
        partsOfSpeech: [PartOfSpeech] = []
    ) {
        self.text = text
        self.score = score.isFinite ? score : 0
        self.partsOfSpeech = PartOfSpeech.normalized(partsOfSpeech)
    }
}
```

Replace `TranslationResult.init(options:)` deduplication with:

```swift
public init(options: [TranslationOption]) {
    let sorted = options
        .filter { !$0.text.isEmpty }
        .sorted {
            $0.score == $1.score
                ? $0.text < $1.text
                : $0.score > $1.score
        }
    var indexes: [String: Int] = [:]
    var merged: [TranslationOption] = []
    for option in sorted {
        let key = Self.dedupeKey(option.text)
        if let index = indexes[key] {
            let existing = merged[index]
            merged[index] = TranslationOption(
                text: existing.text,
                score: existing.score,
                partsOfSpeech:
                    existing.partsOfSpeech + option.partsOfSpeech
            )
        } else {
            indexes[key] = merged.count
            merged.append(option)
        }
    }
    self.options = merged
}
```

Update `TranslationMemo.estimatedCost(for:result:)`:

```swift
let optionBytes = result.options.reduce(0) { partial, option in
    partial
        + option.text.utf8.count
        + option.partsOfSpeech.reduce(0) {
            $0 + $1.abbreviation.utf8.count
        }
        + 32
}
```

- [ ] **Step 4: Run focused and full core tests**

```bash
swift test --package-path Packages/GlintCore --filter PartOfSpeechTests
swift test --package-path Packages/GlintCore --filter TranslationResultTests
swift test --package-path Packages/GlintCore --filter TranslationMemoTests
swift test --package-path Packages/GlintCore
```

Expected: all commands pass.

- [ ] **Step 5: Commit checkpoint**

Only if explicitly authorized:

```bash
git add Packages/GlintCore
git commit -m "Add part-of-speech translation metadata"
```

Otherwise leave changes uncommitted.

---

### Task 2: Parse ECDICT Definition-Line Labels

**Files:**
- Create: `Packages/GlintDictionary/Sources/GlintDictionary/ECDICTPartOfSpeech.swift`
- Create: `Packages/GlintDictionary/Tests/GlintDictionaryTests/ECDICTPartOfSpeechTests.swift`

**Interfaces:**
- Consumes: `PartOfSpeech` from Task 1.
- Produces: `ECDICTPartOfSpeech.parseLine(_:)`, `select(_:)`, `encode(_:)`, and `decode(_:)`.

- [ ] **Step 1: Write failing parser tests**

Create `ECDICTPartOfSpeechTests.swift`:

```swift
import XCTest
@testable import GlintDictionary
import GlintCore

final class ECDICTPartOfSpeechTests: XCTestCase {
    func testParsesCommonDefinitionLabels() {
        XCTAssertEqual(
            ECDICTPartOfSpeech.parseLine("n. 设计, 图样").partOfSpeech,
            .noun
        )
        XCTAssertEqual(
            ECDICTPartOfSpeech.parseLine("vt. 打开, 公开").partOfSpeech,
            .verb
        )
        XCTAssertEqual(
            ECDICTPartOfSpeech.parseLine("a. 开着的").partOfSpeech,
            .adjective
        )
        XCTAssertEqual(
            ECDICTPartOfSpeech.parseLine("prep. 关于").partOfSpeech,
            .preposition
        )
    }

    func testUnknownAndUnlabelledLinesKeepBody() {
        let unknown = ECDICTPartOfSpeech.parseLine(
            "abbr. 缩写"
        )
        XCTAssertNil(unknown.partOfSpeech)
        XCTAssertEqual(unknown.body, "缩写")

        let plain = ECDICTPartOfSpeech.parseLine("[计] 打开指令")
        XCTAssertNil(plain.partOfSpeech)
        XCTAssertEqual(plain.body, "[计] 打开指令")
    }

    func testSelectionUsesFirstTwoThenCanonicalOrder() {
        XCTAssertEqual(
            ECDICTPartOfSpeech.select([.verb, .noun]),
            [.noun, .verb]
        )
        XCTAssertEqual(
            ECDICTPartOfSpeech.select([.verb, .noun, .adjective]),
            [.noun, .verb]
        )
    }

    func testEncodingRoundTripIsCompactAndStable() {
        let encoded = ECDICTPartOfSpeech.encode([.adjective, .noun])
        XCTAssertEqual(encoded, "noun/adjective")
        XCTAssertEqual(
            ECDICTPartOfSpeech.decode(encoded),
            [.noun, .adjective]
        )
        XCTAssertEqual(ECDICTPartOfSpeech.decode(""), [])
        XCTAssertEqual(ECDICTPartOfSpeech.decode("bad"), [])
    }
}
```

- [ ] **Step 2: Run parser tests and verify failure**

```bash
swift test --package-path Packages/GlintDictionary --filter ECDICTPartOfSpeechTests
```

Expected: compilation fails because `ECDICTPartOfSpeech` does not exist.

- [ ] **Step 3: Implement line parser and serializer**

Create `ECDICTPartOfSpeech.swift`:

```swift
import Foundation
import GlintCore

enum ECDICTPartOfSpeech {
    struct ParsedLine: Equatable {
        let body: String
        let partOfSpeech: PartOfSpeech?
    }

    static func parseLine(_ value: String) -> ParsedLine {
        let line = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let dot = line.firstIndex(of: ".") else {
            return ParsedLine(body: line, partOfSpeech: nil)
        }
        let prefix = line[..<dot]
        guard !prefix.isEmpty,
              prefix.allSatisfy({ $0.isLetter })
        else {
            return ParsedLine(body: line, partOfSpeech: nil)
        }
        let part = map(String(prefix).lowercased())
        let bodyStart = line.index(after: dot)
        let body = line[bodyStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedLine(body: body, partOfSpeech: part)
    }

    static func select(_ values: [PartOfSpeech]) -> [PartOfSpeech] {
        var unique: [PartOfSpeech] = []
        for value in values where !unique.contains(value) {
            unique.append(value)
            if unique.count == 2 { break }
        }
        return PartOfSpeech.normalized(unique)
    }

    static func encode(_ values: [PartOfSpeech]) -> String {
        select(values).map(\.rawValue).joined(separator: "/")
    }

    static func decode(_ value: String) -> [PartOfSpeech] {
        select(
            value.split(separator: "/").compactMap {
                PartOfSpeech(String($0))
            }
        )
    }

    private static func map(_ code: String) -> PartOfSpeech? {
        switch code {
        case "n": .noun
        case "v", "vt", "vi", "aux": .verb
        case "a", "adj": .adjective
        case "adv", "ad": .adverb
        case "prep": .preposition
        case "pron": .pronoun
        case "conj": .conjunction
        case "det": .determiner
        case "num": .numeral
        case "int", "interj": .interjection
        default: nil
        }
    }
}
```

- [ ] **Step 4: Run parser tests**

```bash
swift test --package-path Packages/GlintDictionary --filter ECDICTPartOfSpeechTests
```

Expected: all parser tests pass.

- [ ] **Step 5: Commit checkpoint**

Only if explicitly authorized:

```bash
git add Packages/GlintDictionary/Sources/GlintDictionary/ECDICTPartOfSpeech.swift \
  Packages/GlintDictionary/Tests/GlintDictionaryTests/ECDICTPartOfSpeechTests.swift
git commit -m "Parse ECDICT part-of-speech definition prefixes"
```

Otherwise leave changes uncommitted.

---

### Task 3: Build the Global English POS Index

**Files:**
- Modify: `Packages/GlintDictionary/Sources/GlintDictionary/ECDICTRankBuilder.swift`
- Modify: `Packages/GlintDictionary/Sources/GlintDictionary/ECDICTRanker.swift`
- Modify: `Packages/GlintDictionary/Sources/GlintDictionaryBuilder/main.swift`
- Modify: `Packages/GlintDictionary/Tests/GlintDictionaryTests/ECDICTRankBuilderTests.swift`
- Modify: `Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3`
- Modify: `Resources/Plugins/dict-ecdict/manifest.json`

**Interfaces:**
- Consumes: `ECDICTPartOfSpeech` from Task 2.
- Produces: `ECDICTRankSummary.posCount`, `english_parts_of_speech`, and `PartOfSpeechProviding`.

- [ ] **Step 1: Add failing builder and ranker tests**

Append to `ECDICTRankBuilderTests.swift`:

```swift
func testBuildsGlobalEnglishPartsOfSpeech() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("ecdict.csv")
    let database = directory.appendingPathComponent("rank.sqlite3")
    try Data(
        """
        word,phonetic,definition,translation,pos,collins,oxford,tag,bnc,frq,exchange,detail,audio
        design,,,"n. 设计\\nv. 计划",,5,1,,,100,,
        convenient,,,"a. 方便",,4,1,,,120,,
        user,,,"n. 用户",,4,1,,,200,,
        """.utf8
    ).write(to: source)

    let summary = try ECDICTRankBuilder.build(
        fromCSVURL: source,
        to: database
    )
    XCTAssertEqual(summary.posCount, 3)

    let ranker = ECDICTRanker(databaseURL: database)
    XCTAssertEqual(
        await ranker.partsOfSpeech(forEnglish: "design"),
        [.noun, .verb]
    )
    XCTAssertEqual(
        await ranker.partsOfSpeech(forEnglish: "convenient"),
        [.adjective]
    )
    XCTAssertEqual(
        await ranker.partsOfSpeech(forEnglish: "user"),
        [.noun]
    )

    let schema = try databaseSchema(at: database)
    XCTAssertEqual(schema.userVersion, 4)
    XCTAssertTrue(
        schema.englishPOSDefinition.contains("english_parts_of_speech")
    )
}
```

Extend the existing `databaseSchema(at:)` helper tuple with
`englishPOSDefinition: String` and read it with:

```swift
englishPOSDefinition: try text(
    "SELECT sql FROM sqlite_master WHERE name = 'english_parts_of_speech';"
)
```

In the existing `testBuildsQuotedCSVAndRanksTerms`, change the expected
`schema.userVersion` from `3` to `4`. In
`testBundledDatabaseIsCompatible`, add:

```swift
XCTAssertGreaterThan(summary.posCount, 0)
```

- [ ] **Step 2: Run focused test and verify failure**

```bash
swift test --package-path Packages/GlintDictionary \
  --filter ECDICTRankBuilderTests/testBuildsGlobalEnglishPartsOfSpeech
```

Expected: compilation fails because `posCount` and `partsOfSpeech` do not exist.

- [ ] **Step 3: Upgrade schema and builder**

In `ECDICTRankBuilder.swift`:

```swift
private static let schema = "ecdict-rank-v4"
```

Keep the existing `ranks` columns unchanged and add:

```sql
CREATE TABLE english_parts_of_speech (
    english_key TEXT NOT NULL,
    parts_of_speech TEXT NOT NULL,
    PRIMARY KEY (english_key)
) WITHOUT ROWID;
```

Change `ECDICTRankSummary` to include `posCount`. During CSV parsing, preserve a
`partsByEnglish: [String: [PartOfSpeech]]` dictionary for every single-word
ECDICT headword.

Refactor `appendCandidate` so it:

1. Replaces literal `\\n` with actual newline.
2. Iterates every definition line without dropping order.
3. Calls `ECDICTPartOfSpeech.parseLine`.
4. Calls the existing term extractor for the ranking map exactly as before.
5. If `parsed.partOfSpeech` exists, appends it to the English word's POS list.
6. Calls `ECDICTPartOfSpeech.select` before storing the final list.

Insert metadata rows after writing `ranks`:

```swift
let parts = ECDICTPartOfSpeech.select(
    partsByEnglish[english] ?? []
)
sqlite3_bind_text(
    insertEnglishPOS,
    2,
    ECDICTPartOfSpeech.encode(parts),
    -1,
    sqliteTransient
)
```

Store `posCount` in metadata as the number of metadata rows. Set
`PRAGMA user_version = 4`.

Keep `hasRankSchema` unchanged for `ranks`, and require a separate
`english_parts_of_speech` schema. In `inspect`, compute and return `posCount`:

```sql
SELECT COUNT(*) FROM english_parts_of_speech
```

- [ ] **Step 4: Read POS from the English metadata table**

Keep the existing `ranks` SELECT unchanged. Add a prepared query:

```swift
SELECT parts_of_speech
FROM english_parts_of_speech
WHERE english_key = ?
```

Implement `PartOfSpeechProviding`:

```swift
public func partsOfSpeech(forEnglish word: String) async -> [PartOfSpeech]
```

`SmartRouter` calls this provider after any translation source returns its final
English options.

- [ ] **Step 5: Update builder CLI output**

```swift
print(
    "terms=\(summary.termCount) rows=\(summary.rankCount) "
        + "pos=\(summary.posCount) db=\(output)"
)
```

- [ ] **Step 6: Rebuild the bundled schema-v4 database**

Run separately:

```bash
curl -L --fail --retry 3 \
  -o /tmp/glint-ecdict-9c46923.tar.gz \
  https://codeload.github.com/skywind3000/ECDICT/tar.gz/9c46923fb81a2eb6c264a3a1689562ea7bc56b6a
```

```bash
tar -xzf /tmp/glint-ecdict-9c46923.tar.gz -C /tmp
```

```bash
swift run --package-path Packages/GlintDictionary \
  glint-dictionary-builder ecdict \
  --input /tmp/ECDICT-9c46923fb81a2eb6c264a3a1689562ea7bc56b6a/ecdict.csv \
  --output Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3 \
  --source-checksum d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc \
  --source-date 2026-10-20T02:25:07Z \
  --source-revision 9c46923fb81a2eb6c264a3a1689562ea7bc56b6a
```

Expected: existing term/rank counts remain plausible and `pos` is greater than
or equal to `150_000`.

- [ ] **Step 7: Validate and update the bundled manifest**

```bash
sqlite3 Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3 \
  "PRAGMA quick_check; SELECT key, value FROM metadata WHERE key='schema'; SELECT COUNT(*) FROM english_parts_of_speech;"
stat -f%z Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3
shasum -a 256 Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3
```

Expected: `ok`, `ecdict-rank-v4`, and a count greater than or equal to `150_000`.

In `manifest.json`, set `version` to `2026.10.20.3`, `sizeBytes` to the integer
printed by `stat`, and `sha256` to the digest printed by `shasum`. Keep all
other fields unchanged.

- [ ] **Step 8: Run all dictionary tests**

```bash
swift test --package-path Packages/GlintDictionary \
  --filter ECDICTPartOfSpeechTests
swift test --package-path Packages/GlintDictionary \
  --filter ECDICTRankBuilderTests/testBuildsGlobalEnglishPartsOfSpeech
swift test --package-path Packages/GlintDictionary
```

Expected: all commands pass against the rebuilt bundled database.

- [ ] **Step 9: Commit checkpoint**

Only if explicitly authorized:

```bash
git add Packages/GlintDictionary/Sources/GlintDictionary/ECDICTRankBuilder.swift \
  Packages/GlintDictionary/Sources/GlintDictionary/ECDICTRanker.swift \
  Packages/GlintDictionary/Sources/GlintDictionaryBuilder/main.swift \
  Packages/GlintDictionary/Tests/GlintDictionaryTests/ECDICTRankBuilderTests.swift \
  Resources/Plugins/dict-ecdict
git commit -m "Store global English parts of speech in ECDICT"
```

Otherwise leave changes uncommitted.

---

### Task 4: Attach POS in Dictionary Engines

**Files:**
- Modify: `Packages/GlintDictionary/Sources/GlintDictionary/CedictDictionary.swift`
- Modify: `Packages/GlintDictionary/Sources/GlintDictionary/ECDICTDictionary.swift`
- Modify: `Packages/GlintDictionary/Sources/GlintDictionary/GenericSQLiteDictionary.swift`
- Modify: `Packages/GlintDictionary/Tests/GlintDictionaryTests/CedictDictionaryTests.swift`
- Modify: `Packages/GlintDictionary/Tests/GlintDictionaryTests/GenericSQLiteDictionaryTests.swift`
- Modify: `App/Glint/DictionaryPluginLoader.swift`
- Modify: `App/Glint/AppEnvironment.swift`

**Interfaces:**
- Consumes: `PartOfSpeechProviding.partsOfSpeech(forEnglish:)` from Task 3.
- Produces: app-level POS provider wiring for every translation source.

- [ ] **Step 1: Add failing engine tests**

Append to `CedictDictionaryTests.swift`:

```swift
func testCedictOptionsGetPOSFromEnglishLookup() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ecdict = directory.appendingPathComponent("rank.sqlite3")
    try makeECDICTFixture(at: ecdict)

    let dictionary = CedictDictionary(
        databaseURL: rootURL.appendingPathComponent(
            "Resources/Plugins/dict-cedict/cedict.sqlite3"
        ),
        ranker: ECDICTRanker(databaseURL: ecdict)
    )
    let ranker = ECDICTRanker(databaseURL: ecdict)
    let router = SmartRouter(
        dictionary: dictionary,
        translation: NoTranslation(),
        partOfSpeechProvider: ranker
    )
    let result = try await router.route(
        Candidate(text: "设计"),
        mode: .dictionaryFirst
    )
    let design = result?.options.first {
        $0.text.lowercased() == "design"
    }

    XCTAssertEqual(design?.partsOfSpeech, [.noun, .verb])
}
```

Add helpers:

```swift
private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "GlintCedictPOS-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func makeECDICTFixture(at database: URL) throws {
    let source = database.deletingLastPathComponent()
        .appendingPathComponent("ecdict.csv")
    try Data(
        """
        word,phonetic,definition,translation,pos,collins,oxford,tag,bnc,frq,exchange,detail,audio
        design,,,"n. 设计\\nv. 设计",,5,1,,,100,,
        plan,,,"n. 计划\\nvt. 计划",,4,1,,,120,,
        """.utf8
    ).write(to: source)
    try ECDICTRankBuilder.build(
        fromCSVURL: source,
        to: database
    )
}
```

Extend `GenericSQLiteDictionaryTests.testStandardSchemaAndLookupRanking`:

```swift
XCTAssertEqual(
    result?.options.first {
        $0.text == "design"
    }?.partsOfSpeech,
    [.noun]
)
```

Add a second generic test whose `entries` table omits `part_of_speech`; assert
compatibility and empty POS.

- [ ] **Step 2: Run tests and verify failure**

```bash
swift test --package-path Packages/GlintDictionary \
  --filter CedictDictionaryTests/testCedictOptionsGetPOSFromEnglishLookup
swift test --package-path Packages/GlintDictionary \
  --filter GenericSQLiteDictionaryTests
```

Expected: engine-level assertions fail because options omit POS.

- [ ] **Step 3: Wire the English POS provider**

Keep CC-CEDICT and ECDICT options as plain translation strings. Make
`PluginDictionaryRouter` retain the active `ECDICTRanker` from
`DictionaryPluginLoader.resolve`, conform to `PartOfSpeechProviding`, and refresh
the ranker on `reload()`. Pass `dictionary` as `partOfSpeechProvider` when
constructing `SmartRouter` in `AppEnvironment`.

Add to `ECDICTRanker`:

```swift
func fallbackRankings(
    term: String,
    maxFrequency: Int = 100_000,
    limit: Int = 3
) -> [EnglishRanking] {
    rows(for: term)
        .filter {
            $0.frequency <= maxFrequency
                && $0.english.count > 1
        }
        .prefix(max(0, limit))
        .map { $0 }
}
```

Keep `fallbackCandidates` as `fallbackRankings(...).map(\.english)`. In
`ECDICTDictionary.lookup`, build options from `fallbackRankings` and pass their
POS.

- [ ] **Step 4: Add optional generic SQLite POS support**

Probe the `entries` columns. If `part_of_speech` exists, select it after
`source_order`; otherwise select `NULL AS part_of_speech`.

For each value:

```swift
let parts = value.split {
    [",", "/", ";"].contains($0)
}.compactMap {
    PartOfSpeech(
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    )
}
TranslationOption(
    text: text,
    score: 1.0 - Double(index) * 0.05,
    partsOfSpeech: parts
)
```

- [ ] **Step 5: Run dictionary tests**

```bash
swift test --package-path Packages/GlintDictionary \
  --filter CedictDictionaryTests/testCedictOptionsGetPOSFromEnglishLookup
swift test --package-path Packages/GlintDictionary \
  --filter GenericSQLiteDictionaryTests
```

Expected: tests pass without changing translation ranking text.

- [ ] **Step 6: Commit checkpoint**

Only if explicitly authorized:

```bash
git add Packages/GlintDictionary/Sources/GlintDictionary \
  Packages/GlintDictionary/Tests/GlintDictionaryTests/CedictDictionaryTests.swift \
  Packages/GlintDictionary/Tests/GlintDictionaryTests/GenericSQLiteDictionaryTests.swift
git commit -m "Attach parts of speech to dictionary options"
```

Otherwise leave changes uncommitted.

---

### Task 5: Preserve POS Through Routing

**Files:**
- Modify: `Packages/GlintCore/Sources/GlintCore/Routing/DictionaryRouter.swift`
- Modify: `Packages/GlintCore/Sources/GlintCore/Routing/SmartRouter.swift`
- Modify: `Packages/GlintCore/Tests/GlintCoreTests/DictionaryRouterTests.swift`
- Modify: `Packages/GlintCore/Tests/GlintCoreTests/SmartRouterTests.swift`

**Interfaces:**
- Consumes: `TranslationResult` merge behavior from Task 1.
- Produces: routed results retaining dictionary POS for single-surface options and on matching English surfaces.

- [ ] **Step 1: Add failing router tests**

Add to `DictionaryRouterTests.swift`:

```swift
func testPreservesPOSForSingleSurfaceOption() async {
    let router = DictionaryRouter(routes: [
        DictionaryRoute(
            id: "pos",
            priority: 0,
            role: .authoritative,
            engine: POSOptionsDictionary(
                options: [
                    TranslationOption(
                        text: "design",
                        score: 1,
                        partsOfSpeech: [.noun, .verb]
                    )
                ]
            )
        )
    ])

    let result = await router.lookup(
        Candidate(text: "设计", kind: .word)
    )
    XCTAssertEqual(
        result?.options.first?.partsOfSpeech,
        [.noun, .verb]
    )
}

func testDropsPOSWhenOneOptionSplitsIntoMultipleSurfaces() async {
    let router = DictionaryRouter(routes: [
        DictionaryRoute(
            id: "pos-split",
            priority: 0,
            role: .authoritative,
            engine: POSOptionsDictionary(
                options: [
                    TranslationOption(
                        text: "design; plan",
                        score: 1,
                        partsOfSpeech: [.noun, .verb]
                    )
                ]
            )
        )
    ])

    let result = await router.lookup(
        Candidate(text: "设计", kind: .word)
    )
    XCTAssertTrue(
        result?.options.allSatisfy {
            $0.partsOfSpeech.isEmpty
        } == true
    )
}
```

Append to `SmartRouterTests.swift`:

```swift
func testSmartFusionPreservesDictionaryPOSOnModelSurface() async throws {
    let router = SmartRouter(
        dictionary: MockDictionary(
            result: TranslationResult(options: [
                TranslationOption(
                    text: "design",
                    score: 0.8,
                    partsOfSpeech: [.noun, .verb]
                )
            ])
        ),
        translation: MockTranslator(
            result: TranslationResult(text: "design")
        )
    )

    let output = try await router.route(
        Candidate(text: "设计"),
        mode: .smartFusion
    )

    XCTAssertEqual(output?.options.first?.partsOfSpeech, [.noun, .verb])
}

func testModelFirstPreservesMatchingDictionaryPOS() async throws {
    let router = SmartRouter(
        dictionary: MockDictionary(
            result: TranslationResult(options: [
                TranslationOption(
                    text: "design",
                    score: 0.8,
                    partsOfSpeech: [.noun, .verb]
                )
            ])
        ),
        translation: MockTranslator(
            result: TranslationResult(text: "design")
        )
    )

    let output = try await router.route(
        Candidate(text: "设计"),
        mode: .modelFirst
    )

    XCTAssertEqual(output?.options.first?.partsOfSpeech, [.noun, .verb])
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
swift test --package-path Packages/GlintCore \
  --filter SmartRouterTests/testSmartFusionPreservesDictionaryPOSOnModelSurface
swift test --package-path Packages/GlintCore \
  --filter SmartRouterTests/testModelFirstPreservesMatchingDictionaryPOS
```

Expected: smart fusion drops duplicate dictionary metadata.

- [ ] **Step 3: Merge metadata in router**

In `DictionaryRouter.routeOptions`, derive the displayable surfaces first. Forward
`option.partsOfSpeech` only when the option produces exactly one surface:

```swift
let surfaces = DictionarySurface.split(option.text)
    .filter(DictionarySurface.isDisplayable)
let partsOfSpeech =
    surfaces.count == 1
    ? option.partsOfSpeech
    : []
```

Pass `partsOfSpeech` into every rebuilt `TranslationOption`.

Replace the dictionary rank map with:

```swift
var dictionaryMetadata:
    [String: (rank: Int, partsOfSpeech: [PartOfSpeech])] = [:]
```

For matching model options:

```swift
TranslationOption(
    text: option.text,
    score: modelSignal + dictionarySignal + consensusBonus,
    partsOfSpeech: key.flatMap {
        dictionaryMetadata[$0]?.partsOfSpeech
    } ?? option.partsOfSpeech
)
```

For dictionary-only options, pass their POS. Change the option created by
`modelFirstMerged` to include:

```swift
partsOfSpeech: option.partsOfSpeech
```

- [ ] **Step 4: Run router tests**

```bash
swift test --package-path Packages/GlintCore --filter SmartRouterTests
swift test --package-path Packages/GlintCore --filter TranslationResultTests
```

Expected: all pass.

- [ ] **Step 5: Commit checkpoint**

Only if explicitly authorized:

```bash
git add Packages/GlintCore/Sources/GlintCore/Routing/SmartRouter.swift \
  Packages/GlintCore/Tests/GlintCoreTests/SmartRouterTests.swift
git commit -m "Preserve part of speech through translation routing"
```

Otherwise leave changes uncommitted.

---

### Task 6: Carry POS Into Selected-Mode Presentation

**Files:**
- Modify: `Packages/GlintMac/Sources/GlintMac/MonitoringController.swift`
- Modify: `Packages/GlintMac/Sources/GlintMac/CandidateTranslationPipeline.swift`
- Modify: `Packages/GlintMac/Tests/GlintMacTests/GlintMacTests.swift`
- Modify: `App/Glint/HUDEventCoordinator.swift`

**Interfaces:**
- Consumes: `TranslationOption.partsOfSpeech`.
- Produces: `CandidateTranslationOptionPresentation`, `displayOptions`, and selected-mode `HUDItem.partsOfSpeech`.

- [ ] **Step 1: Add failing presentation tests**

Append to `GlintMacTests.swift`:

```swift
func testSelectedPresentationCarriesPOSButActionsStayPlain() async {
    let presentations = await CandidateTranslationPipeline.translate(
        [Candidate(text: "设计")],
        selectedIndex: 0,
        mode: .dictionaryFirst,
        configurationToken: "pos-test",
        router: SmartRouter(
            dictionary: POSDictionary(),
            translation: EmptyTranslation()
        ),
        memo: TranslationMemo(),
        displayOptionLimit: 4,
        showsPartsOfSpeech: true
    )

    XCTAssertEqual(
        presentations.first?.displayOptions,
        [
            CandidateTranslationOptionPresentation(
                text: "design",
                partsOfSpeech: [.noun, .verb]
            ),
            CandidateTranslationOptionPresentation(
                text: "plan",
                partsOfSpeech: [.noun]
            ),
        ]
    )
    XCTAssertEqual(
        presentations.first?.insertionOptions,
        ["design", "plan"]
    )
}

func testRowPresentationDoesNotCarryPOS() async {
    let presentations = await CandidateTranslationPipeline.translate(
        [Candidate(text: "设计")],
        selectedIndex: 0,
        mode: .dictionaryFirst,
        configurationToken: "pos-test",
        router: SmartRouter(
            dictionary: POSDictionary(),
            translation: EmptyTranslation()
        ),
        memo: TranslationMemo(),
        displayOptionLimit: 1,
        showsPartsOfSpeech: false
    )

    XCTAssertEqual(presentations.first?.displayOptions, [])
    XCTAssertEqual(presentations.first?.translation, "design")
}

func testMultiwordPresentationDropsPOS() {
    let option = CandidateTranslationOptionPresentation(
        text: "bullet screen",
        partsOfSpeech: [.noun]
    )

    XCTAssertEqual(option.partsOfSpeech, [])
}
```

Add fixture:

```swift
private struct POSDictionary: DictionaryEngine {
    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        TranslationResult(options: [
            TranslationOption(
                text: "design",
                score: 1,
                partsOfSpeech: [.noun, .verb]
            ),
            TranslationOption(
                text: "plan",
                score: 0.8,
                partsOfSpeech: [.noun]
            ),
        ])
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
swift test --package-path Packages/GlintMac \
  --filter GlintMacTests.testSelectedPresentationCarriesPOSButActionsStayPlain
swift test --package-path Packages/GlintMac \
  --filter GlintMacTests.testRowPresentationDoesNotCarryPOS
swift test --package-path Packages/GlintMac \
  --filter GlintMacTests.testMultiwordPresentationDropsPOS
```

Expected: compilation fails because the new types and parameters are absent.

- [ ] **Step 3: Add structured display types**

Add to `MonitoringController.swift`:

```swift
public struct CandidateTranslationOptionPresentation:
    Sendable, Equatable
{
    public let text: String
    public let partsOfSpeech: [PartOfSpeech]

    public init(text: String, partsOfSpeech: [PartOfSpeech]) {
        self.text = text
        self.partsOfSpeech =
            Self.isSingleEnglishWord(text)
            ? PartOfSpeech.normalized(partsOfSpeech)
            : []
    }

    private static func isSingleEnglishWord(_ text: String) -> Bool {
        let value = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
              !value.contains(where: \.isWhitespace)
        else {
            return false
        }
        let hasLatin = value.contains {
            $0.isASCII && $0.isLetter
        }
        let hasHan = value.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)
        }
        return hasLatin && !hasHan
    }
}
```

Add `displayOptions` to `CandidateTranslationPresentation` with a default
empty array.

- [ ] **Step 4: Thread selected-mode flag through pipeline**

Add `showsPartsOfSpeech: Bool = false` to
`CandidateTranslationPipeline.translate` and its private `presentation`.
Pass `translationScope == .selected` from
`MonitoringController.startTranslation`.

Build display options:

```swift
let displayOptions =
    showsPartsOfSpeech
    ? Array(result?.options.prefix(displayOptionLimit) ?? []).map {
        CandidateTranslationOptionPresentation(
            text: $0.text,
            partsOfSpeech: $0.partsOfSpeech
        )
    }
    : []
```

Keep `insertionOptions` and `translation` as plain-string action paths. In
`completeTranslation`, preserve `displayOptions` when rebuilding presentations:

```swift
displayOptions: item.displayOptions,
```

In selected-mode `HUDEventCoordinator.hudItems`, use
`selected.displayOptions` and pass `partsOfSpeech` to `HUDItem`. Use the old
translation fallback only when `displayOptions` is empty. Row mode must pass no
POS.

- [ ] **Step 5: Run focused tests**

```bash
swift test --package-path Packages/GlintMac \
  --filter GlintMacTests.testSelectedPresentationCarriesPOSButActionsStayPlain
swift test --package-path Packages/GlintMac \
  --filter GlintMacTests.testRowPresentationDoesNotCarryPOS
swift test --package-path Packages/GlintMac \
  --filter GlintMacTests.testMultiwordPresentationDropsPOS
swift test --package-path Packages/GlintMac \
  --filter TranslationChoiceMonitoringTests
```

Expected: all pass.

- [ ] **Step 6: Commit checkpoint**

Only if explicitly authorized:

```bash
git add Packages/GlintMac/Sources/GlintMac/MonitoringController.swift \
  Packages/GlintMac/Sources/GlintMac/CandidateTranslationPipeline.swift \
  Packages/GlintMac/Tests/GlintMacTests/GlintMacTests.swift \
  App/Glint/HUDEventCoordinator.swift
git commit -m "Carry part of speech into selected HUD presentation"
```

Otherwise leave changes uncommitted.

---

### Task 7: Render POS and Degrade by Width

**Files:**
- Modify: `Packages/GlintUI/Sources/GlintUI/HUD/HUDView.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/HUD/HUDLayoutPlan.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/HUD/HUDGeometryResolver.swift`
- Modify: `Packages/GlintUI/Tests/GlintUITests/HUDLayoutTests.swift`

**Interfaces:**
- Consumes: `HUDItem.partsOfSpeech` storage introduced minimally in Task 6.
- Produces: POS-aware rendering, width measurement and graceful removal.

- [ ] **Step 1: Write failing HUD tests**

Add `import GlintCore` to `HUDLayoutTests.swift`, then append:

```swift
@MainActor
func testPOSIncreasesMeasuredWidthButNotHeight() {
    let without = HUDItem(id: 0, text: "design")
    let with = HUDItem(
        id: 0,
        text: "design",
        partsOfSpeech: [.noun, .verb]
    )

    XCTAssertGreaterThan(
        HUDLayoutPlan.naturalPanelWidth(for: [with]),
        HUDLayoutPlan.naturalPanelWidth(for: [without])
    )
    XCTAssertEqual(
        HUDLayoutPlan.panelSize(
            for: [with],
            maximumWidth: 1_400
        ).height,
        HUDLayoutPlan.panelSize(
            for: [without],
            maximumWidth: 1_400
        ).height
    )
}

@MainActor
func testPartsOfSpeechAreRemovedBeforeTranslationsWhenNarrow() {
    let items = [
        HUDItem(
            id: 0,
            number: 1,
            text: "design",
            partsOfSpeech: [.noun, .verb]
        )
    ]
    let result = HUDLayoutPlan.itemsFittingPartsOfSpeech(
        items,
        maximumWidth: HUDLayoutPlan.naturalPanelWidth(for: items) - 1,
        layoutStyle: .selectedTranslations
    )

    XCTAssertEqual(result.map(\.text), ["design"])
    XCTAssertEqual(result.map(\.partsOfSpeech), [[]])
}

@MainActor
func testHUDHostingWidthIncludesPOS() {
    let item = HUDItem(
        id: 0,
        number: 1,
        text: "design",
        partsOfSpeech: [.noun, .verb]
    )
    let hosting = NSHostingView(rootView: HUDView(items: [item]))
    hosting.layoutSubtreeIfNeeded()

    XCTAssertGreaterThanOrEqual(
        HUDLayoutPlan.naturalPanelWidth(for: [item]),
        hosting.fittingSize.width
    )
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
swift test --package-path Packages/GlintUI \
  --filter HUDLayoutTests/testPOSIncreasesMeasuredWidthButNotHeight
swift test --package-path Packages/GlintUI \
  --filter HUDLayoutTests/testPartsOfSpeechAreRemovedBeforeTranslationsWhenNarrow
swift test --package-path Packages/GlintUI \
  --filter HUDLayoutTests/testHUDHostingWidthIncludesPOS
```

Expected: compilation fails because the fields and helpers are absent.

- [ ] **Step 3: Complete HUDItem and metrics**

If Task 6 added the minimal field for App compilation, retain it and complete
its normalization/accessibility helpers. Otherwise import `GlintCore` and add:

```swift
public let partsOfSpeech: [PartOfSpeech]

public init(
    id: Int,
    number: Int? = nil,
    text: String,
    partsOfSpeech: [PartOfSpeech] = [],
    isSelected: Bool = false
) {
    self.id = id
    self.number = number
    self.text = text
    self.partsOfSpeech = PartOfSpeech.normalized(partsOfSpeech)
    self.isSelected = isSelected
}

var partsOfSpeechText: String {
    partsOfSpeech.map(\.abbreviation).joined(separator: "/")
}

var accessibilityText: String {
    guard !partsOfSpeech.isEmpty else { return text }
    return "\(text), "
        + partsOfSpeech.map(\.accessibilityName).joined(separator: ", ")
}

func removingPartsOfSpeech() -> Self {
    Self(
        id: id,
        number: number,
        text: text,
        partsOfSpeech: [],
        isSelected: isSelected
    )
}
```

Add to `HUDLayoutMetrics`:

```swift
partOfSpeechFontSize = max(
    9,
    (fontSize * 0.75 * 2).rounded() / 2
)
```

- [ ] **Step 4: Render one baseline with two styles**

In `HUDItemRow.itemView`, compose:

```swift
let primary = Text(item.text)
    .font(.system(
        size: plan.metrics.textFontSize,
        weight: .medium
    ))
    .foregroundColor(
        item.isSelected && items.count > 1
            ? .white
            : appearance.resolvedTextColor
    )

let label =
    item.partsOfSpeechText.isEmpty
    ? primary
    : primary
        + Text(" ").font(.system(
            size: plan.metrics.partOfSpeechFontSize,
            weight: .medium
        ))
        + Text(item.partsOfSpeechText)
            .font(.system(
                size: plan.metrics.partOfSpeechFontSize,
                weight: .medium
            ))
            .foregroundColor(
                appearance.resolvedSecondaryTextColor
            )
```

Use `label` in place of the old `Text(item.text)`. Apply:

```swift
.accessibilityElement(children: .ignore)
.accessibilityLabel(item.accessibilityText)
```

Do not change height, padding, number spacing, material or animations.

- [ ] **Step 5: Include POS in width and remove it first**

In `HUDLayoutPlan.naturalPanelWidth`:

```swift
if !item.partsOfSpeechText.isEmpty {
    let posFont = NSFont.systemFont(
        ofSize: plan.metrics.partOfSpeechFontSize,
        weight: .medium
    )
    let suffix = " " + item.partsOfSpeechText
    itemWidth += ceil(
        (suffix as NSString).size(
            withAttributes: [.font: posFont]
        ).width
    )
}
```

Add:

```swift
@MainActor
static func itemsFittingPartsOfSpeech(
    _ items: [HUDItem],
    maximumWidth: CGFloat,
    layoutStyle: HUDLayoutStyle,
    appearance: HUDAppearance = .default
) -> [HUDItem] {
    guard items.contains(where: { !$0.partsOfSpeech.isEmpty }) else {
        return items
    }
    let width = naturalPanelWidth(
        for: items,
        layoutStyle: layoutStyle,
        appearance: appearance
    )
    guard width > max(HUDGeometry.minimumPanelWidth, maximumWidth) else {
        return items
    }
    return items.map { $0.removingPartsOfSpeech() }
}
```

Add `HUDPresentationRequest.withItems(_:)`. In `HUDGeometryResolver.resolve`,
after obtaining `maximumWidth`:

```swift
let fittedItems = HUDLayoutPlan.itemsFittingPartsOfSpeech(
    request.items,
    maximumWidth: maximumWidth,
    layoutStyle: request.layoutStyle,
    appearance: request.appearance
)
let resolvedRequest =
    fittedItems == request.items
    ? request
    : request.withItems(fittedItems)
```

Use `resolvedRequest` for selected-only checks, panel sizing, placement and the
returned layout.

- [ ] **Step 6: Extend previews**

Add preview items:

```swift
HUDItem(
    id: 0,
    number: 1,
    text: "design",
    partsOfSpeech: [.noun, .verb]
)
HUDItem(
    id: 1,
    number: 2,
    text: "about",
    partsOfSpeech: [.preposition]
)
HUDItem(
    id: 2,
    number: 3,
    text: "devise",
    partsOfSpeech: [.verb]
)
```

- [ ] **Step 7: Run HUD tests and inspect previews**

```bash
swift test --package-path Packages/GlintUI --filter HUDLayoutTests
swift test --package-path Packages/GlintUI
```

Expected: tests pass. Inspect light/dark previews at 12pt, 14pt and 18pt.

- [ ] **Step 8: Commit checkpoint**

Only if explicitly authorized:

```bash
git add Packages/GlintUI
git commit -m "Render word parts of speech in the HUD"
```

Otherwise leave changes uncommitted.

---

### Task 8: Add Update Guards, Update Docs, and Verify

**Files:**
- Modify: `Packages/GlintPlugins/Sources/GlintPlugins/Manager/ECDICTUpdateService.swift`
- Modify: `Packages/GlintPlugins/Tests/GlintPluginsTests/ECDICTUpdateServiceTests.swift`
- Modify: `AGENTS.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/DICTIONARY-SOURCES.md`

**Interfaces:**
- Consumes: schema-v4 bundled database from Task 3 and all product layers from Tasks 1-7.
- Produces: update-service safeguards, documentation and full verification evidence.

- [ ] **Step 1: Add update-service POS plausibility tests**

In `ECDICTUpdateServiceTests.swift`, make fixture CSV rows use labels such as
`n. 设计, 图样\\nv. 设计, 计划`. Add `minimumPOSCount: 1` to the injected
service configuration. Assert:

```swift
XCTAssertGreaterThan(
    try ECDICTRankBuilder.inspect(databaseURL: database).posCount,
    0
)
```

Add a test where the rebuilt source has no supported POS and expect
`ECDICTUpdateError.implausibleDatabase`. Add a repair test with an installed
schema-v3 dictionary and a bundled schema-v4 dictionary; verify
`repairInstalledCopyIfNeeded()` replaces it.

In `ECDICTUpdateService.swift`, add:

```swift
private let minimumPOSCount: Int

public init(
    pluginManager: PluginManager,
    bundledDirectory: URL?,
    session: URLSession? = nil,
    fileManager: FileManager = .default,
    atomURL: URL? = nil,
    archiveURLTemplate: String? = nil,
    minimumTermCount: Int = 80_000,
    minimumRankCount: Int = 120_000,
    minimumPOSCount: Int = 150_000
) {
    self.minimumPOSCount = minimumPOSCount
}
```

Extend the plausibility guard:

```swift
summary.termCount >= minimumTermCount,
summary.rankCount >= minimumRankCount,
summary.posCount >= minimumPOSCount
```

- [ ] **Step 2: Run update-service tests**

```bash
swift test --package-path Packages/GlintPlugins \
  --filter ECDICTUpdateServiceTests
```

Expected: tests pass with synthetic POS rows and fail on an empty POS rebuild.

- [ ] **Step 3: Update documentation**

In `AGENTS.md`, replace the sentence that forbids all part-of-speech display
with:

```markdown
- 仅对“选中”模式中的单词译项显示最多两个标准英文词性缩写，例如
  `n.`、`v.`、`adj.`、`prep.`；不显示中文词性名称、解释、例句或音标。
```

In `docs/ARCHITECTURE.md`, add:

```markdown
- 单词译项可携带来自 ECDICT 释义行标签的最多两个标准英文词性缩写。词性使用
  次要文字样式紧跟英文词，只出现在选中模式；可用宽度不足时先移除词性，
  不得截断译文、改变字号或增加第二行。
```

In `docs/DICTIONARY-SOURCES.md`, add:

```markdown
- 固定 ECDICT revision 的 `pos` 比例列为空；Glint 从 `translation` 的释义行
  前缀提取词性，并按英文词写入 schema-v4 的 `english_parts_of_speech` 表。
  未知或非目标标签不进入 HUD。
```

When preparing a release, add:

```markdown
- 选中单词时，可在英文译项后显示 `n.`、`v.`、`adj.` 等词性缩写。
```

- [ ] **Step 4: Run all affected package tests**

```bash
swift test --package-path Packages/GlintCore
swift test --package-path Packages/GlintDictionary
swift test --package-path Packages/GlintPlugins
swift test --package-path Packages/GlintMac
swift test --package-path Packages/GlintUI
```

Expected: every command passes.

- [ ] **Step 5: Run full regression and build**

```bash
./scripts/test.sh
./scripts/dev.sh --build-only
```

Expected: complete tests and incremental Debug arm64 build pass.

- [ ] **Step 6: Run the real app and inspect UX**

```bash
./scripts/dev.sh
```

Verify only after observing the new build:

- 选中“设计”时，`design` 显示其英文词性；模型优先下的首项模型译文也能显示词性。
- 输入得到 `convenient`、`user`、`develop` 时，分别能显示 `adj./n./v.`；`open`
  显示英文词自身的常用标签，而不是只按中文语境裁剪。
- 一栏模式没有词性。
- 浅色、深色、12/14/18pt 字号下保持单行。
- 窄宽度下先去掉词性，英文译文仍存在。
- 插入结果和朗读不包含 `n.`、`v.`、`adj.` 等标签。
- Secure Input、密码框和终端安全输入行为不变。

Do not claim these behaviors until they are observed.

- [ ] **Step 7: Final checks**

```bash
git diff --check
git status --short --branch
rg -n "TBD|TODO" docs/superpowers Resources/Plugins/dict-ecdict/manifest.json
```

Expected: no whitespace errors, no placeholders, and only intended files are
modified.

- [ ] **Step 8: Delivery commit**

Only if explicitly requested:

```bash
git add AGENTS.md App/Glint/HUDEventCoordinator.swift \
  docs/ARCHITECTURE.md \
  docs/DICTIONARY-SOURCES.md \
  docs/superpowers \
  Packages/GlintCore \
  Packages/GlintDictionary \
  Packages/GlintPlugins \
  Packages/GlintMac \
  Packages/GlintUI \
  Resources/Plugins/dict-ecdict
git commit -m "Show parts of speech for word translations"
```

Do not push unless separately requested.

---

## Plan Self-Review

- [x] All specification requirements map to Tasks 1-8.
- [x] The plan never reads the empty ECDICT `pos` ratio column.
- [x] POS is associated with the final English word, not the Chinese term or source.
- [x] `partsOfSpeech` spelling and `parts_of_speech` storage naming are consistent.
- [x] `displayOptions` is display-only; insertion and speech use plain strings.
- [x] Row mode never creates POS metadata.
- [x] Multiword and sentence display paths drop POS.
- [x] Width fallback removes POS before translation content.
- [x] No task guesses POS from a model, suffix or surrounding context.
- [x] The schema-v4 bundled database is regenerated before full dictionary tests.
