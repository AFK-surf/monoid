# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [1953aa4af](https://github.com/AFK-surf/monoid/commit/1953aa4af5ba6cc481dcf18bf8070ece6c628bd5) fix(notice): fix profile push routing, notice.brin | 2.69 | 3.63 | 14.69 | 36.79 | 56 | 32.2 | 65.24 | 99.85 | 89.85 |
| [8b62854f0](https://github.com/AFK-surf/monoid/commit/8b62854f03592bd74c4e3427f2eae920b434a8c5) feat(mbui): replace legacy frosted bars with liqui | 2.69 | 3.62 | 14.66 | 36.76 | 55.92 | 32.2 | 65.24 | 99.85 | 103.82 |
| [3e01fcab0](https://github.com/AFK-surf/monoid/commit/3e01fcab0066b6975b928daf9c03abc4f0fb1dba) feat(lg,sf-ui,mbui): port iOS 27.0 LiquidMorphPhys | 2.69 | 3.62 | 14.66 | 36.76 | 55.91 | 32.2 | 65.24 | 100.12 | 125.32 |
| [e9f48df90](https://github.com/AFK-surf/monoid/commit/e9f48df90aca90a16004e26ef91eaf6cff6c00ec) fix(mbui): shorten the app update row (#8165) | 2.69 | 3.62 | 14.66 | 36.76 | 55.91 | 32.2 | 65.24 | 100.12 | 125.32 |
| [61314116d](https://github.com/AFK-surf/monoid/commit/61314116db05d116bc27f23a8809c99948a4f49e) fix(station): catch mid-session MCP loss and backo | 2.68 | 3.61 | 14.66 | 36.74 | 55.88 | 32.2 | 65.21 | 99.94 | 123.62 |
| [8b659b96c](https://github.com/AFK-surf/monoid/commit/8b659b96c7cd9a7b67ef429649ac6557ea1b7f19) perf(mbui): add Windows D3D11 GPU timing, display_ | 2.68 | 3.61 | 14.64 | 36.73 | 55.84 | 32.18 | 65.16 | 99.91 | 115.83 |
| [26d9c959d](https://github.com/AFK-surf/monoid/commit/26d9c959d48a61322a07f498827fadf8e79dce30) perf(mbui): isolate stacked glass cache, add GLES  | 2.68 | 3.61 | 14.64 | 36.73 | 55.84 | 32.18 | 65.16 | 99.91 | 115.83 |
| [2fc81fb16](https://github.com/AFK-surf/monoid/commit/2fc81fb1640e8b949325cdfed0f11732a9f51005) feat(mbui): show the source of a Markdown file in  | 2.68 | 3.61 | 14.64 | 36.73 | 55.84 | 32.18 | 65.16 | 99.91 | 115.83 |
| [2baeae5ef](https://github.com/AFK-surf/monoid/commit/2baeae5efc0f19f71244214ce86fefbe58277dc4) feat(sf-ui): put the window keys in one tinted liq | 2.68 | 3.6 | 14.62 | 36.72 | 55.82 | 32.17 | 65.16 | 99.83 | 123.62 |
| [18c2f2077](https://github.com/AFK-surf/monoid/commit/18c2f207752b73d637d47017bc21cf77ab9cacf9) feat(app): put the shortcuts' search above their l | 2.67 | 3.6 | 14.6 | 36.7 | 55.79 | 32.15 | 65.11 | 100.19 | 123.43 |
| [a2e9941cc](https://github.com/AFK-surf/monoid/commit/a2e9941cc2cbce8ff638ef7879cd000e90c269a2) feat(mbui): add macOS and Windows crash and main-t | 2.67 | 3.6 | 14.6 | 36.7 | 55.79 | 32.15 | 65.11 | 100.19 | 123.43 |
| [75c7a178d](https://github.com/AFK-surf/monoid/commit/75c7a178d517259070eca12361d6b1ce6b63fc64) perf(mbui): optimize adaptive liquid glass GPU ren | 2.67 | 3.6 | 14.6 | 36.7 | 55.79 | 32.15 | 65.11 | 100.19 | 123.43 |
| [f7978a96d](https://github.com/AFK-surf/monoid/commit/f7978a96df78ae0c98b939f5952b478314e9fb0b) fix(test): build the delta C harness without PIE o | 2.67 | 3.6 | 14.59 | 36.69 | 55.74 | 32.14 | 65.08 | 98.93 | 120.95 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [1953aa4af](https://github.com/AFK-surf/monoid/commit/1953aa4af5ba6cc481dcf18bf8070ece6c628bd5) fix(notice): fix profile push routing, notice.brin | 0.48 | 0.63 | 2.43 | 3.48 | 5.77 | 1.78 | 4.8 | 54.58 |
| [8b62854f0](https://github.com/AFK-surf/monoid/commit/8b62854f03592bd74c4e3427f2eae920b434a8c5) feat(mbui): replace legacy frosted bars with liqui | 0.48 | 0.63 | 2.43 | 3.48 | 5.77 | 1.78 | 4.8 | 54.58 |
| [3e01fcab0](https://github.com/AFK-surf/monoid/commit/3e01fcab0066b6975b928daf9c03abc4f0fb1dba) feat(lg,sf-ui,mbui): port iOS 27.0 LiquidMorphPhys | 0.48 | 0.63 | 2.43 | 3.48 | 5.77 | 1.78 | 4.8 | 54.58 |
| [e9f48df90](https://github.com/AFK-surf/monoid/commit/e9f48df90aca90a16004e26ef91eaf6cff6c00ec) fix(mbui): shorten the app update row (#8165) | 0.48 | 0.63 | 2.42 | 3.48 | 5.74 | 1.77 | 4.77 | 55.71 |
| [61314116d](https://github.com/AFK-surf/monoid/commit/61314116db05d116bc27f23a8809c99948a4f49e) fix(station): catch mid-session MCP loss and backo | 0.48 | 0.63 | 2.42 | 3.48 | 5.74 | 1.77 | 4.77 | 55.71 |
| [8b659b96c](https://github.com/AFK-surf/monoid/commit/8b659b96c7cd9a7b67ef429649ac6557ea1b7f19) perf(mbui): add Windows D3D11 GPU timing, display_ | 0.48 | 0.63 | 2.42 | 3.48 | 5.74 | 1.77 | 4.77 | 55.71 |
| [26d9c959d](https://github.com/AFK-surf/monoid/commit/26d9c959d48a61322a07f498827fadf8e79dce30) perf(mbui): isolate stacked glass cache, add GLES  | 0.48 | 0.63 | 2.42 | 3.48 | 5.73 | 1.77 | 4.77 | 55.69 |
| [2fc81fb16](https://github.com/AFK-surf/monoid/commit/2fc81fb1640e8b949325cdfed0f11732a9f51005) feat(mbui): show the source of a Markdown file in  | 0.48 | 0.63 | 2.41 | 3.47 | 5.72 | 1.76 | 4.77 | 55.59 |
| [2baeae5ef](https://github.com/AFK-surf/monoid/commit/2baeae5efc0f19f71244214ce86fefbe58277dc4) feat(sf-ui): put the window keys in one tinted liq | 0.48 | 0.63 | 2.41 | 3.47 | 5.72 | 1.76 | 4.77 | 55.59 |
| [18c2f2077](https://github.com/AFK-surf/monoid/commit/18c2f207752b73d637d47017bc21cf77ab9cacf9) feat(app): put the shortcuts' search above their l | 0.48 | 0.63 | 2.41 | 3.47 | 5.72 | 1.76 | 4.77 | 55.59 |
| [a2e9941cc](https://github.com/AFK-surf/monoid/commit/a2e9941cc2cbce8ff638ef7879cd000e90c269a2) feat(mbui): add macOS and Windows crash and main-t | 0.47 | 0.62 | 2.4 | 3.45 | 5.69 | 1.75 | 4.73 | 55.25 |
| [75c7a178d](https://github.com/AFK-surf/monoid/commit/75c7a178d517259070eca12361d6b1ce6b63fc64) perf(mbui): optimize adaptive liquid glass GPU ren | 0.47 | 0.62 | 2.4 | 3.45 | 5.69 | 1.75 | 4.73 | 55.38 |
| [f7978a96d](https://github.com/AFK-surf/monoid/commit/f7978a96df78ae0c98b939f5952b478314e9fb0b) fix(test): build the delta C harness without PIE o | 0.47 | 0.62 | 2.4 | 3.45 | 5.69 | 1.75 | 4.73 | 54.59 |
