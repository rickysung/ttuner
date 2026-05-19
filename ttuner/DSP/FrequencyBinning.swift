import Foundation

/// Log-scale rebinning from raw FFT bins to the display bin count.
///
/// Two regimes, switched per output bin based on whether one output bin spans
/// more than one raw FFT bin:
///   • multi-bin (high frequencies): pool the raw bins by `max` so spectral
///     peaks survive the downsample.
///   • sub-bin  (low frequencies): linearly interpolate between the two
///     surrounding raw bins. Without this, many output bins fall inside the
///     same raw bin and share its exact value — producing the long
///     low-frequency "staircase" stripes in the spectrogram.
struct LogBinner {
    let inputBins: Int
    let outputBins: Int
    let sampleRate: Float
    let minHz: Float
    let maxHz: Float

    /// For each output bin, the (lo, hi) raw-bin range to pool (multi-bin case).
    let ranges: [(Int, Int)]
    /// Fractional raw-bin index of each output bin's center frequency.
    let centers: [Float]

    init(inputBins: Int, outputBins: Int, sampleRate: Float, minHz: Float, maxHz: Float) {
        self.inputBins = inputBins
        self.outputBins = outputBins
        self.sampleRate = sampleRate
        self.minHz = max(1, minHz)
        self.maxHz = min(sampleRate / 2, maxHz)
        let binHz = sampleRate / Float(inputBins * 2)
        let logMin = log(self.minHz)
        let logMax = log(self.maxHz)
        var rs: [(Int, Int)] = []
        var cs: [Float] = []
        rs.reserveCapacity(outputBins)
        cs.reserveCapacity(outputBins)
        for o in 0..<outputBins {
            let f0n = Float(o) / Float(outputBins)
            let f1n = Float(o + 1) / Float(outputBins)
            let fcn = (Float(o) + 0.5) / Float(outputBins)
            let f0 = exp(logMin + (logMax - logMin) * f0n)
            let f1 = exp(logMin + (logMax - logMin) * f1n)
            let fc = exp(logMin + (logMax - logMin) * fcn)
            var lo = Int((f0 / binHz).rounded(.down))
            var hi = Int((f1 / binHz).rounded(.up))
            lo = max(0, min(inputBins - 1, lo))
            hi = max(lo, min(inputBins - 1, hi))
            rs.append((lo, hi))
            cs.append(fc / binHz)
        }
        self.ranges = rs
        self.centers = cs
    }

    func rebin(_ db: [Float], into out: inout [Float]) {
        precondition(out.count == outputBins)
        let maxIdx = inputBins - 1
        db.withUnsafeBufferPointer { p in
            for o in 0..<outputBins {
                let (lo, hi) = ranges[o]
                if hi > lo {
                    // High-frequency case: pool by max across the covered raw bins.
                    var m: Float = -.infinity
                    var i = lo
                    while i <= hi {
                        let v = p[i]
                        if v > m { m = v }
                        i += 1
                    }
                    out[o] = m
                } else {
                    // Low-frequency case: linearly interpolate between the two raw
                    // bins surrounding this output bin's center frequency.
                    let cf = centers[o]
                    let f0i = Int(cf.rounded(.down))
                    let frac = cf - Float(f0i)
                    let i0 = max(0, min(maxIdx, f0i))
                    let i1 = max(0, min(maxIdx, f0i + 1))
                    out[o] = (1 - frac) * p[i0] + frac * p[i1]
                }
            }
        }
    }
}
