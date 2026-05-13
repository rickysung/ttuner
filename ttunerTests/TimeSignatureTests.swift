import XCTest
@testable import ttuner

final class TimeSignatureTests: XCTestCase {

    func testFourFourDefaultAccent() {
        let p = TimeSignature.defaultAccentPattern(for: .fourFour)
        XCTAssertEqual(p.count, 4)
        XCTAssertEqual(p[0], .accent)
    }

    func testThreeFourDefaultAccent() {
        let p = TimeSignature.defaultAccentPattern(for: .threeFour)
        XCTAssertEqual(p, [.accent, .normal, .normal])
    }

    func testSixEightCompound() {
        let p = TimeSignature.defaultAccentPattern(for: .sixEight)
        XCTAssertEqual(p.count, 6)
        XCTAssertEqual(p[0], .accent)
        XCTAssertEqual(p[3], .normal)
    }
}
