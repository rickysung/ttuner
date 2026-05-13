import Foundation
import Accelerate

enum WindowFunction {
    static func hann(length: Int) -> [Float] {
        var w = [Float](repeating: 0, count: length)
        vDSP_hann_window(&w, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        return w
    }
}
