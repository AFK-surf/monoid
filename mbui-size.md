# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [67be246b5](https://github.com/AFK-surf/monoid/commit/67be246b5291e9c7094563d4e6eec8fde602916c) fix(station): let granted stations reach a rig's s | 2.78 | 3.75 | 15.19 | 37.41 | 57.81 | 32.76 | 66.74 | 100.68 | 123.04 |
| [e06b8f342](https://github.com/AFK-surf/monoid/commit/e06b8f342e1320a945260199cb82835a2e70370d) chore(farview): point at AFK-surf/farview-legacy ( | 2.78 | 3.75 | 15.19 | 37.41 | 57.81 | 32.76 | 66.74 | 100.68 | 123.04 |
| [973632d2b](https://github.com/AFK-surf/monoid/commit/973632d2bc8bd432788347a7f8bed0496feaba44) perf(core,station): cut steady-state overview push | 2.78 | 3.75 | 15.19 | 37.41 | 57.81 | 32.76 | 66.74 | 100.68 | 123.04 |
| [4071ef70c](https://github.com/AFK-surf/monoid/commit/4071ef70c97c2aad6409fac6519c3bf6350e9774) feat(pion-station): migrate stateful archive-last  | 2.78 | 3.75 | 15.19 | 37.4 | 57.81 | 32.75 | 66.74 | 100.68 | 125.07 |
| [d9a7748e3](https://github.com/AFK-surf/monoid/commit/d9a7748e3cf7f12fdc33b338bd86f763d53f8d53) fix(screens): bound simulator view startup and enu | 2.78 | 3.75 | 15.19 | 37.4 | 57.81 | 32.75 | 66.74 | 100.68 | 125.07 |
| [e5dc78307](https://github.com/AFK-surf/monoid/commit/e5dc78307cf13887651506576fa3d4636e9ccdb5) feat(pion-station): migrate 5 index/job SQLite bui | 2.78 | 3.75 | 15.19 | 37.4 | 57.81 | 32.75 | 66.74 | 100.68 | 125.07 |
| [27e3294c7](https://github.com/AFK-surf/monoid/commit/27e3294c7cef7cf98d25c71e2a078da32203f508) fix(ui,station): keep long and wide image previews | 2.78 | 3.75 | 15.19 | 37.4 | 57.81 | 32.75 | 66.74 | 100.68 | 125.07 |
| [5f2f4f088](https://github.com/AFK-surf/monoid/commit/5f2f4f0884bd882f4d5e6e615148acbc0341f8c5) fix(ci): prevent preview ios 5m timeouts and drop  | 2.78 | 3.75 | 15.18 | 37.4 | 57.77 | 32.74 | 66.7 | 100.65 | 127.41 |
| [0f5041107](https://github.com/AFK-surf/monoid/commit/0f5041107ca0906f0ac433a02d252c283a3233b1) fix(mbui): wait for a notified message past the ch | 2.78 | 3.75 | 15.18 | 37.4 | 57.77 | 32.74 | 66.7 | 100.58 | 137.62 |
| [d4d7cf079](https://github.com/AFK-surf/monoid/commit/d4d7cf079cc732d783dd55d9978be5758c34e56e) fix(core-ts,ui,mbui): eliminate chat activity moti | 2.78 | 3.75 | 15.18 | 37.4 | 57.77 | 32.74 | 66.7 | 100.45 | 130.12 |
| [04d026f01](https://github.com/AFK-surf/monoid/commit/04d026f016facd8321e7926397e7dd2df40d49dc) test(core-ts): report the hung test when CI stops  | 2.78 | 3.75 | 15.18 | 37.39 | 57.76 | 32.74 | 66.69 | 100.52 | 128.91 |
| [33f6343a7](https://github.com/AFK-surf/monoid/commit/33f6343a733c18611c050c36a5d60e3284d8c76f) fix(core): show a session's steps in flight only a | 2.78 | 3.75 | 15.18 | 37.39 | 57.75 | 32.74 | 66.69 | 100.52 | 128.91 |
| [d88076e26](https://github.com/AFK-surf/monoid/commit/d88076e26070dac0ba0a4db53614836354324ff8) ci(mbui-check): bound cache saves and let them fai | 2.78 | 3.75 | 15.18 | 37.39 | 57.75 | 32.73 | 66.69 | 100.68 | 126 |
| [edfc50ec5](https://github.com/AFK-surf/monoid/commit/edfc50ec59b0018d4a31d49492d139d7a471cf32) feat(pion-station): add sql_db, builder_loop, arch | 2.78 | 3.75 | 15.18 | 37.39 | 57.75 | 32.73 | 66.69 | 100.68 | 126 |
| [9160e1497](https://github.com/AFK-surf/monoid/commit/9160e1497a87565145751f7f63019b3c1cd73bc2) feat(mbui): add line numbers and pick/note annotat | 2.78 | 3.75 | 15.18 | 37.39 | 57.75 | 32.73 | 66.69 | 100.68 | 126 |
| [bbb59ac01](https://github.com/AFK-surf/monoid/commit/bbb59ac011c72633c1fb031f9609cf8f7e6fb234) fix(station): arm waiting timer mid-turn and remin | 2.78 | 3.74 | 15.16 | 37.37 | 57.71 | 32.72 | 66.65 | 100.6 | 116.14 |
| [1956fcba8](https://github.com/AFK-surf/monoid/commit/1956fcba8ea950dccabd1737b79a4530e21a22bd) fix(station): weigh CPU when assigning new chats a | 2.78 | 3.74 | 15.16 | 37.37 | 57.71 | 32.72 | 66.65 | 100.62 | 126.7 |
| [6641932f7](https://github.com/AFK-surf/monoid/commit/6641932f70c050d192449ce0bfb0d9cc7c668cce) fix(mbui): grow the soft scroll edge's blur as r²  | 2.78 | 3.74 | 15.16 | 37.37 | 57.71 | 32.72 | 66.65 | 100.62 | 126.7 |
| [2d8645beb](https://github.com/AFK-surf/monoid/commit/2d8645beb6916175cbb7e43b09d3085d2e8ef566) feat(ui): add transparent/borderless child windows | 2.78 | 3.74 | 15.16 | 37.37 | 57.7 | 32.72 | 66.65 | 100.62 | 127.5 |
| [6d4fc31f6](https://github.com/AFK-surf/monoid/commit/6d4fc31f68db2092d7962d29f6ae0e2f15510012) fix(mbui): keep the history header model picker in | 2.78 | 3.74 | 15.16 | 37.37 | 57.7 | 32.71 | 66.62 | 100.6 | 127.13 |
| [434f6f625](https://github.com/AFK-surf/monoid/commit/434f6f62557761a0b68c98b0376b26b10666eec3) fix(ui,mbui): P0 Regular Liquid Glass optics fix a | 2.78 | 3.74 | 15.16 | 37.37 | 57.7 | 32.71 | 66.62 | 100.6 | 127.13 |
| [294d9460f](https://github.com/AFK-surf/monoid/commit/294d9460f6ff2ac0888058581e24c0a38904beb7) fix(mbui): tidy Poke's pill and popover, and say w | 2.78 | 3.74 | 15.16 | 37.36 | 57.7 | 32.71 | 66.62 | 100.6 | 114.04 |
| [a40327a3b](https://github.com/AFK-surf/monoid/commit/a40327a3b3e8ca64f325c114bdd1bbcdf1b68fc0) feat(mbui): add experimental Cmd/Ctrl hover highli | 2.78 | 3.74 | 15.16 | 37.36 | 57.69 | 32.7 | 66.59 | 100.6 | 118.87 |
| [21b5451ae](https://github.com/AFK-surf/monoid/commit/21b5451ae519b17261bbd35ea4e5c54c078fb953) fix(ui): set emoji presentation sequences and keyc | 2.78 | 3.74 | 15.15 | 37.35 | 57.65 | 32.7 | 66.59 | 100.6 | 123.18 |
| [61c98f1de](https://github.com/AFK-surf/monoid/commit/61c98f1de8298a5b6a8e940f35f96778d6bc9b60) feat(providers): add Command Code and Open Design  | 2.78 | 3.74 | 15.15 | 37.35 | 57.65 | 32.7 | 66.59 | 100.57 | 125.67 |
| [eb460cf48](https://github.com/AFK-surf/monoid/commit/eb460cf482d57905c0b02b24c1b39bb375ac96fd) fix(ui,mbui): hide the quote pill while its words  | 2.78 | 3.74 | 15.14 | 37.35 | 57.65 | 32.7 | 66.59 | 100.57 | 129.4 |
| [51e982cfb](https://github.com/AFK-surf/monoid/commit/51e982cfbcd8bd0824e7861b8c89e3a74881f9e5) fix(station): leave a thread whose chat's station  | 2.78 | 3.74 | 15.14 | 37.35 | 57.65 | 32.7 | 66.57 | 100.6 | 122.68 |
| [b784641b7](https://github.com/AFK-surf/monoid/commit/b784641b76e03e54a96b5d4e27743a662030ad07) fix(ui): bound post-layout re-entry passes in Tree | 2.78 | 3.74 | 15.14 | 37.35 | 57.65 | 32.7 | 66.57 | 100.47 | 130.05 |
| [15372e7f5](https://github.com/AFK-surf/monoid/commit/15372e7f5a4ec23f99bca1d0bac0b2920cf58958) feat(station): restore a hand-archived platform th | 2.78 | 3.74 | 15.14 | 37.35 | 57.65 | 32.7 | 66.57 | 100.47 | 132.16 |
| [ab0bba783](https://github.com/AFK-surf/monoid/commit/ab0bba7835eb64a94cb65870b45a89eabee784fc) feat(pion-station): add Pion memory worker, mb/pio | 2.78 | 3.74 | 15.14 | 37.35 | 57.65 | 32.7 | 66.57 | 100.47 | 132.16 |
| [4efe50b6b](https://github.com/AFK-surf/monoid/commit/4efe50b6b75751b3fae0a3150dfb4ed06af0f7d9) ci(preview): keep the iOS device's engine by its i | 2.78 | 3.74 | 15.14 | 37.35 | 57.65 | 32.68 | 66.54 | 100.47 | 132.16 |
| [d7b42d970](https://github.com/AFK-surf/monoid/commit/d7b42d970192b854013e713d801b1d49d0e6fb9c) fix(mb): refill a moon-include directory CI's clea | 2.77 | 3.74 | 15.13 | 37.33 | 57.58 | 32.68 | 66.54 | 100.47 | 129.98 |
| [1b5405d50](https://github.com/AFK-surf/monoid/commit/1b5405d50c3cdf70d15d847a73b86c81907432c7) feat(mbui): pick and note words of a Markdown file | 2.77 | 3.74 | 15.13 | 37.33 | 57.58 | 32.66 | 66.47 | 100.93 | 123.45 |
| [c2e84024c](https://github.com/AFK-surf/monoid/commit/c2e84024ce63b1aed5ad3ecefe4d34425b8dc73f) feat(chat): add experimental Poke selection reply  | 2.77 | 3.74 | 15.13 | 37.33 | 57.58 | 32.66 | 66.47 | 100.93 | 123.45 |
| [c4f5373cd](https://github.com/AFK-surf/monoid/commit/c4f5373cd81bd5a2e72f893ede3f1d41c08856a4) perf(mbc): add content-addressed core_obj fast pat | 2.77 | 3.73 | 15.11 | 37.31 | 57.5 | 32.66 | 66.47 | 100.93 | 121.52 |
| [9dac38d35](https://github.com/AFK-surf/monoid/commit/9dac38d35b3e1576e055c7c393fa40fb314caf99) feat(pion-station): add Pion packed worker, mb/pio | 2.77 | 3.73 | 15.11 | 37.31 | 57.5 | 32.66 | 66.47 | 100.93 | 121.52 |
| [d82f3621c](https://github.com/AFK-surf/monoid/commit/d82f3621c6416dcccdc1dd097e5abdb89885061f) ci(desktop-build): keep the Mac core's engine and  | 2.77 | 3.73 | 15.11 | 37.31 | 57.5 | 32.66 | 66.47 | 100.93 | 121.52 |
| [6ba8edd27](https://github.com/AFK-surf/monoid/commit/6ba8edd27633eeb3e7bf6ad1c0da9024688d6484) fix(station): keep footprint off mounts and refuse | 2.77 | 3.73 | 15.11 | 37.31 | 57.5 | 32.66 | 66.47 | 100.93 | 121.52 |
| [161c998db](https://github.com/AFK-surf/monoid/commit/161c998dbd4aa80f7c7614497057e2dc35fce660) fix(ui): open the paste bar on a tap at a field's  | 2.77 | 3.73 | 15.11 | 37.31 | 57.5 | 32.66 | 66.47 | 100.55 | 117.96 |
| [e7300722f](https://github.com/AFK-surf/monoid/commit/e7300722fca7dc951cb3f09c5856262895cd61df) feat(mbui,station): allow cancelling sign-in cards | 2.77 | 3.73 | 15.11 | 37.3 | 57.49 | 32.66 | 66.47 | 100.55 | 127.16 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [67be246b5](https://github.com/AFK-surf/monoid/commit/67be246b5291e9c7094563d4e6eec8fde602916c) fix(station): let granted stations reach a rig's s | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 57.44 |
| [e06b8f342](https://github.com/AFK-surf/monoid/commit/e06b8f342e1320a945260199cb82835a2e70370d) chore(farview): point at AFK-surf/farview-legacy ( | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.16 |
| [973632d2b](https://github.com/AFK-surf/monoid/commit/973632d2bc8bd432788347a7f8bed0496feaba44) perf(core,station): cut steady-state overview push | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.56 |
| [4071ef70c](https://github.com/AFK-surf/monoid/commit/4071ef70c97c2aad6409fac6519c3bf6350e9774) feat(pion-station): migrate stateful archive-last  | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.53 |
| [d9a7748e3](https://github.com/AFK-surf/monoid/commit/d9a7748e3cf7f12fdc33b338bd86f763d53f8d53) fix(screens): bound simulator view startup and enu | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.57 |
| [e5dc78307](https://github.com/AFK-surf/monoid/commit/e5dc78307cf13887651506576fa3d4636e9ccdb5) feat(pion-station): migrate 5 index/job SQLite bui | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.46 |
| [27e3294c7](https://github.com/AFK-surf/monoid/commit/27e3294c7cef7cf98d25c71e2a078da32203f508) fix(ui,station): keep long and wide image previews | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.57 |
| [5f2f4f088](https://github.com/AFK-surf/monoid/commit/5f2f4f0884bd882f4d5e6e615148acbc0341f8c5) fix(ci): prevent preview ios 5m timeouts and drop  | 0.55 | 0.73 | 2.84 | 3.85 | 7.05 | 2.09 | 5.81 | 57.2 |
| [0f5041107](https://github.com/AFK-surf/monoid/commit/0f5041107ca0906f0ac433a02d252c283a3233b1) fix(mbui): wait for a notified message past the ch | 0.55 | 0.73 | 2.84 | 3.85 | 7.05 | 2.09 | 5.81 | 57.59 |
| [d4d7cf079](https://github.com/AFK-surf/monoid/commit/d4d7cf079cc732d783dd55d9978be5758c34e56e) fix(core-ts,ui,mbui): eliminate chat activity moti | 0.55 | 0.73 | 2.84 | 3.85 | 7.05 | 2.09 | 5.81 | 57.49 |
| [04d026f01](https://github.com/AFK-surf/monoid/commit/04d026f016facd8321e7926397e7dd2df40d49dc) test(core-ts): report the hung test when CI stops  | 0.56 | 0.73 | 2.84 | 3.85 | 7.05 | 2.09 | 5.81 | 57.62 |
| [33f6343a7](https://github.com/AFK-surf/monoid/commit/33f6343a733c18611c050c36a5d60e3284d8c76f) fix(core): show a session's steps in flight only a | 0.56 | 0.73 | 2.84 | 3.84 | 7.05 | 2.09 | 5.81 | 57.62 |
| [d88076e26](https://github.com/AFK-surf/monoid/commit/d88076e26070dac0ba0a4db53614836354324ff8) ci(mbui-check): bound cache saves and let them fai | 0.56 | 0.73 | 2.84 | 3.84 | 7.05 | 2.09 | 5.81 | 57.59 |
| [edfc50ec5](https://github.com/AFK-surf/monoid/commit/edfc50ec59b0018d4a31d49492d139d7a471cf32) feat(pion-station): add sql_db, builder_loop, arch | 0.56 | 0.73 | 2.84 | 3.84 | 7.05 | 2.09 | 5.81 | 57.39 |
| [9160e1497](https://github.com/AFK-surf/monoid/commit/9160e1497a87565145751f7f63019b3c1cd73bc2) feat(mbui): add line numbers and pick/note annotat | 0.56 | 0.73 | 2.84 | 3.84 | 7.05 | 2.09 | 5.81 | 57.33 |
| [bbb59ac01](https://github.com/AFK-surf/monoid/commit/bbb59ac011c72633c1fb031f9609cf8f7e6fb234) fix(station): arm waiting timer mid-turn and remin | 0.56 | 0.73 | 2.84 | 3.84 | 7.05 | 2.09 | 5.81 | 57.64 |
| [1956fcba8](https://github.com/AFK-surf/monoid/commit/1956fcba8ea950dccabd1737b79a4530e21a22bd) fix(station): weigh CPU when assigning new chats a | 0.56 | 0.73 | 2.84 | 3.84 | 7.05 | 2.09 | 5.81 | 57.44 |
| [6641932f7](https://github.com/AFK-surf/monoid/commit/6641932f70c050d192449ce0bfb0d9cc7c668cce) fix(mbui): grow the soft scroll edge's blur as r²  | 0.56 | 0.73 | 2.84 | 3.84 | 7.05 | 2.09 | 5.81 | 57.84 |
| [2d8645beb](https://github.com/AFK-surf/monoid/commit/2d8645beb6916175cbb7e43b09d3085d2e8ef566) feat(ui): add transparent/borderless child windows | 0.56 | 0.73 | 2.84 | 3.85 | 7.05 | 2.09 | 5.81 | 57.41 |
| [6d4fc31f6](https://github.com/AFK-surf/monoid/commit/6d4fc31f68db2092d7962d29f6ae0e2f15510012) fix(mbui): keep the history header model picker in | 0.56 | 0.73 | 2.84 | 3.85 | 7.05 | 2.09 | 5.81 | 57.66 |
| [434f6f625](https://github.com/AFK-surf/monoid/commit/434f6f62557761a0b68c98b0376b26b10666eec3) fix(ui,mbui): P0 Regular Liquid Glass optics fix a | 0.56 | 0.73 | 2.84 | 3.85 | 7.05 | 2.08 | 5.79 | 57.46 |
| [294d9460f](https://github.com/AFK-surf/monoid/commit/294d9460f6ff2ac0888058581e24c0a38904beb7) fix(mbui): tidy Poke's pill and popover, and say w | 0.56 | 0.73 | 2.84 | 3.85 | 7.04 | 2.08 | 5.79 | 57.48 |
| [a40327a3b](https://github.com/AFK-surf/monoid/commit/a40327a3b3e8ca64f325c114bdd1bbcdf1b68fc0) feat(mbui): add experimental Cmd/Ctrl hover highli | 0.56 | 0.73 | 2.84 | 3.85 | 7.04 | 2.08 | 5.79 | 57.33 |
| [21b5451ae](https://github.com/AFK-surf/monoid/commit/21b5451ae519b17261bbd35ea4e5c54c078fb953) fix(ui): set emoji presentation sequences and keyc | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.44 |
| [61c98f1de](https://github.com/AFK-surf/monoid/commit/61c98f1de8298a5b6a8e940f35f96778d6bc9b60) feat(providers): add Command Code and Open Design  | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.46 |
| [eb460cf48](https://github.com/AFK-surf/monoid/commit/eb460cf482d57905c0b02b24c1b39bb375ac96fd) fix(ui,mbui): hide the quote pill while its words  | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.41 |
| [51e982cfb](https://github.com/AFK-surf/monoid/commit/51e982cfbcd8bd0824e7861b8c89e3a74881f9e5) fix(station): leave a thread whose chat's station  | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.43 |
| [b784641b7](https://github.com/AFK-surf/monoid/commit/b784641b76e03e54a96b5d4e27743a662030ad07) fix(ui): bound post-layout re-entry passes in Tree | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.43 |
| [15372e7f5](https://github.com/AFK-surf/monoid/commit/15372e7f5a4ec23f99bca1d0bac0b2920cf58958) feat(station): restore a hand-archived platform th | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.33 |
| [ab0bba783](https://github.com/AFK-surf/monoid/commit/ab0bba7835eb64a94cb65870b45a89eabee784fc) feat(pion-station): add Pion memory worker, mb/pio | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.48 |
| [4efe50b6b](https://github.com/AFK-surf/monoid/commit/4efe50b6b75751b3fae0a3150dfb4ed06af0f7d9) ci(preview): keep the iOS device's engine by its i | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.48 |
| [d7b42d970](https://github.com/AFK-surf/monoid/commit/d7b42d970192b854013e713d801b1d49d0e6fb9c) fix(mb): refill a moon-include directory CI's clea | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.62 |
| [1b5405d50](https://github.com/AFK-surf/monoid/commit/1b5405d50c3cdf70d15d847a73b86c81907432c7) feat(mbui): pick and note words of a Markdown file | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.75 |
| [c2e84024c](https://github.com/AFK-surf/monoid/commit/c2e84024ce63b1aed5ad3ecefe4d34425b8dc73f) feat(chat): add experimental Poke selection reply  | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.36 |
| [c4f5373cd](https://github.com/AFK-surf/monoid/commit/c4f5373cd81bd5a2e72f893ede3f1d41c08856a4) perf(mbc): add content-addressed core_obj fast pat | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.33 |
| [9dac38d35](https://github.com/AFK-surf/monoid/commit/9dac38d35b3e1576e055c7c393fa40fb314caf99) feat(pion-station): add Pion packed worker, mb/pio | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.33 |
| [d82f3621c](https://github.com/AFK-surf/monoid/commit/d82f3621c6416dcccdc1dd097e5abdb89885061f) ci(desktop-build): keep the Mac core's engine and  | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.59 |
| [6ba8edd27](https://github.com/AFK-surf/monoid/commit/6ba8edd27633eeb3e7bf6ad1c0da9024688d6484) fix(station): keep footprint off mounts and refuse | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.56 |
| [161c998db](https://github.com/AFK-surf/monoid/commit/161c998dbd4aa80f7c7614497057e2dc35fce660) fix(ui): open the paste bar on a tap at a field's  | 0.55 | 0.72 | 2.83 | 3.84 | 7.01 | 2.07 | 5.78 | 57.59 |
| [e7300722f](https://github.com/AFK-surf/monoid/commit/e7300722fca7dc951cb3f09c5856262895cd61df) feat(mbui,station): allow cancelling sign-in cards | 0.55 | 0.72 | 2.83 | 3.84 | 7 | 2.07 | 5.76 | 57.35 |
