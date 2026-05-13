import Foundation
import UIKit

enum AppOrientation: Equatable {
    case portrait
    case landscape

    var isLandscape: Bool { self == .landscape }

    static func from(_ size: CGSize) -> AppOrientation {
        size.width > size.height ? .landscape : .portrait
    }
}
