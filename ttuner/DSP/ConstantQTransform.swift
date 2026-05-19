import Foundation
import Accelerate

/// Constant-Q transform with logarithmically-spaced (musical) output bins.
///
/// Following Brown (1992) and the efficient sparse-kernel variant of
/// Schörkhuber & Klapuri (2010): one large FFT per hop, then a sparse
/// matrix-vector product with precomputed per-band spectral kernels.
///
/// Each kernel is a Hann-windowed complex exponential of length
/// `Nk = Q * sampleRate / fk`, padded to `fftSize`. Bands at low frequencies
/// use long windows (good frequency resolution), bands at high frequencies
/// use short windows (good time resolution) — adaptive in a way no single
/// FFT window can be.
final class ConstantQTransform {
    let fftSize: Int
    let sampleRate: Float
    let minHz: Float
    let maxHz: Float
    let totalBins: Int

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    private var sigReal: [Float]
    private var sigImag: [Float]

    // Flattened sparse kernels. For output bin k, the entries live at
    // [kernelOffsets[k], kernelOffsets[k] + kernelCounts[k]).
    private var kernelBins: [Int32]
    private var kernelReal: [Float]
    private var kernelImag: [Float]
    private var kernelOffsets: [Int]
    private var kernelCounts: [Int]

    init?(fftSize: Int = 32768,
          sampleRate: Float,
          minHz: Float = 65.4064,
          maxHz: Float = 4186.01,
          totalBins: Int = 144) {
        let lg = vDSP_Length(log2(Double(fftSize)).rounded())
        guard 1 << lg == fftSize else { return nil }
        guard let setup = vDSP_create_fftsetup(lg, FFTRadix(kFFTRadix2)) else { return nil }

        self.log2n = lg
        self.fftSetup = setup
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.minHz = minHz
        self.maxHz = maxHz
        self.totalBins = totalBins

        self.sigReal = [Float](repeating: 0, count: fftSize)
        self.sigImag = [Float](repeating: 0, count: fftSize)

        // Continuous (possibly non-integer) bins per octave so that totalBins
        // exactly covers [minHz, maxHz). The CQT formulation only requires
        // log-uniform spacing — integer BPO is convention, not necessity.
        let binsPerOctave = Float(totalBins) / log2(maxHz / minHz)
        let Q: Float = 1.0 / (powf(2.0, 1.0 / binsPerOctave) - 1.0)

        var bins: [Int32] = []
        var reals: [Float] = []
        var imags: [Float] = []
        var offsets: [Int] = []
        var counts: [Int] = []
        offsets.reserveCapacity(totalBins)
        counts.reserveCapacity(totalBins)

        var tmpReal = [Float](repeating: 0, count: fftSize)
        var tmpImag = [Float](repeating: 0, count: fftSize)

        // Threshold matches the standard CQT sparsity recommendation
        // (Schörkhuber-Klapuri suggest ~0.0054 of the kernel's peak energy).
        let threshold: Float = 0.0054

        for k in 0..<totalBins {
            let fk = minHz * powf(2.0, Float(k) / binsPerOctave)
            let Nk_real = Q * sampleRate / fk
            let Nk = min(Int(ceilf(Nk_real)), fftSize)
            let startN = (fftSize - Nk) / 2

            // Zero the temp buffers
            for i in 0..<fftSize { tmpReal[i] = 0; tmpImag[i] = 0 }

            // Hann-windowed complex exponential, centered in fftSize and
            // amplitude-normalized so kernels of any length have comparable
            // magnitude responses.
            let denom = Float(max(1, Nk - 1))
            let phaseStep = 2.0 * Float.pi * fk / sampleRate
            let invN = 1.0 / Float(Nk)
            for n in 0..<Nk {
                let win = 0.5 * (1.0 - cosf(2.0 * .pi * Float(n) / denom))
                let phase = phaseStep * Float(n)
                let amp = win * invN
                tmpReal[startN + n] = amp * cosf(phase)
                tmpImag[startN + n] = amp * sinf(phase)
            }

            // Length-fftSize complex FFT of this kernel
            tmpReal.withUnsafeMutableBufferPointer { rp in
                tmpImag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, lg, FFTDirection(kFFTDirection_Forward))
                }
            }

            // Keep only the spectrally significant entries. Stored as the
            // complex conjugate of the kernel so the per-frame loop can use
            // a straight multiply-accumulate to compute <X, K> = X · K*.
            let firstIndex = bins.count
            for m in 0..<fftSize {
                let re = tmpReal[m]
                let im = tmpImag[m]
                let mag2 = re * re + im * im
                if mag2 > threshold * threshold {
                    bins.append(Int32(m))
                    reals.append(re)
                    imags.append(-im)
                }
            }
            offsets.append(firstIndex)
            counts.append(bins.count - firstIndex)
        }

        self.kernelBins = bins
        self.kernelReal = reals
        self.kernelImag = imags
        self.kernelOffsets = offsets
        self.kernelCounts = counts
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Process exactly `fftSize` samples and emit `totalBins` log10-magnitude
    /// values (in dB) into `output`.
    func process(samples: UnsafePointer<Float>, into output: inout [Float]) {
        precondition(output.count == totalBins)

        // Copy signal into real part, zero the imag part.
        sigReal.withUnsafeMutableBufferPointer { rp in
            memcpy(rp.baseAddress!, samples, fftSize * MemoryLayout<Float>.size)
        }
        sigImag.withUnsafeMutableBufferPointer { ip in
            memset(ip.baseAddress!, 0, fftSize * MemoryLayout<Float>.size)
        }

        // Forward complex FFT in place
        sigReal.withUnsafeMutableBufferPointer { rp in
            sigImag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        // Sparse band dot product: cqt[k] = sum_m X[m] · conj(K_k)[m]
        kernelBins.withUnsafeBufferPointer { binsPtr in
            kernelReal.withUnsafeBufferPointer { krePtr in
                kernelImag.withUnsafeBufferPointer { kimPtr in
                    sigReal.withUnsafeBufferPointer { srPtr in
                        sigImag.withUnsafeBufferPointer { siPtr in
                            for k in 0..<totalBins {
                                let off = kernelOffsets[k]
                                let cnt = kernelCounts[k]
                                var sumRe: Float = 0
                                var sumIm: Float = 0
                                var i = 0
                                while i < cnt {
                                    let m = Int(binsPtr[off + i])
                                    let xRe = srPtr[m]
                                    let xIm = siPtr[m]
                                    let kRe = krePtr[off + i]
                                    let kIm = kimPtr[off + i]
                                    sumRe += xRe * kRe - xIm * kIm
                                    sumIm += xRe * kIm + xIm * kRe
                                    i += 1
                                }
                                let mag2 = sumRe * sumRe + sumIm * sumIm
                                // 20·log10(mag) = 10·log10(mag^2)
                                output[k] = 10.0 * log10f(max(mag2, 1e-24))
                            }
                        }
                    }
                }
            }
        }
    }
}
