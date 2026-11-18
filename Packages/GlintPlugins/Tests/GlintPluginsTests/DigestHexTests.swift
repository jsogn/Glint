import CryptoKit
import Foundation
import XCTest

@testable import GlintPlugins

final class DigestHexTests: XCTestCase {
    func testFormatsSHA256DigestAsLowercaseHex() {
        let digest = SHA256.hash(data: Data("abc".utf8))

        XCTAssertEqual(
            DigestHex.string(for: digest),
            "ba7816bf8f01cfea414140de5dae2223"
                + "b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            DigestHex.string(for: digest.prefix(4)),
            "ba7816bf"
        )
    }
}
