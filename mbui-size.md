# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [ed329b2b2](https://github.com/AFK-surf/monoid/commit/ed329b2b20a06afe3fd1bd50b6a99260676b27bc) fix(ui): unify GLES kind 11 path loop for SwiftSha | 2.54 | 3.43 | 14.18 | 36.71 | 55.47 | 32.07 | 64.89 | 100.89 | 126.26 |
| [2551adf7c](https://github.com/AFK-surf/monoid/commit/2551adf7c40279f71ec8b698c011f40a63b531e2) feat(pion-station): W7-D readops_views L2 package  | 2.54 | 3.43 | 14.18 | 36.72 | 55.47 | 32.07 | 64.89 | 101.01 | 125.52 |
| [c5360f5d9](https://github.com/AFK-surf/monoid/commit/c5360f5d9310088fb6c4f26c96eb29f88f76bdbc) fix(rules): only a web page's device runs out (#86 | 2.54 | 3.43 | 14.18 | 36.72 | 55.47 | 32.07 | 64.89 | 101.01 | 125.52 |
| [05f2d897f](https://github.com/AFK-surf/monoid/commit/05f2d897fca75d83bab1c4d2f36022735633c2fa) perf(station): eliminate cross-station slot sync S | 2.54 | 3.43 | 14.18 | 36.72 | 55.47 | 32.07 | 64.89 | 100.91 | 130.84 |
| [bf6c0b0b1](https://github.com/AFK-surf/monoid/commit/bf6c0b0b1ef743dcb270744775fbcb57298959c0) fix(mbui): part the stations sidebar's cards and g | 2.54 | 3.43 | 14.18 | 36.72 | 55.47 | 32.07 | 64.89 | 100.91 | 130.84 |
| [217b8c948](https://github.com/AFK-surf/monoid/commit/217b8c9486c48d3b5b1ce73b70896b9ffd4737d5) feat(pion-station): port readops_usage (W7-E) with | 2.54 | 3.43 | 14.17 | 36.71 | 55.44 | 32.06 | 64.85 | 100.84 | 131.87 |
| [f20305d93](https://github.com/AFK-surf/monoid/commit/f20305d93d413a5bd147f8b076b7accd8fd61498) perf(profiles): eliminate overview freezes via pac | 2.54 | 3.43 | 14.17 | 36.71 | 55.44 | 32.06 | 64.85 | 100.84 | 131.87 |
| [4d3015d7b](https://github.com/AFK-surf/monoid/commit/4d3015d7bf4d64f699a96a2cc54110c68f6e689b) feat(ui): redesign video viewer with full-bleed st | 2.53 | 3.41 | 14.09 | 36.63 | 55.14 | 31.99 | 64.64 | 101.01 | 128.65 |
| [37699ee04](https://github.com/AFK-surf/monoid/commit/37699ee04412dd4433c9f786773079894972d966) fix(mbui): fade adjacent stations list dividers on | 2.53 | 3.41 | 14.07 | 36.61 | 55.09 | 31.97 | 64.59 | 100.84 | 128.89 |
| [e86c47ecb](https://github.com/AFK-surf/monoid/commit/e86c47ecb166aedb9496078a0be5f06a53db8b89) feat(mbui,i18n): add V8 single-screen font setting | 2.53 | 3.41 | 14.07 | 36.61 | 55.09 | 31.97 | 64.59 | 100.84 | 128.89 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [ed329b2b2](https://github.com/AFK-surf/monoid/commit/ed329b2b20a06afe3fd1bd50b6a99260676b27bc) fix(ui): unify GLES kind 11 path loop for SwiftSha | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.71 |
| [2551adf7c](https://github.com/AFK-surf/monoid/commit/2551adf7c40279f71ec8b698c011f40a63b531e2) feat(pion-station): W7-D readops_views L2 package  | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.75 |
| [c5360f5d9](https://github.com/AFK-surf/monoid/commit/c5360f5d9310088fb6c4f26c96eb29f88f76bdbc) fix(rules): only a web page's device runs out (#86 | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.95 |
| [05f2d897f](https://github.com/AFK-surf/monoid/commit/05f2d897fca75d83bab1c4d2f36022735633c2fa) perf(station): eliminate cross-station slot sync S | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.13 |
| [bf6c0b0b1](https://github.com/AFK-surf/monoid/commit/bf6c0b0b1ef743dcb270744775fbcb57298959c0) fix(mbui): part the stations sidebar's cards and g | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 58.03 |
| [217b8c948](https://github.com/AFK-surf/monoid/commit/217b8c9486c48d3b5b1ce73b70896b9ffd4737d5) feat(pion-station): port readops_usage (W7-E) with | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 58.02 |
| [f20305d93](https://github.com/AFK-surf/monoid/commit/f20305d93d413a5bd147f8b076b7accd8fd61498) perf(profiles): eliminate overview freezes via pac | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 58.02 |
| [4d3015d7b](https://github.com/AFK-surf/monoid/commit/4d3015d7bf4d64f699a96a2cc54110c68f6e689b) feat(ui): redesign video viewer with full-bleed st | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.49 |
| [37699ee04](https://github.com/AFK-surf/monoid/commit/37699ee04412dd4433c9f786773079894972d966) fix(mbui): fade adjacent stations list dividers on | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.54 |
| [e86c47ecb](https://github.com/AFK-surf/monoid/commit/e86c47ecb166aedb9496078a0be5f06a53db8b89) feat(mbui,i18n): add V8 single-screen font setting | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.94 | 57.75 |
