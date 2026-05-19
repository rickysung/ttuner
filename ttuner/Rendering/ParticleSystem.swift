import Foundation
import simd

/// A single sprite-billboard particle. Sized to match the GPU instance layout
/// exactly so the buffer can be uploaded with a `memcpy`.
struct ParticleInstance {
    var pos: SIMD2<Float>   // NDC
    var vel: SIMD2<Float>   // NDC per second (for optional motion stretching)
    var life: Float         // 1.0 = freshly emitted, 0 = expired
    var seed: Float         // per-particle random in [0, 1)
}

/// Particle pool — data holder + initial seed only. The actual physics
/// step now runs on the GPU (see `simulate_particles` in Shaders.metal);
/// this class exists to:
///   • own the initial `particles` array (seeded with staggered lives so
///     the steady-state cloud is visible from frame 1)
///   • centralize the simulation parameters that the renderer copies
///     into SimUniforms each frame
///
/// Forces per particle (applied on GPU):
///   • slow constant upward acceleration ("fire" rise)
///   • soft Brownian acceleration in both axes for natural flicker
///   • Hooke-style pull toward the nearest reference-grid line
///   • extra upward kick when within `boostRadius` of any line — gives
///     the satisfying jet shape when the player holds a clean pitch
final class ParticleSystem {
    let capacity: Int
    private(set) var particles: [ParticleInstance]

    // Emitter position in NDC (origin of every newborn particle).
    var emitterX: Float = 0
    var emitterY: Float = -0.66

    // Reference-grid camera (smoothed MIDI semitone of the current pitch).
    // The renderer updates this every frame.
    var cameraSemitone: Float = 60
    var semitoneSpacing: Float = 2.0 / 6.0    // 1 semitone in NDC.x (half octave across screen)

    // Volume/clarity hooks
    var emitterIntensity: Float = 0.4 // 0..1, scales spawn vigour & brightness
    var inTuneAmount: Float = 0       // 0 = far off, 1 = within ±5¢
    var pitchActive: Bool = false     // when false, the force field weakens —
                                      // particles scatter freely like a wild flame

    // Tunables — physics now models F=ma honestly:
    //   * attract / boost / upBias / brownian are forces (÷ mass).
    //   * globalGravity is an acceleration (mass-independent, à la Galileo).
    // This gives the visual story the user is after:
    //   light sparks → caught by a pitch line, spiral upward;
    //   heavy embers → gravity wins, they fall back down and fade.
    var upwardBias: Float = 0.18       // buoyancy force (heavier = less lift)
    var brownianStrength: Float = 0.50 // random kick keeps the flame "alive"
    var attractStrength: Float = 24.0  // spring k toward nearest line — strong enough to
                                       // overcome gravity for light particles
    var boostRadius: Float = 0.10      // NDC distance under which a line lifts particles
    var boostStrength: Float = 1.50    // upward kick force near a line
    var globalGravity: Float = 0.50    // acceleration, always downward (mass-independent)
    var lifeDecay: Float = 0.20        // ⇒ ~5 s lifetime — long enough for the
                                       // up-then-down arc, short enough to recycle

    private var rng = SystemRandomNumberGenerator()

    init(capacity: Int = 500) {
        self.capacity = capacity
        self.particles = (0..<capacity).map { _ in
            ParticleInstance(pos: SIMD2(0, -0.66),
                             vel: .zero,
                             life: 0,
                             seed: Float.random(in: 0..<1))
        }
        // Stagger starting lives so the steady-state cloud is visible from
        // the first frame instead of a single emit burst.
        for i in 0..<capacity {
            particles[i].life = Float.random(in: 0..<1)
            respawn(at: i, freshLife: particles[i].life)
        }
    }

    @inline(__always)
    private func uniformRand() -> Float {
        // Float.random uses a thread-unsafe global, but the renderer steps
        // particles serially on the main thread; using `rng` keeps that intent.
        Float(UInt32.random(in: 0..<UInt32.max, using: &rng)) / Float(UInt32.max)
    }

    private func respawn(at index: Int, freshLife: Float = 1.0) {
        // Fully omnidirectional spawn — matches the GPU compute kernel
        // so init-time particles blend seamlessly with the steady-state
        // cloud once simulation takes over.
        let angle: Float = uniformRand() * 2.0 * .pi
        // Wider speed envelope, biased toward slow (pow > 1 squashes high values).
        let speedRand = uniformRand()
        let speed = 0.02 + powf(speedRand, 1.3) * 0.50
        particles[index] = ParticleInstance(
            pos: SIMD2(emitterX + (uniformRand() - 0.5) * 0.045,
                       emitterY + (uniformRand() - 0.5) * 0.020),
            vel: SIMD2(cosf(angle) * speed, sinf(angle) * speed),
            life: freshLife,
            // `seed` carries both visual jitter (size/brightness in the
            // shader) and mass jitter (the simulator scales force by 1/mass).
            seed: uniformRand()
        )
    }

    /// Number of particles that should be alive at any moment, as a
    /// function of the current emitter intensity (loudness 0..1).
    /// Quiet = 25 % of the pool (≈ half the pre-volume baseline of 500
    /// particles); peak = 100 % (≈ double the baseline). The compute
    /// kernel holds slots beyond this dead so the visible cloud breathes
    /// with loudness without growing the pool.
    func activeCount(forIntensity intensity: Float) -> Int {
        let clamped = max(0, min(1, intensity))
        let fraction: Float = 0.25 + 0.75 * powf(clamped, 0.6)
        return Int(Float(capacity) * fraction)
    }
}

/// Mirror of the Metal `SimUniforms` struct. Field order and types must
/// match exactly — the renderer uploads this with `setBytes`.
struct ParticleSimUniforms {
    var dt: Float
    var frameCounter: UInt32
    var activeCount: UInt32
    var capacity: UInt32
    var emitterX: Float
    var emitterY: Float
    var cameraSemitone: Float
    var semitoneSpacing: Float
    var upwardBias: Float
    var brownian: Float
    var attract: Float
    var boost: Float
    var boostRadius: Float
    var globalGravity: Float
    var lifeDecay: Float
    var damp: Float
    var emitterIntensity: Float
}
