import GlintPlugins

struct CachedTranslationModelUpdate: Codable {
    let currentRevision: String
    let latestRevision: String
    let lastModified: String?
    let manifest: PluginManifest

    init(_ update: UpstreamModelUpdate) {
        currentRevision = update.currentRevision
        latestRevision = update.latestRevision
        lastModified = update.lastModified
        manifest = update.manifest
    }

    var upstreamUpdate: UpstreamModelUpdate {
        UpstreamModelUpdate(
            currentRevision: currentRevision,
            latestRevision: latestRevision,
            lastModified: lastModified,
            manifest: manifest
        )
    }
}

enum TranslationModelUpdateKey {
    static func lastSuccess(_ modelID: String) -> String {
        "translationModelUpdate.lastSuccess.\(modelID)"
    }

    static func lastFailure(_ modelID: String) -> String {
        "translationModelUpdate.lastFailure.\(modelID)"
    }

    static func cachedUpdate(_ modelID: String) -> String {
        "translationModelUpdate.update.\(modelID)"
    }
}
