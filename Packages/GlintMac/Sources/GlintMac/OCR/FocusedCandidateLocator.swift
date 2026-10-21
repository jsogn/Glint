import CoreGraphics
import Foundation
import Vision

struct FocusedCandidateComponent: Sendable, Equatable {
    let rect: CGRect
    let area: Int

    var aspectRatio: CGFloat {
        guard rect.height > 0 else { return .infinity }
        return rect.width / rect.height
    }
}

struct NumberedRowEvidence: Sendable, Equatable {
    let rect: CGRect
    let consecutiveCount: Int
}

struct NumberedTextObservation: Sendable, Equatable {
    let text: String
    let rect: CGRect
}

enum FocusedCandidateLocator {
    private static let naturalMaximumAspectRatio: CGFloat = 6
    private static let contextualMaximumAspectRatio: CGFloat = 18
    private static let validationCache = ValidationCache()

    static func bestBlueComponent(
        in image: CGImage,
        anchor: CGPoint?
    ) -> CGRect? {
        let components = blueComponents(in: image)
        guard !components.isEmpty else { return nil }

        let requiresContext = components.count > 1
            || components.contains {
                $0.aspectRatio > naturalMaximumAspectRatio
            }
        let rows = requiresContext
            ? numberedRows(in: image, near: components)
            : []
        let selected = selectComponent(
            components: components,
            numberedRows: rows,
            anchor: anchor
        )

        if ProcessInfo.processInfo.environment["GLINT_OCR_TRACE"] == "1" {
            let componentsDescription = components.map {
                "\(Int($0.rect.width))x\(Int($0.rect.height))"
            }.joined(separator: ",")
            fputs(
                "Glint focus: components=[\(componentsDescription)] "
                    + "numberedRows=\(rows.count) "
                    + "selected=\(selected?.rect.debugDescription ?? "<nil>")\n",
                stderr
            )
        }
        return selected?.rect
    }

    static func blueComponents(in image: CGImage) -> [FocusedCandidateComponent] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }

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
            return []
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        var visited = [Bool](repeating: false, count: width * height)
        var components: [FocusedCandidateComponent] = []

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if visited[index] { continue }
                visited[index] = true
                guard isAccentBlue(pixels: pixels, index: index) else {
                    continue
                }

                var stack = [index]
                var area = 0
                var minX = x
                var maxX = x
                var minY = y
                var maxY = y

                while let current = stack.popLast() {
                    let currentY = current / width
                    let currentX = current % width
                    area += 1
                    minX = min(minX, currentX)
                    maxX = max(maxX, currentX)
                    minY = min(minY, currentY)
                    maxY = max(maxY, currentY)

                    for (nextX, nextY) in [
                        (currentX - 1, currentY),
                        (currentX + 1, currentY),
                        (currentX, currentY - 1),
                        (currentX, currentY + 1),
                    ] {
                        guard nextX >= 0,
                              nextX < width,
                              nextY >= 0,
                              nextY < height else {
                            continue
                        }
                        let neighbor = nextY * width + nextX
                        if visited[neighbor] { continue }
                        visited[neighbor] = true
                        if isAccentBlue(pixels: pixels, index: neighbor) {
                            stack.append(neighbor)
                        }
                    }
                }

                let componentWidth = maxX - minX + 1
                let componentHeight = maxY - minY + 1
                let rect = CGRect(
                    x: minX,
                    y: height - maxY - 1,
                    width: componentWidth,
                    height: componentHeight
                )
                guard area >= 400,
                      componentWidth >= 30,
                      componentHeight >= 16,
                      componentWidth >= componentHeight,
                      CGFloat(componentWidth)
                        <= CGFloat(componentHeight)
                            * contextualMaximumAspectRatio,
                      componentWidth <= 1_200,
                      componentHeight <= 120,
                      area <= 80_000 else {
                    continue
                }
                components.append(
                    FocusedCandidateComponent(rect: rect, area: area)
                )
            }
        }
        return components
    }

    static func selectComponent(
        components: [FocusedCandidateComponent],
        numberedRows: [NumberedRowEvidence],
        anchor: CGPoint?
    ) -> FocusedCandidateComponent? {
        guard !components.isEmpty else { return nil }
        if components.count == 1,
           components[0].aspectRatio <= naturalMaximumAspectRatio {
            return components[0]
        }

        let matches = components.compactMap { component -> CandidateRowMatch? in
            guard let row = numberedRows.first(where: {
                verticallyOverlaps(component.rect, $0.rect)
            }) else {
                return nil
            }
            let overlapHeight = verticalOverlapHeight(
                component.rect,
                row.rect
            )
            return CandidateRowMatch(
                component: component,
                row: row,
                overlapFraction: overlapHeight
                    / max(1, min(component.rect.height, row.rect.height))
            )
        }
        return matches.sorted {
            isPreferred($0, over: $1, anchor: anchor)
        }.first?.component
    }

    static func numberedRows(
        from observations: [NumberedTextObservation]
    ) -> [NumberedRowEvidence] {
        var rows: [NumberedRowEvidence] = []

        for observation in observations {
            let digits = asciiDigits(in: observation.text)
            let runLength = longestConsecutiveRun(in: digits)
            if runLength >= 2 {
                rows.append(
                    NumberedRowEvidence(
                        rect: observation.rect,
                        consecutiveCount: runLength
                    )
                )
            }
        }

        let singleDigits = observations.compactMap {
            observation -> (value: Int, rect: CGRect)? in
            let digits = asciiDigits(in: observation.text)
            guard digits.count == 1,
                  observation.rect.width
                    <= observation.rect.height * 2.5 else {
                return nil
            }
            return (digits[0], observation.rect)
        }.sorted { $0.rect.minX < $1.rect.minX }

        for startIndex in singleDigits.indices {
            let seed = singleDigits[startIndex]
            var expectedValue = seed.value + 1
            var consecutiveCount = 1
            var rowRect = seed.rect
            var lastMatchedRect = seed.rect
            let nextStartIndex = singleDigits.index(after: startIndex)

            for nextIndex in nextStartIndex..<singleDigits.endIndex {
                let next = singleDigits[nextIndex]
                guard sharesBaseline(lastMatchedRect, next.rect),
                      hasReasonableHorizontalSpacing(
                        previous: lastMatchedRect,
                        next: next.rect
                      ),
                      next.value >= expectedValue else {
                    continue
                }
                guard next.value == expectedValue else { continue }
                consecutiveCount += 1
                expectedValue += 1
                rowRect = rowRect.union(next.rect)
                lastMatchedRect = next.rect
            }

            if consecutiveCount >= 2 {
                rows.append(
                    NumberedRowEvidence(
                        rect: rowRect,
                        consecutiveCount: consecutiveCount
                    )
                )
            }
        }
        return rows.sorted {
            if $0.consecutiveCount != $1.consecutiveCount {
                return $0.consecutiveCount > $1.consecutiveCount
            }
            return $0.rect.minX < $1.rect.minX
        }
    }

    private struct CandidateRowMatch {
        let component: FocusedCandidateComponent
        let row: NumberedRowEvidence
        let overlapFraction: CGFloat
    }

    static func numberedRows(in image: CGImage) -> [NumberedRowEvidence] {
        numberedRows(in: image, near: blueComponents(in: image))
    }

    static func numberedRows(
        in image: CGImage,
        near components: [FocusedCandidateComponent]
    ) -> [NumberedRowEvidence] {
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )
        let cacheKey = ValidationCacheKey(
            imageWidth: image.width,
            imageHeight: image.height,
            componentBands: components.map {
                VerticalComponentBand(
                    minY: Self.roundedPixel($0.rect.minY),
                    maxY: Self.roundedPixel($0.rect.maxY)
                )
            }.sorted {
                if $0.minY != $1.minY {
                    return $0.minY < $1.minY
                }
                return $0.maxY < $1.maxY
            }
        )
        if let cached = validationCache.value(for: cacheKey) {
            traceValidation(pass: "cache", rows: cached.count)
            return cached
        }

        let verticalBands = mergedBands(
            components.map { component in
                let padding = max(8, component.rect.height * 0.45)
                return CGRect(
                    x: 0,
                    y: component.rect.minY - padding,
                    width: CGFloat(image.width),
                    height: component.rect.height + padding * 2
                )
                .intersection(imageBounds)
            }
        )
        let compactBands = deduplicatedRegions(
            components.map { compactBand(for: $0, in: imageBounds) }
        )
        let prefersAccurateRecognition = components.count == 1
            && components[0].aspectRatio > naturalMaximumAspectRatio

        if !prefersAccurateRecognition {
            let fastRegions = deduplicatedRegions(
                [imageBounds] + verticalBands + compactBands
            )
            let fastRows = firstRecognizedRows(
                in: image,
                regions: fastRegions,
                level: .fast,
                languages: ["en-US"]
            )
            if !fastRows.isEmpty {
                validationCache.store(fastRows, for: cacheKey)
                traceValidation(pass: "fast", rows: fastRows.count)
                return fastRows
            }
        }

        let accurateRegions = deduplicatedRegions(
            verticalBands + compactBands + [imageBounds]
        )
        let accurateRows = firstRecognizedRows(
            in: image,
            regions: accurateRegions,
            level: .accurate,
            languages: ["zh-Hans", "en-US"]
        )
        validationCache.store(accurateRows, for: cacheKey)
        traceValidation(pass: "accurate", rows: accurateRows.count)
        return accurateRows
    }

    private static func firstRecognizedRows(
        in image: CGImage,
        regions: [CGRect],
        level: VNRequestTextRecognitionLevel,
        languages: [String]
    ) -> [NumberedRowEvidence] {
        for region in regions {
            guard let cropped = image.cropping(to: region) else { continue }
            let rows = numberedRows(
                from: numberedTextObservations(
                    in: cropped,
                    origin: region.origin,
                    level: level,
                    languages: languages
                )
            )
            if !rows.isEmpty {
                return rows
            }
        }
        return []
    }

    private static func numberedTextObservations(
        in image: CGImage,
        origin: CGPoint,
        level: VNRequestTextRecognitionLevel,
        languages: [String]
    ) -> [NumberedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.01

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let observations = (request.results ?? []).compactMap {
            observation -> NumberedTextObservation? in
            guard let text = observation.topCandidates(1).first?.string else {
                return nil
            }
            let box = observation.boundingBox
            return NumberedTextObservation(
                text: text,
                rect: CGRect(
                    x: origin.x + box.minX * width,
                    y: origin.y + (1 - box.maxY) * height,
                    width: box.width * width,
                    height: box.height * height
                )
            )
        }
        return observations
    }

    private static func compactBand(
        for component: FocusedCandidateComponent,
        in imageBounds: CGRect
    ) -> CGRect {
        let padding = max(8, component.rect.height * 0.45)
        let width = min(850, imageBounds.width)
        let horizontalPadding = max(32, component.rect.height * 0.7)
        let maximumX = max(0, imageBounds.width - width)
        let x = min(
            max(0, component.rect.minX - horizontalPadding),
            maximumX
        )
        return CGRect(
            x: x,
            y: component.rect.minY - padding,
            width: width,
            height: component.rect.height + padding * 2
        ).intersection(imageBounds)
    }

    private static func deduplicatedRegions(_ regions: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for region in regions where !region.isNull && !region.isEmpty {
            guard !result.contains(where: {
                abs($0.minX - region.minX) < 0.5
                    && abs($0.minY - region.minY) < 0.5
                    && abs($0.width - region.width) < 0.5
                    && abs($0.height - region.height) < 0.5
            }) else {
                continue
            }
            result.append(region)
        }
        return result
    }

    private static func traceValidation(pass: String, rows: Int) {
        guard ProcessInfo.processInfo.environment["GLINT_OCR_TRACE"] == "1" else {
            return
        }
        fputs(
            "Glint focus validation: pass=\(pass) rows=\(rows)\n",
            stderr
        )
    }

    private static func roundedPixel(_ value: CGFloat) -> Int {
        Int((value * 2).rounded())
    }

    private struct VerticalComponentBand: Hashable {
        let minY: Int
        let maxY: Int
    }

    private struct ValidationCacheKey: Hashable {
        let imageWidth: Int
        let imageHeight: Int
        let componentBands: [VerticalComponentBand]
    }

    private final class ValidationCache: @unchecked Sendable {
        private struct Entry {
            let rows: [NumberedRowEvidence]
            let expiration: ContinuousClock.Instant
        }

        private let lock = NSLock()
        private var entries: [ValidationCacheKey: Entry] = [:]

        func value(for key: ValidationCacheKey) -> [NumberedRowEvidence]? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key] else { return nil }
            guard ContinuousClock.now < entry.expiration else {
                entries.removeValue(forKey: key)
                return nil
            }
            return entry.rows
        }

        func store(
            _ rows: [NumberedRowEvidence],
            for key: ValidationCacheKey
        ) {
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= 24 {
                let now = ContinuousClock.now
                entries = entries.filter { now < $0.value.expiration }
                if entries.count >= 24 {
                    entries.removeAll(keepingCapacity: true)
                }
            }
            entries[key] = Entry(
                rows: rows,
                expiration: ContinuousClock.now.advanced(
                    by: .milliseconds(500)
                )
            )
        }
    }

    private static func asciiDigits(in text: String) -> [Int] {
        text.compactMap { character in
            guard let scalar = character.unicodeScalars.first,
                  scalar.value >= 48,
                  scalar.value <= 57 else {
                return nil
            }
            return Int(scalar.value - 48)
        }
    }

    private static func longestConsecutiveRun(in digits: [Int]) -> Int {
        guard !digits.isEmpty else { return 0 }
        var result = 1
        for startIndex in digits.indices {
            var expected = digits[startIndex] + 1
            var length = 1
            for nextIndex in digits.index(after: startIndex)..<digits.endIndex {
                guard digits[nextIndex] == expected else { continue }
                length += 1
                result = max(result, length)
                expected += 1
            }
        }
        return result
    }

    private static func verticallyOverlaps(
        _ component: CGRect,
        _ row: CGRect
    ) -> Bool {
        let overlapHeight = verticalOverlapHeight(component, row)
        let shorterHeight = min(component.height, row.height)
        return overlapHeight >= shorterHeight * 0.2
    }

    private static func verticalOverlapHeight(
        _ first: CGRect,
        _ second: CGRect
    ) -> CGFloat {
        max(0, min(first.maxY, second.maxY) - max(first.minY, second.minY))
    }

    private static func sharesBaseline(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.midY - second.midY)
            <= max(first.height, second.height) * 0.55
    }

    private static func hasReasonableHorizontalSpacing(
        previous: CGRect,
        next: CGRect
    ) -> Bool {
        let gap = next.minX - previous.maxX
        let tolerance = max(previous.height, next.height)
        return gap >= -tolerance * 0.25
            && gap <= tolerance * 12
    }

    private static func mergedBands(_ bands: [CGRect]) -> [CGRect] {
        let sorted = bands
            .filter { !$0.isNull && !$0.isEmpty }
            .sorted { $0.minY < $1.minY }
        var result: [CGRect] = []
        for band in sorted {
            guard let last = result.last else {
                result.append(band)
                continue
            }
            if band.minY <= last.maxY + 4 {
                result[result.count - 1] = last.union(band)
            } else {
                result.append(band)
            }
        }
        return result
    }

    private static func isPreferred(
        _ lhs: CandidateRowMatch,
        over rhs: CandidateRowMatch,
        anchor: CGPoint?
    ) -> Bool {
        if lhs.row.consecutiveCount != rhs.row.consecutiveCount {
            return lhs.row.consecutiveCount > rhs.row.consecutiveCount
        }
        if abs(lhs.overlapFraction - rhs.overlapFraction) > 0.1 {
            return lhs.overlapFraction > rhs.overlapFraction
        }
        if let anchor {
            let lhsDistance = distanceSquared(lhs.component.rect, anchor)
            let rhsDistance = distanceSquared(rhs.component.rect, anchor)
            if abs(lhsDistance - rhsDistance) > 1 {
                return lhsDistance < rhsDistance
            }
        }
        return lhs.component.area > rhs.component.area
    }

    private static func distanceSquared(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return dx * dx + dy * dy
    }

    private static func isAccentBlue(pixels: [UInt8], index: Int) -> Bool {
        let offset = index * 4
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        return blue > 120 && blue - red > 40 && blue - green > 15
    }
}
