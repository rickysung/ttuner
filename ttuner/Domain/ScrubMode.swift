import Foundation

enum ScrubMode: Equatable {
    case live
    case paused(offsetSeconds: Double)

    var isLive: Bool { if case .live = self { return true } else { return false } }
}
