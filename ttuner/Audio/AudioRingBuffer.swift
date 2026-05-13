import Foundation
import os.lock

/// Single-producer / single-consumer ring buffer for Float32 PCM samples.
///
/// `os_unfair_lock` guards the head/tail indices only — the critical section is a
/// handful of integer stores, so contention between the real-time audio thread
/// and the DSP queue is bounded to sub-microsecond bursts. This is not strictly
/// wait-free, but it is bounded and allocation-free, which is what the audio
/// callback actually needs.
final class AudioRingBuffer {
    private let capacity: Int
    private let mask: Int
    private var storage: UnsafeMutablePointer<Float>
    private var head: Int = 0
    private var tail: Int = 0
    private var lock = os_unfair_lock_s()

    init(capacitySamples: Int) {
        let cap = nextPowerOfTwo(max(capacitySamples, 1024))
        self.capacity = cap
        self.mask = cap - 1
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0, count: cap)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    var availableToRead: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return head - tail
    }

    /// Append `count` samples from `src`. Drops the oldest data if buffer is full.
    func write(_ src: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(&lock)
        var h = head
        let t = tail
        let free = capacity - (h - t)
        if count > free {
            let drop = count - free
            tail = t + drop
        }
        for i in 0..<count {
            storage[(h + i) & mask] = src[i]
        }
        h &+= count
        head = h
        os_unfair_lock_unlock(&lock)
    }

    /// Read up to `maxCount` samples. Returns actual sample count read.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        os_unfair_lock_lock(&lock)
        let h = head
        var t = tail
        let avail = h - t
        let n = min(maxCount, avail)
        for i in 0..<n {
            dst[i] = storage[(t + i) & mask]
        }
        t &+= n
        tail = t
        os_unfair_lock_unlock(&lock)
        return n
    }

    /// Peek the most recent `count` samples without consuming them.
    @discardableResult
    func peekRecent(_ count: Int, into dst: UnsafeMutablePointer<Float>) -> Int {
        os_unfair_lock_lock(&lock)
        let h = head
        let t = tail
        let avail = h - t
        let n = min(count, avail)
        let start = h - n
        for i in 0..<n {
            dst[i] = storage[(start + i) & mask]
        }
        os_unfair_lock_unlock(&lock)
        return n
    }
}

private func nextPowerOfTwo(_ x: Int) -> Int {
    var n = 1
    while n < x { n <<= 1 }
    return n
}
