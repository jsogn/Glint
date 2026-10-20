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

    func testAppleVisionFallbackWhenPPOCRIsUnavailable() throws {
        let image = try loadCandidateSample()
        let service = OCRService(
            configuration: OCRRuntimeConfiguration(
                preferredBackend: .ppocr,
                ppocrPluginDirectory: nil
            )
        )
        XCTAssertEqual(service.detect(in: image)?.text, "你好")
    }

    func testAppleVisionAutomaticEnhancementUsesPPOCRForLowConfidence() throws {
        let image = try loadImage(at: ocrDatasetURL("synthetic_021_0.png"))
        let service = OCRService(
            configuration: OCRRuntimeConfiguration(
                preferredBackend: .vision,
                ppocrPluginDirectory: pluginDirectoryURL(),
                candidateCacheEnabled: false,
                enhancementMode: .automatic
            )
        )

        XCTAssertEqual(service.detect(in: image)?.text, "重要")
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
                preferredBackend: .ppocr,
                ppocrPluginDirectory: pluginDirectoryURL(),
                candidateCacheEnabled: cacheEnabled
            )
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

    func testBlueHighlightPrefersComponentNearCaret() throws {
        let width = 400
        let height = 200
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 50, y: 150, width: 100, height: 30))
        context.fill(CGRect(x: 100, y: 20, width: 80, height: 30))

        let image = try XCTUnwrap(context.makeImage())
        let selected = try XCTUnwrap(OCRService.bestBlueComponent(
            in: image,
            anchor: CGPoint(x: 140, y: 165)
        ))

        XCTAssertEqual(selected.origin.x, 100)
        XCTAssertEqual(selected.origin.y, 150)
    }

    @MainActor
    func testInputSourceReturnsString() async {
        XCTAssertFalse(InputSourceMonitor().currentInputSourceID().contains(" "))
    }
}
