import Foundation
import Observation
import QuartzCore

@Observable
final class TunerState {
    var current: PitchEvent?
    var reading: NoteReading?
    var stable: Bool = false
    var trail: [PitchEvent] = []

    private let trailMax = 64
    private let stabilityWindowMs: Double = 300
    private var recentCents: [(time: TimeInterval, cents: Double)] = []
    private let recentMax = 32

    func update(with event: PitchEvent?, reading: NoteReading?, stabilityCents: Float) {
        self.current = event
        self.reading = reading
        if let event {
            trail.append(event)
            if trail.count > trailMax { trail.removeFirst(trail.count - trailMax) }
        }
        if let reading {
            let now = CACurrentMediaTime()
            recentCents.append((now, reading.cents))
            if recentCents.count > recentMax { recentCents.removeFirst(recentCents.count - recentMax) }
            let cutoff = now - stabilityWindowMs / 1000.0
            let recent = recentCents.filter { $0.time >= cutoff }.map { $0.cents }
            if recent.count >= 4 {
                let mean = recent.reduce(0, +) / Double(recent.count)
                let variance = recent.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(recent.count)
                let std = sqrt(variance)
                stable = std < Double(stabilityCents)
            } else {
                stable = false
            }
        } else {
            stable = false
        }
    }
}
