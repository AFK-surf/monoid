# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [bd2012fe8](https://github.com/AFK-surf/monoid/commit/bd2012fe8fd018a6de405bf3b43e513b047bb505) fix(projects): unify unclassified, keep active/pin | 2.59 | 3.5 | 14.5 | 37.26 | 56.66 | 32.63 | 66.28 | 101.17 | 120.2 |
| [a64c7ab50](https://github.com/AFK-surf/monoid/commit/a64c7ab5091689f31b0d004b5adbc80ac85d2e36) perf(ui,core,shell): verify kept fonts off UI thre | 2.59 | 3.5 | 14.5 | 37.26 | 56.66 | 32.62 | 66.28 | 101.27 | 120.2 |
| [b54ef725e](https://github.com/AFK-surf/monoid/commit/b54ef725e5da47b4d2ce6a4dabf9d4cdb5186b92) feat(screen): separate stream resolution, bitrate, | 2.59 | 3.5 | 14.5 | 37.26 | 56.66 | 32.61 | 66.26 | 100.93 | 120.2 |
| [df558d46f](https://github.com/AFK-surf/monoid/commit/df558d46f7883ab02755932d033f8795c73ab3d5) fix(station): hold self-update while a login is un | 2.59 | 3.5 | 14.48 | 37.25 | 56.62 | 32.59 | 66.24 | 100.88 | 122.79 |
| [5e09001df](https://github.com/AFK-surf/monoid/commit/5e09001dfe5b86fe509687120f33a2d0c7325a75) perf(station): read every profile's allowance hour | 2.59 | 3.5 | 14.48 | 37.25 | 56.62 | 32.59 | 66.24 | 100.88 | 122.79 |
| [db07237c5](https://github.com/AFK-surf/monoid/commit/db07237c5ac95f844a7deb042638380bed2341b6) fix(shell): release an endpoint's sockets before i | 2.59 | 3.5 | 14.48 | 37.25 | 56.62 | 32.59 | 66.24 | 101.12 | 133.97 |
| [f7b33699e](https://github.com/AFK-surf/monoid/commit/f7b33699ebf908c8e198e1fd78a69fd7ead5e7a7) fix(station): block provider-restricted accounts a | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.71 | 124.98 |
| [6117ad142](https://github.com/AFK-surf/monoid/commit/6117ad1421cdbbf5cdd6934da456edf4d5303cc2) fix(station): read a rig's grants again once the p | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.71 | 124.98 |
| [91cfd340e](https://github.com/AFK-surf/monoid/commit/91cfd340e3034afd42e4da201257c1e93e8c114e) fix(station): omit commentless auto-quotes when ou | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.71 | 124.98 |
| [91d27fc9d](https://github.com/AFK-surf/monoid/commit/91d27fc9d1edcd9b2c763afc06d12960c5eb8bfc) fix(ui,web): prevent iOS WebKit touchend from blur | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.71 | 124.98 |
| [f94f0883c](https://github.com/AFK-surf/monoid/commit/f94f0883c061d0856743341a618260609e54c233) feat(station): W9-A5a default policy table, wildca | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.71 | 124.98 |
| [b97430dc8](https://github.com/AFK-surf/monoid/commit/b97430dc8bb9bdc9c4fe762c1dd504316aec5ee3) fix(station): wait out Windows rename locks in hea | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.71 | 124.98 |
| [95364a80f](https://github.com/AFK-surf/monoid/commit/95364a80f84eb43ad00fc4dbb161ca8329cfa532) feat(install,mbui): remind Windows users to instal | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 101.01 | 127.36 |
| [50ce74f12](https://github.com/AFK-surf/monoid/commit/50ce74f1266d0405f0372360e9b0ca7e78ff75e2) fix(ui): remove dead MBRAWPTR raw-pointer image ho | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.91 | 131.93 |
| [ec265b87e](https://github.com/AFK-surf/monoid/commit/ec265b87ecace25864f707e45a589c6ba95e3f24) fix(station-test): gate the screen task in remote. | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.91 | 131.93 |
| [506a06686](https://github.com/AFK-surf/monoid/commit/506a0668620e77c74f24dbf39ecbe30c0c80ca9f) perf(station): read who waits for a person from th | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.91 | 131.93 |
| [638e1d2ad](https://github.com/AFK-surf/monoid/commit/638e1d2adb9371c62921dade9b549c51e690bd5f) fix(ui): keep virtual list bottom aligned on dynam | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.88 | 106.6 |
| [ece43bfac](https://github.com/AFK-surf/monoid/commit/ece43bfac32738b28d00d5da36af36334912f743) fix(station): dirsync edge fixes and replica-chat  | 2.59 | 3.5 | 14.48 | 37.12 | 56.61 | 32.43 | 65.85 | 101.09 | 122.14 |
| [4eb2befde](https://github.com/AFK-surf/monoid/commit/4eb2befde23edb1e4276c9e7781c1828ea1dcd99) fix(station): take up a Codex session by its id af | 2.59 | 3.5 | 14.48 | 37.12 | 56.61 | 32.43 | 65.85 | 101.09 | 122.14 |
| [259f33ecf](https://github.com/AFK-surf/monoid/commit/259f33ecfe5ada96b07d36de863d6cd7212add5a) station: include quote comments in outflowMessages | 2.59 | 3.5 | 14.48 | 37.12 | 56.61 | 32.43 | 65.85 | 101.09 | 122.14 |
| [9239b1fc0](https://github.com/AFK-surf/monoid/commit/9239b1fc0dec4c74f6f18ded7926583b5ef92ed7) fix(core-ts): avoid dead-relay and sleep-freeze st | 2.59 | 3.5 | 14.48 | 37.12 | 56.61 | 32.43 | 65.85 | 101.09 | 122.14 |
| [6e0f24c48](https://github.com/AFK-surf/monoid/commit/6e0f24c4831c7aab5a686fa8e4e72852e2f9c528) perf(station): split mb-fault-replica-retire into  | 2.59 | 3.5 | 14.48 | 37.12 | 56.61 | 32.42 | 65.85 | 101.27 | 125.87 |
| [5665f3844](https://github.com/AFK-surf/monoid/commit/5665f384419fe3ca532c90bcf7b0acc06909996f) fix(shell): abort in-flight tcp.read and tcp.write | 2.59 | 3.5 | 14.48 | 37.12 | 56.61 | 32.42 | 65.85 | 101.27 | 125.87 |
| [ab0f513b0](https://github.com/AFK-surf/monoid/commit/ab0f513b0fb241c38df3d46be191cd49134bc541) fix(ui,mbui): keep text selection across virtualiz | 2.59 | 3.5 | 14.48 | 37.1 | 56.61 | 32.41 | 65.81 | 101.11 | 121.8 |
| [ef316b563](https://github.com/AFK-surf/monoid/commit/ef316b56330902b7675c3e3caf52bbda33a0c1bc) fix(station): stop stillfail-pion.exe on Windows,  | 2.59 | 3.5 | 14.48 | 37.1 | 56.61 | 32.41 | 65.81 | 101.19 | 125.52 |
| [d07b20358](https://github.com/AFK-surf/monoid/commit/d07b2035876c5b1d5dcee159ffe059465dbf6de1) perf(pion-base): copy unescaped runs in base_codec | 2.59 | 3.5 | 14.48 | 37.1 | 56.61 | 32.41 | 65.81 | 101.19 | 121.2 |
| [00a8d823d](https://github.com/AFK-surf/monoid/commit/00a8d823df8382da91550b4bb9cac3cceba395da) chore(ui): lower clean motion bars for list_stint  | 2.59 | 3.5 | 14.48 | 37.1 | 56.61 | 32.41 | 65.81 | 101.19 | 121.2 |
| [13922d044](https://github.com/AFK-surf/monoid/commit/13922d04412896a190d731348154548ddc05d71f) perf(ui): fix dark-mode adaptive settle storm, 3x  | 2.59 | 3.5 | 14.48 | 37.1 | 56.61 | 32.41 | 65.81 | 100.84 | 131.52 |
| [377326ff8](https://github.com/AFK-surf/monoid/commit/377326ff88a3b6c822f3c085fb0dc56002cb1887) fix(station): preserve progress across stale-head  | 2.59 | 3.5 | 14.48 | 37.1 | 56.6 | 32.41 | 65.8 | 101.06 | 124.05 |
| [169ca1f50](https://github.com/AFK-surf/monoid/commit/169ca1f50f653cc34c326270faf227038242e574) feat(pion-station): port --builder replica-chat to | 2.59 | 3.5 | 14.48 | 37.1 | 56.6 | 32.41 | 65.8 | 101.06 | 124.05 |
| [d8051674f](https://github.com/AFK-surf/monoid/commit/d8051674f4057ed1411a045676ad85c18a2fe5e0) feat(pion-station): W8-F zero-stub reader_sessions | 2.59 | 3.5 | 14.48 | 37.1 | 56.6 | 32.41 | 65.8 | 101.06 | 124.05 |
| [fe21ea979](https://github.com/AFK-surf/monoid/commit/fe21ea9792544802abee0f3e097cd6f03766a464) perf(ci): cut cloud and root test time in check-li | 2.59 | 3.5 | 14.48 | 37.1 | 56.6 | 32.41 | 65.8 | 101.06 | 124.05 |
| [6c37aaacb](https://github.com/AFK-surf/monoid/commit/6c37aaacb80de3719d622e3e2168cfc319733bee) feat(mbui): add cross-screen chat projects and tag | 2.59 | 3.5 | 14.48 | 37.1 | 56.6 | 32.41 | 65.8 | 101.06 | 124.05 |
| [771a84655](https://github.com/AFK-surf/monoid/commit/771a846551385d1cde773b0790c1c013fe538280) fix(station): wait for own connects before refusin | 2.56 | 3.46 | 14.31 | 36.92 | 55.88 | 32.25 | 65.22 | 101.04 | 125.82 |
| [224d3f7a0](https://github.com/AFK-surf/monoid/commit/224d3f7a0df6dfa1c3b0f175962148b19b9e4443) fix(ci): publish main's Mac natives to the native  | 2.56 | 3.46 | 14.29 | 36.9 | 55.82 | 32.24 | 65.18 | 101.21 | 130.49 |
| [fdc6ccbb1](https://github.com/AFK-surf/monoid/commit/fdc6ccbb10984b875d6b04264ed5e770fe11c947) perf(ci): rebalance station test slices by CI runn | 2.55 | 3.45 | 14.24 | 36.87 | 55.72 | 32.18 | 65.05 | 100.7 | 122.76 |
| [17f337ddd](https://github.com/AFK-surf/monoid/commit/17f337ddd8e9f8e0fd0c0e3e25003c5815ce0d86) perf(mbui): copy-on-write apply_delta, single-pass | 2.55 | 3.45 | 14.24 | 36.87 | 55.72 | 32.18 | 65.05 | 100.7 | 122.76 |
| [17dd44eeb](https://github.com/AFK-surf/monoid/commit/17dd44eeb65296de5e4416de6458c4e83209bbdc) feat(ui): add Settings MCP tab to manage station M | 2.55 | 3.45 | 14.24 | 36.87 | 55.72 | 32.18 | 65.05 | 100.7 | 122.76 |
| [e722bb594](https://github.com/AFK-surf/monoid/commit/e722bb594602ee611772cb8e17251e370c982fbe) ci(linux): move Linux jobs to GitHub-hosted runner | 2.55 | 3.45 | 14.24 | 36.87 | 55.72 | 32.18 | 65.05 | 100.7 | 122.76 |
| [8d840de46](https://github.com/AFK-surf/monoid/commit/8d840de468396987e2e02aea3d0d4fa4a0f936f2) fix(ci): stop mbui-size idle from tainting mbui-re | 2.55 | 3.45 | 14.24 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [bd2012fe8](https://github.com/AFK-surf/monoid/commit/bd2012fe8fd018a6de405bf3b43e513b047bb505) fix(projects): unify unclassified, keep active/pin | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.33 |
| [a64c7ab50](https://github.com/AFK-surf/monoid/commit/a64c7ab5091689f31b0d004b5adbc80ac85d2e36) perf(ui,core,shell): verify kept fonts off UI thre | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.54 |
| [b54ef725e](https://github.com/AFK-surf/monoid/commit/b54ef725e5da47b4d2ce6a4dabf9d4cdb5186b92) feat(screen): separate stream resolution, bitrate, | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.25 |
| [df558d46f](https://github.com/AFK-surf/monoid/commit/df558d46f7883ab02755932d033f8795c73ab3d5) fix(station): hold self-update while a login is un | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.33 |
| [5e09001df](https://github.com/AFK-surf/monoid/commit/5e09001dfe5b86fe509687120f33a2d0c7325a75) perf(station): read every profile's allowance hour | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.05 |
| [db07237c5](https://github.com/AFK-surf/monoid/commit/db07237c5ac95f844a7deb042638380bed2341b6) fix(shell): release an endpoint's sockets before i | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.23 |
| [f7b33699e](https://github.com/AFK-surf/monoid/commit/f7b33699ebf908c8e198e1fd78a69fd7ead5e7a7) fix(station): block provider-restricted accounts a | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.44 |
| [6117ad142](https://github.com/AFK-surf/monoid/commit/6117ad1421cdbbf5cdd6934da456edf4d5303cc2) fix(station): read a rig's grants again once the p | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.38 |
| [91cfd340e](https://github.com/AFK-surf/monoid/commit/91cfd340e3034afd42e4da201257c1e93e8c114e) fix(station): omit commentless auto-quotes when ou | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.44 |
| [91d27fc9d](https://github.com/AFK-surf/monoid/commit/91d27fc9d1edcd9b2c763afc06d12960c5eb8bfc) fix(ui,web): prevent iOS WebKit touchend from blur | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.49 |
| [f94f0883c](https://github.com/AFK-surf/monoid/commit/f94f0883c061d0856743341a618260609e54c233) feat(station): W9-A5a default policy table, wildca | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.35 |
| [b97430dc8](https://github.com/AFK-surf/monoid/commit/b97430dc8bb9bdc9c4fe762c1dd504316aec5ee3) fix(station): wait out Windows rename locks in hea | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.54 |
| [95364a80f](https://github.com/AFK-surf/monoid/commit/95364a80f84eb43ad00fc4dbb161ca8329cfa532) feat(install,mbui): remind Windows users to instal | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.57 |
| [50ce74f12](https://github.com/AFK-surf/monoid/commit/50ce74f1266d0405f0372360e9b0ca7e78ff75e2) fix(ui): remove dead MBRAWPTR raw-pointer image ho | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.07 |
| [ec265b87e](https://github.com/AFK-surf/monoid/commit/ec265b87ecace25864f707e45a589c6ba95e3f24) fix(station-test): gate the screen task in remote. | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.35 |
| [506a06686](https://github.com/AFK-surf/monoid/commit/506a0668620e77c74f24dbf39ecbe30c0c80ca9f) perf(station): read who waits for a person from th | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.43 |
| [638e1d2ad](https://github.com/AFK-surf/monoid/commit/638e1d2adb9371c62921dade9b549c51e690bd5f) fix(ui): keep virtual list bottom aligned on dynam | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.16 |
| [ece43bfac](https://github.com/AFK-surf/monoid/commit/ece43bfac32738b28d00d5da36af36334912f743) fix(station): dirsync edge fixes and replica-chat  | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.14 | 6.01 | 57.53 |
| [4eb2befde](https://github.com/AFK-surf/monoid/commit/4eb2befde23edb1e4276c9e7781c1828ea1dcd99) fix(station): take up a Codex session by its id af | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.14 | 6.01 | 57.53 |
| [259f33ecf](https://github.com/AFK-surf/monoid/commit/259f33ecfe5ada96b07d36de863d6cd7212add5a) station: include quote comments in outflowMessages | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.14 | 6.01 | 57.2 |
| [9239b1fc0](https://github.com/AFK-surf/monoid/commit/9239b1fc0dec4c74f6f18ded7926583b5ef92ed7) fix(core-ts): avoid dead-relay and sleep-freeze st | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.14 | 6.01 | 57.1 |
| [6e0f24c48](https://github.com/AFK-surf/monoid/commit/6e0f24c4831c7aab5a686fa8e4e72852e2f9c528) perf(station): split mb-fault-replica-retire into  | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.14 | 6.01 | 57.54 |
| [5665f3844](https://github.com/AFK-surf/monoid/commit/5665f384419fe3ca532c90bcf7b0acc06909996f) fix(shell): abort in-flight tcp.read and tcp.write | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.14 | 6.01 | 57.3 |
| [ab0f513b0](https://github.com/AFK-surf/monoid/commit/ab0f513b0fb241c38df3d46be191cd49134bc541) fix(ui,mbui): keep text selection across virtualiz | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.14 | 6.01 | 57.46 |
| [ef316b563](https://github.com/AFK-surf/monoid/commit/ef316b56330902b7675c3e3caf52bbda33a0c1bc) fix(station): stop stillfail-pion.exe on Windows,  | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.13 | 6.01 | 57.35 |
| [d07b20358](https://github.com/AFK-surf/monoid/commit/d07b2035876c5b1d5dcee159ffe059465dbf6de1) perf(pion-base): copy unescaped runs in base_codec | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.13 | 6.01 | 57.35 |
| [00a8d823d](https://github.com/AFK-surf/monoid/commit/00a8d823df8382da91550b4bb9cac3cceba395da) chore(ui): lower clean motion bars for list_stint  | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.13 | 6.01 | 57.12 |
| [13922d044](https://github.com/AFK-surf/monoid/commit/13922d04412896a190d731348154548ddc05d71f) perf(ui): fix dark-mode adaptive settle storm, 3x  | 0.56 | 0.74 | 2.87 | 3.92 | 7.18 | 2.13 | 6.01 | 57.28 |
| [377326ff8](https://github.com/AFK-surf/monoid/commit/377326ff88a3b6c822f3c085fb0dc56002cb1887) fix(station): preserve progress across stale-head  | 0.56 | 0.74 | 2.87 | 3.92 | 7.17 | 2.13 | 5.99 | 57.35 |
| [169ca1f50](https://github.com/AFK-surf/monoid/commit/169ca1f50f653cc34c326270faf227038242e574) feat(pion-station): port --builder replica-chat to | 0.56 | 0.74 | 2.87 | 3.92 | 7.17 | 2.13 | 5.99 | 57.28 |
| [d8051674f](https://github.com/AFK-surf/monoid/commit/d8051674f4057ed1411a045676ad85c18a2fe5e0) feat(pion-station): W8-F zero-stub reader_sessions | 0.56 | 0.74 | 2.87 | 3.92 | 7.17 | 2.13 | 5.99 | 57.41 |
| [fe21ea979](https://github.com/AFK-surf/monoid/commit/fe21ea9792544802abee0f3e097cd6f03766a464) perf(ci): cut cloud and root test time in check-li | 0.56 | 0.74 | 2.87 | 3.92 | 7.17 | 2.13 | 5.99 | 57.39 |
| [6c37aaacb](https://github.com/AFK-surf/monoid/commit/6c37aaacb80de3719d622e3e2168cfc319733bee) feat(mbui): add cross-screen chat projects and tag | 0.56 | 0.74 | 2.87 | 3.92 | 7.17 | 2.13 | 5.99 | 57.33 |
| [771a84655](https://github.com/AFK-surf/monoid/commit/771a846551385d1cde773b0790c1c013fe538280) fix(station): wait for own connects before refusin | 0.56 | 0.74 | 2.87 | 3.92 | 7.17 | 2.13 | 5.99 | 57.53 |
| [224d3f7a0](https://github.com/AFK-surf/monoid/commit/224d3f7a0df6dfa1c3b0f175962148b19b9e4443) fix(ci): publish main's Mac natives to the native  | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.9 |
| [fdc6ccbb1](https://github.com/AFK-surf/monoid/commit/fdc6ccbb10984b875d6b04264ed5e770fe11c947) perf(ci): rebalance station test slices by CI runn | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.85 |
| [17f337ddd](https://github.com/AFK-surf/monoid/commit/17f337ddd8e9f8e0fd0c0e3e25003c5815ce0d86) perf(mbui): copy-on-write apply_delta, single-pass | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.72 |
| [17dd44eeb](https://github.com/AFK-surf/monoid/commit/17dd44eeb65296de5e4416de6458c4e83209bbdc) feat(ui): add Settings MCP tab to manage station M | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.66 |
| [e722bb594](https://github.com/AFK-surf/monoid/commit/e722bb594602ee611772cb8e17251e370c982fbe) ci(linux): move Linux jobs to GitHub-hosted runner | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 58.03 |
| [8d840de46](https://github.com/AFK-surf/monoid/commit/8d840de468396987e2e02aea3d0d4fa4a0f936f2) fix(ci): stop mbui-size idle from tainting mbui-re | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.49 |
