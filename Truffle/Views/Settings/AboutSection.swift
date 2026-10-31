import MessageUI
import SwiftUI
import os

/// The bottom of Settings: report a bug, the help and privacy pages, the source, the version.
struct AboutSection: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(SeasonClock.self) private var season
    @Environment(PlayerEngine.self) private var player
    @Environment(\.openURL) private var openURL
    @State private var mail: BugMail?
    @State private var gatheringLog = false

    private static let help = URL(string: "https://am2.biz/truffle/support")!
    private static let privacy = URL(string: "https://am2.biz/truffle/privacy")!
    private static let source = URL(string: "https://github.com/vanities/truffle")!

    var body: some View {
        Section {
            Menu {
                Button("Email Us", systemImage: "envelope") { Task { await emailUs() } }
                Button("Open a GitHub Issue", systemImage: "chevron.left.forwardslash.chevron.right") {
                    Logger.ui.info("[bug] opening a GitHub issue")
                    openURL(report().gitHubIssueURL)
                }
            } label: {
                HStack {
                    Label("Report a Bug", systemImage: "ladybug")
                    if gatheringLog {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(gatheringLog)
            Link(destination: Self.help) { Label("Help", systemImage: "questionmark.circle") }
            Link(destination: Self.privacy) { Label("Privacy", systemImage: "hand.raised") }
            Link(destination: Self.source) { Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            LabeledContent("Version", value: BugReport.appVersionString)
            LabeledContent("Made by", value: "AM2 LLC")
        } header: {
            Text("About")
        } footer: {
            Text("Free and open source. Bugs get squashed fast.")
        }
        .sheet(item: $mail) { draft in
            MailComposer(draft: draft) { mail = nil }
                .ignoresSafeArea()
        }
    }

    private func report() -> BugReport {
        BugReport.current(library: library, settings: settings, season: season, player: player)
    }

    /// Mail with this launch's log attached when the phone has Mail set up; otherwise a plain mailto.
    private func emailUs() async {
        let report = report()
        guard MFMailComposeViewController.canSendMail() else {
            Logger.ui.info("[bug] no Mail account; opening a mailto link")
            openURL(report.mailtoURL)
            return
        }
        gatheringLog = true
        let sw = Stopwatch()
        let log = await Task.detached(priority: .userInitiated) { BugReport.launchLog() }.value
        gatheringLog = false
        Logger.ui.info("[bug] email with \(log.count) characters of log in \(sw.ms, format: .fixed(precision: 0))ms")
        mail = BugMail(subject: report.subject, body: report.template, log: Data(log.utf8))
    }
}

struct BugMail: Identifiable {
    let id = UUID()
    let subject: String
    let body: String
    let log: Data
}

/// The system mail sheet, addressed to the app's email with the log attached.
struct MailComposer: UIViewControllerRepresentable {
    let draft: BugMail
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([BugReport.email])
        composer.setSubject(draft.subject)
        composer.setMessageBody(draft.body, isHTML: false)
        if !draft.log.isEmpty {
            composer.addAttachmentData(draft.log, mimeType: "text/plain", fileName: "truffle-log.txt")
        }
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: (any Error)?) {
            Logger.ui.info("[bug] mail \(result == .sent ? "sent" : "closed", privacy: .public)")
            onFinish()
        }
    }
}
