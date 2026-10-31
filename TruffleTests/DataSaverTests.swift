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

    func testTheTranscodeRequestIsTheOneCheckedAgainstPlex() throws {
        let client = PlexClient(endpoint: PlexEndpoint(baseURL: URL(string: "http://192.168.1.20:32400")!, kind: .local,
                                                       machineIdentifier: "m", token: "secret"),
                                identity: PlexIdentity(clientIdentifier: "c1", version: "1", platformVersion: "27", deviceName: "d", model: "iPhone"))
        let url = client.transcodeURL(ratingKey: "4242", session: "s-1")
        XCTAssertEqual(url.absoluteString,
                       "http://192.168.1.20:32400/music/:/transcode/universal/start.m3u8?path=%2Flibrary%2Fmetadata%2F4242"
                       + "&mediaIndex=0&partIndex=0&protocol=hls&directPlay=0&directStream=0&musicBitrate=192&maxAudioBitrate=192"
                       + "&session=s-1&X-Plex-Client-Identifier=c1&X-Plex-Product=Truffle&X-Plex-Platform=iOS"
                       + "&X-Plex-Client-Profile-Extra=add-transcode-target%28type%3DmusicProfile%26context%3Dstreaming"
                       + "%26protocol%3Dhls%26container%3Dmpegts%26audioCodec%3Daac%29&X-Plex-Token=secret")
        // One value, its ( ) & = escaped, so the server reads it back whole rather than as five parameters.
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "X-Plex-Client-Profile-Extra" }.map(\.value),
                       ["add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac)"])
        XCTAssertFalse(items.contains { ["type", "context", "container", "audioCodec"].contains($0.name) })
        XCTAssertEqual(items.filter { $0.name == "protocol" }.map(\.value), ["hls"], "only the request's own protocol")
    }

    func testAFailedTranscodePlaysTheOriginalAndAFailedOriginalRecovers() {
        XCTAssertEqual(DataSaver.onFailure(of: .dataSaver), .playOriginal, "Data Saver never costs a song")
        XCTAssertEqual(DataSaver.onFailure(of: .original), .recover, "retry, then skip, as before")
    }

    func testASongWhoseTranscodeFailedPlaysItsOriginalFromThenOn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var health = TranscodeHealth()
        XCTAssertEqual(DataSaver.mode(enabled: true, metered: true, song: "1", health: health, now: now), .dataSaver)
        XCTAssertFalse(health.failed("1", at: now), "one failure doesn't rest Data Saver")
        XCTAssertEqual(DataSaver.mode(enabled: true, metered: true, song: "1", health: health, now: now), .original)
        XCTAssertEqual(DataSaver.mode(enabled: true, metered: true, song: "2", health: health, now: now), .dataSaver,
                       "other songs still try")
        XCTAssertEqual(DataSaver.mode(enabled: true, metered: false, song: "2", health: health, now: now), .original, "Wi-Fi")
    }

    func testFailuresInARowRestTranscodesForAFewMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var health = TranscodeHealth()
        health.failed("1", at: now)
        XCTAssertTrue(health.failed("2", at: now.addingTimeInterval(30)), "the second in a row starts a rest")
        XCTAssertTrue(health.isResting(at: now.addingTimeInterval(31)))
        XCTAssertEqual(DataSaver.mode(enabled: true, metered: true, song: "3", health: health, now: now.addingTimeInterval(60)),
                       .original, "resting: originals for every song")
        let after = now.addingTimeInterval(30 + TranscodeHealth.rest)
        XCTAssertFalse(health.isResting(at: after))
        XCTAssertEqual(DataSaver.mode(enabled: true, metered: true, song: "3", health: health, now: after), .dataSaver,
                       "then Data Saver tries again")
        XCTAssertEqual(TranscodeHealth.rest, 300)
    }

    func testATranscodeThatPlaysEndsTheRunOfFailures() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var health = TranscodeHealth()
        health.failed("1", at: now)
        health.played()
        XCTAssertFalse(health.failed("2", at: now), "not in a row")
        XCTAssertFalse(health.isResting(at: now))
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
