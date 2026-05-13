import XCTest
@testable import ttuner

final class WAVWriterTests: XCTestCase {

    func testRoundTripHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttuner-wav-test.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [Float] = (0..<4800).map { sin(2 * .pi * 440 * Float($0) / 48_000) }
        try WAVWriter.write(samples: samples, sampleRate: 48_000, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 44)
        let riff = String(data: data.prefix(4), encoding: .ascii)
        XCTAssertEqual(riff, "RIFF")
        let wave = String(data: data[8..<12], encoding: .ascii)
        XCTAssertEqual(wave, "WAVE")
        let fmt  = String(data: data[12..<16], encoding: .ascii)
        XCTAssertEqual(fmt, "fmt ")
        let dataMagic = String(data: data[36..<40], encoding: .ascii)
        XCTAssertEqual(dataMagic, "data")
    }
}
