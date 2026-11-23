# Working in `pion/app` (for agents)

Pure-Pion `still.fail` client workspace connecting `pion/client-core` (`sync::ClientCore` + `pion/client-core/packages/views`) directly to Invar (`AFK-surf/invar@368ff1b5652ed692786d34afffdfc9f1c0a4cdce`) reactive `signals::Signal` state and Apple Two-Layer Liquid Glass UI (`lg`, `icons`, `film`) via zero-serialization `outbox::FrameOutbox[sync::CoreEvent]` + `ui::wake_frame` / `ui::on_frame_take`.

## Packages

- `packages/app_state`:
  - `packages/app_state/src/views_model.pion`: strongly typed ViewModel types and decoders directly backed by real `pion/client-core/packages/views` projections (`ChatsView`, `ChatView`, `stations`, `SafeModeView`, `vaultApprovals`, `profiles`, `models`, `fleet`, `downloads`, `search`, `archive`, `presets`, `auth`).
  - `packages/app_state/src/controller.pion`: headless `AppController` Signal bridge (`open_initial`, `select_chat`, `select_station_chat`, `send_text`, `send_message`, `answer_decision`, `answer_card`, `approve_vault`, `deny_vault`, `toggle_model_star`, `set_search_tab`, `set_search_query`, `copy_preset`, `begin_auth`, `begin_passkey`, `complete_auth`, `cancel_auth`, `rename_chat`, `archive_chat`, `set_chat_filter`, `set_sheet`, `set_settings_tab`, `toggle_dark`, `refresh_all_views`, `drain_core_events`).
  - `packages/app_state/src/sim_backend_test.pion` & `packages/app_state/src/app_state_test.pion`: deterministic `SimAccountDb`, `SimStation`, signed Ed25519 lock-chain fixture, and 5 headless `ui::Tester` end-to-end closed-loop tests verified across `INVAR_TEST_FPS=60 / 120 / 24 / 7`.
- `packages/sf_ui`:
  - `packages/sf_ui/src/app.pion`: `sf_app_root` assembling `<lg::SplitShell>`, `SettingsSheet`, `SearchSheet`, and `SignInView` bound to `AppController`.
  - `packages/sf_ui/src/sidebar.pion`: Chats List sidebar driven by `ChatsView.days` and `glyph`, `<lg::Segmented flat=true>` filter, and first-line-aligned status dots.
  - `packages/sf_ui/src/chat_pane.pion`: `<lg::PageShell>` + `<lg::ComposerBar>` conversation pane with `<lg::BackButton>`, `<lg::BarPillGroup>` (`icons`), Markdown + `<lg::CodeBlock>`, folded `toolGroups` (`<lg::Disclosure>`), reverse-wrapped interactive decision cards, and optimistic `outbox` bubbles.
  - `packages/sf_ui/src/markdown_view.pion`: CommonMark/GFM block renderer on `markdown-v0.2.1` + `<lg::CodeBlock>`.
  - `packages/sf_ui/src/settings_sheet.pion`: Apple Inset Grouped modals for Settings (Safe Mode & Vault Approvals with zero 「个人锁」, sanitized `profiles` + star-toggle `models`, `fleet` + `stations` + `downloads`) and Search/Archive/Personal Presets (flat search bar, `search`/`archive`/`presets` + `preset.copy`).
  - `packages/sf_ui/src/signin_view.pion`: centered 400pt Apple HIG `SignInView` driving `auth.begin` (OAuth PKCE with zero `verifier` exposure), Passkey challenge, and `auth.cancel` recovery guidance.
  - `packages/sf_ui/src/sf_sim_fixture_test.pion` & `packages/sf_ui/src/sf_ui_test.pion`: real `ClientCore` + `pion/client-core/packages/views` test harness, `lg::assert_apple_ui` / `lg::assert_no_nested_glass` / 0-scroll-fault gates across wide/narrow/light/dark/sheet/signin, E2E interactive closed loops, and native Apple Metal `film::picture` 2x offscreen PNG generation.
- `packages/sf_desktop`:
  - `packages/sf_desktop/src/worker.pion` & `packages/sf_desktop/src/main.pion`: native desktop executable entry connecting `sf_ui::sf_app_root` to `AppController` / `ClientCore` via dual-thread `ui::Worker::pair()` + `ui::wake_now()` (zero `#render_thread` `World` IO, `--demo` and `--data-dir` startup args).
  - `packages/sf_desktop/src/desktop_test.pion`: deterministic `ui::Worker::inline` + `ui::Tester` headless verification.

## Pinned Baselines

- `AFK-surf/invar`: rev `368ff1b5652ed692786d34afffdfc9f1c0a4cdce` (`signals`, `view`, `ui`, `lg`, `icons`, `paint`, `flex`, `text`, `font`, `dmath`, `film`, `pixels`, `render`, `codec`, `motion`, `headless`, `shape`, `svg`, `kit`, `host`).
- `AFK-surf/pion-packages`: official release tags (`crypto-v0.2.0`, `markdown-v0.2.1`, and `v0.1.0` for `base64`, `effect`, `flate`, `url`, `time`, `http1`, `json5`).

## Rules

- Keep `packages/app_state` strictly headless and visual-skin agnostic (no `lg` or custom visual chrome).
- Never hand-roll `paint::Glass::liquid` in `packages/sf_ui`; use `lg` components exclusively, pass `flat=true` to `<lg::Segmented>` inside sheets/cards, and never mention 「个人锁」 in Safe Mode UI.
- Verify with:
  - `pionc fmt --check pion/app`
  - `pionc check --json pion/app`
  - `pionc test --json pion/app`
  - `for fps in 60 120 24 7; do INVAR_TEST_FPS=$fps INVAR_FPS=$fps pionc test --json --package app_state pion/app || exit 1; done`
