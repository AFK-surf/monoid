# The liquid glass library in mbui (for agents)

A component library of its own beside mbui (`libs/mbui`), which it alone imports: Kyant0/AndroidLiquidGlass's catalog
(`catalog/components`, `catalog/utils`, `catalog/destinations`; Apache-2.0) ported 1:1 to mbui's window tree. mbui is
the framework and holds no look; a library holds the looks; an app uses a library.

- `src/lg` is the library; `src/pages` the gallery's pages (overview, dialog, interactive: the overview with every part
  held, film: what the film drags), shown by `src/gallery` in a window (`MBUI_LG_PAGE`, `MBUI_DARK=1`;
  `APP=gallery MBUI_APP_MOD=libs/liquid-glass libs/mbui/scripts/mac.sh run`) and drawn by `src/shots` offscreen
  (`MBUI_LG_SHOTS=<dir>`, `MBUI_LG_ONLY=<page|film>`: each page light and dark at 3×, and a 60 fps film of the parts
  held and dragged, mbui's `@film.picture` and `@film.film`). `scripts/check.sh` is its check, CI's
  `check-liquid-glass`.
- It is a 1:1 port: every number (colours, sizes, springs, lens heights and amounts, highlight styles, shadows, the
  jelly squeeze) is the catalog's, said where it is used with the Kotlin it comes from, and every file ported from it
  says so in its head (`Ported from Kyant0/AndroidLiquidGlass (Apache-2.0)`). A change of look starts from the catalog's
  source, not from a picture. Where mbui cannot yet draw what the catalog draws (a lens seeing a backdrop scaled or
  moved: the toggle's and slider's combined backdrop, the magnifier's 1.5× zoom; the tabs' accent row drawn only into
  the lens's backdrop), the part says so in its head and draws the nearest mbui has.
- Motion is mbui's closed-form ways (`@motion.NodeWay`, `@motion.spring`, `View::at_moment`): DampedDragAnimation and
  InteractiveHighlight (`damped_drag.mbt`, `interactive_highlight.mbt`) are ways set off from their cause's moment,
  never a frame loop, so a run draws the same at 60, 120, 24 and 7 fps (`parts_wbtest.mbt` holds it).
- What a control is to the hand, the keys and a screen reader is mbui's headless component's (`libs/mbui/src/headless`):
  the button and the dialog's buttons over `@headless.button`, the toggle and the control item over
  `@headless.toggle`, the slider over `@headless.slider`, the bottom tabs over `@headless.radio_group` (a tab list), the
  dialog over `@headless.dialog`. A finger's drag on a part's glass is `View::gesture` (press, tap, drag), never
  `on_drag` on a headless node (detlint `headless-on-drag`).
- A part's springs can be held by its caller (`drag?`, `light?`: a `DampedDrag` or `InteractiveHighlight` made by the
  caller and pressed by it): the interactive page draws every part held that way.
- mbui's rules hold here as in an app (`libs/mbui/AGENTS.md`): tests declare their moments, warnings are errors or off
  (`moon.mod`'s line), maths is `@dmath`'s, no Python.
