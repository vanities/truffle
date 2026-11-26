import Foundation

/// A stretch with no sound while the player meant to be playing, written to the car log when it ends:
/// "Silent 12 s mid-song (1:23 in, song 9 of 281): streaming the original on cellular; moved to the lighter
/// stream". The log used to time only how a drive starts, so the pauses on a long drive left nothing to read
/// back (2026-11-26: "that pausing thing while driving is still happening", and three drives in the log that
/// all started in under 2 s). Counts and states only, no song names.
struct Silence: Equatable, Sendable {
    enum Moment: Equatable, Sendable {
        /// The song was already sounding and stopped.
        case midSong(at: TimeInterval)
        /// A song that hadn't made a sound yet: the next one, a skip, a resume.
        case songStart
    }

    enum Ending: Equatable, Sendable {
        case sound
        /// Someone gave up and paused, or something else took the audio.
        case paused
        /// Still silent at `Silence.longWait`: written then, in case the app never sees the end.
        case stillWaiting
    }

    /// What the song is coming from when the silence is written down.
    struct Stream: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case onPhone, original, lighter, nothingLoaded }
        var kind: Kind
        var cellular: Bool

        var text: String {
            switch kind {
            case .onPhone: "song saved on the phone"
            case .original: "streaming the original on \(cellular ? "cellular" : "Wi-Fi")"
            case .lighter: "streaming the lighter stream on \(cellular ? "cellular" : "Wi-Fi")"
            case .nothingLoaded: "nothing loaded yet, on \(cellular ? "cellular" : "Wi-Fi")"
            }
        }
    }

    /// A skip or the next song takes a moment over cellular; a song that stops mid-way is heard at once.
    static let worthNotingAtStart: TimeInterval = 3
    static let worthNotingMidSong: TimeInterval = 1
    static let longWait: Duration = .seconds(30)

    var moment: Moment
    /// What the player did while it was silent, in order.
    private(set) var steps: [String] = []

    init(moment: Moment) {
        self.moment = moment
    }

    mutating func did(_ step: String) {
        if steps.last != step { steps.append(step) }
    }

    func isWorthNoting(lasted: TimeInterval) -> Bool {
        switch moment {
        case .midSong: lasted >= Self.worthNotingMidSong
        case .songStart: lasted >= Self.worthNotingAtStart
        }
    }

    /// The car log's line. `song` is its place in the queue, from 1; `savedAhead` of the next `ofNext` songs
    /// are on the phone, which says whether saving ahead is keeping up on the road.
    func line(lasted: TimeInterval, ending: Ending, song: Int, of total: Int, stream: Stream, savedAhead: Int = 0, ofNext: Int = 0) -> String {
        let length = lasted < 10 ? String(format: "%.1f s", lasted) : "\(Int(lasted.rounded())) s"
        let place: String
        switch moment {
        case .midSong(let at):
            let seconds = max(0, Int(at))
            place = "mid-song (\(seconds / 60):\(String(format: "%02d", seconds % 60)) in, song \(song) of \(total))"
        case .songStart:
            place = "starting song \(song) of \(total)"
        }
        let head: String
        switch ending {
        case .sound: head = "Silent \(length) \(place)"
        case .paused: head = "Silent \(length) \(place), then paused"
        case .stillWaiting: head = "Silent \(length) so far \(place)"
        }
        let ahead = ofNext > 0 ? ["\(savedAhead) of the next \(ofNext) saved"] : []
        return ([head + ": " + stream.text] + steps + ahead).joined(separator: "; ")
    }
}
