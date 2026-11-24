# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [00b25b9e0](https://github.com/AFK-surf/monoid/commit/00b25b9e0b73cd1450440413390d6065ddac3272) feat(pion-station): migrate vault-uses SQLite buil | 2.8 | 3.76 | 15.25 | 37.49 | 58.04 | 32.81 | 66.92 | 100.89 | 132.16 |
| [fe220a848](https://github.com/AFK-surf/monoid/commit/fe220a8482864df7977422f47192751d9253b0a9) fix(core,station): keep waiting writes in SQLite a | 2.8 | 3.76 | 15.23 | 37.47 | 57.96 | 32.81 | 66.87 | 100.91 | 130.93 |
| [56d4ffcb5](https://github.com/AFK-surf/monoid/commit/56d4ffcb54e7c88a08ec6c8e2ce8973da252bad4) docs(releases): 0.1.11211 stable notes (#8518) | 2.8 | 3.76 | 15.23 | 37.47 | 57.96 | 32.81 | 66.87 | 100.91 | 130.93 |
| [056fa5a93](https://github.com/AFK-surf/monoid/commit/056fa5a9323df0e00f29bac61313ed61152eb4e9) feat(pion): Wave M1.1 monoid mbt2pion toolchain, s | 2.8 | 3.76 | 15.23 | 37.47 | 57.96 | 32.81 | 66.87 | 100.81 | 130.64 |
| [03c64d375](https://github.com/AFK-surf/monoid/commit/03c64d375a40de178f160b4ce6c6e70df185be9e) feat(mbui): add multicolor accent option that pick | 2.8 | 3.76 | 15.23 | 37.46 | 57.96 | 32.79 | 66.84 | 100.86 | 120.3 |
| [41601bf57](https://github.com/AFK-surf/monoid/commit/41601bf576e9798f57b9853ef390bd4b52aa9953) fix(ui): space stop slider ends evenly and keep th | 2.79 | 3.76 | 15.22 | 37.41 | 57.82 | 32.79 | 66.84 | 100.86 | 132.14 |
| [40408f70c](https://github.com/AFK-surf/monoid/commit/40408f70c1100971cbaf09c07c102a987c6c8dfb) feat(pion-station): add Wave 5 foundation primitiv | 2.79 | 3.76 | 15.22 | 37.41 | 57.82 | 32.79 | 66.84 | 100.86 | 132.14 |
| [87f4dd70f](https://github.com/AFK-surf/monoid/commit/87f4dd70f451134171d9301ac3bff6f1655cd13d) fix(ui,mbui): fix quote card motion and particle s | 2.79 | 3.75 | 15.19 | 37.41 | 57.82 | 32.76 | 66.75 | 100.73 | 132.14 |
| [8eaa7eeb3](https://github.com/AFK-surf/monoid/commit/8eaa7eeb3b0c312dd4fc5b773e992e2d97b93810) fix(ui): fix Role 4 Tab bevelGate ghosting, slim L | 2.79 | 3.75 | 15.19 | 37.41 | 57.82 | 32.76 | 66.75 | 100.73 | 132.14 |
| [208f9e2ff](https://github.com/AFK-surf/monoid/commit/208f9e2ffce41755590dfea1aa85464da8ecabc4) fix(mbui): let the chat scroll under an open Poke  | 2.79 | 3.75 | 15.19 | 37.41 | 57.82 | 32.76 | 66.75 | 100.73 | 132.14 |
| [674707c85](https://github.com/AFK-surf/monoid/commit/674707c850553d39ee4ba9c1ea2f1aba344e55e9) fix(app): drop the 屏幕 menu headings when no agent  | 2.79 | 3.75 | 15.19 | 37.41 | 57.82 | 32.76 | 66.75 | 100.73 | 132.14 |
| [8f98e134a](https://github.com/AFK-surf/monoid/commit/8f98e134af1708e573fdb5714339079d0972d885) fix(station): bound the task list a station answer | 2.79 | 3.75 | 15.19 | 37.41 | 57.82 | 32.76 | 66.75 | 100.73 | 132.14 |
| [a2a1f41bb](https://github.com/AFK-surf/monoid/commit/a2a1f41bbfbe96aeaae1c00b3105c63aa098f029) feat(station,core,mbui): let a shared profile foll | 2.79 | 3.75 | 15.19 | 37.41 | 57.82 | 32.76 | 66.75 | 100.84 | 132.14 |
| [b55239583](https://github.com/AFK-surf/monoid/commit/b55239583372d921e62424d996c323e7e1b3c557) perf(ui,mbui): fix touch-move batching and elimina | 2.79 | 3.75 | 15.19 | 37.41 | 57.82 | 32.76 | 66.75 | 100.84 | 132.14 |
| [79d825178](https://github.com/AFK-surf/monoid/commit/79d82517845e64708bf4e75dce2f23d4893f2670) fix(mbui): use Meta text size in Poke popover and  | 2.78 | 3.75 | 15.19 | 37.41 | 57.81 | 32.76 | 66.75 | 100.78 | 125.87 |
| [49c56a044](https://github.com/AFK-surf/monoid/commit/49c56a04493e35db7f2da2b4b906537df25bda7e) fix(station): share one ssh connection per Colab V | 2.78 | 3.75 | 15.19 | 37.41 | 57.81 | 32.76 | 66.75 | 100.78 | 125.87 |
| [f0fb92750](https://github.com/AFK-surf/monoid/commit/f0fb92750e75a8625aa4da34e206fee16f6c96db) feat(ui): v8 liquid glass optics, parabolic Light  | 2.78 | 3.75 | 15.19 | 37.41 | 57.81 | 32.76 | 66.75 | 100.78 | 125.87 |
| [d40b1fee6](https://github.com/AFK-surf/monoid/commit/d40b1fee6657d2b51f62954d6daab0e7f44312a8) fix(station): start a new Feishu thread for a quot | 2.78 | 3.75 | 15.19 | 37.41 | 57.81 | 32.76 | 66.74 | 100.68 | 123.04 |
| [67be246b5](https://github.com/AFK-surf/monoid/commit/67be246b5291e9c7094563d4e6eec8fde602916c) fix(station): let granted stations reach a rig's s | 2.78 | 3.75 | 15.19 | 37.41 | 57.81 | 32.76 | 66.74 | 100.68 | 123.04 |
| [e06b8f342](https://github.com/AFK-surf/monoid/commit/e06b8f342e1320a945260199cb82835a2e70370d) chore(farview): point at AFK-surf/farview-legacy ( | 2.78 | 3.75 | 15.19 | 37.41 | 57.81 | 32.76 | 66.74 | 100.68 | 123.04 |
| [973632d2b](https://github.com/AFK-surf/monoid/commit/973632d2bc8bd432788347a7f8bed0496feaba44) perf(core,station): cut steady-state overview push | 2.78 | 3.75 | 15.19 | 37.41 | 57.81 | 32.76 | 66.74 | 100.68 | 123.04 |
| [4071ef70c](https://github.com/AFK-surf/monoid/commit/4071ef70c97c2aad6409fac6519c3bf6350e9774) feat(pion-station): migrate stateful archive-last  | 2.78 | 3.75 | 15.19 | 37.4 | 57.81 | 32.75 | 66.74 | 100.68 | 125.07 |
| [d9a7748e3](https://github.com/AFK-surf/monoid/commit/d9a7748e3cf7f12fdc33b338bd86f763d53f8d53) fix(screens): bound simulator view startup and enu | 2.78 | 3.75 | 15.19 | 37.4 | 57.81 | 32.75 | 66.74 | 100.68 | 125.07 |
| [e5dc78307](https://github.com/AFK-surf/monoid/commit/e5dc78307cf13887651506576fa3d4636e9ccdb5) feat(pion-station): migrate 5 index/job SQLite bui | 2.78 | 3.75 | 15.19 | 37.4 | 57.81 | 32.75 | 66.74 | 100.68 | 125.07 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [00b25b9e0](https://github.com/AFK-surf/monoid/commit/00b25b9e0b73cd1450440413390d6065ddac3272) feat(pion-station): migrate vault-uses SQLite buil | 0.56 | 0.73 | 2.85 | 3.86 | 7.09 | 2.1 | 5.86 | 57.28 |
| [fe220a848](https://github.com/AFK-surf/monoid/commit/fe220a8482864df7977422f47192751d9253b0a9) fix(core,station): keep waiting writes in SQLite a | 0.56 | 0.73 | 2.85 | 3.86 | 7.09 | 2.1 | 5.86 | 57.51 |
| [56d4ffcb5](https://github.com/AFK-surf/monoid/commit/56d4ffcb54e7c88a08ec6c8e2ce8973da252bad4) docs(releases): 0.1.11211 stable notes (#8518) | 0.56 | 0.73 | 2.85 | 3.86 | 7.09 | 2.1 | 5.86 | 57.54 |
| [056fa5a93](https://github.com/AFK-surf/monoid/commit/056fa5a9323df0e00f29bac61313ed61152eb4e9) feat(pion): Wave M1.1 monoid mbt2pion toolchain, s | 0.56 | 0.73 | 2.85 | 3.86 | 7.09 | 2.1 | 5.86 | 57.75 |
| [03c64d375](https://github.com/AFK-surf/monoid/commit/03c64d375a40de178f160b4ce6c6e70df185be9e) feat(mbui): add multicolor accent option that pick | 0.56 | 0.73 | 2.85 | 3.86 | 7.09 | 2.1 | 5.86 | 57.31 |
| [41601bf57](https://github.com/AFK-surf/monoid/commit/41601bf576e9798f57b9853ef390bd4b52aa9953) fix(ui): space stop slider ends evenly and keep th | 0.56 | 0.73 | 2.85 | 3.86 | 7.09 | 2.1 | 5.86 | 57.21 |
| [40408f70c](https://github.com/AFK-surf/monoid/commit/40408f70c1100971cbaf09c07c102a987c6c8dfb) feat(pion-station): add Wave 5 foundation primitiv | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.1 | 5.84 | 57.38 |
| [87f4dd70f](https://github.com/AFK-surf/monoid/commit/87f4dd70f451134171d9301ac3bff6f1655cd13d) fix(ui,mbui): fix quote card motion and particle s | 0.56 | 0.73 | 2.85 | 3.86 | 7.09 | 2.1 | 5.86 | 57.44 |
| [8eaa7eeb3](https://github.com/AFK-surf/monoid/commit/8eaa7eeb3b0c312dd4fc5b773e992e2d97b93810) fix(ui): fix Role 4 Tab bevelGate ghosting, slim L | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.1 | 5.84 | 57.48 |
| [208f9e2ff](https://github.com/AFK-surf/monoid/commit/208f9e2ffce41755590dfea1aa85464da8ecabc4) fix(mbui): let the chat scroll under an open Poke  | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 57.26 |
| [674707c85](https://github.com/AFK-surf/monoid/commit/674707c850553d39ee4ba9c1ea2f1aba344e55e9) fix(app): drop the 屏幕 menu headings when no agent  | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 57.43 |
| [8f98e134a](https://github.com/AFK-surf/monoid/commit/8f98e134af1708e573fdb5714339079d0972d885) fix(station): bound the task list a station answer | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 57.16 |
| [a2a1f41bb](https://github.com/AFK-surf/monoid/commit/a2a1f41bbfbe96aeaae1c00b3105c63aa098f029) feat(station,core,mbui): let a shared profile foll | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 57.87 |
| [b55239583](https://github.com/AFK-surf/monoid/commit/b55239583372d921e62424d996c323e7e1b3c557) perf(ui,mbui): fix touch-move batching and elimina | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 57.53 |
| [79d825178](https://github.com/AFK-surf/monoid/commit/79d82517845e64708bf4e75dce2f23d4893f2670) fix(mbui): use Meta text size in Poke popover and  | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 57.54 |
| [49c56a044](https://github.com/AFK-surf/monoid/commit/49c56a04493e35db7f2da2b4b906537df25bda7e) fix(station): share one ssh connection per Colab V | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 65.41 |
| [f0fb92750](https://github.com/AFK-surf/monoid/commit/f0fb92750e75a8625aa4da34e206fee16f6c96db) feat(ui): v8 liquid glass optics, parabolic Light  | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 57.71 |
| [d40b1fee6](https://github.com/AFK-surf/monoid/commit/d40b1fee6657d2b51f62954d6daab0e7f44312a8) fix(station): start a new Feishu thread for a quot | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 57.53 |
| [67be246b5](https://github.com/AFK-surf/monoid/commit/67be246b5291e9c7094563d4e6eec8fde602916c) fix(station): let granted stations reach a rig's s | 0.56 | 0.73 | 2.85 | 3.86 | 7.08 | 2.09 | 5.84 | 57.44 |
| [e06b8f342](https://github.com/AFK-surf/monoid/commit/e06b8f342e1320a945260199cb82835a2e70370d) chore(farview): point at AFK-surf/farview-legacy ( | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.16 |
| [973632d2b](https://github.com/AFK-surf/monoid/commit/973632d2bc8bd432788347a7f8bed0496feaba44) perf(core,station): cut steady-state overview push | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.56 |
| [4071ef70c](https://github.com/AFK-surf/monoid/commit/4071ef70c97c2aad6409fac6519c3bf6350e9774) feat(pion-station): migrate stateful archive-last  | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.53 |
| [d9a7748e3](https://github.com/AFK-surf/monoid/commit/d9a7748e3cf7f12fdc33b338bd86f763d53f8d53) fix(screens): bound simulator view startup and enu | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.57 |
| [e5dc78307](https://github.com/AFK-surf/monoid/commit/e5dc78307cf13887651506576fa3d4636e9ccdb5) feat(pion-station): migrate 5 index/job SQLite bui | 0.56 | 0.73 | 2.85 | 3.85 | 7.08 | 2.09 | 5.84 | 57.46 |
