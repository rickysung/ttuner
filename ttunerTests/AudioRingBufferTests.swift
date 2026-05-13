import XCTest
@testable import ttuner

final class AudioRingBufferTests: XCTestCase {

    func testSequentialWriteRead() throws {
        let buf = AudioRingBuffer(capacitySamples: 16)
        var input: [Float] = [1, 2, 3, 4, 5]
        input.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(buf.availableToRead, 5)
        var out = [Float](repeating: 0, count: 5)
        let n = out.withUnsafeMutableBufferPointer { buf.read(into: $0.baseAddress!, maxCount: 5) }
        XCTAssertEqual(n, 5)
        XCTAssertEqual(out, [1, 2, 3, 4, 5])
        XCTAssertEqual(buf.availableToRead, 0)
    }

    func testOverflowDropsOldestSamples() throws {
        let buf = AudioRingBuffer(capacitySamples: 8)   // round up to 8
        var input = (0..<12).map { Float($0) }
        input.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: $0.count) }
        // The buffer can only hold capacity samples (8) — last 8 must remain (samples 4..11).
        XCTAssertEqual(buf.availableToRead, 8)
        var out = [Float](repeating: 0, count: 8)
        let n = out.withUnsafeMutableBufferPointer { buf.read(into: $0.baseAddress!, maxCount: 8) }
        XCTAssertEqual(n, 8)
        XCTAssertEqual(out, [4, 5, 6, 7, 8, 9, 10, 11])
    }

    func testPeekDoesNotConsume() throws {
        let buf = AudioRingBuffer(capacitySamples: 16)
        let vals: [Float] = [10, 20, 30, 40]
        vals.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: $0.count) }
        var p = [Float](repeating: 0, count: 4)
        _ = p.withUnsafeMutableBufferPointer { buf.peekRecent(4, into: $0.baseAddress!) }
        XCTAssertEqual(p, vals)
        XCTAssertEqual(buf.availableToRead, 4, "Peek must not consume")
    }
}
