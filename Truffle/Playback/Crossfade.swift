import Foundation

/// Crossfades between shuffled songs: which transitions get one, when it starts, and the volume curves.
/// Pure, so the rules are tested apart from AVFoundation; `PlayerEngine` does the playing.
enum Crossfade {
    /// The lengths Settings offers, in seconds. 0 is off.
    static let choices = [0, 3, 6, 10]
    /// A fade never takes more than this share of either song, so a short song still gets a moment on its
    /// own and one fade is always over before the next can start.
    static let maxShare = 0.25
    /// Shorter than this isn't worth a blend; the songs run together gaplessly instead.
    static let minimumLength: TimeInterval = 1

    struct Plan: Equatable, Sendable {
        /// When the fade begins, in the outgoing song's time.
        var start: TimeInterval
        var length: TimeInterval
    }

    /// Why a transition stays gapless.
    enum Gapless: String, Sendable {
        case off
        case albumOrder = "album order"
        case notShuffle = "not a shuffle"
        case repeatOne = "repeat one"
        case sameSong = "same song"
        case tooShort = "too short"
    }

    enum Decision: Equatable, Sendable {
        case fade(Plan)
        case gapless(Gapless)
    }

    /// `seconds` is the setting; the lengths are the songs' own (0 when unknown).
    static func decide(seconds: Int, source: PlaySource?, repeatMode: RepeatMode,
                       from current: Track, length currentLength: TimeInterval,
                       to next: Track, length nextLength: TimeInterval) -> Decision {
        guard seconds > 0 else { return .gapless(.off) }
        if follows(next, current) { return .gapless(.albumOrder) }
        guard isShuffle(source) else { return .gapless(.notShuffle) }
        guard repeatMode != .one else { return .gapless(.repeatOne) }
        guard next.id != current.id else { return .gapless(.sameSong) }
        let length = min(TimeInterval(seconds), currentLength * maxShare, nextLength * maxShare)
        guard length >= minimumLength else { return .gapless(.tooShort) }
        return .fade(Plan(start: currentLength - length, length: length))
    }

    /// Shuffle All, and playlists played in a random order. Everything else plays as it was sequenced.
    static func isShuffle(_ source: PlaySource?) -> Bool {
        guard let source else { return false }
        return source.kind == .shuffleAll || (source.kind == .playlist && source.shuffled)
    }

    /// `next` comes right after `current` on the same album: the next track, or the first of the next disc.
    /// Those stay gapless even in a shuffle, because live albums and segues run into each other.
    static func follows(_ next: Track, _ current: Track) -> Bool {
        guard let album = current.albumID, album == next.albumID,
              let number = current.trackNumber, let nextNumber = next.trackNumber else { return false }
        let disc = current.discNumber ?? 1
        let nextDisc = next.discNumber ?? 1
        return (nextDisc == disc && nextNumber == number + 1) || (nextDisc == disc + 1 && nextNumber == 1)
    }

    /// How far through the fade the outgoing song is at `time`, from 0 to 1.
    static func progress(at time: TimeInterval, start: TimeInterval, length: TimeInterval) -> Double {
        guard time.isFinite else { return 0 }
        guard length > 0 else { return 1 }
        return min(1, max(0, (time - start) / length))
    }

    /// Equal-power curves: the squares of the two gains always add up to 1, so two unrelated songs blend
    /// without the dip halfway that straight lines give.
    static func gains(at progress: Double) -> (outgoing: Float, incoming: Float) {
        let clamped = min(1, max(0, progress))
        return (Float(cos(clamped * .pi / 2)), Float(sin(clamped * .pi / 2)))
    }
}
