# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [23c599a29](https://github.com/AFK-surf/monoid/commit/23c599a293d3ef84bd3c3a34f272d1dbfd2a4606) fix(mesh): filter benchmarking IPs from lookup and | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.03 | 103.88 | 134.72 |
| [9c79d355d](https://github.com/AFK-surf/monoid/commit/9c79d355d73ecce1dbbef8d649c8aaaa4700430b) chore(mbui): replace 5 cross-pkg iter().any/search | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 104.06 | 138.98 |
| [b1ff26ba8](https://github.com/AFK-surf/monoid/commit/b1ff26ba84e7b3c2b2f8922a7d0d9949062d2af8) ci(station): eliminate SQLite fsync storms in 13 t | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 103.89 | 133.3 |
| [527dadfe2](https://github.com/AFK-surf/monoid/commit/527dadfe2b7f452c3f6cd04c4a8891ebb3362ada) refactor(ui): drop defer and inferred closure type | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 103.89 | 133.3 |
| [eb8640e16](https://github.com/AFK-surf/monoid/commit/eb8640e1621fb1bf208ce0da5bea70ed05b8bc9f) feat(station): wire Wave 17C-3A ReadOps, CRDT reco | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 103.86 | 134.86 |
| [439eb89e1](https://github.com/AFK-surf/monoid/commit/439eb89e193662fcccc755821cc07dff97273fef) feat(station-pion): wire Wave 17C-3B admin setting | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 103.86 | 134.86 |
| [9c220ed9b](https://github.com/AFK-surf/monoid/commit/9c220ed9b2b5fb4b3120d15b67fdbd95a221dc6f) refactor(ui): name kit and controls keys and types | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 103.86 | 134.86 |
| [365cbebe5](https://github.com/AFK-surf/monoid/commit/365cbebe507252b8cafce8b2579221bb8e9332fe) perf(ui): cache iOS 27 prominent-tab overflow chec | 2.74 | 3.71 | 15.38 | 38.49 | 59.49 | 33.74 | 69.01 | 103.6 | 128.41 |
| [4ac7045e1](https://github.com/AFK-surf/monoid/commit/4ac7045e15b94f8570e1a881c394919358e71de1) fix(ci): skip remote release and store probes in c | 2.74 | 3.71 | 15.38 | 38.49 | 59.49 | 33.74 | 69.01 | 103.47 | 125.35 |
| [5d4555094](https://github.com/AFK-surf/monoid/commit/5d455509408ddd187d8cfc85d0be971565a07702) refactor(ui): spell out ambiguous constructors and | 2.74 | 3.71 | 15.38 | 38.49 | 59.49 | 33.74 | 69.01 | 103.53 | 135.34 |
| [3c16fe69f](https://github.com/AFK-surf/monoid/commit/3c16fe69fe9da64cded849b724ae6717161a0d43) fix(ui,mbui): add dock_first sheet hint and omit s | 2.74 | 3.71 | 15.38 | 38.49 | 59.49 | 33.74 | 69.01 | 103.76 | 137.03 |
| [fea98115c](https://github.com/AFK-surf/monoid/commit/fea98115ca6fd391e7b69bc53bfdf1c68077e029) feat(station): fetch platform attachments on deman | 2.74 | 3.71 | 15.38 | 38.49 | 59.49 | 33.74 | 69.01 | 103.89 | 120.7 |
| [541965cbc](https://github.com/AFK-surf/monoid/commit/541965cbc2e72f42e091e9b56234d811355cbc64) feat(pion-station): wire production HTTP API ops,  | 2.74 | 3.71 | 15.38 | 38.49 | 59.49 | 33.74 | 69.01 | 103.89 | 120.7 |
| [e0ccfd141](https://github.com/AFK-surf/monoid/commit/e0ccfd1416b509ba58bb2e5ee9fd41263146be46) perf(core): batch opened sub-chat lookups in chat  | 2.74 | 3.71 | 15.38 | 38.49 | 59.49 | 33.74 | 69.01 | 103.89 | 120.7 |
| [8fa48d56b](https://github.com/AFK-surf/monoid/commit/8fa48d56b62d2b727cfa67c5ce85239bbbc415d2) feat(station): add CoW worktree command, clone pri | 2.74 | 3.71 | 15.38 | 38.48 | 59.49 | 33.74 | 69.01 | 103.76 | 127.04 |
| [84182f16d](https://github.com/AFK-surf/monoid/commit/84182f16d5ef5d6bd20e5f7d29b874c4a87427a9) fix(ci): parse Node-Station-Only trailers in GitHu | 2.74 | 3.71 | 15.38 | 38.48 | 59.49 | 33.74 | 69.01 | 103.76 | 127.04 |
| [0887a2f25](https://github.com/AFK-surf/monoid/commit/0887a2f25da434e8ebb4273626be14e3f8e180d4) fix(ui,mbui): dock tall auto-height phone sheets f | 2.74 | 3.71 | 15.38 | 38.48 | 59.49 | 33.74 | 69.01 | 103.56 | 127.37 |
| [bff3776c0](https://github.com/AFK-surf/monoid/commit/bff3776c07fe17c788bc520301ea165eae8444a5) fix(station): stop ambiguous connect.event timeout | 2.74 | 3.7 | 15.37 | 38.48 | 59.48 | 33.74 | 69 | 103.68 | 136.41 |
| [d23b63109](https://github.com/AFK-surf/monoid/commit/d23b6310954fb5b08211962bf80afe84d5811956) fix(ui): fixed short dialog titles, concentric ver | 2.74 | 3.7 | 15.37 | 38.48 | 59.48 | 33.74 | 69 | 103.68 | 136.41 |
| [caa0645c9](https://github.com/AFK-surf/monoid/commit/caa0645c917ba4038b8555f390aa77bc970256e1) fix(ci,station): split station-pion side suite, us | 2.73 | 3.7 | 15.36 | 38.46 | 59.4 | 33.71 | 68.93 | 103.71 | 131.96 |
| [dd7569046](https://github.com/AFK-surf/monoid/commit/dd7569046e59c718ad3345d0ab4e3f1045ab2cdb) fix(station-main): remove duplicate device field i | 2.73 | 3.7 | 15.36 | 38.46 | 59.4 | 33.71 | 68.93 | 103.71 | 131.96 |
| [92adfc092](https://github.com/AFK-surf/monoid/commit/92adfc0923f8c0029db715aa65207bd284b72fcc) fix(station-main): set device: None in whole_daemo | 2.73 | 3.7 | 15.36 | 38.46 | 59.4 | 33.71 | 68.93 | 103.66 | 131.94 |
| [f87f8fa6a](https://github.com/AFK-surf/monoid/commit/f87f8fa6ad6b113ea82de4576ff521f6326eadce) fix(screens,core,mbui): prevent false duplicate vi | 2.73 | 3.7 | 15.36 | 38.46 | 59.4 | 33.71 | 68.93 | 103.73 | 131.94 |
| [b2d40a09f](https://github.com/AFK-surf/monoid/commit/b2d40a09f7b4bb380b9645e63756b38076953db7) feat(pion-station): port vault discovery/asks, saf | 2.73 | 3.7 | 15.36 | 38.46 | 59.4 | 33.71 | 68.93 | 103.73 | 131.94 |
| [7861b1124](https://github.com/AFK-surf/monoid/commit/7861b112483ad1ffe8119a07e32ab3670d9fa75e) feat(pion/client-core): add AuthCapability, WireOu | 2.73 | 3.7 | 15.36 | 38.46 | 59.4 | 33.71 | 68.93 | 103.73 | 131.94 |
| [487d6f517](https://github.com/AFK-surf/monoid/commit/487d6f5174104f7ce3174ec71e3bea12f0531996) feat(station-main): catch up 22 Node commits for o | 2.73 | 3.7 | 15.36 | 38.46 | 59.4 | 33.71 | 68.93 | 103.73 | 131.94 |
| [9f8ee9e1b](https://github.com/AFK-surf/monoid/commit/9f8ee9e1b0cc0680164851296dc809f48c377dd2) feat(station-devices): complete native AirPlay and | 2.73 | 3.7 | 15.35 | 38.48 | 59.45 | 33.72 | 68.98 | 104.04 | 108.14 |
| [b44646346](https://github.com/AFK-surf/monoid/commit/b446463460865f387224e063ceb812b5ce23f69a) fix(station): preserve switched runtime across in- | 2.73 | 3.7 | 15.35 | 38.48 | 59.45 | 33.72 | 68.98 | 104.04 | 108.14 |
| [da61bcfd1](https://github.com/AFK-surf/monoid/commit/da61bcfd1d96ab60ef09d9311d6ae22a8be43f46) fix(core,mbui): resync auth on pre-started native  | 2.73 | 3.7 | 15.35 | 38.48 | 59.45 | 33.72 | 68.98 | 104.04 | 108.14 |
| [f2cbbc500](https://github.com/AFK-surf/monoid/commit/f2cbbc500973e13b912a42e92a8783687714f097) fix(station): wake sessions queued by the account  | 2.73 | 3.69 | 15.34 | 38.46 | 59.4 | 33.71 | 68.95 | 103.56 | 130.28 |
| [a44f36931](https://github.com/AFK-surf/monoid/commit/a44f369315e0e88bc35a18117ba797d988008398) chore(pion-station): bump TOOLCHAIN to a030aa49 an | 2.73 | 3.69 | 15.34 | 38.46 | 59.4 | 33.71 | 68.95 | 103.56 | 130.28 |
| [3a31c8796](https://github.com/AFK-surf/monoid/commit/3a31c8796523bf1ee9d4c22cf80bfcd88c01757f) feat(mbui): scrollable share stage preview and pro | 2.73 | 3.69 | 15.34 | 38.46 | 59.4 | 33.71 | 68.95 | 103.56 | 130.28 |
| [258f2f96e](https://github.com/AFK-surf/monoid/commit/258f2f96e4cc82a91fdc578190efb53113224bb5) feat(station-main): enable roles:rig,whole cutover | 2.73 | 3.69 | 15.34 | 38.46 | 59.4 | 33.71 | 68.95 | 103.56 | 130.28 |
| [4c56e21bb](https://github.com/AFK-surf/monoid/commit/4c56e21bb0e0a81d9dbdf39a1dbdc76d1d9bd3da) chore(station): enforce pion/station-main sync gua | 2.73 | 3.69 | 15.33 | 38.46 | 59.39 | 33.7 | 68.93 | 103.4 | 139.55 |
| [7f2cea20e](https://github.com/AFK-surf/monoid/commit/7f2cea20e10288114056b9331748c6d14497f522) fix(mbui): pin sidebar layout and window position  | 2.73 | 3.69 | 15.33 | 38.46 | 59.39 | 33.7 | 68.93 | 103.4 | 139.55 |
| [e1b9f2f4c](https://github.com/AFK-surf/monoid/commit/e1b9f2f4c937fc2b9ffb19237f1f50b4d4875d9d) fix(mbui): smoothly dissolve peek drawer glass, sh | 2.73 | 3.69 | 15.33 | 38.46 | 59.39 | 33.7 | 68.93 | 103.4 | 139.55 |
| [29f114f4a](https://github.com/AFK-surf/monoid/commit/29f114f4a65049752a872e8806fbe485d5422d9c) feat(mbui): add wide keeps_left allowlist, pages_l | 2.73 | 3.69 | 15.33 | 38.46 | 59.38 | 33.68 | 68.88 | 103.68 | 129.49 |
| [0ef14d118](https://github.com/AFK-surf/monoid/commit/0ef14d1188dd4ea47d13845a074bbc6532c7ec42) fix(station): await in-flight stateDir removal acr | 2.73 | 3.69 | 15.31 | 38.44 | 59.31 | 33.68 | 68.88 | 103.68 | 134.43 |
| [ea9ed02cb](https://github.com/AFK-surf/monoid/commit/ea9ed02cb073cd8425848a6c9e62387b97015213) fix(mbui): open the model panel at its foot and ke | 2.72 | 3.68 | 15.27 | 38.39 | 59.16 | 33.64 | 68.76 | 103.47 | 133.05 |
| [1f8e7b096](https://github.com/AFK-surf/monoid/commit/1f8e7b0965b35bf1c8c48739c2a43e437c92a2d1) feat(ui,mbui): add DataTable and fixed-header wide | 2.72 | 3.68 | 15.27 | 38.39 | 59.16 | 33.63 | 68.73 | 103.7 | 131.87 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [23c599a29](https://github.com/AFK-surf/monoid/commit/23c599a293d3ef84bd3c3a34f272d1dbfd2a4606) fix(mesh): filter benchmarking IPs from lookup and | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.9 |
| [9c79d355d](https://github.com/AFK-surf/monoid/commit/9c79d355d73ecce1dbbef8d649c8aaaa4700430b) chore(mbui): replace 5 cross-pkg iter().any/search | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.67 |
| [b1ff26ba8](https://github.com/AFK-surf/monoid/commit/b1ff26ba84e7b3c2b2f8922a7d0d9949062d2af8) ci(station): eliminate SQLite fsync storms in 13 t | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.75 |
| [527dadfe2](https://github.com/AFK-surf/monoid/commit/527dadfe2b7f452c3f6cd04c4a8891ebb3362ada) refactor(ui): drop defer and inferred closure type | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.87 |
| [eb8640e16](https://github.com/AFK-surf/monoid/commit/eb8640e1621fb1bf208ce0da5bea70ed05b8bc9f) feat(station): wire Wave 17C-3A ReadOps, CRDT reco | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.84 |
| [439eb89e1](https://github.com/AFK-surf/monoid/commit/439eb89e193662fcccc755821cc07dff97273fef) feat(station-pion): wire Wave 17C-3B admin setting | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.85 |
| [9c220ed9b](https://github.com/AFK-surf/monoid/commit/9c220ed9b2b5fb4b3120d15b67fdbd95a221dc6f) refactor(ui): name kit and controls keys and types | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.69 |
| [365cbebe5](https://github.com/AFK-surf/monoid/commit/365cbebe507252b8cafce8b2579221bb8e9332fe) perf(ui): cache iOS 27 prominent-tab overflow chec | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.9 |
| [4ac7045e1](https://github.com/AFK-surf/monoid/commit/4ac7045e15b94f8570e1a881c394919358e71de1) fix(ci): skip remote release and store probes in c | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.53 |
| [5d4555094](https://github.com/AFK-surf/monoid/commit/5d455509408ddd187d8cfc85d0be971565a07702) refactor(ui): spell out ambiguous constructors and | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.79 |
| [3c16fe69f](https://github.com/AFK-surf/monoid/commit/3c16fe69fe9da64cded849b724ae6717161a0d43) fix(ui,mbui): add dock_first sheet hint and omit s | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.67 |
| [fea98115c](https://github.com/AFK-surf/monoid/commit/fea98115ca6fd391e7b69bc53bfdf1c68077e029) feat(station): fetch platform attachments on deman | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.59 |
| [541965cbc](https://github.com/AFK-surf/monoid/commit/541965cbc2e72f42e091e9b56234d811355cbc64) feat(pion-station): wire production HTTP API ops,  | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 58.03 |
| [e0ccfd141](https://github.com/AFK-surf/monoid/commit/e0ccfd1416b509ba58bb2e5ee9fd41263146be46) perf(core): batch opened sub-chat lookups in chat  | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.67 |
| [8fa48d56b](https://github.com/AFK-surf/monoid/commit/8fa48d56b62d2b727cfa67c5ce85239bbbc415d2) feat(station): add CoW worktree command, clone pri | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.67 |
| [84182f16d](https://github.com/AFK-surf/monoid/commit/84182f16d5ef5d6bd20e5f7d29b874c4a87427a9) fix(ci): parse Node-Station-Only trailers in GitHu | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.75 |
| [0887a2f25](https://github.com/AFK-surf/monoid/commit/0887a2f25da434e8ebb4273626be14e3f8e180d4) fix(ui,mbui): dock tall auto-height phone sheets f | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.53 |
| [bff3776c0](https://github.com/AFK-surf/monoid/commit/bff3776c07fe17c788bc520301ea165eae8444a5) fix(station): stop ambiguous connect.event timeout | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.61 |
| [d23b63109](https://github.com/AFK-surf/monoid/commit/d23b6310954fb5b08211962bf80afe84d5811956) fix(ui): fixed short dialog titles, concentric ver | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.85 |
| [caa0645c9](https://github.com/AFK-surf/monoid/commit/caa0645c917ba4038b8555f390aa77bc970256e1) fix(ci,station): split station-pion side suite, us | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.64 |
| [dd7569046](https://github.com/AFK-surf/monoid/commit/dd7569046e59c718ad3345d0ab4e3f1045ab2cdb) fix(station-main): remove duplicate device field i | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.64 |
| [92adfc092](https://github.com/AFK-surf/monoid/commit/92adfc0923f8c0029db715aa65207bd284b72fcc) fix(station-main): set device: None in whole_daemo | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.8 |
| [f87f8fa6a](https://github.com/AFK-surf/monoid/commit/f87f8fa6ad6b113ea82de4576ff521f6326eadce) fix(screens,core,mbui): prevent false duplicate vi | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.69 |
| [b2d40a09f](https://github.com/AFK-surf/monoid/commit/b2d40a09f7b4bb380b9645e63756b38076953db7) feat(pion-station): port vault discovery/asks, saf | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.71 |
| [7861b1124](https://github.com/AFK-surf/monoid/commit/7861b112483ad1ffe8119a07e32ab3670d9fa75e) feat(pion/client-core): add AuthCapability, WireOu | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.71 |
| [487d6f517](https://github.com/AFK-surf/monoid/commit/487d6f5174104f7ce3174ec71e3bea12f0531996) feat(station-main): catch up 22 Node commits for o | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.64 |
| [9f8ee9e1b](https://github.com/AFK-surf/monoid/commit/9f8ee9e1b0cc0680164851296dc809f48c377dd2) feat(station-devices): complete native AirPlay and | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 58.75 |
| [b44646346](https://github.com/AFK-surf/monoid/commit/b446463460865f387224e063ceb812b5ce23f69a) fix(station): preserve switched runtime across in- | 0.59 | 0.78 | 3.03 | 4.06 | 7.53 | 2.23 | 6.31 | 57.66 |
| [da61bcfd1](https://github.com/AFK-surf/monoid/commit/da61bcfd1d96ab60ef09d9311d6ae22a8be43f46) fix(core,mbui): resync auth on pre-started native  | 0.59 | 0.78 | 3.03 | 4.06 | 7.53 | 2.23 | 6.31 | 57.71 |
| [f2cbbc500](https://github.com/AFK-surf/monoid/commit/f2cbbc500973e13b912a42e92a8783687714f097) fix(station): wake sessions queued by the account  | 0.59 | 0.78 | 3.03 | 4.06 | 7.53 | 2.23 | 6.31 | 57.64 |
| [a44f36931](https://github.com/AFK-surf/monoid/commit/a44f369315e0e88bc35a18117ba797d988008398) chore(pion-station): bump TOOLCHAIN to a030aa49 an | 0.59 | 0.78 | 3.03 | 4.06 | 7.53 | 2.23 | 6.31 | 57.8 |
| [3a31c8796](https://github.com/AFK-surf/monoid/commit/3a31c8796523bf1ee9d4c22cf80bfcd88c01757f) feat(mbui): scrollable share stage preview and pro | 0.59 | 0.78 | 3.03 | 4.06 | 7.53 | 2.23 | 6.31 | 57.97 |
| [258f2f96e](https://github.com/AFK-surf/monoid/commit/258f2f96e4cc82a91fdc578190efb53113224bb5) feat(station-main): enable roles:rig,whole cutover | 0.59 | 0.78 | 3.03 | 4.06 | 7.53 | 2.23 | 6.31 | 57.69 |
| [4c56e21bb](https://github.com/AFK-surf/monoid/commit/4c56e21bb0e0a81d9dbdf39a1dbdc76d1d9bd3da) chore(station): enforce pion/station-main sync gua | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.72 |
| [7f2cea20e](https://github.com/AFK-surf/monoid/commit/7f2cea20e10288114056b9331748c6d14497f522) fix(mbui): pin sidebar layout and window position  | 0.59 | 0.78 | 3.03 | 4.06 | 7.53 | 2.23 | 6.31 | 57.79 |
| [e1b9f2f4c](https://github.com/AFK-surf/monoid/commit/e1b9f2f4c937fc2b9ffb19237f1f50b4d4875d9d) fix(mbui): smoothly dissolve peek drawer glass, sh | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.74 |
| [29f114f4a](https://github.com/AFK-surf/monoid/commit/29f114f4a65049752a872e8806fbe485d5422d9c) feat(mbui): add wide keeps_left allowlist, pages_l | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.74 |
| [0ef14d118](https://github.com/AFK-surf/monoid/commit/0ef14d1188dd4ea47d13845a074bbc6532c7ec42) fix(station): await in-flight stateDir removal acr | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.64 |
| [ea9ed02cb](https://github.com/AFK-surf/monoid/commit/ea9ed02cb073cd8425848a6c9e62387b97015213) fix(mbui): open the model panel at its foot and ke | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.56 |
| [1f8e7b096](https://github.com/AFK-surf/monoid/commit/1f8e7b0965b35bf1c8c48739c2a43e437c92a2d1) feat(ui,mbui): add DataTable and fixed-header wide | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.75 |
