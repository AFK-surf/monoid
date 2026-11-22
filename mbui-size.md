# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [2e83ff5d4](https://github.com/AFK-surf/monoid/commit/2e83ff5d4f1a7ac17214417e10e508cf021d3733) fix(mbui): refresh page-seconds and rebalance app  | 2.72 | 3.66 | 14.83 | 36.94 | 56.49 | 32.37 | 65.71 | 99.62 | 124.9 |
| [8c3c82085](https://github.com/AFK-surf/monoid/commit/8c3c82085e63fd332d5a3670cea5d94714a0e689) feat(mbui): merge composer-top controls into one c | 2.72 | 3.66 | 14.83 | 36.94 | 56.49 | 32.37 | 65.71 | 99.62 | 124.9 |
| [13cfd02f3](https://github.com/AFK-surf/monoid/commit/13cfd02f3d105d402dd4ff4bd2a8d9ab6fd4f5c2) feat(sf-ui): upgrade floating player controls and  | 2.71 | 3.65 | 14.82 | 36.93 | 56.44 | 32.35 | 65.66 | 99.57 | 157.03 |
| [4dcdd2a40](https://github.com/AFK-surf/monoid/commit/4dcdd2a40e05ee58cf7453db5422eeac18879dda) fix(mbui): track composed text for composer line r | 2.71 | 3.65 | 14.82 | 36.93 | 56.43 | 32.35 | 65.66 | 99.63 | 125.17 |
| [1809b2751](https://github.com/AFK-surf/monoid/commit/1809b2751552f70b75a8dae34dcb50288db4591f) fix(station): drop O(N²) scans from MoonBit replic | 2.71 | 3.65 | 14.81 | 36.93 | 56.43 | 32.35 | 65.66 | 99.4 | 127.26 |
| [063ac567f](https://github.com/AFK-surf/monoid/commit/063ac567f454ce7f1828c157a6bdd6fad8145610) feat(mbui,sf-ui): polish iOS 26/27 liquid glass pr | 2.71 | 3.65 | 14.81 | 36.93 | 56.43 | 32.35 | 65.66 | 99.71 | 127.72 |
| [77aef8b6d](https://github.com/AFK-surf/monoid/commit/77aef8b6d7aff40a9bff79032a9a4553b570ac9b) perf(mbui): cut medium-screen tape drag frame cost | 2.71 | 3.65 | 14.81 | 36.93 | 56.43 | 32.35 | 65.64 | 99.55 | 127.72 |
| [40807fa89](https://github.com/AFK-surf/monoid/commit/40807fa892485f932200ffe2772f7acb2b9caa24) refactor(sf-ui,website): unify ui.monoid live stud | 2.71 | 3.65 | 14.81 | 36.92 | 56.41 | 32.35 | 65.64 | 99.63 | 126.38 |
| [02f41fec5](https://github.com/AFK-surf/monoid/commit/02f41fec50cc59a564b150a7c47cecc848edc501) feat(sf-ui): align segmented and slider liquid gla | 2.71 | 3.65 | 14.81 | 36.92 | 56.41 | 32.35 | 65.64 | 99.6 | 128.73 |
| [ba6e9abbf](https://github.com/AFK-surf/monoid/commit/ba6e9abbfd3cc643cc3d6ee825df237c528e61f5) fix(cloud): give the web.json put its Cloudflare a | 2.71 | 3.65 | 14.81 | 36.93 | 56.42 | 32.36 | 65.64 | 99.63 | 131.04 |
| [f43ce757d](https://github.com/AFK-surf/monoid/commit/f43ce757d63053878134d6c1218711955822c7da) refactor(sf-ui): move the bottom bar's glass onto  | 2.7 | 3.64 | 14.76 | 36.86 | 56.21 | 32.3 | 65.46 | 99.53 | 117.37 |
| [3e63fed71](https://github.com/AFK-surf/monoid/commit/3e63fed71c7e6870293138e275744584ccdbdbb4) fix(mbui): run switches tests through a core-sized | 2.7 | 3.64 | 14.76 | 36.86 | 56.21 | 32.3 | 65.46 | 99.45 | 122.56 |
| [c442e4689](https://github.com/AFK-surf/monoid/commit/c442e468983462b7c71ed8eaee0ddf14fe76a0c6) fix(app): stop raising lifted media above composer | 2.7 | 3.64 | 14.76 | 36.86 | 56.21 | 32.28 | 65.46 | 99.55 | 115.86 |
| [2787f032a](https://github.com/AFK-surf/monoid/commit/2787f032ab7824c096d7cc4222b5a4244a8378ff) refactor(sf-ui): merge production liquid glass lay | 2.7 | 3.64 | 14.75 | 36.85 | 56.2 | 32.28 | 65.46 | 99.55 | 126.47 |
| [3a99f35e7](https://github.com/AFK-surf/monoid/commit/3a99f35e7d0e81f7a35027e8af34dd51c34e3f90) fix(station): leave Unix domain sockets out of arc | 2.7 | 3.64 | 14.75 | 36.85 | 56.19 | 32.28 | 65.46 | 99.19 | 121.69 |
| [219e4eeb0](https://github.com/AFK-surf/monoid/commit/219e4eeb0f336f78ce342038ab6ef2795238f2d5) perf(mbui): optimize Apple and Android text shapin | 2.7 | 3.64 | 14.75 | 36.85 | 56.19 | 32.27 | 65.46 | 99.35 | 140.9 |
| [0e13725c6](https://github.com/AFK-surf/monoid/commit/0e13725c60fa22a216a72f725dc0259ab0d467f3) perf(mbui): make one page block per station in Pla | 2.7 | 3.64 | 14.75 | 36.84 | 56.19 | 32.27 | 65.46 | 99.01 | 119.94 |
| [4daac21ad](https://github.com/AFK-surf/monoid/commit/4daac21adb61ca310f25a8e92d6fbb2634ed3a10) perf(mbui): de-amplify GLES and Metal partial redr | 2.7 | 3.64 | 14.75 | 36.84 | 56.19 | 32.27 | 65.46 | 99.01 | 119.94 |
| [f5b905dd9](https://github.com/AFK-surf/monoid/commit/f5b905dd908240a93b88d6f5ab5236a946722e40) feat(app): a station's 资源 says what the machine is | 2.7 | 3.64 | 14.75 | 36.84 | 56.19 | 32.27 | 65.46 | 98.96 | 120.06 |
| [0c7cb25d4](https://github.com/AFK-surf/monoid/commit/0c7cb25d40707b594be15d68df81e6525a45c6ed) fix(sf-ui): adapt window keys glass over dark back | 2.7 | 3.64 | 14.75 | 36.84 | 56.19 | 32.27 | 65.46 | 99.04 | 129.98 |
| [c65cbf33e](https://github.com/AFK-surf/monoid/commit/c65cbf33ee3de127d64ec400103b7228ed25d7c7) feat(mbui): show only Web services in chat bar, li | 2.7 | 3.64 | 14.75 | 36.84 | 56.19 | 32.27 | 65.46 | 99.01 | 129.05 |
| [4564d7804](https://github.com/AFK-surf/monoid/commit/4564d7804083ceec2e3b30c7603fee7b14c2efcc) feat(ios): bring pushed messages onto the device i | 2.7 | 3.64 | 14.75 | 36.84 | 56.19 | 32.27 | 65.46 | 99.01 | 129.05 |
| [dd5869c8c](https://github.com/AFK-surf/monoid/commit/dd5869c8cb9ceb4ff62cc17ec883ee02ffb12ed9) fix(sf-ui): in-container submenu slide, pill morph | 2.7 | 3.64 | 14.75 | 36.84 | 56.19 | 32.27 | 65.46 | 99.16 | 123.14 |
| [627160f39](https://github.com/AFK-surf/monoid/commit/627160f39bc0c40e1bcab473e7161d2d4789ec48) chore(sf-ui): guard against raw glass outside @lg  | 2.7 | 3.63 | 14.73 | 36.82 | 56.09 | 32.25 | 65.38 | 99.21 | 121.28 |
| [dd573a706](https://github.com/AFK-surf/monoid/commit/dd573a706239ec1ae450b59bff9fef8f5d839ce3) refactor(sf-ui): delegate controls, capsules, lens | 2.7 | 3.63 | 14.73 | 36.82 | 56.09 | 32.25 | 65.38 | 99.32 | 125.45 |
| [f70cbae6f](https://github.com/AFK-surf/monoid/commit/f70cbae6f66c4022f8d655a311a01a188ebc1ae9) fix(mbui,sf-ui): let the wheel scroll the page und | 2.7 | 3.64 | 14.73 | 36.82 | 56.11 | 32.25 | 65.39 | 99.12 | 119.8 |
| [085d7c0a8](https://github.com/AFK-surf/monoid/commit/085d7c0a84130648707d7f09f68058f82a90c5a0) fix(mbui): unbind blur levels before glass draws i | 2.7 | 3.64 | 14.73 | 36.82 | 56.11 | 32.25 | 65.39 | 99.12 | 119.8 |
| [d94818248](https://github.com/AFK-surf/monoid/commit/d948182484b4d401de1f16ae9323305032a147c8) feat(mbui): polish multi-touch scrolling velocity, | 2.7 | 3.64 | 14.73 | 36.82 | 56.1 | 32.25 | 65.39 | 99.26 | 126.73 |
| [b390c13c4](https://github.com/AFK-surf/monoid/commit/b390c13c494ec2029c85b8ebe3cdce0500af8507) feat(mbui): upgrade narrow sub-page back button an | 2.7 | 3.63 | 14.72 | 36.81 | 56.09 | 32.25 | 65.39 | 99.26 | 127.7 |
| [69d36b777](https://github.com/AFK-surf/monoid/commit/69d36b77723412480ecb77f482f465e84d0cc226) feat(mbui): move archived and feedback notices to  | 2.7 | 3.63 | 14.72 | 36.81 | 56.09 | 32.25 | 65.39 | 99.26 | 127.7 |
| [35b23251f](https://github.com/AFK-surf/monoid/commit/35b23251f0cf9de43be53db39aa7c1a60519567a) feat(liquid-glass): add pill trigger scope, capsul | 2.7 | 3.63 | 14.71 | 36.81 | 56.07 | 32.25 | 65.36 | 99.22 | 122.29 |
| [35b23251f](https://github.com/AFK-surf/monoid/commit/35b23251f0cf9de43be53db39aa7c1a60519567a) feat(liquid-glass): add pill trigger scope, capsul | 2.7 | 3.63 | 14.71 | 36.81 | 56.07 | 32.24 | 65.34 | 99.34 | 125.71 |
| [4f0b0d29b](https://github.com/AFK-surf/monoid/commit/4f0b0d29bc4e0be898bbbc740f211c3b2b195ece) feat(liquid-glass): add overlay, drawer, and morph | 2.7 | 3.63 | 14.7 | 36.79 | 56.05 | 32.24 | 65.34 | 99.34 | 122.78 |
| [c2a94eb4a](https://github.com/AFK-surf/monoid/commit/c2a94eb4a98da030645237dd6f56d5fe51faa614) perf(sf-ui): mount the offers overlay only when it | 2.7 | 3.63 | 14.7 | 36.79 | 56.05 | 32.24 | 65.34 | 99.27 | 124.04 |
| [05e4455a8](https://github.com/AFK-surf/monoid/commit/05e4455a883e2eec552185a7647e3a0603539908) perf(mbui): fix rotated glass cache invalidation a | 2.7 | 3.63 | 14.7 | 36.8 | 56.05 | 32.24 | 65.34 | 99.11 | 124.3 |
| [54143d819](https://github.com/AFK-surf/monoid/commit/54143d8197007801c1b85fa22acfe3cb341e1f00) fix(mbui): keep frequent model names readable (#81 | 2.7 | 3.63 | 14.7 | 36.8 | 56.04 | 32.24 | 65.34 | 99.21 | 118.59 |
| [005f1d100](https://github.com/AFK-surf/monoid/commit/005f1d100a6a15a0a4e86c7e96eb271e251570e2) fix(mbui): let two fingers take turns scrolling a  | 2.7 | 3.63 | 14.7 | 36.79 | 56.04 | 32.24 | 65.34 | 99.16 | 126.07 |
| [e414d0eca](https://github.com/AFK-surf/monoid/commit/e414d0eca0b572035ccbd302232fb58e0555b445) perf(station): start the runtime when an app makes | 2.7 | 3.63 | 14.69 | 36.78 | 56.01 | 32.23 | 65.33 | 99.44 | 124.13 |
| [29f393569](https://github.com/AFK-surf/monoid/commit/29f393569f860c872ada1332c2bf6dcf1579e83f) feat(mbui): keep long UI hangs in a local log (#81 | 2.7 | 3.63 | 14.69 | 36.78 | 56.01 | 32.23 | 65.33 | 99.44 | 124.13 |
| [0f1800b12](https://github.com/AFK-surf/monoid/commit/0f1800b122c3d86a2fefe2ca7adb25b4181defdf) fix(mbui): replace 9-tap progressive blur small-ra | 2.69 | 3.63 | 14.69 | 36.79 | 56 | 32.23 | 65.31 | 99.27 | 127.74 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [2e83ff5d4](https://github.com/AFK-surf/monoid/commit/2e83ff5d4f1a7ac17214417e10e508cf021d3733) fix(mbui): refresh page-seconds and rebalance app  | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.58 |
| [8c3c82085](https://github.com/AFK-surf/monoid/commit/8c3c82085e63fd332d5a3670cea5d94714a0e689) feat(mbui): merge composer-top controls into one c | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 55 |
| [13cfd02f3](https://github.com/AFK-surf/monoid/commit/13cfd02f3d105d402dd4ff4bd2a8d9ab6fd4f5c2) feat(sf-ui): upgrade floating player controls and  | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.84 |
| [4dcdd2a40](https://github.com/AFK-surf/monoid/commit/4dcdd2a40e05ee58cf7453db5422eeac18879dda) fix(mbui): track composed text for composer line r | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.74 |
| [1809b2751](https://github.com/AFK-surf/monoid/commit/1809b2751552f70b75a8dae34dcb50288db4591f) fix(station): drop O(N²) scans from MoonBit replic | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.53 |
| [063ac567f](https://github.com/AFK-surf/monoid/commit/063ac567f454ce7f1828c157a6bdd6fad8145610) feat(mbui,sf-ui): polish iOS 26/27 liquid glass pr | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.81 |
| [77aef8b6d](https://github.com/AFK-surf/monoid/commit/77aef8b6d7aff40a9bff79032a9a4553b570ac9b) perf(mbui): cut medium-screen tape drag frame cost | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.46 |
| [40807fa89](https://github.com/AFK-surf/monoid/commit/40807fa892485f932200ffe2772f7acb2b9caa24) refactor(sf-ui,website): unify ui.monoid live stud | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.69 |
| [02f41fec5](https://github.com/AFK-surf/monoid/commit/02f41fec50cc59a564b150a7c47cecc848edc501) feat(sf-ui): align segmented and slider liquid gla | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.69 |
| [ba6e9abbf](https://github.com/AFK-surf/monoid/commit/ba6e9abbfd3cc643cc3d6ee825df237c528e61f5) fix(cloud): give the web.json put its Cloudflare a | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.69 |
| [f43ce757d](https://github.com/AFK-surf/monoid/commit/f43ce757d63053878134d6c1218711955822c7da) refactor(sf-ui): move the bottom bar's glass onto  | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.69 |
| [3e63fed71](https://github.com/AFK-surf/monoid/commit/3e63fed71c7e6870293138e275744584ccdbdbb4) fix(mbui): run switches tests through a core-sized | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.69 |
| [c442e4689](https://github.com/AFK-surf/monoid/commit/c442e468983462b7c71ed8eaee0ddf14fe76a0c6) fix(app): stop raising lifted media above composer | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.69 |
| [2787f032a](https://github.com/AFK-surf/monoid/commit/2787f032ab7824c096d7cc4222b5a4244a8378ff) refactor(sf-ui): merge production liquid glass lay | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.59 |
| [3a99f35e7](https://github.com/AFK-surf/monoid/commit/3a99f35e7d0e81f7a35027e8af34dd51c34e3f90) fix(station): leave Unix domain sockets out of arc | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.59 |
| [219e4eeb0](https://github.com/AFK-surf/monoid/commit/219e4eeb0f336f78ce342038ab6ef2795238f2d5) perf(mbui): optimize Apple and Android text shapin | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.59 |
| [0e13725c6](https://github.com/AFK-surf/monoid/commit/0e13725c60fa22a216a72f725dc0259ab0d467f3) perf(mbui): make one page block per station in Pla | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.59 |
| [4daac21ad](https://github.com/AFK-surf/monoid/commit/4daac21adb61ca310f25a8e92d6fbb2634ed3a10) perf(mbui): de-amplify GLES and Metal partial redr | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.67 |
| [f5b905dd9](https://github.com/AFK-surf/monoid/commit/f5b905dd908240a93b88d6f5ab5236a946722e40) feat(app): a station's 资源 says what the machine is | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.61 |
| [0c7cb25d4](https://github.com/AFK-surf/monoid/commit/0c7cb25d40707b594be15d68df81e6525a45c6ed) fix(sf-ui): adapt window keys glass over dark back | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.61 |
| [c65cbf33e](https://github.com/AFK-surf/monoid/commit/c65cbf33ee3de127d64ec400103b7228ed25d7c7) feat(mbui): show only Web services in chat bar, li | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.61 |
| [4564d7804](https://github.com/AFK-surf/monoid/commit/4564d7804083ceec2e3b30c7603fee7b14c2efcc) feat(ios): bring pushed messages onto the device i | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.76 |
| [dd5869c8c](https://github.com/AFK-surf/monoid/commit/dd5869c8cb9ceb4ff62cc17ec883ee02ffb12ed9) fix(sf-ui): in-container submenu slide, pill morph | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.85 |
| [627160f39](https://github.com/AFK-surf/monoid/commit/627160f39bc0c40e1bcab473e7161d2d4789ec48) chore(sf-ui): guard against raw glass outside @lg  | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.85 |
| [dd573a706](https://github.com/AFK-surf/monoid/commit/dd573a706239ec1ae450b59bff9fef8f5d839ce3) refactor(sf-ui): delegate controls, capsules, lens | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.85 |
| [f70cbae6f](https://github.com/AFK-surf/monoid/commit/f70cbae6f66c4022f8d655a311a01a188ebc1ae9) fix(mbui,sf-ui): let the wheel scroll the page und | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.85 |
| [085d7c0a8](https://github.com/AFK-surf/monoid/commit/085d7c0a84130648707d7f09f68058f82a90c5a0) fix(mbui): unbind blur levels before glass draws i | 0.48 | 0.63 | 2.44 | 3.49 | 5.79 | 1.78 | 4.82 | 54.79 |
| [d94818248](https://github.com/AFK-surf/monoid/commit/d948182484b4d401de1f16ae9323305032a147c8) feat(mbui): polish multi-touch scrolling velocity, | 0.48 | 0.63 | 2.44 | 3.49 | 5.79 | 1.78 | 4.82 | 54.56 |
| [b390c13c4](https://github.com/AFK-surf/monoid/commit/b390c13c494ec2029c85b8ebe3cdce0500af8507) feat(mbui): upgrade narrow sub-page back button an | 0.48 | 0.63 | 2.44 | 3.49 | 5.79 | 1.78 | 4.82 | 54.56 |
| [69d36b777](https://github.com/AFK-surf/monoid/commit/69d36b77723412480ecb77f482f465e84d0cc226) feat(mbui): move archived and feedback notices to  | 0.48 | 0.63 | 2.43 | 3.49 | 5.78 | 1.78 | 4.8 | 54.63 |
| [35b23251f](https://github.com/AFK-surf/monoid/commit/35b23251f0cf9de43be53db39aa7c1a60519567a) feat(liquid-glass): add pill trigger scope, capsul | 0.48 | 0.63 | 2.43 | 3.49 | 5.78 | 1.78 | 4.8 | 54.63 |
| [35b23251f](https://github.com/AFK-surf/monoid/commit/35b23251f0cf9de43be53db39aa7c1a60519567a) feat(liquid-glass): add pill trigger scope, capsul | 0.48 | 0.63 | 2.43 | 3.49 | 5.78 | 1.78 | 4.8 | 54.63 |
| [4f0b0d29b](https://github.com/AFK-surf/monoid/commit/4f0b0d29bc4e0be898bbbc740f211c3b2b195ece) feat(liquid-glass): add overlay, drawer, and morph | 0.48 | 0.63 | 2.43 | 3.49 | 5.78 | 1.78 | 4.8 | 54.63 |
| [c2a94eb4a](https://github.com/AFK-surf/monoid/commit/c2a94eb4a98da030645237dd6f56d5fe51faa614) perf(sf-ui): mount the offers overlay only when it | 0.48 | 0.63 | 2.43 | 3.49 | 5.78 | 1.78 | 4.8 | 54.63 |
| [05e4455a8](https://github.com/AFK-surf/monoid/commit/05e4455a883e2eec552185a7647e3a0603539908) perf(mbui): fix rotated glass cache invalidation a | 0.48 | 0.63 | 2.43 | 3.49 | 5.78 | 1.78 | 4.8 | 54.63 |
| [54143d819](https://github.com/AFK-surf/monoid/commit/54143d8197007801c1b85fa22acfe3cb341e1f00) fix(mbui): keep frequent model names readable (#81 | 0.48 | 0.63 | 2.43 | 3.49 | 5.77 | 1.78 | 4.8 | 54.56 |
| [005f1d100](https://github.com/AFK-surf/monoid/commit/005f1d100a6a15a0a4e86c7e96eb271e251570e2) fix(mbui): let two fingers take turns scrolling a  | 0.48 | 0.63 | 2.43 | 3.49 | 5.77 | 1.78 | 4.8 | 54.56 |
| [e414d0eca](https://github.com/AFK-surf/monoid/commit/e414d0eca0b572035ccbd302232fb58e0555b445) perf(station): start the runtime when an app makes | 0.48 | 0.63 | 2.43 | 3.49 | 5.77 | 1.78 | 4.8 | 54.56 |
| [29f393569](https://github.com/AFK-surf/monoid/commit/29f393569f860c872ada1332c2bf6dcf1579e83f) feat(mbui): keep long UI hangs in a local log (#81 | 0.48 | 0.63 | 2.43 | 3.49 | 5.77 | 1.78 | 4.8 | 54.48 |
| [0f1800b12](https://github.com/AFK-surf/monoid/commit/0f1800b122c3d86a2fefe2ca7adb25b4181defdf) fix(mbui): replace 9-tap progressive blur small-ra | 0.48 | 0.63 | 2.43 | 3.49 | 5.77 | 1.78 | 4.8 | 54.48 |
