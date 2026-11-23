# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [c9ce75bdc](https://github.com/AFK-surf/monoid/commit/c9ce75bdcb0c5c3c0204c5f42ee4b2ec033e45d3) perf(station): project each event once for all old | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 116.63 |
| [803c9e8ea](https://github.com/AFK-surf/monoid/commit/803c9e8ea2bb8e41487ff46c1f3afa81d7597bab) fix(station): report MiniMax and GLM plan quotas ( | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.62 | 118.2 |
| [68fb3c249](https://github.com/AFK-surf/monoid/commit/68fb3c2497c138f1f8790687be24c2387b487cf3) test(mbui): hold a history group's steps at their  | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.39 | 121.54 |
| [6eb1558df](https://github.com/AFK-surf/monoid/commit/6eb1558df72482940a2d8e16fe6292a29b78c145) fix(ui): grow start-indented content from its star | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.39 | 121.54 |
| [9d9b96358](https://github.com/AFK-surf/monoid/commit/9d9b96358c94ecc736a542e2ed99e9a85e1f846e) refactor(ui,mbui): clean dead controls APIs and un | 2.74 | 3.69 | 14.95 | 37.14 | 56.95 | 32.52 | 66.07 | 100.6 | 114.59 |
| [db2b6cdf5](https://github.com/AFK-surf/monoid/commit/db2b6cdf503a0fb378b372704da3c95cdf18c266) fix(pion-client-core): enforce lock genesis pinnin | 2.74 | 3.69 | 14.95 | 37.14 | 56.95 | 32.52 | 66.07 | 100.48 | 127.55 |
| [c4160616f](https://github.com/AFK-surf/monoid/commit/c4160616f52038080e27860eed80bdc1eab6592e) perf(station): keep the hub's config when a check  | 2.74 | 3.69 | 14.95 | 37.14 | 56.94 | 32.52 | 66.06 | 101.3 | 131.39 |
| [cabc742d9](https://github.com/AFK-surf/monoid/commit/cabc742d9fa13e6f7852c7ed5cb67dc16b6f5e99) perf(mbui): prewarm offscreen home chat row text a | 2.74 | 3.69 | 14.95 | 37.14 | 56.94 | 32.52 | 66.06 | 101.3 | 131.39 |
| [f32384c6d](https://github.com/AFK-surf/monoid/commit/f32384c6dbc05992d004ddb2b4e03375664f5820) feat(ui): calibrate pressed liquid glass lens and  | 2.74 | 3.69 | 14.95 | 37.14 | 56.93 | 32.51 | 66.04 | 101.09 | 118.55 |
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

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [c9ce75bdc](https://github.com/AFK-surf/monoid/commit/c9ce75bdcb0c5c3c0204c5f42ee4b2ec033e45d3) perf(station): project each event once for all old | 0.55 | 0.72 | 2.8 | 3.81 | 6.92 | 2.05 | 5.69 | 57.16 |
| [803c9e8ea](https://github.com/AFK-surf/monoid/commit/803c9e8ea2bb8e41487ff46c1f3afa81d7597bab) fix(station): report MiniMax and GLM plan quotas ( | 0.55 | 0.72 | 2.8 | 3.81 | 6.92 | 2.05 | 5.69 | 57.16 |
| [68fb3c249](https://github.com/AFK-surf/monoid/commit/68fb3c2497c138f1f8790687be24c2387b487cf3) test(mbui): hold a history group's steps at their  | 0.55 | 0.72 | 2.8 | 3.81 | 6.92 | 2.05 | 5.69 | 57.23 |
| [6eb1558df](https://github.com/AFK-surf/monoid/commit/6eb1558df72482940a2d8e16fe6292a29b78c145) fix(ui): grow start-indented content from its star | 0.55 | 0.72 | 2.8 | 3.81 | 6.92 | 2.05 | 5.69 | 57.07 |
| [9d9b96358](https://github.com/AFK-surf/monoid/commit/9d9b96358c94ecc736a542e2ed99e9a85e1f846e) refactor(ui,mbui): clean dead controls APIs and un | 0.55 | 0.72 | 2.8 | 3.81 | 6.9 | 2.04 | 5.68 | 57.31 |
| [db2b6cdf5](https://github.com/AFK-surf/monoid/commit/db2b6cdf503a0fb378b372704da3c95cdf18c266) fix(pion-client-core): enforce lock genesis pinnin | 0.55 | 0.72 | 2.8 | 3.81 | 6.9 | 2.04 | 5.68 | 57.31 |
| [c4160616f](https://github.com/AFK-surf/monoid/commit/c4160616f52038080e27860eed80bdc1eab6592e) perf(station): keep the hub's config when a check  | 0.55 | 0.72 | 2.8 | 3.81 | 6.9 | 2.04 | 5.68 | 57.85 |
| [cabc742d9](https://github.com/AFK-surf/monoid/commit/cabc742d9fa13e6f7852c7ed5cb67dc16b6f5e99) perf(mbui): prewarm offscreen home chat row text a | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.85 |
| [f32384c6d](https://github.com/AFK-surf/monoid/commit/f32384c6dbc05992d004ddb2b4e03375664f5820) feat(ui): calibrate pressed liquid glass lens and  | 0.55 | 0.72 | 2.8 | 3.81 | 6.9 | 2.04 | 5.68 | 57.28 |
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
