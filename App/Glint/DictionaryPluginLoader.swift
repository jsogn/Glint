import Foundation
import GlintCore
import GlintDictionary
import GlintPlugins

actor PluginDictionaryRouter: DictionaryEngine {
    private let baseDirectory: URL?
    private var router: DictionaryRouter

    init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
        router = DictionaryRouter(
            routes: DictionaryPluginLoader.resolvedRoutes(
                baseDirectory: baseDirectory
            )
        )
    }

    func reload() {
        router = DictionaryRouter(
            routes: DictionaryPluginLoader.resolvedRoutes(
                baseDirectory: baseDirectory
            )
        )
    }

    func lookup(_ candidate: Candidate) async -> TranslationResult? {
        await router.lookup(candidate)
    }
}

enum DictionaryPluginLoader {
    static func resolvedRoutes(baseDirectory: URL? = nil) -> [DictionaryRoute] {
        let bundledRoutes = routes(
            in: BundledPluginResources.directories,
            firstPriority: 0
        )
        let bundledIDs = Set(bundledRoutes.map(\.id))
        let fileManager = FileManager.default
        let pluginsDirectory: URL
        if let baseDirectory {
            pluginsDirectory = baseDirectory
        } else {
            guard let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                return bundledRoutes
            }
            pluginsDirectory = support.appendingPathComponent(
                "Glint/plugins",
                isDirectory: true
            )
        }

        guard let directories = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return bundledRoutes
        }

        let installedRoutes = routes(
            in: directories.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            },
            firstPriority: 10
        ).filter { !bundledIDs.contains($0.id) }
        return bundledRoutes + installedRoutes
    }

    private static func routes(
        in directories: [URL],
        firstPriority: Int
    ) -> [DictionaryRoute] {
        directories
            .enumerated()
            .compactMap { index, directory in
                guard let manifest = try? PluginManifest.load(
                    from: directory
                ),
                manifest.type == .dictionary,
                let engine = engine(
                    for: manifest,
                    in: directory
                ) else {
                    return nil
                }
                return DictionaryRoute(
                    id: manifest.id,
                    priority: firstPriority + index,
                    engine: engine
                )
            }
    }

    private static func engine(
        for manifest: PluginManifest,
        in directory: URL
    ) -> (any DictionaryEngine)? {
        switch manifest.runtime {
        case "cedict-sqlite":
            let database = directory.appendingPathComponent(
                "cedict.sqlite3"
            )
            let overrides = directory.appendingPathComponent(
                "overrides.json"
            )
            guard FileManager.default.fileExists(atPath: database.path) else {
                return nil
            }
            return CedictDictionary(
                databaseURL: database,
                overridesURL: overrides
            )
        case "ecdict-rank":
            let database = directory.appendingPathComponent(
                "ecdict_rank.sqlite3"
            )
            guard FileManager.default.fileExists(atPath: database.path) else {
                return nil
            }
            return ECDICTDictionary(databaseURL: database)
        case GenericSQLiteDictionary.runtime:
            let database = directory.appendingPathComponent(
                GenericSQLiteDictionary.databaseName
            )
            return GenericSQLiteDictionary(
                databaseURL: database,
                sourceLanguage: "zh-Hans",
                targetLanguage: "en"
            )
        default:
            return nil
        }
    }
}
