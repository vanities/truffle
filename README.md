# Truffle

A music player for your Plex server, made for the car.

- **Shuffle All that's actually random.** Every song in your library, in a uniformly random order,
  one round before anything repeats. No favoring what's rated, popular or recently played.
- **A CarPlay screen with only what you use:** Shuffle All, Liked, the season's mixes, your
  playlists and your library. Now Playing has one extra button: the heart.
- **Mixes for the season.** Your library's own mood tags make a Halloween mix, a fall mix, holiday,
  New Year, Valentine's and summer mixes; your play history makes "This Time Last Year" and your
  favorites from seasons past. The app's colors and the little falling things change with them.
- **Plays your files as they are,** FLAC included, straight from your server, with volume evened out
  from Plex's loudness analysis. It moves to your server's public address when you drive away from
  home Wi-Fi.
- Playlists, likes, artists, albums and search, all synced with Plex.

GPL-3.0. Made by AM2 LLC.

## Building

```bash
brew install xcodegen
make gen && make test
make demo-library && make demo-server   # a stand-in Plex server with invented music
make demo                                # run against it in the simulator
```

Device builds need a team: copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig`.
