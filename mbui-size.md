# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [1804448f4](https://github.com/AFK-surf/monoid/commit/1804448f4ffb8b13674d01502c64cde76ef7e908) docs(releases): 0.1.11553 stable notes (#8888) | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.52 | 122.87 |
| [354decda1](https://github.com/AFK-surf/monoid/commit/354decda1ca733035a69dc6a0b364bffc2547f43) perf(ui,web): stop calling gl.invalidateFramebuffe | 2.63 | 3.55 | 14.69 | 37.52 | 57.41 | 32.84 | 66.96 | 101.45 | 114.79 |
| [e256e703c](https://github.com/AFK-surf/monoid/commit/e256e703c4bd409cdc85efe4196f089383505a8d) test(station): follow the current mesh port during | 2.63 | 3.55 | 14.69 | 37.52 | 57.41 | 32.84 | 66.96 | 101.45 | 114.79 |
| [c7da62951](https://github.com/AFK-surf/monoid/commit/c7da629516b59b6a2ca85a1c1fa45c58f9885cbf) fix(mesh): stop noq-udp recv_single busy-loop afte | 2.63 | 3.55 | 14.69 | 37.52 | 57.41 | 32.84 | 66.96 | 101.45 | 114.79 |
| [6a858326d](https://github.com/AFK-surf/monoid/commit/6a858326db60ceaf47eb88dbf8d466269833081a) feat(shell): Wave 11-0 TLS ops, race connector, tc | 2.62 | 3.54 | 14.67 | 37.5 | 57.34 | 32.79 | 66.79 | 101.24 | 130.39 |
| [ad825d2bf](https://github.com/AFK-surf/monoid/commit/ad825d2bf60979322febda5c9fa8e3c3b33c9fde) perf(station): keep Readers.retireMismatchedIdle s | 2.62 | 3.54 | 14.67 | 37.5 | 57.34 | 32.79 | 66.79 | 101.24 | 130.39 |
| [a57f36eaf](https://github.com/AFK-surf/monoid/commit/a57f36eaf9f847437906a062ddc3816ed9f27503) fix(station): clear queued pending messages when s | 2.62 | 3.54 | 14.67 | 37.5 | 57.34 | 32.79 | 66.79 | 101.24 | 130.39 |
| [e9a5b9ffd](https://github.com/AFK-surf/monoid/commit/e9a5b9ffd41ea1022d5b418bbff481f3af9bd76b) fix(core): refresh transcripts edited while a chat | 2.62 | 3.54 | 14.67 | 37.5 | 57.34 | 32.79 | 66.79 | 101.24 | 130.39 |
| [d86a03c45](https://github.com/AFK-surf/monoid/commit/d86a03c452e0a7b99ccae9cc49169287b08d2949) feat(mbui): slide menu confirmations inline and ke | 2.62 | 3.54 | 14.65 | 37.47 | 57.24 | 32.79 | 66.79 | 101.24 | 120.23 |
| [9af2ea648](https://github.com/AFK-surf/monoid/commit/9af2ea648a346d7d5b3b4d6d7adc37e862f03c67) fix(station): cover every shared clone and gc.auto | 2.62 | 3.54 | 14.65 | 37.47 | 57.24 | 32.79 | 66.79 | 101.24 | 120.23 |
| [a3ee70d28](https://github.com/AFK-surf/monoid/commit/a3ee70d284d95d6e735a18f823da4c0727a88ce9) fix(station): cancel CommaSurface.ask timeout time | 2.62 | 3.54 | 14.65 | 37.47 | 57.24 | 32.79 | 66.79 | 101.24 | 120.23 |
| [94b4edb34](https://github.com/AFK-surf/monoid/commit/94b4edb34facbd730d75fe2544b39d44207af9d0) station: keep failed Feishu messages in the reconn | 2.62 | 3.54 | 14.65 | 37.46 | 57.23 | 32.79 | 66.77 | 101.27 | 131.05 |
| [b361c3fa4](https://github.com/AFK-surf/monoid/commit/b361c3fa47a916633e9a6bcd9fcddaff09f2abfe) station: preserve dangling links already in the tr | 2.62 | 3.54 | 14.65 | 37.46 | 57.23 | 32.79 | 66.77 | 101.27 | 131.05 |
| [fee10277e](https://github.com/AFK-surf/monoid/commit/fee10277e9b088e70d65f6c7dfa95f060f9b6481) fix(mbui): open Mermaid charts when the picture is | 2.62 | 3.54 | 14.65 | 37.46 | 57.23 | 32.79 | 66.77 | 101.27 | 131.05 |
| [69d71266c](https://github.com/AFK-surf/monoid/commit/69d71266c7bffde6e33c16ad9ec41aedc605affd) fix(station): retry the frozen station's vault bac | 2.62 | 3.54 | 14.65 | 37.46 | 57.23 | 32.79 | 66.77 | 101.27 | 131.05 |
| [5f2521d73](https://github.com/AFK-surf/monoid/commit/5f2521d734de8807c83a6dfb9fff44884244a7e1) fix(ui,mbui): let tables reach the pane's edge bef | 2.62 | 3.54 | 14.65 | 37.46 | 57.23 | 32.79 | 66.77 | 101.27 | 131.05 |
| [edf80a0ce](https://github.com/AFK-surf/monoid/commit/edf80a0ce52f13a73be2a3e784de46ea575b263a) cloud: route configured aliases on self-hosted ori | 2.62 | 3.54 | 14.65 | 37.46 | 57.23 | 32.78 | 66.76 | 101.14 | 125.68 |
| [e9c4fae44](https://github.com/AFK-surf/monoid/commit/e9c4fae440089ce98ae4252d2694741dff992b4b) fix(ci): add conditional wait-shell pre-waiter in  | 2.62 | 3.54 | 14.65 | 37.46 | 57.23 | 32.78 | 66.76 | 101.14 | 125.68 |
| [8becf487a](https://github.com/AFK-surf/monoid/commit/8becf487a0d190689a210bd887a13a2507ce88d0) fix(mbui): unify drive error and retry UI across f | 2.62 | 3.54 | 14.65 | 37.46 | 57.23 | 32.78 | 66.76 | 101.14 | 125.68 |
| [a6e33e168](https://github.com/AFK-surf/monoid/commit/a6e33e16857b8237ea486d49b211bb33cc036168) feat(ui): read CSS Color 4 oklab() and oklch() in  | 2.62 | 3.54 | 14.64 | 37.45 | 57.19 | 32.78 | 66.76 | 101.14 | 120.89 |
| [276814db2](https://github.com/AFK-surf/monoid/commit/276814db2cd81bfdc2d14adc1aa475a285ef4d06) fix(station): retry failed cross-station Comma syn | 2.62 | 3.53 | 14.63 | 37.45 | 57.19 | 32.77 | 66.74 | 101.29 | 124.02 |
| [96a918d63](https://github.com/AFK-surf/monoid/commit/96a918d63268acdf6d222cff469c65c1f884c033) fix(ci): gate pion-station* build jobs on fast uni | 2.62 | 3.53 | 14.63 | 37.45 | 57.19 | 32.77 | 66.74 | 101.29 | 124.02 |
| [189cc0860](https://github.com/AFK-surf/monoid/commit/189cc086039fcf3c7b395dee0f5358bab1a13b3d) fix(ui): account for light glass opacity in adapti | 2.62 | 3.53 | 14.63 | 37.45 | 57.19 | 32.77 | 66.74 | 101.29 | 124.02 |
| [ccbd9dfd5](https://github.com/AFK-surf/monoid/commit/ccbd9dfd59030d6c6f42100182b9246617c76846) fix(ci): split build-linux-reader in pion-station. | 2.62 | 3.53 | 14.64 | 37.45 | 57.19 | 32.77 | 66.74 | 101.25 | 128.45 |
| [9c1d89546](https://github.com/AFK-surf/monoid/commit/9c1d895464bb375b91fa7954d98bbd5fa2fa8d1e) fix(ui): reduced motion ends motions at once inste | 2.62 | 3.53 | 14.64 | 37.45 | 57.19 | 32.77 | 66.74 | 101.25 | 128.45 |
| [d2b910707](https://github.com/AFK-surf/monoid/commit/d2b910707799594705a36db27b6b489de450f097) feat(projects): redesign filter/group panel, curta | 2.62 | 3.53 | 14.64 | 37.45 | 57.19 | 32.77 | 66.74 | 101.25 | 128.45 |
| [45590fca5](https://github.com/AFK-surf/monoid/commit/45590fca5c796ffd7a6854e1260b5a863b1a23bf) fix(ci): fast-path pion-station native waits and p | 2.61 | 3.52 | 14.59 | 37.4 | 56.99 | 32.73 | 66.59 | 101.91 | 122.11 |
| [e34bbe043](https://github.com/AFK-surf/monoid/commit/e34bbe043159cf4af25185bed10dc76526c3c1bf) feat(ui,mbui): replace the glass frost slider with | 2.61 | 3.52 | 14.59 | 37.4 | 56.99 | 32.72 | 66.56 | 101.21 | 122.33 |
| [e1b0ab7ba](https://github.com/AFK-surf/monoid/commit/e1b0ab7ba493ef8709e9eaa968959cc68e645212) fix(i18n): the catalog says the settings words the | 2.61 | 3.52 | 14.58 | 37.4 | 56.99 | 32.72 | 66.56 | 101.21 | 88.08 |
| [8386ac591](https://github.com/AFK-surf/monoid/commit/8386ac59156a2412f3d12774d18ead3bb0fdd99e) perf(core-ts,station): trace leaf prepare stages a | 2.6 | 3.52 | 14.56 | 37.39 | 56.93 | 32.72 | 66.56 | 101.21 | 125.13 |
| [670c0b9f4](https://github.com/AFK-surf/monoid/commit/670c0b9f4670c66ab116813d612d181b152fae84) fix(ci): add native Cargo cache warmer and fast-pa | 2.6 | 3.52 | 14.56 | 37.38 | 56.93 | 32.71 | 66.56 | 101.21 | 125.13 |
| [117c8eadf](https://github.com/AFK-surf/monoid/commit/117c8eadf37263bcb77f5dd7bcbd26b77954d218) feat(ui): unified geometry curtain motion and filt | 2.6 | 3.52 | 14.56 | 37.38 | 56.93 | 32.71 | 66.56 | 101.21 | 125.13 |
| [9d24cac8f](https://github.com/AFK-surf/monoid/commit/9d24cac8f775e4a9fd880a4d2662f40be23f3ddf) fix(station): sync Helper folder grants across res | 2.6 | 3.52 | 14.56 | 37.38 | 56.93 | 32.71 | 66.56 | 101.21 | 125.13 |
| [09aa2b9d5](https://github.com/AFK-surf/monoid/commit/09aa2b9d5e43c47f12944316c4983bae30bda051) feat(station): uninstall a runtime from a station' | 2.6 | 3.52 | 14.56 | 37.38 | 56.93 | 32.71 | 66.56 | 101.21 | 125.13 |
| [a31bb3abf](https://github.com/AFK-surf/monoid/commit/a31bb3abffed6934548a995a7fa6d416479d1ea4) fix(ci): split mesh/shell-station in natives-build | 2.6 | 3.52 | 14.56 | 37.37 | 56.91 | 32.7 | 66.49 | 101.04 | 127.38 |
| [05fa9593e](https://github.com/AFK-surf/monoid/commit/05fa9593e35a7f683e6b697005ff9218379eb5d4) fix(ui): compact desktop selection bar to 30pt and | 2.6 | 3.52 | 14.56 | 37.37 | 56.91 | 32.7 | 66.49 | 101.04 | 127.38 |
| [05375acb0](https://github.com/AFK-surf/monoid/commit/05375acb03249cb8382a85621092229115e9dc13) perf(ui): cache iOS nav bar work and offload Apple | 2.6 | 3.52 | 14.56 | 37.37 | 56.91 | 32.64 | 66.38 | 101.01 | 127.38 |
| [f5bbb1cbf](https://github.com/AFK-surf/monoid/commit/f5bbb1cbf3a631e065cc3351ce0e0e4b6e0117d3) fix(station): read Antigravity quota through its C | 2.6 | 3.52 | 14.56 | 37.37 | 56.91 | 32.64 | 66.38 | 101.01 | 127.38 |
| [d1ae551bf](https://github.com/AFK-surf/monoid/commit/d1ae551bf9b3ab6856ec3dd5e447070aeb16ab62) fix(vault): clear pending requests on archive and  | 2.6 | 3.52 | 14.56 | 37.37 | 56.91 | 32.64 | 66.38 | 101.01 | 127.38 |
| [b69602eb8](https://github.com/AFK-surf/monoid/commit/b69602eb8f5ca6d948645eb0ccc661304326164a) fix(ui): fade every scroll box's cut ends and let  | 2.6 | 3.52 | 14.56 | 37.37 | 56.91 | 32.64 | 66.38 | 101.01 | 126.83 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [1804448f4](https://github.com/AFK-surf/monoid/commit/1804448f4ffb8b13674d01502c64cde76ef7e908) docs(releases): 0.1.11553 stable notes (#8888) | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.49 |
| [354decda1](https://github.com/AFK-surf/monoid/commit/354decda1ca733035a69dc6a0b364bffc2547f43) perf(ui,web): stop calling gl.invalidateFramebuffe | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.26 |
| [e256e703c](https://github.com/AFK-surf/monoid/commit/e256e703c4bd409cdc85efe4196f089383505a8d) test(station): follow the current mesh port during | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.75 |
| [c7da62951](https://github.com/AFK-surf/monoid/commit/c7da629516b59b6a2ca85a1c1fa45c58f9885cbf) fix(mesh): stop noq-udp recv_single busy-loop afte | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.79 |
| [6a858326d](https://github.com/AFK-surf/monoid/commit/6a858326db60ceaf47eb88dbf8d466269833081a) feat(shell): Wave 11-0 TLS ops, race connector, tc | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.67 |
| [ad825d2bf](https://github.com/AFK-surf/monoid/commit/ad825d2bf60979322febda5c9fa8e3c3b33c9fde) perf(station): keep Readers.retireMismatchedIdle s | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.54 |
| [a57f36eaf](https://github.com/AFK-surf/monoid/commit/a57f36eaf9f847437906a062ddc3816ed9f27503) fix(station): clear queued pending messages when s | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.56 |
| [e9a5b9ffd](https://github.com/AFK-surf/monoid/commit/e9a5b9ffd41ea1022d5b418bbff481f3af9bd76b) fix(core): refresh transcripts edited while a chat | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.98 |
| [d86a03c45](https://github.com/AFK-surf/monoid/commit/d86a03c452e0a7b99ccae9cc49169287b08d2949) feat(mbui): slide menu confirmations inline and ke | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.57 |
| [9af2ea648](https://github.com/AFK-surf/monoid/commit/9af2ea648a346d7d5b3b4d6d7adc37e862f03c67) fix(station): cover every shared clone and gc.auto | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.69 |
| [a3ee70d28](https://github.com/AFK-surf/monoid/commit/a3ee70d284d95d6e735a18f823da4c0727a88ce9) fix(station): cancel CommaSurface.ask timeout time | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.72 |
| [94b4edb34](https://github.com/AFK-surf/monoid/commit/94b4edb34facbd730d75fe2544b39d44207af9d0) station: keep failed Feishu messages in the reconn | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.53 |
| [b361c3fa4](https://github.com/AFK-surf/monoid/commit/b361c3fa47a916633e9a6bcd9fcddaff09f2abfe) station: preserve dangling links already in the tr | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.54 |
| [fee10277e](https://github.com/AFK-surf/monoid/commit/fee10277e9b088e70d65f6c7dfa95f060f9b6481) fix(mbui): open Mermaid charts when the picture is | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.54 |
| [69d71266c](https://github.com/AFK-surf/monoid/commit/69d71266c7bffde6e33c16ad9ec41aedc605affd) fix(station): retry the frozen station's vault bac | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.43 |
| [5f2521d73](https://github.com/AFK-surf/monoid/commit/5f2521d734de8807c83a6dfb9fff44884244a7e1) fix(ui,mbui): let tables reach the pane's edge bef | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.33 |
| [edf80a0ce](https://github.com/AFK-surf/monoid/commit/edf80a0ce52f13a73be2a3e784de46ea575b263a) cloud: route configured aliases on self-hosted ori | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.62 |
| [e9c4fae44](https://github.com/AFK-surf/monoid/commit/e9c4fae440089ce98ae4252d2694741dff992b4b) fix(ci): add conditional wait-shell pre-waiter in  | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 58.41 |
| [8becf487a](https://github.com/AFK-surf/monoid/commit/8becf487a0d190689a210bd887a13a2507ce88d0) fix(mbui): unify drive error and retry UI across f | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.61 |
| [a6e33e168](https://github.com/AFK-surf/monoid/commit/a6e33e16857b8237ea486d49b211bb33cc036168) feat(ui): read CSS Color 4 oklab() and oklch() in  | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.74 |
| [276814db2](https://github.com/AFK-surf/monoid/commit/276814db2cd81bfdc2d14adc1aa475a285ef4d06) fix(station): retry failed cross-station Comma syn | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.87 |
| [96a918d63](https://github.com/AFK-surf/monoid/commit/96a918d63268acdf6d222cff469c65c1f884c033) fix(ci): gate pion-station* build jobs on fast uni | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.51 |
| [189cc0860](https://github.com/AFK-surf/monoid/commit/189cc086039fcf3c7b395dee0f5358bab1a13b3d) fix(ui): account for light glass opacity in adapti | 0.57 | 0.75 | 2.92 | 3.98 | 7.3 | 2.17 | 6.14 | 57.51 |
| [ccbd9dfd5](https://github.com/AFK-surf/monoid/commit/ccbd9dfd59030d6c6f42100182b9246617c76846) fix(ci): split build-linux-reader in pion-station. | 0.57 | 0.75 | 2.92 | 3.97 | 7.3 | 2.17 | 6.14 | 57.74 |
| [9c1d89546](https://github.com/AFK-surf/monoid/commit/9c1d895464bb375b91fa7954d98bbd5fa2fa8d1e) fix(ui): reduced motion ends motions at once inste | 0.57 | 0.75 | 2.92 | 3.97 | 7.3 | 2.17 | 6.14 | 57.69 |
| [d2b910707](https://github.com/AFK-surf/monoid/commit/d2b910707799594705a36db27b6b489de450f097) feat(projects): redesign filter/group panel, curta | 0.57 | 0.75 | 2.92 | 3.97 | 7.3 | 2.17 | 6.14 | 57.77 |
| [45590fca5](https://github.com/AFK-surf/monoid/commit/45590fca5c796ffd7a6854e1260b5a863b1a23bf) fix(ci): fast-path pion-station native waits and p | 0.57 | 0.75 | 2.92 | 3.97 | 7.3 | 2.17 | 6.14 | 57.98 |
| [e34bbe043](https://github.com/AFK-surf/monoid/commit/e34bbe043159cf4af25185bed10dc76526c3c1bf) feat(ui,mbui): replace the glass frost slider with | 0.57 | 0.75 | 2.92 | 3.97 | 7.3 | 2.17 | 6.14 | 57.62 |
| [e1b0ab7ba](https://github.com/AFK-surf/monoid/commit/e1b0ab7ba493ef8709e9eaa968959cc68e645212) fix(i18n): the catalog says the settings words the | 0.57 | 0.75 | 2.91 | 3.97 | 7.3 | 2.17 | 6.14 | 57.33 |
| [8386ac591](https://github.com/AFK-surf/monoid/commit/8386ac59156a2412f3d12774d18ead3bb0fdd99e) perf(core-ts,station): trace leaf prepare stages a | 0.57 | 0.74 | 2.89 | 3.95 | 7.24 | 2.15 | 6.09 | 57.69 |
| [670c0b9f4](https://github.com/AFK-surf/monoid/commit/670c0b9f4670c66ab116813d612d181b152fae84) fix(ci): add native Cargo cache warmer and fast-pa | 0.57 | 0.75 | 2.91 | 3.97 | 7.3 | 2.17 | 6.14 | 57.69 |
| [117c8eadf](https://github.com/AFK-surf/monoid/commit/117c8eadf37263bcb77f5dd7bcbd26b77954d218) feat(ui): unified geometry curtain motion and filt | 0.57 | 0.75 | 2.91 | 3.97 | 7.3 | 2.17 | 6.14 | 57.43 |
| [9d24cac8f](https://github.com/AFK-surf/monoid/commit/9d24cac8f775e4a9fd880a4d2662f40be23f3ddf) fix(station): sync Helper folder grants across res | 0.57 | 0.74 | 2.89 | 3.95 | 7.24 | 2.15 | 6.09 | 57.41 |
| [09aa2b9d5](https://github.com/AFK-surf/monoid/commit/09aa2b9d5e43c47f12944316c4983bae30bda051) feat(station): uninstall a runtime from a station' | 0.57 | 0.74 | 2.89 | 3.95 | 7.24 | 2.15 | 6.09 | 57.51 |
| [a31bb3abf](https://github.com/AFK-surf/monoid/commit/a31bb3abffed6934548a995a7fa6d416479d1ea4) fix(ci): split mesh/shell-station in natives-build | 0.57 | 0.74 | 2.89 | 3.95 | 7.24 | 2.15 | 6.09 | 57.66 |
| [05fa9593e](https://github.com/AFK-surf/monoid/commit/05fa9593e35a7f683e6b697005ff9218379eb5d4) fix(ui): compact desktop selection bar to 30pt and | 0.57 | 0.74 | 2.89 | 3.95 | 7.23 | 2.15 | 6.06 | 57.77 |
| [05375acb0](https://github.com/AFK-surf/monoid/commit/05375acb03249cb8382a85621092229115e9dc13) perf(ui): cache iOS nav bar work and offload Apple | 0.57 | 0.74 | 2.89 | 3.95 | 7.23 | 2.15 | 6.06 | 57.54 |
| [f5bbb1cbf](https://github.com/AFK-surf/monoid/commit/f5bbb1cbf3a631e065cc3351ce0e0e4b6e0117d3) fix(station): read Antigravity quota through its C | 0.57 | 0.74 | 2.89 | 3.95 | 7.23 | 2.15 | 6.06 | 57.36 |
| [d1ae551bf](https://github.com/AFK-surf/monoid/commit/d1ae551bf9b3ab6856ec3dd5e447070aeb16ab62) fix(vault): clear pending requests on archive and  | 0.57 | 0.74 | 2.89 | 3.95 | 7.23 | 2.15 | 6.06 | 57.77 |
| [b69602eb8](https://github.com/AFK-surf/monoid/commit/b69602eb8f5ca6d948645eb0ccc661304326164a) fix(ui): fade every scroll box's cut ends and let  | 0.57 | 0.74 | 2.89 | 3.95 | 7.23 | 2.15 | 6.06 | 57.43 |
