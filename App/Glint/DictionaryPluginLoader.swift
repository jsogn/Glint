import Foundation
import GlintCore
import GlintDictionary
import GlintPlugins

enum DictionaryPluginLoader {
    static func routes(baseDirectory: URL? = nil) -> [DictionaryRoute] {
        let fileManager = FileManager.default
        let pluginsDirectory = baseDirectory
            ?? fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
                .appendingPathComponent("Glint/plugins", isDirectory: true)

        guard let directories = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .enumerated()
            .compactMap { index, directory in
                guard let data = try? Data(
                    contentsOf: directory.appendingPathComponent("manifest.json")
                ),
                let manifest = try? JSONDecoder().decode(
                    PluginManifest.self,
                    from: data
                ),
                manifest.type == .dictionary,
                manifest.runtime == GenericSQLiteDictionary.runtime,
                manifest.languages.count >= 2 else {
                    return nil
                }

                let databaseURL = directory.appendingPathComponent(
                    GenericSQLiteDictionary.databaseName
                )
                guard let engine = GenericSQLiteDictionary(
                    databaseURL: databaseURL,
                    sourceLanguage: manifest.languages[0],
                    targetLanguage: manifest.languages[1]
                ) else {
                    return nil
                }
                return DictionaryRoute(
                    id: manifest.id,
                    priority: 10 + index,
                    engine: engine
                )
            }
    }
}
