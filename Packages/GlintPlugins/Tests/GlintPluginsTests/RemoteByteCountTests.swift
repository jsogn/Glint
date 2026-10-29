import XCTest
@testable import GlintPlugins

final class RemoteByteCountTests: XCTestCase {
    func testByteSumRejectsOverflowAndNegativeValues() {
        XCTAssertNil(
            RemoteByteCount.checkedSum([Int64.max, 1])
        )
        XCTAssertNil(
            RemoteByteCount.checkedSum([100, -1])
        )
        XCTAssertEqual(
            RemoteByteCount.checkedSum([100, 200]),
            300
        )
    }

    func testByteMultiplicationRejectsOverflow() {
        XCTAssertNil(
            RemoteByteCount.checkedProduct(Int64.max, 2)
        )
        XCTAssertNil(
            RemoteByteCount.checkedProduct(-1, 2)
        )
        XCTAssertEqual(
            RemoteByteCount.checkedProduct(100, 2),
            200
        )
    }
}
