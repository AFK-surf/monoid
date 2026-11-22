# still.fail's parts in mbui (for agents)

still.fail's design system as a component library beside mbui (`libs/mbui`): `src` (`stillfail/sf`, `@sf`) holds the parts
still.fail's app (`apps/mbui`) is made of, and `src/glass` (`stillfail/sf/glass`, `@glass`) holds its liquid glass
material recipes, physics, surface decorators, and glass controls. It lived inside `apps/mbui` till it was made a
module of its own (`name = "stillfail/sf"`), so that a program outside still.fail's app (a workspace of another
repository: `moon.work` naming `libs/sf-ui` and `libs/mbui`, `moon.mod` importing `"stillfail/sf@0.1.0"`) uses
the parts still.fail itself ships and tests (左子健, 2026-11-17: 「感觉最好用有项目用的 UI 吧，不然都没人测」).

- It knows no app: it imports only mbui and MoonBit's core (detlint's `library-import`), and what it needs of an app
  (its words, the core's answers, its pictures) is given to it as the app starts. The rules of how its parts are made,
  look and move are the app's (`apps/mbui/AGENTS.md`: The component library, Made once as nodes, Motion) and mbui's
  (`libs/mbui/AGENTS.md`): they hold here as there.
- Its tests have no core: what they ask of the core's pure calls (`markdown`, `code.ink`, `reader.*`, `ref.words`) is
  answered from what the real core answered, kept beside them (`src/kept_wbtest.mbt`, `src/kept_test.mbt`, each
  a copy of the lines of the app's `apps/mbui/src/sfkept/kept.mbt` these tests ask). A test that asks one more fails
  saying which (`kept-answers-ask {…}`, `scripts/check.sh`): the core works it out into that file as it does the app's
  (those lines saved to a file, `node client/core-ts/scripts/kept-answers.ts <file>`), and its line is copied here.
- Some of its files are made, never edited: `src/palette_data.mbt` (`scripts/palette.ts`), `src/font_assets.mbt`
  (`apps/mbui/scripts/fontassets.py`), `src/math_glyphs.mbt` and `src/math.json` (`client/core-ts/scripts`'
  `math-font.ts`, `math-fixture.ts`), and `src/icon_data.mbt` (`apps/mbui/scripts/icons.py`). App-specific brand
  drawables live in `apps/mbui/src/sfbase/drawable_data.mbt` and register via `register_drawables` / `register_station_glyphs`.
- `scripts/check.sh` is its check, CI's `check-sf-ui`: the determinism lint with this module's `detlint.json` (its
  counts, as the app's, only fall), its packages type-checked on native and js, its tests on native.
- A `SourceLoc` of a part made here reads `stillfail/sf/src/<file>`: a test that names one (an audit's fault, what a node
  was made at) says it so.
- Only general parts and design atoms go in `src`: a part bound to one kind of the app's things (a station, an agent,
  a vault item, a login's step) is the app's, made in `apps/mbui` from these parts, so the library stays one any
  program can use.
- A public part here takes at most 8 arguments. One that needs more is split into a compound part with slots, as
  `src/row_compound_node.mbt` is (`row_box_node` and its `RowScope`'s parts), never grown further: `link_row_node`
  takes no new arguments, and a row that needs one more says it in parts.
- Outlined controls (`input_node`, `textarea_node`, `select_node`, `filter_pill_node`, `choice_card`, `accordion_card`,
  framed bar fields, swatch and avatar tiles) share one hairline edge (`B0_5`, `control_edge_w` in
  `src/control_edge.mbt`): `Line` at rest, `Border` pointed at or written in. `B2` in `Fg` is kept for a chosen ring.
