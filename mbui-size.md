# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [3ff199971](https://github.com/AFK-surf/monoid/commit/3ff19997143a331df663142bccbc2546744c5327) refactor(mbui): hoist invariant reads and simplify | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.74 | 118.11 |
| [94a5b9728](https://github.com/AFK-surf/monoid/commit/94a5b97280aa7ec730e3db48e0df1841d3c73767) perf(core): replace byte flatMap spreads with Uint | 2.74 | 3.72 | 15.43 | 38.52 | 59.57 | 33.77 | 69.06 | 103.6 | 135.11 |
| [92be89c03](https://github.com/AFK-surf/monoid/commit/92be89c034ea1bc12b4464c3a5fd084c2aab43d0) feat(station-main): wire device/screen/browser MCP | 2.74 | 3.72 | 15.43 | 38.52 | 59.57 | 33.77 | 69.06 | 103.6 | 135.11 |
| [cd9bea710](https://github.com/AFK-surf/monoid/commit/cd9bea710ec3962cc8e130f086d62c290593dad6) fix(cli): guard trailing argument slices in bin/st | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [a394ec41d](https://github.com/AFK-surf/monoid/commit/a394ec41db47ed51d1a5269f6d977c6d6e44728b) perf(core): combine said passes and index mine seq | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [e6de3d544](https://github.com/AFK-surf/monoid/commit/e6de3d544978c607e183a6447b40f60adad578b1) ci(scripts): include bin TypeScript files in ts_ro | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [546256e51](https://github.com/AFK-surf/monoid/commit/546256e51f492d8fd08fd4a8d3778407924acb7f) perf(cloud): batch feedbackOf queries and prefilte | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [f15c1b48b](https://github.com/AFK-surf/monoid/commit/f15c1b48b489d114894328d54adf3c6ca340e1a6) perf(cloud): reuse alike view across changed and v | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [b36540849](https://github.com/AFK-surf/monoid/commit/b36540849e22ddfc78085d85b6f90f63d3b22beb) perf(cloud): skip no-op storage writes and Directo | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [61f498278](https://github.com/AFK-surf/monoid/commit/61f498278d600851896ab5354143636d4d1e7a7b) perf(cloud): add SQLite indexes for hot Directory  | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [90c65ef4a](https://github.com/AFK-surf/monoid/commit/90c65ef4a7bf6a97695a910e98f370d1458d03e2) feat(pion-core): add PendingAuthConfirm, admitted_ | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [c09350c0b](https://github.com/AFK-surf/monoid/commit/c09350c0bc20bc276d00dd73d913c9319c8fb6b1) fix(cloud): match weak If-None-Match headers and c | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [02544a117](https://github.com/AFK-surf/monoid/commit/02544a11796d97f393e109172f7fd1d7a00a8d25) fix(install): stage unpacked release on data files | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [c4362f5f7](https://github.com/AFK-surf/monoid/commit/c4362f5f7427daa525820fb0d22fd5819a23c5b0) fix(station): preserve Slack ordered list numberin | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.7 | 130.13 |
| [e196a2778](https://github.com/AFK-surf/monoid/commit/e196a27789a9bbe5a84d0a6138ac178716863e7e) feat(station-main): wire 17 live updates, accounts | 2.74 | 3.72 | 15.43 | 38.52 | 59.56 | 33.77 | 69.06 | 103.68 | 120.63 |
| [258434e6d](https://github.com/AFK-surf/monoid/commit/258434e6dce28924e77455fce7222cb52a75add2) perf(core): open a leading chat without reading it | 2.74 | 3.71 | 15.4 | 38.51 | 59.55 | 33.76 | 69.05 | 103.94 | 133.96 |
| [063dabbb3](https://github.com/AFK-surf/monoid/commit/063dabbb3797b9316cac9754f27c8f27070ec32b) feat(station-pion): wire Wave 17D-1 all 11 Vault a | 2.74 | 3.71 | 15.4 | 38.51 | 59.55 | 33.76 | 69.05 | 103.94 | 133.96 |
| [27a53d081](https://github.com/AFK-surf/monoid/commit/27a53d08133b7af8b17d41ba87a702438f31b6e0) perf(ui): optimize bit-exact skia/svg rasterizatio | 2.74 | 3.71 | 15.4 | 38.51 | 59.55 | 33.76 | 69.05 | 103.94 | 133.96 |
| [32342a0a7](https://github.com/AFK-surf/monoid/commit/32342a0a73a0ed5cc0f278893c38ea669f96d735) fix(station): requeue unread steered inputs on tra | 2.74 | 3.71 | 15.4 | 38.51 | 59.55 | 33.76 | 69.05 | 103.94 | 133.96 |
| [6d17e28e2](https://github.com/AFK-surf/monoid/commit/6d17e28e27b1b2955d09c57cf9e05da77997c3d1) feat(station-main): wire 10 interactive call_ops a | 2.74 | 3.71 | 15.39 | 38.51 | 59.55 | 33.75 | 69.05 | 103.61 | 127.18 |
| [256a6e6f1](https://github.com/AFK-surf/monoid/commit/256a6e6f1a314819c4bec7734251b4fb3c483c93) fix(ui,mbui): soften scroll-edge .soft fade curve  | 2.74 | 3.71 | 15.39 | 38.51 | 59.55 | 33.75 | 69.05 | 103.61 | 127.18 |
| [2cc9a6279](https://github.com/AFK-surf/monoid/commit/2cc9a627904b345c85a1191d94d48af05f20cf35) fix(ui,mbui): align iOS 27 sheet grabber, modal ti | 2.74 | 3.71 | 15.39 | 38.51 | 59.55 | 33.75 | 69.05 | 103.61 | 127.18 |
| [cba4de5f0](https://github.com/AFK-surf/monoid/commit/cba4de5f05ca9a62bf03454d1637dd6f03937070) refactor(mbui): hoist invariant reads out of iter  | 2.74 | 3.71 | 15.39 | 38.51 | 59.55 | 33.75 | 69.05 | 103.61 | 127.18 |
| [f92fad1dc](https://github.com/AFK-surf/monoid/commit/f92fad1dc2a9440d7fa5fcd025153adba15080ec) feat(station-main): wire live stillfail-runner tur | 2.74 | 3.71 | 15.39 | 38.51 | 59.55 | 33.75 | 69.05 | 103.81 | 116.86 |
| [06568399d](https://github.com/AFK-surf/monoid/commit/06568399dea9bf9ddb45fc4ea64f1b7520be2459) fix(ci): keep staged handovers for put reruns and  | 2.74 | 3.71 | 15.39 | 38.51 | 59.55 | 33.75 | 69.05 | 103.81 | 116.86 |
| [b87c497ea](https://github.com/AFK-surf/monoid/commit/b87c497ea9240be77e404ac03ec66fe6457d8365) refactor(mbui): use named key structs for the last | 2.74 | 3.71 | 15.39 | 38.51 | 59.55 | 33.75 | 69.05 | 103.68 | 128.17 |
| [b87c497ea](https://github.com/AFK-surf/monoid/commit/b87c497ea9240be77e404ac03ec66fe6457d8365) refactor(mbui): use named key structs for the last | 2.74 | 3.71 | 15.39 | 38.51 | 59.55 | 33.75 | 69.03 | 103.65 | 122.94 |
| [2ad497b3a](https://github.com/AFK-surf/monoid/commit/2ad497b3a3ed3000712abba3bb4293702f546b8b) feat(pion-core): add account DB lifecycle, non-ree | 2.74 | 3.71 | 15.39 | 38.51 | 59.53 | 33.75 | 69.03 | 103.65 | 122.94 |
| [a6465c140](https://github.com/AFK-surf/monoid/commit/a6465c140f77b23adc174d21dcb75c3ffa02e42c) perf(ui): skip look-only withins passes and time t | 2.74 | 3.71 | 15.39 | 38.51 | 59.53 | 33.75 | 69.03 | 103.65 | 122.94 |
| [7841c1f72](https://github.com/AFK-surf/monoid/commit/7841c1f721767c6012292e73d48c2ead4af27370) test(station): bind mesh port 0 in retire harness  | 2.74 | 3.71 | 15.39 | 38.51 | 59.53 | 33.75 | 69.03 | 103.65 | 125.47 |
| [d19a0458c](https://github.com/AFK-surf/monoid/commit/d19a0458c9e4ad9dd7b8bebbc6460e1be3e14591) fix(ci,station): fix macOS readlink fallback in bi | 2.74 | 3.71 | 15.39 | 38.51 | 59.53 | 33.75 | 69.03 | 103.65 | 125.47 |
| [2e7445a86](https://github.com/AFK-surf/monoid/commit/2e7445a866ebe508ce29b2e8e4bcc6cd9c1b9e4b) refactor(mbui): use named key structs instead of t | 2.74 | 3.71 | 15.39 | 38.51 | 59.53 | 33.75 | 69.03 | 103.65 | 125.47 |
| [23c599a29](https://github.com/AFK-surf/monoid/commit/23c599a293d3ef84bd3c3a34f272d1dbfd2a4606) fix(mesh): filter benchmarking IPs from lookup and | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.03 | 103.88 | 134.72 |
| [9c79d355d](https://github.com/AFK-surf/monoid/commit/9c79d355d73ecce1dbbef8d649c8aaaa4700430b) chore(mbui): replace 5 cross-pkg iter().any/search | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 104.06 | 138.98 |
| [b1ff26ba8](https://github.com/AFK-surf/monoid/commit/b1ff26ba84e7b3c2b2f8922a7d0d9949062d2af8) ci(station): eliminate SQLite fsync storms in 13 t | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 103.89 | 133.3 |
| [527dadfe2](https://github.com/AFK-surf/monoid/commit/527dadfe2b7f452c3f6cd04c4a8891ebb3362ada) refactor(ui): drop defer and inferred closure type | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 103.89 | 133.3 |
| [eb8640e16](https://github.com/AFK-surf/monoid/commit/eb8640e1621fb1bf208ce0da5bea70ed05b8bc9f) feat(station): wire Wave 17C-3A ReadOps, CRDT reco | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 103.86 | 134.86 |
| [439eb89e1](https://github.com/AFK-surf/monoid/commit/439eb89e193662fcccc755821cc07dff97273fef) feat(station-pion): wire Wave 17C-3B admin setting | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 103.86 | 134.86 |
| [9c220ed9b](https://github.com/AFK-surf/monoid/commit/9c220ed9b2b5fb4b3120d15b67fdbd95a221dc6f) refactor(ui): name kit and controls keys and types | 2.74 | 3.71 | 15.38 | 38.5 | 59.52 | 33.75 | 69.01 | 103.86 | 134.86 |
| [365cbebe5](https://github.com/AFK-surf/monoid/commit/365cbebe507252b8cafce8b2579221bb8e9332fe) perf(ui): cache iOS 27 prominent-tab overflow chec | 2.74 | 3.71 | 15.38 | 38.49 | 59.49 | 33.74 | 69.01 | 103.6 | 128.41 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [3ff199971](https://github.com/AFK-surf/monoid/commit/3ff19997143a331df663142bccbc2546744c5327) refactor(mbui): hoist invariant reads and simplify | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.74 |
| [94a5b9728](https://github.com/AFK-surf/monoid/commit/94a5b97280aa7ec730e3db48e0df1841d3c73767) perf(core): replace byte flatMap spreads with Uint | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.89 |
| [92be89c03](https://github.com/AFK-surf/monoid/commit/92be89c034ea1bc12b4464c3a5fd084c2aab43d0) feat(station-main): wire device/screen/browser MCP | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.72 |
| [cd9bea710](https://github.com/AFK-surf/monoid/commit/cd9bea710ec3962cc8e130f086d62c290593dad6) fix(cli): guard trailing argument slices in bin/st | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.87 |
| [a394ec41d](https://github.com/AFK-surf/monoid/commit/a394ec41db47ed51d1a5269f6d977c6d6e44728b) perf(core): combine said passes and index mine seq | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.72 |
| [e6de3d544](https://github.com/AFK-surf/monoid/commit/e6de3d544978c607e183a6447b40f60adad578b1) ci(scripts): include bin TypeScript files in ts_ro | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.66 |
| [546256e51](https://github.com/AFK-surf/monoid/commit/546256e51f492d8fd08fd4a8d3778407924acb7f) perf(cloud): batch feedbackOf queries and prefilte | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.59 |
| [f15c1b48b](https://github.com/AFK-surf/monoid/commit/f15c1b48b489d114894328d54adf3c6ca340e1a6) perf(cloud): reuse alike view across changed and v | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.8 |
| [b36540849](https://github.com/AFK-surf/monoid/commit/b36540849e22ddfc78085d85b6f90f63d3b22beb) perf(cloud): skip no-op storage writes and Directo | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 65.03 |
| [61f498278](https://github.com/AFK-surf/monoid/commit/61f498278d600851896ab5354143636d4d1e7a7b) perf(cloud): add SQLite indexes for hot Directory  | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.87 |
| [90c65ef4a](https://github.com/AFK-surf/monoid/commit/90c65ef4a7bf6a97695a910e98f370d1458d03e2) feat(pion-core): add PendingAuthConfirm, admitted_ | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.56 |
| [c09350c0b](https://github.com/AFK-surf/monoid/commit/c09350c0bc20bc276d00dd73d913c9319c8fb6b1) fix(cloud): match weak If-None-Match headers and c | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.95 |
| [02544a117](https://github.com/AFK-surf/monoid/commit/02544a11796d97f393e109172f7fd1d7a00a8d25) fix(install): stage unpacked release on data files | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.82 |
| [c4362f5f7](https://github.com/AFK-surf/monoid/commit/c4362f5f7427daa525820fb0d22fd5819a23c5b0) fix(station): preserve Slack ordered list numberin | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.43 |
| [e196a2778](https://github.com/AFK-surf/monoid/commit/e196a27789a9bbe5a84d0a6138ac178716863e7e) feat(station-main): wire 17 live updates, accounts | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.72 |
| [258434e6d](https://github.com/AFK-surf/monoid/commit/258434e6dce28924e77455fce7222cb52a75add2) perf(core): open a leading chat without reading it | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.49 |
| [063dabbb3](https://github.com/AFK-surf/monoid/commit/063dabbb3797b9316cac9754f27c8f27070ec32b) feat(station-pion): wire Wave 17D-1 all 11 Vault a | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.8 |
| [27a53d081](https://github.com/AFK-surf/monoid/commit/27a53d08133b7af8b17d41ba87a702438f31b6e0) perf(ui): optimize bit-exact skia/svg rasterizatio | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.8 |
| [32342a0a7](https://github.com/AFK-surf/monoid/commit/32342a0a73a0ed5cc0f278893c38ea669f96d735) fix(station): requeue unread steered inputs on tra | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.67 |
| [6d17e28e2](https://github.com/AFK-surf/monoid/commit/6d17e28e27b1b2955d09c57cf9e05da77997c3d1) feat(station-main): wire 10 interactive call_ops a | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.77 |
| [256a6e6f1](https://github.com/AFK-surf/monoid/commit/256a6e6f1a314819c4bec7734251b4fb3c483c93) fix(ui,mbui): soften scroll-edge .soft fade curve  | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.75 |
| [2cc9a6279](https://github.com/AFK-surf/monoid/commit/2cc9a627904b345c85a1191d94d48af05f20cf35) fix(ui,mbui): align iOS 27 sheet grabber, modal ti | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.79 |
| [cba4de5f0](https://github.com/AFK-surf/monoid/commit/cba4de5f05ca9a62bf03454d1637dd6f03937070) refactor(mbui): hoist invariant reads out of iter  | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.95 |
| [f92fad1dc](https://github.com/AFK-surf/monoid/commit/f92fad1dc2a9440d7fa5fcd025153adba15080ec) feat(station-main): wire live stillfail-runner tur | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.75 |
| [06568399d](https://github.com/AFK-surf/monoid/commit/06568399dea9bf9ddb45fc4ea64f1b7520be2459) fix(ci): keep staged handovers for put reruns and  | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.87 |
| [b87c497ea](https://github.com/AFK-surf/monoid/commit/b87c497ea9240be77e404ac03ec66fe6457d8365) refactor(mbui): use named key structs for the last | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.72 |
| [b87c497ea](https://github.com/AFK-surf/monoid/commit/b87c497ea9240be77e404ac03ec66fe6457d8365) refactor(mbui): use named key structs for the last | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.82 |
| [2ad497b3a](https://github.com/AFK-surf/monoid/commit/2ad497b3a3ed3000712abba3bb4293702f546b8b) feat(pion-core): add account DB lifecycle, non-ree | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.82 |
| [a6465c140](https://github.com/AFK-surf/monoid/commit/a6465c140f77b23adc174d21dcb75c3ffa02e42c) perf(ui): skip look-only withins passes and time t | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.82 |
| [7841c1f72](https://github.com/AFK-surf/monoid/commit/7841c1f721767c6012292e73d48c2ead4af27370) test(station): bind mesh port 0 in retire harness  | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.64 |
| [d19a0458c](https://github.com/AFK-surf/monoid/commit/d19a0458c9e4ad9dd7b8bebbc6460e1be3e14591) fix(ci,station): fix macOS readlink fallback in bi | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.82 |
| [2e7445a86](https://github.com/AFK-surf/monoid/commit/2e7445a866ebe508ce29b2e8e4bcc6cd9c1b9e4b) refactor(mbui): use named key structs instead of t | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.71 |
| [23c599a29](https://github.com/AFK-surf/monoid/commit/23c599a293d3ef84bd3c3a34f272d1dbfd2a4606) fix(mesh): filter benchmarking IPs from lookup and | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.9 |
| [9c79d355d](https://github.com/AFK-surf/monoid/commit/9c79d355d73ecce1dbbef8d649c8aaaa4700430b) chore(mbui): replace 5 cross-pkg iter().any/search | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.67 |
| [b1ff26ba8](https://github.com/AFK-surf/monoid/commit/b1ff26ba84e7b3c2b2f8922a7d0d9949062d2af8) ci(station): eliminate SQLite fsync storms in 13 t | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.75 |
| [527dadfe2](https://github.com/AFK-surf/monoid/commit/527dadfe2b7f452c3f6cd04c4a8891ebb3362ada) refactor(ui): drop defer and inferred closure type | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.87 |
| [eb8640e16](https://github.com/AFK-surf/monoid/commit/eb8640e1621fb1bf208ce0da5bea70ed05b8bc9f) feat(station): wire Wave 17C-3A ReadOps, CRDT reco | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.84 |
| [439eb89e1](https://github.com/AFK-surf/monoid/commit/439eb89e193662fcccc755821cc07dff97273fef) feat(station-pion): wire Wave 17C-3B admin setting | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.85 |
| [9c220ed9b](https://github.com/AFK-surf/monoid/commit/9c220ed9b2b5fb4b3120d15b67fdbd95a221dc6f) refactor(ui): name kit and controls keys and types | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.69 |
| [365cbebe5](https://github.com/AFK-surf/monoid/commit/365cbebe507252b8cafce8b2579221bb8e9332fe) perf(ui): cache iOS 27 prominent-tab overflow chec | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.9 |
