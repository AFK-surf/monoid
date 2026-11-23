# ui.monoid (`mbui`)

**`mbui`** is the cross-platform GPU-rendered UI framework powering **`ui.monoid`** (`https://ui.monoid.build`), written in [MoonBit](https://www.moonbitlang.com/).

One MoonBit core builds, lays out, and paints a retained UI tree and draws everything itself on the GPU, paired with thin native hosts that present frames and feed platform input across 6 targets:

- **macOS & iOS** — Metal + Core Text
- **Windows** — Direct3D 11
- **Android & Linux** — OpenGL ES (GTK 4 on Linux)
- **Web** — WebGL2 + Canvas / IME bridge

## Highlights

- **Retained window tree (`src/view`) + fine-grained signals (`src/signals`)**: build each node once and bind changing properties to signals so only affected work reruns.
- **Motion as data (`src/motion`)**: frame-rate-invariant transitions and layout animations (identical output at 60, 120, 24, or 7 fps).
- **Headless controls (`src/headless`)**: accessible behavior and keyboard/pointer state machines separated cleanly from visual design systems.
- **Standards-tested layout & text**: flexbox engine passing Yoga's test suite and Unicode-compliant text segmentation.
- **Deterministic testing (`Tester` + `FakeHost`)**: declare exact moments (`run_for`), audit layout invariants, and verify draw lists without linking a device host or opening a window.
- **Zero-C-toolchain packaging (`--runtime wasm`)**: bundle MoonBit `.wasm`/`.cwasm` apps into prebuilt `mbui-runtime` shells across desktop and mobile, or compile native AOT with parallel C splitting (`tools/mbc`).

---

## Quick Start

### Install CLI & Prebuilt Runtime

```sh
curl -fsSL https://ui.monoid.build/install.sh | sh
mbui version
```

Or run directly from a local checkout via `scripts/mbui`.

### Scaffold, Check, and Pack an App

```sh
# 1. Create a new standalone project (optionally pass --ui /path/to/ui-lib)
scripts/mbui init ./my-app --name "My App" --id dev.example.myapp

# 2. Type-check for native and Web targets
cd ./my-app
moon check --target native
moon check --target js

# 3. Validate mbui.json and build a production Web bundle
../scripts/mbui check mbui.json
../scripts/mbui pack mbui.json --target web --out dist
```

See [`docs/PACKAGING.md`](docs/PACKAGING.md) for full `mbui.json` configuration, 6-target signing/packaging, prebuilt `mbui-runtime` shells, and auto-updates.

---

## Building & Developing from Source

### macOS (MoonBit + Xcode)

```sh
scripts/mac.sh build && scripts/mac.sh run      # macOS Metal window
scripts/mac.sh script ime                       # scripted IME run, snapshots in out/ime
MBUI_BENCH=1 _build/native/release/build/demo/demo.exe   # scroll benchmark
scripts/bench.sh                                # offscreen benchmark scenes
scripts/web.sh build && scripts/web.sh test     # WebGL2 build + Playwright test
scripts/ios.sh build && scripts/ios.sh run      # iOS simulator
scripts/textdiff.sh mac web android             # text rendering diff vs platform
```

### Windows (Git Bash, MoonBit, MSVC Developer Command Prompt)

```sh
scripts/win.sh build && scripts/win.sh run      # Win32 + D3D11 window
scripts/win.sh script ime                       # scripted IME run, snapshots in out/ime
scripts/shots.sh windows                        # manual window capture (goldens/windows.png)
```

### Linux (MoonBit, C compiler, GTK 4.12+, `libgtk-4-dev libsoup-3.0-dev`)

```sh
scripts/linux.sh build && scripts/linux.sh run  # GTK 4 window (Wayland, X11, or Xvfb)
scripts/linux.sh script ime                     # scripted IME run, snapshots in out/ime
```

### Checks & Release Preflight

```sh
# Full framework check (detlint, host C/ObjC tests, native type-check)
sh scripts/check.sh

# Standalone release readiness check
sh scripts/publish-check.sh

# Packager & CLI tests
(cd tools && env -u MOON_CC moon test --target native pack)
```

### Parallel Native C Compilation (`tools/mbc`)

Native builds split `moonc`'s generated C into stable per-package/per-file units compiled in parallel (`scripts/mbc`, implemented in `tools/mbc/csplit.mbt`). Unchanged units are cached by content, so incremental native rebuilds recompile only modified units. Set `MBC_SPLIT=0` to compile whole-file; run `scripts/mbc_test.sh` to verify split vs whole symbol parity.

---

## Documentation

- [`docs/PACKAGING.md`](docs/PACKAGING.md) — `mbui.json` schema, 6-target packaging & signing, Wasm runtime shells, auto-updater.
- [`docs/RELEASING.md`](docs/RELEASING.md) — `mooncakes.io` publishing, 6-target `mbui-runtime` releases, SHA-256 manifests, release checklist.

## License

MIT — see [`LICENSE`](LICENSE). Third-party data, tests, and code retain their respective licenses (see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)).
