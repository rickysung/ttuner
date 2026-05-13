import Foundation
import Accelerate

/// Forward real-to-complex FFT producing magnitude-in-dB output.
/// Designed to be reused — heavyweight setup allocated once.
final class FFTProcessor {
    let n: Int
    let log2n: vDSP_Length
    private let setup: vDSP.FFT<DSPSplitComplex>
    private var window: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]
    private var db: [Float]
    private let halfN: Int

    init?(size n: Int) {
        let lg = vDSP_Length(log2(Double(n)).rounded(.up))
        guard 1 << lg == n, let setup = vDSP.FFT(log2n: lg, radix: .radix2, ofType: DSPSplitComplex.self)
        else { return nil }
        self.n = n
        self.halfN = n / 2
        self.log2n = lg
        self.setup = setup
        self.window = WindowFunction.hann(length: n)
        self.windowed = [Float](repeating: 0, count: n)
        self.realp = [Float](repeating: 0, count: halfN)
        self.imagp = [Float](repeating: 0, count: halfN)
        self.magnitudes = [Float](repeating: 0, count: halfN)
        self.db = [Float](repeating: 0, count: halfN)
    }

    /// Process `n` samples and return magnitude-in-dB (length n/2).
    func process(samples: UnsafePointer<Float>) -> [Float] {
        // Window
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // Pack interleaved real → split complex
        let halfN = self.halfN
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { typed in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(halfN))
                        setup.forward(input: split, output: &split)
                        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        // Convert to dB: 10·log10(mag + eps); reference 1.0; use "amplitude" flag = 0 → power
        var one: Float = 1.0
        vDSP_vdbcon(magnitudes, 1, &one, &db, 1, vDSP_Length(halfN), 0)
        // Half of vDSP_zvmags returns magnitude squared scaled by 4N (R2C convention) — we don't
        // need absolute calibration here, normalization happens in the colormap mapping.
        return db
    }
}
