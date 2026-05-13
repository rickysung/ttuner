import Foundation
import AVFoundation

final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private init() {}

    func configure(mode: SessionAudioMode, preferredSampleRate: Double) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: mode == .measurement ? .measurement : .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setPreferredSampleRate(preferredSampleRate)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true, options: [])
        } catch {
            NSLog("AVAudioSession configure failed: \(error)")
        }
    }

    func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    var hasRecordPermission: Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    var outputLatency: TimeInterval {
        AVAudioSession.sharedInstance().outputLatency
    }

    var inputLatency: TimeInterval {
        AVAudioSession.sharedInstance().inputLatency
    }
}
