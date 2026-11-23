# Working in `pion/app` (for agents)

Pure-Pion native Monoid client workspace connecting `pion/client-core` (`sync::ClientCore`) directly to Invar reactive `signals::Signal` state via zero-serialization `outbox::FrameOutbox[sync::CoreEvent]` + `ui::wake_frame` / `ui::on_frame_take` (zero Hermes, zero MoonBit, zero JSON UI protocol).

## Packages

- `packages/app_state` (strictly headless, zero `lg` dependency):
  - `packages/app_state/src/controller.pion`: `AppController` headless ViewModel / Signal bridge (`open_initial`, `select_chat`, `send_text`, `answer_decision`, `rename_chat`, `archive_chat`, `dismiss_notice`, `set_search_query`, `filtered_chats`, `open_settings`/`close_settings`, `set_appearance`, `set_font_scale`, `set_show_badge`, `drain_core_events`).
  - `packages/app_state/src/sim_backend_test.pion`: deterministic `SimAccountDb`, `SimStation`, and signed Ed25519 `pion/rules` lock-chain test fixture over `effect::Runtime` virtual clock (excluded from production `pionc build`).
  - `packages/app_state/src/app_state_test.pion`: 5 headless `ui::Tester` end-to-end closed-loop tests verified across `INVAR_TEST_FPS=60 / 120 / 24 / 7`.
- `packages/app_ui` (pure Pion-JSX + Invar `lg` Apple Two-Layer UI shell):
  - `packages/app_ui/src/shell.pion`: `mount_monoid_app` built on `<lg::SplitShell>`, `<lg::PageShell>`, `<lg::ComposerBar>`, `<lg::BarPillGroup>`, `<lg::BackButton>`, `<lg::SurfaceCard>`, `<lg::SurfaceSection>`, and `<lg::Sheet>` (zero hand-rolled liquid glass).
  - `packages/app_ui/src/demo.pion`: deterministic zero-IO `DemoApp` fixture shared by `ui::Tester` tests and `app_media`.
  - `packages/app_ui/src/app_ui_test.pion`: 5 interactive + `lg::assert_apple_ui` / `lg::assert_no_nested_glass` / `scroll_faults == 0` tests across wide (1280×800) and narrow (390×844) viewports at `INVAR_TEST_FPS=60 / 120 / 24 / 7`.
- `packages/app_media` (native GPU offscreen rendering via Invar `film`):
  - `packages/app_media/src/main.pion`: renders 2× offscreen PNGs (`invar-desktop.png`, `invar-narrow.png`, `invar-settings.png`) into `MONOID_SHOTS_OUT` (never committed to git).

## Pinned Baselines

- `AFK-surf/invar`: `main` rev `9299a28dcdab6b876278cb0754ae276a58903403` (`signals`, `view`, `headless`, `motion`, `ui`, `paint`, `kit`, `lg`, `film`, `host`, `hostapi`).
- `AFK-surf/pion-packages`: official release tags (`crypto-v0.2.0`, and `v0.1.0` for `base64`, `effect`, `flate`, `url`, `time`, `http1`, `json5`).

## Rules

- Keep `packages/app_state` strictly headless and visual-skin agnostic (zero `lg` dependency).
- Never hand-roll liquid glass in `packages/app_ui`; use Invar `lg` components and keep `lg::assert_apple_ui` green across wide and narrow viewports.
- Never commit offscreen `.png` artifacts to git.
- Verify with:
  - `pionc fmt --check pion/app`
  - `pionc check --json pion/app`
  - `for fps in 60 120 24 7; do INVAR_TEST_FPS=$fps INVAR_FPS=$fps pionc test --json pion/app || exit 1; done`
  - `pionc build --target wasm32 pion/app/packages/app_ui`
