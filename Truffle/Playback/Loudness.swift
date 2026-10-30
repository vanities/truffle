import Foundation

/// Evens out volume between songs from the server's loudness analysis.
///
/// AVPlayer can only turn a song down (volume tops out at 1.0), so the target sits below most
/// modern masters: louder songs come down to it, quieter ones play at full volume.
enum Loudness {
    /// LUFS. Around where Apple's Sound Check lands.
    static let target = -16.0

    /// The volume (0…1) for a song. An album played in order keeps its own dynamics: every song in
    /// it gets the album's level, the way ReplayGain's album mode works.
    static func volume(for track: Track, albumMode: Bool) -> Float {
        guard let loudness = level(of: track, albumMode: albumMode) else { return 1 }
        let change = min(0, target - loudness)
        return Float(pow(10, change / 20))
    }

    /// Plex's `gain` is what takes a song to its own reference level, and `albumGain` the same for
    /// the whole album, so the album's loudness is the song's, shifted by their difference.
    static func level(of track: Track, albumMode: Bool) -> Double? {
        guard let loudness = track.loudness else { return nil }
        guard albumMode, let gain = track.gain, let albumGain = track.albumGain else { return loudness }
        return loudness + gain - albumGain
    }
}
