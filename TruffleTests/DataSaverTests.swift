import XCTest
@testable import Truffle

/// Data Saver's choice, the transcode request it makes, and the saved queue's play source.
final class DataSaverTests: XCTestCase {
    func testOnlyCellularWithTheSettingOnGetsTheTranscode() {
        XCTAssertEqual(DataSaver.mode(enabled: true, metered: true), .dataSaver)
        XCTAssertEqual(DataSaver.mode(enabled: true, metered: false), .original, "Wi-Fi keeps the originals")
        XCTAssertEqual(DataSaver.mode(enabled: false, metered: true), .original, "off by default")
        XCTAssertEqual(DataSaver.mode(enabled: false, metered: false), .original)
    }

    func testCellularOrAnExpensiveLinkCountsAsMetered() {
        XCTAssertTrue(DataSaver.isMetered(cellular: true, expensive: false))
        XCTAssertTrue(DataSaver.isMetered(cellular: false, expensive: true), "a hotspot is Wi-Fi, but expensive")
        XCTAssertFalse(DataSaver.isMetered(cellular: false, expensive: false))
    }

    @MainActor
    func testTheSettingsDefaultToOffAndKeepWhatWasChosen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DataSaverTests"))
        defaults.removePersistentDomain(forName: "DataSaverTests")
        let fresh = AppSettings(defaults: defaults)
        XCTAssertEqual(fresh.crossfadeSeconds, 0)
        XCTAssertFalse(fresh.dataSaver)
        fresh.crossfadeSeconds = 6
        fresh.dataSaver = true
        let reopened = AppSettings(defaults: defaults)
        XCTAssertEqual(reopened.crossfadeSeconds, 6)
        XCTAssertTrue(reopened.dataSaver)
        defaults.set(7, forKey: "settings.crossfade")
        XCTAssertEqual(AppSettings(defaults: defaults).crossfadeSeconds, 0, "not a choice: off")
        defaults.removePersistentDomain(forName: "DataSaverTests")
    }

    func testTheTranscodeRequestIsTheOneCheckedAgainstPlex() {
        let client = PlexClient(endpoint: PlexEndpoint(baseURL: URL(string: "http://192.168.1.20:32400")!, kind: .local,
                                                       machineIdentifier: "m", token: "secret"),
                                identity: PlexIdentity(clientIdentifier: "c1", version: "1", platformVersion: "27", deviceName: "d", model: "iPhone"))
        XCTAssertEqual(client.transcodeURL(ratingKey: "4242", session: "s-1").absoluteString,
                       "http://192.168.1.20:32400/music/:/transcode/universal/start.m3u8?path=%2Flibrary%2Fmetadata%2F4242"
                       + "&mediaIndex=0&partIndex=0&protocol=hls&directPlay=0&directStream=0&musicBitrate=192&maxAudioBitrate=192"
                       + "&session=s-1&X-Plex-Client-Identifier=c1&X-Plex-Product=Truffle&X-Plex-Platform=iOS&X-Plex-Token=secret")
    }

    func testQueuesSavedBeforeShuffleWasRememberedStillRestore() throws {
        let old = Data(#"{"kind":"playlist","title":"Road Trip","id":"901","albumInOrder":false}"#.utf8)
        let source = try JSONDecoder().decode(PlaySource.self, from: old)
        XCTAssertEqual(source.title, "Road Trip")
        XCTAssertFalse(source.shuffled)
        let older = try JSONDecoder().decode(PlaySource.self, from: Data(#"{"kind":"shuffleAll","title":"Shuffle All"}"#.utf8))
        XCTAssertTrue(Crossfade.isShuffle(older), "Shuffle All is a shuffle whatever was saved")
        let roundTrip = try JSONDecoder().decode(PlaySource.self, from: JSONEncoder().encode(
            PlaySource(kind: .playlist, title: "Road Trip", id: "901", shuffled: true)))
        XCTAssertTrue(roundTrip.shuffled)
    }
}
