# Working on the client core in MoonBit (for agents)

The first slice of still.fail's client core in MoonBit, on the base (`libs/base`): what the TypeScript core
(`client/core-ts`) does, written again where the app is to run it in its own process instead of in Hermes. Nothing
runs it yet. A moon module of its own, `client_core`, whose workspace (`moon.work`) takes the base and mbui (for
`effect`).

## Its parts

- `src/store`: what is kept on the device, read from an account's database (`databases/<account>.db`, the tables
  `client/core-ts/src/db/schema.ts` makes) through the base's `sql` (`@sql.Sql`, `@sql.Burst`). `md.mbt` is
  `MdStore`, the trees of Markdown kept (`md_kept`) and the logs opened (`log_use`), as `client/core-ts/src/data.ts`
  `mdStore` and `flushMd` keep them; `window.mbt` is what a chat opens on (`entry_min_rows`, `first_shown_window`:
  `client/core-ts/src/station/topics.ts` `entryMinRows`, `#firstShown`); `open.mbt` opens a chat (`open_chat`).
- `src/outbox`: `FrameOutbox[T]`, what the core hands the frames: typed values, never JSON, taken once a frame.

## Its rules

- Opening a chat writes nothing before its first view is made: a tree read or shown, a log opened, is pending in
  `MdStore` and written in one transaction after (`MdStore::flush_turn`, by the core's turn, and as it closes). Its
  trees are read in one statement (`MdStore::preload`), and the statements it runs do not grow with the chats the
  account holds (`src/store/cold_open_wbtest.mbt` holds all three).
- What the core hands the window goes through `FrameOutbox`: `tell` from the core's runtime, `take` from mbui's
  `@ui.on_frame_take`, its `wake` mbui's `@ui.wake_frame`. Nothing is serialised between the two.
- What it shares with the TypeScript core (the tables, `md_kept`'s keys `md_key`, how many rows a message takes at
  least) is the same as there: change both together.
- A package here imports the base, mbui's `effect` and MoonBit's core; never mbui's UI packages.

## Working here

- Never run `moon check` or `moon info` on the whole workspace, nor `moon fmt` (it would rewrite mbui's and the base's
  files). By package, writing no interface: `moon check --no-mbti --target native src/store` (and `--target js`),
  `moon test --target native src/store`. `scripts/check.sh` runs every package on both.
- A compiler warning is an error or off (`moon.mod`'s `warnings`, the base's line).
- Tests run on a database stood in (`src/store/fake_wbtest.mbt`: `@shell.Shell::stood_in` answering the statements
  this module runs from tables in memory), natively and on js, no SQLite linked: a statement it does not know fails the
  test, so a new one is taught there.
