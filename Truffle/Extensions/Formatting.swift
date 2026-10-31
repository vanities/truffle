import Foundation

extension TimeInterval {
    /// 3:07, or 1:02:33 past an hour.
    var clockString: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    /// "3 minutes, 7 seconds": what VoiceOver says for 3:07.
    var spokenDuration: String {
        guard isFinite, self >= 0 else { return "0 seconds" }
        return Duration.seconds(Int(rounded(.down))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// "3 hr 12 min", "47 min".
    var shortDurationString: String {
        guard isFinite, self > 0 else { return "0 min" }
        let minutes = Int((self / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}

extension Int {
    /// 17,085.
    var grouped: String { formatted(.number) }

    /// "1 song", "17,085 songs".
    func counted(_ singular: String, _ plural: String? = nil) -> String {
        "\(grouped) \(self == 1 ? singular : plural ?? singular + "s")"
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
