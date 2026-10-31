import XCTest
@testable import Truffle

/// "Report a Bug" sends the app's state, never who or where: no account, server name, addresses or tokens.
final class BugReportTests: XCTestCase {
    private let report = BugReport(appVersion: "1.1.0 (9)", system: "iOS 27.2", device: "iPhone18,2",
                                   details: [("Library", "Plex"), ("Connection", "local"), ("Songs", "17085")])

    func testDiagnosticsSayWhatAndWhereNotWho() {
        XCTAssertTrue(report.diagnostics.contains("Truffle 1.1.0 (9)"))
        XCTAssertTrue(report.diagnostics.contains("iOS 27.2 on iPhone18,2"))
        XCTAssertTrue(report.diagnostics.contains("Connection: local"))
        XCTAssertTrue(report.template.hasPrefix("What happened?"))
    }

    func testGitHubIssueCarriesTheTemplate() throws {
        let url = report.gitHubIssueURL
        XCTAssertEqual(url.host(), "github.com")
        XCTAssertEqual(url.path(), "/vanities/truffle/issues/new")
        let body = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertEqual(body, report.template, "survives the round trip through the URL")
    }

    func testMailtoIsAddressedToUs() throws {
        let url = report.mailtoURL
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:\(BugReport.email)?"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "subject" }?.value, "Truffle 1.1.0 (9) bug")
    }

    func testLogLinesLoseNamesAndAddresses() {
        XCTAssertEqual(BugReport.redact("[library] start: signed in as somebody, server=Den, 763 cached albums"),
                       "[library] start: signed in as <user>, server=<name>, 763 cached albums")
        XCTAssertEqual(BugReport.redact("[library] server Adam's NAS with 3 address(es)"), "[library] server <name> with 3 address(es)")
        XCTAssertEqual(BugReport.redact("[library] start: signed in as some body, server=The Den, 12 cached albums"),
                       "[library] start: signed in as <user>, server=<name>, 12 cached albums")
        XCTAssertEqual(BugReport.redact("[library] no address for Adam's NAS answered (812ms)"), "[library] no address for <server> answered (812ms)")
        XCTAssertEqual(BugReport.redact("picked https://192-168-1-3.0123456789abcdef0123456789abcdef.plex.direct:32400"),
                       "picked https://<ip>.<server>.plex.direct:32400")
        XCTAssertEqual(BugReport.redact("GET /x?X-Plex-Token=abc123&y=1 from 10.0.0.7"), "GET /x?X-Plex-Token=<redacted>&y=1 from <ip>")
        XCTAssertEqual(BugReport.redact("[player] advanced to 3/12 \"Song\""), "[player] advanced to 3/12 \"Song\"", "ordinary lines are untouched")
    }
}
