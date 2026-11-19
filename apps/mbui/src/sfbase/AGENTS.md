# still.fail app data readiness, transitions, tabs, and features (for agents)

## Instant bar places, SWR, and open gates

- A bottom-bar place never opens on bones when the device has its data: list every opening list in both `lasting` (shown immediately) and `place_reads` (pre-requested), verified by `apps/mbui/src/sfapp/place_first_wbtest.mbt`. Sole exception: `stationNet` (Station network line) samples stations only after pressing the Station tab, so that line alone may show bones on first open.
- Read-only page, panel, and card topics (`views_kept`) stay cached in the client and display immediately on re-open until the core answers (`@core.Client::show_kept`, `MBUI_SWR_VIEWS`). Chat values wait for the core, bar lists replay via `last_said`, and `station_marks` never uses kept values.
- Cards, panels, sheets, and dialogs opening for the first time wait up to `open_hold_ms` for local topic reads made during construction, never waiting on a station (`libs/sf-ui/src/open_gate.mbt`, `Source::topic`, `MBUI_OPEN_WHOLE`, `apps/mbui/src/sfapp/open_whole_wbtest.mbt`).
- On 小屏, keep switched-away bottom-bar places parked on the stack shelf (`nav_root_kept`: bar, chats, history, while rail, wide frames, and legacy views replace normally) and release them only on workspace or tier change (`@settings.left`). Parked places automatically preserve scroll, 连接's 我的, Home's list/filter/search, and 用量's days (keyboard focus still clears).

## Workspace switch, ahead reads, and press waits

- Show no loading state within 300 ms of switching workspaces: hold the previous screen up to `switch_wait_ms` until all first-screen reads of the new workspace answer, switching in the press frame if already answered (`apps/mbui/src/sfbase/workspace_switch.mbt`, `apps/mbui/src/sfapp/late_core_wbtest.mbt`).
- Declare first-screen workspace reads in each shell's open function (小屏 `home_opens`, 中屏/大屏 `frame_opens`), never in a separate switch list. Pass the chooser overlay (workspace sheet, popover, create/join dialog) in `switch_workspace_to` `closes` so it closes at the switch moment while keeping its press-time rows (`apps/mbui/src/sfapp_realsize/switch_drawer_test.mbt`).
- Pre-declare workspace reads between frames via `opens_ahead_node` (`declare_topic`) and top-page reads via `page_opens` (`page_opens_node`), handing the same subscriptions to the built nodes and dropping unused ones on navigation. Every declared topic must be read at rest (`apps/mbui/src/sfapp/declared_read_wbtest.mbt`).
- With `MBUI_OPEN_WHOLE`, every page navigation holds the prior screen up to `page_local_ms` using the exhaustive match tables `page_reads` and `route_reads` in `apps/mbui/src/sfbase/page_reads.mbt` (no `_` arm), consumed by `page_opens_by` (小屏), `pane_opens` + `place_reads` (中屏/大屏), `route_open_asks`, and `page_opens_node` (chained reads via `then`). Chat pages also wait for locally cached avatars (`picture` with `kept` / `pictureKept`, `pictures_in`, `Source.picture_waits`, `apps/mbui/src/sfapp/page_pictures_wbtest.mbt`), never waiting on the network.
- Any press that waits on the core before opening a menu, panel, or question must use `apps/mbui/src/sfbase/press_wait.mbt`, canceling automatically if the page, workspace, or overlay changes (`apps/mbui/src/sfapp/press_waits_wbtest.mbt`).

## Unified beside-chat tabs

- Everything opening beside a chat (files, web services, visualizations, mini-programs) shares one interaction (`apps/mbui/src/sfbase/tab_full.mbt`, `apps/mbui/src/sfdesk/tab_full_node.mbt`, `apps/mbui/src/sfbase/window.mbt`): a chat side-panel tab by default on wide screens, fullscreen over the window on Cmd+click or 全屏, and an independent window as its third host, rendered by the same nodes everywhere. Route every new beside-chat kind through it. Pictures, videos, and audio stay in the whole-window viewer until tabs support flight, marking, and stepping.

## Topic subscriptions, unread calls, and feature registry

- Subscribe only to what a page renders:
  - Stations: lists use `@settings.stations_of` (`station_rows`), detail pages use `@settings.station_of`, single-part overviews use `@settings.station_part`. Never fetch full stations in a list.
  - Connects: lists use `connects`, detail pages use `@settings.connect_of`, and `connectCandidates` is read only while a single-session connect's 更换 row shows.
  - Accounts: lists use `profiles`, detail pages use `profile` (`@settings.profile_read`, `@settings.profile_by_key_read`), opened after local answer via `open_answered`/`show_answered`/`hand_over`/`hand_over_shown` (`apps/mbui/src/sfapp_pages_test/account_open_test.mbt`).
- Fire-and-forget calls omit `on_done` (`answer_unread` in `apps/mbui/src/sfbase/source.mbt`). Detlint `empty-on-done` rejects empty callbacks.
- All unreleased features live in the single core registry (`client/core-ts/src/features.ts`, `scripts/features-check.ts`). The app reads `features`, `experimentalItems`, and station overview `features` (`apps/mbui/src/sfapp/settings/features.mbt`) with no local copy. `beta` follows the channel where its code runs (station features follow station channel). `experimental` starts off on both channels and toggles per device in 设置 › 实验性功能 (`betaOnly` offered on test channel only). Turning a feature off reverts UI immediately without restart. Remove the registry entry and all branches together when graduating or dropping.
