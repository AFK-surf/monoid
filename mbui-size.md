# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [0fa688540](https://github.com/AFK-surf/monoid/commit/0fa688540da1a5ede59dc566d8567c2e16d0144d) feat(station): enforce account concurrency caps ac | 2.53 | 3.41 | 14.07 | 36.61 | 55.09 | 31.97 | 64.59 | 101.09 | 126.08 |
| [eebe4c08b](https://github.com/AFK-surf/monoid/commit/eebe4c08bc5c0a056da6cd6a94802c1761353c74) fix(mbui): close the board chat on Esc (#8618) | 2.53 | 3.41 | 14.07 | 36.61 | 55.09 | 31.97 | 64.59 | 101.09 | 126.08 |
| [352566952](https://github.com/AFK-surf/monoid/commit/352566952d0319900c610590a715a0af1e2278bb) fix(app): line up a board draft's panel and put wh | 2.52 | 3.41 | 14.07 | 36.61 | 55.08 | 31.97 | 64.59 | 100.94 | 110.04 |
| [12b53b34c](https://github.com/AFK-surf/monoid/commit/12b53b34c7a21f149097533e38ff8d533efc74f8) feat(pion): implement W7-B readops_chats L1 packag | 2.52 | 3.41 | 14.07 | 36.61 | 55.08 | 31.97 | 64.57 | 100.83 | 125.74 |
| [bf66c2dbb](https://github.com/AFK-surf/monoid/commit/bf66c2dbbc04fa1067f02629b964b5462bb085bc) feat(pion): Wave 7.1 front (--builder forward and  | 2.52 | 3.41 | 14.07 | 36.61 | 55.08 | 31.97 | 64.57 | 100.83 | 125.74 |
| [04f23f8f2](https://github.com/AFK-surf/monoid/commit/04f23f8f28d20778832cc3a30277cd4de3ea7487) perf(ui): keep the macOS menu bar in place and ope | 2.52 | 3.4 | 14.07 | 36.61 | 55.08 | 31.97 | 64.57 | 100.76 | 120.32 |
| [af836a0fc](https://github.com/AFK-surf/monoid/commit/af836a0fcee54d4fa05d9fe02fce27cb9e6b6374) feat(ui): stop Cmd-click quick-pick at commas (#86 | 2.52 | 3.4 | 14.07 | 36.61 | 55.08 | 31.97 | 64.57 | 100.86 | 129.86 |
| [3142ff413](https://github.com/AFK-surf/monoid/commit/3142ff4130b8045ec4942e14d0e2753673a17ce9) feat(pion-station): port W7-C readops_local L1 pac | 2.52 | 3.4 | 14.07 | 36.6 | 55.08 | 31.97 | 64.57 | 101.07 | 124.6 |
| [4add66765](https://github.com/AFK-surf/monoid/commit/4add66765d1d397ba8a187600457f348d1573124) feat(station): add workspace chat project & tag cl | 2.52 | 3.4 | 14.07 | 36.6 | 55.08 | 31.97 | 64.57 | 101.07 | 124.6 |
| [a6e44a136](https://github.com/AFK-surf/monoid/commit/a6e44a136433173fe51df5157718e92ec2489054) fix(app): let a board draft with files move to ano | 2.52 | 3.4 | 14.07 | 36.6 | 55.08 | 31.97 | 64.57 | 100.76 | 126.05 |
| [0fd9c17df](https://github.com/AFK-surf/monoid/commit/0fd9c17df87abfac1853e2557473c03520413733) feat(rules): prove the fork choice of a keeper tha | 2.52 | 3.4 | 14.07 | 36.6 | 55.08 | 31.97 | 64.57 | 101.01 | 116.62 |
| [ca9d66655](https://github.com/AFK-surf/monoid/commit/ca9d66655aa6811022cfd8af83d0ddeb03b23303) fix(signals): preserve PENDING in check_dirty when | 2.52 | 3.4 | 14.07 | 36.6 | 55.08 | 31.97 | 64.57 | 101.01 | 116.62 |
| [bfc382a17](https://github.com/AFK-surf/monoid/commit/bfc382a1792aa28b6e1e224db14c8c3f2f681eaa) fix(mbui): allow reopening a chat sitting under Ne | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 100.7 | 130.21 |
| [a442e5fad](https://github.com/AFK-surf/monoid/commit/a442e5fad2c3f279cac7d0c06ded11cb44aa6c72) feat(pion): Wave 7.0 foundation, readops_core, TS  | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 101.02 | 126.54 |
| [2be102041](https://github.com/AFK-surf/monoid/commit/2be102041ddffe6ebc8a0a4c8504efe9e38fa089) feat(website): show Antigravity and DeepSeek logos | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 101.02 | 126.54 |
| [f090a98ac](https://github.com/AFK-surf/monoid/commit/f090a98ac106b6800d0f3e7a3e2e5ba6f9af3c42) feat(station): add expected_card_seq CAS for MoonB | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 101.02 | 126.54 |
| [4e1e2088a](https://github.com/AFK-surf/monoid/commit/4e1e2088a9bd1ae1fe054d9d1bd689558455afe5) feat(website): list Antigravity instead of Grok Bu | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 101.02 | 126.54 |
| [fcf19b573](https://github.com/AFK-surf/monoid/commit/fcf19b573d6c375e05e29263e071f0addc2bc6ae) ci(desktop): eliminate Post setup pnpm-cache cance | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 101.02 | 126.54 |
| [9ac4cc360](https://github.com/AFK-surf/monoid/commit/9ac4cc3602b75a392d517890ca3552be1beb94c4) fix(station): fail agy turns that end on a quota n | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 101.02 | 126.54 |
| [319706ddc](https://github.com/AFK-surf/monoid/commit/319706ddcfdcd108923f94bf64740972bb43afb6) feat(pion/station): add builders_replica (replica- | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 101.02 | 126.54 |
| [13f57314c](https://github.com/AFK-surf/monoid/commit/13f57314c446843de910d2c106d81ec2faf1ab88) perf(ui): fix host glyph pre-warming and Android p | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 101.02 | 126.54 |
| [8c8dbd7f8](https://github.com/AFK-surf/monoid/commit/8c8dbd7f8e50230a131bccd70c325e376198b01f) perf(replica): read each transcript directory once | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 101.06 | 121.68 |
| [72f43d9c7](https://github.com/AFK-surf/monoid/commit/72f43d9c7ac974f8839076e712f91e7971508287) perf(core): read the person's own lock beside the  | 2.52 | 3.4 | 14.07 | 36.6 | 55.07 | 31.96 | 64.57 | 101.06 | 121.68 |
| [d4b5dade7](https://github.com/AFK-surf/monoid/commit/d4b5dade7f0f2de6d8f940656716715b98eff147) ci(android): hand off monoid beta and mbui-size AP | 2.52 | 3.4 | 14.07 | 37.51 | 58.07 | 31.96 | 64.57 | 101.07 | 121.83 |
| [d9d5f3020](https://github.com/AFK-surf/monoid/commit/d9d5f3020013dceae2d3f8903b3ac55955f80b6b) perf(replica): resume transcript sweeps at their c | 2.52 | 3.4 | 14.07 | 37.51 | 58.07 | 31.96 | 64.57 | 101.07 | 121.83 |
| [4ec25e5df](https://github.com/AFK-surf/monoid/commit/4ec25e5df72e667fae9d30a362989e5385f2bd97) feat(core,ui): add composite CJK font stack, typog | 2.52 | 3.4 | 14.07 | 37.51 | 58.07 | 31.95 | 64.52 | 100.86 | 121.83 |
| [d9b224ff4](https://github.com/AFK-surf/monoid/commit/d9b224ff4a2a4e53ab440aba7ad8a1861db88b80) feat(ui): unify segmented controls and pill tabs o | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 31.95 | 64.52 | 100.86 | 121.83 |
| [df02b2926](https://github.com/AFK-surf/monoid/commit/df02b2926ce7bb7259d932a9010a5d4f007bf060) fix(ui): align pick_bar_desk_node with 40pt pick_b | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 31.95 | 64.54 | 100.88 | 121.83 |
| [3624aac3f](https://github.com/AFK-surf/monoid/commit/3624aac3f4a2d131a10f2cbfbf9204d885b1cf40) perf(core): read the device's values and its notic | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 31.95 | 64.54 | 100.89 | 121.83 |
| [929390e13](https://github.com/AFK-surf/monoid/commit/929390e139704539b8d406107a49a3f7caf72299) fix(ui): align resting segmented thumb to iOS 27 ( | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 31.95 | 64.54 | 101.07 | 121.83 |
| [a783837af](https://github.com/AFK-surf/monoid/commit/a783837af4e9e83cd77f1246ed17a7d68bcf6609) feat(mbui): increase stations list information den | 2.52 | 3.4 | 14.04 | 37.51 | 58.07 | 31.95 | 64.54 | 101.07 | 121.83 |
| [060b36f41](https://github.com/AFK-surf/monoid/commit/060b36f410a29857fa1fff1514dcebc50f50c540) fix(replica): break pass_rows/scan_transcripts liv | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.94 | 64.5 | 100.91 | 121.83 |
| [c40f9ebb2](https://github.com/AFK-surf/monoid/commit/c40f9ebb2253b462b1ae310e5079e91942f0efeb) fix(ci): offload stable Android deltas and feed to | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.94 | 64.5 | 100.91 | 121.83 |
| [34b7fe8e8](https://github.com/AFK-surf/monoid/commit/34b7fe8e851786f06a93e7502764b137123361f9) perf(replica): D72a 256-bucket transcriptManifest  | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.94 | 64.5 | 100.91 | 121.83 |
| [f8da05ca1](https://github.com/AFK-surf/monoid/commit/f8da05ca18dfab6cbf6de9e287f016f9a9813135) feat(ui): replace player sliders with thumb-free f | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.94 | 64.5 | 100.91 | 121.83 |
| [202432542](https://github.com/AFK-surf/monoid/commit/202432542292efed48867fefbf80743f29be8d6c) fix(ci): give stable the Farview deploy key again  | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [95d864545](https://github.com/AFK-surf/monoid/commit/95d8645458bd06355e97ab706ef52ce4cfd50467) feat(pion): W6-A builders_search (--builder search | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [6d1a704bb](https://github.com/AFK-surf/monoid/commit/6d1a704bbacee0040a4e2b5bf189ebfb8795ece2) docs(readme): refresh READMEs and architecture dia | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [264aa0c6c](https://github.com/AFK-surf/monoid/commit/264aa0c6cc81ef2e01a767d20039f8b8411046f5) perf(core): read a person's own lock from the devi | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |
| [8660d4d6f](https://github.com/AFK-surf/monoid/commit/8660d4d6f8c63b55bcd94b1c14760f36d8d76c0e) feat(pion): port --builder usage-counter to Pion ( | 2.52 | 3.4 | 14.03 | 37.51 | 58.07 | 31.93 | 64.49 | 100.78 | 121.83 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [0fa688540](https://github.com/AFK-surf/monoid/commit/0fa688540da1a5ede59dc566d8567c2e16d0144d) feat(station): enforce account concurrency caps ac | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.93 | 57.77 |
| [eebe4c08b](https://github.com/AFK-surf/monoid/commit/eebe4c08bc5c0a056da6cd6a94802c1761353c74) fix(mbui): close the board chat on Esc (#8618) | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.93 | 57.64 |
| [352566952](https://github.com/AFK-surf/monoid/commit/352566952d0319900c610590a715a0af1e2278bb) fix(app): line up a board draft's panel and put wh | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.93 | 57.49 |
| [12b53b34c](https://github.com/AFK-surf/monoid/commit/12b53b34c7a21f149097533e38ff8d533efc74f8) feat(pion): implement W7-B readops_chats L1 packag | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.93 | 57.48 |
| [bf66c2dbb](https://github.com/AFK-surf/monoid/commit/bf66c2dbbc04fa1067f02629b964b5462bb085bc) feat(pion): Wave 7.1 front (--builder forward and  | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.12 | 5.93 | 57.51 |
| [04f23f8f2](https://github.com/AFK-surf/monoid/commit/04f23f8f28d20778832cc3a30277cd4de3ea7487) perf(ui): keep the macOS menu bar in place and ope | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.69 |
| [af836a0fc](https://github.com/AFK-surf/monoid/commit/af836a0fcee54d4fa05d9fe02fce27cb9e6b6374) feat(ui): stop Cmd-click quick-pick at commas (#86 | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.74 |
| [3142ff413](https://github.com/AFK-surf/monoid/commit/3142ff4130b8045ec4942e14d0e2753673a17ce9) feat(pion-station): port W7-C readops_local L1 pac | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.36 |
| [4add66765](https://github.com/AFK-surf/monoid/commit/4add66765d1d397ba8a187600457f348d1573124) feat(station): add workspace chat project & tag cl | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.39 |
| [a6e44a136](https://github.com/AFK-surf/monoid/commit/a6e44a136433173fe51df5157718e92ec2489054) fix(app): let a board draft with files move to ano | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.75 |
| [0fd9c17df](https://github.com/AFK-surf/monoid/commit/0fd9c17df87abfac1853e2557473c03520413733) feat(rules): prove the fork choice of a keeper tha | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.43 |
| [ca9d66655](https://github.com/AFK-surf/monoid/commit/ca9d66655aa6811022cfd8af83d0ddeb03b23303) fix(signals): preserve PENDING in check_dirty when | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.59 |
| [bfc382a17](https://github.com/AFK-surf/monoid/commit/bfc382a1792aa28b6e1e224db14c8c3f2f681eaa) fix(mbui): allow reopening a chat sitting under Ne | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.93 |
| [a442e5fad](https://github.com/AFK-surf/monoid/commit/a442e5fad2c3f279cac7d0c06ded11cb44aa6c72) feat(pion): Wave 7.0 foundation, readops_core, TS  | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.48 |
| [2be102041](https://github.com/AFK-surf/monoid/commit/2be102041ddffe6ebc8a0a4c8504efe9e38fa089) feat(website): show Antigravity and DeepSeek logos | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.44 |
| [f090a98ac](https://github.com/AFK-surf/monoid/commit/f090a98ac106b6800d0f3e7a3e2e5ba6f9af3c42) feat(station): add expected_card_seq CAS for MoonB | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.59 |
| [4e1e2088a](https://github.com/AFK-surf/monoid/commit/4e1e2088a9bd1ae1fe054d9d1bd689558455afe5) feat(website): list Antigravity instead of Grok Bu | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.56 |
| [fcf19b573](https://github.com/AFK-surf/monoid/commit/fcf19b573d6c375e05e29263e071f0addc2bc6ae) ci(desktop): eliminate Post setup pnpm-cache cance | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.46 |
| [9ac4cc360](https://github.com/AFK-surf/monoid/commit/9ac4cc3602b75a392d517890ca3552be1beb94c4) fix(station): fail agy turns that end on a quota n | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.51 |
| [319706ddc](https://github.com/AFK-surf/monoid/commit/319706ddcfdcd108923f94bf64740972bb43afb6) feat(pion/station): add builders_replica (replica- | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.46 |
| [13f57314c](https://github.com/AFK-surf/monoid/commit/13f57314c446843de910d2c106d81ec2faf1ab88) perf(ui): fix host glyph pre-warming and Android p | 0.56 | 0.73 | 2.86 | 3.89 | 7.13 | 2.11 | 5.93 | 57.69 |
| [8c8dbd7f8](https://github.com/AFK-surf/monoid/commit/8c8dbd7f8e50230a131bccd70c325e376198b01f) perf(replica): read each transcript directory once | 0.56 | 0.73 | 2.86 | 3.88 | 7.13 | 2.11 | 5.93 | 57.53 |
| [72f43d9c7](https://github.com/AFK-surf/monoid/commit/72f43d9c7ac974f8839076e712f91e7971508287) perf(core): read the person's own lock beside the  | 0.56 | 0.73 | 2.86 | 3.88 | 7.13 | 2.11 | 5.93 | 57.57 |
| [d4b5dade7](https://github.com/AFK-surf/monoid/commit/d4b5dade7f0f2de6d8f940656716715b98eff147) ci(android): hand off monoid beta and mbui-size AP | 0.56 | 0.73 | 2.86 | 3.88 | 7.13 | 2.11 | 5.93 | 57.66 |
| [d9d5f3020](https://github.com/AFK-surf/monoid/commit/d9d5f3020013dceae2d3f8903b3ac55955f80b6b) perf(replica): resume transcript sweeps at their c | 0.56 | 0.73 | 2.86 | 3.88 | 7.13 | 2.11 | 5.93 | 57.67 |
| [4ec25e5df](https://github.com/AFK-surf/monoid/commit/4ec25e5df72e667fae9d30a362989e5385f2bd97) feat(core,ui): add composite CJK font stack, typog | 0.56 | 0.73 | 2.86 | 3.88 | 7.13 | 2.11 | 5.93 | 57.89 |
| [d9b224ff4](https://github.com/AFK-surf/monoid/commit/d9b224ff4a2a4e53ab440aba7ad8a1861db88b80) feat(ui): unify segmented controls and pill tabs o | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.56 |
| [df02b2926](https://github.com/AFK-surf/monoid/commit/df02b2926ce7bb7259d932a9010a5d4f007bf060) fix(ui): align pick_bar_desk_node with 40pt pick_b | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.38 |
| [3624aac3f](https://github.com/AFK-surf/monoid/commit/3624aac3f4a2d131a10f2cbfbf9204d885b1cf40) perf(core): read the device's values and its notic | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.41 |
| [929390e13](https://github.com/AFK-surf/monoid/commit/929390e139704539b8d406107a49a3f7caf72299) fix(ui): align resting segmented thumb to iOS 27 ( | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.31 |
| [a783837af](https://github.com/AFK-surf/monoid/commit/a783837af4e9e83cd77f1246ed17a7d68bcf6609) feat(mbui): increase stations list information den | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.71 |
| [060b36f41](https://github.com/AFK-surf/monoid/commit/060b36f410a29857fa1fff1514dcebc50f50c540) fix(replica): break pass_rows/scan_transcripts liv | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.57 |
| [c40f9ebb2](https://github.com/AFK-surf/monoid/commit/c40f9ebb2253b462b1ae310e5079e91942f0efeb) fix(ci): offload stable Android deltas and feed to | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 58.03 |
| [34b7fe8e8](https://github.com/AFK-surf/monoid/commit/34b7fe8e851786f06a93e7502764b137123361f9) perf(replica): D72a 256-bucket transcriptManifest  | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.21 |
| [f8da05ca1](https://github.com/AFK-surf/monoid/commit/f8da05ca18dfab6cbf6de9e287f016f9a9813135) feat(ui): replace player sliders with thumb-free f | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.54 |
| [202432542](https://github.com/AFK-surf/monoid/commit/202432542292efed48867fefbf80743f29be8d6c) fix(ci): give stable the Farview deploy key again  | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.48 |
| [95d864545](https://github.com/AFK-surf/monoid/commit/95d8645458bd06355e97ab706ef52ce4cfd50467) feat(pion): W6-A builders_search (--builder search | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.95 |
| [6d1a704bb](https://github.com/AFK-surf/monoid/commit/6d1a704bbacee0040a4e2b5bf189ebfb8795ece2) docs(readme): refresh READMEs and architecture dia | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.82 |
| [264aa0c6c](https://github.com/AFK-surf/monoid/commit/264aa0c6cc81ef2e01a767d20039f8b8411046f5) perf(core): read a person's own lock from the devi | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.53 |
| [8660d4d6f](https://github.com/AFK-surf/monoid/commit/8660d4d6f8c63b55bcd94b1c14760f36d8d76c0e) feat(pion): port --builder usage-counter to Pion ( | 0.56 | 0.73 | 2.84 | 3.86 | 7.08 | 2.1 | 5.88 | 57.69 |
