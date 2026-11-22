# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [e9f48df90](https://github.com/AFK-surf/monoid/commit/e9f48df90aca90a16004e26ef91eaf6cff6c00ec) fix(mbui): shorten the app update row (#8165) | 2.69 | 3.62 | 14.66 | 36.76 | 55.91 | 32.2 | 65.24 | 100.12 | 125.32 |
| [61314116d](https://github.com/AFK-surf/monoid/commit/61314116db05d116bc27f23a8809c99948a4f49e) fix(station): catch mid-session MCP loss and backo | 2.68 | 3.61 | 14.66 | 36.74 | 55.88 | 32.2 | 65.21 | 99.94 | 123.62 |
| [8b659b96c](https://github.com/AFK-surf/monoid/commit/8b659b96c7cd9a7b67ef429649ac6557ea1b7f19) perf(mbui): add Windows D3D11 GPU timing, display_ | 2.68 | 3.61 | 14.64 | 36.73 | 55.84 | 32.18 | 65.16 | 99.91 | 115.83 |
| [26d9c959d](https://github.com/AFK-surf/monoid/commit/26d9c959d48a61322a07f498827fadf8e79dce30) perf(mbui): isolate stacked glass cache, add GLES  | 2.68 | 3.61 | 14.64 | 36.73 | 55.84 | 32.18 | 65.16 | 99.91 | 115.83 |
| [2fc81fb16](https://github.com/AFK-surf/monoid/commit/2fc81fb1640e8b949325cdfed0f11732a9f51005) feat(mbui): show the source of a Markdown file in  | 2.68 | 3.61 | 14.64 | 36.73 | 55.84 | 32.18 | 65.16 | 99.91 | 115.83 |
| [2baeae5ef](https://github.com/AFK-surf/monoid/commit/2baeae5efc0f19f71244214ce86fefbe58277dc4) feat(sf-ui): put the window keys in one tinted liq | 2.68 | 3.6 | 14.62 | 36.72 | 55.82 | 32.17 | 65.16 | 99.83 | 123.62 |
| [18c2f2077](https://github.com/AFK-surf/monoid/commit/18c2f207752b73d637d47017bc21cf77ab9cacf9) feat(app): put the shortcuts' search above their l | 2.67 | 3.6 | 14.6 | 36.7 | 55.79 | 32.15 | 65.11 | 100.19 | 123.43 |
| [a2e9941cc](https://github.com/AFK-surf/monoid/commit/a2e9941cc2cbce8ff638ef7879cd000e90c269a2) feat(mbui): add macOS and Windows crash and main-t | 2.67 | 3.6 | 14.6 | 36.7 | 55.79 | 32.15 | 65.11 | 100.19 | 123.43 |
| [75c7a178d](https://github.com/AFK-surf/monoid/commit/75c7a178d517259070eca12361d6b1ce6b63fc64) perf(mbui): optimize adaptive liquid glass GPU ren | 2.67 | 3.6 | 14.6 | 36.7 | 55.79 | 32.15 | 65.11 | 100.19 | 123.43 |
| [f7978a96d](https://github.com/AFK-surf/monoid/commit/f7978a96df78ae0c98b939f5952b478314e9fb0b) fix(test): build the delta C harness without PIE o | 2.67 | 3.6 | 14.59 | 36.69 | 55.74 | 32.14 | 65.08 | 98.93 | 120.95 |
| [d14a63795](https://github.com/AFK-surf/monoid/commit/d14a63795c75de8b6ead55911db8ffc2e87657e0) fix(mbui): stop pointer-driven layout loops (#8149 | 2.67 | 3.6 | 14.59 | 36.69 | 55.74 | 32.14 | 65.06 | 98.94 | 123.84 |
| [fb7c623cc](https://github.com/AFK-surf/monoid/commit/fb7c623cc88af36f118d38d615876a62c57b2788) perf(mbui): set macOS menu bar items enabled in pl | 2.67 | 3.6 | 14.59 | 36.69 | 55.74 | 32.14 | 65.06 | 98.94 | 123.84 |
| [5fa0192bb](https://github.com/AFK-surf/monoid/commit/5fa0192bb5782095d688727bbd49077f2ef0f834) perf(mbui): eliminate Windows glyph rasterization  | 2.67 | 3.6 | 14.59 | 36.68 | 55.74 | 32.13 | 65.06 | 98.88 | 123.68 |
| [77a2cb29f](https://github.com/AFK-surf/monoid/commit/77a2cb29f3b020a65bf0ecb03b4a8648b83b1e4c) fix(chat): fade messages behind the composer while | 2.67 | 3.6 | 14.59 | 36.68 | 55.74 | 32.13 | 65.06 | 98.88 | 123.68 |
| [a2ddd8aa2](https://github.com/AFK-surf/monoid/commit/a2ddd8aa24f464260c38c45d0be8b1db9a6de453) feat(liquid-glass): uplift overlay glass recipes,  | 2.67 | 3.6 | 14.59 | 36.68 | 55.74 | 32.13 | 65.06 | 98.88 | 123.68 |
| [5b7e17f0e](https://github.com/AFK-surf/monoid/commit/5b7e17f0eb53e8a04e5fd1104b3bb3569d6d3eb2) fix(sfapp): uncrowd agent info sheet header with 3 | 2.67 | 3.6 | 14.59 | 36.68 | 55.74 | 32.14 | 65.06 | 99.08 | 122.11 |
| [1fa4ef07a](https://github.com/AFK-surf/monoid/commit/1fa4ef07a8be5bf44c3ca223cd9e8e6825777442) fix(mbui): keep later photos in the attach strip o | 2.67 | 3.6 | 14.58 | 36.67 | 55.72 | 32.11 | 65.01 | 98.81 | 121.72 |
| [831ca02c9](https://github.com/AFK-surf/monoid/commit/831ca02c945fd701cc13e872350fb1f06844502a) fix(mbui): redraw complete glass captures during s | 2.67 | 3.59 | 14.57 | 36.66 | 55.67 | 32.11 | 65.01 | 98.81 | 114.66 |
| [2b7f56a69](https://github.com/AFK-surf/monoid/commit/2b7f56a69b3ae604abf57b6ded7787dcfd649652) feat(core,mbui,sfapp): step down model labels in t | 2.67 | 3.59 | 14.57 | 36.66 | 55.67 | 32.11 | 65.01 | 98.81 | 114.66 |
| [7a1ead641](https://github.com/AFK-surf/monoid/commit/7a1ead64114b749fcea9384e2c69dab1d844438e) fix(mbui): remove double smoothstep flattening on  | 2.67 | 3.59 | 14.57 | 36.66 | 55.67 | 32.11 | 65.01 | 98.81 | 114.66 |
| [0a8047918](https://github.com/AFK-surf/monoid/commit/0a804791815d242ada5a95d526f9860914c78447) fix(session): handle failed agent starts and retry | 2.67 | 3.59 | 14.57 | 36.66 | 55.67 | 32.11 | 65.01 | 98.65 | 108.33 |
| [0259f9d0c](https://github.com/AFK-surf/monoid/commit/0259f9d0cb824eecf48dbb691d6193edd0ed83ff) feat(mbui): add new submenu for terminal and brows | 2.67 | 3.59 | 14.57 | 36.66 | 55.67 | 32.11 | 65.01 | 98.65 | 108.33 |
| [7c4bfea28](https://github.com/AFK-surf/monoid/commit/7c4bfea281f3ac6557d50a19aa787600aea0084f) feat(liquid-glass): uplift controls, optical recip | 2.67 | 3.59 | 14.57 | 36.65 | 55.66 | 32.11 | 65 | 98.96 | 126.87 |
| [04d8ccd79](https://github.com/AFK-surf/monoid/commit/04d8ccd79d35d2283fcaac60a9ae2397164ea1a8) fix(sfapp): expand narrow chat top-bar blur platea | 2.66 | 3.59 | 14.56 | 36.65 | 55.64 | 32.1 | 64.98 | 99.09 | 123.45 |
| [33fc6434d](https://github.com/AFK-surf/monoid/commit/33fc6434da852c38759b756b5605c52fa0b5887e) fix(player): match playback controls to the player | 2.66 | 3.59 | 14.56 | 36.65 | 55.64 | 32.1 | 64.98 | 99.26 | 124.87 |
| [2b0b21c94](https://github.com/AFK-surf/monoid/commit/2b0b21c9412241eba48b5e883d40515ec2a8b4ed) fix(screens): recover lost screen frames (#8113) | 2.66 | 3.59 | 14.56 | 36.65 | 55.64 | 32.1 | 64.98 | 99.26 | 124.87 |
| [5dd4241db](https://github.com/AFK-surf/monoid/commit/5dd4241dbe87bc8d1642e44008795082d3210df0) fix(mbui): smooth Wave 7 adaptive liquid glass tra | 2.66 | 3.59 | 14.56 | 36.65 | 55.64 | 32.09 | 64.98 | 99.06 | 118.66 |
| [7351c0c94](https://github.com/AFK-surf/monoid/commit/7351c0c940036cb5d446b5ef5d33523ed51b3d2b) fix(mbui): exempt pinned list foot from Android ov | 2.66 | 3.59 | 14.56 | 36.64 | 55.63 | 32.09 | 64.95 | 98.9 | 111.12 |
| [77b54e068](https://github.com/AFK-surf/monoid/commit/77b54e068e822ba2f99ea47fa0e30694a51e1995) feat(mbui): group composer-top agents by station w | 2.67 | 3.59 | 14.56 | 36.64 | 55.63 | 32.09 | 64.95 | 98.76 | 129.99 |
| [e26266e53](https://github.com/AFK-surf/monoid/commit/e26266e53c18d05a7df86f83486618fac28911a7) feat(mbui): polish text field selection handles, l | 2.66 | 3.59 | 14.56 | 36.64 | 55.61 | 32.09 | 64.93 | 98.85 | 121.55 |
| [e56b27877](https://github.com/AFK-surf/monoid/commit/e56b2787738fe24ae8fa03b529759bca3c476eba) fix(mbui): preserve outer hugs cap in scroll measu | 2.66 | 3.58 | 14.55 | 36.63 | 55.58 | 32.08 | 64.9 | 98.63 | 111.9 |
| [1aaa170ed](https://github.com/AFK-surf/monoid/commit/1aaa170ed270f11c2ab1318ad2c578b8576d61b5) fix(core-ts): fix zero-speed video routing, stall  | 2.66 | 3.58 | 14.55 | 36.63 | 55.58 | 32.08 | 64.91 | 98.96 | 127.28 |
| [e9f727949](https://github.com/AFK-surf/monoid/commit/e9f727949dd1f1e19c91206c5e6893d47926864e) docs: remove misleading chat-message streaming wor | 2.66 | 3.58 | 14.55 | 36.6 | 55.52 | 32.08 | 64.91 | 99.09 | 116.7 |
| [fd4464ef0](https://github.com/AFK-surf/monoid/commit/fd4464ef07d130b1b398ee3e875df369ed89fb3c) fix(ci): include libs/liquid-glass in beta mirror, | 2.66 | 3.58 | 14.55 | 36.6 | 55.52 | 32.08 | 64.91 | 98.9 | 116.7 |
| [aca188733](https://github.com/AFK-surf/monoid/commit/aca18873379823b32ca2853c7c6d8d9289f86df2) fix(mbui,sf-ui,sfapp): smooth small-sigma progress | 2.66 | 3.58 | 14.55 | 36.6 | 55.52 | 32.08 | 64.91 | 98.9 | 116.7 |
| [1312352b4](https://github.com/AFK-surf/monoid/commit/1312352b4df793ffc578868bd5019c7405ae0bbc) fix(mbui): tighten liquid glass outer shadows into | 2.66 | 3.58 | 14.55 | 36.6 | 55.52 | 32.08 | 64.9 | 98.88 | 116.7 |
| [cfeaf85ae](https://github.com/AFK-surf/monoid/commit/cfeaf85ae8abdc54bad8353cbd0d7fa2f26ec90f) feat(mbui): use liquid_segmented_node in sf-ui and | 2.66 | 3.59 | 14.55 | 36.6 | 55.52 | 32.08 | 64.91 | 98.76 | 116.7 |
| [f4f4a3969](https://github.com/AFK-surf/monoid/commit/f4f4a3969319607731f19948d861d5dcbce954cc) fix(sf-ui): keep a hover card open when its modal  | 2.66 | 3.58 | 14.53 | 36.6 | 55.52 | 32.06 | 64.86 | 98.68 | 116.7 |
| [648a3b3c9](https://github.com/AFK-surf/monoid/commit/648a3b3c9d4475c39c5503687109fc748039621b) perf(mbui): fix Android IME pop-up/dismiss frame p | 2.66 | 3.58 | 14.53 | 36.6 | 55.52 | 32.06 | 64.86 | 99.04 | 119.35 |
| [fde7ce64a](https://github.com/AFK-surf/monoid/commit/fde7ce64a6629f9dbf29117b762ef0810490e51f) mbui, sf-ui, sfapp: Wave 7 adaptive liquid glass w | 2.66 | 3.58 | 14.53 | 36.6 | 55.52 | 32.06 | 64.86 | 98.91 | 124.17 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [e9f48df90](https://github.com/AFK-surf/monoid/commit/e9f48df90aca90a16004e26ef91eaf6cff6c00ec) fix(mbui): shorten the app update row (#8165) | 0.48 | 0.63 | 2.42 | 3.48 | 5.74 | 1.77 | 4.77 | 55.71 |
| [61314116d](https://github.com/AFK-surf/monoid/commit/61314116db05d116bc27f23a8809c99948a4f49e) fix(station): catch mid-session MCP loss and backo | 0.48 | 0.63 | 2.42 | 3.48 | 5.74 | 1.77 | 4.77 | 55.71 |
| [8b659b96c](https://github.com/AFK-surf/monoid/commit/8b659b96c7cd9a7b67ef429649ac6557ea1b7f19) perf(mbui): add Windows D3D11 GPU timing, display_ | 0.48 | 0.63 | 2.42 | 3.48 | 5.74 | 1.77 | 4.77 | 55.71 |
| [26d9c959d](https://github.com/AFK-surf/monoid/commit/26d9c959d48a61322a07f498827fadf8e79dce30) perf(mbui): isolate stacked glass cache, add GLES  | 0.48 | 0.63 | 2.42 | 3.48 | 5.73 | 1.77 | 4.77 | 55.69 |
| [2fc81fb16](https://github.com/AFK-surf/monoid/commit/2fc81fb1640e8b949325cdfed0f11732a9f51005) feat(mbui): show the source of a Markdown file in  | 0.48 | 0.63 | 2.41 | 3.47 | 5.72 | 1.76 | 4.77 | 55.59 |
| [2baeae5ef](https://github.com/AFK-surf/monoid/commit/2baeae5efc0f19f71244214ce86fefbe58277dc4) feat(sf-ui): put the window keys in one tinted liq | 0.48 | 0.63 | 2.41 | 3.47 | 5.72 | 1.76 | 4.77 | 55.59 |
| [18c2f2077](https://github.com/AFK-surf/monoid/commit/18c2f207752b73d637d47017bc21cf77ab9cacf9) feat(app): put the shortcuts' search above their l | 0.48 | 0.63 | 2.41 | 3.47 | 5.72 | 1.76 | 4.77 | 55.59 |
| [a2e9941cc](https://github.com/AFK-surf/monoid/commit/a2e9941cc2cbce8ff638ef7879cd000e90c269a2) feat(mbui): add macOS and Windows crash and main-t | 0.47 | 0.62 | 2.4 | 3.45 | 5.69 | 1.75 | 4.73 | 55.25 |
| [75c7a178d](https://github.com/AFK-surf/monoid/commit/75c7a178d517259070eca12361d6b1ce6b63fc64) perf(mbui): optimize adaptive liquid glass GPU ren | 0.47 | 0.62 | 2.4 | 3.45 | 5.69 | 1.75 | 4.73 | 55.38 |
| [f7978a96d](https://github.com/AFK-surf/monoid/commit/f7978a96df78ae0c98b939f5952b478314e9fb0b) fix(test): build the delta C harness without PIE o | 0.47 | 0.62 | 2.4 | 3.45 | 5.69 | 1.75 | 4.73 | 54.59 |
| [d14a63795](https://github.com/AFK-surf/monoid/commit/d14a63795c75de8b6ead55911db8ffc2e87657e0) fix(mbui): stop pointer-driven layout loops (#8149 | 0.47 | 0.62 | 2.4 | 3.45 | 5.69 | 1.75 | 4.73 | 54.59 |
| [fb7c623cc](https://github.com/AFK-surf/monoid/commit/fb7c623cc88af36f118d38d615876a62c57b2788) perf(mbui): set macOS menu bar items enabled in pl | 0.47 | 0.62 | 2.39 | 3.45 | 5.67 | 1.74 | 4.72 | 54.51 |
| [5fa0192bb](https://github.com/AFK-surf/monoid/commit/5fa0192bb5782095d688727bbd49077f2ef0f834) perf(mbui): eliminate Windows glyph rasterization  | 0.47 | 0.62 | 2.39 | 3.45 | 5.67 | 1.74 | 4.72 | 54.51 |
| [77a2cb29f](https://github.com/AFK-surf/monoid/commit/77a2cb29f3b020a65bf0ecb03b4a8648b83b1e4c) fix(chat): fade messages behind the composer while | 0.47 | 0.62 | 2.39 | 3.45 | 5.67 | 1.74 | 4.72 | 54.35 |
| [a2ddd8aa2](https://github.com/AFK-surf/monoid/commit/a2ddd8aa24f464260c38c45d0be8b1db9a6de453) feat(liquid-glass): uplift overlay glass recipes,  | 0.47 | 0.62 | 2.39 | 3.45 | 5.67 | 1.74 | 4.72 | 54.31 |
| [5b7e17f0e](https://github.com/AFK-surf/monoid/commit/5b7e17f0eb53e8a04e5fd1104b3bb3569d6d3eb2) fix(sfapp): uncrowd agent info sheet header with 3 | 0.47 | 0.62 | 2.39 | 3.45 | 5.67 | 1.74 | 4.72 | 54.31 |
| [1fa4ef07a](https://github.com/AFK-surf/monoid/commit/1fa4ef07a8be5bf44c3ca223cd9e8e6825777442) fix(mbui): keep later photos in the attach strip o | 0.47 | 0.62 | 2.39 | 3.45 | 5.67 | 1.74 | 4.72 | 54.31 |
| [831ca02c9](https://github.com/AFK-surf/monoid/commit/831ca02c945fd701cc13e872350fb1f06844502a) fix(mbui): redraw complete glass captures during s | 0.47 | 0.62 | 2.39 | 3.45 | 5.67 | 1.74 | 4.72 | 54.31 |
| [2b7f56a69](https://github.com/AFK-surf/monoid/commit/2b7f56a69b3ae604abf57b6ded7787dcfd649652) feat(core,mbui,sfapp): step down model labels in t | 0.47 | 0.62 | 2.39 | 3.45 | 5.66 | 1.74 | 4.72 | 54.26 |
| [7a1ead641](https://github.com/AFK-surf/monoid/commit/7a1ead64114b749fcea9384e2c69dab1d844438e) fix(mbui): remove double smoothstep flattening on  | 0.47 | 0.62 | 2.39 | 3.45 | 5.66 | 1.74 | 4.7 | 54.53 |
| [0a8047918](https://github.com/AFK-surf/monoid/commit/0a804791815d242ada5a95d526f9860914c78447) fix(session): handle failed agent starts and retry | 0.47 | 0.62 | 2.39 | 3.45 | 5.66 | 1.74 | 4.7 | 54.53 |
| [0259f9d0c](https://github.com/AFK-surf/monoid/commit/0259f9d0cb824eecf48dbb691d6193edd0ed83ff) feat(mbui): add new submenu for terminal and brows | 0.47 | 0.62 | 2.39 | 3.45 | 5.66 | 1.74 | 4.7 | 54.38 |
| [7c4bfea28](https://github.com/AFK-surf/monoid/commit/7c4bfea281f3ac6557d50a19aa787600aea0084f) feat(liquid-glass): uplift controls, optical recip | 0.47 | 0.62 | 2.39 | 3.45 | 5.66 | 1.74 | 4.7 | 54.38 |
| [04d8ccd79](https://github.com/AFK-surf/monoid/commit/04d8ccd79d35d2283fcaac60a9ae2397164ea1a8) fix(sfapp): expand narrow chat top-bar blur platea | 0.47 | 0.62 | 2.39 | 3.45 | 5.66 | 1.74 | 4.7 | 54.38 |
| [33fc6434d](https://github.com/AFK-surf/monoid/commit/33fc6434da852c38759b756b5605c52fa0b5887e) fix(player): match playback controls to the player | 0.47 | 0.62 | 2.39 | 3.45 | 5.66 | 1.74 | 4.7 | 54.38 |
| [2b0b21c94](https://github.com/AFK-surf/monoid/commit/2b0b21c9412241eba48b5e883d40515ec2a8b4ed) fix(screens): recover lost screen frames (#8113) | 0.47 | 0.62 | 2.39 | 3.45 | 5.66 | 1.74 | 4.7 | 54.63 |
| [5dd4241db](https://github.com/AFK-surf/monoid/commit/5dd4241dbe87bc8d1642e44008795082d3210df0) fix(mbui): smooth Wave 7 adaptive liquid glass tra | 0.47 | 0.62 | 2.39 | 3.45 | 5.66 | 1.74 | 4.7 | 54.63 |
| [7351c0c94](https://github.com/AFK-surf/monoid/commit/7351c0c940036cb5d446b5ef5d33523ed51b3d2b) fix(mbui): exempt pinned list foot from Android ov | 0.47 | 0.62 | 2.39 | 3.44 | 5.65 | 1.73 | 4.68 | 54.38 |
| [77b54e068](https://github.com/AFK-surf/monoid/commit/77b54e068e822ba2f99ea47fa0e30694a51e1995) feat(mbui): group composer-top agents by station w | 0.47 | 0.62 | 2.39 | 3.44 | 5.65 | 1.73 | 4.68 | 54.48 |
| [e26266e53](https://github.com/AFK-surf/monoid/commit/e26266e53c18d05a7df86f83486618fac28911a7) feat(mbui): polish text field selection handles, l | 0.47 | 0.62 | 2.39 | 3.44 | 5.65 | 1.73 | 4.68 | 54.48 |
| [e56b27877](https://github.com/AFK-surf/monoid/commit/e56b2787738fe24ae8fa03b529759bca3c476eba) fix(mbui): preserve outer hugs cap in scroll measu | 0.47 | 0.62 | 2.38 | 3.44 | 5.64 | 1.73 | 4.67 | 54.38 |
| [1aaa170ed](https://github.com/AFK-surf/monoid/commit/1aaa170ed270f11c2ab1318ad2c578b8576d61b5) fix(core-ts): fix zero-speed video routing, stall  | 0.47 | 0.62 | 2.38 | 3.44 | 5.64 | 1.73 | 4.67 | 54.4 |
| [e9f727949](https://github.com/AFK-surf/monoid/commit/e9f727949dd1f1e19c91206c5e6893d47926864e) docs: remove misleading chat-message streaming wor | 0.47 | 0.62 | 2.38 | 3.44 | 5.64 | 1.73 | 4.67 | 54.4 |
| [fd4464ef0](https://github.com/AFK-surf/monoid/commit/fd4464ef07d130b1b398ee3e875df369ed89fb3c) fix(ci): include libs/liquid-glass in beta mirror, | 0.47 | 0.62 | 2.38 | 3.44 | 5.64 | 1.73 | 4.67 | 54.4 |
| [aca188733](https://github.com/AFK-surf/monoid/commit/aca18873379823b32ca2853c7c6d8d9289f86df2) fix(mbui,sf-ui,sfapp): smooth small-sigma progress | 0.47 | 0.62 | 2.38 | 3.44 | 5.64 | 1.73 | 4.67 | 54.66 |
| [1312352b4](https://github.com/AFK-surf/monoid/commit/1312352b4df793ffc578868bd5019c7405ae0bbc) fix(mbui): tighten liquid glass outer shadows into | 0.47 | 0.62 | 2.38 | 3.43 | 5.64 | 1.73 | 4.67 | 54.23 |
| [cfeaf85ae](https://github.com/AFK-surf/monoid/commit/cfeaf85ae8abdc54bad8353cbd0d7fa2f26ec90f) feat(mbui): use liquid_segmented_node in sf-ui and | 0.47 | 0.62 | 2.38 | 3.43 | 5.64 | 1.73 | 4.67 | 54.23 |
| [f4f4a3969](https://github.com/AFK-surf/monoid/commit/f4f4a3969319607731f19948d861d5dcbce954cc) fix(sf-ui): keep a hover card open when its modal  | 0.47 | 0.62 | 2.38 | 3.43 | 5.64 | 1.73 | 4.67 | 54.23 |
| [648a3b3c9](https://github.com/AFK-surf/monoid/commit/648a3b3c9d4475c39c5503687109fc748039621b) perf(mbui): fix Android IME pop-up/dismiss frame p | 0.47 | 0.62 | 2.38 | 3.43 | 5.64 | 1.73 | 4.67 | 54.23 |
| [fde7ce64a](https://github.com/AFK-surf/monoid/commit/fde7ce64a6629f9dbf29117b762ef0810490e51f) mbui, sf-ui, sfapp: Wave 7 adaptive liquid glass w | 0.47 | 0.62 | 2.38 | 3.43 | 5.64 | 1.73 | 4.67 | 54.49 |
