# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [d96ca5075](https://github.com/AFK-surf/monoid/commit/d96ca50756a20b86f0b1c886aa30b228ab81ca55) perf(ui): batch & prewarm WebGL2 shaders and strip | 2.65 | 3.58 | 14.86 | 37.77 | 57.83 | 33.09 | 67.67 | 101.61 | 115.48 |
| [870cca361](https://github.com/AFK-surf/monoid/commit/870cca3611e275db49bda34c6182af9a443a5883) feat(station-main): assemble pure-Pion roles:rig d | 2.65 | 3.58 | 14.86 | 37.77 | 57.83 | 33.09 | 67.67 | 101.98 | 115.27 |
| [be4a9e8eb](https://github.com/AFK-surf/monoid/commit/be4a9e8eb72735551e96495fa6d12a247039a6e9) feat(ui): let the reader's layout choose the colum | 2.65 | 3.58 | 14.86 | 37.77 | 57.83 | 33.09 | 67.67 | 101.98 | 115.27 |
| [2021aa205](https://github.com/AFK-surf/monoid/commit/2021aa205b0ea1a380250e4b8cdd30f2211d1f96) fix(ui): check text coverage at the drawn corners  | 2.65 | 3.58 | 14.86 | 37.77 | 57.82 | 33.09 | 67.65 | 101.7 | 131.79 |
| [2fa36d827](https://github.com/AFK-surf/monoid/commit/2fa36d827b55adccfd88b88f9da55dec6d67b835) fix(mbc): build readable debug symbols for empty M | 2.65 | 3.58 | 14.86 | 37.77 | 57.82 | 33.09 | 67.65 | 101.68 | 128.91 |
| [663f65061](https://github.com/AFK-surf/monoid/commit/663f65061c4469b33bffa414095e4a0863b0fcb6) fix(ui): read a Markdown file in a document's colu | 2.65 | 3.58 | 14.86 | 37.77 | 57.82 | 33.09 | 67.65 | 101.68 | 128.91 |
| [319502a40](https://github.com/AFK-surf/monoid/commit/319502a40be7de383f75e17dd1e8e1437d6cbb7c) fix(ui): close a pill menu from its current bounds | 2.65 | 3.58 | 14.86 | 37.77 | 57.82 | 33.09 | 67.65 | 101.94 | 131.62 |
| [9d89a5167](https://github.com/AFK-surf/monoid/commit/9d89a5167fc31fc98cb86e10417e0b684067e54b) perf(station): tell many viewers the overview with | 2.65 | 3.58 | 14.86 | 37.77 | 57.82 | 33.09 | 67.65 | 101.48 | 130.27 |
| [13045bc24](https://github.com/AFK-surf/monoid/commit/13045bc2458349f5a57a7bcb19335c969b994954) feat(ui): complete rest/wake state machine, park-a | 2.65 | 3.58 | 14.86 | 37.77 | 57.82 | 33.09 | 67.65 | 101.48 | 130.27 |
| [bf32a2d88](https://github.com/AFK-surf/monoid/commit/bf32a2d884598c30ce17eaddf4032bad1ae3d870) test(mbui): replay draft recovery after the core s | 2.64 | 3.57 | 14.78 | 37.74 | 57.62 | 33.05 | 67.5 | 101.79 | 129.3 |
| [1afb96bec](https://github.com/AFK-surf/monoid/commit/1afb96bec74ed022c8ac2856f9526d6578da8830) feat(station): bundle and sign opt-in stillfail-st | 2.64 | 3.57 | 14.78 | 37.74 | 57.62 | 33.05 | 67.5 | 101.65 | 131.48 |
| [d79f39aa4](https://github.com/AFK-surf/monoid/commit/d79f39aa42f44a7379be26c2ec3297218e6fc561) fix(mbui): build the Apple core for local Mac e2e  | 2.64 | 3.57 | 14.78 | 37.74 | 57.62 | 33.05 | 67.5 | 101.6 | 129.9 |
| [4434a902f](https://github.com/AFK-surf/monoid/commit/4434a902ffce7f55898c765c51cfc73bf6ad5c6e) perf(ui,mbui): optimize composite CJK text shaping | 2.64 | 3.57 | 14.78 | 37.74 | 57.62 | 33.05 | 67.5 | 101.6 | 129.9 |
| [199a359ec](https://github.com/AFK-surf/monoid/commit/199a359ec39bdd4f6691d5b6b1474c5f6249cadf) fix(ci): keep the halt reason in native test failu | 2.64 | 3.57 | 14.77 | 37.74 | 57.6 | 33.05 | 67.49 | 101.6 | 115.56 |
| [fd365a890](https://github.com/AFK-surf/monoid/commit/fd365a8905602c0900cc39f1e3bf2082ece52000) fix(mbui): keep board counts until the selected fi | 2.64 | 3.57 | 14.77 | 37.74 | 57.6 | 33.05 | 67.49 | 101.6 | 115.56 |
| [cd0edb6e8](https://github.com/AFK-surf/monoid/commit/cd0edb6e80aad3fa4d02d37c8031a8b3731f0bc4) feat(pion): add station_screens and drive local ca | 2.64 | 3.57 | 14.77 | 37.74 | 57.6 | 33.04 | 67.49 | 101.6 | 115.56 |
| [6d2dde849](https://github.com/AFK-surf/monoid/commit/6d2dde849a64e852ad97a3a8a9402628715f0b59) fix(station): remove runner json sentinel last and | 2.64 | 3.57 | 14.77 | 37.73 | 57.6 | 33.04 | 67.49 | 101.65 | 129.36 |
| [ff922a134](https://github.com/AFK-surf/monoid/commit/ff922a134ea9482152559b010335530ccf90eda1) test(ui): synchronize WARP with a D3D11 event quer | 2.64 | 3.57 | 14.77 | 37.73 | 57.6 | 33.04 | 67.49 | 101.65 | 125.33 |
| [f59c98985](https://github.com/AFK-surf/monoid/commit/f59c98985161e7ddfcf6f14da6017cbde219415e) refactor(core,mbui): unify 125-topic policy table  | 2.64 | 3.57 | 14.77 | 37.73 | 57.6 | 33.04 | 67.49 | 101.65 | 125.33 |
| [c76f57771](https://github.com/AFK-surf/monoid/commit/c76f5777167157b08f93aae71073e90428e54cd4) feat(shell): add image.thumb operation for station | 2.64 | 3.57 | 14.77 | 37.73 | 57.6 | 33.04 | 67.49 | 101.65 | 125.33 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [d96ca5075](https://github.com/AFK-surf/monoid/commit/d96ca50756a20b86f0b1c886aa30b228ab81ca55) perf(ui): batch & prewarm WebGL2 shaders and strip | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.82 |
| [870cca361](https://github.com/AFK-surf/monoid/commit/870cca3611e275db49bda34c6182af9a443a5883) feat(station-main): assemble pure-Pion roles:rig d | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.57 |
| [be4a9e8eb](https://github.com/AFK-surf/monoid/commit/be4a9e8eb72735551e96495fa6d12a247039a6e9) feat(ui): let the reader's layout choose the colum | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.74 |
| [2021aa205](https://github.com/AFK-surf/monoid/commit/2021aa205b0ea1a380250e4b8cdd30f2211d1f96) fix(ui): check text coverage at the drawn corners  | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.53 |
| [2fa36d827](https://github.com/AFK-surf/monoid/commit/2fa36d827b55adccfd88b88f9da55dec6d67b835) fix(mbc): build readable debug symbols for empty M | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.79 |
| [663f65061](https://github.com/AFK-surf/monoid/commit/663f65061c4469b33bffa414095e4a0863b0fcb6) fix(ui): read a Markdown file in a document's colu | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.61 |
| [319502a40](https://github.com/AFK-surf/monoid/commit/319502a40be7de383f75e17dd1e8e1437d6cbb7c) fix(ui): close a pill menu from its current bounds | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.59 |
| [9d89a5167](https://github.com/AFK-surf/monoid/commit/9d89a5167fc31fc98cb86e10417e0b684067e54b) perf(station): tell many viewers the overview with | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.38 |
| [13045bc24](https://github.com/AFK-surf/monoid/commit/13045bc2458349f5a57a7bcb19335c969b994954) feat(ui): complete rest/wake state machine, park-a | 0.59 | 0.77 | 3.01 | 4.04 | 7.47 | 2.22 | 6.26 | 57.75 |
| [bf32a2d88](https://github.com/AFK-surf/monoid/commit/bf32a2d884598c30ce17eaddf4032bad1ae3d870) test(mbui): replay draft recovery after the core s | 0.59 | 0.77 | 2.98 | 4.02 | 7.42 | 2.21 | 6.24 | 57.67 |
| [1afb96bec](https://github.com/AFK-surf/monoid/commit/1afb96bec74ed022c8ac2856f9526d6578da8830) feat(station): bundle and sign opt-in stillfail-st | 0.59 | 0.77 | 2.98 | 4.02 | 7.42 | 2.21 | 6.24 | 57.48 |
| [d79f39aa4](https://github.com/AFK-surf/monoid/commit/d79f39aa42f44a7379be26c2ec3297218e6fc561) fix(mbui): build the Apple core for local Mac e2e  | 0.59 | 0.77 | 2.98 | 4.02 | 7.42 | 2.21 | 6.24 | 57.61 |
| [4434a902f](https://github.com/AFK-surf/monoid/commit/4434a902ffce7f55898c765c51cfc73bf6ad5c6e) perf(ui,mbui): optimize composite CJK text shaping | 0.59 | 0.77 | 2.98 | 4.02 | 7.42 | 2.21 | 6.24 | 57.57 |
| [199a359ec](https://github.com/AFK-surf/monoid/commit/199a359ec39bdd4f6691d5b6b1474c5f6249cadf) fix(ci): keep the halt reason in native test failu | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.72 |
| [fd365a890](https://github.com/AFK-surf/monoid/commit/fd365a8905602c0900cc39f1e3bf2082ece52000) fix(mbui): keep board counts until the selected fi | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.59 |
| [cd0edb6e8](https://github.com/AFK-surf/monoid/commit/cd0edb6e80aad3fa4d02d37c8031a8b3731f0bc4) feat(pion): add station_screens and drive local ca | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.59 |
| [6d2dde849](https://github.com/AFK-surf/monoid/commit/6d2dde849a64e852ad97a3a8a9402628715f0b59) fix(station): remove runner json sentinel last and | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.74 |
| [ff922a134](https://github.com/AFK-surf/monoid/commit/ff922a134ea9482152559b010335530ccf90eda1) test(ui): synchronize WARP with a D3D11 event quer | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.64 |
| [f59c98985](https://github.com/AFK-surf/monoid/commit/f59c98985161e7ddfcf6f14da6017cbde219415e) refactor(core,mbui): unify 125-topic policy table  | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.66 |
| [c76f57771](https://github.com/AFK-surf/monoid/commit/c76f5777167157b08f93aae71073e90428e54cd4) feat(shell): add image.thumb operation for station | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.57 |
