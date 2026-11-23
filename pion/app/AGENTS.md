# Working in `pion/app` (for agents)

Pure-Pion `still.fail` client workspace connecting `pion/client-core` (`sync::ClientCore` + `pion/client-core/packages/views`) directly to Invar (`AFK-surf/invar@368ff1b5652ed692786d34afffdfc9f1c0a4cdce`) reactive `signals::Signal` state and Apple Two-Layer Liquid Glass UI (`lg`, `icons`, `film`) via zero-serialization `outbox::FrameOutbox[sync::CoreEvent]` + `ui::wake_frame` / `ui::on_frame_take`.

## Packages

- `packages/app_state`:
  - `packages/app_state/src/views_model.pion`: strongly typed ViewModel types and decoders directly backed by real `pion/client-core/packages/views` projections (`ChatsView`, `ChatView`, `stations`, `SafeModeView`, `vaultApprovals`, `profiles`, `models`, `fleet`).
  - `packages/app_state/src/controller.pion`: headless `AppController` Signal bridge (`open_initial`, `select_chat`, `select_station_chat`, `send_text`, `send_message`, `answer_decision`, `answer_card`, `approve_vault`, `deny_vault`, `rename_chat`, `archive_chat`, `set_chat_filter`, `set_sheet`, `set_settings_tab`, `toggle_dark`, `refresh_all_views`, `drain_core_events`).
  - `packages/app_state/src/sim_backend_test.pion` & `packages/app_state/src/app_state_test.pion`: deterministic `SimAccountDb`, `SimStation`, signed Ed25519 lock-chain fixture, and 5 headless `ui::Tester` end-to-end closed-loop tests verified across `INVAR_TEST_FPS=60 / 120 / 24 / 7`.
- `packages/sf_ui`:
  - `packages/sf_ui/src/app.pion`: `sf_app_root` assembling `<lg::SplitShell>`, `SettingsSheet`, and `SearchSheet` bound to `AppController`.
  - `packages/sf_ui/src/sidebar.pion`: Chats List sidebar driven by `ChatsView.days` and `glyph`, `<lg::Segmented flat=true>` filter, and first-line-aligned status dots.
  - `packages/sf_ui/src/chat_pane.pion`: `<lg::PageShell>` + `<lg::ComposerBar>` conversation pane with `<lg::BackButton>`, `<lg::BarPillGroup>` (`icons`), Markdown + `<lg::CodeBlock>`, folded `toolGroups` (`<lg::Disclosure>`), reverse-wrapped interactive decision cards, and optimistic `outbox` bubbles.
  - `packages/sf_ui/src/markdown_view.pion`: CommonMark/GFM block renderer on `markdown-v0.2.1` + `<lg::CodeBlock>`.
  - `packages/sf_ui/src/settings_sheet.pion`: `<lg::Sheet>` with `<lg::Segmented flat=true>` tabs for Unified Safe Mode & Vault Approvals (zero 「个人锁」 wording, `plainMode: false`), sanitized `profiles` & starred `models`, and `fleet` & `stations`.
  - `packages/sf_ui/src/sf_sim_fixture_test.pion` & `packages/sf_ui/src/sf_ui_test.pion`: real `ClientCore` + `pion/client-core/packages/views` test harness, `lg::assert_apple_ui` / `lg::assert_no_nested_glass` / 0-scroll-fault gates across wide/narrow/light/dark/sheet, E2E interactive closed loop, and native Apple Metal `film::picture` 2x offscreen PNG generation.

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
