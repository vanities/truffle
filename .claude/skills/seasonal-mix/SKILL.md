---
name: seasonal-mix
description: Make a seasonal mix from Adam's Plex library as a Plex playlist with generated cover art, which Truffle plays for that season's card. Use when Adam asks for a mix for a season, holiday or year ("make the Halloween mix", "do a Christmas 2026 mix", "fall mix", "Thanksgiving playlist", "redo winter"), or says /seasonal-mix.
---

# Seasonal mix

One playlist per theme per year, titled "<emoji> <Theme> <Year>" (🎃 Halloween 2026). Each year's mix
stays on the server as a keepsake; asking again for the same theme and year refreshes it in place.
Truffle finds mixes by the `truffle-mix:<theme>:<year>` tag at the end of the playlist summary, and
plays this year's for the season's card on Home and in the car.

Themes: halloween, fall, thanksgiving, christmas (xmas, holidays), winter, newyear, valentines,
stpatricks (stpats), spring, fourthofjuly (fourth, july4; Truffle shows it in the US only), summer. `uv run --script scripts/plex_mix.py themes` lists their moods and keywords; add one
to `THEMES` in that script for anything new.

## Steps

1. **Theme and year.** From the request; the year defaults to this year. `scripts/plex_mix.py existing`
   shows what's already made.
2. **Candidates.** `uv run --script scripts/plex_mix.py candidates <theme> --year <year>` prints one
   line per song with why it's there: `mood` (album mood tags), `word:<w>` (a seasonal word in the
   title), `history×N` (played N times around this date in earlier years), `♥` (liked).
3. **Pick 40–60 songs, with taste.** This is the part that matters. Read the list like a DJ:
   - Songs that are *about* the theme first (titles, and what you know of the song or soundtrack), then
     ones that only *feel* like it. A spooky title on a cheerful pop song doesn't belong in Halloween.
   - Lean on history: what Adam actually played this time of year is what he'll want again.
   - Mix favorites (♥, history) with a few deep cuts. At most 3 songs per artist, never two in a row.
   - Sequence it: an inviting opener, build to the big ones in the middle, ease out at the end.
   - Skip anything over 10 minutes unless it's the point, and anything that's clearly an intro, skit or
     sound effect.
   Keep the ids in play order.
4. **Art from the songs.** Write one prompt from what the picks have in common: the instruments,
   the moods, a character that fits (a jack-o'-lantern DJ, a turkey with headphones). House style is
   cute and a little silly, flat vector, no text (the script adds that).
   `uv run --script scripts/plex_mix.py art <theme> --year <year> --prompt "<prompt>"`. Look at the
   image before using it; regenerate if it has text or reads muddy at small sizes.
5. **Make it.** `uv run --script scripts/plex_mix.py create <theme> --year <year> --ids <id,id,...>
   --art build/mixes/<theme>-<year>.jpg --blurb "<one short silly line>"`. It prints the song count,
   whether the summary carries the tag, and whether the custom poster took.
6. **Tell Adam** in a few lines: the title, how many songs, three or four highlights, and the art
   (build/mixes/<theme>-<year>.jpg). Copy stays short and playful, never explanatory.

## Care

- Every Plex call runs inside the NAS's `plex` container with the token read there; never print it,
  and never print `/status/sessions` (it names sessions after tokens).
- Art uses Adam's OpenAI key (`OPENAI_API_KEY` in ../game/.env) with gpt-image-2, per his instruction.
- Don't delete other playlists. Refreshing a mix only replaces that playlist's own songs.
