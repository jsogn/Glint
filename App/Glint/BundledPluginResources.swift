import Foundation
import GlintPlugins

enum BundledPluginResources {
    static let pluginIDs = [
        "dict-cedict",
        "dict-ecdict",
        "dict-wiktionary-zh-en",
    ]

    static var directories: [URL] {
        pluginIDs.compactMap {
            Bundle.main.url(
                forResource: $0,
                withExtension: nil
            )
        }
    }

    static var manifests: [PluginManifest] {
        directories.compactMap { directory in
            let manifestURL = directory.appendingPathComponent(
                "manifest.json"
            )
            guard let data = try? Data(contentsOf: manifestURL) else {
                return nil
            }
            return try? JSONDecoder().decode(
                PluginManifest.self,
                from: data
            )
        }
    }
}
