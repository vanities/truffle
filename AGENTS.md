# Truffle — agent guide

> `CLAUDE.md` is a symlink to this file.

Truffle is an iOS music player for Plex (SwiftUI, iOS 26+, no dependencies). It exists because
Plexamp's CarPlay is crowded and its shuffle isn't random. The home screen and the car show only
what gets used: Shuffle All, Liked, the season's mixes, playlists and the library.

## Non-negotiables

- **Shuffle All is a true shuffle.** `ShuffleWalk` is a uniformly random order over every song,
  one round before any repeat, saved across launches. Nothing weights it: not ratings, plays,
  popularity or artist spacing. (Plex's server-side "smart shuffle" does all of those, which is
  what drove Adam off Plexamp's random.) `ShuffleWalkTests` checks uniformity with chi-square.
- **Only buttons Adam uses.** No stations, no lyrics, no library switcher on screen (the library is
  picked automatically; Settings has the picker only when the server has several), no promos.
- **Never log a token or a full stream/artwork URL** (those carry `X-Plex-Token`). Log paths.
- **Test runs against Adam's real server play muted** (`-TruffleMute YES`) and stop before 90% of a
  song, so tests don't add plays to his history (the seasonal mixes read it).

## Layout

```
Truffle/
  App/        TruffleApp, AppEnvironment (composition root shared with CarPlay)
  Plex/       PlexClient (server), PlexAccountClient (plex.tv PIN sign-in, resources),
              ConnectionPicker (home network > remote > relay, raced), PlexQuery, PlexModels, Keychain
  Models/     Track/Album/Artist/Playlist, AppSettings
  Library/    MusicLibrary (+Browse, +Mixes, +Edits), ShuffleWalk, Seasons, Mixes, LibraryStore
  Playback/   PlayerEngine (two AVQueuePlayer decks: gapless preload, crossfades in shuffles), PlayQueue and
              Crossfade (pure rules), DataSaver (+ NetworkCost), Loudness, PlexReporter (timeline),
              NowPlayingController, ArtworkCache, AudioSessionManager
  CarPlay/    CarPlaySceneDelegate, CarPlayInterface (Home grid, Playlists, Library; Now Playing: back 15,
              heart, repeat, and the album name opens the album)
  Demo/       DemoServer + DemoLibrary: "Take it for a spin", the invented library served on 127.0.0.1
              from inside the app (a port of scripts/demo_server.py; assets in Resources/DemoLibrary)
  Views/      Root, SignIn, Home, Library, Search, Player, Settings, Components, Seasonal (the backdrop,
              its sky events, the props resting on Home's cards)
TruffleTests/ shuffle uniformity, query encoding, decoding, seasons, mixes, queue, loudness, connections
scripts/      demo_server.py + demo-catalog.json + make-demo-covers.swift (a stand-in Plex server),
              appstore.py (App Store listing), testflight.py (uploads, groups, Xcode Cloud runs),
              asc.py (bundle ID), render-store-screenshots.py, generate-art.py, plex_mix.py, render-icon.swift
marketing/    store screenshots: raw captures (raw/iphone, raw/ipad), framed sets, screenshots.json
```

## Build / run / test

`project.yml` is the source of truth: edit it, then `xcodegen generate` (`make gen`). The project
file is committed. Use the dedicated "Truffle" simulator (iPhone 18 Pro, iOS 27.2); its UDID is in
`build/.sim-udid` after `make sim`.

```bash
make test                 # unit tests
make demo-library         # covers (Swift) + audio (ffmpeg) into ./demo-library (gitignored)
make demo-server          # stand-in Plex server on :32499 (needs demo-library)
make demo                 # build, install, launch against the demo server
```

The demo server answers the requests Truffle makes the way PMS 1.43 does, so the whole app (mixes,
history, likes, playlists, artwork, streaming) runs without a Plex account. Screenshots for anything
public come from it, never from Adam's library.

The app carries the same library inside it: "Take it for a spin" on the sign-in screen starts
`DemoServer` on 127.0.0.1, and that's how App Review gets in (they have no Plex server). Its history runs
up to today, where the Python server's ends on 2026-10-29. **When Truffle starts asking the server for
something new, teach both demo servers to answer it**, or the demo, and App Review with it, breaks.
`-demo.active YES` launches straight into it; Sign Out leaves it.

Debug switches for playback: `-settings.crossfade 6`, `-settings.dataSaver YES`, `-TruffleCellular YES` (acts
as if on cellular), and `-TruffleScene crossfade|crossfade-cut|album`, which jump near the end of a song so the
transition shows in the logs within seconds. Taps from simulator automation often don't land; use these.

## Testing against Adam's real server

Adam approved testing with the Plex sign-in stored on the NAS (2026-10-30). Do it like this:

1. Fresh state: `xcrun simctl uninstall <udid> com.vanities.truffle; xcrun simctl keychain <udid> reset`.
2. Launch with `-TruffleMute YES`, tap Sign in with Plex. Debug builds log the PIN's link code
   (`[auth] pin code`, not a token).
3. Approve it from the NAS, inside the `plex` container, without printing the token:
   `PUT https://plex.tv/api/v2/pins/link` with `code=<link code>`, `X-Plex-Token` from
   Preferences.xml (`PlexOnlineToken`) and `X-Plex-Client-Identifier` = the server's
   `ProcessedMachineIdentifier` (so no new device shows up on the account). Truffle's polling picks
   up the token and closes the browser sheet.
4. Never print `/status/sessions` raw: the server names Truffle's session `token=<token>`.

## Plex API notes (checked against PMS 1.43.5, 2026-10-30)

- Comparison filters go in the parameter name, with `>`/`<` percent-encoded and `=` literal:
  `viewedAt%3E=…` works, `viewedAt%3E%3D…` is a 400 (`PlexQuery`).
- `forwardUrl` with an app scheme (`truffle://`) makes app.plex.tv/auth skip the sign-in form and land
  on watch.plex.tv. Don't send one; polling handles it.
- Loudness (`gain`, `loudness`, `albumGain`) is only in `/library/metadata/{ids}`; lists leave
  streams out. The player fetches details for the next few songs.
- `sort=id` gives a stable order where new songs append, which is what makes `ShuffleWalk`'s
  positions survive library growth. `sort=random` is fine for sampling mood pools.
- Moods live mostly on albums (`album.mood=`); `,` is OR. Plex's photo resizer is `/photo/:/transcode`.
- Data Saver's transcode: `GET /music/:/transcode/universal/start.m3u8?path=%2Flibrary%2Fmetadata%2F<id>&…&protocol=hls&musicBitrate=192&session=<per song>`
  answers an HLS multivariant playlist with one 182 kbps variant at `session/<session>/base/index.m3u8`;
  `GET /video/:/transcode/universal/stop?session=` ends it (`PlexClient.transcodeURL`). `start.mp3` ignores
  byte ranges, so HLS it is. It needs `X-Plex-Client-Profile-Extra=add-transcode-target(type=musicProfile&…)`
  as one escaped value: without it PMS answers 400 now and then ("No conversion profile found for protocol
  hls"). The variant and its MPEG-TS segments answer without the token. A transcode that fails plays the
  original instead; two in a row rest Data Saver for 5 minutes (`TranscodeHealth`). Stopping a session that
  never started is a 404. The demo servers serve each song as one segment (moov first, or AVPlayer can't
  read it) and turn down a request without the profile; `-TruffleTranscodeFails YES` (in-app) and
  `DEMO_TRANSCODE_FAILS=1` (Python) turn them all down, to watch the fallback.
- On Adam's network the plain `http://<LAN IP>:32400` address answers first; the `*.plex.direct`
  names may not resolve at home, which is why `PlexServerInfo` adds the plain address.

## Seasons

`Library/Seasons.swift` decides what's seasonal right now: the season, a moment on top (Halloween,
Thanksgiving, the holidays, New Year, Valentine's, St. Patrick's, the Fourth of July), colors, greeting,
particles, `Decor` (moon, pumpkins, snow caps, sleigh, fireworks, rainbow, butterflies, wind, sunbeams,
aurora, bats, shooting stars) and the mix's moods. The Fourth only shows where `Locale.current.region` is the US or a US territory; elsewhere early
July is summer.

`Views/Seasonal/` draws it. Everything moving runs on one clock, `SeasonalTimeline` (30 fps), stopped when
effects are off, the screen sets `seasonalInView` false (Home: scrolled away, or the player on top), another
tab or page is on top, or the app isn't active; Reduce Motion gets a still frame without the occasional
events. The sky is one `Canvas` per frame (`SeasonScene`), a pure function of time. Those events
(`EventSchedule`) are too: Santa about once a minute, fireworks now and then, a rainbow, gusts of wind, a
bat past the moon, shooting stars. `SeasonScene+Atmosphere.swift` has the wind (a gust's push is
`EventSchedule.runningCount`, which only climbs, so leaves never snap back; blown off one side, they wrap
round out of sight), the spring sunbeams, the winter aurora, the bat and the shooting stars. The pumpkins
and snow on the cards (`seasonalPerch`) sit inside the cards' buttons and never take taps.

The glows (`Glows.swift`) ease, never blink, and `GlowTests` fails any frame-to-frame jump: the string
lights run like a light controller (`LightShow`: twinkle, chase, slow fade, waves, color by color, 15 s
each), and the jack-o'-lantern's candle (`Candle`) swells, dims and flickers. The candle tints two masks
cut from the drawing (`generate-art.py glow`, run by `props jackOLantern`); a test checks they still sit
on its carved face.

Debug launch arguments: `-TruffleDate 2026-12-15T19:00` fakes the date; `-TruffleFlyby YES`,
`-TruffleFireworks YES`, `-TruffleRainbow YES`, `-TruffleGust YES`, `-TruffleBat YES` and
`-TruffleShootingStar YES` start that event two seconds in and repeat it every 14 seconds, for captures.
A date whose theme uses another app icon raises iOS's "You have changed the icon" alert, and the
animations pause behind it: launch twice before recording. Art: `scripts/generate-art.py mixes <key>` (covers), `props <key>` (pumpkins,
the sleigh) and `glow` (the candle's masks). gpt-image-2 has no transparent output, so props are drawn
on a flat color and keyed out.

## Conventions

- Swift 5 language mode, `SWIFT_STRICT_CONCURRENCY = complete`; `@MainActor @Observable` models,
  Sendable value types and actors off main. Fix concurrency warnings, don't silence them.
- Logging: `os.Logger` categories in `Logger+Truffle.swift`, `[scope]`-prefixed, timed with `Stopwatch`.
- UI is native iOS 26+ Liquid Glass. Colors come from the season (`SeasonTheme`); keep hit targets
  ≥ 44 pt, this is used in cars.
- iPhone Duo: the player is an `ArrangementView` split under `IPHONE_DUO_LAYOUTS` (27.1+ SDK), Home
  goes two-column at regular width. See docs/iphone-duo.md.

## Releasing

- `MARKETING_VERSION` lives in project.yml (then `make gen`). 1.1.0 is the first App Store release: 1.0.0 was
  pulled from review before it started (2026-10-31) so everything since could launch with it. `appstore.py`'s
  `VERSION` names the version `setup` edits, and renames it to.
- Xcode Cloud workflow "Default", like Earmark's: every push to `main` archives an App Store build that
  lands in TestFlight. Xcode Cloud numbers builds itself, from 1. The workflow lives in App Store
  Connect, not in this repo; the first one has to be created from Xcode (Integrate → Create Workflow),
  because the API can't create an Xcode Cloud product.
- The listing: `uv run --script scripts/appstore.py setup` (idempotent), `screenshots marketing/iphone`,
  `screenshots marketing/ipad`, `attach-build`, `submit`, `cancel` (pull it back out of review), `status`. App Privacy ("Data Not Collected")
  can only be set on the web.
- Store screenshots come from the demo server. Launch a debug build with
  `-TruffleScene home|mixes|player|albums|icons` on a 6.9" iPhone (1320x2868) and a 13" iPad
  (2064x2752) simulator, save captures to `marketing/raw/{iphone,ipad}/`, then
  `uv run --script scripts/render-store-screenshots.py`. A fresh simulator's first launch shows iOS's
  "You have changed the icon" alert, which UI automation can't dismiss; relaunch.
- `make testflight` archives and uploads from this Mac, for when Xcode Cloud isn't an option.

## Apple setup

- Bundle ID `com.vanities.truffle` is registered (ASC API, `scripts/asc.py`). The App Store Connect
  app record ("Truffle: Music Player for Plex") can't be created through the API (403 "apps does not
  allow CREATE"); Adam made it on the web.
- CarPlay audio is enabled on the App ID (in the developer portal; the API rejects that capability type).
- Public TestFlight link: https://testflight.apple.com/join/ZXeFFhZM (the External group).
