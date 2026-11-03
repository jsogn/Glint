# 多语种支持 Implementation Plan

> Historical implementation plan. Current model-language semantics are defined in the
> expansion design spec: missing `translationTargets` means no restriction, and only
> explicitly declared restrictions are shown to users.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Glint 支持中文候选到英语或日语的全局单目标翻译，同时保持英语现有体验，并为后续语言和模型能力扩展提供清晰的领域、运行时和 UI 边界。

**Architecture:** 以显式 `TranslationDirection` 贯穿领域、路由、缓存和运行时；App 层的 `TranslationLanguageCoordinator` 串行化语言切换、监控暂停/恢复和两个翻译后端。UI 新增“语言与翻译”页面拥有当前配置，“插件与模型”退化为资源管理。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Swift Package Manager、Apple Translation、MLX、CTranslate2、XCTest

**Spec:** `docs/superpowers/specs/2026-11-03-multilingual-expansion-design.md`

## Global Constraints

- 最低系统版本为 macOS 15，仅支持 Apple Silicon arm64。
- 源语言仍固定为简体中文；目标语言只允许英语和日语。
- 任意时刻只启用一个全局目标语言，不支持英日同时显示。
- 日语第一版只走模型翻译，不接入词典、不显示词性、不回退英语语音。
- 英语现有翻译模式、词典、词性、口音和 HUD 行为必须保持。
- 语言切换立即提交目标；未就绪时暂停翻译并保留页面内准备状态，不回退旧语言。
- 普通运行期错误不弹窗、不显示 Toast；权限和系统语言包交互沿用现有规则。
- 模型和词典能力必须来自显式方向声明，不能按模型 ID 名称推断目标语言能力。
- 不新增远程翻译接口、不保存候选或译文、不读取输入框正文。
- UI 使用系统 SwiftUI/AppKit 控件，不引入第三方 UI 组件库。
- 每个任务结束前运行对应模块测试；跨模块和最终验收运行 `./scripts/test.sh`。
- 不推送远程仓库；提交信息使用英文祈使句。

---

### Task 1: 增加目标语言、方向和共享文本门控

**Files:**
- Create: `Packages/GlintCore/Sources/GlintCore/Domain/TranslationLanguage.swift`
- Create: `Packages/GlintCore/Sources/GlintCore/Domain/TranslationTextPolicy.swift`
- Create: `Packages/GlintCore/Tests/GlintCoreTests/TranslationLanguageTests.swift`
- Create: `Packages/GlintCore/Tests/GlintCoreTests/TranslationTextPolicyTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - `TranslationSourceLanguage.simplifiedChinese`
  - `TranslationTarget.english` / `.japanese`
  - `TranslationDirection.source` / `.target`
  - `TranslationDirection.simplifiedChineseToEnglish` / `.simplifiedChineseToJapanese`
  - `TranslationRequest(candidate:direction:)`
  - `TranslationTextPolicy.isDisplayable(_:target:) -> Bool`

- [ ] **Step 1: 写方向和请求测试**

```swift
import XCTest
@testable import GlintCore

final class TranslationLanguageTests: XCTestCase {
    func testTargetRawValuesAreStable() {
        XCTAssertEqual(TranslationTarget.english.rawValue, "en")
        XCTAssertEqual(TranslationTarget.japanese.rawValue, "ja")
    }

    func testDirectionsAreDistinctAndRequestKeepsTarget() {
        let english = TranslationDirection.simplifiedChineseToEnglish
        let japanese = TranslationDirection.simplifiedChineseToJapanese
        XCTAssertNotEqual(english, japanese)

        let request = TranslationRequest(
            candidate: Candidate(text: "你好"),
            direction: japanese
        )
        XCTAssertEqual(request.direction.target, .japanese)
        XCTAssertEqual(request.direction.source, .simplifiedChinese)
    }
}
```

- [ ] **Step 2: 运行测试确认类型缺失**

Run:

```bash
swift test --package-path Packages/GlintCore \
  --filter TranslationLanguageTests
```

Expected: FAIL，因为 `TranslationTarget` 和 `TranslationRequest` 尚不存在。

- [ ] **Step 3: 实现领域值类型**

```swift
import Foundation

public enum TranslationSourceLanguage:
    String, Codable, Sendable, Equatable, Hashable
{
    case simplifiedChinese = "zh-Hans"
}

public enum TranslationTarget:
    String, CaseIterable, Codable, Sendable, Equatable, Hashable
{
    case english = "en"
    case japanese = "ja"
}

public struct TranslationDirection:
    Codable, Sendable, Equatable, Hashable
{
    public let source: TranslationSourceLanguage
    public let target: TranslationTarget

    public init(
        source: TranslationSourceLanguage = .simplifiedChinese,
        target: TranslationTarget
    ) {
        self.source = source
        self.target = target
    }
}

public extension TranslationDirection {
    static let simplifiedChineseToEnglish =
        TranslationDirection(target: .english)
    static let simplifiedChineseToJapanese =
        TranslationDirection(target: .japanese)
}

public struct TranslationRequest: Sendable, Equatable {
    public let candidate: Candidate
    public let direction: TranslationDirection

    public init(
        candidate: Candidate,
        direction: TranslationDirection
    ) {
        self.candidate = candidate
        self.direction = direction
    }
}
```

- [ ] **Step 4: 写共享显示门控测试**

```swift
import XCTest
@testable import GlintCore

final class TranslationTextPolicyTests: XCTestCase {
    func testEnglishStillRejectsChineseEcho() {
        XCTAssertFalse(
            TranslationTextPolicy.isDisplayable(
                "这是一个测试",
                target: .english
            )
        )
    }

    func testJapaneseAllowsHanAndKana() {
        XCTAssertTrue(
            TranslationTextPolicy.isDisplayable(
                "学生",
                target: .japanese
            )
        )
        XCTAssertTrue(
            TranslationTextPolicy.isDisplayable(
                "天気がいい",
                target: .japanese
            )
        )
    }

    func testBothTargetsRejectNewlinesAndOverlongText() {
        for target in TranslationTarget.allCases {
            XCTAssertFalse(
                TranslationTextPolicy.isDisplayable(
                    "first\nsecond",
                    target: target
                )
            )
            XCTAssertFalse(
                TranslationTextPolicy.isDisplayable(
                    String(repeating: "a", count: 49),
                    target: target
                )
            )
        }
    }
}
```

- [ ] **Step 5: 实现共享显示门控**

```swift
public enum TranslationTextPolicy {
    public static func isDisplayable(
        _ text: String,
        target: TranslationTarget
    ) -> Bool {
        let value = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
            value.count <= 48,
            !value.contains(where: \.isNewline)
        else {
            return false
        }
        switch target {
        case .english:
            let hanCount = value.unicodeScalars.count {
                (0x4E00...0x9FFF).contains($0.value)
            }
            return hanCount <= max(1, value.count / 5)
        case .japanese:
            return true
        }
    }
}
```

- [ ] **Step 6: 运行两个测试类**

Run:

```bash
swift test --package-path Packages/GlintCore \
  --filter TranslationLanguageTests
swift test --package-path Packages/GlintCore \
  --filter TranslationTextPolicyTests
```

Expected: PASS。

- [ ] **Step 7: 提交**

```bash
git add Packages/GlintCore
git commit -m "Add translation language primitives"
```

---

### Task 2: 将方向和文本门控接入核心路由与缓存

**Files:**
- Modify: `Packages/GlintCore/Sources/GlintCore/Contracts/Engines.swift`
- Modify: `Packages/GlintCore/Sources/GlintCore/Routing/DictionaryRouter.swift`
- Modify: `Packages/GlintCore/Sources/GlintCore/Routing/SmartRouter.swift`
- Modify: `Packages/GlintCore/Sources/GlintCore/Routing/TranslationMemo.swift`
- Modify: `Packages/GlintCore/Tests/GlintCoreTests/SmartRouterTests.swift`
- Modify: `Packages/GlintCore/Tests/GlintCoreTests/DictionaryRouterTests.swift`
- Modify: `Packages/GlintCore/Tests/GlintCoreTests/TranslationMemoTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `TranslationDirection`、`TranslationRequest`。
- Produces:
  - `TranslationEngine.supports(_:)`
  - `TranslationEngine.translate(_ request:)`
  - `DictionaryEngine.lookup(_ request:)`
  - `DictionaryRoute.directions`
  - `SmartRouter.route(_ request:mode:includesAlternatives:dictionaryPrefetch:)`
  - `TranslationMemoKey.direction`

- [ ] **Step 1: 更新 Core 测试桩并写日语只走模型测试**

```swift
private struct MockTranslator: TranslationEngine {
    let result: TranslationResult?

    func supports(
        _ direction: TranslationDirection
    ) async -> Bool {
        true
    }

    func translate(
        _ request: TranslationRequest
    ) async throws -> TranslationResult? {
        result
    }
}

func testJapaneseBypassesDictionaryInEveryMode() async throws {
    let dictionary = CountingDictionary(
        result: TranslationResult(text: "english fallback")
    )
    let router = SmartRouter(
        dictionary: dictionary,
        translation: MockTranslator(
            result: TranslationResult(text: "こんにちは")
        )
    )
    let request = TranslationRequest(
        candidate: Candidate(text: "你好", kind: .word),
        direction: .simplifiedChineseToJapanese
    )

    let result = try await router.route(
        request,
        mode: .dictionaryFirst
    )

    XCTAssertEqual(result?.text, "こんにちは")
    XCTAssertEqual(await dictionary.lookupCount(), 0)
}
```

- [ ] **Step 2: 运行测试确认旧签名编译失败**

Run:

```bash
swift test --package-path Packages/GlintCore \
  --filter SmartRouterTests
```

Expected: FAIL，因为协议和路由仍接收 `Candidate`。

- [ ] **Step 3: 修改协议**

```swift
public protocol DictionaryEngine: Sendable {
    func lookup(
        _ request: TranslationRequest
    ) async throws -> TranslationResult?
}

public protocol TranslationEngine: Sendable {
    func supports(
        _ direction: TranslationDirection
    ) async -> Bool
    func translate(
        _ request: TranslationRequest
    ) async throws -> TranslationResult?
}
```

- [ ] **Step 4: 让词典路由声明方向**

```swift
public struct DictionaryRoute: Sendable {
    public let id: String
    public let priority: Int
    public let role: DictionaryRouteRole
    public let directions: Set<TranslationDirection>
    public let engine: any DictionaryEngine

    public init(
        id: String,
        priority: Int,
        role: DictionaryRouteRole = .fallback,
        directions: Set<TranslationDirection> = [
            .simplifiedChineseToEnglish
        ],
        engine: any DictionaryEngine
    ) {
        self.id = id
        self.priority = priority
        self.role = role
        self.directions = directions
        self.engine = engine
    }
}
```

`DictionaryRouter.lookup(_:)` 改为接收 `TranslationRequest`，先按
`route.directions.contains(request.direction)` 过滤，再调用 `route.engine.lookup(request)`。

- [ ] **Step 5: 修改 SmartRouter**

```swift
public func route(
    _ request: TranslationRequest,
    mode: TranslationMode = .dictionaryFirst,
    includesAlternatives: Bool = true,
    dictionaryPrefetch: Task<TranslationResult?, Never>? = nil
) async throws -> TranslationResult? {
    try Task.checkCancellation()
    guard !request.candidate.text
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return nil
    }

    if request.direction.target == .japanese {
        return try await translation.translate(request)
    }

    let routed = try await routeWithoutPartOfSpeech(
        request,
        mode: mode,
        includesAlternatives: includesAlternatives,
        dictionaryPrefetch: dictionaryPrefetch
    )
    return await enrichingPartsOfSpeech(routed, request: request)
}
```

英语内部调用全部改为 `translation.translate(request)`、
`dictionary.lookup(request)`；`enrichingPartsOfSpeech` 开头增加
`guard request.direction.target == .english else { return result }`。

- [ ] **Step 6: 将方向加入缓存键**

```swift
public struct TranslationMemoKey: Hashable, Sendable {
    public let text: String
    public let direction: TranslationDirection
    public let mode: TranslationMode
    public let configuration: String
    public let includesAlternatives: Bool

    public init(
        text: String,
        direction: TranslationDirection,
        mode: TranslationMode,
        configuration: String,
        includesAlternatives: Bool = true
    ) {
        self.text = text
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.direction = direction
        self.mode = mode
        self.configuration = configuration
        self.includesAlternatives = includesAlternatives
    }
}
```

所有 Core 测试构造 `TranslationMemoKey` 时传入
`.simplifiedChineseToEnglish`，并新增“英语和日语同配置不命中同一缓存”的断言。

- [ ] **Step 7: 运行 GlintCore 全量测试**

Run:

```bash
swift test --package-path Packages/GlintCore
```

Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add Packages/GlintCore
git commit -m "Make core translation routing direction-aware"
```

---

### Task 3: 增加目标语言偏好和旧模型迁移

**Files:**
- Delete: `Packages/GlintCore/Sources/GlintCore/Domain/TranslationModelSelection.swift`
- Create: `Packages/GlintCore/Sources/GlintCore/Domain/TranslationSelectionStore.swift`
- Delete: `Packages/GlintCore/Tests/GlintCoreTests/TranslationModelSelectionTests.swift`
- Create: `Packages/GlintCore/Tests/GlintCoreTests/TranslationSelectionStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `TranslationTarget`。
- Produces:
  - `TranslationSelectionStore(defaults:)`
  - `selectedTarget`
  - `selectedModelID(for:)`
  - `selectTarget(_:)`
  - `selectModel(_:for:)`
  - `migrateIfNeeded()`
  - `TranslationConfiguration(direction:modelID:mode:)`

- [ ] **Step 1: 写新键、幂等迁移和默认值测试**

```swift
@MainActor
final class TranslationSelectionStoreTests: XCTestCase {
    func testLegacyModelMigratesToEnglishOnlyOnce() {
        let suite = "GlintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("llm-qwen3-1.7b", forKey: "translation.modelID")

        let store = TranslationSelectionStore(defaults: defaults)
        store.migrateIfNeeded()
        XCTAssertEqual(store.selectedTarget, .english)
        XCTAssertEqual(store.selectedModelID(for: .english), "llm-qwen3-1.7b")
        XCTAssertEqual(
            store.selectedModelID(for: .japanese),
            SystemTranslationModel.appleTranslationID
        )

        store.selectModel("local-japanese", for: .japanese)
        store.migrateIfNeeded()
        XCTAssertEqual(store.selectedModelID(for: .japanese), "local-japanese")
    }

    func testTargetsRememberModelsIndependently() {
        let suite = "GlintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TranslationSelectionStore(defaults: defaults)

        store.selectModel("english-local", for: .english)
        store.selectModel("japanese-local", for: .japanese)
        store.selectTarget(.japanese)

        XCTAssertEqual(store.selectedModelID(for: .english), "english-local")
        XCTAssertEqual(store.selectedModelID(for: .japanese), "japanese-local")
        XCTAssertEqual(store.selectedTarget, .japanese)
    }
}
```

- [ ] **Step 2: 运行测试确认新存储缺失**

Run:

```bash
swift test --package-path Packages/GlintCore \
  --filter TranslationSelectionStoreTests
```

Expected: FAIL，因为 `TranslationSelectionStore` 尚不存在。

- [ ] **Step 3: 实现存储与迁移**

```swift
@MainActor
public final class TranslationSelectionStore {
    public static let defaultModelID =
        SystemTranslationModel.appleTranslationID

    private enum Key {
        static let legacyModelID = "translation.modelID"
        static let target = "translation.targetLanguage"
        static let modelEnglish = "translation.modelID.en"
        static let modelJapanese = "translation.modelID.ja"
        static let migration = "translation.multilingualMigration.v1"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var selectedTarget: TranslationTarget {
        get {
            defaults.string(forKey: Key.target)
                .flatMap(TranslationTarget.init(rawValue:))
                ?? .english
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.target)
        }
    }

    public func selectedModelID(
        for target: TranslationTarget
    ) -> String {
        defaults.string(forKey: modelKey(for: target))
            ?? Self.defaultModelID
    }

    public func selectModel(
        _ modelID: String,
        for target: TranslationTarget
    ) {
        defaults.set(modelID, forKey: modelKey(for: target))
    }

    public func migrateIfNeeded() {
        guard !defaults.bool(forKey: Key.migration) else { return }
        let legacy = defaults.string(forKey: Key.legacyModelID)
        let englishModel =
            legacy == "mt-opus-zh-en" ? Self.defaultModelID : legacy
        if defaults.object(forKey: Key.modelEnglish) == nil {
            defaults.set(
                englishModel ?? Self.defaultModelID,
                forKey: Key.modelEnglish
            )
        }
        if defaults.object(forKey: Key.modelJapanese) == nil {
            defaults.set(
                Self.defaultModelID,
                forKey: Key.modelJapanese
            )
        }
        if defaults.object(forKey: Key.target) == nil {
            defaults.set(
                TranslationTarget.english.rawValue,
                forKey: Key.target
            )
        }
        defaults.set(true, forKey: Key.migration)
    }

    private func modelKey(
        for target: TranslationTarget
    ) -> String {
        switch target {
        case .english: Key.modelEnglish
        case .japanese: Key.modelJapanese
        }
    }
}
```

保留 `SystemTranslationModel.appleTranslationID`，把其定义放到独立文件
`Domain/SystemTranslation.swift`，避免依赖已删除的旧 selection 类型。

- [ ] **Step 4: 更新 Core 构造使用**

Core 如果需要当前配置，只通过：

```swift
let direction = TranslationDirection(target: store.selectedTarget)
let modelID = store.selectedModelID(for: store.selectedTarget)
```

不得让 Core 路由或引擎再次读取 `UserDefaults`。

- [ ] **Step 5: 运行 GlintCore 测试**

Run:

```bash
swift test --package-path Packages/GlintCore
```

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add Packages/GlintCore
git commit -m "Persist translation target and per-language models"
```

---

### Task 4: 给插件 manifest 增加目标语言能力

**Files:**
- Modify: `Packages/GlintPlugins/Sources/GlintPlugins/Manifest/PluginManifest.swift`
- Modify: `Packages/GlintPlugins/Sources/GlintPlugins/Manager/ModelHubService.swift`
- Modify: `Packages/GlintPlugins/Sources/GlintPlugins/Import/LocalModelImportService.swift`
- Modify: `Packages/GlintPlugins/Tests/GlintPluginsTests/PluginManifestTests.swift`
- Modify: `Resources/catalog.json`
- Modify: `Resources/Plugins/*/manifest.json`

**Interfaces:**
- Consumes: `TranslationTarget`。
- Produces: `PluginManifest.translationTargets: [TranslationTarget]?` 和
  `supportedTranslationTargets: [TranslationTarget]`。

- [ ] **Step 1: 写旧 manifest 默认英语与新 manifest 解码测试**

```swift
func testLegacyTranslationManifestDefaultsToEnglish() throws {
    let manifest = try decodeTranslationManifest(
        extraJSON: ""
    )
    XCTAssertEqual(manifest.supportedTranslationTargets, [.english])
}

func testTranslationTargetsRoundTrip() throws {
    let manifest = try decodeTranslationManifest(
        extraJSON: #", "translationTargets": ["en", "ja"]"#
    )
    XCTAssertEqual(
        manifest.supportedTranslationTargets,
        [.english, .japanese]
    )
}
```

测试 helper 使用现有完整 manifest JSON，只在 `source` 字段前插入
`extraJSON`。

- [ ] **Step 2: 运行测试确认字段缺失**

Run:

```bash
swift test --package-path Packages/GlintPlugins \
  --filter PluginManifestTests
```

Expected: FAIL，因为 manifest 没有目标语言能力。

- [ ] **Step 3: 增加可选能力字段**

```swift
public let translationTargets: [TranslationTarget]?

public var supportedTranslationTargets: [TranslationTarget] {
    translationTargets ?? [.english]
}
```

`init` 增加参数：

```swift
translationTargets: [TranslationTarget]? = nil
```

- [ ] **Step 4: 更新生成 manifest**

`ModelHubService.manifest(...)` 和 `LocalModelImportService` 默认写入：

```swift
translationTargets: [.english]
```

当前 catalog 与所有 translation manifest 显式写入 `["en"]`。在完成日语模型探针和
评测前，不把 Qwen、Hy-MT2 或 Index-Translate 标记为日语模型。

- [ ] **Step 5: 运行 GlintPlugins 全量测试**

Run:

```bash
swift test --package-path Packages/GlintPlugins
```

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add Packages/GlintPlugins Resources
git commit -m "Declare translation model language capabilities"
```

---

### Task 5: 重构本地推理运行时并支持固定方向模型

**Files:**
- Modify: `Packages/GlintInference/Sources/GlintInference/TranslationRuntime.swift`
- Modify: `Packages/GlintInference/Sources/GlintInference/CTranslate2Engine.swift`
- Modify: `Packages/GlintInference/Tests/GlintInferenceTests/TranslationRuntimeTests.swift`

**Interfaces:**
- Consumes: `TranslationRequest`、`TranslationDirection`、`PluginManifest.supportedTranslationTargets`。
- Produces:
  - `ResolvedTranslationModel.supportedDirections`
  - `TranslationRuntime.prepare(modelID:direction:)`
  - `TranslationRuntime.activeDirection`
  - `TranslationRuntime.translate(_ request:)`
  - `CTranslate2Engine(direction:modelDirectory:libraryURL:)`

- [ ] **Step 1: 写方向拒绝和系统模型测试**

```swift
func testPreparingEnglishModelForJapaneseFails() async {
    let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
    let runtime = TranslationRuntime { _ in
        resolverCalls.withLock { $0 += 1 }
        return ResolvedTranslationModel(
            modelID: "english-only",
            storage: .mlx(
                directory: temporaryModelDirectory(),
                promptProfile: .generic
            ),
            supportedDirections: [.simplifiedChineseToEnglish]
        )
    }

    let error = await runtime.prepare(
        modelID: "english-only",
        direction: .simplifiedChineseToJapanese
    )

    XCTAssertNotNil(error)
    XCTAssertEqual(runtime.activeDirection, nil)
    XCTAssertEqual(resolverCalls.withLock { $0 }, 1)
}

private func temporaryModelDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "GlintTranslationModel-\(UUID().uuidString)",
        isDirectory: true
    )
}
```

- [ ] **Step 2: 运行测试确认旧运行时签名失败**

Run:

```bash
swift test --package-path Packages/GlintInference \
  --filter TranslationRuntimeTests
```

Expected: FAIL，因为运行时仍从 `UserDefaults` 选择模型。

- [ ] **Step 3: 将模型描述改为方向能力值**

```swift
public struct ResolvedTranslationModel: Sendable, Equatable {
    public enum Storage: Sendable, Equatable {
        case mlx(
            directory: URL,
            promptProfile: TranslationPromptProfile
        )
        case ctranslate2(directory: URL)
    }

    public let modelID: String
    public let storage: Storage
    public let supportedDirections: Set<TranslationDirection>

    public init(
        modelID: String,
        storage: Storage,
        supportedDirections: Set<TranslationDirection>
    ) {
        self.modelID = modelID
        self.storage = storage
        self.supportedDirections = supportedDirections
    }
}
```

- [ ] **Step 4: 移除运行时对 UserDefaults 的依赖**

```swift
public actor TranslationRuntime: TranslationEngine {
    public typealias ModelResolver =
        @Sendable (_ modelID: String) async ->
            ResolvedTranslationModel?

    private let systemEngine: (any TranslationEngine)?
    private let modelResolver: ModelResolver
    private(set) public var activeDirection: TranslationDirection?
    private var activeModel: ResolvedTranslationModel?
    private var activeSystemModelID: String?
    private var activeEngine: (any TranslationEngine)?
    private(set) var lastError: String?

    public init(
        systemEngine: (any TranslationEngine)? = nil,
        modelResolver: @escaping ModelResolver
    ) {
        self.systemEngine = systemEngine
        self.modelResolver = modelResolver
    }

    public func prepare(
        modelID: String,
        direction: TranslationDirection
    ) async -> String? {
        if modelID == SystemTranslationModel.appleTranslationID {
            guard let systemEngine,
                await systemEngine.supports(direction)
            else {
                activeEngine = nil
                activeDirection = nil
                lastError = "系统翻译不支持当前方向"
                return lastError
            }
            activeEngine = systemEngine
            activeDirection = direction
            activeSystemModelID = modelID
            activeModel = nil
            lastError = nil
            return nil
        }

        guard let descriptor = await modelResolver(modelID) else {
            activeEngine = nil
            activeDirection = nil
            lastError = "未找到所选翻译模型"
            return lastError
        }
        guard descriptor.supportedDirections.contains(direction) else {
            activeEngine = nil
            activeDirection = nil
            lastError = "当前模型不支持目标语言"
            return lastError
        }
        do {
            activeEngine = nil
            activeModel = nil
            activeSystemModelID = nil
            let engine = try makeEngine(
                for: descriptor,
                direction: direction
            )
            if let mlx = engine as? MLXTranslationEngine {
                try await mlx.prepareForTranslation(
                    target: direction.target
                )
                try? await mlx.warmUp(target: direction.target)
            }
            activeModel = descriptor
            activeDirection = direction
            activeEngine = engine
            lastError = nil
            return nil
        } catch {
            activeEngine = nil
            activeDirection = nil
            lastError = error.localizedDescription
            return lastError
        }
    }
}
```

- [ ] **Step 5: 更新 CTranslate2 固定方向**

```swift
public final class CTranslate2Engine: TranslationEngine {
    private let direction: TranslationDirection

    public init(
        direction: TranslationDirection,
        modelDirectory: URL,
        libraryURL: URL? = nil
    ) throws {
        self.direction = direction
        // Keep the existing dlopen/model loading body.
    }

    public func supports(
        _ direction: TranslationDirection
    ) async -> Bool {
        self.direction == direction
    }

    public func translate(
        _ request: TranslationRequest
    ) async throws -> TranslationResult? {
        guard request.direction == direction else {
            throw GlintError.engineUnavailable
        }
        // Translate request.candidate.text through the existing bridge.
    }
}
```

所有现有 CTranslate2 调用测试传入
`.simplifiedChineseToEnglish`。

- [ ] **Step 6: 运行 GlintInference runtime 测试**

Run:

```bash
swift test --package-path Packages/GlintInference \
  --filter TranslationRuntimeTests
```

Expected: PASS；首次运行仍可能需要 `scripts/prepare_opus_model.sh` 准备本地模型。

- [ ] **Step 7: 提交**

```bash
git add Packages/GlintInference
git commit -m "Decouple translation runtime from global model selection"
```

---

### Task 6: 让 MLX 提示词、探针、缓存和清洗支持日语

**Files:**
- Modify: `Packages/GlintInference/Sources/GlintInference/MLXTranslationEngine.swift`
- Modify: `Packages/GlintInference/Tests/GlintInferenceTests/MLXTranslationEngineTests.swift`

**Interfaces:**
- Consumes: `TranslationTarget`、`TranslationTextPolicy`。
- Produces:
  - `MLXPromptProfile.prompt(for:target:adapterMode:)`
  - `MLXPromptProfile.batchPrompt(for:target:)`
  - `MLXTranslationEngine.prepareForTranslation(target:)`
  - `MLXTranslationEngine.translate(_ request:)`
  - `MLXTranslationEngine.clean(_:target:)`

- [ ] **Step 1: 写日语提示词和汉字输出测试**

```swift
func testJapanesePromptTargetsJapanese() {
    let profile = MLXPromptProfile(modelID: "llm-qwen3-1.7b")
    let prompt = profile.prompt(
        for: "你好",
        target: .japanese,
        adapterMode: .translationInstruction
    )
    XCTAssertTrue(prompt.contains("日语"))
    XCTAssertFalse(prompt.contains("翻译为英语"))
}

func testJapaneseCleanAcceptsKanjiAndKana() {
    XCTAssertEqual(
        MLXTranslationEngine.clean(
            "翻訳：学生です。",
            target: .japanese
        ),
        "学生です。"
    )
}

func testEnglishCleanStillRejectsChineseEcho() {
    XCTAssertNil(
        MLXTranslationEngine.clean(
            "这是一个测试",
            target: .english
        )
    )
}
```

- [ ] **Step 2: 运行测试确认缺少 target 参数**

Run:

```bash
swift test --package-path Packages/GlintInference \
  --filter MLXTranslationEngineTests
```

Expected: FAIL。

- [ ] **Step 3: 生成目标语言提示词**

```swift
private var languageName: String {
    switch self {
    case .english: "英语"
    case .japanese: "日语"
    }
}

func prompt(
    for input: String,
    target: TranslationTarget,
    adapterMode: TranslationAdapterMode
) -> String {
    guard adapterMode == .translationInstruction else {
        return input
    }
    let language = target.languageName
    return "将以下文本翻译为\(language)，只输出翻译结果，不要解释：\n\n\(input)"
}
```

给 `TranslationTarget` 增加 UI 中文名扩展，放在 GlintCore 的
`TranslationLanguage.swift`：

```swift
public extension TranslationTarget {
    var chineseDisplayName: String {
        switch self {
        case .english: "英语"
        case .japanese: "日语"
        }
    }
}
```

`qwenSystemPrompt`、batch prompt、Hy-MT2 和 Index-Translate 也要用目标语言生成；
不得保留固定“English”。

- [ ] **Step 4: 按目标语言缓存适配器协议**

```swift
private func adapterCacheURL(
    target: TranslationTarget
) -> URL? {
    modelDirectory?.appendingPathComponent(
        ".glint-translation-adapter-\(target.rawValue).json"
    )
}
```

首次读取英语缓存时，允许读取旧 `.glint-translation-adapter.json` 并重写到 `.en.json`；
日语只读 `.ja.json`。

- [ ] **Step 5: 使用共享目标语言文本门控**

```swift
guard TranslationTextPolicy.isDisplayable(
    output,
    target: target
) else {
    return nil
}
```

保留现有 think 标签、模型控制标记、前缀和指令回显清洗；删除局部按汉字比例判断的
英文专属逻辑。

- [ ] **Step 6: 写日语探针测试**

```swift
func testJapaneseProbeAcceptsJapaneseOutput() {
    XCTAssertTrue(
        MLXTranslationEngine.isAcceptedProbeOutput(
            "こんにちは",
            expected: ["こんにちは", "ハロー"]
        )
    )
    XCTAssertFalse(
        MLXTranslationEngine.isAcceptedProbeOutput(
            "hello",
            expected: ["こんにちは", "ハロー"]
        )
    )
}
```

日语探针使用无隐私的“你好 / 天气 / 翻译”固定短词，预期至少包含日语脚本。

- [ ] **Step 7: 运行全部 GlintInference 测试**

Run:

```bash
swift test --package-path Packages/GlintInference
```

Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add Packages/GlintInference
git commit -m "Add Japanese support to MLX translation"
```

---

### Task 7: 让 Apple Translation 支持显式方向

**Files:**
- Modify: `Packages/GlintMac/Sources/GlintMac/SystemTranslation/SystemTranslationCoordinator.swift`
- Modify: `Packages/GlintMac/Sources/GlintMac/SystemTranslation/SystemTranslationEngine.swift`
- Modify: `Packages/GlintMac/Tests/GlintMacTests/SystemTranslationTests.swift`

**Interfaces:**
- Consumes: `TranslationDirection`、`TranslationRequest`。
- Produces:
  - `SystemTranslationCoordinator.currentDirection`
  - `setDirection(_:)`
  - `refreshAvailability(for:)`
  - `prepareLanguagePack(for:)`
  - `prepareInstalledSessionIfAvailable(for:)`
  - `translate(_:direction:)`
- Produces `SystemTranslationEngine.supports(_:)` 和 request-based translate。

- [ ] **Step 1: 写英语/日语语言包隔离测试**

```swift
import os

func testAvailabilityIsQueriedForCurrentDirection() async {
    let recorded = OSAllocatedUnfairLock<[TranslationDirection]>(
        initialState: []
    )
    let coordinator = SystemTranslationCoordinator(
        availabilityProvider: { direction in
            recorded.withLock { $0.append(direction) }
            return direction.target == .japanese
                ? .available
                : .installed
        }
    )

    await coordinator.setDirection(.simplifiedChineseToJapanese)
    await coordinator.refreshAvailability(
        for: .simplifiedChineseToJapanese
    )

    XCTAssertEqual(
        recorded.withLock { $0 },
        [.simplifiedChineseToJapanese]
    )
    XCTAssertEqual(coordinator.availability, .available)
}
```

- [ ] **Step 2: 运行测试确认固定英文会话**

Run:

```bash
swift test --package-path Packages/GlintMac \
  --filter SystemTranslationCoordinatorTests
```

Expected: FAIL。

- [ ] **Step 3: 将固定 Locale 改为方向映射**

```swift
private static func languages(
    for direction: TranslationDirection
) -> (Locale.Language, Locale.Language) {
    (
        Locale.Language(identifier: direction.source.rawValue),
        Locale.Language(identifier: direction.target.rawValue)
    )
}
```

`makeConfiguration()` 方法接收方向；`TranslationSession.Configuration` 使用映射结果。

- [ ] **Step 4: 方向切换使旧 session 失效**

```swift
public func setDirection(
    _ direction: TranslationDirection
) async {
    guard currentDirection != direction else { return }
    currentDirection = direction
    sessionGeneration &+= 1
    driver = nil
    configuration = nil
    signalIdleLoop()
    failDriverWaiters()
    failPendingRequests(SystemTranslationError.sessionUnavailable)
    availability = nil
    stopAvailabilityMonitoring()
}
```

旧代次完成时仍由现有 `generation == sessionGeneration` 守卫阻止恢复。

- [ ] **Step 5: request 校验方向**

```swift
public func translate(
    _ text: String,
    direction: TranslationDirection
) async throws -> String {
    guard direction == currentDirection else {
        throw SystemTranslationError.sessionUnavailable
    }
    // Existing request queue body.
}
```

`SystemTranslationEngine`：

```swift
public func supports(
    _ direction: TranslationDirection
) async -> Bool {
    // Conservative until availability has been queried.
    true
}

public func translate(
    _ request: TranslationRequest
) async throws -> TranslationResult? {
    let output = try await coordinator.translate(
        request.candidate.text,
        direction: request.direction
    )
    return output.isEmpty ? nil : TranslationResult(text: output)
}
```

- [ ] **Step 6: 更新动态错误文案**

```swift
case .unsupported:
    "当前 Mac 不支持中文到\(target.chineseDisplayName)翻译"
```

如错误枚举无法携带 target，则错误本身使用中性文案“当前 Mac 不支持该翻译方向”，
具体语言的安装说明由 UI 生成。

- [ ] **Step 7: 运行 GlintMac SystemTranslation 测试**

Run:

```bash
swift test --package-path Packages/GlintMac \
  --filter SystemTranslation
```

Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add Packages/GlintMac
git commit -m "Make Apple translation direction-aware"
```

---

### Task 8: 将方向和目标语言传入候选监控与 HUD

**Files:**
- Modify: `Packages/GlintMac/Sources/GlintMac/MonitoringSession.swift`
- Modify: `Packages/GlintMac/Sources/GlintMac/MonitoringController.swift`
- Modify: `Packages/GlintMac/Sources/GlintMac/CandidateTranslationPipeline.swift`
- Modify: `Packages/GlintMac/Tests/GlintMacTests/GlintMacTests.swift`

**Interfaces:**
- Consumes: request-based `SmartRouter`、`TranslationTextPolicy`。
- Produces:
  - `MonitoringSettings.translationTarget`
  - `MonitoringController.setTranslationTarget(_:)`
  - `CandidateTranslationPipeline.translate(... target:)`

- [ ] **Step 1: 写日语 HUD 过滤和词典预取测试**

```swift
func testJapaneseKanjiTranslationRemainsDisplayable() async {
    let presentations = await CandidateTranslationPipeline.translate(
        [Candidate(text: "学生")],
        selectedIndex: 0,
        mode: .dictionaryFirst,
        target: .japanese,
        configurationToken: "ja-model",
        router: SmartRouter(
            dictionary: EmptyDictionary(),
            translation: JapaneseTranslation()
        ),
        memo: TranslationMemo()
    )

    XCTAssertEqual(presentations.first?.translation, "学生")
}

func testJapaneseNeverPrefetchesDictionary() {
    XCTAssertFalse(
        MonitoringController.shouldPrefetchDictionary(
            target: .japanese,
            mode: .dictionaryFirst,
            scope: .selected
        )
    )
}

private struct JapaneseTranslation: TranslationEngine {
    func supports(
        _ direction: TranslationDirection
    ) async -> Bool {
        direction.target == .japanese
    }

    func translate(
        _ request: TranslationRequest
    ) async throws -> TranslationResult? {
        TranslationResult(text: "学生")
    }
}
```

- [ ] **Step 2: 运行测试确认缺少 target**

Run:

```bash
swift test --package-path Packages/GlintMac \
  --filter GlintMacTests
```

Expected: FAIL。

- [ ] **Step 3: 将目标语言加入监控设置**

```swift
public struct MonitoringSettings: Sendable, Equatable {
    public let mode: TranslationMode
    public let translationTarget: TranslationTarget
    // Existing fields remain.
}
```

`applyStart` 调用 `setTranslationTarget`，`MonitoringController` 保存值并在新候选
revision 的 pipeline 输入中使用。

- [ ] **Step 4: 构造方向请求**

```swift
let request = TranslationRequest(
    candidate: candidate,
    direction: TranslationDirection(target: translationTarget)
)
let routed = try await router.route(
    request,
    mode: mode,
    includesAlternatives: includesAlternatives,
    dictionaryPrefetch: dictionaryPrefetch
)
```

所有 `memoKey` 同时接收 target。

- [ ] **Step 5: 用共享文本策略替换本地汉字比例判断**

```swift
private static func isDisplayable(
    _ result: TranslationResult,
    target: TranslationTarget
) -> Bool {
    TranslationTextPolicy.isDisplayable(
        result.displayText,
        target: target
    )
}
```

`presentation(...)`、`presentationResult(...)` 以及所有相关测试传入 target。

- [ ] **Step 6: 日语关闭词性元数据**

在 `CandidateTranslationOptionPresentation` 和展示分支中增加 target 条件：
仅 `target == .english` 且当前设置允许时才携带词性。

- [ ] **Step 7: 运行 GlintMac 全量测试**

Run:

```bash
swift test --package-path Packages/GlintMac
```

Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add Packages/GlintMac
git commit -m "Propagate translation target through monitoring"
```

---

### Task 9: 重构 UI 模型并把“语言与翻译”做成独立页面

**Files:**
- Modify: `Packages/GlintUI/Sources/GlintUI/MainWindow/MainWindowModel.swift`
- Create: `Packages/GlintUI/Sources/GlintUI/Pages/LanguageTranslationPage.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/MainWindow/MainWindowView.swift`
- Modify: `Packages/GlintUI/Tests/GlintUITests/MainWindowModelTests.swift`
- Create: `Packages/GlintUI/Tests/GlintUITests/LanguageTranslationPageTests.swift`

**Interfaces:**
- Consumes: `TranslationSelectionStore`、`PluginManifest.supportedTranslationTargets`。
- Produces:
  - `SidebarItem.languageTranslation`
  - `MainWindowModel.translationTarget`
  - `availableTranslationModels`
  - `changeTranslationTargetAction`
  - `selectTranslationModelAction`
  - `TranslationReadiness`

- [ ] **Step 1: 写模型状态和过滤测试**

```swift
@MainActor
func testLanguageSwitchUpdatesPerLanguageModelSelection() async throws {
    let context = try makeMultilingualContext()
    defer { context.cleanup() }
    context.model.changeTranslationTargetAction = { target in
        .ready(target)
    }

    await context.model.setTranslationTarget(.japanese)

    XCTAssertEqual(context.model.translationTarget, .japanese)
    XCTAssertEqual(
        context.model.activeModelID,
        SystemTranslationModel.appleTranslationID
    )
    XCTAssertEqual(
        context.store.selectedModelID(for: .english),
        SystemTranslationModel.appleTranslationID
    )
}

func testJapaneseFiltersEnglishOnlyModels() {
    let manifest = translationManifest(
        id: "english-only",
        targets: [.english]
    )
    XCTAssertFalse(
        MainWindowModel.supports(
            manifest,
            target: .japanese
        )
    )
}

private struct MultilingualContext {
    let model: MainWindowModel
    let store: TranslationSelectionStore
    let defaults: UserDefaults
    let suiteName: String
    let root: URL

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeMultilingualContext() throws -> MultilingualContext {
    let suiteName = "GlintMultilingual.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let store = TranslationSelectionStore(defaults: defaults)
    store.migrateIfNeeded()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(suiteName, isDirectory: true)
    return MultilingualContext(
        model: MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil,
            defaults: defaults,
            translationSelectionStore: store
        ),
        store: store,
        defaults: defaults,
        suiteName: suiteName,
        root: root
    )
}
```

- [ ] **Step 2: 运行测试确认新状态不存在**

Run:

```bash
swift test --package-path Packages/GlintUI \
  --filter MainWindowModelTests
```

Expected: FAIL。

- [ ] **Step 3: 在模型中加入目标语言和准备状态**

```swift
public private(set) var translationTarget: TranslationTarget
public private(set) var translationReadiness: TranslationReadiness = .idle
public private(set) var isChangingTranslationTarget = false

public var isEnglishTarget: Bool {
    translationTarget == .english
}

public static func supports(
    _ plugin: PluginManifest,
    target: TranslationTarget
) -> Bool {
    plugin.type == .translation
        && plugin.supportedTranslationTargets.contains(target)
}
```

`activeModelID` 从 `TranslationSelectionStore.selectedModelID(for:)` 初始化；
所有激活、释放和更新检查都显式使用当前 target。

`MainWindowModel.init` 增加可选参数：

```swift
translationSelectionStore: TranslationSelectionStore? = nil
```

未注入时用同一个 `defaults` 创建并执行 `migrateIfNeeded()`，保证测试和 App 只有一条
初始化路径。

- [ ] **Step 4: 提供语言页所需的动作接口**

```swift
@ObservationIgnored
public var changeTranslationTargetAction:
    @MainActor (TranslationTarget) async -> TranslationReadiness = {
        _ in .failed("翻译语言切换不可用")
    }

@ObservationIgnored
public var selectTranslationModelAction:
    @MainActor (String, TranslationTarget) async -> TranslationReadiness = {
        _, _ in .failed("翻译模型切换不可用")
    }
```

模型方法先设置 `isChangingTranslationTarget`，调用动作后更新 target、activeModelID、
readiness 和配置变更回调。失败时保留用户选择的目标语言。

- [ ] **Step 5: 实现独立语言页**

```swift
struct LanguageTranslationPage: View {
    let model: MainWindowModel

    var body: some View {
        PageContainer {
            SettingsCard("学习语言", systemImage: "character.bubble") {
                LanguageTargetSection(model: model)
            }
            SettingsCard("翻译方式") {
                TranslationStrategySection(model: model)
            }
            SettingsCard("当前翻译模型") {
                ActiveTranslationModelSection(model: model)
            }
            SettingsCard("朗读语音") {
                TranslationVoiceSection(model: model)
            }
        }
    }
}
```

`LanguageTargetSection` 使用 `.pickerStyle(.segmented)`；
`TranslationStrategySection` 在日语状态只显示“模型翻译”和说明；
`ActiveTranslationModelSection` 只列出 Apple 与兼容已安装模型；
`TranslationVoiceSection` 仅在英语状态显示英语口音。

- [ ] **Step 6: 将口音设置从通用页迁入语言页**

`LanguageTranslationPage` 读取并写入
`generalPreferences.speechAccent`。不新增口音持久化格式。

- [ ] **Step 7: 增加侧栏项并接入页面**

```swift
case languageTranslation

case .languageTranslation:
    Label("语言与翻译", systemImage: "character.bubble")
```

在 `detailView` 中返回 `LanguageTranslationPage(model: model)`，位置在
`.inputMethods` 与 `.display` 之间。

- [ ] **Step 8: 运行 GlintUI 相关测试**

Run:

```bash
swift test --package-path Packages/GlintUI \
  --filter MainWindowModelTests
swift test --package-path Packages/GlintUI \
  --filter LanguageTranslationPageTests
```

Expected: PASS。

- [ ] **Step 9: 提交**

```bash
git add Packages/GlintUI
git commit -m "Add language and translation settings page"
```

---

### Task 10: 调整概览、插件页、通用页和显示页

**Files:**
- Modify: `Packages/GlintUI/Sources/GlintUI/MainWindow/OverviewPage.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/MainWindow/MainWindowModel.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/MainWindow/SettingsPresentation.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/Pages/PluginsPage.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/Pages/GeneralPage.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/Pages/DisplayPage.swift`
- Modify: `Packages/GlintUI/Tests/GlintUITests/OverviewFormattingTests.swift`
- Modify: `Packages/GlintUI/Tests/GlintUITests/MainWindowModelTests.swift`
- Modify: `Packages/GlintUI/Tests/GlintUITests/DisplayPreferencesTests.swift`

**Interfaces:**
- Consumes: `MainWindowModel.translationTarget`、模型能力过滤。
- Produces: 概览状态流、资源页标签和按语言收口的显示控件。

- [ ] **Step 1: 写概览和页面条件测试**

```swift
func testStatusFlowUsesLanguageInsteadOfRecognition() {
    XCTAssertEqual(
        OverviewFormatting.statusSteps(
            target: .japanese,
            mode: .dictionaryFirst,
            modelName: "Apple 翻译"
        ).map(\.title),
        ["输入", "语言", "策略", "翻译"]
    )
}

func testJapaneseHidesEnglishOnlyDisplayCapabilities() {
    XCTAssertFalse(
        TranslationTarget.japanese.supportsPartsOfSpeech
    )
    XCTAssertFalse(
        TranslationTarget.japanese.supportsMultipleMeanings
    )
    XCTAssertTrue(
        TranslationTarget.english.supportsMultipleMeanings
    )
}
```

- [ ] **Step 2: 运行测试确认缺少条件模型**

Run:

```bash
swift test --package-path Packages/GlintUI \
  --filter DisplayPreferencesTests
swift test --package-path Packages/GlintUI \
  --filter OverviewFormattingTests
```

Expected: FAIL。

- [ ] **Step 3: 概览状态流固定为四步**

第二个单元改为语言，删除“识别当前候选”展示：

```swift
struct OverviewStatusStep: Equatable {
    let title: String
    let value: String
}

static func statusSteps(
    target: TranslationTarget,
    mode: TranslationMode,
    modelName: String
) -> [OverviewStatusStep] {
    [
        OverviewStatusStep(title: "输入", value: "中文拼音"),
        OverviewStatusStep(
            title: "语言",
            value: target.chineseDisplayName
        ),
        OverviewStatusStep(
            title: "策略",
            value: target == .english
                ? mode.title
                : "模型翻译"
        ),
        OverviewStatusStep(title: "翻译", value: modelName),
    ]
}

OverviewStatusStep(
    title: "语言",
    value: model.translationTarget.chineseDisplayName,
    actionHint: "打开语言与翻译"
)
```

点击语言单元直接设置 `selection = .languageTranslation`。

在 `SettingsPresentation.swift` 提供目标能力：

```swift
extension TranslationTarget {
    var supportsPartsOfSpeech: Bool {
        self == .english
    }

    var supportsMultipleMeanings: Bool {
        self == .english
    }
}
```

- [ ] **Step 4: 插件页展示能力而不是切换当前配置**

```swift
private func supportedTargetLabel(
    for plugin: PluginManifest
) -> String {
    let targets = plugin.supportedTranslationTargets
    switch Set(targets) {
    case [.english]: "仅英语"
    case [.japanese]: "仅日语"
    case [.english, .japanese]: "英语 / 日语"
    default: "未验证"
    }
}
```

- 已安装模型行保留更新、卸载等资源动作。
- 删除“使用/切换”按钮；当前模型只显示“使用中”。
- 与当前目标不兼容的模型降低视觉权重并显示能力标签。
- 英文词典在日语状态显示“仅英语参与路由”。
- 安装模型后不自动切换当前模型。

同时调整现有自动激活路径：

- 市场安装和本地导入完成后只执行兼容性验证，不调用
  `selectTranslationModelAction`，不修改当前 `activeModelID`。
- 本地导入验证需要临时准备模型时，验证结束后释放临时资源并恢复导入前已加载模型。
- 更新当前模型时保持同一 target 和 model ID，重新准备当前模型并刷新配置 token。

- [ ] **Step 5: 通用页移除翻译专属设置**

删除 `GeneralPage` 的“翻译”卡片和“英语口音”分段控件；保留插入、朗读快捷键、
朗读语速、自动朗读和基础卡片。

- [ ] **Step 6: 显示页按目标语言收口**

```swift
if model.isEnglishTarget {
    // Existing “显示词性” row.
}

if model.translationTarget == .english
    || preferences.translationScope == .row
{
    // Existing translation count control.
}
```

范围说明使用
`"只显示当前高亮候选对应的\(target.chineseDisplayName)译文..."`。
HUD 预览根据 target 使用英语或日语样例。

- [ ] **Step 7: 更新动态文案**

遍历 `GlintUI` 搜索“英文翻译”“英语口音”“当前候选”，只保留英语能力明确适用的
文案；Apple 语言包说明使用 target，不固定写“中文到英文”。

- [ ] **Step 8: 运行 GlintUI 全量测试**

Run:

```bash
swift test --package-path Packages/GlintUI
```

Expected: PASS。

- [ ] **Step 9: 提交**

```bash
git add Packages/GlintUI
git commit -m "Adapt settings surfaces to the active language"
```

---

### Task 11: 实现 App 层语言切换协调器、监控恢复和语音方向

**Files:**
- Create: `App/Glint/TranslationLanguageCoordinator.swift`
- Modify: `App/Glint/AppEnvironment.swift`
- Modify: `App/Glint/AppDelegate.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/Speech/TranslationSpeechController.swift`
- Modify: `Packages/GlintUI/Sources/GlintUI/Settings/GeneralPreferences.swift`
- Modify: `Packages/GlintUI/Tests/GlintUITests/TranslationSpeechTests.swift`
- Create: `App/GlintTests/TranslationLanguageCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 2–10 的全部方向化 API。
- Produces:
  - `TranslationLanguageCoordinator`
  - `TranslationReadiness`
  - `selectModel(_:for:)`
  - `retryCurrentConfiguration()`
  - `TranslationSpeechController.speak(_:target:englishAccent:rate:source:)`

- [ ] **Step 1: 写切换事务测试**

```swift
@MainActor
final class TranslationLanguageCoordinatorTests: XCTestCase {
    func testSwitchPersistsTargetAndRestoresMonitoringWhenReady()
        async
    {
        let harness = CoordinatorHarness()
        harness.languageRuntime.prepareResult = nil
        harness.wasMonitoring = true

        let readiness = await harness.coordinator.switchTarget(
            to: .japanese
        )

        XCTAssertEqual(readiness, .ready(.japanese))
        XCTAssertEqual(harness.store.selectedTarget, .japanese)
        XCTAssertEqual(harness.stopCalls, 1)
        XCTAssertEqual(harness.resumeCalls, 1)
    }

    func testNeedsLanguagePackKeepsJapaneseAndDoesNotResume()
        async
    {
        let harness = CoordinatorHarness()
        harness.system.availabilityValue = .available
        harness.wasMonitoring = true

        let readiness = await harness.coordinator.switchTarget(
            to: .japanese
        )

        XCTAssertEqual(
            readiness,
            .needsSetup(.japanese, "需要安装语言包")
        )
        XCTAssertEqual(harness.store.selectedTarget, .japanese)
        XCTAssertEqual(harness.resumeCalls, 0)
    }
}

@MainActor
private final class CoordinatorHarness {
    let store: TranslationSelectionStore
    let languageRuntime = StubLanguageRuntime()
    let system = StubSystemTranslationLanguageProvider()
    let coordinator: TranslationLanguageCoordinator
    var wasMonitoring = false
    var stopCalls = 0
    var resumeCalls = 0

    init() {
        let suite = "GlintCoordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        store = TranslationSelectionStore(defaults: defaults)
        store.migrateIfNeeded()
        coordinator = TranslationLanguageCoordinator(
            store: store,
            languageRuntime: languageRuntime,
            system: system
        )
        coordinator.wasMonitoring = { [weak self] in
            self?.wasMonitoring ?? false
        }
        coordinator.stopActiveOutput = { [weak self] in
            self?.stopCalls += 1
        }
        coordinator.resumeMonitoring = { [weak self] in
            self?.resumeCalls += 1
        }
    }
}

@MainActor
private final class StubLanguageRuntime:
    TranslationLanguageRuntimeProviding
{
    var prepareResult: String?

    func prepare(
        modelID: String,
        direction: TranslationDirection
    ) async -> String? {
        prepareResult
    }

    func releaseResources(for modelID: String) async {}
}

@MainActor
private final class StubSystemTranslationLanguageProvider:
    SystemTranslationLanguageProviding
{
    var availabilityValue: SystemTranslationAvailability?
    var availability: SystemTranslationAvailability? {
        availabilityValue
    }

    func setDirection(_ direction: TranslationDirection) async {}

    func refreshAvailability(
        for direction: TranslationDirection
    ) async {}

    func prepareInstalledSessionIfAvailable(
        for direction: TranslationDirection
    ) async -> Bool {
        availabilityValue?.canSelect == true
    }
}
```

- [ ] **Step 2: 运行测试确认协调器缺失**

Run:

```bash
xcodebuild test \
  -workspace Glint.xcworkspace \
  -scheme Glint \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:GlintTests/TranslationLanguageCoordinatorTests
```

Expected: FAIL，因为协调器尚不存在。

- [ ] **Step 3: 定义可测试的协调器边界**

```swift
@MainActor
final class TranslationLanguageCoordinator {
    private let store: TranslationSelectionStore
    private let languageRuntime: any TranslationLanguageRuntimeProviding
    private let system: any SystemTranslationLanguageProviding
    private var generation: UInt64 = 0
    private var pendingResume = false

    var wasMonitoring: @MainActor () -> Bool = { false }
    var stopActiveOutput: @MainActor () async -> Void = {}
    var clearTranslationCache: @MainActor () -> Void = {}
    var resumeMonitoring: @MainActor () async -> Void = {}

    init(
        store: TranslationSelectionStore,
        languageRuntime: any TranslationLanguageRuntimeProviding,
        system: any SystemTranslationLanguageProviding
    ) {
        self.store = store
        self.languageRuntime = languageRuntime
        self.system = system
    }

    func switchTarget(
        to target: TranslationTarget
    ) async -> TranslationReadiness {
        guard target != store.selectedTarget else {
            return .ready(target)
        }
        generation &+= 1
        let transaction = generation
        let shouldResume = wasMonitoring()
        pendingResume = shouldResume
        store.selectedTarget = target
        await stopActiveOutput()
        clearTranslationCache()

        let direction = TranslationDirection(target: target)
        if store.selectedModelID(for: target)
            == SystemTranslationModel.appleTranslationID
        {
            await system.setDirection(direction)
            await system.refreshAvailability(
                for: direction
            )
            guard system.availability?.canSelect == true else {
                pendingResume = shouldResume
                return .needsSetup(
                    target,
                    "需要安装 Apple 翻译语言包"
                )
            }
            guard await system
                .prepareInstalledSessionIfAvailable(for: direction)
            else {
                pendingResume = shouldResume
                return .failed(
                    target,
                    "系统翻译会话不可用"
                )
            }
        } else if let error = await languageRuntime.prepare(
            modelID: store.selectedModelID(for: target),
            direction: direction
        ) {
            pendingResume = shouldResume
            return .failed(target, error)
        }

        guard transaction == generation else {
            return .superseded
        }
        if shouldResume {
            await resumeMonitoring()
            pendingResume = false
        }
        return .ready(target)
    }

    func selectModel(
        _ modelID: String,
        for target: TranslationTarget
    ) async -> TranslationReadiness {
        guard target == store.selectedTarget else {
            return .failed(target, "请先切换到目标语言")
        }
        generation &+= 1
        let transaction = generation
        let shouldResume = pendingResume || wasMonitoring()
        pendingResume = shouldResume
        await stopActiveOutput()
        clearTranslationCache()
        store.selectModel(modelID, for: target)
        let direction = TranslationDirection(target: target)

        let readiness: TranslationReadiness
        if modelID == SystemTranslationModel.appleTranslationID {
            await system.setDirection(direction)
            await system.refreshAvailability(for: direction)
            if system.availability?.canSelect == true,
                await system.prepareInstalledSessionIfAvailable(
                    for: direction
                )
            {
                readiness = .ready(target)
            } else {
                readiness = .needsSetup(
                    target,
                    "需要安装 Apple 翻译语言包"
                )
            }
        } else if let error = await languageRuntime.prepare(
            modelID: modelID,
            direction: direction
        ) {
            readiness = .failed(target, error)
        } else {
            readiness = .ready(target)
        }

        guard transaction == generation else {
            return .superseded
        }
        if readiness == .ready(target), shouldResume {
            await resumeMonitoring()
            pendingResume = false
        }
        return readiness
    }

    func retryCurrentConfiguration() async -> TranslationReadiness {
        await selectModel(
            store.selectedModelID(for: store.selectedTarget),
            for: store.selectedTarget
        )
    }

    func cancelPendingResume() {
        pendingResume = false
    }
}
```

`TranslationReadiness` 定义在 GlintCore 或 App 可共享的 UI 模型文件中：

```swift
public enum TranslationReadiness:
    Sendable, Equatable
{
    case idle
    case preparing(TranslationTarget)
    case ready(TranslationTarget)
    case needsSetup(TranslationTarget, String)
    case failed(TranslationTarget, String)
    case unsupported(TranslationTarget)
    case superseded
}
```

- [ ] **Step 4: 给运行时提供窄协议，避免 App 协调器依赖具体实现细节**

```swift
@MainActor
protocol TranslationLanguageRuntimeProviding {
    func prepare(
        modelID: String,
        direction: TranslationDirection
    ) async -> String?
    func releaseResources(for modelID: String) async
}

@MainActor
protocol SystemTranslationLanguageProviding {
    var availability: SystemTranslationAvailability? { get }
    func setDirection(_ direction: TranslationDirection) async
    func refreshAvailability(
        for direction: TranslationDirection
    ) async
    func prepareInstalledSessionIfAvailable(
        for direction: TranslationDirection
    ) async -> Bool
}

extension SystemTranslationCoordinator:
    SystemTranslationLanguageProviding {}
```

`TranslationRuntime` 和测试 harness 都通过小型 adapter 满足该协议。

```swift
@MainActor
final class TranslationLanguageRuntimeAdapter:
    TranslationLanguageRuntimeProviding
{
    private let runtime: TranslationRuntime

    init(runtime: TranslationRuntime) {
        self.runtime = runtime
    }

    func prepare(
        modelID: String,
        direction: TranslationDirection
    ) async -> String? {
        await runtime.prepare(
            modelID: modelID,
            direction: direction
        )
    }

    func releaseResources(for modelID: String) async {
        await runtime.releaseResources(for: modelID)
    }
}
```

- [ ] **Step 5: AppDelegate 接入切换顺序**

新增不可变依赖：

```swift
private let translationLanguageCoordinator:
    TranslationLanguageCoordinator
```

在 `super.init()` 前使用同一个 `selectionStore`、运行时 adapter 和
`SystemTranslationCoordinator` 构造；`super.init()` 后再绑定监控和 HUD 回调。

在 `configureWindowModel()` 中设置：

```swift
windowModel.changeTranslationTargetAction = { [weak self] target in
    guard let self else {
        return .failed(target, "翻译运行时不可用")
    }
    return await self.translationLanguageCoordinator
        .switchTarget(to: target)
}

windowModel.selectTranslationModelAction = { [weak self] modelID, target in
    guard let self else {
        return .failed(target, "翻译运行时不可用")
    }
    return await self.translationLanguageCoordinator
        .selectModel(modelID, for: target)
}
```

协调器的 `stopActiveOutput` 调用：

1. `translationAutoSpeechScheduler.cancel()`
2. `translationSpeechController.stop()`
3. `hudEventCoordinator.hide(animated: false)`
4. `environment.monitoringSession.stop()`

`resumeMonitoring` 调用现有单实例 `startMonitoring` 路径。不能使用 `open`、不能新建
App 进程、不能跳过 readiness。

用户显式关闭翻译显示时，`stopMonitoring()` 调用
`translationLanguageCoordinator.cancelPendingResume()`，防止随后安装语言包时意外
重新开启。

现有 `prepareSystemTranslationAction` 在成功得到 `.installed` 后调用
`translationLanguageCoordinator.retryCurrentConfiguration()`，并把返回值写入
`windowModel.translationReadiness`。因此日语语言包安装完成后可自动恢复之前开启的
翻译显示，同时仍尊重用户中途主动关闭的状态。

- [ ] **Step 6: 配置 token 和监控设置加入 target**

```swift
private var translationConfigurationToken: String {
    ([
        "target=\(windowModel.translationTarget.rawValue)",
        "model=\(windowModel.activeModelID)",
        "prompt=2",
    ] + pluginVersions).joined(separator: "|")
}

private var monitoringSettings: MonitoringSettings {
    MonitoringSettings(
        mode: windowModel.translationMode,
        translationTarget: windowModel.translationTarget,
        // Existing fields.
    )
}
```

- [ ] **Step 7: 让语音控制器显式选择 target**

```swift
public func speak(
    _ text: String,
    target: TranslationTarget,
    accent: TranslationSpeechAccent,
    rate: TranslationSpeechRate = .standard,
    source: TranslationSpeechSource = .manual
) {
    let languageCode =
        target == .english
        ? accent.languageCode(
            preferredLanguages: preferredLanguages()
        )
        : "ja-JP"
    // Resolve voice from languageCode; never fall back to en-US for Japanese.
}
```

AppDelegate 三处 `speak` 调用都传 `windowModel.translationTarget`。

- [ ] **Step 8: 更新 AppEnvironment 模型解析器**

```swift
let directions = Set(
    manifest.supportedTranslationTargets.map {
        TranslationDirection(target: $0)
    }
)
return ResolvedTranslationModel(
    modelID: modelID,
    storage: .mlx(
        directory: directory,
        promptProfile: manifest.promptProfile
            ?? .inferred(from: modelID)
    ),
    supportedDirections: directions
)
```

CTranslate2 描述同样从 manifest 构造方向集合，并继续限制固定 ID。

同时把 `TranslationSelectionStore` 注入 `AppEnvironment` 和 `MainWindowModel`：

```swift
let selectionStore = TranslationSelectionStore()
selectionStore.migrateIfNeeded()
let environment = AppEnvironment(
    selectionStore: selectionStore
)
let windowModel = MainWindowModel(
    pluginManager: environment.pluginManager,
    builtInPlugins: BundledPluginResources.manifests,
    translationSelectionStore: selectionStore
)
```

删除 `AppDelegate.init` 对旧 `TranslationModelSelection` 的调用。启动准备顺序改为：

1. 读取 `selectionStore.selectedTarget` 和该 target 的模型 ID。
2. 为非 Apple 模型调用
   `translationRuntime.prepare(modelID:direction:)`。
3. 为 Apple 模型先对当前方向刷新 availability，再准备已安装会话。
4. 不受支持的系统方向或不可用语言包保持 `needsSetup`，不得启动监控。

- [ ] **Step 9: 运行 App 协调器测试和 UI 语音测试**

Run:

```bash
xcodebuild test \
  -workspace Glint.xcworkspace \
  -scheme Glint \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:GlintTests/TranslationLanguageCoordinatorTests
swift test --package-path Packages/GlintUI \
  --filter TranslationSpeechTests
```

Expected: PASS。

- [ ] **Step 10: 提交**

```bash
git add App/Glint Packages/GlintUI
git commit -m "Coordinate multilingual translation switching"
```

---

### Task 12: 完成资源、文档、兼容验证和日语评测门禁

**Files:**
- Modify: `AGENTS.md`
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/MODEL-EVALUATION.md`
- Modify: `docs/MACOS-COMPATIBILITY.md`
- Modify: `Resources/catalog.json`
- Modify: `Resources/Plugins/*/manifest.json`
- Create: `Resources/Evaluation/japanese-translation-benchmark.json`
- Modify: `scripts/run_apple_translation_compare.sh`
- Modify: `Tools/GlintEval/Sources/GlintEvalSupport/AppleTranslationEvaluationOptions.swift`
- Modify: `Tools/GlintEval/Sources/AppleTranslationCompare/AppleTranslationBenchmark.swift`

**Interfaces:**
- Consumes: 全部实现。
- Produces: 可发布的中日语言包验证、模型能力文案、中日评测报告和长期架构文档。

- [ ] **Step 1: 添加中日评测数据结构**

`Resources/Evaluation/japanese-translation-benchmark.json` 至少包含：

```json
{
  "cases": [
    {
      "text": "你好",
      "kind": "word",
      "expected": ["こんにちは", "ハロー"],
      "forbidden": ["你好", "hello"]
    },
    {
      "text": "今天天气不错",
      "kind": "sentence",
      "expected": ["今日はいい天気です。", "今日は天気がいいですね。"],
      "forbidden": ["The weather is nice today.", "今天天气不错"]
    }
  ]
}
```

最终文件必须包含 120 条以上用例，其中 50 条为高频产品场景；测试数据不包含用户输入。

- [ ] **Step 2: 将评测工具参数化方向**

```swift
public struct TranslationBenchmarkDirection:
    Sendable, Equatable
{
    public let source: String
    public let target: String

    public static let chineseEnglish =
        TranslationBenchmarkDirection(source: "zh-Hans", target: "en")
    public static let chineseJapanese =
        TranslationBenchmarkDirection(source: "zh-Hans", target: "ja")
}
```

`AppleTranslationEvaluationOptions` 增加 `--direction zh-ja`；未提供时保持 `zh-en`，
确保现有英文评测不回归。

`AppleTranslationBenchmark.run` 根据 direction 建立
`TranslationSession.Configuration` 和 `LanguageAvailability` 查询。目标为日语时不再
使用中英 `mt-opus-zh-en` 作为第二引擎；报告中 `opusMT` 改为可选字段，`zh-en` 模式
继续填写既有对照数据，`zh-ja` 模式只记录 Apple Translation 和已显式提供的兼容模型。

`scripts/run_apple_translation_compare.sh` 增加：

```bash
direction="${GLINT_APPLE_TRANSLATION_DIRECTION:-zh-en}"

open -W "$app_path" --args \
    --cases "$cases_path" \
    --ct2 "$ct2_path" \
    --output "$output_path" \
    --rounds "$rounds" \
    --direction "$direction"
```

- [ ] **Step 3: 使用 Apple 可用性 API 验证当前主机**

Run:

```bash
swift -e 'import Foundation; import Translation; Task { @MainActor in let a = LanguageAvailability(); let s = await a.status(from: Locale.Language(identifier: "zh-Hans"), to: Locale.Language(identifier: "ja")); print(s); exit(0) }; RunLoop.main.run()'
```

Expected: 输出 `.supported` 或 `.installed`；`.unsupported` 时停止发布并在兼容文档记录
具体系统版本。

- [ ] **Step 4: 更新产品与架构文档**

- `AGENTS.md` 产品边界改为中文到英语或日语，明确日语只走模型和单目标全局选择。
- `README.md` 去掉“英文学习工具”和“英文翻译”的唯一前提，说明可选择英语或日语。
- `docs/ARCHITECTURE.md` 增加方向、能力、语言页、切换协调器和日语 HUD 规则。
- `docs/MODEL-EVALUATION.md` 增加中日评测表、系统状态和发布结论。
- `docs/MACOS-COMPATIBILITY.md` 增加 macOS 15/26 `zh-Hans → ja` 语言包验证。
- Release Notes 只使用用户可感知的“新增日语翻译”等短标签。

- [ ] **Step 5: 更新资源 manifest 能力**

实际支持日语的模型才写入 `"translationTargets": ["en", "ja"]`；未通过探针和评测的模型
继续只写 `["en"]`。Apple Translation 不进入插件 manifest。

- [ ] **Step 6: 运行模块测试**

Run:

```bash
swift test --package-path Packages/GlintCore
swift test --package-path Packages/GlintMac
swift test --package-path Packages/GlintDictionary
swift test --package-path Packages/GlintInference
swift test --package-path Packages/GlintPlugins
swift test --package-path Packages/GlintUI
```

Expected: 全部 PASS；需要模型资产的测试按仓库约定准备或明确 Skip。

- [ ] **Step 7: 运行完整回归**

Run:

```bash
./scripts/test.sh
```

Expected: 全部 PASS。

- [ ] **Step 8: 运行增量真实 App**

Run:

```bash
./scripts/dev.sh
```

Expected: 构建通过，稳定签名，只有一个 Debug App 实例，readiness token 成功，监控启动。

- [ ] **Step 9: 真实 App 验收**

在 App 中完成并记录：

1. 英语概览状态流为“输入 → 语言 → 策略 → 翻译”。
2. 英语词典、词性、英语口音和三种模式正常。
3. 切到日语后目标立即变为日语；语言包缺失时显示准备入口且翻译暂停。
4. 安装日语语言包后，在原本开启翻译显示的情况下自动恢复。
5. 日语界面隐藏模式、词性和释义数量，模型页标记英文专用模型。
6. 日语 HUD 显示“学生”“こんにちは”等含汉字结果，不被过滤。
7. 日语朗读使用日语语音，不出现英文音色。
8. 切回英语恢复英语模型和全部能力。
9. 浅色、深色、窗口缩放、Reduce Motion、VoiceOver 无回归。
10. Secure Input、密码框和输入法切换行为不变。

- [ ] **Step 10: 运行日语质量评测**

Run:

```bash
GLINT_APPLE_TRANSLATION_DIRECTION=zh-ja \
GLINT_APPLE_TRANSLATION_CASES="$PWD/Resources/Evaluation/japanese-translation-benchmark.json" \
./scripts/run_apple_translation_compare.sh
```

按规格要求人工复核语义。未达到 90% 可接受率、50 条高频场景无明显错误或
p95 ≤ 200ms 时，不得发布日语默认体验。

- [ ] **Step 11: 最终仓库检查**

Run:

```bash
git diff --check
git status --short --branch
```

Expected: 无空白错误；工作区只包含预期提交，不推送远程。

- [ ] **Step 12: 提交文档和评测**

```bash
git add AGENTS.md README.md docs Resources Tools
git commit -m "Document multilingual translation support"
```

---

## Execution Notes

- 不在 Task 1–10 期间临时绕过测试或保留旧 API 双轨；任务内完成迁移。
- 每完成一个包级任务，先运行该包测试再进入下一个跨模块任务。
- 若编译错误暴露跨包签名遗漏，修复该签名并回到当前任务测试，不带入下个任务。
- UI 实现完成前不声称多语种已完成；质量门禁和真实 App 验证未通过时保持目标 active。
