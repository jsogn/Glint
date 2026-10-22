import Foundation
import GlintPlugins

enum BundledPluginResources {
    static let pluginIDs = [
        "dict-cedict",
        "dict-ecdict",
        "dict-wiktionary-zh-en",
        "mt-opus-zh-en",
    ]

    static var directories: [URL] {
        pluginIDs.compactMap(directory(for:))
    }

    static var manifests: [PluginManifest] {
        pluginIDs.compactMap(manifest(for:))
    }

    static func directory(for id: String) -> URL? {
        Bundle.main.url(forResource: id, withExtension: nil)
    }

    static func manifest(for id: String) -> PluginManifest? {
        guard let directory = directory(for: id) else {
            return nil
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(PluginManifest.self, from: data)
    }
}
