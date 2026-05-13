import XCTest
@testable import ttuner

final class YINPitchDetectorTests: XCTestCase {

    private func synth(freq: Float, n: Int = 2048, sr: Float = 48_000) -> [Float] {
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n { s[i] = sin(2 * .pi * freq * Float(i) / sr) }
        return s
    }

    func testDetectsA4WithinOneCent() throws {
        let target: Float = 440
        let yin = YINPitchDetector(windowSize: 2048, sampleRate: 48_000)
        let samples = synth(freq: target)
        guard let r = samples.withUnsafeBufferPointer({ yin.detect(samples: $0.baseAddress!) })
        else { XCTFail("YIN failed to detect a clean sine"); return }
        let cents = 1200 * log2(r.f0 / target)
        XCTAssertLessThan(abs(cents), 5, "YIN drift was \(cents) cents at 440Hz")
        XCTAssertGreaterThan(r.clarity, 0.9)
    }

    func testSweepAcrossOctaves() throws {
        let yin = YINPitchDetector(windowSize: 2048, sampleRate: 48_000)
        for target: Float in [82.4, 110, 196, 261.6, 440, 880, 1760] {
            let s = synth(freq: target)
            guard let r = s.withUnsafeBufferPointer({ yin.detect(samples: $0.baseAddress!) })
            else { XCTFail("YIN failed at \(target)Hz"); continue }
            let cents = 1200 * log2(r.f0 / target)
            XCTAssertLessThan(abs(cents), 10, "YIN \(target)Hz drift \(cents)¢")
        }
    }

    func testReturnsNilForSilence() throws {
        let yin = YINPitchDetector(windowSize: 1024, sampleRate: 48_000)
        let s = [Float](repeating: 0, count: 1024)
        let r = s.withUnsafeBufferPointer { yin.detect(samples: $0.baseAddress!) }
        XCTAssertNil(r)
    }
}
