# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [368e6e956](https://github.com/AFK-surf/monoid/commit/368e6e9564f3cf43dfd48623662ba5dfd8b67621) fix(ci): bound gh release upload with 90s timeout  | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [83de34c52](https://github.com/AFK-surf/monoid/commit/83de34c526cbe574b9f9a287457a8d588ed5c0aa) fix(ci): skip cached natives and reader-harness in | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [225e4d51a](https://github.com/AFK-surf/monoid/commit/225e4d51add15266b761e500d468ec9b74fa09fe) feat(screen): redo cross-OS remote keyboard and sh | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [c757b11f8](https://github.com/AFK-surf/monoid/commit/c757b11f876dbc22c748fea9fdd559605f3a9a4c) fix(ui): keep dragged thumbs and pictures under th | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [6df8ba486](https://github.com/AFK-surf/monoid/commit/6df8ba4862d216fe89c8eb929ee413c7d6df6e23) fix(mbui): put a station's state dot after its wor | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [b9c8a4280](https://github.com/AFK-surf/monoid/commit/b9c8a42804079619d16d10671845e4ff67eb8d5f) fix(station): let backups give way by the delay th | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [bd99b367c](https://github.com/AFK-surf/monoid/commit/bd99b367c777a9ec85411246d786b09c789baaca) fix(cloud): retry a failed release read once and a | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [5c67aea1c](https://github.com/AFK-surf/monoid/commit/5c67aea1ce6cca79985064a48a603c1e78cb4d14) fix(core): ask the station links first after up to | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [9cafa2118](https://github.com/AFK-surf/monoid/commit/9cafa21182dec33db8873e52342b018f489183b3) fix(mesh,android): enable hot-relay narrowing on n | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [610cee155](https://github.com/AFK-surf/monoid/commit/610cee1555f582e1d16d891ce75b331c78d7a780) fix(ci): allow 60s for active native-handoff GET c | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [c20658d4d](https://github.com/AFK-surf/monoid/commit/c20658d4d60f5f0d26b93b4725be5c945cff29fd) fix(mbui): fly every shared node let go of in one  | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [7c26d51ae](https://github.com/AFK-surf/monoid/commit/7c26d51ae6493bf54b87c3aff8e37f5f1f3ad581) feat(station): give a Copilot profile its own MCP  | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 100.91 | 130.09 |
| [8b93600fa](https://github.com/AFK-surf/monoid/commit/8b93600faad698f59b2ff7b07f4d7ea23dc1aa7c) fix(ci): escalate direct routeMs and clear preferr | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 100.91 | 130.09 |
| [21933f8e1](https://github.com/AFK-surf/monoid/commit/21933f8e185bb3769e2009b15c3caf2296f1ce31) fix(ci): keep ci-1 and macos-ci checkouts non-shal | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 100.91 | 130.09 |
| [33c7dde0b](https://github.com/AFK-surf/monoid/commit/33c7dde0bb128d3a3011bd08bd1dc012ec11ba0b) test(station): fix FIFO P11 cancel barrier race in | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 100.91 | 130.09 |
| [aae87e673](https://github.com/AFK-surf/monoid/commit/aae87e673631ee390916146d6abe89d45d875865) fix(core): read a relay's access URL again once it | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 100.91 | 130.09 |
| [f226b15f0](https://github.com/AFK-surf/monoid/commit/f226b15f06ed2f0a21eaf02eae763957fdd626b6) fix(ui): keep macOS IME marked range and selection | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.15 | 65.02 | 101.14 | 127.63 |
| [d91e984dc](https://github.com/AFK-surf/monoid/commit/d91e984dc7dd4bfb53d73c249f11f9aa3f0af4ff) fix(screens,mbui): paste passwords into locked mac | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.15 | 65.02 | 101.01 | 127.07 |
| [78bab562b](https://github.com/AFK-surf/monoid/commit/78bab562b613233890dc735bc11f6a7e7d5521f8) fix(station): stop relay probes from recovering a  | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.15 | 65.02 | 101.01 | 127.07 |
| [95367d01d](https://github.com/AFK-surf/monoid/commit/95367d01d6d1c86ddce0fbc15cc0fac82deb1292) feat(core,station): add carried /preset-projects,  | 2.54 | 3.44 | 14.21 | 36.81 | 55.6 | 32.15 | 65 | 100.73 | 130.67 |
| [3c721caa7](https://github.com/AFK-surf/monoid/commit/3c721caa78fac2cd3fe647d833878c1c16895b6d) feat(station,app): set the backup upload limit in  | 2.54 | 3.44 | 14.21 | 36.77 | 55.6 | 32.12 | 65 | 100.75 | 129.12 |
| [9b4644fec](https://github.com/AFK-surf/monoid/commit/9b4644fec99fec4d2fe14c41cd42420405580047) perf(mbui): move desktop URL and file launches off | 2.54 | 3.44 | 14.21 | 36.77 | 55.6 | 32.12 | 65 | 100.75 | 129.12 |
| [1a4f2bb4f](https://github.com/AFK-surf/monoid/commit/1a4f2bb4fff0c4a60902d952dd0c4ba1601ec59c) fix(station): take the archive-marks busy test's l | 2.54 | 3.44 | 14.21 | 36.77 | 55.6 | 32.12 | 65 | 100.75 | 129.12 |
| [2e7d48690](https://github.com/AFK-surf/monoid/commit/2e7d48690f586d1d7269d0d3b516609e8b6a7e90) fix(station): start the station's Chrome and Farvi | 2.54 | 3.44 | 14.21 | 36.77 | 55.6 | 32.12 | 65 | 100.75 | 129.12 |
| [d5c6e59eb](https://github.com/AFK-surf/monoid/commit/d5c6e59eb42b8fccb1a678eeb11495a381d1a4aa) feat(ui): calibrate iOS 27.0 Liquid Glass v8 (roun | 2.54 | 3.44 | 14.21 | 36.77 | 55.6 | 32.12 | 65 | 100.75 | 129.12 |
| [010a71e28](https://github.com/AFK-surf/monoid/commit/010a71e280b8fbc0f7fc2c49c9fe51691282808e) fix(ci): run deltas-station and deltas-desktop-win | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.94 | 121.84 |
| [1d40febe4](https://github.com/AFK-surf/monoid/commit/1d40febe4eeb4b726223d5219d2228bb591df388) feat(pion-station): port reader_serve (--serve) wi | 2.54 | 3.44 | 14.21 | 36.76 | 55.6 | 32.11 | 65 | 100.94 | 121.84 |
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

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [368e6e956](https://github.com/AFK-surf/monoid/commit/368e6e9564f3cf43dfd48623662ba5dfd8b67621) fix(ci): bound gh release upload with 90s timeout  | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57 |
| [83de34c52](https://github.com/AFK-surf/monoid/commit/83de34c526cbe574b9f9a287457a8d588ed5c0aa) fix(ci): skip cached natives and reader-harness in | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.16 |
| [225e4d51a](https://github.com/AFK-surf/monoid/commit/225e4d51add15266b761e500d468ec9b74fa09fe) feat(screen): redo cross-OS remote keyboard and sh | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.3 |
| [c757b11f8](https://github.com/AFK-surf/monoid/commit/c757b11f876dbc22c748fea9fdd559605f3a9a4c) fix(ui): keep dragged thumbs and pictures under th | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.31 |
| [6df8ba486](https://github.com/AFK-surf/monoid/commit/6df8ba4862d216fe89c8eb929ee413c7d6df6e23) fix(mbui): put a station's state dot after its wor | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.44 |
| [b9c8a4280](https://github.com/AFK-surf/monoid/commit/b9c8a42804079619d16d10671845e4ff67eb8d5f) fix(station): let backups give way by the delay th | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.51 |
| [bd99b367c](https://github.com/AFK-surf/monoid/commit/bd99b367c777a9ec85411246d786b09c789baaca) fix(cloud): retry a failed release read once and a | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57 |
| [5c67aea1c](https://github.com/AFK-surf/monoid/commit/5c67aea1ce6cca79985064a48a603c1e78cb4d14) fix(core): ask the station links first after up to | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.2 |
| [9cafa2118](https://github.com/AFK-surf/monoid/commit/9cafa21182dec33db8873e52342b018f489183b3) fix(mesh,android): enable hot-relay narrowing on n | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.2 |
| [610cee155](https://github.com/AFK-surf/monoid/commit/610cee1555f582e1d16d891ce75b331c78d7a780) fix(ci): allow 60s for active native-handoff GET c | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.46 |
| [c20658d4d](https://github.com/AFK-surf/monoid/commit/c20658d4d60f5f0d26b93b4725be5c945cff29fd) fix(mbui): fly every shared node let go of in one  | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.13 |
| [7c26d51ae](https://github.com/AFK-surf/monoid/commit/7c26d51ae6493bf54b87c3aff8e37f5f1f3ad581) feat(station): give a Copilot profile its own MCP  | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.28 |
| [8b93600fa](https://github.com/AFK-surf/monoid/commit/8b93600faad698f59b2ff7b07f4d7ea23dc1aa7c) fix(ci): escalate direct routeMs and clear preferr | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.35 |
| [21933f8e1](https://github.com/AFK-surf/monoid/commit/21933f8e185bb3769e2009b15c3caf2296f1ce31) fix(ci): keep ci-1 and macos-ci checkouts non-shal | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.43 |
| [33c7dde0b](https://github.com/AFK-surf/monoid/commit/33c7dde0bb128d3a3011bd08bd1dc012ec11ba0b) test(station): fix FIFO P11 cancel barrier race in | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.31 |
| [aae87e673](https://github.com/AFK-surf/monoid/commit/aae87e673631ee390916146d6abe89d45d875865) fix(core): read a relay's access URL again once it | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.03 |
| [f226b15f0](https://github.com/AFK-surf/monoid/commit/f226b15f06ed2f0a21eaf02eae763957fdd626b6) fix(ui): keep macOS IME marked range and selection | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.12 |
| [d91e984dc](https://github.com/AFK-surf/monoid/commit/d91e984dc7dd4bfb53d73c249f11f9aa3f0af4ff) fix(screens,mbui): paste passwords into locked mac | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.3 |
| [78bab562b](https://github.com/AFK-surf/monoid/commit/78bab562b613233890dc735bc11f6a7e7d5521f8) fix(station): stop relay probes from recovering a  | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.33 |
| [95367d01d](https://github.com/AFK-surf/monoid/commit/95367d01d6d1c86ddce0fbc15cc0fac82deb1292) feat(core,station): add carried /preset-projects,  | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.39 |
| [3c721caa7](https://github.com/AFK-surf/monoid/commit/3c721caa78fac2cd3fe647d833878c1c16895b6d) feat(station,app): set the backup upload limit in  | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.3 |
| [9b4644fec](https://github.com/AFK-surf/monoid/commit/9b4644fec99fec4d2fe14c41cd42420405580047) perf(mbui): move desktop URL and file launches off | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.25 |
| [1a4f2bb4f](https://github.com/AFK-surf/monoid/commit/1a4f2bb4fff0c4a60902d952dd0c4ba1601ec59c) fix(station): take the archive-marks busy test's l | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.64 |
| [2e7d48690](https://github.com/AFK-surf/monoid/commit/2e7d48690f586d1d7269d0d3b516609e8b6a7e90) fix(station): start the station's Chrome and Farvi | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.36 |
| [d5c6e59eb](https://github.com/AFK-surf/monoid/commit/d5c6e59eb42b8fccb1a678eeb11495a381d1a4aa) feat(ui): calibrate iOS 27.0 Liquid Glass v8 (roun | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.41 |
| [010a71e28](https://github.com/AFK-surf/monoid/commit/010a71e280b8fbc0f7fc2c49c9fe51691282808e) fix(ci): run deltas-station and deltas-desktop-win | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.18 |
| [1d40febe4](https://github.com/AFK-surf/monoid/commit/1d40febe4eeb4b726223d5219d2228bb591df388) feat(pion-station): port reader_serve (--serve) wi | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.96 | 57.02 |
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
