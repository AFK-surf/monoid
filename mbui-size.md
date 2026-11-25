# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [224d3f7a0](https://github.com/AFK-surf/monoid/commit/224d3f7a0df6dfa1c3b0f175962148b19b9e4443) fix(ci): publish main's Mac natives to the native  | 2.56 | 3.46 | 14.29 | 36.9 | 55.82 | 32.24 | 65.18 | 101.21 | 130.49 |
| [fdc6ccbb1](https://github.com/AFK-surf/monoid/commit/fdc6ccbb10984b875d6b04264ed5e770fe11c947) perf(ci): rebalance station test slices by CI runn | 2.55 | 3.45 | 14.24 | 36.87 | 55.72 | 32.18 | 65.05 | 100.7 | 122.76 |
| [17f337ddd](https://github.com/AFK-surf/monoid/commit/17f337ddd8e9f8e0fd0c0e3e25003c5815ce0d86) perf(mbui): copy-on-write apply_delta, single-pass | 2.55 | 3.45 | 14.24 | 36.87 | 55.72 | 32.18 | 65.05 | 100.7 | 122.76 |
| [17dd44eeb](https://github.com/AFK-surf/monoid/commit/17dd44eeb65296de5e4416de6458c4e83209bbdc) feat(ui): add Settings MCP tab to manage station M | 2.55 | 3.45 | 14.24 | 36.87 | 55.72 | 32.18 | 65.05 | 100.7 | 122.76 |
| [e722bb594](https://github.com/AFK-surf/monoid/commit/e722bb594602ee611772cb8e17251e370c982fbe) ci(linux): move Linux jobs to GitHub-hosted runner | 2.55 | 3.45 | 14.24 | 36.87 | 55.72 | 32.18 | 65.05 | 100.7 | 122.76 |
| [8d840de46](https://github.com/AFK-surf/monoid/commit/8d840de468396987e2e02aea3d0d4fa4a0f936f2) fix(ci): stop mbui-size idle from tainting mbui-re | 2.55 | 3.45 | 14.24 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [8d58b9cf0](https://github.com/AFK-surf/monoid/commit/8d58b9cf0cbd962677a8014460e8ddd1ae5db54d) feat(pion/station): port sessions_agents 1:1 to pu | 2.55 | 3.45 | 14.24 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [c5cac1fad](https://github.com/AFK-surf/monoid/commit/c5cac1fadb4ad6dc29ef0bf05852b4ad615feba7) fix(cloud): price models by the names their makers | 2.55 | 3.45 | 14.24 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [28f30876c](https://github.com/AFK-surf/monoid/commit/28f30876c6468ff0116f9e0ba46e70a817e07c08) fix(station): size the remote mirror budget by the | 2.55 | 3.45 | 14.24 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [1af7a260e](https://github.com/AFK-surf/monoid/commit/1af7a260e1e81fe59b5d4a49ff3809fcd3594d6b) fix(station): clear stale done login job on cancel | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [349bfc261](https://github.com/AFK-surf/monoid/commit/349bfc26181b0a0352576c81b8d3ae11c5653caa) fix(ci): hand stable monoid Android through compan | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [4ae5e6995](https://github.com/AFK-surf/monoid/commit/4ae5e699587c2008dec7ea2d17c2d52aca6d5fec) fix(ci): recognize git fetch RPC transport failure | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [436044f40](https://github.com/AFK-surf/monoid/commit/436044f4002efe8787fdf72f2b3734abdbdaf07f) feat(station): manage third-party MCP servers in s | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [9fb941213](https://github.com/AFK-surf/monoid/commit/9fb94121389408c2413c934767841767cb4d1c2e) fix(ci): split stable Mac signing and notarization | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [271a0f350](https://github.com/AFK-surf/monoid/commit/271a0f3506fa7b4e8cff18f0e6299a9e964abd41) feat(ui,mbui): unify Liquid Glass v9 overlays & sc | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [184906dae](https://github.com/AFK-surf/monoid/commit/184906dae0dd6431cd03f9f581f71855d89b1004) perf(pion-station): land P0/P1 hot-path optimizati | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [78c0cc1f8](https://github.com/AFK-surf/monoid/commit/78c0cc1f8d13ee72237a8b4954e77902ee4d8eb1) fix(station): declare search directly to agy and n | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [2316b2f67](https://github.com/AFK-surf/monoid/commit/2316b2f6743ae497970c88dc5ea6e9d6119347a3) feat(pion-station): Wave 8 W8-C1 sessions_remote c | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [c47b2cd31](https://github.com/AFK-surf/monoid/commit/c47b2cd314b896ce5b506ac85736bc33576b47ec) revert(core): undo "ask the station links first af | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.7 | 123.19 |
| [1edeb8d91](https://github.com/AFK-surf/monoid/commit/1edeb8d91ba2068cfd57cbd468607d4d931ace2d) feat(pion-station): Wave 8 W8-B sessions_jobs_live | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.75 | 123.19 |
| [be4e447f2](https://github.com/AFK-surf/monoid/commit/be4e447f220b95e3645f28cba2a556d63e958e2b) fix(mbui): viewer controls never fade by themselve | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.75 | 123.19 |
| [797ec5762](https://github.com/AFK-surf/monoid/commit/797ec5762d33ccbb695570770b214a424f613391) feat(pion-station): Wave 8 W8-A port 6 live parser | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.75 | 123.19 |
| [e7a05e132](https://github.com/AFK-surf/monoid/commit/e7a05e1322d6c3a3ae1f8ff7e175823a51708441) fix(core,station): resume image previews and named | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.75 | 123.19 |
| [26a69ad46](https://github.com/AFK-surf/monoid/commit/26a69ad460ebd57a96a62531ace1f87c5ebecfc9) feat(mbui): show each station's state as icons in  | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.75 | 123.19 |
| [4a5c1ad96](https://github.com/AFK-surf/monoid/commit/4a5c1ad9624b189d267abbbcf75f664fab4965da) fix(station): route a thread slack_api posts in th | 2.55 | 3.44 | 14.23 | 36.83 | 55.68 | 32.18 | 65.05 | 100.75 | 123.19 |
| [9df00e044](https://github.com/AFK-surf/monoid/commit/9df00e044b3d24ae9bae30111d9e2093c25630fc) feat(pion-station): Wave 8 W8-E1 sessions_actors c | 2.55 | 3.44 | 14.22 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [43b2f8b59](https://github.com/AFK-surf/monoid/commit/43b2f8b59e87d38b21e1ec729dee6162bcf45a45) fix(ci): reuse pipeline shell-station in pion-stat | 2.55 | 3.44 | 14.22 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [8ead03b5c](https://github.com/AFK-surf/monoid/commit/8ead03b5c8af20335422a36006f9e267e8de7a85) fix(station): do not add backup stand-ins for keep | 2.55 | 3.44 | 14.22 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [368e6e956](https://github.com/AFK-surf/monoid/commit/368e6e9564f3cf43dfd48623662ba5dfd8b67621) fix(ci): bound gh release upload with 90s timeout  | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [83de34c52](https://github.com/AFK-surf/monoid/commit/83de34c526cbe574b9f9a287457a8d588ed5c0aa) fix(ci): skip cached natives and reader-harness in | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [225e4d51a](https://github.com/AFK-surf/monoid/commit/225e4d51add15266b761e500d468ec9b74fa09fe) feat(screen): redo cross-OS remote keyboard and sh | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [c757b11f8](https://github.com/AFK-surf/monoid/commit/c757b11f876dbc22c748fea9fdd559605f3a9a4c) fix(ui): keep dragged thumbs and pictures under th | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [6df8ba486](https://github.com/AFK-surf/monoid/commit/6df8ba4862d216fe89c8eb929ee413c7d6df6e23) fix(mbui): put a station's state dot after its wor | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [b9c8a4280](https://github.com/AFK-surf/monoid/commit/b9c8a42804079619d16d10671845e4ff67eb8d5f) fix(station): let backups give way by the delay th | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [bd99b367c](https://github.com/AFK-surf/monoid/commit/bd99b367c777a9ec85411246d786b09c789baaca) fix(cloud): retry a failed release read once and a | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [5c67aea1c](https://github.com/AFK-surf/monoid/commit/5c67aea1ce6cca79985064a48a603c1e78cb4d14) fix(core): ask the station links first after up to | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [9cafa2118](https://github.com/AFK-surf/monoid/commit/9cafa21182dec33db8873e52342b018f489183b3) fix(mesh,android): enable hot-relay narrowing on n | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [610cee155](https://github.com/AFK-surf/monoid/commit/610cee1555f582e1d16d891ce75b331c78d7a780) fix(ci): allow 60s for active native-handoff GET c | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [c20658d4d](https://github.com/AFK-surf/monoid/commit/c20658d4d60f5f0d26b93b4725be5c945cff29fd) fix(mbui): fly every shared node let go of in one  | 2.54 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 101.12 | 126.18 |
| [7c26d51ae](https://github.com/AFK-surf/monoid/commit/7c26d51ae6493bf54b87c3aff8e37f5f1f3ad581) feat(station): give a Copilot profile its own MCP  | 2.55 | 3.44 | 14.21 | 36.81 | 55.62 | 32.16 | 65.02 | 100.91 | 130.09 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [224d3f7a0](https://github.com/AFK-surf/monoid/commit/224d3f7a0df6dfa1c3b0f175962148b19b9e4443) fix(ci): publish main's Mac natives to the native  | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.9 |
| [fdc6ccbb1](https://github.com/AFK-surf/monoid/commit/fdc6ccbb10984b875d6b04264ed5e770fe11c947) perf(ci): rebalance station test slices by CI runn | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.85 |
| [17f337ddd](https://github.com/AFK-surf/monoid/commit/17f337ddd8e9f8e0fd0c0e3e25003c5815ce0d86) perf(mbui): copy-on-write apply_delta, single-pass | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.72 |
| [17dd44eeb](https://github.com/AFK-surf/monoid/commit/17dd44eeb65296de5e4416de6458c4e83209bbdc) feat(ui): add Settings MCP tab to manage station M | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.66 |
| [e722bb594](https://github.com/AFK-surf/monoid/commit/e722bb594602ee611772cb8e17251e370c982fbe) ci(linux): move Linux jobs to GitHub-hosted runner | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 58.03 |
| [8d840de46](https://github.com/AFK-surf/monoid/commit/8d840de468396987e2e02aea3d0d4fa4a0f936f2) fix(ci): stop mbui-size idle from tainting mbui-re | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.49 |
| [8d58b9cf0](https://github.com/AFK-surf/monoid/commit/8d58b9cf0cbd962677a8014460e8ddd1ae5db54d) feat(pion/station): port sessions_agents 1:1 to pu | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.53 |
| [c5cac1fad](https://github.com/AFK-surf/monoid/commit/c5cac1fadb4ad6dc29ef0bf05852b4ad615feba7) fix(cloud): price models by the names their makers | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.53 |
| [28f30876c](https://github.com/AFK-surf/monoid/commit/28f30876c6468ff0116f9e0ba46e70a817e07c08) fix(station): size the remote mirror budget by the | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 56.94 |
| [1af7a260e](https://github.com/AFK-surf/monoid/commit/1af7a260e1e81fe59b5d4a49ff3809fcd3594d6b) fix(station): clear stale done login job on cancel | 0.56 | 0.74 | 2.87 | 3.91 | 7.16 | 2.13 | 5.98 | 56.94 |
| [349bfc261](https://github.com/AFK-surf/monoid/commit/349bfc26181b0a0352576c81b8d3ae11c5653caa) fix(ci): hand stable monoid Android through compan | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.9 |
| [4ae5e6995](https://github.com/AFK-surf/monoid/commit/4ae5e699587c2008dec7ea2d17c2d52aca6d5fec) fix(ci): recognize git fetch RPC transport failure | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.9 |
| [436044f40](https://github.com/AFK-surf/monoid/commit/436044f4002efe8787fdf72f2b3734abdbdaf07f) feat(station): manage third-party MCP servers in s | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.64 |
| [9fb941213](https://github.com/AFK-surf/monoid/commit/9fb94121389408c2413c934767841767cb4d1c2e) fix(ci): split stable Mac signing and notarization | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.35 |
| [271a0f350](https://github.com/AFK-surf/monoid/commit/271a0f3506fa7b4e8cff18f0e6299a9e964abd41) feat(ui,mbui): unify Liquid Glass v9 overlays & sc | 0.56 | 0.74 | 2.87 | 3.91 | 7.17 | 2.13 | 5.98 | 57.69 |
| [184906dae](https://github.com/AFK-surf/monoid/commit/184906dae0dd6431cd03f9f581f71855d89b1004) perf(pion-station): land P0/P1 hot-path optimizati | 0.56 | 0.74 | 2.87 | 3.91 | 7.16 | 2.13 | 5.98 | 57.28 |
| [78c0cc1f8](https://github.com/AFK-surf/monoid/commit/78c0cc1f8d13ee72237a8b4954e77902ee4d8eb1) fix(station): declare search directly to agy and n | 0.56 | 0.74 | 2.87 | 3.91 | 7.16 | 2.13 | 5.98 | 57.21 |
| [2316b2f67](https://github.com/AFK-surf/monoid/commit/2316b2f6743ae497970c88dc5ea6e9d6119347a3) feat(pion-station): Wave 8 W8-C1 sessions_remote c | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.05 |
| [c47b2cd31](https://github.com/AFK-surf/monoid/commit/c47b2cd314b896ce5b506ac85736bc33576b47ec) revert(core): undo "ask the station links first af | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.16 |
| [1edeb8d91](https://github.com/AFK-surf/monoid/commit/1edeb8d91ba2068cfd57cbd468607d4d931ace2d) feat(pion-station): Wave 8 W8-B sessions_jobs_live | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.18 |
| [be4e447f2](https://github.com/AFK-surf/monoid/commit/be4e447f220b95e3645f28cba2a556d63e958e2b) fix(mbui): viewer controls never fade by themselve | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.36 |
| [797ec5762](https://github.com/AFK-surf/monoid/commit/797ec5762d33ccbb695570770b214a424f613391) feat(pion-station): Wave 8 W8-A port 6 live parser | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.26 |
| [e7a05e132](https://github.com/AFK-surf/monoid/commit/e7a05e1322d6c3a3ae1f8ff7e175823a51708441) fix(core,station): resume image previews and named | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.25 |
| [26a69ad46](https://github.com/AFK-surf/monoid/commit/26a69ad460ebd57a96a62531ace1f87c5ebecfc9) feat(mbui): show each station's state as icons in  | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.41 |
| [4a5c1ad96](https://github.com/AFK-surf/monoid/commit/4a5c1ad9624b189d267abbbcf75f664fab4965da) fix(station): route a thread slack_api posts in th | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.41 |
| [9df00e044](https://github.com/AFK-surf/monoid/commit/9df00e044b3d24ae9bae30111d9e2093c25630fc) feat(pion-station): Wave 8 W8-E1 sessions_actors c | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.46 |
| [43b2f8b59](https://github.com/AFK-surf/monoid/commit/43b2f8b59e87d38b21e1ec729dee6162bcf45a45) fix(ci): reuse pipeline shell-station in pion-stat | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.1 |
| [8ead03b5c](https://github.com/AFK-surf/monoid/commit/8ead03b5c8af20335422a36006f9e267e8de7a85) fix(station): do not add backup stand-ins for keep | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.31 |
| [368e6e956](https://github.com/AFK-surf/monoid/commit/368e6e9564f3cf43dfd48623662ba5dfd8b67621) fix(ci): bound gh release upload with 90s timeout  | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57 |
| [83de34c52](https://github.com/AFK-surf/monoid/commit/83de34c526cbe574b9f9a287457a8d588ed5c0aa) fix(ci): skip cached natives and reader-harness in | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.16 |
| [225e4d51a](https://github.com/AFK-surf/monoid/commit/225e4d51add15266b761e500d468ec9b74fa09fe) feat(screen): redo cross-OS remote keyboard and sh | 0.56 | 0.74 | 2.86 | 3.91 | 7.16 | 2.13 | 5.98 | 57.3 |
| [c757b11f8](https://github.com/AFK-surf/monoid/commit/c757b11f876dbc22c748fea9fdd559605f3a9a4c) fix(ui): keep dragged thumbs and pictures under th | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.31 |
| [6df8ba486](https://github.com/AFK-surf/monoid/commit/6df8ba4862d216fe89c8eb929ee413c7d6df6e23) fix(mbui): put a station's state dot after its wor | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.44 |
| [b9c8a4280](https://github.com/AFK-surf/monoid/commit/b9c8a42804079619d16d10671845e4ff67eb8d5f) fix(station): let backups give way by the delay th | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.51 |
| [bd99b367c](https://github.com/AFK-surf/monoid/commit/bd99b367c777a9ec85411246d786b09c789baaca) fix(cloud): retry a failed release read once and a | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57 |
| [5c67aea1c](https://github.com/AFK-surf/monoid/commit/5c67aea1ce6cca79985064a48a603c1e78cb4d14) fix(core): ask the station links first after up to | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.2 |
| [9cafa2118](https://github.com/AFK-surf/monoid/commit/9cafa21182dec33db8873e52342b018f489183b3) fix(mesh,android): enable hot-relay narrowing on n | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.2 |
| [610cee155](https://github.com/AFK-surf/monoid/commit/610cee1555f582e1d16d891ce75b331c78d7a780) fix(ci): allow 60s for active native-handoff GET c | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.46 |
| [c20658d4d](https://github.com/AFK-surf/monoid/commit/c20658d4d60f5f0d26b93b4725be5c945cff29fd) fix(mbui): fly every shared node let go of in one  | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.13 |
| [7c26d51ae](https://github.com/AFK-surf/monoid/commit/7c26d51ae6493bf54b87c3aff8e37f5f1f3ad581) feat(station): give a Copilot profile its own MCP  | 0.56 | 0.74 | 2.86 | 3.91 | 7.15 | 2.12 | 5.98 | 57.28 |
