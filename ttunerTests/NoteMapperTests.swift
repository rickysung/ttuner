import XCTest
@testable import ttuner

final class NoteMapperTests: XCTestCase {

    func testA4ReferenceMapsToA4() {
        let r = NoteMapper.map(f0: 440, referenceA: 440, transpose: 0, display: .sharp)!
        XCTAssertEqual(r.name, "A")
        XCTAssertEqual(r.octave, 4)
        XCTAssertEqual(r.midi, 69)
        XCTAssertEqual(r.cents, 0, accuracy: 0.01)
    }

    func testReferenceA442ShiftsCents() {
        let r = NoteMapper.map(f0: 440, referenceA: 442, transpose: 0, display: .sharp)!
        XCTAssertEqual(r.name, "A")
        XCTAssertEqual(r.octave, 4)
        // 440 vs 442 ref → ~ -8 cents
        XCTAssertEqual(r.cents, -7.85, accuracy: 0.2)
    }

    func testTransposeShiftsLabel() {
        // Concert C5 (~523.25Hz) viewed through a B♭ transpose should read as "D5".
        let r = NoteMapper.map(f0: 523.25, referenceA: 440, transpose: -2, display: .sharp)!
        XCTAssertEqual(r.name, "D")
        XCTAssertEqual(r.octave, 5)
    }

    func testFlatDisplayPreservesEnharmonics() {
        // F#4 ≈ 369.99Hz
        let sharp = NoteMapper.map(f0: 369.99, referenceA: 440, transpose: 0, display: .sharp)!
        let flat  = NoteMapper.map(f0: 369.99, referenceA: 440, transpose: 0, display: .flat)!
        XCTAssertEqual(sharp.name, "F#")
        XCTAssertEqual(flat.name, "Gb")
    }
}
