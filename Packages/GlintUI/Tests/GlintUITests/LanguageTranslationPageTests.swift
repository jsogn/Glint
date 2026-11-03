import AppKit
import GlintCore
import GlintPlugins
import SwiftUI
import Vision
import XCTest

@testable import GlintUI

@MainActor
final class LanguageTranslationPageTests: XCTestCase {
    func testLanguagePackActionAppearsInLanguageAndModelCards() throws {
        let suite = "GlintLanguagePageLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil,
            defaults: defaults
        )
        model.updateSystemTranslationAvailability(.available)
        model.updateTranslationReadiness(
            .needsSetup(.english, "需要安装 Apple 翻译语言包")
        )
        let hostingView = NSHostingView(
            rootView: LanguageTranslationPage(
                model: model,
                onManageModels: {}
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 900,
            height: 760
        )
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try renderedBitmap(in: hostingView)
        let observations = try recognizedTextObservations(in: bitmap)
        let textFrames = try recognizedTextFrames(in: bitmap)
        let manageFrame = try XCTUnwrap(textFrames["管理模型"])
        let targetFrame = try XCTUnwrap(
            textFrames.first { $0.key.hasPrefix("目标语") }?.value
        )
        let modelCardFrame = try XCTUnwrap(
            textFrames["翻译模型"]
        )
        let installObservations = observations.filter {
            $0.text == "安装语言包"
        }
        let installFrames = installObservations.map(\.frame)

        XCTAssertEqual(installObservations.count, 2)
        XCTAssertTrue(
            installFrames.contains {
                $0.midY < targetFrame.midY
                    && $0.midY > modelCardFrame.midY
            }
        )
        XCTAssertTrue(
            installFrames.contains {
                $0.midY < modelCardFrame.midY
            }
        )
        let modelInstallFrame = try XCTUnwrap(
            installFrames.min { $0.midY < $1.midY }
        )
        XCTAssertLessThan(
            abs(manageFrame.midY - modelInstallFrame.midY),
            0.04
        )
        for frame in installFrames {
            XCTAssertGreaterThan(
                blueButtonRatio(for: frame, in: bitmap),
                0.15
            )
        }
        XCTAssertLessThan(
            blueButtonRatio(for: manageFrame, in: bitmap),
            0.03
        )
        XCTAssertTrue(
            observations.contains {
                $0.text.contains("Apple翻译语言包")
            }
        )
    }

    func testLocalModelFailureShowsRetryBesideModelStatus() throws {
        let suite = "GlintLanguagePageFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TranslationSelectionStore(defaults: defaults)
        store.migrateIfNeeded()
        store.selectModel("local-model", for: .english)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil,
            defaults: defaults,
            translationSelectionStore: store
        )
        model.updateTranslationReadiness(
            .failed(.english, "模型加载失败")
        )
        let hostingView = NSHostingView(
            rootView: LanguageTranslationPage(
                model: model,
                onManageModels: {}
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 900,
            height: 760
        )
        hostingView.layoutSubtreeIfNeeded()

        let textFrames = try recognizedTextFrames(
            in: renderedBitmap(in: hostingView)
        )
        let statusFrame = try XCTUnwrap(
            textFrames["当前翻译模型不可用"]
        )
        let retryFrame = try XCTUnwrap(textFrames["重试"])

        XCTAssertLessThan(
            abs(statusFrame.midY - retryFrame.midY),
            0.04
        )
    }

    func testVoiceRowsAvoidRepeatingTargetLanguageNames() throws {
        for sample in [
            (
                target: TranslationTarget.english,
                expected: "口音",
                forbidden: "英语口音"
            ),
            (
                target: TranslationTarget.french,
                expected: "音色",
                forbidden: "法语音色"
            ),
        ] {
            let suite = "GlintLanguagePageVoice.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(
                UserDefaults(suiteName: suite)
            )
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = TranslationSelectionStore(defaults: defaults)
            store.migrateIfNeeded()
            store.selectedTarget = sample.target
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = MainWindowModel(
                pluginManager: PluginManager(baseDirectory: root),
                catalogURL: nil,
                defaults: defaults,
                translationSelectionStore: store
            )
            let hostingView = NSHostingView(
                rootView: LanguageTranslationPage(
                    model: model,
                    onManageModels: {}
                )
            )
            hostingView.frame = NSRect(
                x: 0,
                y: 0,
                width: 900,
                height: 760
            )
            hostingView.layoutSubtreeIfNeeded()

            let textFrames = try recognizedTextFrames(
                in: renderedBitmap(in: hostingView)
            )

            XCTAssertNotNil(textFrames[sample.expected])
            XCTAssertNil(textFrames[sample.forbidden])
        }
    }

    func testReadyStatusUsesConciseLabel() throws {
        let suite = "GlintLanguagePageReady.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil,
            defaults: defaults
        )
        model.updateSystemTranslationAvailability(.installed)
        let hostingView = NSHostingView(
            rootView: LanguageTranslationPage(
                model: model,
                onManageModels: {}
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 900,
            height: 760
        )
        hostingView.layoutSubtreeIfNeeded()

        let textFrames = try recognizedTextFrames(
            in: renderedBitmap(in: hostingView)
        )

        XCTAssertTrue(
            textFrames["已就绪"] != nil
                || textFrames["已就緒"] != nil
        )
        XCTAssertNil(textFrames["翻译模型已就绪"])
    }

    func testLanguageDirectionUsesLanguageRoleLabels() throws {
        let suite = "GlintLanguagePageDirection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil,
            defaults: defaults
        )
        let hostingView = NSHostingView(
            rootView: LanguageTranslationPage(
                model: model,
                onManageModels: {}
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 900,
            height: 760
        )
        hostingView.layoutSubtreeIfNeeded()

        let textFrames = try recognizedTextFrames(
            in: renderedBitmap(in: hostingView)
        )

        XCTAssertTrue(
            textFrames.keys.contains { $0.hasPrefix("原文语") }
        )
        XCTAssertTrue(
            textFrames.keys.contains { $0.hasPrefix("目标语") }
        )
        XCTAssertTrue(
            textFrames.keys.contains {
                $0.contains("该语言上次使用的翻译模型")
                    && $0.contains("朗读音色")
            }
        )
        XCTAssertNil(textFrames["输入"])
        XCTAssertNil(textFrames["输出"])
    }

    func testPageRendersAcrossTargetsAppearanceAndWidths() async throws {
        let suite = "GlintLanguagePage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil,
            defaults: defaults
        )
        model.changeTranslationTargetAction = { target in
            .ready(target)
        }

        let hostingView = NSHostingView(
            rootView: LanguageTranslationPage(
                model: model,
                onManageModels: {}
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 900,
            height: 760
        )
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
        try assertRendersAcrossAppearanceAndWidths(hostingView)

        for target in TranslationTarget.allCases
        where target != .english {
            await model.setTranslationTarget(target)
            hostingView.layoutSubtreeIfNeeded()

            XCTAssertEqual(model.translationTarget, target)
            XCTAssertEqual(model.translationReadiness, .ready(target))
            XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
            try assertRendersAcrossAppearanceAndWidths(hostingView)
        }
    }

    private func assertRendersAcrossAppearanceAndWidths(
        _ hostingView: NSHostingView<LanguageTranslationPage>
    ) throws {
        for appearanceName in [
            NSAppearance.Name.aqua,
            NSAppearance.Name.darkAqua,
        ] {
            hostingView.appearance = try XCTUnwrap(
                NSAppearance(named: appearanceName)
            )
            for width in [760.0, 1000.0] {
                hostingView.frame = NSRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: 900
                )
                hostingView.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(
                    hostingView.bitmapImageRepForCachingDisplay(
                        in: hostingView.bounds
                    )
                )
                hostingView.cacheDisplay(
                    in: hostingView.bounds,
                    to: bitmap
                )
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            }
        }
    }

    private func renderedBitmap(
        in hostingView: NSHostingView<LanguageTranslationPage>
    ) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(
                in: hostingView.bounds
            )
        )
        hostingView.cacheDisplay(
            in: hostingView.bounds,
            to: bitmap
        )
        return bitmap
    }

    private func recognizedTextFrames(
        in bitmap: NSBitmapImageRep
    ) throws -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for observation in try recognizedTextObservations(in: bitmap) {
            frames[observation.text] = observation.frame
        }
        return frames
    }

    private func recognizedTextObservations(
        in bitmap: NSBitmapImageRep
    ) throws -> [(text: String, frame: CGRect)] {
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])

        var observations: [(text: String, frame: CGRect)] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }
            let text = candidate.string
                .replacingOccurrences(of: " ", with: "")
            observations.append(
                (text: text, frame: observation.boundingBox)
            )
        }
        return observations
    }

    private func blueButtonRatio(
        for frame: CGRect,
        in bitmap: NSBitmapImageRep
    ) -> Double {
        let minX = max(
            0,
            Int((frame.minX - 0.02) * CGFloat(bitmap.pixelsWide))
        )
        let maxX = min(
            bitmap.pixelsWide - 1,
            Int((frame.maxX + 0.02) * CGFloat(bitmap.pixelsWide))
        )
        let minY = max(
            0,
            Int(
                (1 - frame.maxY - 0.015)
                    * CGFloat(bitmap.pixelsHigh)
            )
        )
        let maxY = min(
            bitmap.pixelsHigh - 1,
            Int(
                (1 - frame.minY + 0.015)
                    * CGFloat(bitmap.pixelsHigh)
            )
        )
        guard minX <= maxX, minY <= maxY else { return 0 }

        var bluePixels = 0
        var sampledPixels = 0
        for y in stride(from: minY, through: maxY, by: 2) {
            for x in stride(from: minX, through: maxX, by: 2) {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?
                        .usingColorSpace(.deviceRGB)
                else {
                    continue
                }
                sampledPixels += 1
                if color.blueComponent > 0.55,
                    color.blueComponent
                        > color.redComponent + 0.25,
                    color.blueComponent
                        > color.greenComponent + 0.1
                {
                    bluePixels += 1
                }
            }
        }
        guard sampledPixels > 0 else { return 0 }
        return Double(bluePixels) / Double(sampledPixels)
    }
}
