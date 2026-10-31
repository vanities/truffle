# Finding Truffle by typing "plex"

Adam opens his music player by typing "plex" in the Home Screen search, so Truffle needs to answer
to that without "Plex" under its icon.

- `CFBundleDisplayName` is "Truffle" (what shows under the icon).
- `CFBundleName` is "Truffle for Plex". iOS indexes it for search even though it isn't shown under
  the icon: an Apple DTS engineer says so in
  [How to find renamed app using old name in Spotlight?](https://developer.apple.com/forums/thread/768054).
  It does show in some system prompts: the sign-in sheet's alert reads "Truffle for Plex Wants to
  Use app.plex.tv to Sign In" (seen 2026-10-30), which reads fine.
- An App Store install also indexes the App Store name ("Truffle: Music Player for Plex").

Not yet verified on a phone that typing "plex" lists Truffle from `CFBundleName` alone (a TestFlight
or Xcode install has no App Store record). Check that on the first device install.
