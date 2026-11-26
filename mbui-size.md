# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [6d2dde849](https://github.com/AFK-surf/monoid/commit/6d2dde849a64e852ad97a3a8a9402628715f0b59) fix(station): remove runner json sentinel last and | 2.64 | 3.57 | 14.77 | 37.73 | 57.6 | 33.04 | 67.49 | 101.65 | 129.36 |
| [ff922a134](https://github.com/AFK-surf/monoid/commit/ff922a134ea9482152559b010335530ccf90eda1) test(ui): synchronize WARP with a D3D11 event quer | 2.64 | 3.57 | 14.77 | 37.73 | 57.6 | 33.04 | 67.49 | 101.65 | 125.33 |
| [f59c98985](https://github.com/AFK-surf/monoid/commit/f59c98985161e7ddfcf6f14da6017cbde219415e) refactor(core,mbui): unify 125-topic policy table  | 2.64 | 3.57 | 14.77 | 37.73 | 57.6 | 33.04 | 67.49 | 101.65 | 125.33 |
| [c76f57771](https://github.com/AFK-surf/monoid/commit/c76f5777167157b08f93aae71073e90428e54cd4) feat(shell): add image.thumb operation for station | 2.64 | 3.57 | 14.77 | 37.73 | 57.6 | 33.04 | 67.49 | 101.65 | 125.33 |
| [2f6b1a23f](https://github.com/AFK-surf/monoid/commit/2f6b1a23f329cb2f2a8cbfcdb402a9a15f6fa3ba) feat(pion-station): add station_sessions orchestra | 2.64 | 3.57 | 14.77 | 37.74 | 57.6 | 33.04 | 67.49 | 101.57 | 122.94 |
| [a2b167ca1](https://github.com/AFK-surf/monoid/commit/a2b167ca11cb804f0887aac92e6caa9cdea8151f) feat(station-pion): add station_replica package (W | 2.64 | 3.57 | 14.77 | 37.74 | 57.6 | 33.04 | 67.49 | 101.57 | 122.94 |
| [bbce87b40](https://github.com/AFK-surf/monoid/commit/bbce87b407f8cdc72bc816148b1dc869ca60d63a) fix(ui): keep the segmented thumb within its end o | 2.64 | 3.57 | 14.77 | 37.74 | 57.6 | 33.04 | 67.49 | 101.57 | 122.94 |
| [82cb679dd](https://github.com/AFK-surf/monoid/commit/82cb679dd2480388799d77bb6a071b9c7129978c) feat(pion): add native station_cli package for all | 2.64 | 3.57 | 14.77 | 37.74 | 57.6 | 33.04 | 67.49 | 101.4 | 132.81 |
| [dd013ddef](https://github.com/AFK-surf/monoid/commit/dd013ddef0cc30e406c4aae4d5ef57651b136c43) feat(station-main): add station_tools MCP server,  | 2.64 | 3.57 | 14.77 | 37.74 | 57.6 | 33.04 | 67.49 | 101.75 | 113.44 |
| [9a704269f](https://github.com/AFK-surf/monoid/commit/9a704269f6b73ca3760d751aa7e7b2583e17575a) feat(station-main): add station_hooks_tui package  | 2.64 | 3.57 | 14.77 | 37.74 | 57.6 | 33.04 | 67.49 | 101.75 | 113.44 |
| [7f34800d8](https://github.com/AFK-surf/monoid/commit/7f34800d8f77bbec297192588ca9c16105be43ae) feat(ui,mbui): unify all switches to liquid glass  | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.76 | 125.17 |
| [9d95440e1](https://github.com/AFK-surf/monoid/commit/9d95440e142fed381c38041c9ad0772c894721a2) feat(station-main): add pure Pion station_rig doma | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.76 | 125.17 |
| [126000642](https://github.com/AFK-surf/monoid/commit/126000642071195ca01cc911b221cfdb80bdd9da) fix(station,core): move uploads across disks and s | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.76 | 125.17 |
| [cdb475fd0](https://github.com/AFK-surf/monoid/commit/cdb475fd079438c71e216af948cafe3b6cdcb739) test(station): fix three assumptions in the macOS  | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.76 | 125.17 |
| [093dfc1e8](https://github.com/AFK-surf/monoid/commit/093dfc1e857bc1356a33a0fc0ed2531e693e9c37) feat(ui,app,core): overhaul liquid glass motion fo | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.76 | 125.17 |
| [537157a1e](https://github.com/AFK-surf/monoid/commit/537157a1ebf9f01912ae75640c9fb21eb66e2bd5) perf(station): crop a Mac video frame when the enc | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.76 | 125.17 |
| [b806cdd29](https://github.com/AFK-surf/monoid/commit/b806cdd29944a7531d8da121289e9d56951bd341) perf(mbui): zero-reflow Large/Medium pane fold tra | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.76 | 125.17 |
| [7b1f1df26](https://github.com/AFK-surf/monoid/commit/7b1f1df26d54f54dae65985e90b26c7db4db8161) fix(mesh): bump noq-proto so a discarded path 0 no | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.76 | 125.17 |
| [74a1001ae](https://github.com/AFK-surf/monoid/commit/74a1001ae641a7ab0327a6036a98d4985682c062) feat(pion): add pure-Pion station_store SQLite cor | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.52 | 122.87 |
| [e9b87edea](https://github.com/AFK-surf/monoid/commit/e9b87edea90d6fe7d7e389ed8e10d476633b4b14) feat(pion): add station_ops core ops, platform hel | 2.63 | 3.55 | 14.69 | 37.66 | 57.41 | 32.99 | 67.34 | 101.52 | 122.87 |
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

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [6d2dde849](https://github.com/AFK-surf/monoid/commit/6d2dde849a64e852ad97a3a8a9402628715f0b59) fix(station): remove runner json sentinel last and | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.74 |
| [ff922a134](https://github.com/AFK-surf/monoid/commit/ff922a134ea9482152559b010335530ccf90eda1) test(ui): synchronize WARP with a D3D11 event quer | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.64 |
| [f59c98985](https://github.com/AFK-surf/monoid/commit/f59c98985161e7ddfcf6f14da6017cbde219415e) refactor(core,mbui): unify 125-topic policy table  | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.66 |
| [c76f57771](https://github.com/AFK-surf/monoid/commit/c76f5777167157b08f93aae71073e90428e54cd4) feat(shell): add image.thumb operation for station | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.57 |
| [2f6b1a23f](https://github.com/AFK-surf/monoid/commit/2f6b1a23f329cb2f2a8cbfcdb402a9a15f6fa3ba) feat(pion-station): add station_sessions orchestra | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.64 |
| [a2b167ca1](https://github.com/AFK-surf/monoid/commit/a2b167ca11cb804f0887aac92e6caa9cdea8151f) feat(station-pion): add station_replica package (W | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.54 |
| [bbce87b40](https://github.com/AFK-surf/monoid/commit/bbce87b407f8cdc72bc816148b1dc869ca60d63a) fix(ui): keep the segmented thumb within its end o | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.49 |
| [82cb679dd](https://github.com/AFK-surf/monoid/commit/82cb679dd2480388799d77bb6a071b9c7129978c) feat(pion): add native station_cli package for all | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.41 |
| [dd013ddef](https://github.com/AFK-surf/monoid/commit/dd013ddef0cc30e406c4aae4d5ef57651b136c43) feat(station-main): add station_tools MCP server,  | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.71 |
| [9a704269f](https://github.com/AFK-surf/monoid/commit/9a704269f6b73ca3760d751aa7e7b2583e17575a) feat(station-main): add station_hooks_tui package  | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.33 |
| [7f34800d8](https://github.com/AFK-surf/monoid/commit/7f34800d8f77bbec297192588ca9c16105be43ae) feat(ui,mbui): unify all switches to liquid glass  | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.66 |
| [9d95440e1](https://github.com/AFK-surf/monoid/commit/9d95440e142fed381c38041c9ad0772c894721a2) feat(station-main): add pure Pion station_rig doma | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.72 |
| [126000642](https://github.com/AFK-surf/monoid/commit/126000642071195ca01cc911b221cfdb80bdd9da) fix(station,core): move uploads across disks and s | 0.58 | 0.76 | 2.97 | 4.02 | 7.4 | 2.2 | 6.23 | 57.44 |
| [cdb475fd0](https://github.com/AFK-surf/monoid/commit/cdb475fd079438c71e216af948cafe3b6cdcb739) test(station): fix three assumptions in the macOS  | 0.58 | 0.75 | 2.92 | 3.99 | 7.32 | 2.18 | 6.16 | 57.66 |
| [093dfc1e8](https://github.com/AFK-surf/monoid/commit/093dfc1e857bc1356a33a0fc0ed2531e693e9c37) feat(ui,app,core): overhaul liquid glass motion fo | 0.58 | 0.75 | 2.92 | 3.99 | 7.32 | 2.18 | 6.16 | 57.57 |
| [537157a1e](https://github.com/AFK-surf/monoid/commit/537157a1ebf9f01912ae75640c9fb21eb66e2bd5) perf(station): crop a Mac video frame when the enc | 0.58 | 0.75 | 2.92 | 3.99 | 7.32 | 2.18 | 6.16 | 57.69 |
| [b806cdd29](https://github.com/AFK-surf/monoid/commit/b806cdd29944a7531d8da121289e9d56951bd341) perf(mbui): zero-reflow Large/Medium pane fold tra | 0.58 | 0.75 | 2.92 | 3.99 | 7.32 | 2.18 | 6.16 | 57.56 |
| [7b1f1df26](https://github.com/AFK-surf/monoid/commit/7b1f1df26d54f54dae65985e90b26c7db4db8161) fix(mesh): bump noq-proto so a discarded path 0 no | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.66 |
| [74a1001ae](https://github.com/AFK-surf/monoid/commit/74a1001ae641a7ab0327a6036a98d4985682c062) feat(pion): add pure-Pion station_store SQLite cor | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.75 |
| [e9b87edea](https://github.com/AFK-surf/monoid/commit/e9b87edea90d6fe7d7e389ed8e10d476633b4b14) feat(pion): add station_ops core ops, platform hel | 0.57 | 0.75 | 2.92 | 3.98 | 7.31 | 2.17 | 6.16 | 57.59 |
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
