# Working in `pion/ui` (for agents)

App-agnostic pure-Pion UI component library workspace (`pion.toml`), mirroring `libs/ui/src/controls` (`@sf`) on top of `AFK-surf/invar`.

## It knows no app

- `pion/ui` builds and tests independently of any app. Nothing in `pion/ui/` may import `pion/app`, `pion/client-core`, `pion/rules`, or name an app.
- What `sf` needs from a host (embedded native binaries vs Web lazy-loaded assets, brand drawables) is registered at startup via `sf::register_faces`, `sf::register_math_glyphs`, `sf::register_icons`, and `sf::register_palettes`.

## Packages

- `packages/sf`: migrated `@sf` component library (`libs/ui/src/controls`), asset registration hooks (`assets.pion`), palette contract (`palette.pion`), and cross-workspace probe entrypoint (`probe.pion`).
- `packages/sf_assets_native`: native/headless embedded asset package generated directly by `pion/tools/mbt2pion-monoid/gen_assets.mjs` (never transpiled via `mbt2pion`). Carries JetBrains Mono TTF (300,144 B), gzipped math glyph outlines (293,607 B), icon stroke table, and light/dark palettes.
- `packages/sf_assets_web`: Web host-provider asset adapter supporting absent initial state, late-arrival registration with redraw callbacks, post-decompress cache release, and graceful fallback on missing/corrupt payloads (zero 2 MB embedded binary bloat on `wasm32`).

## Rules

- Single repo-wide `AFK-surf/invar` pin: `pion/ui/pion.toml` and `pion/app/pion.toml` must pin the exact same 40-char `invar` commit SHA (`sh pion/tools/mbt2pion-monoid/check_single_invar_pin.sh`).
- Verify with:
  - `sh pion/tools/mbt2pion-monoid/check_single_invar_pin.sh`
  - `pionc fmt --check pion/ui`
  - `pionc check --json pion/ui`
  - `pionc test --json pion/ui`
  - `pionc build --target wasm32 pion/ui`
