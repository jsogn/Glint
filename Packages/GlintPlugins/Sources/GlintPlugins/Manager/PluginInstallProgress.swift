import Foundation

public struct PluginInstallProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case preparing
        case downloading
        case verifying
        case installing
    }

    public let fraction: Double
    public let phase: Phase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Int64?
    public let sourceHost: String?

    public init(
        fraction: Double,
        phase: Phase,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Int64? = nil,
        sourceHost: String? = nil
    ) {
        let validFraction = fraction.isFinite ? fraction : 0
        self.fraction = min(max(validFraction, 0), 1)
        self.phase = phase
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = max(0, totalBytes)
        self.bytesPerSecond = bytesPerSecond.map { max(0, $0) }
        self.sourceHost = sourceHost
    }
}

enum PluginInstallProgressRange {
    static let preparing = 0.0
    static let downloadingStart = 0.02
    static let downloadingEnd = 0.90
    static let verifyingStart = 0.90
    static let verifyingEnd = 0.97
    static let installingStart = 0.97
    static let installingEnd = 0.99

    static func mapped(
        _ value: Double,
        from start: Double,
        to end: Double
    ) -> Double {
        let clamped = min(max(value.isFinite ? value : 0, 0), 1)
        return start + (end - start) * clamped
    }
}

enum MLXDownloadProgress {
    static func fraction(
        completedBytes: Int64,
        currentFileBytes: Int64,
        totalBytes: Int64,
        completedFiles: Int,
        totalFiles: Int
    ) -> Double {
        let raw: Double
        if totalBytes > 0 {
            let current =
                max(0, completedBytes)
                + min(max(0, currentFileBytes), totalBytes)
            raw = min(1, Double(current) / Double(totalBytes))
        } else if totalFiles > 0 {
            raw = min(
                1,
                Double(max(0, completedFiles)) / Double(totalFiles)
            )
        } else {
            raw = 0
        }
        return PluginInstallProgressRange.mapped(
            raw,
            from: PluginInstallProgressRange.downloadingStart,
            to: PluginInstallProgressRange.downloadingEnd
        )
    }
}
