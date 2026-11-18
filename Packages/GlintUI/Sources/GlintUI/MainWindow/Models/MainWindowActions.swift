import Foundation
import GlintCore
import GlintPlugins

@MainActor
public struct MainWindowActions {
    public var monitoring: Monitoring
    public var permissions: Permissions
    public var translation: Translation
    public var plugins: Plugins

    public init(
        monitoring: Monitoring,
        permissions: Permissions,
        translation: Translation,
        plugins: Plugins
    ) {
        self.monitoring = monitoring
        self.permissions = permissions
        self.translation = translation
        self.plugins = plugins
    }

    @MainActor
    public struct Monitoring {
        public var startMonitoring: @MainActor () -> Void
        public var stopMonitoring: @MainActor () -> Void

        public init(
            startMonitoring: @escaping @MainActor () -> Void,
            stopMonitoring: @escaping @MainActor () -> Void
        ) {
            self.startMonitoring = startMonitoring
            self.stopMonitoring = stopMonitoring
        }
    }

    @MainActor
    public struct Permissions {
        public var refreshPermissions: @MainActor () -> Void
        public var requestPermissions: @MainActor () -> Void
        public var openAccessibilitySettings: @MainActor () -> Void
        public var refreshLaunchAtLogin: @MainActor () -> Void
        public var setLaunchAtLogin: @MainActor (Bool) -> Void
        public var openLoginItemsSettings: @MainActor () -> Void
        public var refreshInputMethodSupport: @MainActor () async -> [InputMethodSupportStatus]
        public var installSquirrelSupport: @MainActor () async throws -> [InputMethodSupportStatus]
        public var uninstallSquirrelSupport: @MainActor () async throws -> [InputMethodSupportStatus]

        public init(
            refreshPermissions: @escaping @MainActor () -> Void,
            requestPermissions: @escaping @MainActor () -> Void,
            openAccessibilitySettings: @escaping @MainActor () -> Void,
            refreshLaunchAtLogin: @escaping @MainActor () -> Void,
            setLaunchAtLogin: @escaping @MainActor (Bool) -> Void,
            openLoginItemsSettings: @escaping @MainActor () -> Void,
            refreshInputMethodSupport:
                @escaping @MainActor () async -> [InputMethodSupportStatus],
            installSquirrelSupport:
                @escaping @MainActor () async throws ->
                [InputMethodSupportStatus],
            uninstallSquirrelSupport:
                @escaping @MainActor () async throws ->
                [InputMethodSupportStatus]
        ) {
            self.refreshPermissions = refreshPermissions
            self.requestPermissions = requestPermissions
            self.openAccessibilitySettings = openAccessibilitySettings
            self.refreshLaunchAtLogin = refreshLaunchAtLogin
            self.setLaunchAtLogin = setLaunchAtLogin
            self.openLoginItemsSettings = openLoginItemsSettings
            self.refreshInputMethodSupport = refreshInputMethodSupport
            self.installSquirrelSupport = installSquirrelSupport
            self.uninstallSquirrelSupport = uninstallSquirrelSupport
        }
    }

    @MainActor
    public struct Translation {
        public var activateModel: @MainActor (String) async -> String?
        public var refreshSystemTranslation: @MainActor () async -> SystemTranslationAvailability
        public var prepareSystemTranslation: @MainActor () async throws -> SystemTranslationAvailability
        public var presentSystemTranslation: @MainActor () -> Void
        public var openSystemTranslationSettings: @MainActor () -> Void
        public var releaseModel: @MainActor (String) async -> Void
        public var previewSpeech: @MainActor (TranslationTarget) -> Void
        public var changeTarget: @MainActor (TranslationTarget) async -> TranslationReadiness
        public var selectModel:
            @MainActor (String, TranslationTarget) async ->
                TranslationReadiness
        public var setMode: @MainActor (TranslationMode) -> Void
        public var configurationChanged: @MainActor () -> Void

        public init(
            activateModel:
                @escaping @MainActor (String) async -> String?,
            refreshSystemTranslation:
                @escaping @MainActor () async ->
                SystemTranslationAvailability,
            prepareSystemTranslation:
                @escaping @MainActor () async throws ->
                SystemTranslationAvailability,
            presentSystemTranslation:
                @escaping @MainActor () -> Void,
            openSystemTranslationSettings:
                @escaping @MainActor () -> Void,
            releaseModel:
                @escaping @MainActor (String) async -> Void,
            previewSpeech:
                @escaping @MainActor (TranslationTarget) -> Void,
            changeTarget:
                @escaping @MainActor (TranslationTarget) async ->
                TranslationReadiness,
            selectModel:
                @escaping @MainActor (String, TranslationTarget) async ->
                TranslationReadiness,
            setMode: @escaping @MainActor (TranslationMode) -> Void,
            configurationChanged: @escaping @MainActor () -> Void
        ) {
            self.activateModel = activateModel
            self.refreshSystemTranslation = refreshSystemTranslation
            self.prepareSystemTranslation = prepareSystemTranslation
            self.presentSystemTranslation = presentSystemTranslation
            self.openSystemTranslationSettings =
                openSystemTranslationSettings
            self.releaseModel = releaseModel
            self.previewSpeech = previewSpeech
            self.changeTarget = changeTarget
            self.selectModel = selectModel
            self.setMode = setMode
            self.configurationChanged = configurationChanged
        }
    }

    @MainActor
    public struct Plugins {
        public var checkCoreDictionaryUpdate: @MainActor (CoreDictionaryUpdateKind) async throws -> String
        public var checkTranslationModelUpdate: @MainActor (PluginManifest) async throws -> UpstreamModelUpdate?
        public var searchModelMarket: @MainActor (String) async throws -> [UpstreamModelSummary]
        public var prepareModelMarketInstall:
            @MainActor (UpstreamModelSummary, PluginManifest?) async throws ->
                ModelInstallPreparation
        public var availableInstallationSpace: @MainActor () -> Int64?
        public var dictionaryConfigurationChanged: @MainActor () async -> Void

        public init(
            checkCoreDictionaryUpdate:
                @escaping @MainActor (CoreDictionaryUpdateKind) async throws ->
                String,
            checkTranslationModelUpdate:
                @escaping @MainActor (PluginManifest) async throws ->
                UpstreamModelUpdate?,
            searchModelMarket:
                @escaping @MainActor (String) async throws ->
                [UpstreamModelSummary],
            prepareModelMarketInstall:
                @escaping @MainActor (
                    UpstreamModelSummary,
                    PluginManifest?
                ) async throws -> ModelInstallPreparation,
            availableInstallationSpace:
                @escaping @MainActor () -> Int64?,
            dictionaryConfigurationChanged:
                @escaping @MainActor () async -> Void
        ) {
            self.checkCoreDictionaryUpdate = checkCoreDictionaryUpdate
            self.checkTranslationModelUpdate = checkTranslationModelUpdate
            self.searchModelMarket = searchModelMarket
            self.prepareModelMarketInstall = prepareModelMarketInstall
            self.availableInstallationSpace = availableInstallationSpace
            self.dictionaryConfigurationChanged =
                dictionaryConfigurationChanged
        }
    }
}

extension MainWindowActions {
    static var stub: Self {
        Self(
            monitoring: Monitoring(
                startMonitoring: {},
                stopMonitoring: {}
            ),
            permissions: Permissions(
                refreshPermissions: {},
                requestPermissions: {},
                openAccessibilitySettings: {},
                refreshLaunchAtLogin: {},
                setLaunchAtLogin: { _ in },
                openLoginItemsSettings: {},
                refreshInputMethodSupport: { [.applePinyin] },
                installSquirrelSupport: { [.applePinyin] },
                uninstallSquirrelSupport: { [.applePinyin] }
            ),
            translation: Translation(
                activateModel: { _ in nil },
                refreshSystemTranslation: { .available },
                prepareSystemTranslation: { .installed },
                presentSystemTranslation: {},
                openSystemTranslationSettings: {},
                releaseModel: { _ in },
                previewSpeech: { _ in },
                changeTarget: { target in
                    .failed(target, "翻译语言切换不可用")
                },
                selectModel: { _, target in
                    .failed(target, "翻译模型切换不可用")
                },
                setMode: { _ in },
                configurationChanged: {}
            ),
            plugins: Plugins(
                checkCoreDictionaryUpdate: { _ in
                    "词典更新服务不可用"
                },
                checkTranslationModelUpdate: { _ in nil },
                searchModelMarket: { _ in [] },
                prepareModelMarketInstall: { _, _ in
                    throw ModelHubError.unavailable
                },
                availableInstallationSpace: {
                    let directory =
                        FileManager.default.urls(
                            for: .applicationSupportDirectory,
                            in: .userDomainMask
                        ).first
                    return try? directory?.resourceValues(
                        forKeys: [
                            .volumeAvailableCapacityForImportantUsageKey
                        ]
                    ).volumeAvailableCapacityForImportantUsage
                },
                dictionaryConfigurationChanged: {}
            )
        )
    }
}
