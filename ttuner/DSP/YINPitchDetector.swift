import Foundation

/// YIN pitch detection in the time domain.
/// See: de Cheveigné & Kawahara (2002), "YIN, a fundamental frequency estimator for speech and music".
final class YINPitchDetector {
    let windowSize: Int
    let sampleRate: Float
    let threshold: Float
    let tauMinSamples: Int
    let tauMaxSamples: Int

    private var diff: [Float]
    private var cmnd: [Float]

    init(windowSize: Int = 2048,
         sampleRate: Float,
         threshold: Float = 0.15,
         minFrequency: Float = 40,
         maxFrequency: Float = 2400) {
        self.windowSize = windowSize
        self.sampleRate = sampleRate
        self.threshold = threshold
        self.tauMinSamples = max(2, Int(sampleRate / maxFrequency))
        self.tauMaxSamples = min(windowSize / 2, Int(sampleRate / minFrequency))
        self.diff = [Float](repeating: 0, count: tauMaxSamples + 1)
        self.cmnd = [Float](repeating: 1, count: tauMaxSamples + 1)
    }

    struct Result {
        let f0: Float
        let clarity: Float
    }

    func detect(samples: UnsafePointer<Float>) -> Result? {
        let N = windowSize
        let tauMax = tauMaxSamples

        // Step 1: difference function d[tau]
        for tau in 1...tauMax {
            var sum: Float = 0
            let limit = N - tau
            var j = 0
            while j < limit {
                let dval = samples[j] - samples[j + tau]
                sum += dval * dval
                j += 1
            }
            diff[tau] = sum
        }

        // Step 2: cumulative mean normalized difference
        cmnd[0] = 1
        var runningSum: Float = 0
        for tau in 1...tauMax {
            runningSum += diff[tau]
            if runningSum <= 0 {
                cmnd[tau] = 1
            } else {
                cmnd[tau] = diff[tau] * Float(tau) / runningSum
            }
        }

        // Step 3: absolute threshold + first dip
        var tauEstimate = -1
        var tau = tauMinSamples
        while tau <= tauMax {
            if cmnd[tau] < threshold {
                var t = tau
                while t + 1 <= tauMax && cmnd[t + 1] < cmnd[t] {
                    t += 1
                }
                tauEstimate = t
                break
            }
            tau += 1
        }
        if tauEstimate < 0 { return nil }

        // Step 4: parabolic interpolation around the minimum
        let x0 = max(tauEstimate - 1, 0)
        let x2 = min(tauEstimate + 1, tauMax)
        let s0 = cmnd[x0]
        let s1 = cmnd[tauEstimate]
        let s2 = cmnd[x2]
        let denom = 2 * (2 * s1 - s2 - s0)
        let betterTau: Float
        if denom != 0 {
            betterTau = Float(tauEstimate) + (s2 - s0) / denom
        } else {
            betterTau = Float(tauEstimate)
        }
        if betterTau <= 0 { return nil }
        let f0 = sampleRate / betterTau
        let clarity = max(0, min(1, 1 - cmnd[tauEstimate]))
        return Result(f0: f0, clarity: clarity)
    }
}
