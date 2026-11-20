# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [147cbffea](https://github.com/AFK-surf/monoid/commit/147cbffeab11883ae0e572fdbb1ae16c43ad2b02) ci(android): hash APK inputs in batches and put fi | 2.67 | 3.58 | 14.64 | 36.93 | 56.33 | 32.39 | 65.67 | 97.63 | 125.92 |
| [07ab0ec5f](https://github.com/AFK-surf/monoid/commit/07ab0ec5fc0516223eee4dc38ded1f7ddee1389a) fix(station): read adb revokes without taking the  | 2.67 | 3.58 | 14.64 | 36.93 | 56.33 | 32.39 | 65.67 | 97.63 | 125.92 |
| [6b2f2c4fa](https://github.com/AFK-surf/monoid/commit/6b2f2c4fad295544428147c3355ef00bba73a635) refactor(station/mb): wire session_storage directl | 2.66 | 3.58 | 14.62 | 36.92 | 56.29 | 32.38 | 65.63 | 97.73 | 120.51 |
| [b251a55c4](https://github.com/AFK-surf/monoid/commit/b251a55c4e3f66d324cb182e76a4883372dc015c) feat(mbui): add layered NavTransition protocol, ge | 2.66 | 3.58 | 14.61 | 36.88 | 56.23 | 32.36 | 65.6 | 97.63 | 130.99 |
| [d84bebb93](https://github.com/AFK-surf/monoid/commit/d84bebb93d3605ed0e7685d96110b71e17efd902) fix(mbui): keep in-list flights from carrying thei | 2.66 | 3.58 | 14.61 | 36.88 | 56.23 | 32.36 | 65.6 | 97.63 | 130.99 |
| [080bbe333](https://github.com/AFK-surf/monoid/commit/080bbe333df0f92f3d7e6bdf93fd21f1342c757d) fix(mbui): register native views, streams and fiel | 2.66 | 3.58 | 14.61 | 36.88 | 56.23 | 32.36 | 65.6 | 97.67 | 130.35 |
| [3ac54494d](https://github.com/AFK-surf/monoid/commit/3ac54494d41a80c7b69cf0bcd9bc6a4fe2ffd7e1) feat(mbui): continuous drag scrim, tape handoff, a | 2.66 | 3.58 | 14.61 | 36.88 | 56.23 | 32.36 | 65.6 | 97.67 | 130.35 |
| [1507e2253](https://github.com/AFK-surf/monoid/commit/1507e22534ea785ab4ba261843940966c217c28b) feat(screen): add 2K gaming quality, adaptive data | 2.66 | 3.58 | 14.61 | 36.88 | 56.23 | 32.36 | 65.6 | 97.67 | 130.35 |
| [74954dc1d](https://github.com/AFK-surf/monoid/commit/74954dc1dfc9658626efda959b8e24fc333b692a) fix(ci): retry network breaks in natives store-syn | 2.66 | 3.57 | 14.59 | 36.85 | 56.18 | 32.31 | 65.48 | 97.39 | 118.67 |
| [13f8de006](https://github.com/AFK-surf/monoid/commit/13f8de0063c785ef1dba3cfb02a5a7417f414213) feat(mbui): link film on every host, film_none.c f | 2.66 | 3.57 | 14.59 | 36.85 | 56.18 | 32.31 | 65.48 | 97.39 | 118.67 |
| [0a7668159](https://github.com/AFK-surf/monoid/commit/0a7668159a92f3431cf94e6c566f306af3a1a7de) refactor(station/mb): retire batch 1 TS parity har | 2.66 | 3.57 | 14.59 | 36.85 | 56.18 | 32.31 | 65.48 | 97.39 | 118.67 |
| [1f5003692](https://github.com/AFK-surf/monoid/commit/1f5003692dee3df202d0f1e9e9e737d504182c37) perf(mbui): expand text fast paths, reuse shape_wi | 2.66 | 3.57 | 14.59 | 36.85 | 56.18 | 32.31 | 65.48 | 97.63 | 119.45 |
| [b9717a798](https://github.com/AFK-surf/monoid/commit/b9717a7986e436479ab3981de509fdff6c0479a3) test(mb): add upstream SSE, zlib, HTTP, and FS sui | 2.66 | 3.57 | 14.59 | 36.85 | 56.18 | 32.31 | 65.48 | 97.63 | 119.45 |
| [c732e0d4a](https://github.com/AFK-surf/monoid/commit/c732e0d4a24334935b84c58e76f3e0fad3bc1466) fix(ci): settle two station test races and share t | 2.66 | 3.57 | 14.59 | 36.85 | 56.18 | 32.31 | 65.48 | 97.54 | 115.28 |
| [b07397ae4](https://github.com/AFK-surf/monoid/commit/b07397ae4c9e9a9a02e4eb69535af18025cdefc0) feat(mbui): add motion library tools, Storybook mo | 2.66 | 3.57 | 14.59 | 36.85 | 56.18 | 32.31 | 65.48 | 97.47 | 124.48 |
| [f4660800f](https://github.com/AFK-surf/monoid/commit/f4660800fb576d8f0b3e8cf824e3ffaab88cbccb) test(station): wait out two live test races (#7631 | 2.65 | 3.57 | 14.57 | 36.83 | 56.13 | 32.31 | 65.45 | 97.5 | 122.26 |
| [e38110638](https://github.com/AFK-surf/monoid/commit/e381106389934969fc0d91e8b47cdaf9c88b982f) fix(station): share the overview's decisions and m | 2.65 | 3.57 | 14.57 | 36.83 | 56.13 | 32.31 | 65.45 | 97.5 | 122.26 |
| [89c6515e8](https://github.com/AFK-surf/monoid/commit/89c6515e805073a2ebc728bf0c1c2d427732dc1f) feat(motion): add Choreography, container flies_in | 2.65 | 3.57 | 14.57 | 36.83 | 56.13 | 32.31 | 65.45 | 97.55 | 129.47 |
| [dc98cef72](https://github.com/AFK-surf/monoid/commit/dc98cef7257936ed9c503aa0b2c6ac645a12bd91) fix(mbui): let shared nodes that stay or say no id | 2.65 | 3.57 | 14.57 | 36.83 | 56.13 | 32.31 | 65.45 | 97.55 | 129.47 |
| [52b377637](https://github.com/AFK-surf/monoid/commit/52b377637c5c80019d7a1374df115db17683dc69) test(mb): add SQL, net, delta, and packed conforma | 2.65 | 3.57 | 14.57 | 36.83 | 56.13 | 32.31 | 65.45 | 97.54 | 125.56 |
| [e70fdb543](https://github.com/AFK-surf/monoid/commit/e70fdb54372d340fd72e2356100f14cdda494403) test(station): add live MoonBit parity tests for C | 2.66 | 3.57 | 14.57 | 36.83 | 56.12 | 32.29 | 65.43 | 97.76 | 120.12 |
| [099f4a3c3](https://github.com/AFK-surf/monoid/commit/099f4a3c32f9deb3c066c3dbd063d57862f27705) test(station): add dual-station MoonBit mesh/remot | 2.65 | 3.57 | 14.57 | 36.81 | 56.12 | 32.29 | 65.43 | 97.76 | 119.01 |
| [fe72a9910](https://github.com/AFK-surf/monoid/commit/fe72a991087292da3964cd067cb3cec154b6beec) fix(mbui): keep a field's keyboard while a finger  | 2.65 | 3.57 | 14.57 | 36.81 | 56.12 | 32.29 | 65.43 | 97.5 | 119.6 |
| [f89e5cb97](https://github.com/AFK-surf/monoid/commit/f89e5cb979901a22ae0f0fc9ba251f5d0ded6a97) test(station): add official upstream test corpora  | 2.65 | 3.57 | 14.57 | 36.81 | 56.11 | 32.29 | 65.43 | 97.58 | 121.01 |
| [3e334ca29](https://github.com/AFK-surf/monoid/commit/3e334ca29bf1452000486d902a0fa1bbabb80897) feat(station): add native Linux screen capture, Op | 2.65 | 3.57 | 14.57 | 36.81 | 56.11 | 32.29 | 65.43 | 97.58 | 121.01 |
| [8eb89195b](https://github.com/AFK-surf/monoid/commit/8eb89195bd4afab72ee1239a6d2bd9764d634e93) feat(screens): decouple ACK viewer_wait_us in pace | 2.65 | 3.57 | 14.57 | 36.81 | 56.11 | 32.29 | 65.43 | 97.32 | 119.75 |
| [6b8e17acf](https://github.com/AFK-surf/monoid/commit/6b8e17acf28b5c731a1feea181e4a36f8492f9fe) fix(mbui): keep zoomed flights round and native ho | 2.65 | 3.57 | 14.57 | 36.81 | 56.11 | 32.29 | 65.43 | 97.49 | 123.55 |
| [bc9485830](https://github.com/AFK-surf/monoid/commit/bc94858304607d88c8cb1819961bedae3c442597) fix(mbui): keep a list's anchor through mid-fill a | 2.65 | 3.57 | 14.57 | 36.81 | 56.11 | 32.29 | 65.43 | 97.4 | 125.75 |
| [a205e3a34](https://github.com/AFK-surf/monoid/commit/a205e3a341774588b5e85a97ede6bbff6d4e36c1) fix(sf-ui): keep file card trailing buttons clicka | 2.65 | 3.57 | 14.57 | 36.81 | 56.1 | 32.28 | 65.43 | 97.54 | 121.1 |
| [7ce56223e](https://github.com/AFK-surf/monoid/commit/7ce56223e96dfb7b96dc96ce8793adab177e3571) fix(mbui): close tree ui::field focus parity gaps  | 2.65 | 3.57 | 14.56 | 36.81 | 56.1 | 32.28 | 65.43 | 97.44 | 112.7 |
| [7e332f4cb](https://github.com/AFK-surf/monoid/commit/7e332f4cb0e38b530ba3b1792fb908b2f7cf9baa) fix(mbui): keep a tree field's asked focus while i | 2.65 | 3.57 | 14.56 | 36.81 | 56.1 | 32.28 | 65.42 | 97.52 | 127.45 |
| [7cc00a60a](https://github.com/AFK-surf/monoid/commit/7cc00a60abb50e24f50cef751dd43189fca6b426) refactor(mb): unify live_wire state helpers, intra | 2.65 | 3.57 | 14.56 | 36.8 | 56.09 | 32.28 | 65.42 | 97.47 | 122.81 |
| [cc8eb937e](https://github.com/AFK-surf/monoid/commit/cc8eb937e8b3a43fb8fa69ad55abb888880def47) fix(mbui): an effect writing what it reads keeps l | 2.65 | 3.57 | 14.56 | 36.8 | 56.09 | 32.28 | 65.42 | 97.49 | 115.86 |
| [bb4ddd828](https://github.com/AFK-surf/monoid/commit/bb4ddd82868bb17bc032c0e8e6f2469d66a5833a) refactor(mb): replace 36 pure session_chats dep RP | 2.65 | 3.57 | 14.56 | 36.8 | 56.09 | 32.28 | 65.42 | 97.49 | 115.86 |
| [4fe809bec](https://github.com/AFK-surf/monoid/commit/4fe809becbfa9f08777a883457e330f500d5b0be) fix(shell): route iroh.probeRelay to the endpoint' | 2.65 | 3.57 | 14.56 | 36.8 | 56.09 | 32.28 | 65.42 | 97.26 | 106.42 |
| [ded934c14](https://github.com/AFK-surf/monoid/commit/ded934c14444d889f4c4dac39cdb478c1bb39930) fix(ci): key core.hbc by the build's day, asked as | 2.65 | 3.57 | 14.56 | 36.8 | 56.09 | 32.28 | 65.42 | 97.54 | 122.24 |
| [8e58d60cd](https://github.com/AFK-surf/monoid/commit/8e58d60cdc346e1f5a61323f906775c892c629cb) feat(website): draw the working mark as the app's  | 2.65 | 3.57 | 14.56 | 36.8 | 56.09 | 32.28 | 65.42 | 97.62 | 125.66 |
| [abbd2198f](https://github.com/AFK-surf/monoid/commit/abbd2198fe3b526fb59c68ba015c7dd3188dce23) test(station): add MoonBit live sessions parity su | 2.65 | 3.56 | 14.53 | 36.77 | 55.96 | 32.25 | 65.32 | 97.44 | 110.92 |
| [8701788d7](https://github.com/AFK-surf/monoid/commit/8701788d7797ee74d9adf3ce9ef9335daa98cd2b) feat(mbui): float the reader's scroll-to-bottom ke | 2.65 | 3.56 | 14.53 | 36.75 | 55.96 | 32.25 | 65.32 | 97.44 | 119.22 |
| [1ff8361c1](https://github.com/AFK-surf/monoid/commit/1ff8361c11dcd13b7163c7abd5b0c0b335ec7faf) fix(station): store Feishu bot identity on MoonBit | 2.65 | 3.56 | 14.53 | 36.75 | 55.96 | 32.24 | 65.32 | 97.73 | 119.22 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [147cbffea](https://github.com/AFK-surf/monoid/commit/147cbffeab11883ae0e572fdbb1ae16c43ad2b02) ci(android): hash APK inputs in batches and put fi | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.08 |
| [07ab0ec5f](https://github.com/AFK-surf/monoid/commit/07ab0ec5fc0516223eee4dc38ded1f7ddee1389a) fix(station): read adb revokes without taking the  | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 53.94 |
| [6b2f2c4fa](https://github.com/AFK-surf/monoid/commit/6b2f2c4fad295544428147c3355ef00bba73a635) refactor(station/mb): wire session_storage directl | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 53.94 |
| [b251a55c4](https://github.com/AFK-surf/monoid/commit/b251a55c4e3f66d324cb182e76a4883372dc015c) feat(mbui): add layered NavTransition protocol, ge | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 53.94 |
| [d84bebb93](https://github.com/AFK-surf/monoid/commit/d84bebb93d3605ed0e7685d96110b71e17efd902) fix(mbui): keep in-list flights from carrying thei | 0.45 | 0.59 | 2.28 | 3.36 | 5.48 | 1.68 | 4.52 | 54.25 |
| [080bbe333](https://github.com/AFK-surf/monoid/commit/080bbe333df0f92f3d7e6bdf93fd21f1342c757d) fix(mbui): register native views, streams and fiel | 0.45 | 0.59 | 2.28 | 3.36 | 5.48 | 1.68 | 4.52 | 54.25 |
| [3ac54494d](https://github.com/AFK-surf/monoid/commit/3ac54494d41a80c7b69cf0bcd9bc6a4fe2ffd7e1) feat(mbui): continuous drag scrim, tape handoff, a | 0.45 | 0.59 | 2.28 | 3.36 | 5.48 | 1.67 | 4.52 | 54.18 |
| [1507e2253](https://github.com/AFK-surf/monoid/commit/1507e22534ea785ab4ba261843940966c217c28b) feat(screen): add 2K gaming quality, adaptive data | 0.45 | 0.59 | 2.28 | 3.36 | 5.48 | 1.67 | 4.52 | 54.12 |
| [74954dc1d](https://github.com/AFK-surf/monoid/commit/74954dc1dfc9658626efda959b8e24fc333b692a) fix(ci): retry network breaks in natives store-syn | 0.45 | 0.59 | 2.28 | 3.36 | 5.48 | 1.67 | 4.52 | 54.12 |
| [13f8de006](https://github.com/AFK-surf/monoid/commit/13f8de0063c785ef1dba3cfb02a5a7417f414213) feat(mbui): link film on every host, film_none.c f | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.2 |
| [0a7668159](https://github.com/AFK-surf/monoid/commit/0a7668159a92f3431cf94e6c566f306af3a1a7de) refactor(station/mb): retire batch 1 TS parity har | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 53.84 |
| [1f5003692](https://github.com/AFK-surf/monoid/commit/1f5003692dee3df202d0f1e9e9e737d504182c37) perf(mbui): expand text fast paths, reuse shape_wi | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 53.84 |
| [b9717a798](https://github.com/AFK-surf/monoid/commit/b9717a7986e436479ab3981de509fdff6c0479a3) test(mb): add upstream SSE, zlib, HTTP, and FS sui | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.43 |
| [c732e0d4a](https://github.com/AFK-surf/monoid/commit/c732e0d4a24334935b84c58e76f3e0fad3bc1466) fix(ci): settle two station test races and share t | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.43 |
| [b07397ae4](https://github.com/AFK-surf/monoid/commit/b07397ae4c9e9a9a02e4eb69535af18025cdefc0) feat(mbui): add motion library tools, Storybook mo | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.43 |
| [f4660800f](https://github.com/AFK-surf/monoid/commit/f4660800fb576d8f0b3e8cf824e3ffaab88cbccb) test(station): wait out two live test races (#7631 | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.43 |
| [e38110638](https://github.com/AFK-surf/monoid/commit/e381106389934969fc0d91e8b47cdaf9c88b982f) fix(station): share the overview's decisions and m | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.26 |
| [89c6515e8](https://github.com/AFK-surf/monoid/commit/89c6515e805073a2ebc728bf0c1c2d427732dc1f) feat(motion): add Choreography, container flies_in | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.26 |
| [dc98cef72](https://github.com/AFK-surf/monoid/commit/dc98cef7257936ed9c503aa0b2c6ac645a12bd91) fix(mbui): let shared nodes that stay or say no id | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.13 |
| [52b377637](https://github.com/AFK-surf/monoid/commit/52b377637c5c80019d7a1374df115db17683dc69) test(mb): add SQL, net, delta, and packed conforma | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.18 |
| [e70fdb543](https://github.com/AFK-surf/monoid/commit/e70fdb54372d340fd72e2356100f14cdda494403) test(station): add live MoonBit parity tests for C | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.18 |
| [099f4a3c3](https://github.com/AFK-surf/monoid/commit/099f4a3c32f9deb3c066c3dbd063d57862f27705) test(station): add dual-station MoonBit mesh/remot | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.18 |
| [fe72a9910](https://github.com/AFK-surf/monoid/commit/fe72a991087292da3964cd067cb3cec154b6beec) fix(mbui): keep a field's keyboard while a finger  | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.18 |
| [f89e5cb97](https://github.com/AFK-surf/monoid/commit/f89e5cb979901a22ae0f0fc9ba251f5d0ded6a97) test(station): add official upstream test corpora  | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.18 |
| [3e334ca29](https://github.com/AFK-surf/monoid/commit/3e334ca29bf1452000486d902a0fa1bbabb80897) feat(station): add native Linux screen capture, Op | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.4 |
| [8eb89195b](https://github.com/AFK-surf/monoid/commit/8eb89195bd4afab72ee1239a6d2bd9764d634e93) feat(screens): decouple ACK viewer_wait_us in pace | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.4 |
| [6b8e17acf](https://github.com/AFK-surf/monoid/commit/6b8e17acf28b5c731a1feea181e4a36f8492f9fe) fix(mbui): keep zoomed flights round and native ho | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.18 |
| [bc9485830](https://github.com/AFK-surf/monoid/commit/bc94858304607d88c8cb1819961bedae3c442597) fix(mbui): keep a list's anchor through mid-fill a | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.3 |
| [a205e3a34](https://github.com/AFK-surf/monoid/commit/a205e3a341774588b5e85a97ede6bbff6d4e36c1) fix(sf-ui): keep file card trailing buttons clicka | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.23 |
| [7ce56223e](https://github.com/AFK-surf/monoid/commit/7ce56223e96dfb7b96dc96ce8793adab177e3571) fix(mbui): close tree ui::field focus parity gaps  | 0.45 | 0.59 | 2.27 | 3.36 | 5.46 | 1.67 | 4.5 | 54.23 |
| [7e332f4cb](https://github.com/AFK-surf/monoid/commit/7e332f4cb0e38b530ba3b1792fb908b2f7cf9baa) fix(mbui): keep a tree field's asked focus while i | 0.45 | 0.59 | 2.27 | 3.36 | 5.45 | 1.67 | 4.5 | 54.13 |
| [7cc00a60a](https://github.com/AFK-surf/monoid/commit/7cc00a60abb50e24f50cef751dd43189fca6b426) refactor(mb): unify live_wire state helpers, intra | 0.45 | 0.59 | 2.27 | 3.36 | 5.45 | 1.67 | 4.48 | 54.28 |
| [cc8eb937e](https://github.com/AFK-surf/monoid/commit/cc8eb937e8b3a43fb8fa69ad55abb888880def47) fix(mbui): an effect writing what it reads keeps l | 0.45 | 0.59 | 2.27 | 3.36 | 5.45 | 1.67 | 4.48 | 54.28 |
| [bb4ddd828](https://github.com/AFK-surf/monoid/commit/bb4ddd82868bb17bc032c0e8e6f2469d66a5833a) refactor(mb): replace 36 pure session_chats dep RP | 0.45 | 0.59 | 2.27 | 3.35 | 5.45 | 1.67 | 4.48 | 54.45 |
| [4fe809bec](https://github.com/AFK-surf/monoid/commit/4fe809becbfa9f08777a883457e330f500d5b0be) fix(shell): route iroh.probeRelay to the endpoint' | 0.45 | 0.59 | 2.27 | 3.35 | 5.45 | 1.67 | 4.48 | 54.45 |
| [ded934c14](https://github.com/AFK-surf/monoid/commit/ded934c14444d889f4c4dac39cdb478c1bb39930) fix(ci): key core.hbc by the build's day, asked as | 0.45 | 0.59 | 2.27 | 3.35 | 5.45 | 1.67 | 4.48 | 54.45 |
| [8e58d60cd](https://github.com/AFK-surf/monoid/commit/8e58d60cdc346e1f5a61323f906775c892c629cb) feat(website): draw the working mark as the app's  | 0.45 | 0.59 | 2.27 | 3.35 | 5.45 | 1.67 | 4.48 | 54.45 |
| [abbd2198f](https://github.com/AFK-surf/monoid/commit/abbd2198fe3b526fb59c68ba015c7dd3188dce23) test(station): add MoonBit live sessions parity su | 0.45 | 0.59 | 2.27 | 3.35 | 5.45 | 1.67 | 4.48 | 54.45 |
| [8701788d7](https://github.com/AFK-surf/monoid/commit/8701788d7797ee74d9adf3ce9ef9335daa98cd2b) feat(mbui): float the reader's scroll-to-bottom ke | 0.45 | 0.59 | 2.27 | 3.35 | 5.45 | 1.67 | 4.48 | 54.45 |
| [1ff8361c1](https://github.com/AFK-surf/monoid/commit/1ff8361c11dcd13b7163c7abd5b0c0b335ec7faf) fix(station): store Feishu bot identity on MoonBit | 0.45 | 0.59 | 2.27 | 3.35 | 5.45 | 1.67 | 4.48 | 54.45 |
