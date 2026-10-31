# iPhone Duo

Same approach as Earmark and Mango (see ../earmark/docs/iphone-duo-testing.md for the simulator
toolchain, hinge control and per-display capture).

- `IPHONE_DUO_LAYOUTS` is set for the 27.1 and 27.2 SDKs in `project.yml`.
- The player's cover and controls are an `ArrangementView` (`.split`, ratio 0.5): one panel each on
  an open Duo; stacked on a phone or a closed Duo. The top bar sits outside it, because on a phone
  the arrangement stacks and would otherwise push the close button below the cover.
- The player opens full screen at regular width and on the Duo, so the split gets the whole display.
- Home switches to two columns at regular width: Shuffle All beside the season's mixes.

Not yet checked on the Duo simulator (next step: open, book and closed poses, inner display 3).
