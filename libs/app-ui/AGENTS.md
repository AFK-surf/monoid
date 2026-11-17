# app-ui (for agents)

A component library of its own beside mbui (`libs/mbui`), which it alone imports: dense, adaptive parts for any app
on mbui, of no product (no product's name, word or look is written here). mbui is the framework and holds no look;
this library holds one; an app uses it.

- `src/appui` is the library: room (`space.mbt`: eight steps, three gutters, concentric corners), words
  (`type_scale.mbt`: five roles at a root the app says, on whole device pixels, `whole_rem`), colour (`theme.mbt`:
  OKLCH from a brand's hue, light and dark), icons, and the parts. `src/specimen` lays every part out in its states,
  wide and narrow, and its tests hold those pages to mbui's audit; `src/shots` draws them offscreen
  (`MBUI_APP_MOD=libs/app-ui APP=shots MODE=debug libs/mbui/scripts/ext-film.sh picture|film NAME DRIVE`, on a Mac;
  `APPUI_PAGE=narrow`, `MBUI_DARK=1`, `MBUI_WIN=960x720`). `scripts/check.sh` is its check, run by mbui-ci's `test` job.
- Every part is a node of mbui's window's tree (`libs/mbui/src/view`), never an old view, and is a look over mbui's
  headless component where there is one (the button and a pressed row over `@headless.button`, the switch and the
  checkbox over `@headless.toggle`, the segmented control over `@headless.radio_group`): it says no role, press or
  focus of its own. `detlint.json` allows none of the old view's debts (every count 0).
- A part names its room by a step (`Space`), never a number of its own, so the distance between two things is said
  once. Where something lies in a rounded box's corner it is as round as that box less how far in it lies
  (`concentric_radius`: a card 12 round keeps 6 round its rows and buttons, which are 6 round); nothing is cut to
  look concentric.
- Beside a block of several lines, an icon or what ends a row sits in a box as tall as the first line and centred in
  it; what is under the first line starts where its words do (`list_row`). A card's actions wrap the other way
  (`card_footer`), the main one first, so it stays at the card's foot on its left. A column some of whose parts hide
  draws a line only between two that show (`divided_column`).
- A button where an icon leads (or ends) it stands that icon a step less in (`Space::less`) by a margin below 0 on the
  icon, its padding the same at both ends: mbui's gap rule 4 measures a drawing by its room, so the two ends are
  held alike as they look.
- mbui's rules hold here as in an app (`libs/mbui/AGENTS.md`): tests declare their moments, warnings are errors or off
  (`moon.mod`'s line), no Python; pictures for people come from mbui's offscreen film, never a window's screenshot.
