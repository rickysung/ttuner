import Foundation
import simd

/// 256-entry RGBA8 lookup tables for the supported colormaps.
/// Coarse but visually faithful approximations of Matplotlib's perceptual maps.
enum Colormaps {
    static func lut(for kind: ColormapKind) -> [UInt8] {
        switch kind {
        case .viridis:  return build(stops: viridisStops)
        case .magma:    return build(stops: magmaStops)
        case .inferno:  return build(stops: infernoStops)
        case .monoBlue: return build(stops: monoBlueStops)
        }
    }

    private static func build(stops: [(Float, SIMD3<Float>)]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            let t = Float(i) / 255.0
            let c = sample(stops: stops, t: t)
            out[i * 4 + 0] = UInt8(clamping: Int(c.x * 255))
            out[i * 4 + 1] = UInt8(clamping: Int(c.y * 255))
            out[i * 4 + 2] = UInt8(clamping: Int(c.z * 255))
            out[i * 4 + 3] = 255
        }
        return out
    }

    private static func sample(stops: [(Float, SIMD3<Float>)], t: Float) -> SIMD3<Float> {
        if t <= stops.first!.0 { return stops.first!.1 }
        if t >= stops.last!.0  { return stops.last!.1 }
        for i in 0..<(stops.count - 1) {
            let (t0, c0) = stops[i]
            let (t1, c1) = stops[i + 1]
            if t >= t0 && t <= t1 {
                let f = (t - t0) / max(1e-6, t1 - t0)
                return mix(c0, c1, t: f)
            }
        }
        return stops.last!.1
    }

    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a * (1 - t) + b * t
    }

    private static let viridisStops: [(Float, SIMD3<Float>)] = [
        (0.00, [0.267, 0.005, 0.329]),
        (0.25, [0.282, 0.140, 0.457]),
        (0.50, [0.254, 0.265, 0.530]),
        (0.75, [0.207, 0.372, 0.553]),
        (0.85, [0.355, 0.561, 0.523]),
        (1.00, [0.993, 0.906, 0.144])
    ]

    private static let magmaStops: [(Float, SIMD3<Float>)] = [
        (0.00, [0.001, 0.000, 0.014]),
        (0.25, [0.115, 0.064, 0.298]),
        (0.50, [0.355, 0.066, 0.430]),
        (0.75, [0.717, 0.214, 0.475]),
        (0.90, [0.967, 0.498, 0.499]),
        (1.00, [0.987, 0.991, 0.749])
    ]

    private static let infernoStops: [(Float, SIMD3<Float>)] = [
        (0.00, [0.001, 0.000, 0.014]),
        (0.25, [0.180, 0.040, 0.376]),
        (0.50, [0.471, 0.110, 0.430]),
        (0.75, [0.873, 0.288, 0.220]),
        (0.90, [0.988, 0.647, 0.040]),
        (1.00, [0.988, 0.998, 0.645])
    ]

    private static let monoBlueStops: [(Float, SIMD3<Float>)] = [
        (0.00, [0.020, 0.030, 0.062]),
        (0.25, [0.094, 0.180, 0.380]),
        (0.50, [0.180, 0.380, 0.640]),
        (0.75, [0.420, 0.680, 0.900]),
        (1.00, [0.870, 0.960, 1.000])
    ]
}
