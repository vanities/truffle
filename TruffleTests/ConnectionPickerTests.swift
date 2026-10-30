import XCTest
@testable import Truffle

final class ConnectionPickerTests: XCTestCase {
    private let local = PlexServerInfo.Connection(uri: URL(string: "https://192-168-1-10.x.plex.direct:32400")!, local: true, relay: false)
    private let remote = PlexServerInfo.Connection(uri: URL(string: "https://203-0-113-9.x.plex.direct:32400")!, local: false, relay: false)
    private let relay = PlexServerInfo.Connection(uri: URL(string: "https://relay.x.plex.direct:8443")!, local: false, relay: true)

    /// Answers after a delay, or never.
    private func probe(_ answers: [URL: Double?]) -> ConnectionPicker.Probe {
        { url in
            guard let delay = answers[url] ?? nil else {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            try? await Task.sleep(for: .seconds(delay))
            return true
        }
    }

    func testHomeAddressWinsEvenWhenTheRemoteAnswersFirst() async {
        let picked = await ConnectionPicker.pick([relay, remote, local], grace: .milliseconds(500),
                                                 probe: probe([local.uri: 0.2, remote.uri: 0.01, relay.uri: 0.01]))
        XCTAssertEqual(picked, local)
    }

    func testAwayFromHomeTheRemoteBeatsTheRelay() async {
        let picked = await ConnectionPicker.pick([local, remote, relay], grace: .milliseconds(300),
                                                 probe: probe([local.uri: nil, remote.uri: 0.1, relay.uri: 0.01]))
        XCTAssertEqual(picked, remote)
    }

    func testTheRelayIsTheLastResort() async {
        let picked = await ConnectionPicker.pick([local, remote, relay], grace: .milliseconds(100),
                                                 probe: probe([local.uri: nil, remote.uri: nil, relay.uri: 0.05]))
        XCTAssertEqual(picked, relay)
    }

    func testNothingAnswers() async {
        let picked = await ConnectionPicker.pick([local, remote], probe: { _ in false })
        XCTAssertNil(picked)
    }

    func testLeavingHomeIsNotATimeoutPerDeadAddress() async {
        let started = Date()
        let picked = await ConnectionPicker.pick([local, remote], grace: .milliseconds(200),
                                                 probe: probe([local.uri: nil, remote.uri: 0.05]))
        XCTAssertEqual(picked, remote)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the dead home address isn't waited out")
    }
}
