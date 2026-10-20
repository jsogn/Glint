import CoreGraphics
import Foundation
import GlintCore
import Vision

public struct OCRDetection: Sendable, Equatable {
    public let text: String
    public let highlightRect: CGRect
    public let confidence: Float

    public init(text: String, highlightRect: CGRect, confidence: Float) {
        self.text = text
        self.highlightRect = highlightRect
        self.confidence = confidence
    }
}

public enum OCRBackend: String, Sendable, Equatable {
    case vision
    case ppocr
}

public struct OCRRuntimeConfiguration: Sendable, Equatable {
    public let preferredBackend: OCRBackend
    public let ppocrPluginDirectory: URL?
    public let ppocrPluginToken: String?
    public let candidateCacheEnabled: Bool
    public let enhancementMode: OCREnhancementMode

    public init(
        preferredBackend: OCRBackend = .vision,
        ppocrPluginDirectory: URL? = nil,
        ppocrPluginToken: String? = nil,
        candidateCacheEnabled: Bool = true,
        enhancementMode: OCREnhancementMode = .automatic
    ) {
        self.preferredBackend = preferredBackend
        self.ppocrPluginDirectory = ppocrPluginDirectory
        self.ppocrPluginToken = ppocrPluginToken
        self.candidateCacheEnabled = candidateCacheEnabled
        self.enhancementMode = enhancementMode
    }

    public static let appleVision = OCRRuntimeConfiguration()
}

public struct OCRService: Sendable {
    private let configuration: OCRRuntimeConfiguration
    private let ppOCR: PPOCRRecognizer?
    private let resultCache = OCRResultCache()

    public init(configuration: OCRRuntimeConfiguration = .appleVision) {
        self.configuration = configuration
        self.ppOCR = configuration.ppocrPluginDirectory.map {
            PPOCRRecognizer(pluginDirectory: $0)
        }
    }

    public var isPPOCRAvailable: Bool {
        ppOCR?.isAvailable == true
    }

    var ppocrTimings: (
        preprocessMs: Double,
        inferenceMs: Double,
        decodeMs: Double
    ) {
        ppOCR?.lastTimings ?? (0, 0, 0)
    }

    var lastUsedCandidateCache: Bool {
        resultCache.lastHit
    }

    func warmUpPreferredBackend() {
        guard configuration.preferredBackend == .ppocr
                || configuration.enhancementMode != .off else {
            return
        }
        _ = ppOCR?.warmUp()
    }

    public func validatePreferredBackend() -> String? {
        guard configuration.preferredBackend == .ppocr else { return nil }
        guard let ppOCR else {
            return "PP-OCR 插件尚未安装"
        }
        return ppOCR.validate()
    }

    public func detect(in image: CGImage, anchor: CGPoint? = nil) -> OCRDetection? {
        guard let blueRect = Self.bestBlueComponent(in: image, anchor: anchor) else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let padded = blueRect.insetBy(dx: -6, dy: -6).intersection(bounds)
        guard padded.width > 8,
              padded.height > 8,
              let cropped = image.cropping(to: padded) else {
            return nil
        }

        let traceOCR = ProcessInfo.processInfo.environment[
            "GLINT_OCR_TRACE"
        ] == "1"
        let signature = configuration.candidateCacheEnabled
            ? OCRCandidateSignature(image: cropped)
            : nil
        if let signature,
           let cached = resultCache.lookup(signature) {
            if traceOCR {
                fputs("Glint OCR: cache=hit text=\(cached.text)\n", stderr)
            }
            return OCRDetection(
                text: cached.text,
                highlightRect: blueRect,
                confidence: cached.confidence
            )
        }
        let requestedBackend = ProcessInfo.processInfo.environment[
            "GLINT_OCR_BACKEND"
        ]?.lowercased()
        let preferredBackend: OCRBackend = switch requestedBackend {
        case "vision": .vision
        case "ppocr": .ppocr
        default: configuration.preferredBackend
        }
        var recognition: (String, Float)?
        if traceOCR {
            fputs(
                "Glint OCR: preferred=\(preferredBackend.rawValue) "
                    + "ppocrAvailable=\(isPPOCRAvailable) "
                    + "crop=\(cropped.width)x\(cropped.height)\n",
                stderr
            )
        }
        switch preferredBackend {
        case .ppocr:
            recognition = recognizeWithPPOCR(in: cropped, trace: traceOCR)
            if recognition == nil {
                recognition = recognizeWithVision(in: cropped, trace: traceOCR)
            }
        case .vision:
            recognition = recognizeWithVision(in: cropped, trace: traceOCR)
            if requestedBackend == nil {
                recognition = applyEnhancement(
                    to: recognition,
                    image: cropped,
                    trace: traceOCR
                )
            } else if recognition == nil {
                recognition = recognizeWithPPOCR(
                    in: cropped,
                    trace: traceOCR
                )
            }
        }

        guard let (text, confidence) = recognition else { return nil }
        let cleaned = Self.cleanCandidate(text)
        guard !cleaned.isEmpty else { return nil }
        if let signature {
            resultCache.store(
                signature: signature,
                text: cleaned,
                confidence: confidence
            )
        }

        return OCRDetection(
            text: cleaned,
            highlightRect: blueRect,
            confidence: confidence
        )
    }

    private func applyEnhancement(
        to visionResult: (String, Float)?,
        image: CGImage,
        trace: Bool
    ) -> (String, Float)? {
        guard configuration.enhancementMode != .off,
              isPPOCRAvailable else {
            return visionResult
        }
        let shouldEnhance = configuration.enhancementMode == .always
            || visionResult == nil
            || (visionResult?.1 ?? 0) < 0.65
        guard shouldEnhance else { return visionResult }
        if trace {
            fputs(
                "Glint OCR: enhancement=\(configuration.enhancementMode.rawValue) "
                    + "visionConfidence=\(visionResult?.1 ?? 0)\n",
                stderr
            )
        }
        let enhanced = recognizeWithPPOCR(in: image, trace: trace)
        guard let visionResult else { return enhanced }
        guard let enhanced else { return visionResult }
        return enhanced.1 > visionResult.1 + 0.02
            ? enhanced
            : visionResult
    }

    private func recognizeWithPPOCR(
        in image: CGImage,
        trace: Bool
    ) -> (String, Float)? {
        guard let ppOCR, ppOCR.isAvailable else { return nil }
        let result = ppOCR.recognize(image)
        if trace {
            fputs(
                "Glint OCR: ppocr=\(result?.text ?? "<nil>") "
                    + "confidence=\(result?.confidence ?? 0)\n",
                stderr
            )
        }
        guard let result, result.confidence >= 0.6 else { return nil }
        return (result.text, result.confidence)
    }

    private func recognizeWithVision(
        in image: CGImage,
        trace: Bool
    ) -> (String, Float)? {
        let result = Self.ocr(image)
        if trace {
            fputs(
                "Glint OCR: vision=\(result?.0 ?? "<nil>")\n",
                stderr
            )
        }
        return result
    }

    private static func cleanCandidate(_ text: String) -> String {
        let allowed = CharacterSet.letters
        return String(text.unicodeScalars.filter { allowed.contains($0) })
    }

    private static func ocr(_ image: CGImage) -> (String, Float)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let candidates = (request.results ?? []).compactMap { observation -> (String, Float)? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let hasLetter = best.string.unicodeScalars.contains {
                CharacterSet.letters.contains($0)
            }
            guard hasLetter else { return nil }
            return (best.string, best.confidence)
        }
        return candidates.max { $0.1 < $1.1 }
    }

    static func bestBlueComponent(in image: CGImage, anchor: CGPoint?) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var visited = [Bool](repeating: false, count: width * height)
        var bestRect: CGRect?
        var bestScore = Int.min
        var bestDistanceSquared = CGFloat.greatestFiniteMagnitude

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if visited[index] { continue }
                visited[index] = true

                let offset = index * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                guard b > 120, b - r > 40, b - g > 15 else { continue }

                var stack = [index]
                var area = 0
                var minX = x
                var maxX = x
                var minY = y
                var maxY = y

                while let current = stack.popLast() {
                    let cy = current / width
                    let cx = current % width
                    area += 1
                    minX = min(minX, cx)
                    maxX = max(maxX, cx)
                    minY = min(minY, cy)
                    maxY = max(maxY, cy)

                    for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighbor = ny * width + nx
                        if visited[neighbor] { continue }
                        visited[neighbor] = true

                        let neighborOffset = neighbor * 4
                        let nr = Int(pixels[neighborOffset])
                        let ng = Int(pixels[neighborOffset + 1])
                        let nb = Int(pixels[neighborOffset + 2])
                        if nb > 120, nb - nr > 40, nb - ng > 15 {
                            stack.append(neighbor)
                        }
                    }
                }

                let componentWidth = maxX - minX + 1
                let componentHeight = maxY - minY + 1
                let topLeftRect = CGRect(
                    x: minX,
                    y: height - maxY - 1,
                    width: componentWidth,
                    height: componentHeight
                )
                guard area >= 400,
                      componentWidth >= 30,
                      componentHeight >= 16,
                      componentWidth >= componentHeight,
                      componentWidth <= componentHeight * 6,
                      componentWidth <= 1200,
                      componentHeight <= 120,
                      area <= 80_000 else {
                    continue
                }

                if let anchor {
                    let dx = topLeftRect.midX - anchor.x
                    let dy = topLeftRect.midY - anchor.y
                    let distanceSquared = dx * dx + dy * dy
                    if distanceSquared < bestDistanceSquared {
                        bestDistanceSquared = distanceSquared
                        bestRect = topLeftRect
                    }
                } else {
                    let score = area - Int(topLeftRect.minY) * 10
                    if score > bestScore {
                        bestScore = score
                        bestRect = topLeftRect
                    }
                }
            }
        }
        return bestRect
    }
}
