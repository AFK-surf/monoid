# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [c40f9ebb2](https://github.com/AFK-surf/monoid/commit/c40f9ebb2253b462b1ae310e5079e91942f0efeb) fix(ci): offload stable Android deltas and feed to | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.94 | 64.5 | 100.91 | 121.83 |
| [34b7fe8e8](https://github.com/AFK-surf/monoid/commit/34b7fe8e851786f06a93e7502764b137123361f9) perf(replica): D72a 256-bucket transcriptManifest  | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.94 | 64.5 | 100.91 | 121.83 |
| [f8da05ca1](https://github.com/AFK-surf/monoid/commit/f8da05ca18dfab6cbf6de9e287f016f9a9813135) feat(ui): replace player sliders with thumb-free f | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.94 | 64.5 | 100.91 | 121.83 |
| [202432542](https://github.com/AFK-surf/monoid/commit/202432542292efed48867fefbf80743f29be8d6c) fix(ci): give stable the Farview deploy key again  | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [95d864545](https://github.com/AFK-surf/monoid/commit/95d8645458bd06355e97ab706ef52ce4cfd50467) feat(pion): W6-A builders_search (--builder search | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [6d1a704bb](https://github.com/AFK-surf/monoid/commit/6d1a704bbacee0040a4e2b5bf189ebfb8795ece2) docs(readme): refresh READMEs and architecture dia | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [264aa0c6c](https://github.com/AFK-surf/monoid/commit/264aa0c6cc81ef2e01a767d20039f8b8411046f5) perf(core): read a person's own lock from the devi | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [8660d4d6f](https://github.com/AFK-surf/monoid/commit/8660d4d6f8c63b55bcd94b1c14760f36d8d76c0e) feat(pion): port --builder usage-counter to Pion ( | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [cfc4a28c5](https://github.com/AFK-surf/monoid/commit/cfc4a28c5c3dc7c697a6c338ff059a0ea6bfac04) docs(releases): pin stable notes to 0.1.11220 (#85 | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [f2d09f531](https://github.com/AFK-surf/monoid/commit/f2d09f53181fc0f13ac58128f085f998925b0aea) perf(ui): fix Windows prewarm eviction race, add c | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [669ee5d70](https://github.com/AFK-surf/monoid/commit/669ee5d70e138679346606f9ce1ded16d7c3ef18) feat(stations): show a station with no mark by its | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.96 | 121.83 |
| [f959ec7ab](https://github.com/AFK-surf/monoid/commit/f959ec7ab6b37494a74a93eee9c1ac90fac526fa) fix(core-ts): show the chats a search finds before | 2.52 | 3.39 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 101.21 | 121.83 |
| [ce96d772e](https://github.com/AFK-surf/monoid/commit/ce96d772e6a0b25621062d194ab5fa39266bd657) docs(releases): 0.1.11216 stable notes (#8531) | 2.52 | 3.39 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 101.21 | 121.83 |
| [2ee61943a](https://github.com/AFK-surf/monoid/commit/2ee61943a73dd8befe837c9fbd73efa7b2400f7b) perf(station): fix O(N^2) Exporter::sources and he | 2.52 | 3.39 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 101.21 | 121.83 |
| [cec55a581](https://github.com/AFK-surf/monoid/commit/cec55a5814431a92ad98f30d8045c6058ee9ff75) perf(core): trace each step of a start and when th | 2.52 | 3.39 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 101.21 | 121.83 |
| [b3364e6c3](https://github.com/AFK-surf/monoid/commit/b3364e6c3162f69451876e18c4ee681d045e534c) fix(e2e): retry station_task start on transient ri | 2.52 | 3.39 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [491053e63](https://github.com/AFK-surf/monoid/commit/491053e63b5024c26d17b28f5aafe9819f86b70e) fix(station): rename Search.#spawnSync to #spawnLo | 2.52 | 3.39 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [703ffa70e](https://github.com/AFK-surf/monoid/commit/703ffa70ebaa461b341792f5bdb6141461613d4b) refactor(ui): replace hostapi.Host trait with clos | 2.52 | 3.39 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.98 | 121.83 |
| [bdab53e32](https://github.com/AFK-surf/monoid/commit/bdab53e32df499e4b266b389ddae0f6d02e0eed6) fix(ui): preserve 1.00x vertical text scale inside | 2.51 | 3.4 | 14.04 | 37.51 | 58.07 | 31.94 | 64.49 | 100.78 | 121.83 |
| [a9586853d](https://github.com/AFK-surf/monoid/commit/a9586853d26ebd14d56fc69a9d971acaa8f4846f) feat(pion): W6-0 Wave 6 foundation, live-locator ( | 2.51 | 3.4 | 14.04 | 37.51 | 58.07 | 31.94 | 64.49 | 100.93 | 121.83 |
| [37a5954c1](https://github.com/AFK-surf/monoid/commit/37a5954c1e707b732e109dd172c2c91f24f99016) fix(vault): stop 未获此库授权 flashing at start, and nev | 2.51 | 3.4 | 14.04 | 37.51 | 58.07 | 31.94 | 64.49 | 100.93 | 121.83 |
| [3f5a8522b](https://github.com/AFK-surf/monoid/commit/3f5a8522b7da579d43297b5a870e3c0f0e834fef) feat(mbui): report a message sent from here that a | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 31.94 | 64.5 | 100.73 | 121.83 |
| [209a0aaac](https://github.com/AFK-surf/monoid/commit/209a0aaace4722e2397bd1102b31552a445cc0ae) refactor(ui): unify check row boxes, markdown task | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 31.93 | 64.49 | 100.99 | 121.83 |
| [11f11d4c6](https://github.com/AFK-surf/monoid/commit/11f11d4c6fa182a2401c34619b9c4fcfcaacba13) feat(ui): extract liquid_slider_look primitive and | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 31.93 | 64.49 | 100.99 | 121.83 |
| [7c26737b5](https://github.com/AFK-surf/monoid/commit/7c26737b5426872b7b9547ef3c464cade377512c) fix(ci): serialize rustup toolchain and target set | 2.52 | 3.39 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.86 | 121.83 |
| [8ce75f9f7](https://github.com/AFK-surf/monoid/commit/8ce75f9f76b7d0c9972edbc7fd3ef97d037065e9) feat(ui,mbui): unify doc notes, profiles batch bar | 2.51 | 3.4 | 14.03 | 37.51 | 58.07 | 31.91 | 64.44 | 100.99 | 121.83 |
| [18e6b5ea7](https://github.com/AFK-surf/monoid/commit/18e6b5ea7597b50152a9d17d35a82daa25cccb61) perf(replica): prune agy/brain derived caches and  | 2.51 | 3.4 | 14.03 | 37.51 | 58.07 | 31.91 | 64.44 | 100.99 | 121.83 |
| [c442651d2](https://github.com/AFK-surf/monoid/commit/c442651d201bf33ac7025d379eb2d4fdc2da87b1) refactor(ui): drop Blitter and Moving trait object | 2.51 | 3.4 | 14.03 | 37.51 | 58.07 | 31.91 | 64.44 | 100.99 | 121.83 |
| [d2d0b0a9c](https://github.com/AFK-surf/monoid/commit/d2d0b0a9c5b2e41b4f7323abbe27893d7c5b7bc4) perf(ui): exact-phase glyph prewarm and Windows Di | 2.51 | 3.4 | 14.03 | 37.51 | 58.07 | 31.91 | 64.44 | 100.99 | 121.83 |
| [7c4a08f16](https://github.com/AFK-surf/monoid/commit/7c4a08f162275db019f943730d5eb8310edb82ef) refactor(ui): drop priv traits and hostapi refs fo | 2.51 | 3.4 | 14.03 | 37.51 | 58.07 | 31.91 | 64.44 | 100.99 | 121.83 |
| [0cf2e4fb3](https://github.com/AFK-surf/monoid/commit/0cf2e4fb3ceaeb12f2a57a9c2031a94abe63c9e3) fix(ci): make a push's Windows core below the app  | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 31.91 | 64.44 | 100.99 | 121.83 |
| [f18896872](https://github.com/AFK-surf/monoid/commit/f188968720696eec671ecaf65cd7a75ba879d8aa) chore(ci): remove FARVIEW_DEPLOY_KEY and farview a | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 31.91 | 64.44 | 100.99 | 121.83 |
| [80f380db8](https://github.com/AFK-surf/monoid/commit/80f380db859498e931272ee2d2c7c9352014a333) perf(screens,browser,ui): stabilize remote desktop | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 32.81 | 66.92 | 100.89 | 121.83 |
| [3a33268d0](https://github.com/AFK-surf/monoid/commit/3a33268d0aa51d46ecefdda2a74244ad0a3f3ad5) fix(ci): set STILLFAIL_DIRECT_DNS in self-hosted d | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 32.81 | 66.92 | 100.89 | 121.83 |
| [995870604](https://github.com/AFK-surf/monoid/commit/99587060490aa1c7647e52d7cfdad4393bb08aac) feat(mbui): light the picked occurrence of Poke wo | 2.8 | 3.77 | 15.26 | 37.51 | 58.07 | 32.81 | 66.92 | 100.89 | 121.83 |
| [86a3bc937](https://github.com/AFK-surf/monoid/commit/86a3bc9371100592f434e8a80672598c3368823b) fix(ci): upload ci-1's MoonBit cache from ubuntu-2 | 2.8 | 3.77 | 15.25 | 37.49 | 58.04 | 32.81 | 66.92 | 100.89 | 132.16 |
| [07d6c4d48](https://github.com/AFK-surf/monoid/commit/07d6c4d484427466d8fcbe6178d1fb4df398602e) fix(client): stop sending traces when usage report | 2.8 | 3.77 | 15.25 | 37.49 | 58.04 | 32.81 | 66.92 | 100.89 | 132.16 |
| [f768891b3](https://github.com/AFK-surf/monoid/commit/f768891b3d8346033f89f8a658e10ae49e864337) fix(station): keep Antigravity CLI profiles on fil | 2.8 | 3.77 | 15.25 | 37.49 | 58.04 | 32.81 | 66.92 | 100.89 | 132.16 |
| [6818dc010](https://github.com/AFK-surf/monoid/commit/6818dc010cb2cb2f155294a0fbe9427aad5df4ff) perf(ui): fix Android frame pacing, cross-platform | 2.8 | 3.76 | 15.25 | 37.49 | 58.04 | 32.81 | 66.92 | 100.89 | 132.16 |
| [61be50e9d](https://github.com/AFK-surf/monoid/commit/61be50e9d4645f0e1d96e747240527f41b1bca82) fix(station): make the station's memory limits fro | 2.8 | 3.76 | 15.25 | 37.49 | 58.04 | 32.81 | 66.92 | 100.89 | 132.16 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [c40f9ebb2](https://github.com/AFK-surf/monoid/commit/c40f9ebb2253b462b1ae310e5079e91942f0efeb) fix(ci): offload stable Android deltas and feed to | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 58.03 |
| [34b7fe8e8](https://github.com/AFK-surf/monoid/commit/34b7fe8e851786f06a93e7502764b137123361f9) perf(replica): D72a 256-bucket transcriptManifest  | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.21 |
| [f8da05ca1](https://github.com/AFK-surf/monoid/commit/f8da05ca18dfab6cbf6de9e287f016f9a9813135) feat(ui): replace player sliders with thumb-free f | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.54 |
| [202432542](https://github.com/AFK-surf/monoid/commit/202432542292efed48867fefbf80743f29be8d6c) fix(ci): give stable the Farview deploy key again  | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.48 |
| [95d864545](https://github.com/AFK-surf/monoid/commit/95d8645458bd06355e97ab706ef52ce4cfd50467) feat(pion): W6-A builders_search (--builder search | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.95 |
| [6d1a704bb](https://github.com/AFK-surf/monoid/commit/6d1a704bbacee0040a4e2b5bf189ebfb8795ece2) docs(readme): refresh READMEs and architecture dia | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.82 |
| [264aa0c6c](https://github.com/AFK-surf/monoid/commit/264aa0c6cc81ef2e01a767d20039f8b8411046f5) perf(core): read a person's own lock from the devi | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.53 |
| [8660d4d6f](https://github.com/AFK-surf/monoid/commit/8660d4d6f8c63b55bcd94b1c14760f36d8d76c0e) feat(pion): port --builder usage-counter to Pion ( | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.69 |
| [cfc4a28c5](https://github.com/AFK-surf/monoid/commit/cfc4a28c5c3dc7c697a6c338ff059a0ea6bfac04) docs(releases): pin stable notes to 0.1.11220 (#85 | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.51 |
| [f2d09f531](https://github.com/AFK-surf/monoid/commit/f2d09f53181fc0f13ac58128f085f998925b0aea) perf(ui): fix Windows prewarm eviction race, add c | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.74 |
| [669ee5d70](https://github.com/AFK-surf/monoid/commit/669ee5d70e138679346606f9ce1ded16d7c3ef18) feat(stations): show a station with no mark by its | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.62 |
| [f959ec7ab](https://github.com/AFK-surf/monoid/commit/f959ec7ab6b37494a74a93eee9c1ac90fac526fa) fix(core-ts): show the chats a search finds before | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.82 |
| [ce96d772e](https://github.com/AFK-surf/monoid/commit/ce96d772e6a0b25621062d194ab5fa39266bd657) docs(releases): 0.1.11216 stable notes (#8531) | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.66 |
| [2ee61943a](https://github.com/AFK-surf/monoid/commit/2ee61943a73dd8befe837c9fbd73efa7b2400f7b) perf(station): fix O(N^2) Exporter::sources and he | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.56 |
| [cec55a581](https://github.com/AFK-surf/monoid/commit/cec55a5814431a92ad98f30d8045c6058ee9ff75) perf(core): trace each step of a start and when th | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.79 |
| [b3364e6c3](https://github.com/AFK-surf/monoid/commit/b3364e6c3162f69451876e18c4ee681d045e534c) fix(e2e): retry station_task start on transient ri | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.62 |
| [491053e63](https://github.com/AFK-surf/monoid/commit/491053e63b5024c26d17b28f5aafe9819f86b70e) fix(station): rename Search.#spawnSync to #spawnLo | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.51 |
| [703ffa70e](https://github.com/AFK-surf/monoid/commit/703ffa70ebaa461b341792f5bdb6141461613d4b) refactor(ui): replace hostapi.Host trait with clos | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.59 |
| [bdab53e32](https://github.com/AFK-surf/monoid/commit/bdab53e32df499e4b266b389ddae0f6d02e0eed6) fix(ui): preserve 1.00x vertical text scale inside | 0.56 | 0.73 | 2.85 | 3.87 | 7.08 | 2.1 | 5.86 | 57.61 |
| [a9586853d](https://github.com/AFK-surf/monoid/commit/a9586853d26ebd14d56fc69a9d971acaa8f4846f) feat(pion): W6-0 Wave 6 foundation, live-locator ( | 0.56 | 0.73 | 2.85 | 3.87 | 7.08 | 2.1 | 5.86 | 58.07 |
| [37a5954c1](https://github.com/AFK-surf/monoid/commit/37a5954c1e707b732e109dd172c2c91f24f99016) fix(vault): stop 未获此库授权 flashing at start, and nev | 0.56 | 0.73 | 2.85 | 3.88 | 7.08 | 2.1 | 5.86 | 57.77 |
| [3f5a8522b](https://github.com/AFK-surf/monoid/commit/3f5a8522b7da579d43297b5a870e3c0f0e834fef) feat(mbui): report a message sent from here that a | 0.56 | 0.73 | 2.85 | 3.88 | 7.08 | 2.1 | 5.86 | 57.74 |
| [209a0aaac](https://github.com/AFK-surf/monoid/commit/209a0aaace4722e2397bd1102b31552a445cc0ae) refactor(ui): unify check row boxes, markdown task | 0.56 | 0.73 | 2.85 | 3.88 | 7.08 | 2.1 | 5.86 | 57.64 |
| [11f11d4c6](https://github.com/AFK-surf/monoid/commit/11f11d4c6fa182a2401c34619b9c4fcfcaacba13) feat(ui): extract liquid_slider_look primitive and | 0.56 | 0.73 | 2.85 | 3.88 | 7.08 | 2.1 | 5.86 | 57.64 |
| [7c26737b5](https://github.com/AFK-surf/monoid/commit/7c26737b5426872b7b9547ef3c464cade377512c) fix(ci): serialize rustup toolchain and target set | 0.56 | 0.73 | 2.85 | 3.88 | 7.08 | 2.1 | 5.86 | 57.79 |
| [8ce75f9f7](https://github.com/AFK-surf/monoid/commit/8ce75f9f76b7d0c9972edbc7fd3ef97d037065e9) feat(ui,mbui): unify doc notes, profiles batch bar | 0.56 | 0.73 | 2.85 | 3.88 | 7.08 | 2.1 | 5.86 | 57.46 |
| [18e6b5ea7](https://github.com/AFK-surf/monoid/commit/18e6b5ea7597b50152a9d17d35a82daa25cccb61) perf(replica): prune agy/brain derived caches and  | 0.56 | 0.73 | 2.85 | 3.88 | 7.08 | 2.1 | 5.86 | 57.57 |
| [c442651d2](https://github.com/AFK-surf/monoid/commit/c442651d201bf33ac7025d379eb2d4fdc2da87b1) refactor(ui): drop Blitter and Moving trait object | 0.56 | 0.73 | 2.85 | 3.88 | 7.08 | 2.1 | 5.86 | 57.36 |
| [d2d0b0a9c](https://github.com/AFK-surf/monoid/commit/d2d0b0a9c5b2e41b4f7323abbe27893d7c5b7bc4) perf(ui): exact-phase glyph prewarm and Windows Di | 0.56 | 0.73 | 2.85 | 3.88 | 7.08 | 2.1 | 5.86 | 57.33 |
| [7c4a08f16](https://github.com/AFK-surf/monoid/commit/7c4a08f162275db019f943730d5eb8310edb82ef) refactor(ui): drop priv traits and hostapi refs fo | 0.56 | 0.73 | 2.85 | 3.88 | 7.08 | 2.1 | 5.86 | 57.43 |
| [0cf2e4fb3](https://github.com/AFK-surf/monoid/commit/0cf2e4fb3ceaeb12f2a57a9c2031a94abe63c9e3) fix(ci): make a push's Windows core below the app  | 0.56 | 0.73 | 2.85 | 3.88 | 7.1 | 2.1 | 5.89 | 57.8 |
| [f18896872](https://github.com/AFK-surf/monoid/commit/f188968720696eec671ecaf65cd7a75ba879d8aa) chore(ci): remove FARVIEW_DEPLOY_KEY and farview a | 0.56 | 0.73 | 2.85 | 3.88 | 7.1 | 2.1 | 5.86 | 57.56 |
| [80f380db8](https://github.com/AFK-surf/monoid/commit/80f380db859498e931272ee2d2c7c9352014a333) perf(screens,browser,ui): stabilize remote desktop | 0.56 | 0.73 | 2.85 | 3.88 | 7.1 | 2.1 | 5.89 | 57.49 |
| [3a33268d0](https://github.com/AFK-surf/monoid/commit/3a33268d0aa51d46ecefdda2a74244ad0a3f3ad5) fix(ci): set STILLFAIL_DIRECT_DNS in self-hosted d | 0.56 | 0.73 | 2.85 | 3.88 | 7.1 | 2.1 | 5.86 | 57.46 |
| [995870604](https://github.com/AFK-surf/monoid/commit/99587060490aa1c7647e52d7cfdad4393bb08aac) feat(mbui): light the picked occurrence of Poke wo | 0.56 | 0.73 | 2.85 | 3.88 | 7.1 | 2.1 | 5.86 | 57.39 |
| [86a3bc937](https://github.com/AFK-surf/monoid/commit/86a3bc9371100592f434e8a80672598c3368823b) fix(ci): upload ci-1's MoonBit cache from ubuntu-2 | 0.56 | 0.73 | 2.85 | 3.88 | 7.1 | 2.1 | 5.86 | 57.48 |
| [07d6c4d48](https://github.com/AFK-surf/monoid/commit/07d6c4d484427466d8fcbe6178d1fb4df398602e) fix(client): stop sending traces when usage report | 0.56 | 0.73 | 2.85 | 3.88 | 7.1 | 2.1 | 5.86 | 57.38 |
| [f768891b3](https://github.com/AFK-surf/monoid/commit/f768891b3d8346033f89f8a658e10ae49e864337) fix(station): keep Antigravity CLI profiles on fil | 0.56 | 0.73 | 2.85 | 3.86 | 7.09 | 2.1 | 5.86 | 57.36 |
| [6818dc010](https://github.com/AFK-surf/monoid/commit/6818dc010cb2cb2f155294a0fbe9427aad5df4ff) perf(ui): fix Android frame pacing, cross-platform | 0.56 | 0.73 | 2.85 | 3.87 | 7.09 | 2.1 | 5.86 | 57.69 |
| [61be50e9d](https://github.com/AFK-surf/monoid/commit/61be50e9d4645f0e1d96e747240527f41b1bca82) fix(station): make the station's memory limits fro | 0.56 | 0.73 | 2.85 | 3.86 | 7.09 | 2.1 | 5.86 | 57.21 |
