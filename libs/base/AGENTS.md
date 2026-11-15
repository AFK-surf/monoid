# Working in the base (for agents)

The first of the base in MoonBit: what a client's core stands on where the core is MoonBit, written once and shared
(the user, 2026-11-14: still.fail's own core is to move to MoonBit, 「以后 still fail 也会切 mb」, and a module is
written once for both sides, 「这样两边共用」). A moon module of its own, `base`, which takes mbui's `effect` as a member
of its workspace (`moon.work`); `effect` stays in mbui.

## Its parts

- `src/shell`: the binding of the Rust shell (`client/shell`, through its C interface) for a program on `@effect`:
  `shell.mbt` is the surface, shared across `shell_native.mbt` (with `shell.c`), `shell_js.mbt` (with `client/iroh-wasm`
  and browser APIs), and `Shell::stood_in` for deterministic tests.
- `src/wire`: pure stream framing and event-stream parsing (`lines`, request/reply heads, SSE text) with no transport.
- `src/mesh`: the device side of the mesh on top of `shell` and `wire` (endpoints, scoped peer links, hello/pings/renewal,
  requests/streams/duplex, health racing in `health.mbt`, and wake/rebind in `wake.mbt`).

## It knows no program

- Not still.fail's app, station or cloud, and not any specific application. Everything program-specific is passed in via
  `Options`, `Mesh::link` (`scope`), `Mesh::drop_link` (`reason`), and `Shell::start`.
- `scripts/mb-base.ts` (`scripts/check.sh`) enforces that packages import only their own packages, `mbui/effect`, and
  MoonBit's core, and that no line under `src/` names `still.fail` or application-specific vocabulary (`member`,
  `conversation`, `im`). Legacy exceptions in `NAMED` (`sf_shell_start`, etc.) may only shrink; never add a name chosen
  by this library, and ask the owner before adding any external symbol.
- The station's MoonBit programs keep their own host binding (`station/mb/src/host`) until moved onto this base whole.

## What is checked here, and what is not

- On commit/push and in CI (`check-linux`): `scripts/mb-base.ts`, `scripts/mb-base-words.ts --check` (verifying
  `src/mesh/words_made.mbt` against `client/core-ts/src/lang.{zh,en}.json` `core-logic.mesh.*`), and
  `scripts/mb-base-sse.ts --check` (verifying `src/wire/sse_made_test.mbt` matches `client/core-ts/src/sse.ts` byte for
  byte). Edit the source files and run the generator scripts; never hand-edit `words_made.mbt` or `sse_made_test.mbt`.
- In CI and full checks: every package under `src/` is type-checked and tested on both `native` and `js` targets using
  `Shell::stood_in` (`src/mesh/stood_wbtest.mbt`) on the test's deterministic clock.
- No Rust shell or real network is linked in unit tests (`shell.c` is compiled as a stub only, and `extern "js"` iroh
  glue in `shell_js.mbt` runs only in real browser/e2e suites outside this repo). When changing `src/shell` or what
  `src/mesh` asks of a shell, state what external suite or environment verified it.

## Working here

- Never run `moon check` or `moon info` on the whole workspace (which would rewrite `mbui`'s `.mbti` files). Check and
  test by package:
  - `moon check --target native src/mesh` (and `--target js`)
  - `moon test --target native src/wire`
  The committed `pkg.generated.mbti` files are from the `native` target.
- A compiler warning is an error or off (`moon.mod`'s `warnings`, matching `libs/mbui`).
- Fiber interruption and shell lifetimes:
  - `catch` does not catch fiber interruption; cleanup on interruption belongs in `defer`, and `Mesh::close` explicitly
    notifies all pending openings, live links, and waiting dialers before cutting fibers so nothing hangs if cut before
    its first step.
  - Only a dial can be cancelled in the shell (`Shell::give_up`). An interrupted stream read or write leaves the shell
    stream unusable, so interrupted streams must be reset (`Reply::cancel`, `Out::write`), and control-stream exchanges
    (`Mesh::ping`, `Mesh::race`) or stream opens/accepts (`Link::stream`, `Link::accept`) run in the mesh's own fibers.
  - `Mesh::rebind` only rebinds the endpoint when `Mesh::idle` reports nothing active on it; callers never cache the
    endpoint handle across waits.
  - Native device keys written by the Rust shell are `0600` (`create_private`), and `shell.c` requires POSIX (`pthread`,
    `arc4random_buf`, glibc >= 2.36 on Linux).
