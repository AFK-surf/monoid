# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [2404366b0](https://github.com/AFK-surf/monoid/commit/2404366b025c3ddd751494997dc1eb64090a3c1a) feat(station): say how short of CPU and memory the | 2.73 | 3.68 | 14.9 | 37.06 | 56.75 | 32.46 | 65.91 | 100.45 | 124.75 |
| [883168f18](https://github.com/AFK-surf/monoid/commit/883168f18fe1ca56393cd0c157cc1dc2faa44398) fix(ui): flip adaptive glass ink to white over App | 2.73 | 3.67 | 14.89 | 37.06 | 56.73 | 32.46 | 65.91 | 100.45 | 124.75 |
| [176fd2214](https://github.com/AFK-surf/monoid/commit/176fd2214c057552f53402dbe77bc28280a641af) feat(ui,mbui): extend liquid glass morphing to pan | 2.73 | 3.67 | 14.89 | 37.06 | 56.73 | 32.46 | 65.91 | 100.58 | 113.28 |
| [6c6003fb0](https://github.com/AFK-surf/monoid/commit/6c6003fb081fea01448bcb2fbc3f99a905f9f707) feat(client-core): add batch 3 pure-Pion views, wi | 2.73 | 3.67 | 14.89 | 37.06 | 56.73 | 32.46 | 65.91 | 100.58 | 113.28 |
| [1273b1fd4](https://github.com/AFK-surf/monoid/commit/1273b1fd443398b42169f28c2231cf258111722c) fix(ui): place popovers clear of the window's own  | 2.73 | 3.67 | 14.89 | 37.06 | 56.73 | 32.46 | 65.91 | 100.58 | 113.28 |
| [9ce847dfe](https://github.com/AFK-surf/monoid/commit/9ce847dfebf3c9ceee104640eda346dce9efd4bf) feat(client-core): wire views projections into Cli | 2.73 | 3.67 | 14.89 | 37.06 | 56.73 | 32.46 | 65.91 | 100.42 | 124.6 |
| [34df40aaa](https://github.com/AFK-surf/monoid/commit/34df40aaa4d4948a5be5ce4e194ad830405883bc) feat(station): a switch on Antigravity profiles fo | 2.73 | 3.67 | 14.89 | 37.06 | 56.73 | 32.45 | 65.89 | 100.52 | 128.2 |
| [ac5672f84](https://github.com/AFK-surf/monoid/commit/ac5672f843714a2096df49c0980cf525fd100980) feat(station): add Google Vertex AI account for An | 2.73 | 3.67 | 14.88 | 37.06 | 56.72 | 32.45 | 65.87 | 100.42 | 127.1 |
| [a8a14a344](https://github.com/AFK-surf/monoid/commit/a8a14a344e856480c9715f797eb82215bc57c77d) feat(client-core): add pure-Pion views package and | 2.73 | 3.67 | 14.88 | 37.06 | 56.72 | 32.45 | 65.87 | 100.42 | 127.1 |
| [0cf13ac28](https://github.com/AFK-surf/monoid/commit/0cf13ac287d0fbbfef92ced562f04efb36ce4596) feat(core,mbui): support multi-workspace tasks-onl | 2.73 | 3.67 | 14.88 | 37.04 | 56.71 | 32.45 | 65.87 | 100.3 | 127.89 |
| [8126680e5](https://github.com/AFK-surf/monoid/commit/8126680e52043bc4a5e191b5b5fc756224a9266f) fix(mbui): phase 3a chat motion fixes for composer | 2.73 | 3.67 | 14.88 | 37.04 | 56.71 | 32.45 | 65.87 | 100.3 | 127.89 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [2404366b0](https://github.com/AFK-surf/monoid/commit/2404366b025c3ddd751494997dc1eb64090a3c1a) feat(station): say how short of CPU and memory the | 0.49 | 0.64 | 2.45 | 3.5 | 5.81 | 1.79 | 4.83 | 54.64 |
| [883168f18](https://github.com/AFK-surf/monoid/commit/883168f18fe1ca56393cd0c157cc1dc2faa44398) fix(ui): flip adaptive glass ink to white over App | 0.49 | 0.64 | 2.45 | 3.5 | 5.81 | 1.79 | 4.83 | 55.05 |
| [176fd2214](https://github.com/AFK-surf/monoid/commit/176fd2214c057552f53402dbe77bc28280a641af) feat(ui,mbui): extend liquid glass morphing to pan | 0.49 | 0.64 | 2.45 | 3.5 | 5.81 | 1.79 | 4.83 | 55.18 |
| [6c6003fb0](https://github.com/AFK-surf/monoid/commit/6c6003fb081fea01448bcb2fbc3f99a905f9f707) feat(client-core): add batch 3 pure-Pion views, wi | 0.49 | 0.64 | 2.45 | 3.51 | 5.81 | 1.79 | 4.83 | 55.02 |
| [1273b1fd4](https://github.com/AFK-surf/monoid/commit/1273b1fd443398b42169f28c2231cf258111722c) fix(ui): place popovers clear of the window's own  | 0.49 | 0.64 | 2.45 | 3.51 | 5.81 | 1.79 | 4.83 | 55.28 |
| [9ce847dfe](https://github.com/AFK-surf/monoid/commit/9ce847dfebf3c9ceee104640eda346dce9efd4bf) feat(client-core): wire views projections into Cli | 0.49 | 0.64 | 2.45 | 3.51 | 5.81 | 1.79 | 4.83 | 55.28 |
| [34df40aaa](https://github.com/AFK-surf/monoid/commit/34df40aaa4d4948a5be5ce4e194ad830405883bc) feat(station): a switch on Antigravity profiles fo | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.79 | 4.83 | 55.26 |
| [ac5672f84](https://github.com/AFK-surf/monoid/commit/ac5672f843714a2096df49c0980cf525fd100980) feat(station): add Google Vertex AI account for An | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.79 | 4.83 | 55.48 |
| [a8a14a344](https://github.com/AFK-surf/monoid/commit/a8a14a344e856480c9715f797eb82215bc57c77d) feat(client-core): add pure-Pion views package and | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.79 | 4.83 | 54.92 |
| [0cf13ac28](https://github.com/AFK-surf/monoid/commit/0cf13ac287d0fbbfef92ced562f04efb36ce4596) feat(core,mbui): support multi-workspace tasks-onl | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.79 | 4.83 | 54.99 |
| [8126680e5](https://github.com/AFK-surf/monoid/commit/8126680e52043bc4a5e191b5b5fc756224a9266f) fix(mbui): phase 3a chat motion fixes for composer | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.79 | 4.83 | 55.25 |
