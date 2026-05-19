import Foundation

/// PCM16 WAV blob builder used by the on-device tone synthesisers
/// (`ReferenceTone`, `DroneEngine`). Both produce a `[Float]` buffer
/// in `[-1, 1]` and need a WAV-wrapped `Data` they can hand to
/// `AVAudioPlayer`. Centralised here so the RIFF header math lives
/// in exactly one place.
enum WAVEncoder {
    /// Wrap mono 16-bit PCM samples in a minimal WAV container.
    /// Clamps each sample to `[-1, 1]` before scaling to Int16.
    static func makeWAVData(samples: [Float], sampleRate: Double) -> Data {
        let sr = UInt32(sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample: UInt16 = bitsPerSample / 8
        let dataBytes = UInt32(samples.count) * UInt32(bytesPerSample)
        let byteRate = sr * UInt32(channels) * UInt32(bytesPerSample)
        let blockAlign = channels * bytesPerSample

        var data = Data()
        data.reserveCapacity(Int(44 + dataBytes))

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36) + dataBytes)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(channels)
        appendLE(sr)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        appendLE(dataBytes)

        for f in samples {
            let clamped = max(-1, min(1, f))
            let scaled = Int16(clamped * 32767)
            appendLE(scaled)
        }
        return data
    }
}
