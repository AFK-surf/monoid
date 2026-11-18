# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [9fe2303fd](https://github.com/AFK-surf/monoid/commit/9fe2303fd4ab738aaaf7db52da58975505202b0c) fix(screens): coalesce unsent pointer moves, recov | 2.56 | 3.44 | 14.07 | 36.02 | 54.15 | 31.58 | 63.66 | 96.75 | 118.31 |
| [b5c70cdc0](https://github.com/AFK-surf/monoid/commit/b5c70cdc09495a54107ea7d332195db61b15967f) fix(mbui): keep a Windows video's frame shown thro | 2.56 | 3.43 | 14.07 | 36.01 | 54.14 | 31.58 | 63.66 | 96.58 | 115.97 |
| [e31f5a37f](https://github.com/AFK-surf/monoid/commit/e31f5a37f32c446b9035c32514dd3f6b1c924d7f) fix(mbui): a mouse's drag scrolls no table or code | 2.56 | 3.43 | 14.07 | 36.01 | 54.14 | 31.58 | 63.66 | 96.58 | 115.97 |
| [ac966624e](https://github.com/AFK-surf/monoid/commit/ac966624e16dc0445e669ae4abf3aeb967b738b1) feat(base): verify Ed25519 fast on js, add a page' | 2.56 | 3.43 | 14.07 | 36.01 | 54.14 | 31.58 | 63.66 | 96.52 | 117.79 |
| [f27e63953](https://github.com/AFK-surf/monoid/commit/f27e6395317734d5b5ea6e79971a7c5b1a76ffc0) fix(core): a chat whose first message did not go c | 2.56 | 3.43 | 14.07 | 36.01 | 54.14 | 31.58 | 63.66 | 96.8 | 107.44 |
| [cd1158577](https://github.com/AFK-surf/monoid/commit/cd11585774d1d8f291d7cc75e45dc8815dc79614) feat(mbui app): write a new 待派发 task in the chat's | 2.56 | 3.43 | 14.07 | 36.01 | 54.14 | 31.58 | 63.66 | 96.8 | 107.44 |
| [fab5e0c17](https://github.com/AFK-surf/monoid/commit/fab5e0c176b47cb65cb966a352dbcc3057780d4d) feat(mbui): add hover_reveal, tooltip glide origin | 2.56 | 3.43 | 14.07 | 36.01 | 54.15 | 31.58 | 63.66 | 96.6 | 120.98 |
| [babed3f66](https://github.com/AFK-surf/monoid/commit/babed3f663c4e1148c4f4975fb26ad576c032056) fix(mbui): open the right soft keyboard on one tap | 2.56 | 3.43 | 14.07 | 36.01 | 54.15 | 31.58 | 63.66 | 96.6 | 120.98 |
| [f03c25025](https://github.com/AFK-surf/monoid/commit/f03c2502589f6146209a3b49d3dff982ea0244e8) test(station): the whole MoonBit station tells a d | 2.56 | 3.43 | 14.07 | 36.01 | 54.15 | 31.58 | 63.66 | 96.78 | 117.45 |
| [a78791d91](https://github.com/AFK-surf/monoid/commit/a78791d9124a36a6dd422ec5f41a80f955be7844) fix(mbui): keep the segmented thumb moving through | 2.56 | 3.43 | 14.07 | 36.01 | 54.15 | 31.58 | 63.66 | 96.78 | 117.45 |
| [fee058d70](https://github.com/AFK-surf/monoid/commit/fee058d70bc98ff76618b35e38dbb6dc14a8177d) fix(mbc): keep framework units at -O2 in light sfa | 2.55 | 3.43 | 14.07 | 36.01 | 54.15 | 31.58 | 63.66 | 96.75 | 117.45 |
| [1104afa35](https://github.com/AFK-surf/monoid/commit/1104afa35e5423f3d9cd9a5752dea86bf43fd679) fix(cloud): a push says what was said as plain wor | 2.55 | 3.43 | 14.07 | 36.01 | 54.15 | 31.58 | 63.66 | 96.75 | 117.45 |
| [33815598f](https://github.com/AFK-surf/monoid/commit/33815598fcddcaa323fa0367afb4e3849a636178) mbui app: a chat's composer made as nodes, whole ( | 2.55 | 3.43 | 14.07 | 36.01 | 54.15 | 31.58 | 63.66 | 96.54 | 117.45 |
| [7c3c797b7](https://github.com/AFK-surf/monoid/commit/7c3c797b72fdc40941ae12bec151b4d7cc83d199) fix(mbui): pick a preset's model on the composer's | 2.55 | 3.42 | 14.02 | 35.94 | 53.91 | 31.52 | 63.46 | 96.77 | 117.45 |
| [3a3bad347](https://github.com/AFK-surf/monoid/commit/3a3bad34737a5401bc21aa71b0b1e3b3de1bde99) fix(station): the front takes a Node's new protoco | 2.55 | 3.42 | 14.02 | 35.94 | 53.91 | 31.52 | 63.46 | 96.73 | 117.45 |
| [3db36a227](https://github.com/AFK-surf/monoid/commit/3db36a227d053592a4b2e1a13fc1476daad9ff67) fix(mbui): background Android test activity via HO | 2.55 | 3.42 | 14.02 | 35.94 | 53.91 | 31.51 | 63.46 | 96.75 | 117.45 |
| [88d08d335](https://github.com/AFK-surf/monoid/commit/88d08d3354e8f4899fbda352f14ca5641515bf68) fix(station): a chat named is not asked to name it | 2.55 | 3.42 | 14.02 | 35.94 | 53.91 | 31.5 | 63.41 | 96.77 | 117.45 |
| [089f33f94](https://github.com/AFK-surf/monoid/commit/089f33f94c8f48ec0c8d9f616c3ef3bd032efe2e) fix(ci): replace undici fetch in release-deltas to | 2.55 | 3.42 | 14.02 | 35.95 | 53.9 | 31.5 | 63.41 | 96.77 | 117.45 |
| [96fae6be6](https://github.com/AFK-surf/monoid/commit/96fae6be63bc71ff0c9597648b9af1ff6b008928) mbui: a chat's words broken anew as the side panel | 2.54 | 3.42 | 14 | 35.93 | 53.86 | 31.5 | 63.41 | 96.77 | 117.45 |
| [47562f9dd](https://github.com/AFK-surf/monoid/commit/47562f9dd2435091c8f4fb111366a4a41fb7f990) fix(mbui): a show shown again by an answer as it c | 2.54 | 3.42 | 14 | 35.93 | 53.86 | 31.5 | 63.41 | 96.77 | 117.45 |
| [bef9e7b69](https://github.com/AFK-surf/monoid/commit/bef9e7b69b9cf6fb3d79fde18093210a51b6c868) fix(station): tell what the threads' store wrote f | 2.54 | 3.42 | 14 | 35.92 | 53.83 | 31.49 | 63.37 | 96.75 | 117.45 |
| [34b88f6c4](https://github.com/AFK-surf/monoid/commit/34b88f6c4ca6ba57b9d48768c8ba518a75d857ed) fix(core): bound pairing code verification reads a | 2.54 | 3.42 | 14 | 35.92 | 53.83 | 31.49 | 63.37 | 96.75 | 117.45 |
| [d61377bd9](https://github.com/AFK-surf/monoid/commit/d61377bd9f7a08047ca54a93486084e276cc880b) fix(mbui): let users swipe between segmented optio | 2.54 | 3.42 | 14 | 35.92 | 53.83 | 31.49 | 63.36 | 96.68 | 117.45 |
| [890460249](https://github.com/AFK-surf/monoid/commit/890460249ac0a2002e44e1a53c1e14be19c02d13) feat(station): the launcher starts the installer t | 2.54 | 3.42 | 14 | 35.92 | 53.83 | 31.49 | 63.36 | 96.68 | 117.45 |
| [13e6f174e](https://github.com/AFK-surf/monoid/commit/13e6f174e360c105172832205fd342177986a7f9) test(station): a station updates itself again afte | 2.54 | 3.42 | 13.99 | 35.92 | 53.82 | 31.49 | 63.36 | 96.68 | 117.45 |
| [2f5363912](https://github.com/AFK-surf/monoid/commit/2f5363912f1a1d6837b16de2c728c060b6da4f95) fix(ci): prefer optimized mbui objects and rebalan | 2.54 | 3.42 | 13.99 | 35.92 | 53.82 | 31.49 | 63.36 | 96.75 | 117.45 |
| [dde626684](https://github.com/AFK-surf/monoid/commit/dde626684c75622e82debae47ca8e3c0a00f0816) revert(station): a release carries the TypeScript  | 2.54 | 3.42 | 13.99 | 35.92 | 53.82 | 31.49 | 63.36 | 96.42 | 117.45 |
| [c8401bba3](https://github.com/AFK-surf/monoid/commit/c8401bba37ffa2bd7704e9449c472a53817f780a) fix(core): open visited chats at their latest page | 2.54 | 3.42 | 13.99 | 35.92 | 53.82 | 31.49 | 63.36 | 96.73 | 117.45 |
| [78d07191c](https://github.com/AFK-surf/monoid/commit/78d07191c23e61450c732d005c57cc38ccb40787) fix(station): the MoonBit station's file ops, inst | 2.54 | 3.42 | 13.99 | 35.92 | 53.82 | 31.49 | 63.36 | 96.62 | 123.09 |
| [9c59a1b52](https://github.com/AFK-surf/monoid/commit/9c59a1b52521d9b7ce6aa38ecb255123f4e3a022) fix(app): open PR links and refresh selected photo | 2.54 | 3.42 | 13.99 | 35.92 | 53.82 | 31.49 | 63.36 | 96.81 | 123.09 |
| [6122dc262](https://github.com/AFK-surf/monoid/commit/6122dc2629ec4ca2f73e5673f582c4667ccf61d4) fix(mbui): add LiquidBottomTabs shadows to the bot | 2.54 | 3.42 | 13.99 | 35.92 | 53.81 | 31.49 | 63.36 | 96.95 | 123.09 |
| [b7b134825](https://github.com/AFK-surf/monoid/commit/b7b134825f2d0db5c79fe3c8d36fdcca73b9ef21) fix(station): make one profile, not all, when the  | 2.54 | 3.42 | 13.99 | 35.92 | 53.82 | 31.49 | 63.36 | 96.83 | 123.09 |
| [e076785f3](https://github.com/AFK-surf/monoid/commit/e076785f3b101f4f7582b0e2f0750647331039f6) fix(ci): rebalance native mbui builds and tests (# | 2.54 | 3.42 | 13.99 | 35.92 | 53.82 | 31.49 | 63.36 | 96.83 | 123.09 |
| [53ebc9dfa](https://github.com/AFK-surf/monoid/commit/53ebc9dfa53e06ffd6a9cf614766b2f4e8daa895) Port AndroidLiquidGlass and refine glass controls | 2.54 | 3.42 | 13.99 | 35.91 | 53.81 | 31.48 | 63.36 | 96.52 | 123.09 |
| [021eab5d9](https://github.com/AFK-surf/monoid/commit/021eab5d9a5649274cc87dfe15aae3eb9e2f095d) app: show refresh countdown capsule on spent quota | 2.54 | 3.41 | 13.99 | 35.91 | 53.79 | 31.48 | 63.34 | 96.72 | 126.18 |
| [5409b4cbc](https://github.com/AFK-surf/monoid/commit/5409b4cbc70cc6419539de41783a28be85367f26) feat(station): Farview 8B and 8C, farview.pin to 8 | 2.54 | 3.41 | 13.99 | 35.91 | 53.79 | 31.48 | 63.34 | 96.72 | 126.18 |
| [38f019e17](https://github.com/AFK-surf/monoid/commit/38f019e17b9fc66d6664a4b921905c495dd40622) fix(app): 控制中心 and a side tab's history open once  | 2.54 | 3.41 | 13.99 | 35.91 | 53.79 | 31.48 | 63.32 | 96.77 | 126.18 |
| [228075b1c](https://github.com/AFK-surf/monoid/commit/228075b1c42786382c7c7283bbdc18e99ffb4132) Show live agent output speed across a workspace (# | 2.54 | 3.41 | 13.98 | 35.9 | 53.78 | 31.48 | 63.32 | 96.77 | 116.78 |
| [3d4e7f31c](https://github.com/AFK-surf/monoid/commit/3d4e7f31c8c5cb3dd90c1edec406bfc8da86e8e5) feat(station): put the MoonBit station together wh | 2.54 | 3.41 | 13.98 | 35.9 | 53.77 | 31.47 | 63.32 | 96.99 | 123.22 |
| [8dea365d1](https://github.com/AFK-surf/monoid/commit/8dea365d1d1817c3ab8256bf568900d88cafc779) test(mbui): sizes_across bars hold what 60 and 120 | 2.54 | 3.41 | 13.98 | 35.9 | 53.77 | 31.47 | 63.32 | 96.58 | 123.22 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [9fe2303fd](https://github.com/AFK-surf/monoid/commit/9fe2303fd4ab738aaaf7db52da58975505202b0c) fix(screens): coalesce unsent pointer moves, recov | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.66 |
| [b5c70cdc0](https://github.com/AFK-surf/monoid/commit/b5c70cdc09495a54107ea7d332195db61b15967f) fix(mbui): keep a Windows video's frame shown thro | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.66 |
| [e31f5a37f](https://github.com/AFK-surf/monoid/commit/e31f5a37f32c446b9035c32514dd3f6b1c924d7f) fix(mbui): a mouse's drag scrolls no table or code | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.81 |
| [ac966624e](https://github.com/AFK-surf/monoid/commit/ac966624e16dc0445e669ae4abf3aeb967b738b1) feat(base): verify Ed25519 fast on js, add a page' | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.61 |
| [f27e63953](https://github.com/AFK-surf/monoid/commit/f27e6395317734d5b5ea6e79971a7c5b1a76ffc0) fix(core): a chat whose first message did not go c | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.61 |
| [cd1158577](https://github.com/AFK-surf/monoid/commit/cd11585774d1d8f291d7cc75e45dc8815dc79614) feat(mbui app): write a new 待派发 task in the chat's | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.54 |
| [fab5e0c17](https://github.com/AFK-surf/monoid/commit/fab5e0c176b47cb65cb966a352dbcc3057780d4d) feat(mbui): add hover_reveal, tooltip glide origin | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.54 |
| [babed3f66](https://github.com/AFK-surf/monoid/commit/babed3f663c4e1148c4f4975fb26ad576c032056) fix(mbui): open the right soft keyboard on one tap | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.64 |
| [f03c25025](https://github.com/AFK-surf/monoid/commit/f03c2502589f6146209a3b49d3dff982ea0244e8) test(station): the whole MoonBit station tells a d | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.64 |
| [a78791d91](https://github.com/AFK-surf/monoid/commit/a78791d9124a36a6dd422ec5f41a80f955be7844) fix(mbui): keep the segmented thumb moving through | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.54 |
| [fee058d70](https://github.com/AFK-surf/monoid/commit/fee058d70bc98ff76618b35e38dbb6dc14a8177d) fix(mbc): keep framework units at -O2 in light sfa | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.45 |
| [1104afa35](https://github.com/AFK-surf/monoid/commit/1104afa35e5423f3d9cd9a5752dea86bf43fd679) fix(cloud): a push says what was said as plain wor | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.63 |
| [33815598f](https://github.com/AFK-surf/monoid/commit/33815598fcddcaa323fa0367afb4e3849a636178) mbui app: a chat's composer made as nodes, whole ( | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.63 |
| [7c3c797b7](https://github.com/AFK-surf/monoid/commit/7c3c797b72fdc40941ae12bec151b4d7cc83d199) fix(mbui): pick a preset's model on the composer's | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.63 |
| [3a3bad347](https://github.com/AFK-surf/monoid/commit/3a3bad34737a5401bc21aa71b0b1e3b3de1bde99) fix(station): the front takes a Node's new protoco | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.63 |
| [3db36a227](https://github.com/AFK-surf/monoid/commit/3db36a227d053592a4b2e1a13fc1476daad9ff67) fix(mbui): background Android test activity via HO | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.63 |
| [88d08d335](https://github.com/AFK-surf/monoid/commit/88d08d3354e8f4899fbda352f14ca5641515bf68) fix(station): a chat named is not asked to name it | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.79 |
| [089f33f94](https://github.com/AFK-surf/monoid/commit/089f33f94c8f48ec0c8d9f616c3ef3bd032efe2e) fix(ci): replace undici fetch in release-deltas to | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.79 |
| [96fae6be6](https://github.com/AFK-surf/monoid/commit/96fae6be63bc71ff0c9597648b9af1ff6b008928) mbui: a chat's words broken anew as the side panel | 0.44 | 0.57 | 2.18 | 3.27 | 5.21 | 1.6 | 4.3 | 53.79 |
| [47562f9dd](https://github.com/AFK-surf/monoid/commit/47562f9dd2435091c8f4fb111366a4a41fb7f990) fix(mbui): a show shown again by an answer as it c | 0.44 | 0.57 | 2.17 | 3.27 | 5.21 | 1.59 | 4.28 | 53.25 |
| [bef9e7b69](https://github.com/AFK-surf/monoid/commit/bef9e7b69b9cf6fb3d79fde18093210a51b6c868) fix(station): tell what the threads' store wrote f | 0.44 | 0.57 | 2.17 | 3.27 | 5.21 | 1.59 | 4.28 | 53.25 |
| [34b88f6c4](https://github.com/AFK-surf/monoid/commit/34b88f6c4ca6ba57b9d48768c8ba518a75d857ed) fix(core): bound pairing code verification reads a | 0.44 | 0.57 | 2.17 | 3.27 | 5.21 | 1.6 | 4.28 | 53.48 |
| [d61377bd9](https://github.com/AFK-surf/monoid/commit/d61377bd9f7a08047ca54a93486084e276cc880b) fix(mbui): let users swipe between segmented optio | 0.44 | 0.57 | 2.17 | 3.27 | 5.21 | 1.6 | 4.28 | 53.48 |
| [890460249](https://github.com/AFK-surf/monoid/commit/890460249ac0a2002e44e1a53c1e14be19c02d13) feat(station): the launcher starts the installer t | 0.43 | 0.57 | 2.17 | 3.27 | 5.21 | 1.59 | 4.28 | 53.33 |
| [13e6f174e](https://github.com/AFK-surf/monoid/commit/13e6f174e360c105172832205fd342177986a7f9) test(station): a station updates itself again afte | 0.43 | 0.57 | 2.17 | 3.27 | 5.21 | 1.59 | 4.28 | 53.33 |
| [2f5363912](https://github.com/AFK-surf/monoid/commit/2f5363912f1a1d6837b16de2c728c060b6da4f95) fix(ci): prefer optimized mbui objects and rebalan | 0.43 | 0.57 | 2.17 | 3.27 | 5.21 | 1.59 | 4.28 | 53.33 |
| [dde626684](https://github.com/AFK-surf/monoid/commit/dde626684c75622e82debae47ca8e3c0a00f0816) revert(station): a release carries the TypeScript  | 0.43 | 0.57 | 2.17 | 3.27 | 5.21 | 1.59 | 4.28 | 53.54 |
| [c8401bba3](https://github.com/AFK-surf/monoid/commit/c8401bba37ffa2bd7704e9449c472a53817f780a) fix(core): open visited chats at their latest page | 0.43 | 0.57 | 2.17 | 3.27 | 5.21 | 1.59 | 4.28 | 53.54 |
| [78d07191c](https://github.com/AFK-surf/monoid/commit/78d07191c23e61450c732d005c57cc38ccb40787) fix(station): the MoonBit station's file ops, inst | 0.43 | 0.57 | 2.17 | 3.27 | 5.21 | 1.59 | 4.28 | 53.54 |
| [9c59a1b52](https://github.com/AFK-surf/monoid/commit/9c59a1b52521d9b7ce6aa38ecb255123f4e3a022) fix(app): open PR links and refresh selected photo | 0.43 | 0.57 | 2.17 | 3.27 | 5.21 | 1.59 | 4.28 | 53.54 |
| [6122dc262](https://github.com/AFK-surf/monoid/commit/6122dc2629ec4ca2f73e5673f582c4667ccf61d4) fix(mbui): add LiquidBottomTabs shadows to the bot | 0.43 | 0.57 | 2.17 | 3.27 | 5.21 | 1.59 | 4.28 | 53.25 |
| [b7b134825](https://github.com/AFK-surf/monoid/commit/b7b134825f2d0db5c79fe3c8d36fdcca73b9ef21) fix(station): make one profile, not all, when the  | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.28 |
| [e076785f3](https://github.com/AFK-surf/monoid/commit/e076785f3b101f4f7582b0e2f0750647331039f6) fix(ci): rebalance native mbui builds and tests (# | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.28 |
| [53ebc9dfa](https://github.com/AFK-surf/monoid/commit/53ebc9dfa53e06ffd6a9cf614766b2f4e8daa895) Port AndroidLiquidGlass and refine glass controls | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.27 |
| [021eab5d9](https://github.com/AFK-surf/monoid/commit/021eab5d9a5649274cc87dfe15aae3eb9e2f095d) app: show refresh countdown capsule on spent quota | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.27 |
| [5409b4cbc](https://github.com/AFK-surf/monoid/commit/5409b4cbc70cc6419539de41783a28be85367f26) feat(station): Farview 8B and 8C, farview.pin to 8 | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.51 |
| [38f019e17](https://github.com/AFK-surf/monoid/commit/38f019e17b9fc66d6664a4b921905c495dd40622) fix(app): 控制中心 and a side tab's history open once  | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.51 |
| [228075b1c](https://github.com/AFK-surf/monoid/commit/228075b1c42786382c7c7283bbdc18e99ffb4132) Show live agent output speed across a workspace (# | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.51 |
| [3d4e7f31c](https://github.com/AFK-surf/monoid/commit/3d4e7f31c8c5cb3dd90c1edec406bfc8da86e8e5) feat(station): put the MoonBit station together wh | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.51 |
| [8dea365d1](https://github.com/AFK-surf/monoid/commit/8dea365d1d1817c3ab8256bf568900d88cafc779) test(mbui): sizes_across bars hold what 60 and 120 | 0.43 | 0.57 | 2.17 | 3.27 | 5.2 | 1.59 | 4.28 | 53.51 |
