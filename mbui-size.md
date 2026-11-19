# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [5f9f2dfa2](https://github.com/AFK-surf/monoid/commit/5f9f2dfa2a0399c6f0b653b441d97a3c8925c6de) fix(app): settings search finds settings by what p | 2.61 | 3.51 | 14.34 | 36.44 | 55.28 | 31.92 | 64.52 | 97.21 | 115.97 |
| [9d591d003](https://github.com/AFK-surf/monoid/commit/9d591d003a8ea8c8ad92538b70889a14c7a2e43e) mbui app: a new chat made as nodes with its compos | 2.61 | 3.51 | 14.33 | 36.42 | 55.25 | 31.9 | 64.5 | 97.21 | 115.97 |
| [0191af001](https://github.com/AFK-surf/monoid/commit/0191af001dad79da0356ee6ff33119ce01f8cc4b) perf(core): walk the archive on a covering index,  | 2.6 | 3.5 | 14.29 | 36.36 | 55.05 | 31.87 | 64.34 | 97.22 | 122.31 |
| [43adeae0d](https://github.com/AFK-surf/monoid/commit/43adeae0d1fae0d4f03da9017aa148e8318a59a4) fix(mbui): a page's list's band drawn where its bl | 2.6 | 3.5 | 14.29 | 36.36 | 55.05 | 31.87 | 64.34 | 97.06 | 127.83 |
| [2db77b0db](https://github.com/AFK-surf/monoid/commit/2db77b0db04dfcaa66e1c0c7865544267ba7a922) test(mbui): refresh Android render golden after #6 | 2.6 | 3.49 | 14.28 | 36.36 | 55.04 | 31.87 | 64.34 | 97.21 | 119.39 |
| [71e0f837a](https://github.com/AFK-surf/monoid/commit/71e0f837a6abfc0e974a01ca1ea41f39dd7388fd) test(mbui): count a running frame's own asks out o | 2.6 | 3.49 | 14.28 | 36.36 | 55.04 | 31.87 | 64.34 | 97.21 | 119.39 |
| [e7e555b89](https://github.com/AFK-surf/monoid/commit/e7e555b89929895651b7c016a3082f2c58bd8000) perf(mbui): read a chat's video first frame by the | 2.6 | 3.49 | 14.28 | 36.36 | 55.04 | 31.87 | 64.34 | 97.4 | 127.7 |
| [d888ba627](https://github.com/AFK-surf/monoid/commit/d888ba62744cb3c5ed3cac369616c6e5c229ed56) fix(station): price session usage from model catal | 2.6 | 3.49 | 14.28 | 36.36 | 55.04 | 31.87 | 64.34 | 97.4 | 127.7 |
| [5ade5b9e6](https://github.com/AFK-surf/monoid/commit/5ade5b9e61bd10131bcc341a0e7c80e9f2432a4d) feat(effect): add quiet and daemon fiber forks (#7 | 2.6 | 3.49 | 14.28 | 36.36 | 55.04 | 31.87 | 64.34 | 97.4 | 127.7 |
| [d2df00612](https://github.com/AFK-surf/monoid/commit/d2df00612c04058ce13629b12945b9235115b34e) fix(station): keep chat.update's text within Slack | 2.6 | 3.49 | 14.28 | 36.36 | 55.04 | 31.87 | 64.34 | 97.21 | 120.29 |
| [d75900a3e](https://github.com/AFK-surf/monoid/commit/d75900a3e785f03d484be8e0199d0168e4af4063) ci: resolve MoonBit and Node downloads directly vi | 2.6 | 3.49 | 14.28 | 36.36 | 55.04 | 31.87 | 64.34 | 97.21 | 120.29 |
| [68a54a553](https://github.com/AFK-surf/monoid/commit/68a54a553cf5ace31c1581e5122cd01674681f00) fix(station): keep a refused Claude renewal's kind | 2.6 | 3.49 | 14.28 | 36.36 | 55.04 | 31.87 | 64.34 | 97.34 | 121.18 |
| [8d9eeb876](https://github.com/AFK-surf/monoid/commit/8d9eeb87690ea386020dab1c4afffaf0017df51b) fix(mbui): open and close a notice's pill in one m | 2.6 | 3.49 | 14.28 | 36.36 | 55.04 | 31.87 | 64.34 | 97.08 | 122.48 |
| [d43cc0ce8](https://github.com/AFK-surf/monoid/commit/d43cc0ce8db625b84c8f83827a46c3ebb0e00db0) fix(mbc): compile test functions in test.<unit> at | 2.6 | 3.49 | 14.28 | 36.35 | 55.03 | 31.77 | 63.99 | 97.44 | 125.25 |
| [fd3d1d1d3](https://github.com/AFK-surf/monoid/commit/fd3d1d1d317beced89cf5125c17fdf12bc0ca651) feat(mbui): move the chat page only for a cause sa | 2.6 | 3.49 | 14.28 | 36.35 | 55.03 | 31.77 | 63.99 | 97.44 | 125.25 |
| [d5e590268](https://github.com/AFK-surf/monoid/commit/d5e59026855dd2844e2a03bc9fa3822d17c515ec) fix(ci): run check off ci-1 unless its Rust change | 2.59 | 3.48 | 14.18 | 36.26 | 54.6 | 31.77 | 63.99 | 97.44 | 163.91 |
| [e8d64fae7](https://github.com/AFK-surf/monoid/commit/e8d64fae7f73cd4011cef67567c24ee70a6011b3) feat(mbui): draw the 小屏 bottom bar and the finger' | 2.59 | 3.48 | 14.18 | 36.26 | 54.6 | 31.77 | 63.99 | 97.03 | 207.49 |
| [f17707546](https://github.com/AFK-surf/monoid/commit/f17707546b459eb9ae1a8df44bf10299fe2ba44c) fix(mbui): keep the search list scroll where peopl | 2.59 | 3.48 | 14.18 | 36.26 | 54.6 | 31.77 | 63.99 | 97.03 | 207.49 |
| [921fbfdd2](https://github.com/AFK-surf/monoid/commit/921fbfdd2b1aa45b9b303f2f040517b21716b4d9) refactor(sf-ui): share a chat's list lines, notice | 2.59 | 3.48 | 14.18 | 36.26 | 54.59 | 31.76 | 63.92 | 97.13 | 121.06 |
| [84a34376a](https://github.com/AFK-surf/monoid/commit/84a34376ac03c82ac49ccc2592ece83224e4651a) refactor(sf-ui): share the workspaces' rows and th | 2.58 | 3.47 | 14.17 | 36.24 | 54.53 | 31.76 | 63.92 | 97.13 | 102.26 |
| [03f939eab](https://github.com/AFK-surf/monoid/commit/03f939eab6f37cb1952dab8a80abf84ae56ccf15) perf(mbui): skip core messages a later whole value | 2.58 | 3.47 | 14.16 | 36.23 | 54.52 | 31.74 | 63.89 | 96.95 | 117.95 |
| [f4f4a2c2d](https://github.com/AFK-surf/monoid/commit/f4f4a2c2d8cd521d1f651d45d27cc67efa12876c) feat(mbui): independent windows: a spec for each,  | 2.58 | 3.47 | 14.16 | 36.23 | 54.52 | 31.74 | 63.89 | 96.95 | 117.95 |
| [6411be4f6](https://github.com/AFK-surf/monoid/commit/6411be4f6b8aa7a4f3c783de6dfc766703dd9ec6) refactor(sf-ui): share the app look, permission gr | 2.58 | 3.47 | 14.15 | 36.22 | 54.47 | 31.74 | 63.89 | 96.95 | 121.72 |
| [00131c048](https://github.com/AFK-surf/monoid/commit/00131c048583b0c91471b6f3e71819077937356b) fix(station): updates read the station apart, Wind | 2.58 | 3.47 | 14.15 | 36.22 | 54.47 | 31.74 | 63.89 | 96.95 | 121.72 |
| [c0070ab30](https://github.com/AFK-surf/monoid/commit/c0070ab308ff3163070bde3700e86dd2578c04dd) fix(mbui): settle chat_bar_node's second row at on | 2.58 | 3.47 | 14.15 | 36.22 | 54.47 | 31.74 | 63.9 | 97.24 | 124.54 |
| [e118c93e1](https://github.com/AFK-surf/monoid/commit/e118c93e127a7c27194f8f121ca94bc19beb9f2e) perf(client): stop host and way readings from rebu | 2.58 | 3.47 | 14.15 | 36.22 | 54.46 | 31.74 | 63.89 | 97.27 | 119.67 |
| [5a092fb5f](https://github.com/AFK-surf/monoid/commit/5a092fb5f3934840747770df5b4fc85694792eaf) fix(ci): keep put green when the prune fails, and  | 2.58 | 3.47 | 14.15 | 36.19 | 54.43 | 31.74 | 63.89 | 97.21 | 129.14 |
| [1a1756ff4](https://github.com/AFK-surf/monoid/commit/1a1756ff40a6a5bdbb7ee839e798bce606fb8251) perf(core): make a streaming chat again without re | 2.58 | 3.47 | 14.15 | 36.19 | 54.43 | 31.74 | 63.89 | 97.11 | 129.14 |
| [7006c0215](https://github.com/AFK-surf/monoid/commit/7006c0215bb79c59d7b4db560b82d9e71be95554) fix(mbui): keep the new chat page's place in long  | 2.58 | 3.47 | 14.15 | 36.19 | 54.43 | 31.71 | 63.82 | 97.14 | 129.14 |
| [981a5d730](https://github.com/AFK-surf/monoid/commit/981a5d7307c20cb4d87df705264d1648563b2d4c) fix(station, mbui): keep media facts and pictures  | 2.58 | 3.46 | 14.14 | 36.19 | 54.43 | 31.71 | 63.82 | 97.14 | 129.14 |
| [8ef99af72](https://github.com/AFK-surf/monoid/commit/8ef99af72ee6e3c270ae494b42cc2c6ae979d779) fix(lock): keep pairing codes when verification is | 2.58 | 3.46 | 14.13 | 36.18 | 54.4 | 31.71 | 63.82 | 97.14 | 113.6 |
| [3c955f582](https://github.com/AFK-surf/monoid/commit/3c955f582a66d9dc0d31ae2650debf2e73e00bb9) test(mbui): lower motion bars that main's mbui-che | 2.58 | 3.46 | 14.13 | 36.18 | 54.4 | 31.71 | 63.82 | 97.14 | 113.6 |
| [0cf6f1b56](https://github.com/AFK-surf/monoid/commit/0cf6f1b56da535338e0ab67560de10e74bd04f2e) fix(mbui): make what a hidden page changes at rest | 2.58 | 3.46 | 14.13 | 36.18 | 54.4 | 31.71 | 63.82 | 97.26 | 130.65 |
| [743fff105](https://github.com/AFK-surf/monoid/commit/743fff1051ff1da20398a6c0463ada8f4217281c) fix(mbui): a drag that captures the pointer (on_dr | 2.58 | 3.46 | 14.13 | 36.18 | 54.4 | 31.71 | 63.82 | 97.26 | 130.65 |
| [eb1ccece4](https://github.com/AFK-surf/monoid/commit/eb1ccece4860deda4296c3fdecd0b62910f0e061) fix(mbui): restore rows after late scroll updates  | 2.58 | 3.46 | 14.13 | 36.18 | 54.4 | 31.71 | 63.82 | 97.26 | 130.65 |
| [eb1ccece4](https://github.com/AFK-surf/monoid/commit/eb1ccece4860deda4296c3fdecd0b62910f0e061) fix(mbui): restore rows after late scroll updates  | 2.58 | 3.46 | 14.13 | 36.18 | 54.4 | 31.69 | 63.81 | 97.22 | 126.31 |
| [5ed58cf15](https://github.com/AFK-surf/monoid/commit/5ed58cf1560157bcb4e1a994952e26aeb6c86329) fix(mbui): keep main's sheet and composer motion a | 2.58 | 3.46 | 14.13 | 36.17 | 54.38 | 31.69 | 63.81 | 97.22 | 120.26 |
| [e6ec96714](https://github.com/AFK-surf/monoid/commit/e6ec96714deaa21be8d1db30285b5a6864bd40b3) fix(mbui): take the start drop of a finger pick wh | 2.57 | 3.46 | 14.12 | 36.16 | 54.38 | 31.69 | 63.81 | 97.14 | 124.81 |
| [47d40edf6](https://github.com/AFK-surf/monoid/commit/47d40edf65d86bbde88b8393fb19532e686a59a8) fix(screen,browser): fix headful passkey hang, wat | 2.58 | 3.46 | 14.12 | 36.16 | 54.38 | 31.69 | 63.81 | 97.14 | 121.14 |
| [140f48085](https://github.com/AFK-surf/monoid/commit/140f480854671be455ce595a929a1ba7b4b00556) fix(station): price Gemini usage right, on agy and | 2.57 | 3.46 | 14.12 | 36.15 | 54.37 | 31.69 | 63.79 | 97.35 | 121.99 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [5f9f2dfa2](https://github.com/AFK-surf/monoid/commit/5f9f2dfa2a0399c6f0b653b441d97a3c8925c6de) fix(app): settings search finds settings by what p | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 53.94 |
| [9d591d003](https://github.com/AFK-surf/monoid/commit/9d591d003a8ea8c8ad92538b70889a14c7a2e43e) mbui app: a new chat made as nodes with its compos | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 53.94 |
| [0191af001](https://github.com/AFK-surf/monoid/commit/0191af001dad79da0356ee6ff33119ce01f8cc4b) perf(core): walk the archive on a covering index,  | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.05 |
| [43adeae0d](https://github.com/AFK-surf/monoid/commit/43adeae0d1fae0d4f03da9017aa148e8318a59a4) fix(mbui): a page's list's band drawn where its bl | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.05 |
| [2db77b0db](https://github.com/AFK-surf/monoid/commit/2db77b0db04dfcaa66e1c0c7865544267ba7a922) test(mbui): refresh Android render golden after #6 | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.05 |
| [71e0f837a](https://github.com/AFK-surf/monoid/commit/71e0f837a6abfc0e974a01ca1ea41f39dd7388fd) test(mbui): count a running frame's own asks out o | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.07 |
| [e7e555b89](https://github.com/AFK-surf/monoid/commit/e7e555b89929895651b7c016a3082f2c58bd8000) perf(mbui): read a chat's video first frame by the | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.07 |
| [d888ba627](https://github.com/AFK-surf/monoid/commit/d888ba62744cb3c5ed3cac369616c6e5c229ed56) fix(station): price session usage from model catal | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.05 |
| [5ade5b9e6](https://github.com/AFK-surf/monoid/commit/5ade5b9e61bd10131bcc341a0e7c80e9f2432a4d) feat(effect): add quiet and daemon fiber forks (#7 | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 53.99 |
| [d2df00612](https://github.com/AFK-surf/monoid/commit/d2df00612c04058ce13629b12945b9235115b34e) fix(station): keep chat.update's text within Slack | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 53.99 |
| [d75900a3e](https://github.com/AFK-surf/monoid/commit/d75900a3e785f03d484be8e0199d0168e4af4063) ci: resolve MoonBit and Node downloads directly vi | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.07 |
| [68a54a553](https://github.com/AFK-surf/monoid/commit/68a54a553cf5ace31c1581e5122cd01674681f00) fix(station): keep a refused Claude renewal's kind | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.07 |
| [8d9eeb876](https://github.com/AFK-surf/monoid/commit/8d9eeb87690ea386020dab1c4afffaf0017df51b) fix(mbui): open and close a notice's pill in one m | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.07 |
| [d43cc0ce8](https://github.com/AFK-surf/monoid/commit/d43cc0ce8db625b84c8f83827a46c3ebb0e00db0) fix(mbc): compile test functions in test.<unit> at | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.07 |
| [fd3d1d1d3](https://github.com/AFK-surf/monoid/commit/fd3d1d1d317beced89cf5125c17fdf12bc0ca651) feat(mbui): move the chat page only for a cause sa | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54.04 |
| [d5e590268](https://github.com/AFK-surf/monoid/commit/d5e59026855dd2844e2a03bc9fa3822d17c515ec) fix(ci): run check off ci-1 unless its Rust change | 0.44 | 0.58 | 2.22 | 3.31 | 5.32 | 1.62 | 4.38 | 54.2 |
| [e8d64fae7](https://github.com/AFK-surf/monoid/commit/e8d64fae7f73cd4011cef67567c24ee70a6011b3) feat(mbui): draw the 小屏 bottom bar and the finger' | 0.44 | 0.58 | 2.22 | 3.31 | 5.32 | 1.62 | 4.38 | 54.2 |
| [f17707546](https://github.com/AFK-surf/monoid/commit/f17707546b459eb9ae1a8df44bf10299fe2ba44c) fix(mbui): keep the search list scroll where peopl | 0.44 | 0.57 | 2.21 | 3.31 | 5.3 | 1.62 | 4.36 | 53.99 |
| [921fbfdd2](https://github.com/AFK-surf/monoid/commit/921fbfdd2b1aa45b9b303f2f040517b21716b4d9) refactor(sf-ui): share a chat's list lines, notice | 0.44 | 0.57 | 2.21 | 3.31 | 5.3 | 1.62 | 4.36 | 53.99 |
| [84a34376a](https://github.com/AFK-surf/monoid/commit/84a34376ac03c82ac49ccc2592ece83224e4651a) refactor(sf-ui): share the workspaces' rows and th | 0.44 | 0.57 | 2.21 | 3.31 | 5.3 | 1.62 | 4.36 | 53.99 |
| [03f939eab](https://github.com/AFK-surf/monoid/commit/03f939eab6f37cb1952dab8a80abf84ae56ccf15) perf(mbui): skip core messages a later whole value | 0.44 | 0.57 | 2.21 | 3.31 | 5.3 | 1.62 | 4.36 | 53.99 |
| [f4f4a2c2d](https://github.com/AFK-surf/monoid/commit/f4f4a2c2d8cd521d1f651d45d27cc67efa12876c) feat(mbui): independent windows: a spec for each,  | 0.44 | 0.57 | 2.21 | 3.31 | 5.3 | 1.62 | 4.36 | 54.4 |
| [6411be4f6](https://github.com/AFK-surf/monoid/commit/6411be4f6b8aa7a4f3c783de6dfc766703dd9ec6) refactor(sf-ui): share the app look, permission gr | 0.44 | 0.57 | 2.21 | 3.31 | 5.3 | 1.62 | 4.36 | 54.4 |
| [00131c048](https://github.com/AFK-surf/monoid/commit/00131c048583b0c91471b6f3e71819077937356b) fix(station): updates read the station apart, Wind | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 53.97 |
| [c0070ab30](https://github.com/AFK-surf/monoid/commit/c0070ab308ff3163070bde3700e86dd2578c04dd) fix(mbui): settle chat_bar_node's second row at on | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 53.97 |
| [e118c93e1](https://github.com/AFK-surf/monoid/commit/e118c93e127a7c27194f8f121ca94bc19beb9f2e) perf(client): stop host and way readings from rebu | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 53.97 |
| [5a092fb5f](https://github.com/AFK-surf/monoid/commit/5a092fb5f3934840747770df5b4fc85694792eaf) fix(ci): keep put green when the prune fails, and  | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 53.97 |
| [1a1756ff4](https://github.com/AFK-surf/monoid/commit/1a1756ff40a6a5bdbb7ee839e798bce606fb8251) perf(core): make a streaming chat again without re | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 53.97 |
| [7006c0215](https://github.com/AFK-surf/monoid/commit/7006c0215bb79c59d7b4db560b82d9e71be95554) fix(mbui): keep the new chat page's place in long  | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 53.97 |
| [981a5d730](https://github.com/AFK-surf/monoid/commit/981a5d7307c20cb4d87df705264d1648563b2d4c) fix(station, mbui): keep media facts and pictures  | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 54.12 |
| [8ef99af72](https://github.com/AFK-surf/monoid/commit/8ef99af72ee6e3c270ae494b42cc2c6ae979d779) fix(lock): keep pairing codes when verification is | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 54.12 |
| [3c955f582](https://github.com/AFK-surf/monoid/commit/3c955f582a66d9dc0d31ae2650debf2e73e00bb9) test(mbui): lower motion bars that main's mbui-che | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 54.05 |
| [0cf6f1b56](https://github.com/AFK-surf/monoid/commit/0cf6f1b56da535338e0ab67560de10e74bd04f2e) fix(mbui): make what a hidden page changes at rest | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 54.05 |
| [743fff105](https://github.com/AFK-surf/monoid/commit/743fff1051ff1da20398a6c0463ada8f4217281c) fix(mbui): a drag that captures the pointer (on_dr | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 53.99 |
| [eb1ccece4](https://github.com/AFK-surf/monoid/commit/eb1ccece4860deda4296c3fdecd0b62910f0e061) fix(mbui): restore rows after late scroll updates  | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 54.04 |
| [eb1ccece4](https://github.com/AFK-surf/monoid/commit/eb1ccece4860deda4296c3fdecd0b62910f0e061) fix(mbui): restore rows after late scroll updates  | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 54.04 |
| [5ed58cf15](https://github.com/AFK-surf/monoid/commit/5ed58cf1560157bcb4e1a994952e26aeb6c86329) fix(mbui): keep main's sheet and composer motion a | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 54.05 |
| [e6ec96714](https://github.com/AFK-surf/monoid/commit/e6ec96714deaa21be8d1db30285b5a6864bd40b3) fix(mbui): take the start drop of a finger pick wh | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 54.05 |
| [47d40edf6](https://github.com/AFK-surf/monoid/commit/47d40edf65d86bbde88b8393fb19532e686a59a8) fix(screen,browser): fix headful passkey hang, wat | 0.44 | 0.57 | 2.21 | 3.3 | 5.29 | 1.62 | 4.35 | 53.95 |
| [140f48085](https://github.com/AFK-surf/monoid/commit/140f480854671be455ce595a929a1ba7b4b00556) fix(station): price Gemini usage right, on agy and | 0.44 | 0.57 | 2.21 | 3.29 | 5.29 | 1.62 | 4.35 | 53.82 |
