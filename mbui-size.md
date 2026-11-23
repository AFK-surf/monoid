# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [95f976d6c](https://github.com/AFK-surf/monoid/commit/95f976d6c3688024ab1db21177b5246a5bd461d6) fix(ui): keep a flying container's shadow drawn on | 2.74 | 3.69 | 14.95 | 37.14 | 56.93 | 32.51 | 66.04 | 101.09 | 118.55 |
| [714c5b362](https://github.com/AFK-surf/monoid/commit/714c5b362fa652cdab0dc3e615011a3a0de050c0) fix(ci): rebalance rules-fork and replica-retire s | 2.74 | 3.69 | 14.95 | 37.13 | 56.92 | 32.51 | 66.04 | 100.96 | 117.5 |
| [10a0c2b8f](https://github.com/AFK-surf/monoid/commit/10a0c2b8fce2642bdf8ae2f8295396bec0914be3) feat(ui,mbui): Phase 3B explicit StageOrigin, clea | 2.74 | 3.69 | 14.95 | 37.13 | 56.92 | 32.51 | 66.04 | 100.96 | 117.5 |
| [e038a5c0b](https://github.com/AFK-surf/monoid/commit/e038a5c0b698b0b6a3394a6e2da695bef8f89b83) feat(station): cap default remote browser screenca | 2.74 | 3.69 | 14.94 | 37.13 | 56.92 | 32.51 | 66.04 | 101.22 | 120.35 |
| [a8b332d2f](https://github.com/AFK-surf/monoid/commit/a8b332d2f3eeaa44a1fabefd96f5af2913772a35) test(e2e): serialize fake claude turns, send held  | 2.74 | 3.69 | 14.94 | 37.13 | 56.92 | 32.51 | 66.04 | 101.17 | 144.6 |
| [e4c4c5abc](https://github.com/AFK-surf/monoid/commit/e4c4c5abc0fbcde0da13426e38aa22c8bd3d35be) feat(pion-core): wake the core worker natively and | 2.74 | 3.69 | 14.94 | 37.13 | 56.92 | 32.51 | 66.04 | 101.17 | 144.6 |
| [55d4cd98a](https://github.com/AFK-surf/monoid/commit/55d4cd98aad6acb1b3ae9d2a29095da6b76d4481) refactor(ui): migrate controls overlays, drawer, a | 2.74 | 3.69 | 14.94 | 37.13 | 56.92 | 32.51 | 66.02 | 101.02 | 97.79 |
| [42840c9fd](https://github.com/AFK-surf/monoid/commit/42840c9fd2e9ea8baca1ce606efe1540a3720397) refactor(ui): migrate remaining controls widgets t | 2.74 | 3.68 | 14.93 | 37.12 | 56.89 | 32.51 | 66.02 | 101.02 | 127.06 |
| [fe7620826](https://github.com/AFK-surf/monoid/commit/fe76208265984fa7fdaf635ef0e6b653bf48be2d) fix(mbui,i18n): pass preferred device language to  | 2.74 | 3.68 | 14.93 | 37.1 | 56.86 | 32.5 | 65.99 | 101.02 | 123.61 |
| [1c6f7ba9e](https://github.com/AFK-surf/monoid/commit/1c6f7ba9e306cce12b17a9961a9405bed7775e31) fix(mbui): show overflowed iOS Duo tabs in a nativ | 2.74 | 3.68 | 14.93 | 37.1 | 56.86 | 32.5 | 65.99 | 100.8 | 114.91 |
| [a7554d680](https://github.com/AFK-surf/monoid/commit/a7554d6800128293eae5b055843e068716aa51cf) docs(releases): 0.1.11070 stable notes (#8347) | 2.74 | 3.68 | 14.93 | 37.1 | 56.86 | 32.5 | 65.99 | 100.8 | 114.91 |
| [d0956dae2](https://github.com/AFK-surf/monoid/commit/d0956dae2dbd48b6604fa2b3fa8bba0f475254d9) fix(station): name the leading chat by its title i | 2.74 | 3.68 | 14.93 | 37.1 | 56.86 | 32.5 | 65.99 | 100.8 | 114.91 |
| [c1073d009](https://github.com/AFK-surf/monoid/commit/c1073d0090201275e1e6767f3c16507e201a962e) perf(ui,mbui): eliminate O(N^2) FLIP diff, full-tr | 2.74 | 3.68 | 14.93 | 37.1 | 56.85 | 32.5 | 65.99 | 100.93 | 118.87 |
| [589f169b6](https://github.com/AFK-surf/monoid/commit/589f169b6531ea5217dcf19380b123bd393c7ccc) fix(mbui,ui,core): keep replied bubble and working | 2.74 | 3.68 | 14.92 | 37.1 | 56.85 | 32.5 | 65.99 | 101.24 | 119.54 |
| [da8a0a85d](https://github.com/AFK-surf/monoid/commit/da8a0a85dc969d1444a0ae7104d2453c760ad3b5) fix(helper): decode the cursor scoreboard strictly | 2.74 | 3.68 | 14.92 | 37.1 | 56.85 | 32.5 | 65.99 | 101.24 | 119.54 |
| [c2e203d5f](https://github.com/AFK-surf/monoid/commit/c2e203d5f86217782a1aa8b450f320d9ac1b9a25) feat(pion): add prefs.set, doing tracker, and SSE  | 2.74 | 3.68 | 14.92 | 37.1 | 56.85 | 32.5 | 65.99 | 101.24 | 119.54 |
| [19c48cfb4](https://github.com/AFK-surf/monoid/commit/19c48cfb4574abbb4f542c5f4d8f516df90bf2b5) feat(ui): absorb control-layer behaviors into head | 2.74 | 3.68 | 14.92 | 37.1 | 56.85 | 32.5 | 65.99 | 101.24 | 119.54 |
| [47e246545](https://github.com/AFK-surf/monoid/commit/47e2465454d6bed53eec810e2b2add228b2364fe) fix(helper): ignore typing cursor obscure in macOS | 2.74 | 3.68 | 14.92 | 37.1 | 56.85 | 32.5 | 65.99 | 101.24 | 119.54 |
| [dd3b6ec54](https://github.com/AFK-surf/monoid/commit/dd3b6ec5435eb7dfba2807386e185eb8d8d8123c) feat(station,mbui): show each backup keeper's prog | 2.74 | 3.68 | 14.92 | 37.1 | 56.85 | 32.5 | 65.99 | 101.24 | 119.54 |
| [65b57cfa2](https://github.com/AFK-surf/monoid/commit/65b57cfa229678239b35658828e33fcec0fd2fcf) test(pion): add L4 TS-vs-Pion deep domain behavior | 2.74 | 3.68 | 14.92 | 37.1 | 56.84 | 32.49 | 65.97 | 101.12 | 127.44 |
| [4bee15bee](https://github.com/AFK-surf/monoid/commit/4bee15bee67ed648e94cbf0a85aba610553e65bd) feat(mbui): add opt-in STILLFAIL_CORE=pion macOS b | 2.74 | 3.68 | 14.92 | 37.1 | 56.84 | 32.49 | 65.97 | 100.96 | 120.36 |
| [b9ba82a65](https://github.com/AFK-surf/monoid/commit/b9ba82a65257adc5889f61cf930ed1e698b150a6) fix(core,station): reduce sqlite disk writes durin | 2.74 | 3.68 | 14.92 | 37.1 | 56.84 | 32.49 | 65.97 | 100.96 | 120.36 |
| [9fe8e5978](https://github.com/AFK-surf/monoid/commit/9fe8e597874d74064c2c723ba4891a5b32af080e) refactor(mbui): zero out remaining old-list, old-s | 2.74 | 3.68 | 14.92 | 37.1 | 56.84 | 32.49 | 65.97 | 100.98 | 127.63 |
| [4bf06aed2](https://github.com/AFK-surf/monoid/commit/4bf06aed222f21fa5c4166e34f07676621346eb5) feat(ui): add continuous glass frost control and i | 2.74 | 3.68 | 14.92 | 37.1 | 56.84 | 32.49 | 65.97 | 100.98 | 127.63 |
| [6f3b36a66](https://github.com/AFK-surf/monoid/commit/6f3b36a661c600080e492e49fc49cfe981e16b73) test(pion): add L3 TS-vs-Pion differential parity  | 2.73 | 3.68 | 14.91 | 37.09 | 56.82 | 32.48 | 65.97 | 101.07 | 132.14 |
| [03be8a1bb](https://github.com/AFK-surf/monoid/commit/03be8a1bb0b100130890aed6b3a8436b69d3b95a) fix(ui): count Windows dropped frames from DWM syn | 2.73 | 3.68 | 14.91 | 37.09 | 56.82 | 32.48 | 65.97 | 101.07 | 132.14 |
| [c37b4165c](https://github.com/AFK-surf/monoid/commit/c37b4165c270850041448958f0030387fd4b7bf7) fix(ui): show composer words in the text loupe and | 2.73 | 3.68 | 14.91 | 37.09 | 56.82 | 32.48 | 65.97 | 100.83 | 127.46 |
| [b45e9603f](https://github.com/AFK-surf/monoid/commit/b45e9603f6c253d97a5cc5e8961df091ad741cea) fix(station): add explicit string type to enum-onl | 2.73 | 3.68 | 14.91 | 37.09 | 56.82 | 32.48 | 65.97 | 100.44 | 132.06 |
| [dfcde34c0](https://github.com/AFK-surf/monoid/commit/dfcde34c089d4df139ef20f962ff5fa96f34e632) test(pion): add L1/L2 TS-vs-Pion differential pari | 2.73 | 3.68 | 14.91 | 37.09 | 56.82 | 32.48 | 65.97 | 100.44 | 132.06 |
| [7ba6b7030](https://github.com/AFK-surf/monoid/commit/7ba6b7030c6551a6974b32fe1dc1796955ec35d2) feat(ui): add runtime Agent Bridge protocol on vie | 2.73 | 3.68 | 14.91 | 37.09 | 56.82 | 32.48 | 65.97 | 100.44 | 132.06 |
| [62801b760](https://github.com/AFK-surf/monoid/commit/62801b76096c861e6fe7b463fc0463b5a43079af) feat(headless): add reorder/transfer, tree, and me | 2.73 | 3.68 | 14.91 | 37.09 | 56.8 | 32.48 | 65.96 | 100.44 | 128.5 |
| [a09f1aec1](https://github.com/AFK-surf/monoid/commit/a09f1aec17d98631174f16e4fa75a21cf6256adc) feat(mbui): apply Liquid Glass surface to narrow o | 2.73 | 3.68 | 14.91 | 37.08 | 56.8 | 32.48 | 65.96 | 100.42 | 137.83 |
| [3c0c201f1](https://github.com/AFK-surf/monoid/commit/3c0c201f15d8d3d3b95f40c342a78df488e34932) revert(pion-app): revert #8307 off-track sf_ui imp | 2.73 | 3.68 | 14.91 | 37.08 | 56.8 | 32.48 | 65.96 | 100.42 | 137.83 |
| [21a57831d](https://github.com/AFK-surf/monoid/commit/21a57831d4729563cfc2cc9930d433fdb581e2a4) perf(ui,mbui): reduce side-panel slide frame cost  | 2.73 | 3.68 | 14.91 | 37.08 | 56.8 | 32.48 | 65.96 | 100.42 | 137.83 |
| [84566e834](https://github.com/AFK-surf/monoid/commit/84566e834def6737fddc28b5d8ea9b85e2a00fe8) fix(station): include check-discovered models in M | 2.73 | 3.68 | 14.91 | 37.08 | 56.79 | 32.48 | 65.96 | 100.19 | 110.17 |
| [8ac524d7f](https://github.com/AFK-surf/monoid/commit/8ac524d7f847da4e3ed251be1524f9e3d826cd18) feat(pion-rules): add #verify and zero-sorry Lean  | 2.73 | 3.68 | 14.9 | 37.06 | 56.76 | 32.47 | 65.92 | 100.45 | 122.88 |
| [d1826a13e](https://github.com/AFK-surf/monoid/commit/d1826a13e087adc3687732c639f2f0221eb26167) fix(e2e): end the fake claude's turn on a remote t | 2.73 | 3.68 | 14.9 | 37.06 | 56.76 | 32.47 | 65.92 | 101.02 | 121.62 |
| [2aba0c6e4](https://github.com/AFK-surf/monoid/commit/2aba0c6e4985ae0f16e6bf62b6a8798fa0301f27) fix(ui): fix adaptive liquid glass pill hover wash | 2.73 | 3.68 | 14.9 | 37.06 | 56.76 | 32.47 | 65.92 | 101.02 | 121.62 |
| [48b7e7c70](https://github.com/AFK-surf/monoid/commit/48b7e7c70512d20285343222ff81cd14f5285221) fix(mbui): align model picker details to the name  | 2.73 | 3.68 | 14.9 | 37.06 | 56.76 | 32.47 | 65.92 | 101.02 | 121.62 |
| [f350f6162](https://github.com/AFK-surf/monoid/commit/f350f6162b1051720cdebd6f75ada97727680a12) feat(station,client,mbui): add local station repla | 2.73 | 3.68 | 14.9 | 37.07 | 56.76 | 32.47 | 65.92 | 100.52 | 113.6 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [95f976d6c](https://github.com/AFK-surf/monoid/commit/95f976d6c3688024ab1db21177b5246a5bd461d6) fix(ui): keep a flying container's shadow drawn on | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.61 |
| [714c5b362](https://github.com/AFK-surf/monoid/commit/714c5b362fa652cdab0dc3e615011a3a0de050c0) fix(ci): rebalance rules-fork and replica-retire s | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.79 |
| [10a0c2b8f](https://github.com/AFK-surf/monoid/commit/10a0c2b8fce2642bdf8ae2f8295396bec0914be3) feat(ui,mbui): Phase 3B explicit StageOrigin, clea | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.9 |
| [e038a5c0b](https://github.com/AFK-surf/monoid/commit/e038a5c0b698b0b6a3394a6e2da695bef8f89b83) feat(station): cap default remote browser screenca | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.9 |
| [a8b332d2f](https://github.com/AFK-surf/monoid/commit/a8b332d2f3eeaa44a1fabefd96f5af2913772a35) test(e2e): serialize fake claude turns, send held  | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.93 |
| [e4c4c5abc](https://github.com/AFK-surf/monoid/commit/e4c4c5abc0fbcde0da13426e38aa22c8bd3d35be) feat(pion-core): wake the core worker natively and | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.85 |
| [55d4cd98a](https://github.com/AFK-surf/monoid/commit/55d4cd98aad6acb1b3ae9d2a29095da6b76d4481) refactor(ui): migrate controls overlays, drawer, a | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.8 |
| [42840c9fd](https://github.com/AFK-surf/monoid/commit/42840c9fd2e9ea8baca1ce606efe1540a3720397) refactor(ui): migrate remaining controls widgets t | 0.55 | 0.71 | 2.79 | 3.8 | 6.88 | 2.04 | 5.64 | 57.93 |
| [fe7620826](https://github.com/AFK-surf/monoid/commit/fe76208265984fa7fdaf635ef0e6b653bf48be2d) fix(mbui,i18n): pass preferred device language to  | 0.55 | 0.71 | 2.79 | 3.8 | 6.88 | 2.04 | 5.64 | 58.18 |
| [1c6f7ba9e](https://github.com/AFK-surf/monoid/commit/1c6f7ba9e306cce12b17a9961a9405bed7775e31) fix(mbui): show overflowed iOS Duo tabs in a nativ | 0.55 | 0.71 | 2.79 | 3.8 | 6.88 | 2.04 | 5.64 | 58.25 |
| [a7554d680](https://github.com/AFK-surf/monoid/commit/a7554d6800128293eae5b055843e068716aa51cf) docs(releases): 0.1.11070 stable notes (#8347) | 0.55 | 0.71 | 2.79 | 3.8 | 6.88 | 2.04 | 5.64 | 58.23 |
| [d0956dae2](https://github.com/AFK-surf/monoid/commit/d0956dae2dbd48b6604fa2b3fa8bba0f475254d9) fix(station): name the leading chat by its title i | 0.55 | 0.71 | 2.79 | 3.8 | 6.88 | 2.04 | 5.64 | 57.8 |
| [c1073d009](https://github.com/AFK-surf/monoid/commit/c1073d0090201275e1e6767f3c16507e201a962e) perf(ui,mbui): eliminate O(N^2) FLIP diff, full-tr | 0.55 | 0.71 | 2.79 | 3.8 | 6.88 | 2.04 | 5.64 | 57.84 |
| [589f169b6](https://github.com/AFK-surf/monoid/commit/589f169b6531ea5217dcf19380b123bd393c7ccc) fix(mbui,ui,core): keep replied bubble and working | 0.55 | 0.71 | 2.79 | 3.8 | 6.88 | 2.04 | 5.64 | 58.03 |
| [da8a0a85d](https://github.com/AFK-surf/monoid/commit/da8a0a85dc969d1444a0ae7104d2453c760ad3b5) fix(helper): decode the cursor scoreboard strictly | 0.55 | 0.71 | 2.79 | 3.8 | 6.88 | 2.04 | 5.64 | 57.79 |
| [c2e203d5f](https://github.com/AFK-surf/monoid/commit/c2e203d5f86217782a1aa8b450f320d9ac1b9a25) feat(pion): add prefs.set, doing tracker, and SSE  | 0.55 | 0.71 | 2.79 | 3.8 | 6.88 | 2.04 | 5.64 | 57.79 |
| [19c48cfb4](https://github.com/AFK-surf/monoid/commit/19c48cfb4574abbb4f542c5f4d8f516df90bf2b5) feat(ui): absorb control-layer behaviors into head | 0.55 | 0.71 | 2.79 | 3.8 | 6.87 | 2.04 | 5.64 | 58.07 |
| [47e246545](https://github.com/AFK-surf/monoid/commit/47e2465454d6bed53eec810e2b2add228b2364fe) fix(helper): ignore typing cursor obscure in macOS | 0.55 | 0.71 | 2.79 | 3.8 | 6.87 | 2.04 | 5.64 | 57.56 |
| [dd3b6ec54](https://github.com/AFK-surf/monoid/commit/dd3b6ec5435eb7dfba2807386e185eb8d8d8123c) feat(station,mbui): show each backup keeper's prog | 0.55 | 0.71 | 2.79 | 3.8 | 6.87 | 2.04 | 5.64 | 57.74 |
| [65b57cfa2](https://github.com/AFK-surf/monoid/commit/65b57cfa229678239b35658828e33fcec0fd2fcf) test(pion): add L4 TS-vs-Pion deep domain behavior | 0.55 | 0.71 | 2.79 | 3.8 | 6.87 | 2.04 | 5.64 | 57.87 |
| [4bee15bee](https://github.com/AFK-surf/monoid/commit/4bee15bee67ed648e94cbf0a85aba610553e65bd) feat(mbui): add opt-in STILLFAIL_CORE=pion macOS b | 0.55 | 0.71 | 2.79 | 3.8 | 6.87 | 2.04 | 5.64 | 57.95 |
| [b9ba82a65](https://github.com/AFK-surf/monoid/commit/b9ba82a65257adc5889f61cf930ed1e698b150a6) fix(core,station): reduce sqlite disk writes durin | 0.49 | 0.64 | 2.46 | 3.52 | 5.85 | 1.8 | 4.87 | 55.69 |
| [9fe8e5978](https://github.com/AFK-surf/monoid/commit/9fe8e597874d74064c2c723ba4891a5b32af080e) refactor(mbui): zero out remaining old-list, old-s | 0.55 | 0.71 | 2.79 | 3.8 | 6.87 | 2.04 | 5.64 | 57.87 |
| [4bf06aed2](https://github.com/AFK-surf/monoid/commit/4bf06aed222f21fa5c4166e34f07676621346eb5) feat(ui): add continuous glass frost control and i | 0.49 | 0.64 | 2.46 | 3.52 | 5.85 | 1.8 | 4.87 | 55.81 |
| [6f3b36a66](https://github.com/AFK-surf/monoid/commit/6f3b36a661c600080e492e49fc49cfe981e16b73) test(pion): add L3 TS-vs-Pion differential parity  | 0.49 | 0.64 | 2.46 | 3.52 | 5.85 | 1.8 | 4.87 | 55.74 |
| [03be8a1bb](https://github.com/AFK-surf/monoid/commit/03be8a1bb0b100130890aed6b3a8436b69d3b95a) fix(ui): count Windows dropped frames from DWM syn | 0.49 | 0.64 | 2.46 | 3.52 | 5.85 | 1.8 | 4.87 | 56.02 |
| [c37b4165c](https://github.com/AFK-surf/monoid/commit/c37b4165c270850041448958f0030387fd4b7bf7) fix(ui): show composer words in the text loupe and | 0.49 | 0.64 | 2.46 | 3.52 | 5.85 | 1.8 | 4.87 | 55.64 |
| [b45e9603f](https://github.com/AFK-surf/monoid/commit/b45e9603f6c253d97a5cc5e8961df091ad741cea) fix(station): add explicit string type to enum-onl | 0.49 | 0.64 | 2.46 | 3.52 | 5.85 | 1.8 | 4.85 | 55.2 |
| [dfcde34c0](https://github.com/AFK-surf/monoid/commit/dfcde34c089d4df139ef20f962ff5fa96f34e632) test(pion): add L1/L2 TS-vs-Pion differential pari | 0.49 | 0.64 | 2.46 | 3.52 | 5.85 | 1.8 | 4.85 | 55.07 |
| [7ba6b7030](https://github.com/AFK-surf/monoid/commit/7ba6b7030c6551a6974b32fe1dc1796955ec35d2) feat(ui): add runtime Agent Bridge protocol on vie | 0.49 | 0.64 | 2.46 | 3.52 | 5.85 | 1.8 | 4.85 | 55.26 |
| [62801b760](https://github.com/AFK-surf/monoid/commit/62801b76096c861e6fe7b463fc0463b5a43079af) feat(headless): add reorder/transfer, tree, and me | 0.49 | 0.64 | 2.45 | 3.52 | 5.84 | 1.8 | 4.85 | 55.28 |
| [a09f1aec1](https://github.com/AFK-surf/monoid/commit/a09f1aec17d98631174f16e4fa75a21cf6256adc) feat(mbui): apply Liquid Glass surface to narrow o | 0.49 | 0.64 | 2.45 | 3.52 | 5.84 | 1.8 | 4.85 | 55.31 |
| [3c0c201f1](https://github.com/AFK-surf/monoid/commit/3c0c201f15d8d3d3b95f40c342a78df488e34932) revert(pion-app): revert #8307 off-track sf_ui imp | 0.49 | 0.64 | 2.45 | 3.51 | 5.83 | 1.8 | 4.85 | 55.23 |
| [21a57831d](https://github.com/AFK-surf/monoid/commit/21a57831d4729563cfc2cc9930d433fdb581e2a4) perf(ui,mbui): reduce side-panel slide frame cost  | 0.49 | 0.64 | 2.45 | 3.51 | 5.83 | 1.8 | 4.85 | 55.2 |
| [84566e834](https://github.com/AFK-surf/monoid/commit/84566e834def6737fddc28b5d8ea9b85e2a00fe8) fix(station): include check-discovered models in M | 0.49 | 0.64 | 2.45 | 3.51 | 5.83 | 1.8 | 4.85 | 55.58 |
| [8ac524d7f](https://github.com/AFK-surf/monoid/commit/8ac524d7f847da4e3ed251be1524f9e3d826cd18) feat(pion-rules): add #verify and zero-sorry Lean  | 0.49 | 0.64 | 2.45 | 3.5 | 5.81 | 1.79 | 4.83 | 55.22 |
| [d1826a13e](https://github.com/AFK-surf/monoid/commit/d1826a13e087adc3687732c639f2f0221eb26167) fix(e2e): end the fake claude's turn on a remote t | 0.49 | 0.64 | 2.45 | 3.51 | 5.83 | 1.8 | 4.85 | 55.1 |
| [2aba0c6e4](https://github.com/AFK-surf/monoid/commit/2aba0c6e4985ae0f16e6bf62b6a8798fa0301f27) fix(ui): fix adaptive liquid glass pill hover wash | 0.49 | 0.64 | 2.45 | 3.5 | 5.81 | 1.79 | 4.83 | 55.26 |
| [48b7e7c70](https://github.com/AFK-surf/monoid/commit/48b7e7c70512d20285343222ff81cd14f5285221) fix(mbui): align model picker details to the name  | 0.49 | 0.64 | 2.45 | 3.5 | 5.81 | 1.79 | 4.83 | 55 |
| [f350f6162](https://github.com/AFK-surf/monoid/commit/f350f6162b1051720cdebd6f75ada97727680a12) feat(station,client,mbui): add local station repla | 0.49 | 0.64 | 2.45 | 3.5 | 5.81 | 1.79 | 4.83 | 54.92 |
