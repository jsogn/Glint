import Foundation

public enum RimeSupportPaths {
    public static func supportDirectory(
        applicationSupportDirectory: URL
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Glint", isDirectory: true)
            .appendingPathComponent(
                "RimeCandidateSupport",
                isDirectory: true
            )
    }

    public static var defaultSupportDirectory: URL {
        supportDirectory(
            applicationSupportDirectory:
                FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
        )
    }

    public static func socketPath(in supportDirectory: URL) -> String {
        supportDirectory.appendingPathComponent("bridge.sock").path
    }
}
