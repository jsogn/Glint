import CoreGraphics
import Foundation
import GlintONNXRuntime
import Security

final class PPOCRRecognizer: @unchecked Sendable {
    struct Recognition {
        let text: String
        let confidence: Float
    }

    private let modelURL: URL
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var characters: [String] = []
    private var initialized = false
    private var preferredFlip: Bool?
    private(set) var initializationError: String?
    private(set) var lastTimings = (
        preprocessMs: 0.0,
        inferenceMs: 0.0,
        decodeMs: 0.0
    )

    init(pluginDirectory: URL) {
        let modelDirectory = pluginDirectory
            .appendingPathComponent("model", isDirectory: true)
        self.modelURL = modelDirectory.appendingPathComponent("model.onnx")
    }

    private var runtimeURL: URL? {
        Self.resourceURL(
            name: "libonnxruntime.1",
            extension: "dylib",
            subdirectory: "ONNXRuntime"
        )
    }

    private var charactersURL: URL? {
        let pluginCharacters = modelURL
            .deletingLastPathComponent()
            .appendingPathComponent("characters.json")
        if FileManager.default.fileExists(atPath: pluginCharacters.path) {
            return pluginCharacters
        }
        return Self.resourceURL(
            name: "characters",
            extension: "json",
            subdirectory: "OCR/PP-OCRv6"
        )
    }

    var isAvailable: Bool {
        runtimeURL != nil
            && FileManager.default.fileExists(atPath: modelURL.path)
            && charactersURL != nil
    }

    func validate() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard isAvailable else {
            initializationError = "PP-OCR 插件资源不完整"
            return initializationError
        }
        guard let runtimeURL, Self.hasValidSignature(runtimeURL) else {
            initializationError = "PP-OCR 运行库签名无效"
            return initializationError
        }
        initializationError = nil
        return nil
    }

    func warmUp() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard prepareIfNeeded() else {
            return initializationError ?? "PP-OCR 初始化失败"
        }
        return nil
    }

    func recognize(_ image: CGImage) -> Recognition? {
        lock.lock()
        defer { lock.unlock() }
        guard prepareIfNeeded() else {
            return nil
        }

        if let preferredFlip {
            let primary = recognizeOnce(
                image,
                flipVertically: preferredFlip
            )
            if let primary, primary.confidence >= 0.6 {
                traceResults(
                    primary: primary,
                    alternate: nil,
                    reusedOrientation: preferredFlip
                )
                return primary
            }

            let alternateFlip = !preferredFlip
            let alternate = recognizeOnce(
                image,
                flipVertically: alternateFlip
            )
            traceResults(
                primary: primary,
                alternate: alternate,
                reusedOrientation: preferredFlip
            )
            guard let selected = choose(
                primary: primary,
                primaryFlip: preferredFlip,
                alternate: alternate,
                alternateFlip: alternateFlip
            ) else {
                return nil
            }
            self.preferredFlip = selected.flip
            return selected.recognition
        }

        let primary = recognizeOnce(image, flipVertically: true)
        let alternate = recognizeOnce(image, flipVertically: false)
        traceResults(
            primary: primary,
            alternate: alternate,
            reusedOrientation: nil
        )
        guard let selected = choose(
            primary: primary,
            primaryFlip: true,
            alternate: alternate,
            alternateFlip: false
        ) else {
            return nil
        }
        preferredFlip = selected.flip
        return selected.recognition
    }

    private func choose(
        primary: Recognition?,
        primaryFlip: Bool,
        alternate: Recognition?,
        alternateFlip: Bool
    ) -> (recognition: Recognition, flip: Bool)? {
        if let primary, let alternate {
            if primary.text.count != alternate.text.count {
                let longer = primary.text.count > alternate.text.count
                    ? primary
                    : alternate
                let shorter = primary.text.count > alternate.text.count
                    ? alternate
                    : primary
                if longer.confidence >= 0.75 {
                    return (
                        longer,
                        longer.text == primary.text ? primaryFlip : alternateFlip
                    )
                }
                return (
                    shorter,
                    shorter.text == primary.text ? primaryFlip : alternateFlip
                )
            }
            if alternate.confidence > primary.confidence {
                return (alternate, alternateFlip)
            }
            return (primary, primaryFlip)
        }
        if let primary {
            return (primary, primaryFlip)
        }
        if let alternate {
            return (alternate, alternateFlip)
        }
        return nil
    }

    private func traceResults(
        primary: Recognition?,
        alternate: Recognition?,
        reusedOrientation: Bool?
    ) {
        guard ProcessInfo.processInfo.environment["GLINT_OCR_TRACE"] == "1" else {
            return
        }
        fputs(
            "Glint PP-OCR orientation: primary=\(primary?.text ?? "<nil>")"
                + "/\(primary?.confidence ?? 0) "
                + "alternate=\(alternate?.text ?? "<nil>")"
                + "/\(alternate?.confidence ?? 0) "
                + "reused=\(reusedOrientation.map(String.init) ?? "none")\n",
            stderr
        )
    }

    private func recognizeOnce(
        _ image: CGImage,
        flipVertically: Bool
    ) -> Recognition? {
        guard let handle else {
            return nil
        }
        let preprocessStarted = ContinuousClock.now
        let input = preprocess(image, flipVertically: flipVertically)
        let preprocessMs = elapsedMilliseconds(
            preprocessStarted.duration(to: .now)
        )
        guard input.width > 0, !input.pixels.isEmpty else {
            return nil
        }

        let inferenceStarted = ContinuousClock.now
        var result = GlintORTResult()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = input.pixels.withUnsafeBufferPointer { buffer in
            glint_ort_run(
                handle,
                buffer.baseAddress,
                48,
                Int32(input.width),
                &result,
                &errorPointer
            )
        }
        defer {
            if let errorPointer {
                glint_ort_string_free(errorPointer)
            }
        }
        guard status == 0,
              result.rank == 3,
              result.dimensions.0 == 1,
              let data = result.data else {
            return nil
        }
        defer { glint_ort_result_free(&result) }
        let inferenceMs = elapsedMilliseconds(
            inferenceStarted.duration(to: .now)
        )

        let decodeStarted = ContinuousClock.now
        let timesteps = Int(result.dimensions.1)
        let classCount = Int(result.dimensions.2)
        guard timesteps > 0,
              classCount == characters.count,
              result.element_count >= Int64(timesteps * classCount) else {
            return nil
        }

        var decoded = GlintCTCResult()
        let decodeStatus = glint_ctc_greedy_decode(
            data,
            Int64(timesteps),
            Int64(classCount),
            &decoded
        )
        guard decodeStatus == 0, let indices = decoded.indices,
              let scores = decoded.scores else {
            return nil
        }
        defer { glint_ctc_result_free(&decoded) }

        var text = ""
        var confidenceValues: [Float] = []
        text.reserveCapacity(min(Int(decoded.count), 64))
        confidenceValues.reserveCapacity(min(Int(decoded.count), 64))
        for index in 0..<Int(decoded.count) {
            text += characters[Int(indices[index])]
            confidenceValues.append(scores[index])
        }

        let cleaned = String(text.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        })
        guard !cleaned.isEmpty else { return nil }
        let confidence = confidenceValues.isEmpty
            ? 0
            : confidenceValues.reduce(0, +) / Float(confidenceValues.count)
        lastTimings = (
            preprocessMs,
            inferenceMs,
            elapsedMilliseconds(decodeStarted.duration(to: .now))
        )
        return Recognition(text: cleaned, confidence: confidence)
    }

    private func prepareIfNeeded() -> Bool {
        if initialized {
            return handle != nil
        }
        initialized = true
        guard isAvailable,
              let runtimeURL,
              let charactersURL,
              let charactersData = try? Data(contentsOf: charactersURL),
              let rawCharacters = try? JSONDecoder().decode(
                  [String].self,
                  from: charactersData
              ) else {
            initializationError = "PP-OCR 插件资源不完整"
            fputs(
                "Glint PP-OCR: runtime=\(runtimeURL?.path ?? "missing") "
                    + "model=\(modelURL.path) "
                    + "characters=\(charactersURL?.path ?? "missing")\n",
                stderr
            )
            return false
        }
        guard Self.hasValidSignature(runtimeURL) else {
            initializationError = "PP-OCR 运行库签名无效"
            return false
        }
        characters = ["blank"] + rawCharacters + [" "]

        var errorPointer: UnsafeMutablePointer<CChar>?
        let threadCount = Int32(
            ProcessInfo.processInfo.environment["GLINT_ORT_THREADS"] ?? "4"
        ) ?? 4
        let created = runtimeURL.path.withCString { runtimePath in
            modelURL.path.withCString { modelPath in
                glint_ort_create(
                    runtimePath,
                    modelPath,
                    threadCount,
                    &errorPointer
                )
            }
        }
        if let errorPointer {
            initializationError = String(cString: errorPointer)
            fputs("Glint PP-OCR: \(initializationError!)\n", stderr)
            glint_ort_string_free(errorPointer)
        }
        handle = created
        return created != nil
    }

    private func elapsedMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds)
            / 1_000_000_000_000_000
    }

    private func preprocess(
        _ image: CGImage,
        flipVertically: Bool
    ) -> (pixels: [Float], width: Int) {
        let sourceWidth = max(1, image.width)
        let sourceHeight = max(1, image.height)
        let ratio = Double(sourceWidth) / Double(sourceHeight)
        let resizedWidth = min(3_200, max(1, Int(ceil(48 * ratio))))
        let modelWidth = max(320, resizedWidth)

        var rgba = [UInt8](repeating: 255, count: modelWidth * 48 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &rgba,
            width: modelWidth,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: modelWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return ([], 0)
        }
        context.setFillColor(
            CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: modelWidth, height: 48))
        if flipVertically {
            context.translateBy(x: 0, y: 48)
            context.scaleBy(x: 1, y: -1)
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: resizedWidth, height: 48)
        )

        let planeSize = modelWidth * 48
        var pixels = [Float](
            repeating: 0,
            count: planeSize * 3
        )
        for index in 0..<planeSize {
            let rgbaOffset = index * 4
            let b = Float(rgba[rgbaOffset + 2])
            let g = Float(rgba[rgbaOffset + 1])
            let r = Float(rgba[rgbaOffset])
            pixels[index] = b / 127.5 - 1
            pixels[planeSize + index] = g / 127.5 - 1
            pixels[planeSize * 2 + index] = r / 127.5 - 1
        }
        return (pixels, modelWidth)
    }

    private static func hasValidSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else {
            return false
        }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
                | kSecCSStrictValidate
        )
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    private static func resourceURL(
        name: String,
        extension fileExtension: String,
        subdirectory: String
    ) -> URL? {
        let bundleCandidates = [
            Bundle.main.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "Resources/\(subdirectory)"
            ),
            Bundle.main.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ),
        ]
        if let url = bundleCandidates.compactMap({ $0 }).first {
            return url
        }

        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent(
                    "\(name).\(fileExtension)",
                    isDirectory: false
                )
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
