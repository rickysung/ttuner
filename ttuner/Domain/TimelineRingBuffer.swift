import Foundation

/// Ring buffer of compressed spectrogram columns (display-bin count).
/// Stored as Float (mapped from Float16 at read time would also work, but Float on
/// modern iOS is fine memory-wise — see spec §6.2 budget).
final class TimelineRingBuffer {
    let columnHeight: Int
    let capacityColumns: Int
    private var storage: UnsafeMutablePointer<Float>
    private var hostTimes: UnsafeMutablePointer<UInt64>
    private(set) var writeIndex: Int = 0
    private(set) var totalWrites: UInt64 = 0
    private var lock = os_unfair_lock_s()

    init(capacityColumns: Int, columnHeight: Int) {
        self.capacityColumns = capacityColumns
        self.columnHeight = columnHeight
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: capacityColumns * columnHeight)
        self.storage.initialize(repeating: -.infinity, count: capacityColumns * columnHeight)
        self.hostTimes = UnsafeMutablePointer<UInt64>.allocate(capacity: capacityColumns)
        self.hostTimes.initialize(repeating: 0, count: capacityColumns)
    }

    deinit {
        storage.deallocate()
        hostTimes.deallocate()
    }

    func write(_ frame: SpectrumFrame) {
        guard frame.bins.count == columnHeight else { return }
        os_unfair_lock_lock(&lock)
        let dst = storage.advanced(by: writeIndex * columnHeight)
        frame.bins.withUnsafeBufferPointer { src in
            dst.assign(from: src.baseAddress!, count: columnHeight)
        }
        hostTimes[writeIndex] = frame.hostTime
        writeIndex = (writeIndex + 1) % capacityColumns
        totalWrites &+= 1
        os_unfair_lock_unlock(&lock)
    }

    /// Snapshot the most recent `count` columns in chronological order into `dst`.
    @discardableResult
    func snapshotLatest(count: Int, into dst: UnsafeMutablePointer<Float>) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let n = min(count, capacityColumns)
        let written = min(Int(totalWrites), capacityColumns)
        let take = min(n, written)
        // Newest is at (writeIndex - 1) mod cap. Walk backwards.
        var srcIdx = (writeIndex - 1 + capacityColumns) % capacityColumns
        for c in 0..<take {
            let dstCol = take - 1 - c  // chronological
            let src = storage.advanced(by: srcIdx * columnHeight)
            let d = dst.advanced(by: dstCol * columnHeight)
            d.assign(from: src, count: columnHeight)
            srcIdx = (srcIdx - 1 + capacityColumns) % capacityColumns
        }
        // Zero-fill any unused columns at the front
        if take < n {
            let pad = n - take
            for i in 0..<(pad * columnHeight) {
                dst[i] = -.infinity
            }
        }
        return take
    }

    /// Snapshot `count` columns ending at `offsetColumns` columns before the latest.
    @discardableResult
    func snapshot(offsetColumns: Int, count: Int, into dst: UnsafeMutablePointer<Float>) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let written = min(Int(totalWrites), capacityColumns)
        let off = max(0, min(offsetColumns, max(0, written - 1)))
        let take = min(count, max(0, written - off))
        var srcIdx = (writeIndex - 1 - off + capacityColumns * 2) % capacityColumns
        for c in 0..<take {
            let dstCol = take - 1 - c
            let src = storage.advanced(by: srcIdx * columnHeight)
            let d = dst.advanced(by: dstCol * columnHeight)
            d.assign(from: src, count: columnHeight)
            srcIdx = (srcIdx - 1 + capacityColumns) % capacityColumns
        }
        for i in (take * columnHeight)..<(count * columnHeight) {
            dst[i] = -.infinity
        }
        return take
    }
}
