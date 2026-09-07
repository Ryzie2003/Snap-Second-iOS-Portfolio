import AVFoundation

enum AVWarmup {
    /// Warm the audio session & AVFoundation so first playback/composition doesn't hitch.
    static func primeAudioSession() async {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Warm-up only; safe to ignore failures.
        }
    }
}
