import Foundation
import GlintPlugins

enum InstallProgressFormatting {
    static func description(
        for progress: PluginInstallProgress
    ) -> String {
        switch progress.phase {
        case .preparing:
            if let sourceHost = progress.sourceHost {
                return "正在连接 \(sourceHost)…"
            }
            return "正在准备下载…"
        case .downloading:
            var parts = ["正在下载"]
            if progress.totalBytes > 0 {
                parts.append(
                    "\(formatBytes(progress.completedBytes)) / "
                        + formatBytes(progress.totalBytes)
                )
            }
            if let speed = progress.bytesPerSecond, speed > 0 {
                parts.append("\(formatBytes(speed))/s")
            }
            return parts.joined(separator: " · ")
        case .verifying:
            return "正在校验模型…"
        case .installing:
            return "正在安装模型…"
        }
    }

    private static func formatBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: count,
            countStyle: .file
        )
    }
}
