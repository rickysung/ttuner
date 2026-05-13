import Foundation

/// Log-scale rebinning from raw FFT bins to the display bin count.
/// Each output bin pools its source bins using `max` so transients survive compression.
struct LogBinner {
    let inputBins: Int
    let outputBins: Int
    let sampleRate: Float
    let minHz: Float
    let maxHz: Float

    /// For each output bin, the (lo, hi) raw-bin range to pool.
    let ranges: [(Int, Int)]

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
        rs.reserveCapacity(outputBins)
        for o in 0..<outputBins {
            let f0n = Float(o) / Float(outputBins)
            let f1n = Float(o + 1) / Float(outputBins)
            let f0 = exp(logMin + (logMax - logMin) * f0n)
            let f1 = exp(logMin + (logMax - logMin) * f1n)
            var lo = Int((f0 / binHz).rounded(.down))
            var hi = Int((f1 / binHz).rounded(.up))
            lo = max(0, min(inputBins - 1, lo))
            hi = max(lo, min(inputBins - 1, hi))
            rs.append((lo, hi))
        }
        self.ranges = rs
    }

    func rebin(_ db: [Float], into out: inout [Float]) {
        precondition(out.count == outputBins)
        db.withUnsafeBufferPointer { p in
            for o in 0..<outputBins {
                let (lo, hi) = ranges[o]
                var m: Float = -.infinity
                var i = lo
                while i <= hi {
                    let v = p[i]
                    if v > m { m = v }
                    i += 1
                }
                out[o] = m
            }
        }
    }
}
