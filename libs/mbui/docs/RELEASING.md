# Releasing `ui.monoid` (`mbui`)

This document describes the standalone release process for `ui.monoid` (`mbui`, hosted at `https://ui.monoid.build`), covering `mooncakes.io` package publishing, 6-target prebuilt `mbui-runtime` binaries on GitHub Releases, MoonBit toolchain compatibility, and automated preflight gates.

---

## 1. Release Preflight Gate (`scripts/publish-check.sh`)

Every release candidate must pass both the standard verification suite and the standalone release preflight:

```sh
# 1. Standalone release preflight (detlint app-word=0, docs/license, no ../../ coupling, size report)
sh scripts/publish-check.sh

# 2. Full type-check and host C/ObjC unit tests
. scripts/env.sh
sh scripts/check.sh
TARGETS="native js" moon check --target js --output-json 2>&1 | scripts/chk errs

# 3. Packager & CLI unit tests
(cd tools && env -u MOON_CC moon test --target native pack)

# 4. End-to-end scaffold smoke test
scripts/mbui init /tmp/mbui-smoke --name "Smoke App" --id dev.monoid.smoke
(cd /tmp/mbui-smoke && moon check --target native && moon check --target js)
scripts/mbui check /tmp/mbui-smoke/mbui.json
scripts/mbui pack /tmp/mbui-smoke/mbui.json --target web --web-no-compress --out /tmp/mbui-smoke/dist
rm -rf /tmp/mbui-smoke
```

---

## 2. `mooncakes.io` Module Publishing

### Module Naming & Versioning

- Standalone module name on `mooncakes.io`: `monoid/mbui` (local workspace alias `mbui`).
- Semantic version in `moon.mod` (`version = "X.Y.Z"`) must match the Git release tag `vX.Y.Z` and `cli_version` in `tools/pack/init.mbt`.
- Keep `LICENSE` (MIT) and `THIRD_PARTY_NOTICES.md` at the module root.

### Publish `exclude` List

To keep the `mooncakes.io` tarball compact, exclude test goldens, benchmarks, reference images, and build outputs when publishing:

```json
{
  "exclude": [
    "goldens/",
    "bench/",
    "src/skiatest/images/",
    "out/",
    "_build/",
    "tools/_build/"
  ]
}
```

Run `sh scripts/publish-check.sh` before `moon publish` to inspect the current module size and excluded directory breakdown.

---

## 3. 6-Target Prebuilt `mbui-runtime` & CLI Artifacts (GitHub Releases)

Apps packaged with `mbui pack --runtime wasm` require zero native C/Xcode/MSVC compilation on the app developer's machine by embedding the app's `.wasm` / `.cwasm` into a prebuilt `mbui-runtime` shell.

### Building `mbui-runtime` Shells

Each platform runner builds its shell using `scripts/runtime.sh` (backed by the Wasmtime version pinned in `scripts/runtime.sh` with `-C collector=drc`):

| Target | Runner OS | Build Command | Output Archive |
|---|---|---|---|
| macOS (arm64) | `macos-15` | `scripts/runtime.sh build mac` | `mbui-runtime-macos-arm64.tar.gz` |
| macOS (x64) | `macos-13` | `scripts/runtime.sh build mac` | `mbui-runtime-macos-x64.tar.gz` |
| Linux (x64) | `ubuntu-24.04` | `scripts/runtime.sh build linux` | `mbui-runtime-linux-x64.tar.gz` |
| Linux (arm64) | `ubuntu-24.04-arm` | `scripts/runtime.sh build linux` | `mbui-runtime-linux-arm64.tar.gz` |
| Windows (x64) | `windows-latest` | `scripts/runtime.sh build win` | `mbui-runtime-windows-x64.zip` |
| Android (arm64-v8a / x86_64) | `ubuntu-24.04` | `ABI=arm64-v8a scripts/runtime.sh build android` | `mbui-runtime-android-arm64-v8a.apk` |
| iOS (device / simulator) | `macos-15` | `MBUI_IOS_SDK=iphoneos scripts/runtime.sh build ios` | `mbui-runtime-ios-device.tar.gz` |
| Web host bundle | any | `web/host.js` + `web/index.html` | `mbui-web-host.tar.gz` |

Before packaging runtime archives, verify that the generated Wasm host ABI thunks match `src/host/*_native.mbt` with zero diff:

```sh
scripts/runtime.sh check
scripts/runtime.sh test
```

### CLI Binaries

Build native `mbui` CLI executables from `tools/pack` on each desktop target:

- `mbui-cli-macos-arm64.tar.gz`
- `mbui-cli-macos-x64.tar.gz`
- `mbui-cli-linux-x64.tar.gz`
- `mbui-cli-linux-arm64.tar.gz`
- `mbui-cli-windows-x64.zip`

### `SHA256SUMS` Manifest

Generate a deterministic `SHA256SUMS` file covering every release archive and upload it alongside the archives to the GitHub Release:

```sh
(cd dist/release && shasum -a 256 *.tar.gz *.zip *.apk > SHA256SUMS)
```

`https://ui.monoid.build/install.sh` (source: `scripts/install.sh`) downloads `SHA256SUMS` first and verifies every archive's SHA-256 digest before extracting.

---

## 4. MoonBit Toolchain Compatibility

Each release note must declare the tested MoonBit toolchain version (`moon version --all`) and target coverage:

- **Compiler targets verified**: `native`, `js`, `wasm`, `wasm-gc`.
- **Wasmtime runtime**: pinned in `scripts/runtime.sh` (`WT_VERSION`, collector `drc`).
- **Node.js**: required for Web bundling (`esbuild` minification / Brotli compression) and `wasm-gc` dev tool execution.

---

## 5. Release Checklist

1. Bump `version` in `moon.mod` and `cli_version` in `tools/pack/init.mbt`.
2. Run `sh scripts/publish-check.sh` and confirm all checks pass.
3. Run `sh scripts/check.sh` and `moon test --target native pack` in `tools/`.
4. Tag `vX.Y.Z` and trigger the 6-platform release workflow.
5. Verify `SHA256SUMS` is published on GitHub Releases and `sh scripts/install.sh --version vX.Y.Z --dry-run` resolves the expected URLs.
6. Publish the MoonBit module to `mooncakes.io` with the exclude list above.
