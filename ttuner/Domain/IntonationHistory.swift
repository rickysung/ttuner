import Foundation

/// Rolling buffer of (hostTime, |cents|) for the intonation heatmap.
final class IntonationHistory {
    private struct Entry { let hostTime: UInt64; let magnitude: Float }
    private var ring: [Entry?] = []
    private var head: Int = 0
    private let capacity: Int

    init(capacity: Int = 1024) {
        self.capacity = capacity
        self.ring = Array(repeating: nil, count: capacity)
    }

    func append(hostTime: UInt64, magnitude: Float) {
        ring[head] = Entry(hostTime: hostTime, magnitude: magnitude)
        head = (head + 1) % capacity
    }

    func snapshot(secondsBack: Double) -> [(ageSeconds: Double, magnitude: Float)] {
        let info = MachTimebase.info
        let secondsPerTick = Double(info.numer) / Double(info.denom) / 1.0e9
        let now = mach_absolute_time()
        var out: [(Double, Float)] = []
        out.reserveCapacity(capacity)
        for i in 0..<capacity {
            let idx = (head + i) % capacity
            guard let e = ring[idx] else { continue }
            let dt = Double(Int64(now) - Int64(e.hostTime)) * secondsPerTick
            if dt < 0 || dt > secondsBack { continue }
            out.append((dt, e.magnitude))
        }
        return out
    }
}

enum MachTimebase {
    static let info: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}
