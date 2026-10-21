import CoreGraphics
import XCTest
import AppKit
import ImageIO
@testable import GlintMac

final class GlintMacTests: XCTestCase {
    func testPPOCRReadsCandidateSample() throws {
        let image = try loadCandidateSample()
        let detection = try XCTUnwrap(
            ppocrService().detect(in: image)
        )
        XCTAssertEqual(detection.text, "你好")
    }

    func testPPOCRReadsNSImageCandidateSample() throws {
        let imageURL = try candidateSampleURL()
        let image = try XCTUnwrap(NSImage(contentsOf: imageURL))
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        )
        let detection = try XCTUnwrap(
            ppocrService().detect(in: cgImage)
        )
        XCTAssertEqual(detection.text, "你好")
    }

    func testAppleVisionRunsWhenPPOCRIsUnavailable() throws {
        let image = try loadCandidateSample()
        let service = OCRService(configuration: .appleVision)
        XCTAssertEqual(service.detect(in: image)?.text, "你好")
    }

    func testAutomaticFallbackUsesPPOCRForLowConfidence() throws {
        let image = try loadImage(at: ocrDatasetURL("synthetic_021_0.png"))
        let service = OCRService(
            configuration: OCRRuntimeConfiguration(
                primaryModel: .appleVision,
                backupModel: ppocrRuntime(),
                recognitionStrategy: .automaticFallback,
                candidateCacheEnabled: false
            )
        )

        XCTAssertEqual(service.detect(in: image)?.text, "重要")
    }

    func testDualVerificationRunsBackupModel() throws {
        let image = try loadCandidateSample()
        let service = OCRService(
            configuration: OCRRuntimeConfiguration(
                primaryModel: ppocrRuntime(id: "test.ppocr.primary"),
                backupModel: ppocrRuntime(id: "test.ppocr.backup"),
                recognitionStrategy: .dualVerification,
                candidateCacheEnabled: false
            )
        )

        XCTAssertEqual(service.detect(in: image)?.text, "你好")
    }

    func testCandidateCacheReusesStableCrop() throws {
        let image = try loadCandidateSample()
        let service = ppocrService(cacheEnabled: true)

        XCTAssertEqual(service.detect(in: image)?.text, "你好")
        XCTAssertFalse(service.lastUsedCandidateCache)
        XCTAssertEqual(service.detect(in: image)?.text, "你好")
        XCTAssertTrue(service.lastUsedCandidateCache)
    }

    func testCandidateCacheDoesNotReuseDifferentCandidate() throws {
        let images = try [
            ocrDatasetURL("real_original.png"),
            ocrDatasetURL("synthetic_001_0.png"),
        ].map(loadImage(at:))
        let service = ppocrService(cacheEnabled: true)

        XCTAssertEqual(service.detect(in: images[0])?.text, "你好")
        XCTAssertFalse(service.lastUsedCandidateCache)
        XCTAssertEqual(service.detect(in: images[1])?.text, "中国")
        XCTAssertFalse(service.lastUsedCandidateCache)
    }

    func testPPOCRDatasetQuality() throws {
        struct Record: Decodable {
            let path: String
            let text: String
        }
        struct Manifest: Decodable {
            let records: [Record]
        }

        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/OCRLab/data/manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("OCR benchmark dataset is not generated")
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let service = ppocrService()
        var exact = 0
        var times: [Double] = []
        var failures: [(String, String, String)] = []
        for record in manifest.records {
            let source = try XCTUnwrap(
                CGImageSourceCreateWithURL(
                    URL(fileURLWithPath: record.path) as CFURL,
                    nil
                )
            )
            let image = try XCTUnwrap(
                CGImageSourceCreateImageAtIndex(source, 0, nil)
            )
            if ProcessInfo.processInfo.environment["GLINT_OCR_TRACE"] == "1" {
                fputs("DATASET \(record.path)\n", stderr)
            }
            let started = ContinuousClock.now
            let detection = service.detect(in: image)
            times.append(
                elapsedMilliseconds(started.duration(to: .now))
            )
            if detection?.text == record.text {
                exact += 1
            } else {
                failures.append(
                    (
                        URL(fileURLWithPath: record.path).lastPathComponent,
                        record.text,
                        detection?.text ?? "<nil>"
                    )
                )
            }
        }
        let sorted = times.sorted()
        print(
            String(
                format: "ppocr swift dataset exact=%.2f%% "
                    + "p50=%.2fms p95=%.2fms",
                Double(exact) / Double(max(1, manifest.records.count)) * 100,
                sorted[sorted.count / 2],
                sorted[Int(Double(sorted.count - 1) * 0.95)]
            )
        )
        for failure in failures.prefix(20) {
            print(
                "ppocr failure \(failure.0) expected=\(failure.1) "
                    + "actual=\(failure.2)"
            )
        }
        XCTAssertGreaterThanOrEqual(
            Double(exact) / Double(max(1, manifest.records.count)),
            0.95
        )
    }

    func testPPOCRReadsCandidateSampleWarmLatency() throws {
        let image = try loadCandidateSample()
        let service = ppocrService()
        for _ in 0..<20 {
            _ = service.detect(in: image)
        }

        var times: [Double] = []
        var preprocessTimes: [Double] = []
        var inferenceTimes: [Double] = []
        var decodeTimes: [Double] = []
        for _ in 0..<100 {
            let started = ContinuousClock.now
            let detection = service.detect(in: image)
            let elapsed = started.duration(to: .now)
            times.append(elapsedMilliseconds(elapsed))
            XCTAssertEqual(detection?.text, "你好")
            let timings = service.ppocrTimings
            preprocessTimes.append(timings.preprocessMs)
            inferenceTimes.append(timings.inferenceMs)
            decodeTimes.append(timings.decodeMs)
        }
        let sorted = times.sorted()
        let sortedPreprocess = preprocessTimes.sorted()
        let sortedInference = inferenceTimes.sorted()
        let sortedDecode = decodeTimes.sorted()
        print(
            String(
                format: "ppocr swift total p50=%.2fms p95=%.2fms "
                    + "pre p50=%.2fms inference p50=%.2fms "
                    + "inference p95=%.2fms decode p50=%.2fms",
                sorted[sorted.count / 2],
                sorted[Int(Double(sorted.count - 1) * 0.95)],
                sortedPreprocess[sortedPreprocess.count / 2],
                sortedInference[sortedInference.count / 2],
                sortedInference[Int(Double(sortedInference.count - 1) * 0.95)],
                sortedDecode[sortedDecode.count / 2]
            )
        )
    }

    private func elapsedMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1_000_000_000_000_000
            + Double(duration.components.seconds) * 1_000
    }

    private func loadCandidateSample() throws -> CGImage {
        let imageURL = try candidateSampleURL()
        return try loadImage(at: imageURL)
    }

    private func loadImage(at imageURL: URL) throws -> CGImage {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(imageURL as CFURL, nil)
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
        return image
    }

    private func ocrDatasetURL(_ filename: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/OCRLab/data/images")
            .appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("OCR benchmark dataset is not generated")
        }
        return url
    }

    private func ppocrService(
        cacheEnabled: Bool = false
    ) -> OCRService {
        OCRService(
            configuration: OCRRuntimeConfiguration(
                primaryModel: ppocrRuntime(),
                recognitionStrategy: .primaryOnly,
                candidateCacheEnabled: cacheEnabled
            )
        )
    }

    private func ppocrRuntime(
        id: String = "test.ppocr"
    ) -> OCRModelRuntimeConfiguration {
        OCRModelRuntimeConfiguration(
            id: id,
            backend: .ppocr,
            ppocrPluginDirectory: pluginDirectoryURL()
        )
    }

    private func pluginDirectoryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "PluginAssets/ocr-ppocrv6-small",
                isDirectory: true
            )
    }

    private func candidateSampleURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent(
            "Resources/Samples/sample-candidate-bar.png"
        )
    }

    func testCaptureRegionConvertsToCGRect() {
        let region = CaptureRegion(x: 10, y: 20, width: 300, height: 120)
        XCTAssertEqual(region.cgRect.origin.x, 10)
        XCTAssertEqual(region.cgRect.size.width, 300)
    }

    func testCaptureRegionIncludesCandidateBarAboveAndBelowCaret() {
        let caret = CGRect(x: 300, y: 240, width: 2, height: 18)
        let region = MonitoringController.captureRegion(
            caret: caret,
            elementFrame: nil
        )

        XCTAssertLessThanOrEqual(region.y, caret.minY - 60)
        XCTAssertGreaterThanOrEqual(region.y + region.height, caret.maxY + 60)
    }

    func testAXCandidateFrameBecomesDisplayRegion() {
        let frame = CGRect(x: 120, y: 240, width: 96, height: 28)

        XCTAssertEqual(
            MonitoringController.candidateRegion(for: frame),
            CaptureRegion(x: 120, y: 240, width: 96, height: 28)
        )
    }

    func testEmptyAXCandidateFrameIsRejected() {
        XCTAssertNil(
            MonitoringController.candidateRegion(
                for: CGRect(x: 120, y: 240, width: 0, height: 28)
            )
        )
    }

    func testRowModeUsesStableCandidateBarFrame() throws {
        let frame = try XCTUnwrap(
            MonitoringController.candidateDisplayFrame(
                scope: .row,
                selectedFrame: CGRect(x: 180, y: 80, width: 50, height: 28),
                options: [
                    AXCandidateOption(
                        text: "你好",
                        frame: CGRect(x: 20, y: 80, width: 50, height: 28),
                        isSelected: false
                    ),
                    AXCandidateOption(
                        text: "你好吗",
                        frame: CGRect(x: 80, y: 80, width: 70, height: 28),
                        isSelected: true
                    ),
                ],
                listFrame: CGRect(x: 10, y: 80, width: 360, height: 28)
            )
        )

        XCTAssertEqual(
            frame,
            CGRect(x: 10, y: 80, width: 360, height: 28)
        )
    }

    func testRowModeAnchorsToVisibleRowInsideCandidateWindow() throws {
        let expandedWindow = CGRect(x: 10, y: 20, width: 540, height: 260)
        let frame = try XCTUnwrap(
            MonitoringController.candidateDisplayFrame(
                scope: .row,
                selectedFrame: CGRect(x: 40, y: 170, width: 50, height: 28),
                options: [
                    AXCandidateOption(
                        text: "逆",
                        frame: CGRect(x: 40, y: 170, width: 50, height: 28),
                        isSelected: true
                    ),
                ],
                windowFrame: expandedWindow,
                listFrame: CGRect(x: 20, y: 30, width: 500, height: 220)
            )
        )

        XCTAssertEqual(
            frame,
            CGRect(x: 10, y: 170, width: 540, height: 28)
        )
    }

    func testSelectedModeKeepsSelectedCandidateFrame() {
        let selected = CGRect(x: 180, y: 80, width: 50, height: 28)

        XCTAssertEqual(
            MonitoringController.candidateDisplayFrame(
                scope: .selected,
                selectedFrame: selected,
                options: [],
                listFrame: CGRect(x: 10, y: 80, width: 360, height: 28)
            ),
            selected
        )
    }

    func testRowTrackingIgnoresSelectionMovementWithinSameRow() {
        let rowFrame = CGRect(x: 10, y: 80, width: 360, height: 28)
        let first = CandidateTrackingIdentity.make(
            scope: .row,
            selectedText: "翻译",
            selectedFrame: CGRect(x: 20, y: 80, width: 50, height: 28),
            rowTexts: ["翻译", "翻译了"],
            rowFrame: rowFrame
        )
        let second = CandidateTrackingIdentity.make(
            scope: .row,
            selectedText: "翻译了",
            selectedFrame: CGRect(x: 90, y: 80, width: 60, height: 28),
            rowTexts: ["翻译", "翻译了"],
            rowFrame: rowFrame
        )

        XCTAssertEqual(first, second)
    }

    func testSelectedTrackingChangesWhenCandidateChanges() {
        let first = CandidateTrackingIdentity.make(
            scope: .selected,
            selectedText: "翻译",
            selectedFrame: CGRect(x: 20, y: 80, width: 50, height: 28),
            rowTexts: ["翻译"],
            rowFrame: CGRect(x: 20, y: 80, width: 50, height: 28)
        )
        let second = CandidateTrackingIdentity.make(
            scope: .selected,
            selectedText: "翻译了",
            selectedFrame: CGRect(x: 90, y: 80, width: 60, height: 28),
            rowTexts: ["翻译了"],
            rowFrame: CGRect(x: 90, y: 80, width: 60, height: 28)
        )

        XCTAssertNotEqual(first, second)
    }

    func testTextSelectionExcludesMarkedCompositionRange() {
        XCTAssertFalse(
            FocusMonitor.isTextSelection(nil, markedRange: nil)
        )
        XCTAssertFalse(
            FocusMonitor.isTextSelection(
                NSRange(location: 12, length: 0),
                markedRange: nil
            )
        )
        XCTAssertTrue(
            FocusMonitor.isTextSelection(
                NSRange(location: 1, length: 6),
                markedRange: NSRange(location: 7, length: 6)
            )
        )
        XCTAssertFalse(
            FocusMonitor.isTextSelection(
                NSRange(location: 6, length: 5),
                markedRange: NSRange(location: 6, length: 5)
            )
        )
    }

    func testCompositionStateUsesMarkedRange() {
        XCTAssertEqual(
            FocusMonitor.compositionState(for: nil),
            .unknown
        )
        XCTAssertEqual(
            FocusMonitor.compositionState(
                for: NSRange(location: 4, length: 3)
            ),
            .composing
        )
        XCTAssertEqual(
            FocusMonitor.compositionState(
                for: NSRange(location: 7, length: 0)
            ),
            .inactive
        )
    }

    func testComposingStateAlwaysAllowsCandidateScanning() {
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .composing,
                isEditableTextInput: false,
                hasCaret: false
            )
        )
    }

    func testInactiveCompositionFallsBackToTextInputEvidence() {
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .inactive,
                isEditableTextInput: true,
                hasCaret: false
            )
        )
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .inactive,
                isEditableTextInput: false,
                hasCaret: true
            )
        )
        XCTAssertFalse(
            CandidateScanGate.allowsScanning(
                compositionState: .inactive,
                isEditableTextInput: false,
                hasCaret: false
            )
        )
    }

    func testUnknownCompositionFallsBackToTextInputEvidence() {
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .unknown,
                isEditableTextInput: true,
                hasCaret: true
            )
        )
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .unknown,
                isEditableTextInput: false,
                hasCaret: true
            )
        )
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .unknown,
                isEditableTextInput: true,
                hasCaret: false
            )
        )
        XCTAssertFalse(
            CandidateScanGate.allowsScanning(
                compositionState: .unknown,
                isEditableTextInput: false,
                hasCaret: false
            )
        )
    }

    func testEditableTextInputRecognizesTextRolesAndEditableAttribute() {
        XCTAssertTrue(
            FocusMonitor.isEditableTextInput(
                role: kAXTextFieldRole as String,
                editable: false
            )
        )
        XCTAssertTrue(
            FocusMonitor.isEditableTextInput(
                role: kAXTextAreaRole as String,
                editable: false
            )
        )
        XCTAssertTrue(
            FocusMonitor.isEditableTextInput(
                role: kAXGroupRole as String,
                editable: true
            )
        )
        XCTAssertFalse(
            FocusMonitor.isEditableTextInput(
                role: kAXMenuItemRole as String,
                editable: false
            )
        )
    }

    func testAXCandidateIdentityDeduplicatesEquivalentFrame() {
        let frame = CGRect(x: 120, y: 80, width: 48, height: 28)
        let first = AXCandidateItem(text: "吃", frame: frame)
        let second = AXCandidateItem(text: "吃", frame: frame)

        XCTAssertEqual(first.identity, second.identity)
    }

    func testAXVisibleRowUsesVisibleCandidatesAndSelectedIndex() throws {
        let visible = (0..<6).reversed().map { index in
            AXCandidateItem(
                text: "candidate\(index)",
                frame: CGRect(
                    x: CGFloat(index * 60),
                    y: 80,
                    width: 50,
                    height: 28
                )
            )
        }
        let selected = AXCandidateItem(
            text: "candidate2",
            frame: CGRect(x: 999, y: 999, width: 50, height: 28)
        )

        let row = try XCTUnwrap(
            AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visible
            )
        )

        XCTAssertEqual(
            row.items.map(\.text),
            (0..<6).map { "candidate\($0)" }
        )
        XCTAssertEqual(row.selectedIndex, 2)
    }

    func testAXVisibleRowFallsBackToSelectedWhenAbsent() throws {
        let selected = AXCandidateItem(
            text: "selected",
            frame: CGRect(x: 20, y: 80, width: 50, height: 28)
        )
        let visible = [
            AXCandidateItem(
                text: "other",
                frame: CGRect(x: 80, y: 80, width: 50, height: 28)
            ),
        ]

        XCTAssertEqual(
            try XCTUnwrap(
                AXCandidateVisibleRowSelector.select(
                    selected: selected,
                    visible: visible
                )
            ),
            AXCandidateVisibleRow(
                items: [selected],
                selectedIndex: 0
            )
        )
    }

    func testAXVisibleRowRejectsExpandedVisibleRows() {
        let selected = AXCandidateItem(
            text: "candidate0",
            frame: CGRect(x: 20, y: 80, width: 50, height: 28)
        )
        let visible = [
            selected,
            AXCandidateItem(
                text: "candidate1",
                frame: CGRect(x: 80, y: 80, width: 50, height: 28)
            ),
            AXCandidateItem(
                text: "candidate2",
                frame: CGRect(x: 20, y: 110, width: 50, height: 28)
            ),
        ]

        XCTAssertNil(
            AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visible
            )
        )
    }

    func testAXVisibleRowRejectsBulkVisibleChildren() {
        let selected = AXCandidateItem(
            text: "candidate0",
            frame: CGRect(x: 0, y: 80, width: 50, height: 28)
        )
        let visible = (0..<30).map { index in
            AXCandidateItem(
                text: "candidate\(index)",
                frame: CGRect(
                    x: CGFloat(index * 60),
                    y: 80,
                    width: 50,
                    height: 28
                )
            )
        }

        XCTAssertNil(
            AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visible
            )
        )
    }

    func testAXVisibleRowSupportsNineCandidates() throws {
        let visible = (0..<9).map { index in
            AXCandidateItem(
                text: "candidate\(index)",
                frame: CGRect(
                    x: CGFloat(index * 52),
                    y: 120,
                    width: 44,
                    height: 28
                )
            )
        }

        let row = try XCTUnwrap(
            AXCandidateVisibleRowSelector.select(
                selected: visible[4],
                visible: visible
            )
        )

        XCTAssertEqual(row.items, visible)
        XCTAssertEqual(row.selectedIndex, 4)
    }

    func testAXVisibleRowDeduplicatesEquivalentCandidates() throws {
        let selected = AXCandidateItem(
            text: "same",
            frame: CGRect(x: 20, y: 80, width: 50, height: 28)
        )
        let visible = [
            selected,
            AXCandidateItem(
                text: "other",
                frame: CGRect(x: 80, y: 80, width: 50, height: 28)
            ),
            selected,
        ]

        let row = try XCTUnwrap(
            AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visible
            )
        )

        XCTAssertEqual(row.items.map(\.text), ["same", "other"])
        XCTAssertEqual(row.selectedIndex, 0)
    }

    func testAXVisibleRowAcceptsMinorVerticalJitter() throws {
        let selected = AXCandidateItem(
            text: "candidate0",
            frame: CGRect(x: 20, y: 80, width: 50, height: 28)
        )
        let visible = [
            selected,
            AXCandidateItem(
                text: "candidate1",
                frame: CGRect(x: 80, y: 81, width: 50, height: 28)
            ),
        ]

        let row = try XCTUnwrap(
            AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visible
            )
        )

        XCTAssertEqual(row.items.map(\.text), ["candidate0", "candidate1"])
        XCTAssertEqual(row.selectedIndex, 0)
    }

    func testCandidateMissRequiresTwoConsecutiveFrames() {
        var debouncer = CandidateMissDebouncer()

        XCTAssertFalse(debouncer.observeMiss())
        debouncer.observeCandidate()
        XCTAssertFalse(debouncer.observeMiss())
        XCTAssertTrue(debouncer.observeMiss())
    }

    func testCandidateMissResetClearsPartialAbsence() {
        var debouncer = CandidateMissDebouncer()

        XCTAssertFalse(debouncer.observeMiss())
        debouncer.reset()
        XCTAssertFalse(debouncer.observeMiss())
        XCTAssertTrue(debouncer.observeMiss())
    }

    func testCompositionTrackerDetectsExplicitEnd() {
        var tracker = CompositionTransitionTracker()

        XCTAssertFalse(tracker.observe(.composing))
        XCTAssertTrue(tracker.observe(.inactive))
        XCTAssertFalse(tracker.observe(.inactive))
    }

    func testCompositionTrackerDoesNotTreatUnknownStateAsEnd() {
        var tracker = CompositionTransitionTracker()

        XCTAssertFalse(tracker.observe(.unknown))
        XCTAssertFalse(tracker.observe(.inactive))
    }

    func testAmbiguousBlueHighlightsUseNumberedCandidateRow() {
        let message = FocusedCandidateComponent(
            rect: CGRect(x: 180, y: 10, width: 120, height: 34),
            area: 4_080
        )
        let candidate = FocusedCandidateComponent(
            rect: CGRect(x: 60, y: 92, width: 220, height: 34),
            area: 7_480
        )
        let row = NumberedRowEvidence(
            rect: CGRect(x: 90, y: 90, width: 500, height: 34),
            consecutiveCount: 4
        )

        let selected = FocusedCandidateLocator.selectComponent(
            components: [message, candidate],
            numberedRows: [row],
            anchor: CGPoint(x: 240, y: 27)
        )

        XCTAssertEqual(selected, candidate)
    }

    func testAmbiguousBlueHighlightsAreRejectedWithoutNumberedRow() {
        let components = [
            FocusedCandidateComponent(
                rect: CGRect(x: 180, y: 10, width: 120, height: 34),
                area: 4_080
            ),
            FocusedCandidateComponent(
                rect: CGRect(x: 60, y: 92, width: 220, height: 34),
                area: 7_480
            ),
        ]

        XCTAssertNil(
            FocusedCandidateLocator.selectComponent(
                components: components,
                numberedRows: [],
                anchor: CGPoint(x: 240, y: 27)
            )
        )
    }

    func testSingleShortBlueHighlightKeepsFastPath() {
        let component = FocusedCandidateComponent(
            rect: CGRect(x: 60, y: 92, width: 200, height: 34),
            area: 6_800
        )

        XCTAssertEqual(
            FocusedCandidateLocator.selectComponent(
                components: [component],
                numberedRows: [],
                anchor: nil
            ),
            component
        )
    }

    func testLongFocusedCandidateRequiresNumberedRowContext() {
        let component = FocusedCandidateComponent(
            rect: CGRect(x: 60, y: 92, width: 540, height: 30),
            area: 16_200
        )
        let row = NumberedRowEvidence(
            rect: CGRect(x: 70, y: 90, width: 600, height: 34),
            consecutiveCount: 3
        )

        XCTAssertNil(
            FocusedCandidateLocator.selectComponent(
                components: [component],
                numberedRows: [],
                anchor: nil
            )
        )
        XCTAssertEqual(
            FocusedCandidateLocator.selectComponent(
                components: [component],
                numberedRows: [row],
                anchor: nil
            ),
            component
        )
    }

    func testBlueComponentScanAllowsLongFocusedCandidate() throws {
        let width = 800
        let height = 120
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(
            CGColor(red: 0, green: 0.48, blue: 1, alpha: 1)
        )
        context.fill(CGRect(x: 50, y: 35, width: 600, height: 40))

        let image = try XCTUnwrap(context.makeImage())
        let components = FocusedCandidateLocator.blueComponents(in: image)
        let component = try XCTUnwrap(components.first)

        XCTAssertGreaterThan(component.aspectRatio, 6)
        XCTAssertLessThanOrEqual(component.aspectRatio, 18)
    }

    func testMergedOCRTextCanProvideNumberedCandidateRow() {
        let row = CGRect(x: 400, y: 180, width: 300, height: 32)
        let evidence = FocusedCandidateLocator.numberedRows(
            from: [
                NumberedTextObservation(
                    text: "31iJ,l}L8 41IJiE 51IJ,",
                    rect: row
                )
            ]
        )

        XCTAssertEqual(evidence.first?.rect, row)
        XCTAssertEqual(evidence.first?.consecutiveCount, 3)
    }

    func testNumberedCandidateRowRequiresCommonBaseline() {
        let evidence = FocusedCandidateLocator.numberedRows(
            from: [
                NumberedTextObservation(
                    text: "1",
                    rect: CGRect(x: 100, y: 100, width: 10, height: 20)
                ),
                NumberedTextObservation(
                    text: "2",
                    rect: CGRect(x: 150, y: 101, width: 10, height: 20)
                ),
                NumberedTextObservation(
                    text: "3",
                    rect: CGRect(x: 200, y: 150, width: 10, height: 20)
                ),
            ]
        )

        XCTAssertEqual(evidence.first?.consecutiveCount, 2)
        XCTAssertEqual(
            evidence.first?.rect,
            CGRect(x: 100, y: 100, width: 60, height: 21)
        )
    }

    func testProvidedCandidateSampleHasMatchingNumberedRow() throws {
        let image = try loadCandidateSample()
        let components = FocusedCandidateLocator.blueComponents(in: image)
        let rows = FocusedCandidateLocator.numberedRows(in: image)
        if ProcessInfo.processInfo.environment["GLINT_OCR_TRACE"] == "1" {
            print("candidate components: \(components)")
            print("numbered rows: \(rows)")
        }

        XCTAssertFalse(components.isEmpty)
        XCTAssertTrue(
            rows.contains { row in
                components.contains { component in
                    min(component.rect.maxY, row.rect.maxY)
                        > max(component.rect.minY, row.rect.minY)
                }
            }
        )
    }

    func testNumberedRowValidationCacheReturnsStableRows() throws {
        let image = try loadCandidateSample()
        let components = FocusedCandidateLocator.blueComponents(in: image)

        let first = FocusedCandidateLocator.numberedRows(
            in: image,
            near: components
        )
        let second = FocusedCandidateLocator.numberedRows(
            in: image,
            near: components
        )

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(second, first)
    }

    func testBlueMessageAboveSampleDoesNotWinFocusSelection() throws {
        let sample = try loadCandidateSample()
        let width = sample.width
        let height = sample.height + 100
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(
            sample,
            in: CGRect(
                x: 0,
                y: 0,
                width: sample.width,
                height: sample.height
            )
        )
        context.setFillColor(
            CGColor(red: 0.1, green: 0.45, blue: 1, alpha: 1)
        )
        context.fill(
            CGRect(x: 700, y: height - 45, width: 140, height: 36)
        )

        let image = try XCTUnwrap(context.makeImage())
        let selected = try XCTUnwrap(
            FocusedCandidateLocator.bestBlueComponent(
                in: image,
                anchor: CGPoint(x: 760, y: 25)
            )
        )

        XCTAssertEqual(selected.minX, 192, accuracy: 1)
        XCTAssertGreaterThan(selected.minY, 150)
        XCTAssertEqual(
            OCRService(configuration: .appleVision)
                .detect(in: image, anchor: CGPoint(x: 760, y: 25))?.text,
            "你好"
        )
    }

    func testExternalFocusedCandidateScreenshotWhenProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let imagePath = environment["GLINT_FOCUS_TEST_IMAGE"],
              let expectedText = environment["GLINT_FOCUS_EXPECTED_TEXT"] else {
            throw XCTSkip(
                "Set GLINT_FOCUS_TEST_IMAGE and GLINT_FOCUS_EXPECTED_TEXT"
            )
        }
        let image = try loadImage(at: URL(fileURLWithPath: imagePath))
        let anchor: CGPoint? = if
            let x = environment["GLINT_FOCUS_ANCHOR_X"].flatMap(Double.init),
            let y = environment["GLINT_FOCUS_ANCHOR_Y"].flatMap(Double.init) {
            CGPoint(x: x, y: y)
        } else {
            nil
        }

        let service = OCRService(configuration: .appleVision)
        XCTAssertEqual(
            service.detect(in: image, anchor: anchor)?.text,
            expectedText
        )
        XCTAssertEqual(
            service.detect(in: image, anchor: anchor)?.text,
            expectedText
        )
    }

    @MainActor
    func testInputSourceReturnsString() async {
        XCTAssertFalse(InputSourceMonitor().currentInputSourceID().contains(" "))
    }
}
