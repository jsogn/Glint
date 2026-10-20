import CoreGraphics
import Foundation

struct OCRCandidateSignature: Sendable {
    private static let sampleWidth = 48
    private static let sampleHeight = 24

    private let imageWidth: Int
    private let imageHeight: Int
    private let luma: [UInt8]

    init?(image: CGImage) {
        guard image.width > 0, image.height > 0 else { return nil }
        imageWidth = image.width
        imageHeight = image.height

        var pixels = [UInt8](
            repeating: 0,
            count: Self.sampleWidth * Self.sampleHeight
        )
        guard let context = CGContext(
            data: &pixels,
            width: Self.sampleWidth,
            height: Self.sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: Self.sampleWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: Self.sampleWidth,
                height: Self.sampleHeight
            )
        )
        luma = pixels
    }

    func similarityDistance(to other: OCRCandidateSignature) -> Double? {
        guard imageWidth == other.imageWidth,
              imageHeight == other.imageHeight,
              luma.count == other.luma.count else {
            return nil
        }

        var totalDifference = 0
        var maximumDifference = 0
        var differingPixels = 0
        for index in luma.indices {
            let difference = abs(Int(luma[index]) - Int(other.luma[index]))
            totalDifference += difference
            maximumDifference = max(maximumDifference, difference)
            if difference > 8 {
                differingPixels += 1
            }
        }
        let meanDifference = Double(totalDifference) / Double(max(1, luma.count))
        let differingRatio = Double(differingPixels) / Double(max(1, luma.count))
        guard maximumDifference <= 24,
              meanDifference <= 0.9,
              differingRatio <= 0.015 else {
            return nil
        }
        return meanDifference
    }
}

final class OCRResultCache: @unchecked Sendable {
    struct Hit {
        let text: String
        let confidence: Float
    }

    private struct Entry {
        let signature: OCRCandidateSignature
        let text: String
        let confidence: Float
        var lastAccess: TimeInterval
    }

    private let lock = NSLock()
    private let capacity: Int
    private let ttl: TimeInterval
    private var entries: [Entry] = []
    private var lastHitValue = false

    init(capacity: Int = 64, ttl: TimeInterval = 3) {
        self.capacity = capacity
        self.ttl = ttl
    }

    var lastHit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastHitValue
    }

    func lookup(_ signature: OCRCandidateSignature) -> Hit? {
        lock.lock()
        defer { lock.unlock() }

        let now = Date.timeIntervalSinceReferenceDate
        entries.removeAll { now - $0.lastAccess > ttl }

        var bestIndex: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for index in entries.indices {
            guard let distance = signature.similarityDistance(
                to: entries[index].signature
            ), distance < bestDistance else {
                continue
            }
            bestDistance = distance
            bestIndex = index
        }
        guard let bestIndex else {
            lastHitValue = false
            return nil
        }

        entries[bestIndex].lastAccess = now
        let entry = entries.remove(at: bestIndex)
        entries.append(entry)
        lastHitValue = true
        return Hit(text: entry.text, confidence: entry.confidence)
    }

    func store(
        signature: OCRCandidateSignature,
        text: String,
        confidence: Float
    ) {
        lock.lock()
        defer { lock.unlock() }
        lastHitValue = false

        let now = Date.timeIntervalSinceReferenceDate
        entries.removeAll { now - $0.lastAccess > ttl }
        entries.append(
            Entry(
                signature: signature,
                text: text,
                confidence: confidence,
                lastAccess: now
            )
        )
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        lastHitValue = false
    }
}
