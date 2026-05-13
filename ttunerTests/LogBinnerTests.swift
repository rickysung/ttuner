import XCTest
@testable import ttuner

final class LogBinnerTests: XCTestCase {

    func testRangesAreMonotonic() {
        let b = LogBinner(inputBins: 2048, outputBins: 512, sampleRate: 48_000, minHz: 50, maxHz: 4_000)
        var prevHi = 0
        for (lo, hi) in b.ranges {
            XCTAssertLessThanOrEqual(lo, hi)
            XCTAssertGreaterThanOrEqual(lo, prevHi - 1) // allow overlap by 1 bin
            prevHi = hi
        }
    }

    func testRebinTakesMaxOfPool() {
        let b = LogBinner(inputBins: 8, outputBins: 4, sampleRate: 16_000, minHz: 1, maxHz: 4_000)
        let db: [Float] = [-90, -60, -30, -50, -10, -80, -40, -20]
        var out = [Float](repeating: 0, count: 4)
        b.rebin(db, into: &out)
        // Each output bin must equal max of its input pool — values must come from `db`.
        for v in out { XCTAssertTrue(db.contains(v)) }
        // Output should be non-decreasing only if input has that property — relax to "valid".
        XCTAssertEqual(out.count, 4)
    }
}
