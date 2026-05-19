import Foundation

/// Minimal mono 16-bit PCM WAV writer. Output is suitable for sharing via
/// `UIActivityViewController` or saving via `UIDocumentPickerViewController`.
enum WAVWriter {
    static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign: UInt16 = numChannels * bitsPerSample / 8
        let dataSize = UInt32(samples.count * Int(bitsPerSample) / 8)
        let chunkSize: UInt32 = 36 + dataSize

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(chunkSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))           // PCM fmt chunk size
        data.appendLE(UInt16(1))            // PCM
        data.appendLE(numChannels)
        data.appendLE(UInt32(sampleRate))
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.appendLE(dataSize)

        // Clamp + convert Float32 -> Int16
        data.reserveCapacity(data.count + samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let v = Int16(clamped * 32767.0)
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
}
