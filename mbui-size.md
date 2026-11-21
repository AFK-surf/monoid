# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [f82607a79](https://github.com/AFK-surf/monoid/commit/f82607a7983e2ac0e09c37d49cf61ced5a9c43f1) fix(mesh): yield stale transport paths and bound m | 2.79 | 3.77 | 15.33 | 37.45 | 57.97 | 32.82 | 66.96 | 98.29 | 127.37 |
| [f82c45e91](https://github.com/AFK-surf/monoid/commit/f82c45e914c82f87b0e406e054a53248e31d1a53) chore(farview): sync Stage 19A release a00124db8f5 | 2.78 | 3.76 | 15.31 | 37.42 | 57.92 | 32.8 | 66.93 | 98.27 | 124.63 |
| [298439eb4](https://github.com/AFK-surf/monoid/commit/298439eb46de043778d2cbe142ed7e3764903354) fix(mesh): prefer validated direct paths with dire | 2.78 | 3.76 | 15.29 | 37.36 | 57.87 | 32.74 | 66.8 | 98.31 | 122.73 |
| [c877b9401](https://github.com/AFK-surf/monoid/commit/c877b9401b55f30f565af218486c8a0b290941d7) feat(mbui): add iOS 27 capillary liquid bridge mer | 2.78 | 3.75 | 15.29 | 37.35 | 57.86 | 32.74 | 66.76 | 98.49 | 119.09 |
| [ae684ef51](https://github.com/AFK-surf/monoid/commit/ae684ef5190c837baf00bb4d75f7f2d01d8c9b30) perf(mbui): show each frame at once when scrubbing | 2.78 | 3.75 | 15.28 | 37.34 | 57.85 | 32.73 | 66.76 | 98.34 | 120.72 |
| [793585a59](https://github.com/AFK-surf/monoid/commit/793585a59780b2a0a5e419a88ca12af9a75f1e5b) feat(liquid-glass): redesign gallery as ui.monoid  | 2.78 | 3.75 | 15.28 | 37.34 | 57.85 | 32.73 | 66.74 | 98.44 | 123.53 |
| [d80265b89](https://github.com/AFK-surf/monoid/commit/d80265b89d03e34b98135083a05a17d83f2fd73b) fix(mbui): show the exact frame under the finger w | 2.78 | 3.75 | 15.28 | 37.34 | 57.86 | 32.73 | 66.74 | 98.22 | 135.54 |
| [7888eeafc](https://github.com/AFK-surf/monoid/commit/7888eeafcdba3b36d80f7b00c28b6b88d9a7fac9) perf(mbui): migrate single-axis window reads to Vi | 2.78 | 3.75 | 15.28 | 37.35 | 57.86 | 32.73 | 66.74 | 98.24 | 124.79 |
| [2051eb306](https://github.com/AFK-surf/monoid/commit/2051eb306ffd45d7741ff9c52dafc1720240213c) fix(mbui): keep near seeks within a second of the  | 2.78 | 3.75 | 15.28 | 37.35 | 57.86 | 32.73 | 66.74 | 98.24 | 124.79 |
| [f00bc6da4](https://github.com/AFK-surf/monoid/commit/f00bc6da4a5d39ce05f875db5181d95e2b9b6a38) chore(mbui): delete dead sfbase and sfpages Ctx vi | 2.78 | 3.75 | 15.28 | 37.34 | 57.86 | 32.73 | 66.74 | 98.16 | 133.91 |
| [4c3ca1b67](https://github.com/AFK-surf/monoid/commit/4c3ca1b673569c07ac58c1ee7c1e8b6f05dd43f7) perf(mbui): split View::window_w/h signals and mak | 2.78 | 3.75 | 15.28 | 37.34 | 57.86 | 32.73 | 66.74 | 98.26 | 121.96 |
| [7e5d6b10e](https://github.com/AFK-surf/monoid/commit/7e5d6b10e2e97b0971b447e16432f83ab975a3bb) chore(mbui): delete dead settings Ctx views and cl | 2.78 | 3.75 | 15.28 | 37.35 | 57.85 | 32.73 | 66.74 | 98.27 | 131.13 |
| [e410e26d2](https://github.com/AFK-surf/monoid/commit/e410e26d208a829d1aa7e3c6c2026d54c5a3e1c0) feat(mbui): support middle-click to close side pan | 2.77 | 3.75 | 15.27 | 37.34 | 57.83 | 32.72 | 66.73 | 98.39 | 126 |
| [853a27a04](https://github.com/AFK-surf/monoid/commit/853a27a043803c86acdff794affe3ec93840abff) perf(mbui): raise glass blur cache to 32 slots wit | 2.77 | 3.75 | 15.27 | 37.34 | 57.83 | 32.72 | 66.73 | 98.39 | 126 |
| [5b050d6fc](https://github.com/AFK-surf/monoid/commit/5b050d6fc21e5ddbe2d9119f5c5f4f14037d8e42) feat(comma): report quantized owner activity times | 2.77 | 3.75 | 15.27 | 37.34 | 57.83 | 32.72 | 66.73 | 98.39 | 126 |
| [b7304a23f](https://github.com/AFK-surf/monoid/commit/b7304a23f06f6a3388e43bed53dec9b59fbcb60d) fix(mbui): lazily settle moves_for under transitio | 2.77 | 3.74 | 15.24 | 37.3 | 57.72 | 32.7 | 66.65 | 98.09 | 122.24 |
| [f01cb2955](https://github.com/AFK-surf/monoid/commit/f01cb295503137fc410dde9b0611a05443aaaf7b) feat(station): Farview Stage 14A release, farview. | 2.77 | 3.74 | 15.24 | 37.3 | 57.72 | 32.7 | 66.65 | 98.09 | 122.24 |
| [b62885c7a](https://github.com/AFK-surf/monoid/commit/b62885c7a4b0c908f096f39d85bf11a00a2c190c) fix(station): say why a lent profile cannot serve  | 2.77 | 3.74 | 15.24 | 37.3 | 57.72 | 32.69 | 66.65 | 98.42 | 126.19 |
| [b8c850ece](https://github.com/AFK-surf/monoid/commit/b8c850ece362fd8c79db6729999c6b628a0a9eab) chore(mbui): delete unreachable Ctx views from sf- | 2.77 | 3.74 | 15.24 | 37.3 | 57.72 | 32.69 | 66.65 | 98.42 | 126.19 |
| [ede8c9a28](https://github.com/AFK-surf/monoid/commit/ede8c9a2850aae2ce08bc0910afdfb2fab86993f) fix(mbui): use pixel quantization band for sub-hal | 2.77 | 3.74 | 15.24 | 37.3 | 57.72 | 32.69 | 66.65 | 98.42 | 116.32 |
| [99ed258ba](https://github.com/AFK-surf/monoid/commit/99ed258ba77de9070356e1c86ec95ffa268f8891) fix(ci): skip desktop-build cache saves when too l | 2.77 | 3.74 | 15.24 | 37.3 | 57.72 | 32.69 | 66.65 | 98.53 | 126.14 |
| [796c5771d](https://github.com/AFK-surf/monoid/commit/796c5771d8d4cbb36f530c7c264c10dbdc4f1a07) test(station/mb): hold phones' grants and outbox,  | 2.77 | 3.74 | 15.24 | 37.3 | 57.72 | 32.69 | 66.65 | 98.34 | 124.21 |
| [65c250355](https://github.com/AFK-surf/monoid/commit/65c2503556894227c8ec23525eec03eba66017e2) refactor(mbui): remove legacy backdrop_lens and un | 2.77 | 3.74 | 15.24 | 37.3 | 57.72 | 32.69 | 66.65 | 98.5 | 126.42 |
| [72e6bdf52](https://github.com/AFK-surf/monoid/commit/72e6bdf52a4c4f3204622e8fcb12739567fdcfde) feat(station): Farview Stage 13A release, farview. | 2.77 | 3.74 | 15.24 | 37.3 | 57.73 | 32.7 | 66.66 | 98.58 | 127.7 |
| [394d28e5f](https://github.com/AFK-surf/monoid/commit/394d28e5f1c0a32101335be75e593477604cd43f) feat(sf-ui): add built-in zh/en fallback words, op | 2.77 | 3.74 | 15.22 | 37.28 | 57.63 | 32.68 | 66.6 | 98.34 | 121.28 |
| [3ae3dd86c](https://github.com/AFK-surf/monoid/commit/3ae3dd86ca419e0f5dd102be2ecd23062b941450) fix(station): answer a chat's station_move soon, t | 2.76 | 3.73 | 15.2 | 37.27 | 57.57 | 32.68 | 66.56 | 98.8 | 124.6 |
| [1dd0b7818](https://github.com/AFK-surf/monoid/commit/1dd0b7818eb78e33e60e2ba80032311ad1e36576) feat(website): add ui.monoid.build V3 interactive  | 2.76 | 3.73 | 15.19 | 37.27 | 57.55 | 32.67 | 66.55 | 98.35 | 105.82 |
| [e2303813a](https://github.com/AFK-surf/monoid/commit/e2303813ace976914092725ff9cab869cbcfd1a6) fix(mbui): place fresh rows past carried rows and  | 2.76 | 3.73 | 15.19 | 37.27 | 57.55 | 32.67 | 66.55 | 98.35 | 105.82 |
| [442ec2eb0](https://github.com/AFK-surf/monoid/commit/442ec2eb03ab6ff866b384611713211ec720e1ce) perf(mbui): bring WebGL2 host to parity with nativ | 2.76 | 3.73 | 15.19 | 37.27 | 57.55 | 32.67 | 66.55 | 98.35 | 105.82 |
| [5799e3d5b](https://github.com/AFK-surf/monoid/commit/5799e3d5b5e6382838e822d460cc99f5cb0f83d0) chore(farview): bump Stage 12A release (cf0d2d2736 | 2.76 | 3.73 | 15.19 | 37.27 | 57.55 | 32.67 | 66.55 | 98.35 | 105.82 |
| [faab03fb6](https://github.com/AFK-surf/monoid/commit/faab03fb646501b107bb8e3f2586582529e1d78d) fix(mbui): align scrollbars to container edges and | 2.76 | 3.73 | 15.18 | 37.27 | 57.54 | 32.67 | 66.53 | 98.14 | 120.72 |
| [5cea23eb8](https://github.com/AFK-surf/monoid/commit/5cea23eb8370d3e034cf3ca338e7115e1492c05e) fix(vault): hand vaults over at pairing without wa | 2.76 | 3.73 | 15.18 | 37.27 | 57.54 | 32.67 | 66.53 | 98.14 | 120.72 |
| [b2818f70e](https://github.com/AFK-surf/monoid/commit/b2818f70e9502a25b61a973c99504284f9a3d5a5) perf(station): bound MoonBit storage upkeep on lar | 2.76 | 3.73 | 15.18 | 37.27 | 57.54 | 32.67 | 66.53 | 98.22 | 123.74 |
| [27dc5efa7](https://github.com/AFK-surf/monoid/commit/27dc5efa790632a00dd97784061b58f680d6355f) fix(station): treat an Antigravity account held fo | 2.76 | 3.73 | 15.18 | 37.27 | 57.54 | 32.67 | 66.53 | 98.21 | 122.88 |
| [9b61589f6](https://github.com/AFK-surf/monoid/commit/9b61589f6a4a651103abc7b17fd0df268db3b21a) perf(mbui): drop dead sharp backdrop level and ena | 2.76 | 3.73 | 15.18 | 37.26 | 57.53 | 32.67 | 66.53 | 98.26 | 122.81 |
| [05ca57c9c](https://github.com/AFK-surf/monoid/commit/05ca57c9c0e1ea864891e03d6ca938ccb4f4838e) fix(mbui): decode an image again when its key gets | 2.76 | 3.73 | 15.18 | 37.26 | 57.53 | 32.67 | 66.53 | 98.26 | 122.81 |
| [99884b6e3](https://github.com/AFK-surf/monoid/commit/99884b6e37139704f2119e65eecee3ae59f1bdeb) fix(mesh): enforce relay allowlist on client endpo | 2.76 | 3.73 | 15.18 | 37.26 | 57.53 | 32.67 | 66.53 | 98.26 | 122.81 |
| [6d19980fa](https://github.com/AFK-surf/monoid/commit/6d19980fa800cf2f775045f29ca86df9ceb3a0a4) ci(preview): start windows host checks before the  | 2.76 | 3.73 | 15.18 | 37.26 | 57.53 | 32.65 | 66.51 | 98.22 | 121.84 |
| [ee0907d04](https://github.com/AFK-surf/monoid/commit/ee0907d0429d86dc7e6806861c6164144d30833c) fix(station): support thumb=2 preview images in Mo | 2.76 | 3.73 | 15.18 | 37.26 | 57.53 | 32.65 | 66.51 | 98.47 | 115.64 |
| [2cb7928bb](https://github.com/AFK-surf/monoid/commit/2cb7928bb32e111f58e9cdbeef9cc78b48b5dfe4) fix(mbui): forget glyph keys shaped before the fir | 2.76 | 3.73 | 15.18 | 37.26 | 57.53 | 32.66 | 66.51 | 98.29 | 121.9 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [f82607a79](https://github.com/AFK-surf/monoid/commit/f82607a7983e2ac0e09c37d49cf61ced5a9c43f1) fix(mesh): yield stale transport paths and bound m | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.71 | 4.62 | 54.08 |
| [f82c45e91](https://github.com/AFK-surf/monoid/commit/f82c45e914c82f87b0e406e054a53248e31d1a53) chore(farview): sync Stage 19A release a00124db8f5 | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.71 | 4.62 | 54.08 |
| [298439eb4](https://github.com/AFK-surf/monoid/commit/298439eb46de043778d2cbe142ed7e3764903354) fix(mesh): prefer validated direct paths with dire | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.71 | 4.62 | 54.08 |
| [c877b9401](https://github.com/AFK-surf/monoid/commit/c877b9401b55f30f565af218486c8a0b290941d7) feat(mbui): add iOS 27 capillary liquid bridge mer | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.71 | 4.62 | 54.08 |
| [ae684ef51](https://github.com/AFK-surf/monoid/commit/ae684ef5190c837baf00bb4d75f7f2d01d8c9b30) perf(mbui): show each frame at once when scrubbing | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.71 | 4.62 | 54.22 |
| [793585a59](https://github.com/AFK-surf/monoid/commit/793585a59780b2a0a5e419a88ca12af9a75f1e5b) feat(liquid-glass): redesign gallery as ui.monoid  | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 54.15 |
| [d80265b89](https://github.com/AFK-surf/monoid/commit/d80265b89d03e34b98135083a05a17d83f2fd73b) fix(mbui): show the exact frame under the finger w | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 54.15 |
| [7888eeafc](https://github.com/AFK-surf/monoid/commit/7888eeafcdba3b36d80f7b00c28b6b88d9a7fac9) perf(mbui): migrate single-axis window reads to Vi | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 54.15 |
| [2051eb306](https://github.com/AFK-surf/monoid/commit/2051eb306ffd45d7741ff9c52dafc1720240213c) fix(mbui): keep near seeks within a second of the  | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 54.07 |
| [f00bc6da4](https://github.com/AFK-surf/monoid/commit/f00bc6da4a5d39ce05f875db5181d95e2b9b6a38) chore(mbui): delete dead sfbase and sfpages Ctx vi | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 54.02 |
| [4c3ca1b67](https://github.com/AFK-surf/monoid/commit/4c3ca1b673569c07ac58c1ee7c1e8b6f05dd43f7) perf(mbui): split View::window_w/h signals and mak | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 54.02 |
| [7e5d6b10e](https://github.com/AFK-surf/monoid/commit/7e5d6b10e2e97b0971b447e16432f83ab975a3bb) chore(mbui): delete dead settings Ctx views and cl | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 54.02 |
| [e410e26d2](https://github.com/AFK-surf/monoid/commit/e410e26d208a829d1aa7e3c6c2026d54c5a3e1c0) feat(mbui): support middle-click to close side pan | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 54.02 |
| [853a27a04](https://github.com/AFK-surf/monoid/commit/853a27a043803c86acdff794affe3ec93840abff) perf(mbui): raise glass blur cache to 32 slots wit | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 53.95 |
| [5b050d6fc](https://github.com/AFK-surf/monoid/commit/5b050d6fc21e5ddbe2d9119f5c5f4f14037d8e42) feat(comma): report quantized owner activity times | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 54 |
| [b7304a23f](https://github.com/AFK-surf/monoid/commit/b7304a23f06f6a3388e43bed53dec9b59fbcb60d) fix(mbui): lazily settle moves_for under transitio | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.6 | 54 |
| [f01cb2955](https://github.com/AFK-surf/monoid/commit/f01cb295503137fc410dde9b0611a05443aaaf7b) feat(station): Farview Stage 14A release, farview. | 0.47 | 0.61 | 2.36 | 3.4 | 5.59 | 1.7 | 4.6 | 53.89 |
| [b62885c7a](https://github.com/AFK-surf/monoid/commit/b62885c7a4b0c908f096f39d85bf11a00a2c190c) fix(station): say why a lent profile cannot serve  | 0.47 | 0.61 | 2.36 | 3.4 | 5.59 | 1.7 | 4.6 | 53.89 |
| [b8c850ece](https://github.com/AFK-surf/monoid/commit/b8c850ece362fd8c79db6729999c6b628a0a9eab) chore(mbui): delete unreachable Ctx views from sf- | 0.46 | 0.61 | 2.36 | 3.4 | 5.58 | 1.7 | 4.6 | 54.25 |
| [ede8c9a28](https://github.com/AFK-surf/monoid/commit/ede8c9a2850aae2ce08bc0910afdfb2fab86993f) fix(mbui): use pixel quantization band for sub-hal | 0.46 | 0.61 | 2.36 | 3.4 | 5.58 | 1.7 | 4.6 | 54.25 |
| [99ed258ba](https://github.com/AFK-surf/monoid/commit/99ed258ba77de9070356e1c86ec95ffa268f8891) fix(ci): skip desktop-build cache saves when too l | 0.46 | 0.61 | 2.36 | 3.4 | 5.58 | 1.7 | 4.6 | 54.1 |
| [796c5771d](https://github.com/AFK-surf/monoid/commit/796c5771d8d4cbb36f530c7c264c10dbdc4f1a07) test(station/mb): hold phones' grants and outbox,  | 0.46 | 0.61 | 2.36 | 3.4 | 5.58 | 1.7 | 4.6 | 54.1 |
| [65c250355](https://github.com/AFK-surf/monoid/commit/65c2503556894227c8ec23525eec03eba66017e2) refactor(mbui): remove legacy backdrop_lens and un | 0.46 | 0.61 | 2.36 | 3.4 | 5.58 | 1.7 | 4.6 | 54.1 |
| [72e6bdf52](https://github.com/AFK-surf/monoid/commit/72e6bdf52a4c4f3204622e8fcb12739567fdcfde) feat(station): Farview Stage 13A release, farview. | 0.46 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.12 |
| [394d28e5f](https://github.com/AFK-surf/monoid/commit/394d28e5f1c0a32101335be75e593477604cd43f) feat(sf-ui): add built-in zh/en fallback words, op | 0.46 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.12 |
| [3ae3dd86c](https://github.com/AFK-surf/monoid/commit/3ae3dd86ca419e0f5dd102be2ecd23062b941450) fix(station): answer a chat's station_move soon, t | 0.46 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.12 |
| [1dd0b7818](https://github.com/AFK-surf/monoid/commit/1dd0b7818eb78e33e60e2ba80032311ad1e36576) feat(website): add ui.monoid.build V3 interactive  | 0.46 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.12 |
| [e2303813a](https://github.com/AFK-surf/monoid/commit/e2303813ace976914092725ff9cab869cbcfd1a6) fix(mbui): place fresh rows past carried rows and  | 0.46 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.08 |
| [442ec2eb0](https://github.com/AFK-surf/monoid/commit/442ec2eb03ab6ff866b384611713211ec720e1ce) perf(mbui): bring WebGL2 host to parity with nativ | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.05 |
| [5799e3d5b](https://github.com/AFK-surf/monoid/commit/5799e3d5b5e6382838e822d460cc99f5cb0f83d0) chore(farview): bump Stage 12A release (cf0d2d2736 | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.05 |
| [faab03fb6](https://github.com/AFK-surf/monoid/commit/faab03fb646501b107bb8e3f2586582529e1d78d) fix(mbui): align scrollbars to container edges and | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.05 |
| [5cea23eb8](https://github.com/AFK-surf/monoid/commit/5cea23eb8370d3e034cf3ca338e7115e1492c05e) fix(vault): hand vaults over at pairing without wa | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.25 |
| [b2818f70e](https://github.com/AFK-surf/monoid/commit/b2818f70e9502a25b61a973c99504284f9a3d5a5) perf(station): bound MoonBit storage upkeep on lar | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.25 |
| [27dc5efa7](https://github.com/AFK-surf/monoid/commit/27dc5efa790632a00dd97784061b58f680d6355f) fix(station): treat an Antigravity account held fo | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.25 |
| [9b61589f6](https://github.com/AFK-surf/monoid/commit/9b61589f6a4a651103abc7b17fd0df268db3b21a) perf(mbui): drop dead sharp backdrop level and ena | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.25 |
| [05ca57c9c](https://github.com/AFK-surf/monoid/commit/05ca57c9c0e1ea864891e03d6ca938ccb4f4838e) fix(mbui): decode an image again when its key gets | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.2 |
| [99884b6e3](https://github.com/AFK-surf/monoid/commit/99884b6e37139704f2119e65eecee3ae59f1bdeb) fix(mesh): enforce relay allowlist on client endpo | 0.46 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.2 |
| [6d19980fa](https://github.com/AFK-surf/monoid/commit/6d19980fa800cf2f775045f29ca86df9ceb3a0a4) ci(preview): start windows host checks before the  | 0.46 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.2 |
| [ee0907d04](https://github.com/AFK-surf/monoid/commit/ee0907d0429d86dc7e6806861c6164144d30833c) fix(station): support thumb=2 preview images in Mo | 0.46 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.2 |
| [2cb7928bb](https://github.com/AFK-surf/monoid/commit/2cb7928bb32e111f58e9cdbeef9cc78b48b5dfe4) fix(mbui): forget glyph keys shaped before the fir | 0.46 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.2 |
