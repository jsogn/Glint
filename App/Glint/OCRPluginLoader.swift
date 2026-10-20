import Foundation
import GlintCore
import GlintMac
import GlintPlugins

struct OCRPluginResolution {
    let configuration: OCRRuntimeConfiguration
    let warning: String?
}

enum OCRPluginLoader {
    static let ppocrPluginID = "ocr-ppocrv6-small"

    static func resolve(
        engineID: String,
        enhancementMode: OCREnhancementMode,
        manager: PluginManager
    ) async -> OCRPluginResolution {
        let installed = await manager.installedPlugins()
        let ocrPlugins = installed.filter {
            $0.type == .ocr
                && ["huggingface-onnx", "onnxruntime"].contains($0.runtime)
        }
        let selected = ocrPlugins.first { $0.id == engineID }
            ?? ocrPlugins.first { $0.id == ppocrPluginID }
            ?? ocrPlugins.first

        let pluginDirectory: URL?
        let pluginToken: String?
        if let override = ProcessInfo.processInfo.environment[
            "GLINT_OCR_PLUGIN_DIR"
        ], !override.isEmpty {
            pluginDirectory = URL(fileURLWithPath: override, isDirectory: true)
            pluginToken = nil
        } else if let selected {
            pluginDirectory = await manager.pluginDirectory(for: selected.id)
            pluginToken = "\(selected.version):\(selected.sha256)"
        } else {
            pluginDirectory = nil
            pluginToken = nil
        }

        if engineID == OCREngineSelection.visionEngineID {
            return OCRPluginResolution(
                configuration: OCRRuntimeConfiguration(
                    preferredBackend: .vision,
                    ppocrPluginDirectory: pluginDirectory,
                    ppocrPluginToken: pluginToken,
                    enhancementMode: enhancementMode
                ),
                warning: nil
            )
        }

        guard selected != nil || pluginDirectory != nil else {
            return OCRPluginResolution(
                configuration: .appleVision,
                warning: "未找到已安装的 PP-OCR 插件，已使用 Apple Vision"
            )
        }
        return OCRPluginResolution(
            configuration: OCRRuntimeConfiguration(
                preferredBackend: .ppocr,
                ppocrPluginDirectory: pluginDirectory,
                ppocrPluginToken: pluginToken,
                enhancementMode: enhancementMode
            ),
            warning: nil
        )
    }
}
