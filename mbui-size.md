# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [c045a928e](https://github.com/AFK-surf/monoid/commit/c045a928e75f6125dd4a471b95abb7a6639f4a64) feat(cloud,core,app): allow managers to switch sta | 2.76 | 3.73 | 15.18 | 37.26 | 57.53 | 32.66 | 66.51 | 98.29 | 121.9 |
| [bf467b14a](https://github.com/AFK-surf/monoid/commit/bf467b14a768cb2e247ae9180e95b11574a39c1b) fix(station): revert default maxConcurrentTurns ba | 2.76 | 3.73 | 15.18 | 37.26 | 57.53 | 32.66 | 66.51 | 98.32 | 121.42 |
| [628f68ea9](https://github.com/AFK-surf/monoid/commit/628f68ea93b9a6d11bb18a16d7625484d83f93f2) fix(mbui): skip sharp copy/overdraw for backdrop_l | 2.76 | 3.73 | 15.17 | 37.24 | 57.51 | 32.58 | 66.33 | 98.44 | 126.44 |
| [7ff2df2a5](https://github.com/AFK-surf/monoid/commit/7ff2df2a5b9e69afc1450d292ab1861e2e68419c) feat(mbui): port iOS 27 flutter_liquid_glass model | 2.75 | 3.71 | 15.09 | 37.17 | 57.27 | 32.58 | 66.33 | 98.44 | 121.64 |
| [69bc50c72](https://github.com/AFK-surf/monoid/commit/69bc50c723914f1c5016dc9975dd43303bffce25) fix(core-ts): match multi-word search, sort chats  | 2.75 | 3.71 | 15.09 | 37.17 | 57.27 | 32.58 | 66.33 | 98.44 | 121.64 |
| [b254297ee](https://github.com/AFK-surf/monoid/commit/b254297eec986c271ce504c0b024baea014545f2) feat(station): Farview Stage 11A release, farview. | 2.75 | 3.71 | 15.09 | 37.17 | 57.27 | 32.58 | 66.33 | 98.44 | 121.64 |
| [e253c7ef7](https://github.com/AFK-surf/monoid/commit/e253c7ef7307cbcf4767ee53385ab6bdbef9f105) fix(mbui): title the web app's tab with the page's | 2.75 | 3.71 | 15.09 | 37.17 | 57.27 | 32.58 | 66.33 | 98.44 | 121.64 |
| [e5bdea018](https://github.com/AFK-surf/monoid/commit/e5bdea01886282646562dd77f3ddd9541a173f57) fix(station): keep connect files whole and route o | 2.75 | 3.71 | 15.09 | 37.17 | 57.27 | 32.58 | 66.33 | 98.44 | 121.64 |
| [1b662c64f](https://github.com/AFK-surf/monoid/commit/1b662c64f2cddd9f80850033cc8e95980d1f6a19) fix(station/mb): send a hand-over's requests throu | 2.74 | 3.71 | 15.07 | 37.14 | 57.19 | 32.56 | 66.28 | 98.39 | 137.8 |
| [fca46308b](https://github.com/AFK-surf/monoid/commit/fca46308bfbad979e59e669a04acf61a7d55ccce) fix(mbui): free what native reference counting kep | 2.74 | 3.71 | 15.07 | 37.14 | 57.19 | 32.56 | 66.28 | 98.39 | 137.8 |
| [2d3ee743e](https://github.com/AFK-surf/monoid/commit/2d3ee743e38777838fe0ff0dcec868d6ed68e1c8) fix(station): end the usage programs and live loca | 2.74 | 3.71 | 15.07 | 37.14 | 57.19 | 32.56 | 66.28 | 98.39 | 137.8 |
| [bdfa0f80a](https://github.com/AFK-surf/monoid/commit/bdfa0f80a4e691ba3ed1cbfb717411a3636b11ca) fix(mbui): free host VRAM when glass goes idle and | 2.74 | 3.71 | 15.07 | 37.14 | 57.19 | 32.56 | 66.28 | 97.96 | 116.44 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [c045a928e](https://github.com/AFK-surf/monoid/commit/c045a928e75f6125dd4a471b95abb7a6639f4a64) feat(cloud,core,app): allow managers to switch sta | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.05 |
| [bf467b14a](https://github.com/AFK-surf/monoid/commit/bf467b14a768cb2e247ae9180e95b11574a39c1b) fix(station): revert default maxConcurrentTurns ba | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.05 |
| [628f68ea9](https://github.com/AFK-surf/monoid/commit/628f68ea93b9a6d11bb18a16d7625484d83f93f2) fix(mbui): skip sharp copy/overdraw for backdrop_l | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.05 |
| [7ff2df2a5](https://github.com/AFK-surf/monoid/commit/7ff2df2a5b9e69afc1450d292ab1861e2e68419c) feat(mbui): port iOS 27 flutter_liquid_glass model | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 54.05 |
| [69bc50c72](https://github.com/AFK-surf/monoid/commit/69bc50c723914f1c5016dc9975dd43303bffce25) fix(core-ts): match multi-word search, sort chats  | 0.47 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 53.87 |
| [b254297ee](https://github.com/AFK-surf/monoid/commit/b254297eec986c271ce504c0b024baea014545f2) feat(station): Farview Stage 11A release, farview. | 0.46 | 0.61 | 2.36 | 3.41 | 5.59 | 1.7 | 4.61 | 53.81 |
| [e253c7ef7](https://github.com/AFK-surf/monoid/commit/e253c7ef7307cbcf4767ee53385ab6bdbef9f105) fix(mbui): title the web app's tab with the page's | 0.46 | 0.61 | 2.35 | 3.4 | 5.59 | 1.7 | 4.6 | 53.92 |
| [e5bdea018](https://github.com/AFK-surf/monoid/commit/e5bdea01886282646562dd77f3ddd9541a173f57) fix(station): keep connect files whole and route o | 0.46 | 0.61 | 2.35 | 3.4 | 5.59 | 1.7 | 4.6 | 54.2 |
| [1b662c64f](https://github.com/AFK-surf/monoid/commit/1b662c64f2cddd9f80850033cc8e95980d1f6a19) fix(station/mb): send a hand-over's requests throu | 0.46 | 0.61 | 2.35 | 3.4 | 5.59 | 1.7 | 4.6 | 54.2 |
| [fca46308b](https://github.com/AFK-surf/monoid/commit/fca46308bfbad979e59e669a04acf61a7d55ccce) fix(mbui): free what native reference counting kep | 0.46 | 0.61 | 2.35 | 3.4 | 5.59 | 1.7 | 4.6 | 54.18 |
| [2d3ee743e](https://github.com/AFK-surf/monoid/commit/2d3ee743e38777838fe0ff0dcec868d6ed68e1c8) fix(station): end the usage programs and live loca | 0.46 | 0.61 | 2.34 | 3.4 | 5.54 | 1.7 | 4.58 | 54.2 |
| [bdfa0f80a](https://github.com/AFK-surf/monoid/commit/bdfa0f80a4e691ba3ed1cbfb717411a3636b11ca) fix(mbui): free host VRAM when glass goes idle and | 0.46 | 0.61 | 2.34 | 3.4 | 5.54 | 1.7 | 4.58 | 54.2 |
