import Foundation

struct PluginCatalogPayload: Decodable {
    let plugins: [PluginManifest]
}

struct HuggingFaceSnapshot: Decodable {
    struct Sibling: Decodable {
        struct LFS: Decodable {
            let sha256: String?
        }

        let rfilename: String
        let size: Int64?
        let lfs: LFS?
    }

    let siblings: [Sibling]
}

enum MLXDownloadSource {
    case modelScope(repository: String, endpoint: URL)
    case huggingFace(
        repository: String,
        revision: String,
        endpoint: URL
    )

    var host: String? {
        switch self {
        case let .modelScope(_, endpoint),
            let .huggingFace(_, _, endpoint):
            return endpoint.host
        }
    }
}

struct SnapshotDownloadFile {
    let path: String
    let size: Int64
    let sha256: String?
    let revision: String?
}

struct ModelScopeSnapshot: Decodable {
    struct Payload: Decodable {
        let files: [File]

        private enum CodingKeys: String, CodingKey {
            case files = "Files"
        }
    }

    struct File: Decodable {
        let path: String
        let size: Int64
        let sha256: String?
        let revision: String?
        let type: String

        private enum CodingKeys: String, CodingKey {
            case path = "Path"
            case size = "Size"
            case sha256 = "Sha256"
            case revision = "Revision"
            case type = "Type"
        }
    }

    let data: Payload

    private enum CodingKeys: String, CodingKey {
        case data = "Data"
    }
}

struct DownloadedSnapshotFile {
    let destination: URL
    let actualBytes: Int64
    let expectedSHA256: String?
}

final class InstallProgressReporter: @unchecked Sendable {
    private static let minimumFractionDelta = 0.001
    private static let maximumUpdateInterval: UInt64 = 200_000_000

    private let progress: (@Sendable (PluginInstallProgress) -> Void)?
    private let lock = NSLock()
    private var lastFraction = -1.0
    private var lastPhase: PluginInstallProgress.Phase?
    private var lastSourceHost: String?
    private var lastEmission: UInt64 = 0

    init(_ progress: (@Sendable (PluginInstallProgress) -> Void)?) {
        self.progress = progress
    }

    func reset() {
        lock.lock()
        lastFraction = -1
        lastPhase = nil
        lastSourceHost = nil
        lastEmission = 0
        lock.unlock()
    }

    func emit(
        _ value: PluginInstallProgress,
        force: Bool = false
    ) {
        guard let progress else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let phaseChanged = value.phase != lastPhase
        let sourceChanged = value.sourceHost != lastSourceHost
        let fractionAdvanced =
            value.fraction >= lastFraction + Self.minimumFractionDelta
        let intervalElapsed =
            now >= lastEmission
            && now - lastEmission >= Self.maximumUpdateInterval
        let shouldEmit =
            force
            || phaseChanged
            || sourceChanged
            || fractionAdvanced
            || (intervalElapsed && value.fraction >= lastFraction)
        guard shouldEmit else {
            lock.unlock()
            return
        }
        lastFraction = value.fraction
        lastPhase = value.phase
        lastSourceHost = value.sourceHost
        lastEmission = now
        lock.unlock()
        progress(value)
    }
}
