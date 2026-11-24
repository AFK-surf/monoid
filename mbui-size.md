# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [9d9b96358](https://github.com/AFK-surf/monoid/commit/9d9b96358c94ecc736a542e2ed99e9a85e1f846e) refactor(ui,mbui): clean dead controls APIs and un | 2.74 | 3.69 | 14.95 | 37.14 | 56.95 | 32.52 | 66.07 | 100.6 | 114.59 |
| [db2b6cdf5](https://github.com/AFK-surf/monoid/commit/db2b6cdf503a0fb378b372704da3c95cdf18c266) fix(pion-client-core): enforce lock genesis pinnin | 2.74 | 3.69 | 14.95 | 37.14 | 56.95 | 32.52 | 66.07 | 100.48 | 127.55 |
| [c4160616f](https://github.com/AFK-surf/monoid/commit/c4160616f52038080e27860eed80bdc1eab6592e) perf(station): keep the hub's config when a check  | 2.74 | 3.69 | 14.95 | 37.14 | 56.94 | 32.52 | 66.06 | 101.3 | 131.39 |
| [cabc742d9](https://github.com/AFK-surf/monoid/commit/cabc742d9fa13e6f7852c7ed5cb67dc16b6f5e99) perf(mbui): prewarm offscreen home chat row text a | 2.74 | 3.69 | 14.95 | 37.14 | 56.94 | 32.52 | 66.06 | 101.3 | 131.39 |
| [f32384c6d](https://github.com/AFK-surf/monoid/commit/f32384c6dbc05992d004ddb2b4e03375664f5820) feat(ui): calibrate pressed liquid glass lens and  | 2.74 | 3.69 | 14.95 | 37.14 | 56.93 | 32.51 | 66.04 | 101.09 | 118.55 |
| [95f976d6c](https://github.com/AFK-surf/monoid/commit/95f976d6c3688024ab1db21177b5246a5bd461d6) fix(ui): keep a flying container's shadow drawn on | 2.74 | 3.69 | 14.95 | 37.14 | 56.93 | 32.51 | 66.04 | 101.09 | 118.55 |
| [714c5b362](https://github.com/AFK-surf/monoid/commit/714c5b362fa652cdab0dc3e615011a3a0de050c0) fix(ci): rebalance rules-fork and replica-retire s | 2.74 | 3.69 | 14.95 | 37.13 | 56.92 | 32.51 | 66.04 | 100.96 | 117.5 |
| [10a0c2b8f](https://github.com/AFK-surf/monoid/commit/10a0c2b8fce2642bdf8ae2f8295396bec0914be3) feat(ui,mbui): Phase 3B explicit StageOrigin, clea | 2.74 | 3.69 | 14.95 | 37.13 | 56.92 | 32.51 | 66.04 | 100.96 | 117.5 |
| [e038a5c0b](https://github.com/AFK-surf/monoid/commit/e038a5c0b698b0b6a3394a6e2da695bef8f89b83) feat(station): cap default remote browser screenca | 2.74 | 3.69 | 14.94 | 37.13 | 56.92 | 32.51 | 66.04 | 101.22 | 120.35 |
| [a8b332d2f](https://github.com/AFK-surf/monoid/commit/a8b332d2f3eeaa44a1fabefd96f5af2913772a35) test(e2e): serialize fake claude turns, send held  | 2.74 | 3.69 | 14.94 | 37.13 | 56.92 | 32.51 | 66.04 | 101.17 | 144.6 |
| [e4c4c5abc](https://github.com/AFK-surf/monoid/commit/e4c4c5abc0fbcde0da13426e38aa22c8bd3d35be) feat(pion-core): wake the core worker natively and | 2.74 | 3.69 | 14.94 | 37.13 | 56.92 | 32.51 | 66.04 | 101.17 | 144.6 |
| [55d4cd98a](https://github.com/AFK-surf/monoid/commit/55d4cd98aad6acb1b3ae9d2a29095da6b76d4481) refactor(ui): migrate controls overlays, drawer, a | 2.74 | 3.69 | 14.94 | 37.13 | 56.92 | 32.51 | 66.02 | 101.02 | 97.79 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [9d9b96358](https://github.com/AFK-surf/monoid/commit/9d9b96358c94ecc736a542e2ed99e9a85e1f846e) refactor(ui,mbui): clean dead controls APIs and un | 0.55 | 0.72 | 2.8 | 3.81 | 6.9 | 2.04 | 5.68 | 57.31 |
| [db2b6cdf5](https://github.com/AFK-surf/monoid/commit/db2b6cdf503a0fb378b372704da3c95cdf18c266) fix(pion-client-core): enforce lock genesis pinnin | 0.55 | 0.72 | 2.8 | 3.81 | 6.9 | 2.04 | 5.68 | 57.31 |
| [c4160616f](https://github.com/AFK-surf/monoid/commit/c4160616f52038080e27860eed80bdc1eab6592e) perf(station): keep the hub's config when a check  | 0.55 | 0.72 | 2.8 | 3.81 | 6.9 | 2.04 | 5.68 | 57.85 |
| [cabc742d9](https://github.com/AFK-surf/monoid/commit/cabc742d9fa13e6f7852c7ed5cb67dc16b6f5e99) perf(mbui): prewarm offscreen home chat row text a | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.85 |
| [f32384c6d](https://github.com/AFK-surf/monoid/commit/f32384c6dbc05992d004ddb2b4e03375664f5820) feat(ui): calibrate pressed liquid glass lens and  | 0.55 | 0.72 | 2.8 | 3.81 | 6.9 | 2.04 | 5.68 | 57.28 |
| [95f976d6c](https://github.com/AFK-surf/monoid/commit/95f976d6c3688024ab1db21177b5246a5bd461d6) fix(ui): keep a flying container's shadow drawn on | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.61 |
| [714c5b362](https://github.com/AFK-surf/monoid/commit/714c5b362fa652cdab0dc3e615011a3a0de050c0) fix(ci): rebalance rules-fork and replica-retire s | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.79 |
| [10a0c2b8f](https://github.com/AFK-surf/monoid/commit/10a0c2b8fce2642bdf8ae2f8295396bec0914be3) feat(ui,mbui): Phase 3B explicit StageOrigin, clea | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.9 |
| [e038a5c0b](https://github.com/AFK-surf/monoid/commit/e038a5c0b698b0b6a3394a6e2da695bef8f89b83) feat(station): cap default remote browser screenca | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.9 |
| [a8b332d2f](https://github.com/AFK-surf/monoid/commit/a8b332d2f3eeaa44a1fabefd96f5af2913772a35) test(e2e): serialize fake claude turns, send held  | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.93 |
| [e4c4c5abc](https://github.com/AFK-surf/monoid/commit/e4c4c5abc0fbcde0da13426e38aa22c8bd3d35be) feat(pion-core): wake the core worker natively and | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.85 |
| [55d4cd98a](https://github.com/AFK-surf/monoid/commit/55d4cd98aad6acb1b3ae9d2a29095da6b76d4481) refactor(ui): migrate controls overlays, drawer, a | 0.55 | 0.72 | 2.8 | 3.81 | 6.89 | 2.04 | 5.66 | 57.8 |
