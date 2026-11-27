# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [3548369bf](https://github.com/AFK-surf/monoid/commit/3548369bf6d69f5cd5342ee6231f105a2389ae5a) perf(cloud): cache compact changelog fixes and bat | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 109.2 | 122.42 |
| [888341385](https://github.com/AFK-surf/monoid/commit/888341385d2dd34f3489cfcd2dbaf6aa5a08c24d) fix(station): offer Copilot models GitHub lists wi | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 109.2 | 122.42 |
| [c793e8932](https://github.com/AFK-surf/monoid/commit/c793e8932be884d034b45c2b5e41747bfe94fd3d) perf(cloud): single-flight cache changelog and rel | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 109.2 | 122.42 |
| [e3218e65a](https://github.com/AFK-surf/monoid/commit/e3218e65aa16b7e28b8b6c6757e38fa5f157eef0) perf(station,core): stream incremental overview-pa | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 109.2 | 122.42 |
| [36bef9f96](https://github.com/AFK-surf/monoid/commit/36bef9f96a1e71d686c5c71fe550e82cd7ec0dfc) fix(station): end a turn that stays silent after i | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 108.89 | 125.14 |
| [0c05c70eb](https://github.com/AFK-surf/monoid/commit/0c05c70ebc24863896e6e66b029a60309712c263) feat(mbui): migrate profiles/stations places to pi | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 108.89 | 125.14 |
| [c14a4b71d](https://github.com/AFK-surf/monoid/commit/c14a4b71d0f144c24929d1021d967b1f5e1b3f05) feat(core,mbui): add authGen/vaultGen sync boundar | 2.67 | 3.61 | 14.99 | 38.02 | 58.24 | 33.33 | 67.99 | 108.89 | 125.14 |
| [dc6e4f996](https://github.com/AFK-surf/monoid/commit/dc6e4f9961facdb43561ff91f42454cb2071df38) fix(core-ts): memoize bridged conn.closed and forg | 2.67 | 3.6 | 14.95 | 37.94 | 58.12 | 33.25 | 67.9 | 102.12 | 129.32 |
| [38ba386fa](https://github.com/AFK-surf/monoid/commit/38ba386fa931ef37ed7734be8cc194ddc5e6de00) feat(station-whole): assemble transport-independen | 2.67 | 3.6 | 14.95 | 37.94 | 58.12 | 33.25 | 67.9 | 101.96 | 130.04 |
| [5d20d0961](https://github.com/AFK-surf/monoid/commit/5d20d09614916784636c531a919e59426f5d51b6) docs(changelog): say the lists that came with the  | 2.67 | 3.6 | 14.95 | 37.94 | 58.12 | 33.25 | 67.9 | 101.96 | 130.04 |
| [0973b9321](https://github.com/AFK-surf/monoid/commit/0973b9321389c2506ab5590eae4d3d9a2dd5f1f2) fix(ci): update mbui-ci test package prefixes from | 2.66 | 3.6 | 14.94 | 37.92 | 58.09 | 33.23 | 67.87 | 101.86 | 127.14 |
| [225e586cc](https://github.com/AFK-surf/monoid/commit/225e586ccf866d08902958d74e855d99ced9ab01) feat(station-main): wire native hooks and claude-t | 2.66 | 3.6 | 14.94 | 37.92 | 58.09 | 33.23 | 67.87 | 101.86 | 127.14 |
| [d93475c74](https://github.com/AFK-surf/monoid/commit/d93475c74b41ea78eb736f7a8102b326d3687209) fix(ci): paginate native-artifacts release assets  | 2.66 | 3.6 | 14.94 | 37.92 | 58.09 | 33.23 | 67.87 | 102.09 | 138.12 |
| [b1d1d6c1c](https://github.com/AFK-surf/monoid/commit/b1d1d6c1cd280efcd84bbe20f4c52b9bbc66a506) feat(ui,mbui,core): Markdown marks and lists in th | 2.66 | 3.6 | 14.94 | 37.92 | 58.09 | 33.23 | 67.87 | 102.09 | 138.12 |
| [af3969628](https://github.com/AFK-surf/monoid/commit/af396962837fed9c56ccb914c2816c3399efd84b) feat(mbui): migrate pollers, subject-keyed screen  | 2.66 | 3.6 | 14.94 | 37.92 | 58.09 | 33.23 | 67.87 | 102.09 | 138.12 |
| [5a3e3166e](https://github.com/AFK-surf/monoid/commit/5a3e3166eac49e576ec3cac9e9f5db2064eb827a) ci(mbui): trim Actions cache footprint below GitHu | 2.66 | 3.59 | 14.9 | 37.88 | 57.97 | 33.2 | 67.79 | 102.06 | 130.96 |
| [3ac73fc9f](https://github.com/AFK-surf/monoid/commit/3ac73fc9f057a7f2c9cfa83099b721d0c155a2fe) perf(pion-station): single-pass JSON stringify, fa | 2.66 | 3.59 | 14.9 | 37.88 | 57.97 | 33.2 | 67.79 | 102.06 | 130.96 |
| [3bb9a03a0](https://github.com/AFK-surf/monoid/commit/3bb9a03a01ff07c3712fd1a806ec539402ddfec9) fix(ui): support Shift+click range extension for t | 2.66 | 3.59 | 14.9 | 37.88 | 57.97 | 33.2 | 67.79 | 102.06 | 130.96 |
| [2eab0062a](https://github.com/AFK-surf/monoid/commit/2eab0062a97617dbc5b2db61cb14fe8717f75f18) feat(station): expose chat attachments over Comma  | 2.66 | 3.59 | 14.9 | 37.88 | 57.97 | 33.2 | 67.77 | 101.99 | 109.78 |
| [3cc244396](https://github.com/AFK-surf/monoid/commit/3cc2443960c94da204958f3dc3d7448c76775f7b) feat(mbui,core): add a switch that removes the hue | 2.66 | 3.59 | 14.9 | 37.88 | 57.97 | 33.2 | 67.77 | 101.99 | 109.78 |
| [554dfc3e0](https://github.com/AFK-surf/monoid/commit/554dfc3e067544e3c911965dd49a52ec1d934588) test(station): retry the temp directory removal in | 2.65 | 3.59 | 14.9 | 37.87 | 57.96 | 33.2 | 67.77 | 101.91 | 136.35 |
| [d63accfe9](https://github.com/AFK-surf/monoid/commit/d63accfe908b7b0bb3454206879d453e4015c7f9) perf(station): speed up timeline reads via direct  | 2.66 | 3.59 | 14.9 | 37.87 | 57.95 | 33.19 | 67.75 | 101.89 | 94.32 |
| [10685d264](https://github.com/AFK-surf/monoid/commit/10685d2642b2298e74133c1c784bc0eed5b3a50e) feat(core,mbui): add repair and update shortcuts t | 2.66 | 3.59 | 14.9 | 37.87 | 57.95 | 33.19 | 67.75 | 101.89 | 94.32 |
| [353fa03f1](https://github.com/AFK-surf/monoid/commit/353fa03f1a611ad4ec25fe83fce504475a9c3103) feat(mbui,core): read basic Markdown marks in a pe | 2.66 | 3.59 | 14.9 | 37.87 | 57.95 | 33.19 | 67.75 | 101.89 | 94.32 |
| [fd3ebabc5](https://github.com/AFK-surf/monoid/commit/fd3ebabc587450382c37abfbd790c18432779085) fix(mbui): put the desktop sign-in page in the mid | 2.66 | 3.59 | 14.9 | 37.87 | 57.95 | 33.19 | 67.75 | 101.89 | 94.32 |
| [9317c90cd](https://github.com/AFK-surf/monoid/commit/9317c90cd555e7fc587a5737dff0cd737183ed56) fix(mbui): ease the tab bar width as its panel ope | 2.65 | 3.59 | 14.9 | 37.87 | 57.94 | 33.18 | 67.75 | 101.93 | 135.89 |
| [2658f9d9c](https://github.com/AFK-surf/monoid/commit/2658f9d9c307b0ba39b50d3078ccf5500708526a) refactor(station-main): extract shared daemon_core | 2.65 | 3.59 | 14.9 | 37.87 | 57.94 | 33.18 | 67.75 | 101.94 | 124.02 |
| [e6ec6ddce](https://github.com/AFK-surf/monoid/commit/e6ec6ddce6d21578ca69f00ba64a2df164e86162) perf(station): join screen helper frame pieces onc | 2.65 | 3.59 | 14.9 | 37.87 | 57.94 | 33.18 | 67.75 | 101.94 | 124.02 |
| [4064a47f9](https://github.com/AFK-surf/monoid/commit/4064a47f9b0a4977981de67ac39d6a024b13b308) perf(ui): stop waking idle frames for parked or hi | 2.65 | 3.59 | 14.9 | 37.87 | 57.94 | 33.18 | 67.75 | 101.94 | 124.02 |
| [466583200](https://github.com/AFK-surf/monoid/commit/466583200a8a7779268e0506cf2af3efbc35cc63) fix(mbui): take folders only from the chosen stati | 2.66 | 3.59 | 14.9 | 37.86 | 57.94 | 33.19 | 67.75 | 101.84 | 120.34 |
| [3b815d77d](https://github.com/AFK-surf/monoid/commit/3b815d77d93bb5255bea32599be7f116c8716304) fix(ci): deduplicate cache-prune listings and pagi | 2.65 | 3.59 | 14.9 | 37.86 | 57.94 | 33.19 | 67.75 | 102.25 | 127.34 |
| [686a170c1](https://github.com/AFK-surf/monoid/commit/686a170c1ea9b0e400a6e0ea4bc637c5a46472a9) fix(ui): measure list bands from the rows they fol | 2.65 | 3.59 | 14.89 | 37.8 | 57.93 | 33.12 | 67.74 | 101.53 | 125.46 |
| [9b2df4375](https://github.com/AFK-surf/monoid/commit/9b2df437584c5f79c9778d2e3578bfc652a87a68) perf(station): name the session in a slow history  | 2.65 | 3.59 | 14.89 | 37.8 | 57.93 | 33.12 | 67.74 | 101.53 | 123.44 |
| [31e518d3a](https://github.com/AFK-surf/monoid/commit/31e518d3ac79355c27990842cea53f90e6273747) fix(mbui): isolate VaultItem plaintext, visibility | 2.65 | 3.59 | 14.89 | 37.8 | 57.93 | 33.12 | 67.74 | 101.53 | 123.44 |
| [cc78ae49e](https://github.com/AFK-surf/monoid/commit/cc78ae49ef4d463c7dbc41dc782e1d0424df4de1) feat(mbui): add project-grouped sticky section hea | 2.65 | 3.58 | 14.88 | 37.78 | 57.87 | 33.1 | 67.7 | 101.42 | 132.69 |
| [3cf626007](https://github.com/AFK-surf/monoid/commit/3cf62600776cb0d2255954c70948689a826f4560) feat(station-main): wire all 8 CLI subcommands int | 2.65 | 3.58 | 14.86 | 37.77 | 57.83 | 33.09 | 67.67 | 101.7 | 130.2 |
| [fde30eb69](https://github.com/AFK-surf/monoid/commit/fde30eb69d56d3cfd39ebfe5ef1b0bcacdcddeda) fix(ui): record keyboard scrolls for row motion ch | 2.65 | 3.58 | 14.86 | 37.77 | 57.83 | 33.09 | 67.67 | 101.7 | 130.2 |
| [7cb446b32](https://github.com/AFK-surf/monoid/commit/7cb446b322f2282313dd7bf0686de8a1049c863f) fix(mbui): open the first chat when the startup wa | 2.65 | 3.58 | 14.86 | 37.77 | 57.83 | 33.09 | 67.67 | 101.7 | 130.2 |
| [946d4f54c](https://github.com/AFK-surf/monoid/commit/946d4f54c95a38588c97016d8997f0a2125806c6) fix(mbui): include the film build script in the ho | 2.65 | 3.58 | 14.86 | 37.77 | 57.83 | 33.09 | 67.67 | 101.5 | 130.75 |
| [a1672fb1e](https://github.com/AFK-surf/monoid/commit/a1672fb1e10a7d2fb9f5c1bf3fb07152ed8724b4) fix(mbui): keep Home rows in place while a chat op | 2.65 | 3.58 | 14.86 | 37.77 | 57.83 | 33.09 | 67.67 | 101.5 | 130.75 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [3548369bf](https://github.com/AFK-surf/monoid/commit/3548369bf6d69f5cd5342ee6231f105a2389ae5a) perf(cloud): cache compact changelog fixes and bat | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.46 |
| [888341385](https://github.com/AFK-surf/monoid/commit/888341385d2dd34f3489cfcd2dbaf6aa5a08c24d) fix(station): offer Copilot models GitHub lists wi | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.51 |
| [c793e8932](https://github.com/AFK-surf/monoid/commit/c793e8932be884d034b45c2b5e41747bfe94fd3d) perf(cloud): single-flight cache changelog and rel | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.56 |
| [e3218e65a](https://github.com/AFK-surf/monoid/commit/e3218e65aa16b7e28b8b6c6757e38fa5f157eef0) perf(station,core): stream incremental overview-pa | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.64 |
| [36bef9f96](https://github.com/AFK-surf/monoid/commit/36bef9f96a1e71d686c5c71fe550e82cd7ec0dfc) fix(station): end a turn that stays silent after i | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.82 |
| [0c05c70eb](https://github.com/AFK-surf/monoid/commit/0c05c70ebc24863896e6e66b029a60309712c263) feat(mbui): migrate profiles/stations places to pi | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.74 |
| [c14a4b71d](https://github.com/AFK-surf/monoid/commit/c14a4b71d0f144c24929d1021d967b1f5e1b3f05) feat(core,mbui): add authGen/vaultGen sync boundar | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.74 |
| [dc6e4f996](https://github.com/AFK-surf/monoid/commit/dc6e4f9961facdb43561ff91f42454cb2071df38) fix(core-ts): memoize bridged conn.closed and forg | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.54 |
| [38ba386fa](https://github.com/AFK-surf/monoid/commit/38ba386fa931ef37ed7734be8cc194ddc5e6de00) feat(station-whole): assemble transport-independen | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.46 |
| [5d20d0961](https://github.com/AFK-surf/monoid/commit/5d20d09614916784636c531a919e59426f5d51b6) docs(changelog): say the lists that came with the  | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.66 |
| [0973b9321](https://github.com/AFK-surf/monoid/commit/0973b9321389c2506ab5590eae4d3d9a2dd5f1f2) fix(ci): update mbui-ci test package prefixes from | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.46 |
| [225e586cc](https://github.com/AFK-surf/monoid/commit/225e586ccf866d08902958d74e855d99ced9ab01) feat(station-main): wire native hooks and claude-t | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.28 | 57.62 |
| [d93475c74](https://github.com/AFK-surf/monoid/commit/d93475c74b41ea78eb736f7a8102b326d3687209) fix(ci): paginate native-artifacts release assets  | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.56 |
| [b1d1d6c1c](https://github.com/AFK-surf/monoid/commit/b1d1d6c1cd280efcd84bbe20f4c52b9bbc66a506) feat(ui,mbui,core): Markdown marks and lists in th | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.56 |
| [af3969628](https://github.com/AFK-surf/monoid/commit/af396962837fed9c56ccb914c2816c3399efd84b) feat(mbui): migrate pollers, subject-keyed screen  | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.28 | 57.75 |
| [5a3e3166e](https://github.com/AFK-surf/monoid/commit/5a3e3166eac49e576ec3cac9e9f5db2064eb827a) ci(mbui): trim Actions cache footprint below GitHu | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.28 | 57.84 |
| [3ac73fc9f](https://github.com/AFK-surf/monoid/commit/3ac73fc9f057a7f2c9cfa83099b721d0c155a2fe) perf(pion-station): single-pass JSON stringify, fa | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.28 | 57.64 |
| [3bb9a03a0](https://github.com/AFK-surf/monoid/commit/3bb9a03a01ff07c3712fd1a806ec539402ddfec9) fix(ui): support Shift+click range extension for t | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.28 | 57.54 |
| [2eab0062a](https://github.com/AFK-surf/monoid/commit/2eab0062a97617dbc5b2db61cb14fe8717f75f18) feat(station): expose chat attachments over Comma  | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.28 | 57.41 |
| [3cc244396](https://github.com/AFK-surf/monoid/commit/3cc2443960c94da204958f3dc3d7448c76775f7b) feat(mbui,core): add a switch that removes the hue | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.26 | 57.61 |
| [554dfc3e0](https://github.com/AFK-surf/monoid/commit/554dfc3e067544e3c911965dd49a52ec1d934588) test(station): retry the temp directory removal in | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.26 | 57.31 |
| [d63accfe9](https://github.com/AFK-surf/monoid/commit/d63accfe908b7b0bb3454206879d453e4015c7f9) perf(station): speed up timeline reads via direct  | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.26 | 57.67 |
| [10685d264](https://github.com/AFK-surf/monoid/commit/10685d2642b2298e74133c1c784bc0eed5b3a50e) feat(core,mbui): add repair and update shortcuts t | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.26 | 57.67 |
| [353fa03f1](https://github.com/AFK-surf/monoid/commit/353fa03f1a611ad4ec25fe83fce504475a9c3103) feat(mbui,core): read basic Markdown marks in a pe | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.26 | 57.44 |
| [fd3ebabc5](https://github.com/AFK-surf/monoid/commit/fd3ebabc587450382c37abfbd790c18432779085) fix(mbui): put the desktop sign-in page in the mid | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.26 | 57.92 |
| [9317c90cd](https://github.com/AFK-surf/monoid/commit/9317c90cd555e7fc587a5737dff0cd737183ed56) fix(mbui): ease the tab bar width as its panel ope | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.26 | 57.8 |
| [2658f9d9c](https://github.com/AFK-surf/monoid/commit/2658f9d9c307b0ba39b50d3078ccf5500708526a) refactor(station-main): extract shared daemon_core | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.26 | 57.64 |
| [e6ec6ddce](https://github.com/AFK-surf/monoid/commit/e6ec6ddce6d21578ca69f00ba64a2df164e86162) perf(station): join screen helper frame pieces onc | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.26 | 57.79 |
| [4064a47f9](https://github.com/AFK-surf/monoid/commit/4064a47f9b0a4977981de67ac39d6a024b13b308) perf(ui): stop waking idle frames for parked or hi | 0.59 | 0.77 | 3.01 | 4.04 | 7.48 | 2.22 | 6.26 | 57.77 |
| [466583200](https://github.com/AFK-surf/monoid/commit/466583200a8a7779268e0506cf2af3efbc35cc63) fix(mbui): take folders only from the chosen stati | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.59 |
| [3b815d77d](https://github.com/AFK-surf/monoid/commit/3b815d77d93bb5255bea32599be7f116c8716304) fix(ci): deduplicate cache-prune listings and pagi | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.59 |
| [686a170c1](https://github.com/AFK-surf/monoid/commit/686a170c1ea9b0e400a6e0ea4bc637c5a46472a9) fix(ui): measure list bands from the rows they fol | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.56 |
| [9b2df4375](https://github.com/AFK-surf/monoid/commit/9b2df437584c5f79c9778d2e3578bfc652a87a68) perf(station): name the session in a slow history  | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.66 |
| [31e518d3a](https://github.com/AFK-surf/monoid/commit/31e518d3ac79355c27990842cea53f90e6273747) fix(mbui): isolate VaultItem plaintext, visibility | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.62 |
| [cc78ae49e](https://github.com/AFK-surf/monoid/commit/cc78ae49ef4d463c7dbc41dc782e1d0424df4de1) feat(mbui): add project-grouped sticky section hea | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.44 |
| [3cf626007](https://github.com/AFK-surf/monoid/commit/3cf62600776cb0d2255954c70948689a826f4560) feat(station-main): wire all 8 CLI subcommands int | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.67 |
| [fde30eb69](https://github.com/AFK-surf/monoid/commit/fde30eb69d56d3cfd39ebfe5ef1b0bcacdcddeda) fix(ui): record keyboard scrolls for row motion ch | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.75 |
| [7cb446b32](https://github.com/AFK-surf/monoid/commit/7cb446b322f2282313dd7bf0686de8a1049c863f) fix(mbui): open the first chat when the startup wa | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.48 |
| [946d4f54c](https://github.com/AFK-surf/monoid/commit/946d4f54c95a38588c97016d8997f0a2125806c6) fix(mbui): include the film build script in the ho | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.53 |
| [a1672fb1e](https://github.com/AFK-surf/monoid/commit/a1672fb1e10a7d2fb9f5c1bf3fb07152ed8724b4) fix(mbui): keep Home rows in place while a chat op | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.46 |
