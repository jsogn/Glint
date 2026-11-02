import Foundation
import Observation

public struct AppRelease: Equatable, Sendable {
    public let version: String
    public let pageURL: URL

    public init(version: String, pageURL: URL) {
        self.version = version
        self.pageURL = pageURL
    }
}

public enum AppUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(AppRelease)
    case failed
}

public struct AppUpdateOverviewPrompt: Equatable, Sendable {
    public let releaseVersion: String
    public let currentVersion: String
    public let destinationURL: URL

    public init(
        releaseVersion: String,
        currentVersion: String,
        destinationURL: URL
    ) {
        self.releaseVersion = releaseVersion
        self.currentVersion = currentVersion
        self.destinationURL = destinationURL
    }
}

public struct AppUpdateMenuPresentation: Equatable, Sendable {
    public let title: String
    public let isEnabled: Bool
    public let destinationURL: URL?

    public init(
        title: String,
        isEnabled: Bool,
        destinationURL: URL?
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.destinationURL = destinationURL
    }
}

public struct AppUpdateResultPresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let informativeText: String?
    public let primaryButtonTitle: String
    public let secondaryButtonTitle: String?
    public let destinationURL: URL?

    public init(
        title: String,
        message: String,
        informativeText: String?,
        primaryButtonTitle: String,
        secondaryButtonTitle: String?,
        destinationURL: URL?
    ) {
        self.title = title
        self.message = message
        self.informativeText = informativeText
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryButtonTitle = secondaryButtonTitle
        self.destinationURL = destinationURL
    }
}

extension AppUpdateStatus {
    public var menuPresentation: AppUpdateMenuPresentation {
        switch self {
        case .idle:
            AppUpdateMenuPresentation(
                title: "检查更新…",
                isEnabled: true,
                destinationURL: nil
            )
        case .checking:
            AppUpdateMenuPresentation(
                title: "正在检查…",
                isEnabled: false,
                destinationURL: nil
            )
        case .upToDate:
            AppUpdateMenuPresentation(
                title: "检查更新…",
                isEnabled: true,
                destinationURL: nil
            )
        case .available(let release):
            AppUpdateMenuPresentation(
                title: "点击前往更新",
                isEnabled: true,
                destinationURL: release.pageURL
            )
        case .failed:
            AppUpdateMenuPresentation(
                title: "检查更新（暂时不可用）",
                isEnabled: true,
                destinationURL: nil
            )
        }
    }

    public var resultPresentation: AppUpdateResultPresentation? {
        switch self {
        case .idle, .checking:
            nil
        case .upToDate:
            AppUpdateResultPresentation(
                title: "软件更新",
                message: "您使用的就是最新版！",
                informativeText: "当前安装的 Glint 已是最新版本。",
                primaryButtonTitle: "好",
                secondaryButtonTitle: nil,
                destinationURL: nil
            )
        case .available(let release):
            AppUpdateResultPresentation(
                title: "软件更新",
                message:
                    "发现新版本 \(AppUpdateVersion.displayVersion(release.version))",
                informativeText: "请前往 GitHub 下载并安装最新版。",
                primaryButtonTitle: "前往下载",
                secondaryButtonTitle: "取消",
                destinationURL: release.pageURL
            )
        case .failed:
            AppUpdateResultPresentation(
                title: "软件更新",
                message: "暂时无法检查更新",
                informativeText: "请检查网络连接后重试。",
                primaryButtonTitle: "好",
                secondaryButtonTitle: nil,
                destinationURL: nil
            )
        }
    }
}

@MainActor
@Observable
public final class AppUpdateModel {
    private enum PersistenceKey {
        static let lastAttemptAt = "glint.appUpdate.lastAttemptAt"
        static let cachedStatus = "glint.appUpdate.cachedStatus"
        static let cachedReleaseVersion =
            "glint.appUpdate.cachedReleaseVersion"
        static let cachedReleasePageURL =
            "glint.appUpdate.cachedReleasePageURL"
    }

    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    typealias ReleaseLoader =
        @Sendable () async throws -> AppRelease

    @ObservationIgnored
    private let currentVersion: String
    @ObservationIgnored
    private let defaults: UserDefaults?
    @ObservationIgnored
    private let now: @Sendable () -> Date
    @ObservationIgnored
    private let fetchLatestRelease: ReleaseLoader

    public private(set) var status = AppUpdateStatus.idle
    public private(set) var isChecking = false

    public convenience init() {
        let version =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "未知"
        self.init(
            currentVersion: version,
            defaults: .standard,
            fetchLatestRelease: {
                try await GitHubReleaseClient(
                    currentVersion: version
                ).latestRelease()
            }
        )
    }

    init(
        currentVersion: String,
        initialStatus: AppUpdateStatus = .idle,
        defaults: UserDefaults? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        fetchLatestRelease: @escaping ReleaseLoader
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.now = now
        self.fetchLatestRelease = fetchLatestRelease
        if initialStatus == .idle, let defaults {
            self.status =
                Self.restoredStatus(
                    from: defaults,
                    currentVersion: currentVersion
                )
                ?? .idle
        } else {
            self.status = initialStatus
        }
    }

    public var overviewPrompt: AppUpdateOverviewPrompt? {
        guard case .available(let release) = status else {
            return nil
        }
        return AppUpdateOverviewPrompt(
            releaseVersion:
                AppUpdateVersion.displayVersion(release.version),
            currentVersion:
                AppUpdateVersion.displayVersion(currentVersion),
            destinationURL: release.pageURL
        )
    }

    public func checkForUpdates() async {
        guard !isChecking else { return }
        await runCheck(reportFailure: true, at: now())
    }

    public func automaticallyCheckForUpdates() async {
        guard !isChecking else { return }
        let checkDate = now()
        guard shouldAutomaticallyCheck(at: checkDate) else { return }
        await runCheck(reportFailure: false, at: checkDate)
    }

    private func runCheck(
        reportFailure: Bool,
        at checkDate: Date
    ) async {
        guard !isChecking else { return }
        isChecking = true
        if reportFailure {
            status = .checking
        }
        defer { isChecking = false }

        guard AppUpdateVersion.isValid(currentVersion) else {
            persistAttempt(at: checkDate)
            if reportFailure {
                status = .failed
            }
            return
        }
        do {
            let release = try await fetchLatestRelease()
            guard AppUpdateVersion.isValid(release.version) else {
                persistAttempt(at: checkDate)
                if reportFailure {
                    status = .failed
                }
                return
            }
            let result: AppUpdateStatus =
                AppUpdateVersion.isNewer(
                    release.version,
                    than: currentVersion
                )
                ? .available(release)
                : .upToDate
            status = result
            persist(result, at: checkDate)
        } catch {
            persistAttempt(at: checkDate)
            if reportFailure {
                status = .failed
            } else {
                status = restoredCachedStatus ?? .idle
            }
        }
    }

    private func shouldAutomaticallyCheck(at date: Date) -> Bool {
        guard
            let defaults,
            let lastAttempt =
                defaults.object(
                    forKey: PersistenceKey.lastAttemptAt
                ) as? Date
        else {
            return true
        }
        return date.timeIntervalSince(lastAttempt)
            >= Self.automaticCheckInterval
    }

    private var restoredCachedStatus: AppUpdateStatus? {
        guard let defaults else { return nil }
        return Self.restoredStatus(
            from: defaults,
            currentVersion: currentVersion
        )
    }

    private func persist(
        _ updateStatus: AppUpdateStatus,
        at date: Date
    ) {
        guard let defaults else { return }
        defaults.set(date, forKey: PersistenceKey.lastAttemptAt)
        switch updateStatus {
        case .available(let release):
            defaults.set(
                "available",
                forKey: PersistenceKey.cachedStatus
            )
            defaults.set(
                release.version,
                forKey: PersistenceKey.cachedReleaseVersion
            )
            defaults.set(
                release.pageURL.absoluteString,
                forKey: PersistenceKey.cachedReleasePageURL
            )
        case .upToDate:
            defaults.set(
                "upToDate",
                forKey: PersistenceKey.cachedStatus
            )
            defaults.removeObject(
                forKey: PersistenceKey.cachedReleaseVersion
            )
            defaults.removeObject(
                forKey: PersistenceKey.cachedReleasePageURL
            )
        case .idle, .checking, .failed:
            break
        }
    }

    private func persistAttempt(at date: Date) {
        defaults?.set(
            date,
            forKey: PersistenceKey.lastAttemptAt
        )
    }

    private static func restoredStatus(
        from defaults: UserDefaults,
        currentVersion: String
    ) -> AppUpdateStatus? {
        switch defaults.string(forKey: PersistenceKey.cachedStatus) {
        case "available":
            guard
                let releaseVersion = defaults.string(
                    forKey: PersistenceKey.cachedReleaseVersion
                ),
                let pageURLString = defaults.string(
                    forKey: PersistenceKey.cachedReleasePageURL
                ),
                let pageURL = URL(string: pageURLString),
                AppUpdateVersion.isValid(releaseVersion),
                AppUpdateVersion.isNewer(
                    releaseVersion,
                    than: currentVersion
                )
            else {
                return nil
            }
            return .available(
                AppRelease(
                    version: releaseVersion,
                    pageURL: pageURL
                )
            )
        case "upToDate":
            return .upToDate
        default:
            return nil
        }
    }
}
