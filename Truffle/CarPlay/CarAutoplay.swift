import AVFoundation
import Foundation
import os

/// "Play in the Car" (Settings, on by default): when CarPlay connects and Truffle is idle, pick up the
/// saved queue where it left off, or Shuffle All when there's nothing to pick up. It never talks over
/// anything already playing, Truffle or another app, and it decides once per connection.
///
/// The rule is a plain function so it's tested without a car (the CarPlay simulator window can't be
/// scripted); every decision is logged with what it saw.
struct CarAutoplay: Sendable {
    enum Decision: String, Sendable {
        case resume
        case shuffleAll
        /// This connection already decided; asking again changes nothing.
        case alreadyDecided
        case off
        case signedOut
        /// Truffle is playing, or starting something.
        case busy
        /// Another app is playing (a podcast, an audiobook).
        case otherAudio

        var plays: Bool { self == .resume || self == .shuffleAll }
    }

    struct Situation: Equatable, Sendable {
        var enabled: Bool
        var signedIn: Bool
        var truffleBusy: Bool
        var otherAudio: Bool
        var canResume: Bool

        var summary: String {
            [enabled ? "on" : "off", signedIn ? "signed in" : "signed out", truffleBusy ? "Truffle busy" : "Truffle idle",
             otherAudio ? "other audio playing" : "no other audio", canResume ? "a queue to pick up" : "nothing to pick up"]
                .joined(separator: ", ")
        }
    }

    private(set) var decidedThisConnection = false

    static func decision(for situation: Situation, alreadyDecided: Bool) -> Decision {
        if alreadyDecided { return .alreadyDecided }
        if !situation.enabled { return .off }
        if !situation.signedIn { return .signedOut }
        if situation.truffleBusy { return .busy }
        if situation.otherAudio { return .otherAudio }
        return situation.canResume ? .resume : .shuffleAll
    }

    /// A saved queue with something left in it: a song partway through, more after it, or an endless
    /// shuffle. A queue that played to its end is nothing to pick up.
    static func canResume(_ queue: PlayQueue, at time: TimeInterval, endless: Bool) -> Bool {
        guard queue.current != nil else { return false }
        return endless || queue.indexForNext() != nil || time >= 1
    }

    mutating func carConnected(_ situation: Situation) -> Decision {
        let decision = Self.decision(for: situation, alreadyDecided: decidedThisConnection)
        decidedThisConnection = true
        Logger.carplay.info("[autoplay] \(decision.rawValue, privacy: .public): \(situation.summary, privacy: .public)")
        return decision
    }

    mutating func carDisconnected() {
        decidedThisConnection = false
        Logger.carplay.info("[autoplay] car gone; the next connection decides again")
    }
}

@MainActor
extension CarAutoplay {
    /// The car connected: decide, then carry it out. `showNowPlaying` puts the car's Now Playing screen
    /// up when something starts.
    mutating func carConnected(environment: AppEnvironment, showNowPlaying: @MainActor () -> Void) {
        let player = environment.player
        let situation = Situation(
            enabled: environment.settings.playInTheCar,
            signedIn: environment.library.isSignedIn,
            truffleBusy: player.isPlaying || player.isLoading,
            otherAudio: AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint,
            canResume: Self.canResume(player.queue, at: player.currentTime, endless: player.isEndless))
        switch carConnected(situation) {
        case .resume:
            Logger.carplay.info("[autoplay] picking up \"\(player.current?.title ?? "?", privacy: .public)\" (\(player.queue.index + 1)/\(player.queue.tracks.count)) at \(Int(player.currentTime))s")
            showNowPlaying()
            player.play()
        case .shuffleAll:
            Logger.carplay.info("[autoplay] starting Shuffle All")
            showNowPlaying()
            Task { await player.shuffleAll() }
        case .busy:
            Logger.carplay.info("[autoplay] leaving \"\(player.current?.title ?? "?", privacy: .public)\" alone")
        case .alreadyDecided, .off, .signedOut, .otherAudio:
            break
        }
    }
}
