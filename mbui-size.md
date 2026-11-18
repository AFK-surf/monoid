# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [228075b1c](https://github.com/AFK-surf/monoid/commit/228075b1c42786382c7c7283bbdc18e99ffb4132) Show live agent output speed across a workspace (# | 2.54 | 3.41 | 13.98 | 35.9 | 53.78 | 31.48 | 63.32 | 96.77 | 116.78 |
| [3d4e7f31c](https://github.com/AFK-surf/monoid/commit/3d4e7f31c8c5cb3dd90c1edec406bfc8da86e8e5) feat(station): put the MoonBit station together wh | 2.54 | 3.41 | 13.98 | 35.9 | 53.77 | 31.47 | 63.32 | 96.99 | 123.22 |
| [8dea365d1](https://github.com/AFK-surf/monoid/commit/8dea365d1d1817c3ab8256bf568900d88cafc779) test(mbui): sizes_across bars hold what 60 and 120 | 2.54 | 3.41 | 13.98 | 35.9 | 53.77 | 31.47 | 63.32 | 96.58 | 123.22 |
| [918c33836](https://github.com/AFK-surf/monoid/commit/918c338368e4074de489f36a8f85972a98e99bdf) Merge pull request #7041 from AFK-surf/feat/scoped | 2.54 | 3.41 | 13.98 | 35.9 | 53.77 | 31.47 | 63.32 | 96.47 | 123.22 |
| [e8271ed6e](https://github.com/AFK-surf/monoid/commit/e8271ed6e93314315beb5266a2650b6b3dc9d23a) station: wait for connect file writes in tests (#7 | 2.54 | 3.41 | 13.98 | 35.19 | 53.77 | 30.78 | 61.72 | 96.47 | 123.22 |
| [0b4845931](https://github.com/AFK-surf/monoid/commit/0b4845931b37f62b20f25fce13fe46037ebe3ff1) mbui: sizes_steady measures across as down (sizes_ | 2.54 | 3.41 | 13.98 | 35.19 | 53.77 | 30.78 | 61.72 | 96.49 | 123.22 |
| [00b57b6f0](https://github.com/AFK-surf/monoid/commit/00b57b6f0c2fbd56ae6d735f9db4be3c01b5b797) sf-ui: a slider's knob glides to a key's step inst | 2.54 | 3.41 | 13.98 | 35.19 | 53.77 | 30.78 | 61.72 | 96.62 | 123.22 |
| [bbf27a761](https://github.com/AFK-surf/monoid/commit/bbf27a76104fdd6fb314451ad3f5dac026df4034) ci: build Windows release alongside setup (#7002) | 2.54 | 3.41 | 13.98 | 35.19 | 53.77 | 30.78 | 61.72 | 96.62 | 123.22 |
| [737fff83c](https://github.com/AFK-surf/monoid/commit/737fff83c7af74ae4b86a48269e881339b14d12b) mbui: drive system notifications offscreen (#7101) | 2.54 | 3.41 | 13.98 | 35.19 | 53.77 | 30.77 | 61.69 | 96.54 | 122.43 |
| [75502bc34](https://github.com/AFK-surf/monoid/commit/75502bc34a630f7b0dda5511ed14b8c111b37e8d) ci: reuse Mac app build caches safely (#7049) | 2.54 | 3.41 | 13.97 | 35.17 | 53.73 | 30.77 | 61.69 | 96.54 | 122.41 |
| [a1efb1f95](https://github.com/AFK-surf/monoid/commit/a1efb1f95543630f51c5c4c2e89ebb1bdd2ea431) mbui: guard box reads and bound press waits (#7095 | 2.54 | 3.41 | 13.97 | 35.17 | 53.73 | 30.76 | 61.69 | 96.55 | 121.64 |
| [5d60f1e5b](https://github.com/AFK-surf/monoid/commit/5d60f1e5bfccc2e05cafb7b798575b96be8b6262) app, mbui: add and dispatch board tasks with icons | 2.54 | 3.41 | 13.97 | 35.17 | 53.73 | 30.76 | 61.69 | 96.55 | 121.64 |
| [767bf3a54](https://github.com/AFK-surf/monoid/commit/767bf3a5416785c76355e2972f140b9a8ca0abf7) station: route events during handover adoption (#7 | 2.54 | 3.41 | 13.97 | 35.17 | 53.72 | 30.76 | 61.69 | 96.55 | 109.59 |
| [4c89a3b06](https://github.com/AFK-surf/monoid/commit/4c89a3b06b913256574e6fe0e82d6e2f9e113e44) Respect wrapping when measuring a nested row’s min | 2.54 | 3.41 | 13.97 | 35.17 | 53.72 | 31.69 | 64.57 | 96.45 | 119.72 |
| [fde0f64c7](https://github.com/AFK-surf/monoid/commit/fde0f64c727cddabc7ede6f4260c64dbc591097a) mbui: a page's list compiled once, not once a key  | 2.54 | 3.41 | 13.97 | 35.17 | 53.72 | 31.69 | 64.57 | 96.45 | 119.72 |
| [74df55c40](https://github.com/AFK-surf/monoid/commit/74df55c407cd82a8379c7bef1499a94390822ac8) sf-ui: extract still.fail's src/sf component libra | 2.57 | 3.63 | 15.19 | 36.33 | 57.93 | 31.69 | 64.57 | 96.45 | 124.25 |
| [4f66be198](https://github.com/AFK-surf/monoid/commit/4f66be1980197550f5bc486dc30d19acd4c592fd) Let new Claude chats default to TUI on this device | 2.57 | 3.63 | 15.19 | 36.33 | 57.93 | 31.69 | 64.57 | 96.45 | 124.25 |
| [77ebdfed6](https://github.com/AFK-surf/monoid/commit/77ebdfed6d4bf3be3b6a97810364a552e77d3209) Fix unresponsive context menus when switching card | 2.56 | 3.63 | 15.18 | 36.33 | 57.93 | 31.69 | 64.57 | 96.45 | 124.25 |
| [415ec50f8](https://github.com/AFK-surf/monoid/commit/415ec50f85085a14cebd8ceeb21102bf6655ce09) Align marks in chat-list rows (#6455) | 2.56 | 3.63 | 15.18 | 36.33 | 57.93 | 31.69 | 64.57 | 96.42 | 120.63 |
| [2cea29165](https://github.com/AFK-surf/monoid/commit/2cea29165294fd7b43bcfe7d2115c091f4c5b0e2) admin: dual-brand console, feedback replies, relay | 2.56 | 3.63 | 15.18 | 36.33 | 57.93 | 31.69 | 64.57 | 96.42 | 120.63 |
| [7f4127bab](https://github.com/AFK-surf/monoid/commit/7f4127babaf94ca2b9c48155067e27adf4df7769) station test: await home's background relayStatus  | 2.56 | 3.63 | 15.18 | 36.32 | 57.93 | 31.67 | 64.57 | 96.49 | 127.43 |
| [b199c2d64](https://github.com/AFK-surf/monoid/commit/b199c2d648538499e233464c7ae2799b7ad79684) mbui: bound transition holds on the tree timeline  | 2.56 | 3.63 | 15.18 | 36.32 | 58.04 | 31.67 | 64.57 | 96.49 | 127.01 |
| [22d710a47](https://github.com/AFK-surf/monoid/commit/22d710a4790454fb0face4be2d50b8e15ddbefb0) mbui: add writable derivations, optimistic project | 2.56 | 3.63 | 15.18 | 36.32 | 58.04 | 31.66 | 64.57 | 96.21 | 124.28 |
| [0e7a6fd68](https://github.com/AFK-surf/monoid/commit/0e7a6fd68280c9c72a313cab07f0b2107b84fb78) Choose the Claude TUI runtime in model settings (# | 2.56 | 3.63 | 15.18 | 36.32 | 58.04 | 31.66 | 64.57 | 96.21 | 124.28 |
| [9cc460c07](https://github.com/AFK-surf/monoid/commit/9cc460c078d346956000a18aeb25b2d101be646d) mbui: reuse each layout tree on its own pixel grid | 2.57 | 3.63 | 15.18 | 36.31 | 58.04 | 32.51 | 68.98 | 96.26 | 115.92 |
| [7ea31c7e4](https://github.com/AFK-surf/monoid/commit/7ea31c7e4681f5ba1f74094658295c348aada469) Farview Stage 7: the app's tab draws native select | 2.56 | 3.62 | 15.18 | 36.31 | 58.03 | 32.51 | 68.98 | 96.26 | 123.94 |
| [319f56e71](https://github.com/AFK-surf/monoid/commit/319f56e71cc8f72ea1f6319aef10d5aff0381166) core: only the opener is reminded of a long-runnin | 2.57 | 3.64 | 15.96 | 37.31 | 63.51 | 32.51 | 68.98 | 96.26 | 123.8 |
| [50c369b3a](https://github.com/AFK-surf/monoid/commit/50c369b3a932b2457cb0b15f22497a1a58ce1d92) mbui: pick and structured compiled once, not once  | 2.57 | 3.64 | 15.96 | 37.31 | 63.5 | 32.51 | 68.98 | 96.26 | 117.52 |
| [b1ca91efa](https://github.com/AFK-surf/monoid/commit/b1ca91efaeee3bf1d5a27f78125ddf4cfda615d4) mbui: two-finger swipe back and scrollable executi | 2.57 | 3.64 | 15.96 | 37.31 | 63.5 | 32.51 | 68.98 | 96.26 | 117.52 |
| [183c0c53f](https://github.com/AFK-surf/monoid/commit/183c0c53fc9ce1437e9673f01fe39306dccb27f1) Android: upload the glyphs a picture draws before  | 2.57 | 3.64 | 15.96 | 37.31 | 63.5 | 32.51 | 68.98 | 96.26 | 117.52 |
| [2a690a24c](https://github.com/AFK-surf/monoid/commit/2a690a24c1d279c850706f58b9eb198e9d0c707d) Show workflow progress and step logs on GitHub Act | 2.57 | 3.64 | 15.96 | 37.31 | 63.5 | 32.51 | 68.98 | 96.26 | 117.52 |
| [78e0e3bc4](https://github.com/AFK-surf/monoid/commit/78e0e3bc45acac13f84ba9f1517239a74e428f0f) app: open notified chats in the current board or c | 2.57 | 3.63 | 15.93 | 37.27 | 63.38 | 32.51 | 68.98 | 96.26 | 123.64 |
| [d18bcc13b](https://github.com/AFK-surf/monoid/commit/d18bcc13b15f9a3f38d781ec07eb38d7d9c29ae9) mbui: what a chat's composer made as nodes asks of | 2.57 | 3.63 | 15.92 | 37.26 | 63.36 | 32.51 | 68.98 | 96.26 | 120.55 |
| [4cc373f9f](https://github.com/AFK-surf/monoid/commit/4cc373f9f84fab44e570275f29396dfdba86c5ab) station: a batch taken as its process is let go is | 2.57 | 3.63 | 15.92 | 37.26 | 63.36 | 32.51 | 68.98 | 96.26 | 120.55 |
| [f763bcf4e](https://github.com/AFK-surf/monoid/commit/f763bcf4e04a4fcf6552c59186f5a46771ca28c6) ci: publish ready beta feeds when the Android job  | 2.56 | 3.63 | 15.92 | 37.26 | 63.36 | 32.51 | 68.98 | 96.26 | 114.21 |
| [f18d30634](https://github.com/AFK-surf/monoid/commit/f18d3063414e5f696a1782eae614d560b99df6e7) app: a process's stop sits on its name's line on a | 2.57 | 3.63 | 15.92 | 37.26 | 63.36 | 32.51 | 68.98 | 96.26 | 122.81 |
| [bc074d677](https://github.com/AFK-surf/monoid/commit/bc074d67709bfcf785c69f67ad34d3f3b3400f8e) station: tell the workspace when its last terminal | 2.56 | 3.62 | 15.8 | 37.18 | 62.82 | 32.51 | 68.98 | 96.26 | 125.26 |
| [7f8b43bd1](https://github.com/AFK-surf/monoid/commit/7f8b43bd1f84373744e88f3abada311916279df8) app: what lights a message whole is one band the l | 2.56 | 3.62 | 15.8 | 37.18 | 62.82 | 32.51 | 68.98 | 96.14 | 125.72 |
| [8aa48a00c](https://github.com/AFK-surf/monoid/commit/8aa48a00c6a2fa69d3d45b1b873aa1de75626e9e) release: resolve the previous stable base SHA when | 2.56 | 3.62 | 15.8 | 37.18 | 62.82 | 32.51 | 68.98 | 96.14 | 125.72 |
| [4c9974d97](https://github.com/AFK-surf/monoid/commit/4c9974d978dda945aaf942569ce00b751874b9f5) app: mark the station process group (#6962) | 2.56 | 3.62 | 15.8 | 37.18 | 62.82 | 32.51 | 68.98 | 96.34 | 125.46 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [228075b1c](https://github.com/AFK-surf/monoid/commit/228075b1c42786382c7c7283bbdc18e99ffb4132) Show live agent output speed across a workspace (# | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.51 |
| [3d4e7f31c](https://github.com/AFK-surf/monoid/commit/3d4e7f31c8c5cb3dd90c1edec406bfc8da86e8e5) feat(station): put the MoonBit station together wh | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.51 |
| [8dea365d1](https://github.com/AFK-surf/monoid/commit/8dea365d1d1817c3ab8256bf568900d88cafc779) test(mbui): sizes_across bars hold what 60 and 120 | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.51 |
| [918c33836](https://github.com/AFK-surf/monoid/commit/918c338368e4074de489f36a8f85972a98e99bdf) Merge pull request #7041 from AFK-surf/feat/scoped | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.58 |
| [e8271ed6e](https://github.com/AFK-surf/monoid/commit/e8271ed6e93314315beb5266a2650b6b3dc9d23a) station: wait for connect file writes in tests (#7 | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.58 |
| [0b4845931](https://github.com/AFK-surf/monoid/commit/0b4845931b37f62b20f25fce13fe46037ebe3ff1) mbui: sizes_steady measures across as down (sizes_ | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.58 |
| [00b57b6f0](https://github.com/AFK-surf/monoid/commit/00b57b6f0c2fbd56ae6d735f9db4be3c01b5b797) sf-ui: a slider's knob glides to a key's step inst | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.58 |
| [bbf27a761](https://github.com/AFK-surf/monoid/commit/bbf27a76104fdd6fb314451ad3f5dac026df4034) ci: build Windows release alongside setup (#7002) | 0.43 | 0.57 | 2.18 | 3.27 | 5.21 | 1.59 | 4.28 | 53.43 |
| [737fff83c](https://github.com/AFK-surf/monoid/commit/737fff83c7af74ae4b86a48269e881339b14d12b) mbui: drive system notifications offscreen (#7101) | 0.43 | 0.57 | 2.18 | 3.27 | 5.21 | 1.59 | 4.28 | 53.43 |
| [75502bc34](https://github.com/AFK-surf/monoid/commit/75502bc34a630f7b0dda5511ed14b8c111b37e8d) ci: reuse Mac app build caches safely (#7049) | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.59 | 4.28 | 53.54 |
| [a1efb1f95](https://github.com/AFK-surf/monoid/commit/a1efb1f95543630f51c5c4c2e89ebb1bdd2ea431) mbui: guard box reads and bound press waits (#7095 | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.59 | 4.28 | 53.54 |
| [5d60f1e5b](https://github.com/AFK-surf/monoid/commit/5d60f1e5bfccc2e05cafb7b798575b96be8b6262) app, mbui: add and dispatch board tasks with icons | 0.43 | 0.56 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.45 |
| [767bf3a54](https://github.com/AFK-surf/monoid/commit/767bf3a5416785c76355e2972f140b9a8ca0abf7) station: route events during handover adoption (#7 | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.27 |
| [4c89a3b06](https://github.com/AFK-surf/monoid/commit/4c89a3b06b913256574e6fe0e82d6e2f9e113e44) Respect wrapping when measuring a nested row’s min | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.27 |
| [fde0f64c7](https://github.com/AFK-surf/monoid/commit/fde0f64c727cddabc7ede6f4260c64dbc591097a) mbui: a page's list compiled once, not once a key  | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.51 |
| [74df55c40](https://github.com/AFK-surf/monoid/commit/74df55c407cd82a8379c7bef1499a94390822ac8) sf-ui: extract still.fail's src/sf component libra | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.51 |
| [4f66be198](https://github.com/AFK-surf/monoid/commit/4f66be1980197550f5bc486dc30d19acd4c592fd) Let new Claude chats default to TUI on this device | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.46 |
| [77ebdfed6](https://github.com/AFK-surf/monoid/commit/77ebdfed6d4bf3be3b6a97810364a552e77d3209) Fix unresponsive context menus when switching card | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.46 |
| [415ec50f8](https://github.com/AFK-surf/monoid/commit/415ec50f85085a14cebd8ceeb21102bf6655ce09) Align marks in chat-list rows (#6455) | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.46 |
| [2cea29165](https://github.com/AFK-surf/monoid/commit/2cea29165294fd7b43bcfe7d2115c091f4c5b0e2) admin: dual-brand console, feedback replies, relay | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.4 |
| [7f4127bab](https://github.com/AFK-surf/monoid/commit/7f4127babaf94ca2b9c48155067e27adf4df7769) station test: await home's background relayStatus  | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.4 |
| [b199c2d64](https://github.com/AFK-surf/monoid/commit/b199c2d648538499e233464c7ae2799b7ad79684) mbui: bound transition holds on the tree timeline  | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.4 |
| [22d710a47](https://github.com/AFK-surf/monoid/commit/22d710a4790454fb0face4be2d50b8e15ddbefb0) mbui: add writable derivations, optimistic project | 0.43 | 0.56 | 2.17 | 3.27 | 5.19 | 1.59 | 4.28 | 53.4 |
| [0e7a6fd68](https://github.com/AFK-surf/monoid/commit/0e7a6fd68280c9c72a313cab07f0b2107b84fb78) Choose the Claude TUI runtime in model settings (# | 0.43 | 0.56 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.64 |
| [9cc460c07](https://github.com/AFK-surf/monoid/commit/9cc460c078d346956000a18aeb25b2d101be646d) mbui: reuse each layout tree on its own pixel grid | 0.43 | 0.56 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.64 |
| [7ea31c7e4](https://github.com/AFK-surf/monoid/commit/7ea31c7e4681f5ba1f74094658295c348aada469) Farview Stage 7: the app's tab draws native select | 0.43 | 0.56 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.45 |
| [319f56e71](https://github.com/AFK-surf/monoid/commit/319f56e71cc8f72ea1f6319aef10d5aff0381166) core: only the opener is reminded of a long-runnin | 0.43 | 0.56 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.45 |
| [50c369b3a](https://github.com/AFK-surf/monoid/commit/50c369b3a932b2457cb0b15f22497a1a58ce1d92) mbui: pick and structured compiled once, not once  | 0.43 | 0.56 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.45 |
| [b1ca91efa](https://github.com/AFK-surf/monoid/commit/b1ca91efaeee3bf1d5a27f78125ddf4cfda615d4) mbui: two-finger swipe back and scrollable executi | 0.43 | 0.56 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.33 |
| [183c0c53f](https://github.com/AFK-surf/monoid/commit/183c0c53fc9ce1437e9673f01fe39306dccb27f1) Android: upload the glyphs a picture draws before  | 0.43 | 0.56 | 2.17 | 3.26 | 5.19 | 1.59 | 4.26 | 53.45 |
| [2a690a24c](https://github.com/AFK-surf/monoid/commit/2a690a24c1d279c850706f58b9eb198e9d0c707d) Show workflow progress and step logs on GitHub Act | 0.43 | 0.56 | 2.17 | 3.26 | 5.19 | 1.59 | 4.26 | 53.45 |
| [78e0e3bc4](https://github.com/AFK-surf/monoid/commit/78e0e3bc45acac13f84ba9f1517239a74e428f0f) app: open notified chats in the current board or c | 0.43 | 0.56 | 2.17 | 3.26 | 5.19 | 1.59 | 4.26 | 53.45 |
| [d18bcc13b](https://github.com/AFK-surf/monoid/commit/d18bcc13b15f9a3f38d781ec07eb38d7d9c29ae9) mbui: what a chat's composer made as nodes asks of | 0.43 | 0.56 | 2.17 | 3.26 | 5.19 | 1.59 | 4.26 | 53.45 |
| [4cc373f9f](https://github.com/AFK-surf/monoid/commit/4cc373f9f84fab44e570275f29396dfdba86c5ab) station: a batch taken as its process is let go is | 0.43 | 0.56 | 2.16 | 3.26 | 5.18 | 1.59 | 4.26 | 53.53 |
| [f763bcf4e](https://github.com/AFK-surf/monoid/commit/f763bcf4e04a4fcf6552c59186f5a46771ca28c6) ci: publish ready beta feeds when the Android job  | 0.43 | 0.56 | 2.16 | 3.26 | 5.18 | 1.59 | 4.26 | 53.53 |
| [f18d30634](https://github.com/AFK-surf/monoid/commit/f18d3063414e5f696a1782eae614d560b99df6e7) app: a process's stop sits on its name's line on a | 0.43 | 0.56 | 2.16 | 3.26 | 5.18 | 1.59 | 4.26 | 53.53 |
| [bc074d677](https://github.com/AFK-surf/monoid/commit/bc074d67709bfcf785c69f67ad34d3f3b3400f8e) station: tell the workspace when its last terminal | 0.43 | 0.56 | 2.16 | 3.26 | 5.18 | 1.59 | 4.26 | 53.53 |
| [7f8b43bd1](https://github.com/AFK-surf/monoid/commit/7f8b43bd1f84373744e88f3abada311916279df8) app: what lights a message whole is one band the l | 0.43 | 0.56 | 2.16 | 3.26 | 5.18 | 1.59 | 4.26 | 53.53 |
| [8aa48a00c](https://github.com/AFK-surf/monoid/commit/8aa48a00c6a2fa69d3d45b1b873aa1de75626e9e) release: resolve the previous stable base SHA when | 0.43 | 0.56 | 2.16 | 3.26 | 5.18 | 1.59 | 4.26 | 53.3 |
| [4c9974d97](https://github.com/AFK-surf/monoid/commit/4c9974d978dda945aaf942569ce00b751874b9f5) app: mark the station process group (#6962) | 0.43 | 0.56 | 2.16 | 3.26 | 5.18 | 1.59 | 4.26 | 53.3 |
