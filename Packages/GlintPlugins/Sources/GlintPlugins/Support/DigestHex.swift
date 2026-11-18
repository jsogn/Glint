import CryptoKit
import Foundation

enum DigestHex {
    static func string<Bytes: Sequence>(for bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(fileURL: URL) throws -> String {
        let data = try Data(
            contentsOf: fileURL,
            options: [.mappedIfSafe]
        )
        return string(for: SHA256.hash(data: data))
    }
}
