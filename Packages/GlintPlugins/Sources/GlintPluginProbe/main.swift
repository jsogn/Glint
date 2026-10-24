import Foundation
import GlintPlugins

@main
struct GlintPluginProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 3,
            let pluginID = arguments.dropFirst(2).first
        else {
            fputs("usage: glint-plugin-probe <catalog> <install-dir> <plugin-id>\n", stderr)
            exit(2)
        }
        let catalogURL = URL(fileURLWithPath: arguments[0])
        let installDirectory = URL(
            fileURLWithPath: arguments[1],
            isDirectory: true
        )
        let manager = PluginManager(baseDirectory: installDirectory)
        let service = PluginCatalogService(manager: manager)

        do {
            let catalog = try await service.fetchCatalog(from: catalogURL)
            guard let plugin = catalog.first(where: { $0.id == pluginID }) else {
                fputs("plugin \(pluginID) not found\n", stderr)
                exit(3)
            }
            print("installing \(plugin.name) (\(plugin.sizeBytes) bytes)")
            let installed = try await service.install(plugin) { value in
                print(
                    String(
                        format: "progress %.1f%% phase=%@",
                        value.fraction * 100,
                        value.phase.rawValue
                    )
                )
            }
            let directory = await manager.pluginDirectory(for: installed.id)
            print("installed \(installed.id) -> \(directory.path)")
        } catch {
            fputs("install failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
