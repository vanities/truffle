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
  Playback/   PlayerEngine (AVQueuePlayer, gapless preload), PlayQueue (pure rules), Loudness,
              PlexReporter (timeline), NowPlayingController, ArtworkCache, AudioSessionManager
  CarPlay/    CarPlaySceneDelegate, CarPlayInterface (Home grid, Playlists, Library; Now Playing heart)
  Views/      Root, SignIn, Home, Library, Search, Player, Settings, Components (SeasonalBackdrop…)
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
- On Adam's network the plain `http://<LAN IP>:32400` address answers first; the `*.plex.direct`
  names may not resolve at home, which is why `PlexServerInfo` adds the plain address.

## Conventions

- Swift 5 language mode, `SWIFT_STRICT_CONCURRENCY = complete`; `@MainActor @Observable` models,
  Sendable value types and actors off main. Fix concurrency warnings, don't silence them.
- Logging: `os.Logger` categories in `Logger+Truffle.swift`, `[scope]`-prefixed, timed with `Stopwatch`.
- UI is native iOS 26+ Liquid Glass. Colors come from the season (`SeasonTheme`); keep hit targets
  ≥ 44 pt, this is used in cars.
- iPhone Duo: the player is an `ArrangementView` split under `IPHONE_DUO_LAYOUTS` (27.1+ SDK), Home
  goes two-column at regular width. See docs/iphone-duo.md.

## Releasing

- `MARKETING_VERSION` lives in project.yml (then `make gen`). 1.0.0 is the first App Store release.
- Xcode Cloud workflow "Default", like Earmark's: every push to `main` archives an App Store build that
  lands in TestFlight. Xcode Cloud numbers builds itself, from 1. The workflow lives in App Store
  Connect, not in this repo; the first one has to be created from Xcode (Integrate → Create Workflow),
  because the API can't create an Xcode Cloud product.
- The listing: `uv run --script scripts/appstore.py setup` (idempotent), `screenshots marketing/iphone`,
  `screenshots marketing/ipad`, `attach-build`, `submit`, `status`. App Privacy ("Data Not Collected")
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
