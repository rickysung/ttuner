import Foundation

struct TimeSignature: Equatable, Codable {
    var numerator: Int
    var denominator: Int

    static let twoFour = TimeSignature(numerator: 2, denominator: 4)
    static let threeFour = TimeSignature(numerator: 3, denominator: 4)
    static let fourFour = TimeSignature(numerator: 4, denominator: 4)
    static let sixEight = TimeSignature(numerator: 6, denominator: 8)

    var label: String { "\(numerator)/\(denominator)" }

    static func defaultAccentPattern(for sig: TimeSignature) -> [Accent] {
        switch (sig.numerator, sig.denominator) {
        case (2, 4): return [.accent, .normal]
        case (3, 4): return [.accent, .normal, .normal]
        case (4, 4): return [.accent, .normal, .soft, .normal]
        case (6, 8): return [.accent, .soft, .soft, .normal, .soft, .soft]
        default:
            var pattern = Array(repeating: Accent.normal, count: max(1, sig.numerator))
            if !pattern.isEmpty { pattern[0] = .accent }
            return pattern
        }
    }
}
