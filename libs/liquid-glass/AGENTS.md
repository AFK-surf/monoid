# The liquid glass library in mbui (for agents)

A component library of its own beside mbui (`libs/mbui`), which it alone imports: layout, motion and interaction
structure ported from Kyant0/AndroidLiquidGlass's catalog (`catalog/components`, `catalog/utils`, `catalog/destinations`;
Apache-2.0), with all glass materials unified on mbui's iOS 27 `flutter_liquid_glass` `@paint.Glass::liquid` optical
model (uniform blurred backdrop, quarter-circle bevel refraction, adaptive iOS 27 light/dark/clear color transfer,
inner bevel shadow, glint, and 0.75pt external contour). mbui is the framework and holds no look; a library holds the
looks; an app uses a library.

- Design specification (`DESIGN.md`): strict two-layer material architecture (Content Layer with zero `Glass::liquid` vs.
  Floating Liquid Glass Layer with single-layer `Glass::liquid`), hard zero glass-on-glass invariant enforced by
  `Tester::drawn_glass()` (`assert_no_nested_glass` in `src/lg/kit_overlays_wbtest.mbt` and
  `src/pages/gallery_wbtest.mbt`), concentric corner ladder (`R_inner = R_outer - pad`, 0 faults), WCAG >= 4.5:1 contrast
  with zero `alpha == 0` hidden glass instances at rest, and closed-form `@headless` controls.
- `src/lg` is the library (35 Liquid Glass components across controls, inputs, navigation, overlays, feedback and
  physics; token files `tokens.mbt`, `tokens_controls.mbt`, `tokens_overlays.mbt`); `src/pages` holds the self-hosted
  fullscreen component library (`library.mbt`, the default entry when `MBUI_LG_PAGE` is empty) plus the gallery's pages
  (`pages.mbt`: overview, dialog, interactive: the overview with every part held, film: what the film drags, merge) and
  the gallery round them (`gallery.mbt`: a bar of glass choosing the page and the look on non-`library` pages), shown by
  `src/gallery` in a window (`MBUI_LG_PAGE`, `MBUI_DARK=1`, `MBUI_LG_CHROME=0` no bar;
  `APP=gallery MBUI_APP_MOD=libs/liquid-glass libs/mbui/scripts/mac.sh run`) and in the browser (`scripts/web.sh [OUT]`,
  the settings in the page's query, as ui.monoid.build/liquid-glass/app/ serves it), and drawn by `src/shots` offscreen
  (`MBUI_LG_SHOTS=<dir>`, `MBUI_LG_ONLY=<library|library-film|page|film|gallery>`: the self-hosted library shots and
  60 fps demo, each page light and dark at 3×, the gallery with its bar, and a 60 fps film of the parts held and
  dragged, mbui's `@film.picture` and `@film.film`). `scripts/check.sh` is its check, CI's `check-liquid-glass`.
- `page` draws each page as the shots always have: the gallery only adds room over it (`top`), so `src/shots`' page
  pictures stay the same byte for byte.
- It is released on its own as ui.monoid's Liquid Glass under Apache-2.0 (`LICENSE`, `NOTICE` naming the catalog's
  revision, `README.md`): a part added or renamed is said in the README's table.
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
