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

public struct OCRModelRuntimeConfiguration: Sendable, Equatable {
    public let id: String
    public let backend: OCRBackend
    public let ppocrPluginDirectory: URL?
    public let ppocrPluginToken: String?

    public init(
        id: String,
        backend: OCRBackend,
        ppocrPluginDirectory: URL? = nil,
        ppocrPluginToken: String? = nil
    ) {
        self.id = id
        self.backend = backend
        self.ppocrPluginDirectory = ppocrPluginDirectory
        self.ppocrPluginToken = ppocrPluginToken
    }

    public static let appleVision = OCRModelRuntimeConfiguration(
        id: OCRRecognitionPreferences.visionModelID,
        backend: .vision
    )
}

public struct OCRRuntimeConfiguration: Sendable, Equatable {
    public let primaryModel: OCRModelRuntimeConfiguration
    public let backupModel: OCRModelRuntimeConfiguration?
    public let recognitionStrategy: OCRRecognitionStrategy
    public let candidateCacheEnabled: Bool

    public init(
        primaryModel: OCRModelRuntimeConfiguration = .appleVision,
        backupModel: OCRModelRuntimeConfiguration? = nil,
        recognitionStrategy: OCRRecognitionStrategy = .primaryOnly,
        candidateCacheEnabled: Bool = true
    ) {
        self.primaryModel = primaryModel
        self.backupModel = backupModel?.id == primaryModel.id
            ? nil
            : backupModel
        self.recognitionStrategy = recognitionStrategy
        self.candidateCacheEnabled = candidateCacheEnabled
    }

    public static let appleVision = OCRRuntimeConfiguration()
}

public struct OCRService: Sendable {
    private struct Recognition {
        let text: String
        let confidence: Float
        let model: OCRModelRuntimeConfiguration
    }

    private let configuration: OCRRuntimeConfiguration
    private let primaryPPOCR: PPOCRRecognizer?
    private let backupPPOCR: PPOCRRecognizer?
    private let resultCache = OCRResultCache()

    public init(configuration: OCRRuntimeConfiguration = .appleVision) {
        self.configuration = configuration
        self.primaryPPOCR = configuration.primaryModel.ppocrPluginDirectory.map {
            PPOCRRecognizer(pluginDirectory: $0)
        }
        self.backupPPOCR = configuration.backupModel?.ppocrPluginDirectory.map {
            PPOCRRecognizer(pluginDirectory: $0)
        }
    }

    public var isPPOCRAvailable: Bool {
        requiredModels.contains {
            ppOCRRecognizer(for: $0)?.isAvailable == true
        }
    }

    var ppocrTimings: (
        preprocessMs: Double,
        inferenceMs: Double,
        decodeMs: Double
    ) {
        (primaryPPOCR ?? backupPPOCR)?.lastTimings ?? (0, 0, 0)
    }

    var lastUsedCandidateCache: Bool {
        resultCache.lastHit
    }

    func warmUpConfiguredBackends() {
        for model in requiredModels {
            _ = ppOCRRecognizer(for: model)?.warmUp()
        }
    }

    public func validateConfiguration() -> String? {
        for model in requiredModels where model.backend == .ppocr {
            guard let recognizer = ppOCRRecognizer(for: model) else {
                return "\(model.id) 插件尚未安装"
            }
            if let error = recognizer.validate() {
                return "\(model.id)：\(error)"
            }
        }
        return nil
    }

    public func detect(in image: CGImage, anchor: CGPoint? = nil) -> OCRDetection? {
        guard let blueRect = FocusedCandidateLocator.bestBlueComponent(
                in: image,
                anchor: anchor
              ),
              let recognition = recognizeCropped(
                in: image,
                rect: blueRect,
                padding: 6
              ) else {
            return nil
        }
        let cleaned = Self.cleanCandidate(recognition.text)
        guard !cleaned.isEmpty else { return nil }
        return OCRDetection(
            text: cleaned,
            highlightRect: blueRect,
            confidence: recognition.confidence
        )
    }

    private func requestedBackend() -> OCRBackend? {
        let requested = ProcessInfo.processInfo.environment[
            "GLINT_OCR_BACKEND"
        ]?.lowercased()
        return switch requested {
        case "vision": .vision
        case "ppocr": .ppocr
        default: nil
        }
    }

    private func recognizeCropped(
        in image: CGImage,
        rect: CGRect,
        padding: CGFloat
    ) -> Recognition? {
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )
        let padded = rect.insetBy(dx: -padding, dy: -padding)
            .intersection(bounds)
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
            return Recognition(
                text: cached.text,
                confidence: cached.confidence,
                model: configuration.primaryModel
            )
        }
        if traceOCR {
            fputs(
                "Glint OCR: strategy=\(configuration.recognitionStrategy.rawValue) "
                    + "primary=\(configuration.primaryModel.id) "
                    + "backup=\(configuration.backupModel?.id ?? "<none>") "
                    + "ppocrAvailable=\(isPPOCRAvailable) "
                    + "crop=\(cropped.width)x\(cropped.height)\n",
                stderr
            )
        }
        let recognition = if let forcedBackend = requestedBackend() {
            forcedModel(for: forcedBackend).flatMap {
                recognize(model: $0, in: cropped, trace: traceOCR)
            }
        } else {
            recognizeUsingStrategy(in: cropped, trace: traceOCR)
        }

        guard let recognition else { return nil }
        let cleaned = Self.cleanCandidate(recognition.text)
        guard !cleaned.isEmpty else { return nil }
        if let signature {
            resultCache.store(
                signature: signature,
                text: cleaned,
                confidence: recognition.confidence
            )
        }
        return Recognition(
            text: cleaned,
            confidence: recognition.confidence,
            model: recognition.model
        )
    }

    private var requiredModels: [OCRModelRuntimeConfiguration] {
        guard configuration.recognitionStrategy != .primaryOnly,
              let backup = configuration.backupModel,
              backup.id != configuration.primaryModel.id else {
            return [configuration.primaryModel]
        }
        return [configuration.primaryModel, backup]
    }

    private func forcedModel(
        for backend: OCRBackend
    ) -> OCRModelRuntimeConfiguration? {
        requiredModels.first { $0.backend == backend }
    }

    private func recognizeUsingStrategy(
        in image: CGImage,
        trace: Bool
    ) -> Recognition? {
        let primary = recognize(
            model: configuration.primaryModel,
            in: image,
            trace: trace
        )
        guard configuration.recognitionStrategy != .primaryOnly,
              let backupModel = configuration.backupModel,
              backupModel.id != configuration.primaryModel.id else {
            return primary
        }

        switch configuration.recognitionStrategy {
        case .primaryOnly:
            return primary
        case .automaticFallback:
            if let primary,
               Self.isUsable(primary) {
                return primary
            }
            let backup = recognize(model: backupModel, in: image, trace: trace)
            if let backup, Self.isUsable(backup) {
                return backup
            }
            return primary ?? backup
        case .dualVerification:
            let backup = recognize(model: backupModel, in: image, trace: trace)
            return Self.chooseBetter(primary: primary, backup: backup)
        }
    }

    private func recognize(
        model: OCRModelRuntimeConfiguration,
        in image: CGImage,
        trace: Bool
    ) -> Recognition? {
        let result: (text: String, confidence: Float)?
        switch model.backend {
        case .vision:
            result = Self.ocr(image)
        case .ppocr:
            guard let recognizer = ppOCRRecognizer(for: model),
                  recognizer.isAvailable,
                  let recognized = recognizer.recognize(image) else {
                return nil
            }
            result = (recognized.text, recognized.confidence)
        }
        if trace {
            fputs(
                "Glint OCR: model=\(model.id) "
                    + "backend=\(model.backend.rawValue) "
                    + "text=\(result?.text ?? "<nil>") "
                    + "confidence=\(result?.confidence ?? 0)\n",
                stderr
            )
        }
        guard let result else { return nil }
        return Recognition(
            text: result.text,
            confidence: result.confidence,
            model: model
        )
    }

    private func ppOCRRecognizer(
        for model: OCRModelRuntimeConfiguration
    ) -> PPOCRRecognizer? {
        guard model.backend == .ppocr else { return nil }
        if model.id == configuration.primaryModel.id {
            return primaryPPOCR
        }
        if model.id == configuration.backupModel?.id {
            return backupPPOCR
        }
        return nil
    }

    private static func isUsable(_ recognition: Recognition) -> Bool {
        !cleanCandidate(recognition.text).isEmpty
            && recognition.confidence >= minimumConfidence(for: recognition)
    }

    private static func chooseBetter(
        primary: Recognition?,
        backup: Recognition?
    ) -> Recognition? {
        guard let primary else { return backup }
        guard let backup else { return primary }
        let primaryText = cleanCandidate(primary.text)
        let backupText = cleanCandidate(backup.text)
        guard !primaryText.isEmpty else { return backup }
        guard !backupText.isEmpty else { return primary }
        if primaryText == backupText {
            return backup.confidence > primary.confidence ? backup : primary
        }

        let primaryQuality = normalizedQuality(primary)
        let backupQuality = normalizedQuality(backup)
        return backupQuality > primaryQuality + 0.2 ? backup : primary
    }

    private static func normalizedQuality(_ recognition: Recognition) -> Double {
        Double(recognition.confidence)
            / Double(minimumConfidence(for: recognition))
    }

    private static func minimumConfidence(for recognition: Recognition) -> Float {
        recognition.model.backend == .vision ? 0.65 : 0.6
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
}
