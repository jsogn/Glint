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
        let fileManager = FileManager.default
        let bundledDirectories = BundledPluginResources.directories
        let installedDirectories = pluginDirectories(
            baseDirectory: baseDirectory,
            fileManager: fileManager
        )
        let ranker =
            ecdictRanker(in: installedDirectories)
            ?? ecdictRanker(in: bundledDirectories)
        let bundledRoutes = routes(
            in: bundledDirectories,
            firstPriority: 0,
            ecdictRanker: ranker
        )
        let bundledIDs = Set(bundledRoutes.map(\.id))
        guard !installedDirectories.isEmpty else {
            return bundledRoutes
        }
        let installedRoutes = routes(
            in: installedDirectories,
            firstPriority: 10,
            ecdictRanker: ranker
        )
        var installedByID: [String: DictionaryRoute] = [:]
        for route in installedRoutes where installedByID[route.id] == nil {
            installedByID[route.id] = route
        }
        let effectiveBundledRoutes = bundledRoutes.map { bundled in
            guard let installed = installedByID[bundled.id] else {
                return bundled
            }
            return DictionaryRoute(
                id: bundled.id,
                priority: bundled.priority,
                role: bundled.role,
                engine: installed.engine
            )
        }
        let additionalRoutes = installedRoutes.filter {
            !bundledIDs.contains($0.id)
        }
        return effectiveBundledRoutes + additionalRoutes
    }

    private static func pluginDirectories(
        baseDirectory: URL?,
        fileManager: FileManager
    ) -> [URL] {
        let pluginsDirectory: URL
        if let baseDirectory {
            pluginsDirectory = baseDirectory
        } else {
            guard
                let support = fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
            else {
                return []
            }
            pluginsDirectory = support.appendingPathComponent(
                "Glint/plugins",
                isDirectory: true
            )
        }
        return
            (try? fileManager.contentsOfDirectory(
                at: pluginsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ))?.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            } ?? []
    }

    private static func ecdictRanker(
        in directories: [URL]
    ) -> ECDICTRanker? {
        for directory in directories {
            guard
                let manifest = try? PluginManifest.load(from: directory),
                manifest.id == "dict-ecdict",
                manifest.runtime == "ecdict-rank"
            else {
                continue
            }
            let database = directory.appendingPathComponent(
                "ecdict_rank.sqlite3"
            )
            guard ECDICTRankBuilder.isCompatible(databaseURL: database) else {
                continue
            }
            return ECDICTRanker(databaseURL: database)
        }
        return nil
    }

    private static func routes(
        in directories: [URL],
        firstPriority: Int,
        ecdictRanker: ECDICTRanker?
    ) -> [DictionaryRoute] {
        directories
            .enumerated()
            .compactMap { index, directory in
                guard
                    let manifest = try? PluginManifest.load(
                        from: directory
                    ),
                    manifest.type == .dictionary,
                    let engine = engine(
                        for: manifest,
                        in: directory,
                        ecdictRanker: ecdictRanker
                    )
                else {
                    return nil
                }
                return DictionaryRoute(
                    id: manifest.id,
                    priority: firstPriority + index,
                    role: manifest.id == "dict-cedict"
                        ? .authoritative
                        : .fallback,
                    engine: engine
                )
            }
    }

    private static func engine(
        for manifest: PluginManifest,
        in directory: URL,
        ecdictRanker: ECDICTRanker?
    ) -> (any DictionaryEngine)? {
        switch manifest.runtime {
        case "cedict-sqlite":
            let database = directory.appendingPathComponent(
                "cedict.sqlite3"
            )
            guard
                FileManager.default.fileExists(atPath: database.path),
                CedictDatabaseBuilder.isCompatible(databaseURL: database)
            else {
                return nil
            }
            return CedictDictionary(
                databaseURL: database,
                ranker: ecdictRanker
            )
        case "ecdict-rank":
            let database = directory.appendingPathComponent(
                "ecdict_rank.sqlite3"
            )
            guard ECDICTRankBuilder.isCompatible(databaseURL: database) else {
                return nil
            }
            return ECDICTDictionary(ranker: ecdictRanker)
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
