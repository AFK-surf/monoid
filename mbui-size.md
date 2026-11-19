# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [81556eb15](https://github.com/AFK-surf/monoid/commit/81556eb15db6acfb1ec9fed55ea1a89d6cef3898) feat(mbui): polish execution history interactions, | 2.62 | 3.52 | 14.37 | 36.48 | 55.39 | 31.96 | 64.62 | 97.04 | 107.97 |
| [4aa521887](https://github.com/AFK-surf/monoid/commit/4aa52188713df8eadf6bdb338772e50ada19c5eb) refactor(core-ts): split shapes schema into domain | 2.61 | 3.51 | 14.36 | 36.46 | 55.32 | 31.94 | 64.57 | 97.06 | 126.32 |
| [9e26c535e](https://github.com/AFK-surf/monoid/commit/9e26c535eb1be6ba936c29567f855b244eb60d8c) fix(mbui): apply pixel-sliver guard to the n == 3  | 2.61 | 3.51 | 14.36 | 36.46 | 55.32 | 31.94 | 64.57 | 97.22 | 127.72 |
| [7950d8399](https://github.com/AFK-surf/monoid/commit/7950d839914a95329b74e196a3e3d2aa9405e4a6) perf(station): encode H.264 at High, look at macOS | 2.61 | 3.51 | 14.36 | 36.46 | 55.32 | 31.94 | 64.57 | 97.22 | 127.72 |
| [d5f7b63a0](https://github.com/AFK-surf/monoid/commit/d5f7b63a06b9c6cfa31901152178ac7d67f469d3) feat(station): add chat_configure tool, enhance ch | 2.61 | 3.51 | 14.36 | 36.46 | 55.32 | 31.94 | 64.57 | 97.22 | 127.72 |
| [30c4f02b3](https://github.com/AFK-surf/monoid/commit/30c4f02b3bf37ec29a04868738609c735b6baff3) perf(station, core-ts): start screen views at the  | 2.61 | 3.51 | 14.35 | 36.45 | 55.3 | 31.93 | 64.55 | 97.26 | 122.25 |
| [a032f3f2e](https://github.com/AFK-surf/monoid/commit/a032f3f2e6ba5d7b16157d3d61a72cd01eaf3c5b) fix(mbui): keep glyph phase across whole-pixel shi | 2.61 | 3.51 | 14.35 | 36.45 | 55.3 | 31.93 | 64.55 | 97.26 | 116.05 |
| [01ea77285](https://github.com/AFK-surf/monoid/commit/01ea77285e1d9e05a83e8acee89ff61d921ed36e) feat: prompt to upgrade builds older than 7 days ( | 2.61 | 3.51 | 14.35 | 36.45 | 55.3 | 31.93 | 64.55 | 97.26 | 116.05 |
| [4bca0dd4c](https://github.com/AFK-surf/monoid/commit/4bca0dd4cbc38acc60fa1f8b66e437cd57468e18) fix(station/mb): add async host fs helpers and giv | 2.61 | 3.51 | 14.35 | 36.45 | 55.3 | 31.93 | 64.55 | 97.26 | 116.05 |
| [ce9309e5e](https://github.com/AFK-surf/monoid/commit/ce9309e5e70b2f36bf09404c6e43f36fb8d98f26) refactor(station/mb): eliminate remaining bare ign | 2.61 | 3.51 | 14.35 | 36.44 | 55.29 | 31.92 | 64.53 | 97.14 | 121.21 |
| [65266f033](https://github.com/AFK-surf/monoid/commit/65266f0330d44f08f1215ae08cbb3f6893bb1853) refactor(core-ts): retire pre-7143 sidebar compat  | 2.61 | 3.51 | 14.35 | 36.43 | 55.28 | 31.92 | 64.52 | 97.19 | 115.88 |
| [1dee65d49](https://github.com/AFK-surf/monoid/commit/1dee65d4902de50f3f044b30f395fb40b298e890) refactor(station): route all remaining MoonBit soc | 2.61 | 3.51 | 14.34 | 36.44 | 55.28 | 31.92 | 64.52 | 97.13 | 125.05 |
| [d5a741a43](https://github.com/AFK-surf/monoid/commit/d5a741a43c3a72c890a8ddcaf70dde766e11bc0b) perf(mbui): snap View::shift to whole pixels, drop | 2.61 | 3.51 | 14.34 | 36.44 | 55.28 | 31.92 | 64.52 | 97.21 | 115.97 |
| [16aa89a96](https://github.com/AFK-surf/monoid/commit/16aa89a96bc9704cc3067d23f96daf7402e80f0a) fix(station, sf-ui): fix Slack app creation crash, | 2.61 | 3.51 | 14.34 | 36.44 | 55.28 | 31.92 | 64.52 | 97.21 | 115.97 |
| [f65dd8ee5](https://github.com/AFK-surf/monoid/commit/f65dd8ee584b511023f9c87efe3263611d1b38f9) refactor(mbui): shard detlint counts by package (# | 2.61 | 3.51 | 14.34 | 36.44 | 55.28 | 31.92 | 64.52 | 97.21 | 115.97 |
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

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [81556eb15](https://github.com/AFK-surf/monoid/commit/81556eb15db6acfb1ec9fed55ea1a89d6cef3898) feat(mbui): polish execution history interactions, | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.04 |
| [4aa521887](https://github.com/AFK-surf/monoid/commit/4aa52188713df8eadf6bdb338772e50ada19c5eb) refactor(core-ts): split shapes schema into domain | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.04 |
| [9e26c535e](https://github.com/AFK-surf/monoid/commit/9e26c535eb1be6ba936c29567f855b244eb60d8c) fix(mbui): apply pixel-sliver guard to the n == 3  | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.04 |
| [7950d8399](https://github.com/AFK-surf/monoid/commit/7950d839914a95329b74e196a3e3d2aa9405e4a6) perf(station): encode H.264 at High, look at macOS | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.31 |
| [d5f7b63a0](https://github.com/AFK-surf/monoid/commit/d5f7b63a06b9c6cfa31901152178ac7d67f469d3) feat(station): add chat_configure tool, enhance ch | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.41 |
| [30c4f02b3](https://github.com/AFK-surf/monoid/commit/30c4f02b3bf37ec29a04868738609c735b6baff3) perf(station, core-ts): start screen views at the  | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.41 |
| [a032f3f2e](https://github.com/AFK-surf/monoid/commit/a032f3f2e6ba5d7b16157d3d61a72cd01eaf3c5b) fix(mbui): keep glyph phase across whole-pixel shi | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.41 |
| [01ea77285](https://github.com/AFK-surf/monoid/commit/01ea77285e1d9e05a83e8acee89ff61d921ed36e) feat: prompt to upgrade builds older than 7 days ( | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.22 |
| [4bca0dd4c](https://github.com/AFK-surf/monoid/commit/4bca0dd4cbc38acc60fa1f8b66e437cd57468e18) fix(station/mb): add async host fs helpers and giv | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.28 |
| [ce9309e5e](https://github.com/AFK-surf/monoid/commit/ce9309e5e70b2f36bf09404c6e43f36fb8d98f26) refactor(station/mb): eliminate remaining bare ign | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.28 |
| [65266f033](https://github.com/AFK-surf/monoid/commit/65266f0330d44f08f1215ae08cbb3f6893bb1853) refactor(core-ts): retire pre-7143 sidebar compat  | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.28 |
| [1dee65d49](https://github.com/AFK-surf/monoid/commit/1dee65d4902de50f3f044b30f395fb40b298e890) refactor(station): route all remaining MoonBit soc | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.28 |
| [d5a741a43](https://github.com/AFK-surf/monoid/commit/d5a741a43c3a72c890a8ddcaf70dde766e11bc0b) perf(mbui): snap View::shift to whole pixels, drop | 0.44 | 0.58 | 2.23 | 3.32 | 5.34 | 1.63 | 4.4 | 54.28 |
| [16aa89a96](https://github.com/AFK-surf/monoid/commit/16aa89a96bc9704cc3067d23f96daf7402e80f0a) fix(station, sf-ui): fix Slack app creation crash, | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54 |
| [f65dd8ee5](https://github.com/AFK-surf/monoid/commit/f65dd8ee584b511023f9c87efe3263611d1b38f9) refactor(mbui): shard detlint counts by package (# | 0.44 | 0.58 | 2.22 | 3.31 | 5.34 | 1.63 | 4.4 | 54 |
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
