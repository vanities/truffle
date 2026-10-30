import AVFoundation
import os

enum AudioSessionManager {
    static func configure() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            Logger.player.info("[session] configured playback/longFormAudio")
        } catch {
            Logger.player.error("[session] configure failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func activate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Logger.player.error("[session] activate failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
