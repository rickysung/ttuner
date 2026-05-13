import XCTest
@testable import ttuner

final class FFTProcessorTests: XCTestCase {

    func testSineWavePeakAtExpectedBin() throws {
        let n = 4096
        let sampleRate: Float = 48_000
        let targetHz: Float = 440  // A4
        guard let fft = FFTProcessor(size: n) else { XCTFail(); return }
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = sin(2 * .pi * targetHz * Float(i) / sampleRate)
        }
        let db = samples.withUnsafeBufferPointer { fft.process(samples: $0.baseAddress!) }
        // Bin where the energy should peak.
        let expectedBin = Int(round(Double(targetHz) * Double(n) / Double(sampleRate)))
        let maxIdx = db.enumerated().max(by: { $0.element < $1.element })!.offset
        XCTAssertEqual(maxIdx, expectedBin, accuracy: 1,
                       "FFT peak was at \(maxIdx) but expected near \(expectedBin)")
    }

    func testZeroInputProducesNoSpurs() throws {
        let n = 2048
        guard let fft = FFTProcessor(size: n) else { XCTFail(); return }
        let samples = [Float](repeating: 0, count: n)
        let db = samples.withUnsafeBufferPointer { fft.process(samples: $0.baseAddress!) }
        XCTAssertEqual(db.count, n / 2)
        // All bins should be near -inf (very large negative dB).
        XCTAssertTrue(db.allSatisfy { $0 < -100 })
    }
}
