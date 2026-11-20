# mbui Packaging, Signing & Release Guide

This guide covers scaffolding, packaging, signing, auto-updating, and desktop host capabilities for standalone applications built on `mbui`.

All packaging commands are exposed through the unified CLI wrapper `libs/mbui/scripts/mbui` (implemented in MoonBit under `libs/mbui/tools/pack`).

---

## 1. Quick Start (1 Minute)

```bash
# 1. Scaffold a new standalone mbui project
libs/mbui/scripts/mbui init ./my-app \
  --name "Acme Client" \
  --id dev.example.acme \
  --mbui /path/to/libs/mbui

# 2. Validate mbui.json and environment (wasm runtime requires no native C toolchain)
libs/mbui/scripts/mbui check ./my-app/mbui.json --runtime wasm

# 3. Build & package for Web and macOS using the prebuilt Wasm runtime shell
libs/mbui/scripts/mbui pack ./my-app/mbui.json \
  --target web,mac \
  --runtime wasm \
  --runtime-dir /path/to/mbui-out/runtime \
  --format app,zip \
  --out ./my-app/dist
```

---

## 2. `mbui.json` Configuration Reference

`mbui.json` lives at the root of your application repository. Every platform-specific block is optional and has sensible defaults.

```json
{
  "appId": "dev.example.acme",
  "name": "Acme Client",
  "executable": "Acme-Client",
  "version": "1.0.0",
  "build": 1,
  "moduleDir": "ui",
  "entry": "src/app",
  "icon": "assets/icon.png",
  "iconDark": "assets/icon-dark.png",
  "urlSchemes": ["acme"],
  "runtime": "wasm",
  "env": {
    "ACME_API": "https://api.example.com"
  },
  "resources": ["assets/fonts"],
  "hooks": {
    "preBuild": "",
    "postStage": "",
    "postPack": ""
  },
  "macos": {
    "minVersion": "13.0",
    "category": "public.app-category.productivity",
    "entitlements": "macos/entitlements.plist",
    "formats": ["app", "dmg", "zip"],
    "infoPlist": {}
  },
  "windows": {
    "company": "Acme Inc.",
    "installDir": "Acme",
    "formats": ["portable", "zip", "setup"],
    "rawForDelta": false
  },
  "linux": {
    "categories": ["Utility"],
    "formats": ["tar.gz", "deb", "appimage"]
  },
  "android": {
    "minSdk": 26,
    "targetSdk": 35,
    "compileSdk": 35,
    "abis": ["arm64-v8a"],
    "edgeToEdge": true,
    "ground": "#FFFFFF",
    "permissions": ["android.permission.INTERNET"],
    "java": [],
    "res": [],
    "rules": [],
    "lock": "",
    "merged": []
  },
  "ios": {
    "minVersion": "16.0",
    "edgeToEdge": true,
    "ground": "#FFFFFF",
    "shareExtension": false,
    "push": false,
    "entitlements": "",
    "usageDescriptions": {}
  },
  "web": {
    "title": "Acme Client",
    "themeColorLight": "#FFFFFF",
    "themeColorDark": "#111111",
    "brotli": true,
    "pwa": true,
    "head": ""
  },
  "updater": {
    "feed": "https://releases.example.com/acme/latest.json",
    "channel": "stable",
    "publicKey": "<base64-ed25519-pubkey>"
  },
  "variants": {
    "beta": {
      "appId": "dev.example.acme.beta",
      "name": "Acme Client Beta",
      "urlSchemes": ["acme-beta"],
      "updater": {
        "channel": "beta",
        "feed": "https://releases.example.com/acme-beta/latest.json"
      }
    }
  }
}
```

### Multi-Channel & White-Label Variants (`--variant`) & `--env`

Any key under `variants.<name>` is deep-merged on top of the base manifest. CLI flags (`--version`, `--build`, `--app-id`, `--runtime`, and repeatable `--env K=V`) take highest precedence:

```bash
libs/mbui/scripts/mbui pack mbui.json --variant beta --version 1.1.0 --build 42 --env ACME_API=https://beta.example.com --target mac,win
```

### Multi-Module Layout (`moduleDir`)

When `mbui.json` lives at the repository root while the MoonBit UI module lives in a subdirectory (for example `ui/`), set `"moduleDir": "ui"` (also overridable per variant). MoonBit builds (`moon build`, `moon.mod`, `moon.work`, `_build/`) resolve against `moduleDir`, while manifest-relative paths (`icon`, `iconDark`, `resources`, `entitlements`, `android.*`, `hooks.*`, default `--out`) stay relative to `mbui.json`.

### Lifecycle Hooks (`hooks`)

Optional shell commands under `hooks` (`preBuild`, `postStage`, `postPack`, deep-merged across `variants`) run in `cwd = <manifest_dir>` via `sh -c` with standard `MBUI_*` environment variables (`MBUI_HOOK_PHASE`, `MBUI_TARGET`, `MBUI_RUNTIME`, `MBUI_VARIANT`, `MBUI_APP_ID`, `MBUI_APP_NAME`, `MBUI_EXECUTABLE`, `MBUI_VERSION`, `MBUI_BUILD`, `MBUI_MANIFEST_DIR`, `MBUI_MODULE_DIR`, `MBUI_STAGE_DIR`, `MBUI_OUT_DIR`, `MBUI_DIR`):

- `preBuild`: before compiling the target (e.g., build native libraries or generate assets).
- `postStage`: after binaries/assets/metadata are staged into `MBUI_STAGE_DIR`, **before** signing and archive compression (e.g., copy extra `.wasm`/fonts, patch `host.js` before `.gz`/`.br` compression, or copy extra `Contents/Frameworks/*.{dylib,framework}` on macOS before nested inside-out signing).
- `postPack`: after all target formats finish packaging.

### Exporting Resolved Metadata (`mbui meta`)

Existing build or CI scripts can consume `mbui.json` as a single source of truth via `mbui meta`:

```bash
# Normalized JSON (after variant merge and CLI overrides)
libs/mbui/scripts/mbui meta mbui.json --variant beta --env EXTRA_URL=https://x.test --format json

# Safe single-quoted POSIX shell assignments (eval-ready)
eval "$(libs/mbui/scripts/mbui meta mbui.json --variant beta --env EXTRA_URL=https://x.test --format sh)"
```

---

## 3. Runtime Modes: `--runtime wasm` vs `--runtime native`

| Aspect | `--runtime wasm` (Default for fast/cross-platform delivery) | `--runtime native` (Native AOT) |
|---|---|---|
| Compilation | Compiles MoonBit to `.wasm` (or precompiled `.cwasm` with `--wasm-aot`) and injects it into a prebuilt `mbui-runtime` shell. | Compiles MoonBit to C and links directly with platform host C/ObjC/C++ sources. |
| C/Xcode/MSVC needed per app build | **None** once `mbui-runtime` shells are built/downloaded (`--runtime-dir`). | Requires host platform native toolchain (Xcode / MSVC / GCC+GTK / Android NDK). |
| Custom native C extensions | Uses standard `mbui/hostapi` only. | Supports custom app C/ObjC/Java FFI extensions. |

### Building the Prebuilt Wasm Runtime Shell (`scripts/runtime.sh`)

```bash
# Build pure mbui-runtime shell for macOS / Linux / Windows / Android / iOS
MBUI_OUT=/path/to/mbui-out libs/mbui/scripts/runtime.sh build mac
MBUI_OUT=/path/to/mbui-out libs/mbui/scripts/runtime.sh build linux

# Optional: AOT-compile a .wasm module into .cwasm for a target triple
libs/mbui/scripts/runtime.sh compile app.wasm --target aarch64-apple-darwin --out app.cwasm

# Verify Wasm host ABI bindings match host_native.mbt (0 diff)
libs/mbui/scripts/runtime.sh check
```

When running a bundled app, `mbui-runtime` auto-discovers `app.cwasm` or `app.wasm` next to the executable (or inside `Contents/Resources/` on macOS), so double-clicking the `.app` or launching the binary with zero arguments works out of the box.

---

## 4. Packaging & Signing Across 6 Targets

Generate platform icons standalone at any time with:

```bash
libs/mbui/scripts/mbui icons mbui.json --out ./dist/icons --platform all
```

### Web (`--target web`)

```bash
libs/mbui/scripts/mbui pack mbui.json --target web --out ./dist
```

Outputs static assets (`index.html`, JS bundle, `host.js`, PWA manifest/icons, and pre-compressed `.gz` / optional `.br` assets generated after `postStage` so hook-added or patched `.js`/`.html`/`.wasm` files stay in sync; pass `--web-no-compress` to skip compression).

### macOS (`--target mac`)

Supported `--format`: `app`, `zip`, `dmg` (comma-separated). Pass `--keychain <PATH>` when signing from a temporary CI keychain.

```bash
libs/mbui/scripts/mbui pack mbui.json \
  --target mac --runtime wasm --runtime-dir ./runtime \
  --format app,dmg,zip \
  --sign-identity "Developer ID Application: Acme Inc. (TEAMID)" \
  --keychain ./build.keychain-db \
  --notarize-profile "acme-notary" \
  --out ./dist
```

### Windows (`--target win`)

Supported `--format`: `portable`, `zip`, `setup`.

```bash
libs/mbui/scripts/mbui pack mbui.json \
  --target win --runtime wasm --runtime-dir ./runtime \
  --format portable,zip,setup \
  --win-cert ./certs/code-sign.pfx \
  --win-cert-pass "$WIN_CERT_PASS" \
  --win-timestamp http://timestamp.digicert.com \
  --out ./dist
```

### Linux (`--target linux`)

Supported `--format`: `tar.gz`, `deb`, `appimage`.

```bash
libs/mbui/scripts/mbui pack mbui.json \
  --target linux --runtime wasm --runtime-dir ./runtime \
  --format tar.gz,deb,appimage \
  --out ./dist
```

### Android (`--target android` & `mbui repack`)

Full build and sign:

```bash
libs/mbui/scripts/mbui pack mbui.json \
  --target android --runtime wasm --runtime-dir ./runtime \
  --keystore ./release.jks --key-alias release \
  --ks-pass env:KS_PASS --key-pass env:KEY_PASS \
  --v3-signing --verify-cert <SHA256> \
  --out ./dist
```

Fast white-label / variant rebranding of an existing APK without recompiling native code (`mbui repack`):

```bash
libs/mbui/scripts/mbui repack mbui.json \
  --target android \
  --in ./dist/android/base.apk \
  --out ./dist/android/acme-beta.apk \
  --variant beta \
  --keystore ./release.jks --key-alias release \
  --ks-pass env:KS_PASS --key-pass env:KEY_PASS
```

### iOS (`--target ios`)

```bash
libs/mbui/scripts/mbui pack mbui.json \
  --target ios --runtime wasm --runtime-dir ./runtime \
  --ios-sdk iphoneos \
  --sign-identity "Apple Distribution: Acme Inc. (TEAMID)" \
  --keychain ./build.keychain-db \
  --ios-profile ./certs/acme.mobileprovision \
  --out ./dist
```

Use `--ios-sdk iphonesimulator` for simulator builds.

---

## 5. Auto-Updates (`mbui/updater` & `mbui publish`)

### Client Integration (5 Lines)

Import `mbui/updater` in your app package and feed it the fetched `latest.json` text:

```moonbit
let pubkeys = ["<base64-ed25519-public-key>"]
match @updater.check_and_fetch(feed_json, "https://releases.example.com/acme/", public_keys=pubkeys, expected_kind="dev.example.acme") {
  Ok(true) => () // Native host is downloading (with optional binary delta)
  Ok(false) => () // Already up to date
  Err(err) => @hostapi.log("update error: " + err)
}
```

Poll or display progress via `@updater.status()` (`UpdatePhase`: `Idle`, `Waiting`, `Downloading`, `Retrying`, `Ready`, `Asking`, `Installing`, `Failed`), and apply when `Ready`:

```moonbit
if @updater.status().phase == Ready {
  @updater.apply()
}
```

### Release Pipeline (`mbui publish` / `libs/mbui/scripts/release`)

`mbui publish` reads `version`, `build`, and `appId` from `mbui.json` (with `--variant` / `--version` / `--build` overrides) and forwards to `tools/release`:

```bash
# 1. Generate an Ed25519 signing keypair (prints base64 public key to stdout)
libs/mbui/scripts/mbui publish mbui.json keygen --out ./release-key.pem

# 2. (Optional) Generate a binary delta patch from previous releases
libs/mbui/scripts/mbui publish mbui.json delta \
  --old-dir ./prev-release --new "./dist/mac/Acme Client-mac.zip" --out ./rel/from-1.delta

# 3. Generate signed latest.json feed and stage artifacts
libs/mbui/scripts/mbui publish mbui.json feed \
  --file "./dist/mac/Acme Client-mac.zip" \
  --key ./release-key.pem \
  --out-dir ./rel

# 4. Verify latest.json signature before uploading
libs/mbui/scripts/mbui publish mbui.json verify ./rel/latest.json \
  --pubkey "<BASE64_PUBKEY>" \
  --kind dev.example.acme

# 5. Publish artifacts first, then latest.json atomically (providers: dir | github | s3)
libs/mbui/scripts/mbui publish mbui.json \
  --dir ./rel --provider dir --target ./published
```

Supported `--provider` values:
- `dir`: Copies artifacts then `latest.json` to a local directory (`--target <path>`).
- `github`: Uploads to a GitHub Release via `gh` (`--target <owner/repo> --tag <tag>`).
- `s3`: Uploads to S3/R2 via `aws s3` (`--target s3://<bucket>/<prefix> [--endpoint <url>]`).

---

## 6. Advanced Desktop Host Capabilities

### macOS `NSStatusBar` Menu Bar Tray (Opt-In)

Windows and Linux use `"role": "tray"` in `@hostapi.menu_setup(json)` for their notification-area icon. On macOS, menu bar status items are **opt-in** by setting `"macos": true` on the tray entry so existing apps keep their Dock-only behavior unless opted in:

```json
[
  {
    "role": "tray",
    "macos": true,
    "symbol": "bolt.fill",
    "title": "",
    "tooltip": "Acme Client",
    "items": [
      { "title": "Show {app}", "role": "show" },
      { "separator": true },
      { "title": "Preferences", "action": "open_prefs" },
      { "separator": true },
      { "title": "Quit {app}", "role": "quit" }
    ]
  }
]
```

- `symbol`: macOS SF Symbol name rendered as a template image.
- `title`: Optional status bar text. If both `symbol` and `title` are omitted, macOS falls back to the app icon scaled to 18x18 template image (or the first character of the app name).
- `tooltip`: Hover tooltip text.
- `items`: Supports `"role": "show"`, `"role": "quit"`, `"separator": true`, and `"action": "<id>"` (delivered on the system channel as `{"menu": "<id>"}`).
- Calling `menu_setup` later without a `"role": "tray"` + `"macos": true` entry automatically removes the status item.

### Cross-Platform Login Auto-Launch

```moonbit
let enabled = @hostapi.auto_launch()
let ok = @hostapi.set_auto_launch(!enabled)
```

Platform implementations:
- **macOS**: Dynamically loads `ServiceManagement.framework` (`SMAppService.mainAppService`) with zero extra `-framework` link flags. Works inside signed/bundled `.app` packages; safely returns `false` when run outside a bundle.
- **Windows**: Reads/writes `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` under `MBUI_APP_ID` (falling back to the executable filename).
- **Linux**: Reads/writes `$XDG_CONFIG_HOME/autostart/<app_id>.desktop` (falling back to `$HOME/.config/autostart/`).
- **iOS / Android / Web**: Safe no-op stub returning `false`.

### Cross-Platform Global Hotkeys

```moonbit
// Register a global shortcut; re-registering the same id replaces the previous binding.
let ok = @hostapi.hotkey_set("quick_capture", "CmdOrCtrl+Shift+Space")

// Unregister when no longer needed.
@hostapi.hotkey_clear("quick_capture")
```

- Supported modifiers: `CmdOrCtrl` (maps to `Cmd` on macOS, `Ctrl` elsewhere), `Cmd`, `Ctrl`, `Alt` (`Option`), `Shift`, `Super` (`Meta` / `Win`). At least one modifier is required.
- Supported keys: `A`-`Z`, `0`-`9`, `F1`-`F12`, `Space`, `Enter`, `Tab`, `Escape`, `Up`, `Down`, `Left`, `Right`.
- Triggered hotkeys are delivered between frames as a host post on channel `"mbui.hotkey"` with JSON payload `{"id":"quick_capture"}`.
- Platform implementations:
  - **macOS**: Dynamically loads `Carbon.framework` (`RegisterEventHotKey`) with zero extra `-framework Carbon` link flags.
  - **Windows**: Uses Win32 `RegisterHotKey` / `UnregisterHotKey` and handles `WM_HOTKEY`, automatically unregistering all hotkeys on exit.
  - **Linux / iOS / Android / Web**: Safe stub returning `false` / no-op.
