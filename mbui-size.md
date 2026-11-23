# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [15e4bd88f](https://github.com/AFK-surf/monoid/commit/15e4bd88f4e1d5d313e9187ee46950e1f1e6dfad) refactor(ui): merge libs/mbui and libs/sf-ui into  | 2.71 | 3.66 | 14.82 | 36.95 | 56.48 | 32.38 | 65.69 | 100.27 | 120.76 |
| [1f8abdffe](https://github.com/AFK-surf/monoid/commit/1f8abdffeaa46dc430ba0d87683d3809ebb4d56d) feat(station): add OTLP business trace spans acros | 2.71 | 3.66 | 14.82 | 36.95 | 56.48 | 32.38 | 65.69 | 100.24 | 121.17 |
| [15e4bd88f](https://github.com/AFK-surf/monoid/commit/15e4bd88f4e1d5d313e9187ee46950e1f1e6dfad) refactor(ui): merge libs/mbui and libs/sf-ui into  | 2.71 | 3.66 | 14.82 | 36.95 | 56.48 | 32.38 | 65.71 | 100.07 | 123.65 |
| [2e080a421](https://github.com/AFK-surf/monoid/commit/2e080a421b8050968fdabe36bb82370f22840c2f) fix(mbui): invert adaptive glass ink locally over  | 2.72 | 3.66 | 14.83 | 36.95 | 56.5 | 32.38 | 65.71 | 100.07 | 121.9 |
| [2346b90bb](https://github.com/AFK-surf/monoid/commit/2346b90bb670992e634f127e736f30c02e116cc0) feat(cloud): trace cron tasks, slow, rate-limited  | 2.72 | 3.66 | 14.83 | 36.95 | 56.5 | 32.38 | 65.71 | 99.68 | 109.58 |
| [cbb992816](https://github.com/AFK-surf/monoid/commit/cbb9928169cca710826d0540c72d1112b5eed0de) perf(mbui): lazy-compile pruned GLES shaders and f | 2.72 | 3.66 | 14.83 | 36.95 | 56.5 | 32.38 | 65.71 | 99.68 | 109.58 |
| [bc2520fb4](https://github.com/AFK-surf/monoid/commit/bc2520fb4e4851f33a4130b42ab2c773a2f0f316) feat(sf-ui,mbui): upgrade remote screen/terminal f | 2.72 | 3.66 | 14.83 | 36.96 | 56.5 | 32.38 | 65.71 | 99.55 | 124.51 |
| [769720911](https://github.com/AFK-surf/monoid/commit/76972091188326e83c3391d3e92ec7f71b97a51e) feat(sf-ui,mbui): adopt liquid glass on dialogs, m | 2.72 | 3.66 | 14.83 | 36.96 | 56.5 | 32.38 | 65.71 | 99.6 | 123.22 |
| [3d846babe](https://github.com/AFK-surf/monoid/commit/3d846babecb0760781dc2021dea320eee0a4d78c) fix(sf-ui,mbui): keep Small-screen panels as botto | 2.72 | 3.66 | 14.83 | 36.96 | 56.5 | 32.38 | 65.71 | 99.58 | 121.83 |
| [67422c4f0](https://github.com/AFK-surf/monoid/commit/67422c4f02d6ea87761e22f360c3ea8cfd4a8cda) fix(station): count a timed-out warm as a failed s | 2.72 | 3.66 | 14.83 | 36.96 | 56.5 | 32.38 | 65.71 | 99.53 | 126.63 |
| [62d0ee807](https://github.com/AFK-surf/monoid/commit/62d0ee80739d6256b3cabb8aee4c3cd1c6a2c2b0) fix(station): handle ENOENT races during replica l | 2.72 | 3.66 | 14.83 | 36.96 | 56.5 | 32.38 | 65.71 | 99.53 | 126.63 |
| [cfe9b1739](https://github.com/AFK-surf/monoid/commit/cfe9b17397e8a6986472d8b28e361497c06a94e1) fix(ci): refresh station-slice.sh weights and sort | 2.72 | 3.66 | 14.83 | 36.96 | 56.5 | 32.38 | 65.71 | 99.53 | 126.63 |
| [90b2506a3](https://github.com/AFK-surf/monoid/commit/90b2506a3adf95a64f48056797df9058cf4a2166) feat(core,station): follow only open chats' live e | 2.72 | 3.66 | 14.83 | 36.96 | 56.5 | 32.38 | 65.71 | 99.53 | 126.63 |
| [ad2fcd4e1](https://github.com/AFK-surf/monoid/commit/ad2fcd4e12a21f8631a7517709682220b1683971) fix(ci): prewarm monoid core.hbc and overlap setup | 2.72 | 3.66 | 14.83 | 36.95 | 56.5 | 32.37 | 65.71 | 99.8 | 126.71 |
| [3dee04890](https://github.com/AFK-surf/monoid/commit/3dee04890ccda08bb2bbfff06b9049b3c4e0afec) feat(station,app): show where a station's traffic  | 2.72 | 3.66 | 14.83 | 36.95 | 56.5 | 32.37 | 65.71 | 99.8 | 126.71 |
| [17fb8f5be](https://github.com/AFK-surf/monoid/commit/17fb8f5be8a5dc2c0eb0595624256bb7e15e4016) fix(mbui): skip pointer-off Tree::at withins layou | 2.71 | 3.66 | 14.83 | 36.94 | 56.49 | 32.37 | 65.71 | 99.58 | 123.17 |
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

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [15e4bd88f](https://github.com/AFK-surf/monoid/commit/15e4bd88f4e1d5d313e9187ee46950e1f1e6dfad) refactor(ui): merge libs/mbui and libs/sf-ui into  | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.79 | 4.82 | 55.08 |
| [1f8abdffe](https://github.com/AFK-surf/monoid/commit/1f8abdffeaa46dc430ba0d87683d3809ebb4d56d) feat(station): add OTLP business trace spans acros | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.79 | 4.82 | 55.26 |
| [15e4bd88f](https://github.com/AFK-surf/monoid/commit/15e4bd88f4e1d5d313e9187ee46950e1f1e6dfad) refactor(ui): merge libs/mbui and libs/sf-ui into  | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.79 | 4.82 | 55.02 |
| [2e080a421](https://github.com/AFK-surf/monoid/commit/2e080a421b8050968fdabe36bb82370f22840c2f) fix(mbui): invert adaptive glass ink locally over  | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.83 | 55.22 |
| [2346b90bb](https://github.com/AFK-surf/monoid/commit/2346b90bb670992e634f127e736f30c02e116cc0) feat(cloud): trace cron tasks, slow, rate-limited  | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.67 |
| [cbb992816](https://github.com/AFK-surf/monoid/commit/cbb9928169cca710826d0540c72d1112b5eed0de) perf(mbui): lazy-compile pruned GLES shaders and f | 0.48 | 0.63 | 2.44 | 3.49 | 5.8 | 1.78 | 4.82 | 54.38 |
| [bc2520fb4](https://github.com/AFK-surf/monoid/commit/bc2520fb4e4851f33a4130b42ab2c773a2f0f316) feat(sf-ui,mbui): upgrade remote screen/terminal f | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.49 |
| [769720911](https://github.com/AFK-surf/monoid/commit/76972091188326e83c3391d3e92ec7f71b97a51e) feat(sf-ui,mbui): adopt liquid glass on dialogs, m | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.61 |
| [3d846babe](https://github.com/AFK-surf/monoid/commit/3d846babecb0760781dc2021dea320eee0a4d78c) fix(sf-ui,mbui): keep Small-screen panels as botto | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.63 |
| [67422c4f0](https://github.com/AFK-surf/monoid/commit/67422c4f02d6ea87761e22f360c3ea8cfd4a8cda) fix(station): count a timed-out warm as a failed s | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.72 |
| [62d0ee807](https://github.com/AFK-surf/monoid/commit/62d0ee80739d6256b3cabb8aee4c3cd1c6a2c2b0) fix(station): handle ENOENT races during replica l | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.41 |
| [cfe9b1739](https://github.com/AFK-surf/monoid/commit/cfe9b17397e8a6986472d8b28e361497c06a94e1) fix(ci): refresh station-slice.sh weights and sort | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.72 |
| [90b2506a3](https://github.com/AFK-surf/monoid/commit/90b2506a3adf95a64f48056797df9058cf4a2166) feat(core,station): follow only open chats' live e | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 55.15 |
| [ad2fcd4e1](https://github.com/AFK-surf/monoid/commit/ad2fcd4e12a21f8631a7517709682220b1683971) fix(ci): prewarm monoid core.hbc and overlap setup | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.9 |
| [3dee04890](https://github.com/AFK-surf/monoid/commit/3dee04890ccda08bb2bbfff06b9049b3c4e0afec) feat(station,app): show where a station's traffic  | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.95 |
| [17fb8f5be](https://github.com/AFK-surf/monoid/commit/17fb8f5be8a5dc2c0eb0595624256bb7e15e4016) fix(mbui): skip pointer-off Tree::at withins layou | 0.48 | 0.63 | 2.44 | 3.5 | 5.8 | 1.78 | 4.82 | 54.56 |
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
