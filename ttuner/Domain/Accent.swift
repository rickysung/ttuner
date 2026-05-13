import Foundation

enum Accent: UInt8, Codable, CaseIterable {
    case off = 0
    case soft = 1
    case normal = 2
    case accent = 3

    func next() -> Accent {
        switch self {
        case .off: return .soft
        case .soft: return .normal
        case .normal: return .accent
        case .accent: return .off
        }
    }
}
