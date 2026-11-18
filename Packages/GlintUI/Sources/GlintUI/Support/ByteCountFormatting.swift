import Foundation

enum ByteCountFormatting {
    static func file(_ count: Int64) -> String {
        format(count, style: .file)
    }

    static func memory(_ count: Int64) -> String {
        format(count, style: .memory)
    }

    private static func format(
        _ count: Int64,
        style: ByteCountFormatter.CountStyle
    ) -> String {
        ByteCountFormatter.string(
            fromByteCount: count,
            countStyle: style
        )
    }
}
