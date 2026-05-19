import Foundation
import AVFoundation

/// One process-wide `AVAudioEngine` that both `CaptureEngine` (input tap)
/// and `MetronomeEngine` (output) attach to.
///
/// Why one engine instead of two:
///   iOS allows multiple `AVAudioEngine` instances on a single
///   `AVAudioSession`, but in practice — once one engine has the input
///   bus active (mic capture) — a second engine's output path frequently
///   fails to route to the speaker. The audio session is happy; the
///   second engine is "running"; but no frames reach the device. Apple's
///   sample code consistently routes input and output through a single
///   engine, and doing the same here removes that whole class of bug.
///
/// Lifecycle: idempotent `start()`/`stop()`. Components call `start()`
/// after they've attached/connected their nodes; the first caller boots
/// the engine, subsequent calls are no-ops.
final class SharedAudioEngine {
    static let shared = SharedAudioEngine()

    let engine = AVAudioEngine()

    private let lock = NSLock()

    private init() {}

    /// Start the engine if it isn't already running. Safe to call from
    /// any component; idempotent. Throws whatever `AVAudioEngine.start()`
    /// throws on the actual cold-start call.
    func startIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Full teardown — only call this from app teardown. Individual
    /// components should leave the engine running so other clients
    /// (e.g. metronome) keep working.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if engine.isRunning {
            engine.stop()
        }
    }
}
