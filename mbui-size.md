# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [d560d6d15](https://github.com/AFK-surf/monoid/commit/d560d6d156b22839338d1b11f92355afb8528fe0) perf(station): keep GET /profiles/pace's reads to  | 2.75 | 3.7 | 14.99 | 37.19 | 57.13 | 32.57 | 66.21 | 100.65 | 127.91 |
| [3a1008e52](https://github.com/AFK-surf/monoid/commit/3a1008e520a376650db65262f02e21aa52ef5f3e) fix(station): let Claude Code skip permissions on  | 2.75 | 3.7 | 14.99 | 37.19 | 57.13 | 32.57 | 66.21 | 100.65 | 127.91 |
| [c08f26292](https://github.com/AFK-surf/monoid/commit/c08f26292ab15d842d07412250cc2b99f73a22df) feat(ui): Wave 3c iOS 27.0 Liquid Glass parity acr | 2.75 | 3.7 | 14.99 | 37.19 | 57.13 | 32.57 | 66.21 | 100.65 | 127.91 |
| [1e5f6c7e9](https://github.com/AFK-surf/monoid/commit/1e5f6c7e98f36d0b9fb2fc6b72623cd1859b5f68) ci(desktop-build): separate built/cut moon cache k | 2.75 | 3.7 | 14.99 | 37.19 | 57.12 | 32.57 | 66.21 | 100.66 | 120.6 |
| [4fc759d20](https://github.com/AFK-surf/monoid/commit/4fc759d2076e82c29b7b05d86e91f2932fa66d6b) fix(mbui): hide TestFlight prompt on App Store bui | 2.75 | 3.7 | 14.99 | 37.19 | 57.12 | 32.57 | 66.21 | 100.42 | 120.6 |
| [6f91e40d4](https://github.com/AFK-surf/monoid/commit/6f91e40d40284f76d819a6d1135b4f47cf2d09cd) feat(mbui,core-ts): add pull-down search to sub-ch | 2.75 | 3.7 | 14.99 | 37.19 | 57.12 | 32.54 | 66.16 | 100.42 | 120.6 |
| [f1eaf852b](https://github.com/AFK-surf/monoid/commit/f1eaf852b6cd86ee55e472cb617558a078504507) fix(ui): isolate per-window D3D11 vertex buffers a | 2.75 | 3.7 | 14.97 | 37.17 | 57.06 | 32.54 | 66.16 | 100.42 | 108.37 |
| [ad527d4f4](https://github.com/AFK-surf/monoid/commit/ad527d4f4ef9047d0475e16afb5b7f28c8d43442) fix(ui): allocate exact CF_UNICODETEXT buffer size | 2.75 | 3.7 | 14.97 | 37.17 | 57.06 | 32.54 | 66.16 | 100.42 | 108.37 |
| [9a29a9fd0](https://github.com/AFK-surf/monoid/commit/9a29a9fd057e6c16844aef7a764f2e68e6ca88a0) fix(ui): isolate selection scopes and improve tabl | 2.75 | 3.7 | 14.97 | 37.17 | 57.06 | 32.53 | 66.11 | 100.68 | 128.12 |
| [e683562a0](https://github.com/AFK-surf/monoid/commit/e683562a0c7e088714c49ed04dbb48204f8626c2) fix(cloud): keep hints and repeat openings off the | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.68 | 123.09 |
| [3971c9513](https://github.com/AFK-surf/monoid/commit/3971c951323986b7ec7f063e25ef32defab56794) test(e2e): emit requesting status frame in fake cl | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.68 | 123.09 |
| [da1df4b8a](https://github.com/AFK-surf/monoid/commit/da1df4b8a3582f9373b19c5dfa89b72b5d449812) fix(station): never block on a CACHEDIR.TAG that i | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.68 | 123.09 |
| [f0170c00c](https://github.com/AFK-surf/monoid/commit/f0170c00c685faac64c2f74ac87b61f0c25496fc) refactor(station): detach station_main from stillf | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.68 | 123.09 |
| [08cf53d77](https://github.com/AFK-surf/monoid/commit/08cf53d7791503c7b7a528d4ad2dde6f777fb074) fix(cloud): stop hot-path storage writes on creden | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.5 | 105.48 |
| [b02677196](https://github.com/AFK-surf/monoid/commit/b0267719676c66e17fc54961dade04d9347cb222) feat(station): add reader engine selector and blac | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 120.98 |
| [a8ecd98c2](https://github.com/AFK-surf/monoid/commit/a8ecd98c2a3237ab773bcbd86e6ba6b44468f7d3) test(station): stop holding the frozen station_mai | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 120.97 |
| [73d9f3d25](https://github.com/AFK-surf/monoid/commit/73d9f3d257d00e5206e3ef176e7df6c4f5f72b0f) fix(station): run Node's admin CLI before the Moon | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [546e938ea](https://github.com/AFK-surf/monoid/commit/546e938ea59163bea3e380e00fd0c670add3fbb2) fix(ui,mbui): clear chat/composer motion exemption | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [e1dbcc2c0](https://github.com/AFK-surf/monoid/commit/e1dbcc2c02c889de1943876155f8b73771150fa5) ci: trigger station/core checks and beta release o | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [d35704a0b](https://github.com/AFK-surf/monoid/commit/d35704a0bdb6f0b65f5979c4d94897174d21c646) test(station): pick an unbound usualPort in adb po | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [75f27a56e](https://github.com/AFK-surf/monoid/commit/75f27a56e9bcf2e5051976d9d7614f913ba213a0) ci: pass read-only GH_TOKEN to native-consuming jo | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [6d01358d6](https://github.com/AFK-surf/monoid/commit/6d01358d615fe146cd58a43a09095fbeb5cc2d68) perf(pion-rules): eliminate wasm-to-js boundary an | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [2ffb45884](https://github.com/AFK-surf/monoid/commit/2ffb45884ea1350138fb869aa6315722d9987e3e) feat(pion-core): W27e pion-packages crypto-v0.4.1/ | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [539a932fd](https://github.com/AFK-surf/monoid/commit/539a932fd288b0c2149ab25ca8866dceb0c7924a) fix(station): guard replica handover removal again | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [7d4a6e7fd](https://github.com/AFK-surf/monoid/commit/7d4a6e7fd254a4a22fab46851a89cf7c110b8d3b) fix(station): sign in Google Colab profiles on the | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [0137c6212](https://github.com/AFK-surf/monoid/commit/0137c6212710357ba77f919d775790e0ac96785e) perf(station): read the sessions waiting for a per | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [e8c5ae383](https://github.com/AFK-surf/monoid/commit/e8c5ae383aeb2bea5739328cde431f1b566a997c) ci(station): run the station's tests in seven slic | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [fab977045](https://github.com/AFK-surf/monoid/commit/fab977045e7869d0f1cbfa5296a51294edbdc119) fix(ui): space a long pick's search off its first  | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 133.3 |
| [90e217a8e](https://github.com/AFK-surf/monoid/commit/90e217a8e273ca102c9676f1c3372b4291ae3dd1) fix(station): a new session on the MoonBit station | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.58 | 121.18 |
| [a9ed054f1](https://github.com/AFK-surf/monoid/commit/a9ed054f13fee12ad7b7aa5bf2f1a8019e6ef72a) feat(pion-core): native event wake, pure-C screen/ | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.58 | 121.18 |
| [576b3c3bf](https://github.com/AFK-surf/monoid/commit/576b3c3bfa187f50f42b5d062bfce9f291aba37b) feat(pion-core): W28a merged stations roster, lock | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.58 | 121.18 |
| [2074adb56](https://github.com/AFK-surf/monoid/commit/2074adb56bb048760d3da413f0ef9d71302692b9) fix(station): check borrowed API provider profiles | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.58 | 121.18 |
| [452a24829](https://github.com/AFK-surf/monoid/commit/452a248291c8ee8922510e3c11f2ed41e62d3fc4) feat(pion-core): W24-v6 1:1 views parity, chat-sha | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.58 | 121.18 |
| [cfeddd40f](https://github.com/AFK-surf/monoid/commit/cfeddd40ffa87c2fe84cd131f4e28d54ddc4449b) feat(pion-client-core): wire mesh transport, lock/ | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.58 | 121.18 |
| [b01ba4eaa](https://github.com/AFK-surf/monoid/commit/b01ba4eaa266dd5e9f43f0389fd6fca7e8317b89) feat(ui): align regular liquid glass rim/hairline  | 2.74 | 3.69 | 14.96 | 37.15 | 56.99 | 32.53 | 66.11 | 100.45 | 123.8 |
| [ca9c7827a](https://github.com/AFK-surf/monoid/commit/ca9c7827af71025ff4835dd52e9b042202099a0d) feat(rules): default Node station to Pion Wasm rul | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 116.63 |
| [c9ce75bdc](https://github.com/AFK-surf/monoid/commit/c9ce75bdcb0c5c3c0204c5f42ee4b2ec033e45d3) perf(station): project each event once for all old | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.48 | 116.63 |
| [803c9e8ea](https://github.com/AFK-surf/monoid/commit/803c9e8ea2bb8e41487ff46c1f3afa81d7597bab) fix(station): report MiniMax and GLM plan quotas ( | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.62 | 118.2 |
| [68fb3c249](https://github.com/AFK-surf/monoid/commit/68fb3c2497c138f1f8790687be24c2387b487cf3) test(mbui): hold a history group's steps at their  | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.39 | 121.54 |
| [6eb1558df](https://github.com/AFK-surf/monoid/commit/6eb1558df72482940a2d8e16fe6292a29b78c145) fix(ui): grow start-indented content from its star | 2.74 | 3.69 | 14.95 | 37.15 | 56.98 | 32.53 | 66.11 | 100.39 | 121.54 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [d560d6d15](https://github.com/AFK-surf/monoid/commit/d560d6d156b22839338d1b11f92355afb8528fe0) perf(station): keep GET /profiles/pace's reads to  | 0.55 | 0.72 | 2.82 | 3.84 | 7 | 2.07 | 5.76 | 57.56 |
| [3a1008e52](https://github.com/AFK-surf/monoid/commit/3a1008e520a376650db65262f02e21aa52ef5f3e) fix(station): let Claude Code skip permissions on  | 0.55 | 0.72 | 2.82 | 3.84 | 7 | 2.07 | 5.76 | 57.57 |
| [c08f26292](https://github.com/AFK-surf/monoid/commit/c08f26292ab15d842d07412250cc2b99f73a22df) feat(ui): Wave 3c iOS 27.0 Liquid Glass parity acr | 0.55 | 0.72 | 2.82 | 3.84 | 7 | 2.07 | 5.76 | 57.51 |
| [1e5f6c7e9](https://github.com/AFK-surf/monoid/commit/1e5f6c7e98f36d0b9fb2fc6b72623cd1859b5f68) ci(desktop-build): separate built/cut moon cache k | 0.55 | 0.72 | 2.82 | 3.83 | 7 | 2.07 | 5.74 | 57.61 |
| [4fc759d20](https://github.com/AFK-surf/monoid/commit/4fc759d2076e82c29b7b05d86e91f2932fa66d6b) fix(mbui): hide TestFlight prompt on App Store bui | 0.55 | 0.72 | 2.82 | 3.83 | 7 | 2.07 | 5.74 | 57.38 |
| [6f91e40d4](https://github.com/AFK-surf/monoid/commit/6f91e40d40284f76d819a6d1135b4f47cf2d09cd) feat(mbui,core-ts): add pull-down search to sub-ch | 0.55 | 0.72 | 2.82 | 3.83 | 7 | 2.07 | 5.74 | 57.38 |
| [f1eaf852b](https://github.com/AFK-surf/monoid/commit/f1eaf852b6cd86ee55e472cb617558a078504507) fix(ui): isolate per-window D3D11 vertex buffers a | 0.55 | 0.72 | 2.82 | 3.83 | 7 | 2.07 | 5.74 | 57.56 |
| [ad527d4f4](https://github.com/AFK-surf/monoid/commit/ad527d4f4ef9047d0475e16afb5b7f28c8d43442) fix(ui): allocate exact CF_UNICODETEXT buffer size | 0.55 | 0.72 | 2.82 | 3.83 | 6.99 | 2.07 | 5.74 | 57.38 |
| [9a29a9fd0](https://github.com/AFK-surf/monoid/commit/9a29a9fd057e6c16844aef7a764f2e68e6ca88a0) fix(ui): isolate selection scopes and improve tabl | 0.55 | 0.72 | 2.82 | 3.83 | 6.99 | 2.07 | 5.74 | 57.51 |
| [e683562a0](https://github.com/AFK-surf/monoid/commit/e683562a0c7e088714c49ed04dbb48204f8626c2) fix(cloud): keep hints and repeat openings off the | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.71 |
| [3971c9513](https://github.com/AFK-surf/monoid/commit/3971c951323986b7ec7f063e25ef32defab56794) test(e2e): emit requesting status frame in fake cl | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.28 |
| [da1df4b8a](https://github.com/AFK-surf/monoid/commit/da1df4b8a3582f9373b19c5dfa89b72b5d449812) fix(station): never block on a CACHEDIR.TAG that i | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.18 |
| [f0170c00c](https://github.com/AFK-surf/monoid/commit/f0170c00c685faac64c2f74ac87b61f0c25496fc) refactor(station): detach station_main from stillf | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.2 |
| [08cf53d77](https://github.com/AFK-surf/monoid/commit/08cf53d7791503c7b7a528d4ad2dde6f777fb074) fix(cloud): stop hot-path storage writes on creden | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.46 |
| [b02677196](https://github.com/AFK-surf/monoid/commit/b0267719676c66e17fc54961dade04d9347cb222) feat(station): add reader engine selector and blac | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.03 |
| [a8ecd98c2](https://github.com/AFK-surf/monoid/commit/a8ecd98c2a3237ab773bcbd86e6ba6b44468f7d3) test(station): stop holding the frozen station_mai | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.35 |
| [73d9f3d25](https://github.com/AFK-surf/monoid/commit/73d9f3d257d00e5206e3ef176e7df6c4f5f72b0f) fix(station): run Node's admin CLI before the Moon | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.33 |
| [546e938ea](https://github.com/AFK-surf/monoid/commit/546e938ea59163bea3e380e00fd0c670add3fbb2) fix(ui,mbui): clear chat/composer motion exemption | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.49 |
| [e1dbcc2c0](https://github.com/AFK-surf/monoid/commit/e1dbcc2c02c889de1943876155f8b73771150fa5) ci: trigger station/core checks and beta release o | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.3 |
| [d35704a0b](https://github.com/AFK-surf/monoid/commit/d35704a0bdb6f0b65f5979c4d94897174d21c646) test(station): pick an unbound usualPort in adb po | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.3 |
| [75f27a56e](https://github.com/AFK-surf/monoid/commit/75f27a56e9bcf2e5051976d9d7614f913ba213a0) ci: pass read-only GH_TOKEN to native-consuming jo | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.46 |
| [6d01358d6](https://github.com/AFK-surf/monoid/commit/6d01358d615fe146cd58a43a09095fbeb5cc2d68) perf(pion-rules): eliminate wasm-to-js boundary an | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.41 |
| [2ffb45884](https://github.com/AFK-surf/monoid/commit/2ffb45884ea1350138fb869aa6315722d9987e3e) feat(pion-core): W27e pion-packages crypto-v0.4.1/ | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.3 |
| [539a932fd](https://github.com/AFK-surf/monoid/commit/539a932fd288b0c2149ab25ca8866dceb0c7924a) fix(station): guard replica handover removal again | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.41 |
| [7d4a6e7fd](https://github.com/AFK-surf/monoid/commit/7d4a6e7fd254a4a22fab46851a89cf7c110b8d3b) fix(station): sign in Google Colab profiles on the | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.26 |
| [0137c6212](https://github.com/AFK-surf/monoid/commit/0137c6212710357ba77f919d775790e0ac96785e) perf(station): read the sessions waiting for a per | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.51 |
| [e8c5ae383](https://github.com/AFK-surf/monoid/commit/e8c5ae383aeb2bea5739328cde431f1b566a997c) ci(station): run the station's tests in seven slic | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.3 |
| [fab977045](https://github.com/AFK-surf/monoid/commit/fab977045e7869d0f1cbfa5296a51294edbdc119) fix(ui): space a long pick's search off its first  | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.3 |
| [90e217a8e](https://github.com/AFK-surf/monoid/commit/90e217a8e273ca102c9676f1c3372b4291ae3dd1) fix(station): a new session on the MoonBit station | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.54 |
| [a9ed054f1](https://github.com/AFK-surf/monoid/commit/a9ed054f13fee12ad7b7aa5bf2f1a8019e6ef72a) feat(pion-core): native event wake, pure-C screen/ | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.54 |
| [576b3c3bf](https://github.com/AFK-surf/monoid/commit/576b3c3bfa187f50f42b5d062bfce9f291aba37b) feat(pion-core): W28a merged stations roster, lock | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.25 |
| [2074adb56](https://github.com/AFK-surf/monoid/commit/2074adb56bb048760d3da413f0ef9d71302692b9) fix(station): check borrowed API provider profiles | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.18 |
| [452a24829](https://github.com/AFK-surf/monoid/commit/452a248291c8ee8922510e3c11f2ed41e62d3fc4) feat(pion-core): W24-v6 1:1 views parity, chat-sha | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.12 |
| [cfeddd40f](https://github.com/AFK-surf/monoid/commit/cfeddd40ffa87c2fe84cd131f4e28d54ddc4449b) feat(pion-client-core): wire mesh transport, lock/ | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.39 |
| [b01ba4eaa](https://github.com/AFK-surf/monoid/commit/b01ba4eaa266dd5e9f43f0389fd6fca7e8317b89) feat(ui): align regular liquid glass rim/hairline  | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.15 |
| [ca9c7827a](https://github.com/AFK-surf/monoid/commit/ca9c7827af71025ff4835dd52e9b042202099a0d) feat(rules): default Node station to Pion Wasm rul | 0.55 | 0.72 | 2.8 | 3.81 | 6.93 | 2.05 | 5.71 | 57.26 |
| [c9ce75bdc](https://github.com/AFK-surf/monoid/commit/c9ce75bdcb0c5c3c0204c5f42ee4b2ec033e45d3) perf(station): project each event once for all old | 0.55 | 0.72 | 2.8 | 3.81 | 6.92 | 2.05 | 5.69 | 57.16 |
| [803c9e8ea](https://github.com/AFK-surf/monoid/commit/803c9e8ea2bb8e41487ff46c1f3afa81d7597bab) fix(station): report MiniMax and GLM plan quotas ( | 0.55 | 0.72 | 2.8 | 3.81 | 6.92 | 2.05 | 5.69 | 57.16 |
| [68fb3c249](https://github.com/AFK-surf/monoid/commit/68fb3c2497c138f1f8790687be24c2387b487cf3) test(mbui): hold a history group's steps at their  | 0.55 | 0.72 | 2.8 | 3.81 | 6.92 | 2.05 | 5.69 | 57.23 |
| [6eb1558df](https://github.com/AFK-surf/monoid/commit/6eb1558df72482940a2d8e16fe6292a29b78c145) fix(ui): grow start-indented content from its star | 0.55 | 0.72 | 2.8 | 3.81 | 6.92 | 2.05 | 5.69 | 57.07 |
