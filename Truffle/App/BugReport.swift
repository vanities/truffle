import Foundation
import OSLog

/// What "Report a Bug" sends: a template, plus the app's state with nothing that names the person or
/// their server (no account, server name, addresses or tokens), and optionally this launch's log.
struct BugReport: Sendable {
    static let email = "engineering@am2.biz"
    static let newIssue = URL(string: "https://github.com/vanities/truffle/issues/new")!

    let appVersion: String
    let system: String
    let device: String
    let details: [(String, String)]

    var diagnostics: String {
        (["Truffle \(appVersion)", "\(system) on \(device)"] + details.map { "\($0): \($1)" }).joined(separator: "\n")
    }

    var template: String {
        "What happened?\n\n\nWhat did you expect?\n\n\nHow to make it happen again:\n1. \n\n---\n\(diagnostics)\n"
    }

    var subject: String { "Truffle \(appVersion) bug" }

    var gitHubIssueURL: URL {
        var components = URLComponents(url: Self.newIssue, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: template)]
        return components.url ?? Self.newIssue
    }

    var mailtoURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.email
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: template)]
        return components.url ?? URL(string: "mailto:\(Self.email)")!
    }

    static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// The hardware model ("iPhone18,2"), which says nothing about whose phone it is.
    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: - The log

    /// This launch's Truffle log lines, redacted, newest last. Reading the store can take a moment.
    static func launchLog(subsystem: String = Bundle.main.bundleIdentifier ?? "com.vanities.truffle", limit: Int = 3000) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return "" }
        let since = store.position(date: Date().addingTimeInterval(-24 * 3600))
        guard let entries = try? store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@", subsystem)) else {
            return ""
        }
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true).dateSeparator(.dash).time(includingFractionalSeconds: true)
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(entry.date.formatted(format)) [\(entry.category)] \(redact(entry.composedMessage))")
        }
        return lines.suffix(limit).joined(separator: "\n")
    }

    /// Logs never carry tokens or URLs by design; this is the backstop for names and addresses.
    static func redact(_ line: String) -> String {
        var text = line
        // The lines that name the account or server (MusicLibrary: start, the server it picked, no answer).
        text = text.replacing(#/signed in as [^,]+/#, with: "signed in as <user>")
        text = text.replacing(#/server=[^,]+/#, with: "server=<name>")
        text = text.replacing(#/server .+? with (\d+) address/#) { "server <name> with \($0.1) address" }
        text = text.replacing(#/no address for .+? answered/#, with: "no address for <server> answered")
        text = text.replacing(#/X-Plex-Token=[^&\s]+/#, with: "X-Plex-Token=<redacted>")
        text = text.replacing(#/[0-9a-f]{32}\.plex\.direct/#, with: "<server>.plex.direct")
        text = text.replacing(#/\b\d{1,3}(?:[.-]\d{1,3}){3}\b/#, with: "<ip>")
        return text
    }
}

extension BugReport {
    /// The report for the app as it is right now.
    @MainActor
    static func current(library: MusicLibrary, settings: AppSettings, season: SeasonClock, player: PlayerEngine) -> BugReport {
        let onOff = { (on: Bool) in on ? "on" : "off" }
        let setup = [
            settings.crossfadeSeconds > 0 ? "crossfade \(settings.crossfadeSeconds)s" : "crossfade off",
            "data saver \(onOff(settings.dataSaver))",
            "play in the car \(onOff(settings.playInTheCar))",
            "holidays in season \(onOff(settings.holidaysInSeason))",
            "even out volume \(onOff(settings.evenOutVolume))",
            "seasonal effects \(onOff(settings.seasonalEffects))",
            "hemisphere \(settings.hemisphere.rawValue)",
        ]
        return BugReport(
            appVersion: appVersionString,
            system: ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version", with: "iOS"),
            device: deviceModel,
            details: [
                ("Library", library.isDemo ? "the demo" : "Plex"),
                ("Connection", library.endpoint?.kind.rawValue ?? "none"),
                ("Songs", String(library.trackCount)),
                ("Theme", season.theme.id),
                ("Playing", player.current == nil ? "no" : (player.isPlaying ? "yes" : "paused")),
                ("Settings", setup.joined(separator: ", ")),
            ])
    }
}
