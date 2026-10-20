import Foundation
import GlintCore
import GlintMac
import GlintPlugins

struct OCRPluginResolution {
    let configuration: OCRRuntimeConfiguration
    let warning: String?
}

enum OCRPluginLoader {
    static func resolve(
        preferences: OCRRecognitionPreferences,
        manager: PluginManager
    ) async -> OCRPluginResolution {
        if let override = ProcessInfo.processInfo.environment[
            "GLINT_OCR_PLUGIN_DIR"
        ], !override.isEmpty {
            return OCRPluginResolution(
                configuration: OCRRuntimeConfiguration(
                    primaryModel: OCRModelRuntimeConfiguration(
                        id: "ppocr.override",
                        backend: .ppocr,
                        ppocrPluginDirectory: URL(
                            fileURLWithPath: override,
                            isDirectory: true
                        )
                    ),
                    recognitionStrategy: .primaryOnly
                ),
                warning: nil
            )
        }

        let installed = await manager.installedPlugins()
        let ocrPlugins = installed.filter {
            $0.type == .ocr
                && ["huggingface-onnx", "onnxruntime"].contains($0.runtime)
        }
        let manifests = Dictionary(
            uniqueKeysWithValues: ocrPlugins.map { ($0.id, $0) }
        )

        let primary: OCRModelRuntimeConfiguration
        let warning: String?
        if preferences.primaryModelID == OCRRecognitionPreferences.visionModelID {
            primary = .appleVision
            warning = nil
        } else if let runtime = await runtime(
            modelID: preferences.primaryModelID,
            manifests: manifests,
            manager: manager
        ) {
            primary = runtime
            warning = nil
        } else {
            primary = .appleVision
            warning = "主识别模型不可用，已使用 Apple Vision"
        }

        let backup: OCRModelRuntimeConfiguration?
        if preferences.strategy != .primaryOnly,
           let backupModelID = preferences.backupModelID,
           backupModelID != primary.id,
           backupModelID != preferences.primaryModelID {
            if backupModelID == OCRRecognitionPreferences.visionModelID {
                backup = primary.id == OCRRecognitionPreferences.visionModelID
                    ? nil
                    : .appleVision
            } else {
                backup = await runtime(
                    modelID: backupModelID,
                    manifests: manifests,
                    manager: manager
                )
            }
        } else {
            backup = nil
        }

        return OCRPluginResolution(
            configuration: OCRRuntimeConfiguration(
                primaryModel: primary,
                backupModel: backup,
                recognitionStrategy: preferences.strategy
            ),
            warning: warning
        )
    }

    private static func runtime(
        modelID: String,
        manifests: [String: PluginManifest],
        manager: PluginManager
    ) async -> OCRModelRuntimeConfiguration? {
        guard let manifest = manifests[modelID] else {
            return nil
        }
        let directory = await manager.pluginDirectory(for: modelID)
        return OCRModelRuntimeConfiguration(
            id: modelID,
            backend: .ppocr,
            ppocrPluginDirectory: directory,
            ppocrPluginToken: "\(manifest.version):\(manifest.sha256)"
        )
    }
}
