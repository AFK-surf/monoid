# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [38f0aa4e0](https://github.com/AFK-surf/monoid/commit/38f0aa4e0dad79a45f5bd4b81d53f283c662b54c) feat(mbui): default profile sharing to follow work | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.94 | 121.84 |
| [a9403c5f7](https://github.com/AFK-surf/monoid/commit/a9403c5f758d891a20284a7b52ed34ed83d9160b) fix(lock,station): let admitted members verify off | 2.54 | 3.44 | 14.21 | 36.77 | 55.6 | 32.11 | 65 | 100.96 | 130.04 |
| [dd7cfdf75](https://github.com/AFK-surf/monoid/commit/dd7cfdf759b3bbf099eec36cbe12f3a28df77ad3) fix(station): hear spawn errors before touching ch | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.53 | 131.51 |
| [686de55fb](https://github.com/AFK-surf/monoid/commit/686de55fbd0a4b4cd63ed6222a6d900f2181c2d2) fix(station): give agy only the skills that fit be | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.53 | 131.51 |
| [c2380f54e](https://github.com/AFK-surf/monoid/commit/c2380f54ebefbda921b5c1bbf9497cff1fc059c9) fix(mbui): anchor steps_seconds clock to eliminate | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.52 | 124.13 |
| [fd72c2b59](https://github.com/AFK-surf/monoid/commit/fd72c2b59ac70c6fe5f6487ae97093859c30a2cf) fix(station): leave an unknown runtime's agentIden | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.53 | 129.08 |
| [6ff926ec7](https://github.com/AFK-surf/monoid/commit/6ff926ec7c14626fc283d5ad79a3c410b1fc045d) fix(ci): filter native-handoff get by host target, | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.53 | 129.08 |
| [794c6d87e](https://github.com/AFK-surf/monoid/commit/794c6d87ed75741aa65ac8c0c9afa57c51358c57) fix(core-ts): stop lock reads from dialing unlinke | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.53 | 129.08 |
| [230e58f54](https://github.com/AFK-surf/monoid/commit/230e58f54d94eb5bba7b1b7d76054061ce616aac) fix(station): await async readFile in agy pastWait | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.53 | 129.08 |
| [47097061b](https://github.com/AFK-surf/monoid/commit/47097061b5bd44afb3e63b2b22a194506b85cd34) feat(station): add mb vs pion reader engine compar | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.53 | 129.08 |
| [df214c830](https://github.com/AFK-surf/monoid/commit/df214c8303070f7f785dede0c7225463bca5896c) fix(station): eliminate Linux ephemeral port race  | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.53 | 129.08 |
| [ba5068703](https://github.com/AFK-surf/monoid/commit/ba50687035bf07a94a6ef377e5359578536320af) fix(pion-station): sync readops parity for #8625 a | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.53 | 129.08 |
| [c67d892c7](https://github.com/AFK-surf/monoid/commit/c67d892c77c99cdde13c29b2d3687bf580c17010) ci(mbui): split mbui-host-windows contracts into t | 2.55 | 3.44 | 14.21 | 36.77 | 55.6 | 32.11 | 65 | 100.47 | 131.79 |
| [480a4ccad](https://github.com/AFK-surf/monoid/commit/480a4ccad1e1d2301cbf394423f5ff7eebb786de) fix(mbui): viewer taps toggle chrome; images at on | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.83 | 93.86 |
| [66fc0145f](https://github.com/AFK-surf/monoid/commit/66fc0145f612889519919079f360839083056e0a) perf(android): move notification IPC off app threa | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.83 | 93.86 |
| [d27f004bc](https://github.com/AFK-surf/monoid/commit/d27f004bc7c660da2dbfee7a20eda100f3b878d2) feat(station,app): GitHub Copilot as a station run | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.55 | 125.57 |
| [0dc373cef](https://github.com/AFK-surf/monoid/commit/0dc373cef1e2826ea03b3dc9e0e6de4555a84c8b) fix(core): show the running command, not the tool  | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.55 | 125.57 |
| [3f59bd231](https://github.com/AFK-surf/monoid/commit/3f59bd231f0784f4b83126f37930f2f0bba26659) fix(station): keep agy profiles off the macOS keyc | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.63 | 123.13 |
| [d65877bfe](https://github.com/AFK-surf/monoid/commit/d65877bfe98afbab2532bf32245e9b9adf464835) fix(app): make the text in interactive cards selec | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.63 | 123.13 |
| [3a47d3fd0](https://github.com/AFK-surf/monoid/commit/3a47d3fd021c0e9289b201a998f7afcb9549c025) fix(install): keep the station running when the ke | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.66 | 126.4 |
| [fcc12b2f2](https://github.com/AFK-surf/monoid/commit/fcc12b2f238fe55cf3c32f73730ad693f7c3c981) feat(ui): calibrate Regular Liquid Glass controls  | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.66 | 126.4 |
| [918c06c90](https://github.com/AFK-surf/monoid/commit/918c06c90111e3e415bf6c5f41f1c6302ef52555) build(station): bundle stillfail-pion native reade | 2.54 | 3.44 | 14.21 | 36.75 | 55.59 | 32.11 | 64.99 | 100.93 | 123.13 |
| [c4535b791](https://github.com/AFK-surf/monoid/commit/c4535b7918ac1a4c6c49914f4ef314579d1658e2) fix(core,station): show parent breadcrumbs on arch | 2.54 | 3.44 | 14.21 | 36.75 | 55.59 | 32.11 | 64.99 | 100.93 | 123.13 |
| [c4535b791](https://github.com/AFK-surf/monoid/commit/c4535b7918ac1a4c6c49914f4ef314579d1658e2) fix(core,station): show parent breadcrumbs on arch | 2.54 | 3.44 | 14.21 | 36.75 | 55.59 | 32.11 | 64.99 | 101.01 | 130.55 |
| [a647c8cd8](https://github.com/AFK-surf/monoid/commit/a647c8cd8653efc189f682ac138fb23ced025571) feat(core-ts): show size and speed of downloads, a | 2.54 | 3.43 | 14.19 | 36.72 | 55.5 | 32.08 | 64.92 | 101.06 | 127.43 |
| [df9dbe4c8](https://github.com/AFK-surf/monoid/commit/df9dbe4c8d749328665885f9f9c66b82e6626cdb) fix(pion-ui): sync icon_data.pion after #8643 and  | 2.54 | 3.43 | 14.18 | 36.72 | 55.49 | 32.08 | 64.9 | 101.06 | 120.08 |
| [1d04c4a24](https://github.com/AFK-surf/monoid/commit/1d04c4a24094b5c869979a84acf1391ceb812f66) fix(station): pace backup uploads so they no longe | 2.54 | 3.43 | 14.18 | 36.72 | 55.49 | 32.08 | 64.9 | 101.06 | 120.08 |
| [89a9d560b](https://github.com/AFK-surf/monoid/commit/89a9d560baa71e07c964dcd6a734f712eeebb5f1) perf(ios,core,mbui): enrich perf record with power | 2.54 | 3.43 | 14.18 | 36.72 | 55.49 | 32.08 | 64.9 | 101.06 | 120.08 |
| [f729b41ba](https://github.com/AFK-surf/monoid/commit/f729b41ba1ebd0435484cd00597a7f58d57a02e3) fix(mbui): stop a swiped row's 归档 softly at its sl | 2.54 | 3.43 | 14.18 | 36.72 | 55.48 | 32.07 | 64.89 | 101.11 | 121.55 |
| [8851a260e](https://github.com/AFK-surf/monoid/commit/8851a260ea6a65b7a440f1f78e0b19f7dc3bcb93) test(station): resolve new-account-cap concurrent  | 2.54 | 3.43 | 14.18 | 36.72 | 55.48 | 32.07 | 64.89 | 100.88 | 110.78 |
| [71a24c1b4](https://github.com/AFK-surf/monoid/commit/71a24c1b42326b2375412920d33edbc8d8a7ef14) feat(core,mbui): sync only the workspace in view,  | 2.54 | 3.43 | 14.18 | 36.72 | 55.48 | 32.07 | 64.89 | 100.88 | 110.78 |
| [5badca1bd](https://github.com/AFK-surf/monoid/commit/5badca1bd3f3f096a6fad209c44fe240c15059d7) feat(comma): report human participants in task.ind | 2.54 | 3.43 | 14.18 | 36.72 | 55.48 | 32.07 | 64.89 | 100.76 | 122.81 |
| [54be19794](https://github.com/AFK-surf/monoid/commit/54be1979418e710aa221906c6d5197ff178a6f8a) fix(mbui): hide the empty "who can use" section of | 2.54 | 3.43 | 14.18 | 36.72 | 55.48 | 32.07 | 64.89 | 100.76 | 122.81 |
| [ccfa67f6e](https://github.com/AFK-surf/monoid/commit/ccfa67f6e2da9a315fb547f49c47827bd4070c5c) fix(station): finish agy 1.5.14 company sign-ins p | 2.54 | 3.43 | 14.18 | 36.72 | 55.48 | 32.07 | 64.89 | 100.81 | 122.81 |
| [3c6d60e59](https://github.com/AFK-surf/monoid/commit/3c6d60e594fbed10d7bc0dcc249f77a8cb1109d8) fix(mbui): keep the remote rail dot steady during  | 2.54 | 3.43 | 14.18 | 36.72 | 55.48 | 32.07 | 64.89 | 100.96 | 123.35 |
| [cd9b47945](https://github.com/AFK-surf/monoid/commit/cd9b47945a7781e08f686cb52bd817296dc2988a) fix(ui): remove liquid slider end-clamp and flush- | 2.54 | 3.43 | 14.18 | 36.71 | 55.47 | 32.07 | 64.89 | 100.93 | 113.13 |
| [a9e0129a7](https://github.com/AFK-surf/monoid/commit/a9e0129a7fd817301be66e61e3edd0a7102b8ded) perf(ui): skip off-screen resident clock wakes and | 2.54 | 3.43 | 14.18 | 36.71 | 55.47 | 32.07 | 64.89 | 101.14 | 128.19 |
| [ff693e9ed](https://github.com/AFK-surf/monoid/commit/ff693e9ed78f3b196f93ece36f34e3c59e4e161d) feat(core,app): time a start before the core and t | 2.54 | 3.43 | 14.18 | 36.71 | 55.47 | 32.07 | 64.89 | 101.14 | 128.19 |
| [1776360fa](https://github.com/AFK-surf/monoid/commit/1776360fa07e72e590339786b6859d70daa5649e) fix(station): keep a builder's permit when the one | 2.54 | 3.43 | 14.18 | 36.71 | 55.47 | 32.07 | 64.89 | 100.89 | 126.26 |
| [973efe842](https://github.com/AFK-surf/monoid/commit/973efe84254621ae10ab2357785202523c2c3d54) fix(mbui): close the side panel on Esc with a file | 2.54 | 3.43 | 14.18 | 36.71 | 55.47 | 32.07 | 64.89 | 100.89 | 126.26 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [38f0aa4e0](https://github.com/AFK-surf/monoid/commit/38f0aa4e0dad79a45f5bd4b81d53f283c662b54c) feat(mbui): default profile sharing to follow work | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.23 |
| [a9403c5f7](https://github.com/AFK-surf/monoid/commit/a9403c5f758d891a20284a7b52ed34ed83d9160b) fix(lock,station): let admitted members verify off | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.23 |
| [dd7cfdf75](https://github.com/AFK-surf/monoid/commit/dd7cfdf759b3bbf099eec36cbe12f3a28df77ad3) fix(station): hear spawn errors before touching ch | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.18 |
| [686de55fb](https://github.com/AFK-surf/monoid/commit/686de55fbd0a4b4cd63ed6222a6d900f2181c2d2) fix(station): give agy only the skills that fit be | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.25 |
| [c2380f54e](https://github.com/AFK-surf/monoid/commit/c2380f54ebefbda921b5c1bbf9497cff1fc059c9) fix(mbui): anchor steps_seconds clock to eliminate | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57 |
| [fd72c2b59](https://github.com/AFK-surf/monoid/commit/fd72c2b59ac70c6fe5f6487ae97093859c30a2cf) fix(station): leave an unknown runtime's agentIden | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57 |
| [6ff926ec7](https://github.com/AFK-surf/monoid/commit/6ff926ec7c14626fc283d5ad79a3c410b1fc045d) fix(ci): filter native-handoff get by host target, | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.18 |
| [794c6d87e](https://github.com/AFK-surf/monoid/commit/794c6d87ed75741aa65ac8c0c9afa57c51358c57) fix(core-ts): stop lock reads from dialing unlinke | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.2 |
| [230e58f54](https://github.com/AFK-surf/monoid/commit/230e58f54d94eb5bba7b1b7d76054061ce616aac) fix(station): await async readFile in agy pastWait | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.31 |
| [47097061b](https://github.com/AFK-surf/monoid/commit/47097061b5bd44afb3e63b2b22a194506b85cd34) feat(station): add mb vs pion reader engine compar | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.26 |
| [df214c830](https://github.com/AFK-surf/monoid/commit/df214c8303070f7f785dede0c7225463bca5896c) fix(station): eliminate Linux ephemeral port race  | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.2 |
| [ba5068703](https://github.com/AFK-surf/monoid/commit/ba50687035bf07a94a6ef377e5359578536320af) fix(pion-station): sync readops parity for #8625 a | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.13 |
| [c67d892c7](https://github.com/AFK-surf/monoid/commit/c67d892c77c99cdde13c29b2d3687bf580c17010) ci(mbui): split mbui-host-windows contracts into t | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.2 |
| [480a4ccad](https://github.com/AFK-surf/monoid/commit/480a4ccad1e1d2301cbf394423f5ff7eebb786de) fix(mbui): viewer taps toggle chrome; images at on | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.43 |
| [66fc0145f](https://github.com/AFK-surf/monoid/commit/66fc0145f612889519919079f360839083056e0a) perf(android): move notification IPC off app threa | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.28 |
| [d27f004bc](https://github.com/AFK-surf/monoid/commit/d27f004bc7c660da2dbfee7a20eda100f3b878d2) feat(station,app): GitHub Copilot as a station run | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.31 |
| [0dc373cef](https://github.com/AFK-surf/monoid/commit/0dc373cef1e2826ea03b3dc9e0e6de4555a84c8b) fix(core): show the running command, not the tool  | 0.56 | 0.74 | 2.86 | 3.9 | 7.15 | 2.12 | 5.96 | 57.28 |
| [3f59bd231](https://github.com/AFK-surf/monoid/commit/3f59bd231f0784f4b83126f37930f2f0bba26659) fix(station): keep agy profiles off the macOS keyc | 0.56 | 0.74 | 2.86 | 3.9 | 7.15 | 2.12 | 5.96 | 57.18 |
| [d65877bfe](https://github.com/AFK-surf/monoid/commit/d65877bfe98afbab2532bf32245e9b9adf464835) fix(app): make the text in interactive cards selec | 0.56 | 0.74 | 2.86 | 3.9 | 7.15 | 2.12 | 5.96 | 56.9 |
| [3a47d3fd0](https://github.com/AFK-surf/monoid/commit/3a47d3fd021c0e9289b201a998f7afcb9549c025) fix(install): keep the station running when the ke | 0.56 | 0.74 | 2.86 | 3.9 | 7.15 | 2.12 | 5.96 | 57.46 |
| [fcc12b2f2](https://github.com/AFK-surf/monoid/commit/fcc12b2f238fe55cf3c32f73730ad693f7c3c981) feat(ui): calibrate Regular Liquid Glass controls  | 0.56 | 0.74 | 2.86 | 3.9 | 7.15 | 2.12 | 5.96 | 57.21 |
| [918c06c90](https://github.com/AFK-surf/monoid/commit/918c06c90111e3e415bf6c5f41f1c6302ef52555) build(station): bundle stillfail-pion native reade | 0.56 | 0.74 | 2.86 | 3.9 | 7.15 | 2.12 | 5.96 | 57.36 |
| [c4535b791](https://github.com/AFK-surf/monoid/commit/c4535b7918ac1a4c6c49914f4ef314579d1658e2) fix(core,station): show parent breadcrumbs on arch | 0.56 | 0.74 | 2.86 | 3.9 | 7.14 | 2.12 | 5.94 | 57.59 |
| [c4535b791](https://github.com/AFK-surf/monoid/commit/c4535b7918ac1a4c6c49914f4ef314579d1658e2) fix(core,station): show parent breadcrumbs on arch | 0.56 | 0.74 | 2.86 | 3.9 | 7.14 | 2.12 | 5.94 | 57.75 |
| [a647c8cd8](https://github.com/AFK-surf/monoid/commit/a647c8cd8653efc189f682ac138fb23ced025571) feat(core-ts): show size and speed of downloads, a | 0.56 | 0.74 | 2.86 | 3.9 | 7.14 | 2.12 | 5.94 | 57.67 |
| [df9dbe4c8](https://github.com/AFK-surf/monoid/commit/df9dbe4c8d749328665885f9f9c66b82e6626cdb) fix(pion-ui): sync icon_data.pion after #8643 and  | 0.56 | 0.74 | 2.86 | 3.9 | 7.14 | 2.12 | 5.94 | 57.87 |
| [1d04c4a24](https://github.com/AFK-surf/monoid/commit/1d04c4a24094b5c869979a84acf1391ceb812f66) fix(station): pace backup uploads so they no longe | 0.56 | 0.74 | 2.86 | 3.9 | 7.14 | 2.12 | 5.94 | 57.71 |
| [89a9d560b](https://github.com/AFK-surf/monoid/commit/89a9d560baa71e07c964dcd6a734f712eeebb5f1) perf(ios,core,mbui): enrich perf record with power | 0.56 | 0.74 | 2.86 | 3.9 | 7.14 | 2.12 | 5.94 | 57.57 |
| [f729b41ba](https://github.com/AFK-surf/monoid/commit/f729b41ba1ebd0435484cd00597a7f58d57a02e3) fix(mbui): stop a swiped row's 归档 softly at its sl | 0.56 | 0.74 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.9 |
| [8851a260e](https://github.com/AFK-surf/monoid/commit/8851a260ea6a65b7a440f1f78e0b19f7dc3bcb93) test(station): resolve new-account-cap concurrent  | 0.56 | 0.74 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.53 |
| [71a24c1b4](https://github.com/AFK-surf/monoid/commit/71a24c1b42326b2375412920d33edbc8d8a7ef14) feat(core,mbui): sync only the workspace in view,  | 0.56 | 0.74 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.9 |
| [5badca1bd](https://github.com/AFK-surf/monoid/commit/5badca1bd3f3f096a6fad209c44fe240c15059d7) feat(comma): report human participants in task.ind | 0.56 | 0.74 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.82 |
| [54be19794](https://github.com/AFK-surf/monoid/commit/54be1979418e710aa221906c6d5197ff178a6f8a) fix(mbui): hide the empty "who can use" section of | 0.56 | 0.74 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.59 |
| [ccfa67f6e](https://github.com/AFK-surf/monoid/commit/ccfa67f6e2da9a315fb547f49c47827bd4070c5c) fix(station): finish agy 1.5.14 company sign-ins p | 0.56 | 0.74 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.57 |
| [3c6d60e59](https://github.com/AFK-surf/monoid/commit/3c6d60e594fbed10d7bc0dcc249f77a8cb1109d8) fix(mbui): keep the remote rail dot steady during  | 0.56 | 0.74 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.71 |
| [cd9b47945](https://github.com/AFK-surf/monoid/commit/cd9b47945a7781e08f686cb52bd817296dc2988a) fix(ui): remove liquid slider end-clamp and flush- | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.69 |
| [a9e0129a7](https://github.com/AFK-surf/monoid/commit/a9e0129a7fd817301be66e61e3edd0a7102b8ded) perf(ui): skip off-screen resident clock wakes and | 0.56 | 0.74 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.59 |
| [ff693e9ed](https://github.com/AFK-surf/monoid/commit/ff693e9ed78f3b196f93ece36f34e3c59e4e161d) feat(core,app): time a start before the core and t | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.41 |
| [1776360fa](https://github.com/AFK-surf/monoid/commit/1776360fa07e72e590339786b6859d70daa5649e) fix(station): keep a builder's permit when the one | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.53 |
| [973efe842](https://github.com/AFK-surf/monoid/commit/973efe84254621ae10ab2357785202523c2c3d54) fix(mbui): close the side panel on Esc with a file | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.53 |
