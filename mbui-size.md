# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [0ef14d118](https://github.com/AFK-surf/monoid/commit/0ef14d1188dd4ea47d13845a074bbc6532c7ec42) fix(station): await in-flight stateDir removal acr | 2.73 | 3.69 | 15.31 | 38.44 | 59.31 | 33.68 | 68.88 | 103.68 | 134.43 |
| [ea9ed02cb](https://github.com/AFK-surf/monoid/commit/ea9ed02cb073cd8425848a6c9e62387b97015213) fix(mbui): open the model panel at its foot and ke | 2.72 | 3.68 | 15.27 | 38.39 | 59.16 | 33.64 | 68.76 | 103.47 | 133.05 |
| [1f8e7b096](https://github.com/AFK-surf/monoid/commit/1f8e7b0965b35bf1c8c48739c2a43e437c92a2d1) feat(ui,mbui): add DataTable and fixed-header wide | 2.72 | 3.68 | 15.27 | 38.39 | 59.16 | 33.63 | 68.73 | 103.7 | 131.87 |
| [c1f8f8ff5](https://github.com/AFK-surf/monoid/commit/c1f8f8ff5a7b143832b0b2a674f18675296345f3) fix(ui): align dialog/sheet heads, iOS 27 38pt geo | 2.72 | 3.68 | 15.27 | 38.39 | 59.16 | 33.63 | 68.73 | 103.7 | 131.87 |
| [a93db9c1d](https://github.com/AFK-surf/monoid/commit/a93db9c1d22daed4cc35a4f90254216426dd4e5f) feat(ui): add View::covered_box, SleepScope.frozen | 2.71 | 3.68 | 15.26 | 38.39 | 59.13 | 33.63 | 68.73 | 103.7 | 128.94 |
| [b504fd14e](https://github.com/AFK-surf/monoid/commit/b504fd14ef3e5f49e3ebd883363b7946a0641e93) feat(mbui): pick a preset's stations in the statio | 2.72 | 3.68 | 15.26 | 38.39 | 59.12 | 33.64 | 68.73 | 103.5 | 141.68 |
| [bbd8d2fc0](https://github.com/AFK-surf/monoid/commit/bbd8d2fc064414d898ae25517f296fdcbcf3a5c2) feat(mbui): align Profiles quota share picture wit | 2.71 | 3.67 | 15.25 | 38.38 | 59.11 | 33.63 | 68.71 | 103.48 | 113.86 |
| [835f3aec8](https://github.com/AFK-surf/monoid/commit/835f3aec8d4510ceadc415b02a745a65247b977d) fix(cloud): drain queued frames and skip duplicate | 2.71 | 3.67 | 15.25 | 38.38 | 59.11 | 33.63 | 68.71 | 103.48 | 113.86 |
| [e352d3138](https://github.com/AFK-surf/monoid/commit/e352d3138e4714abbf6309d4b0183a5a34d1828b) fix(cloud): allow rig owners to upload custom stat | 2.71 | 3.67 | 15.25 | 38.38 | 59.11 | 33.61 | 68.66 | 103.7 | 129.79 |
| [7d10e1bae](https://github.com/AFK-surf/monoid/commit/7d10e1bae342fcc0f29ad04552f8dc2e0b6ee29b) perf(ui/text): O(1) CJK range lookup, lazy rich li | 2.71 | 3.67 | 15.25 | 38.38 | 59.11 | 33.61 | 68.66 | 103.7 | 129.79 |
| [0d1a636af](https://github.com/AFK-surf/monoid/commit/0d1a636afb53cf81c9b5ecf2bf34702869b54c10) docs(releases): 0.1.11718 stable notes (#9095) | 2.71 | 3.67 | 15.25 | 38.38 | 59.11 | 33.61 | 68.66 | 103.7 | 129.79 |
| [9f2817e54](https://github.com/AFK-surf/monoid/commit/9f2817e54f553ef17254858e404889232dd16ca3) feat(mbui): compact grouped Profiles & Connects ro | 2.71 | 3.67 | 15.25 | 38.38 | 59.11 | 33.61 | 68.66 | 103.7 | 129.79 |
| [89089da80](https://github.com/AFK-surf/monoid/commit/89089da803552093d1ba066dc83c94f3d1c0aaf1) ci(mbui): speed up pages test build on release/* a | 2.71 | 3.67 | 15.23 | 38.36 | 59.04 | 33.61 | 68.66 | 103.7 | 124.28 |
| [2bfbbefca](https://github.com/AFK-surf/monoid/commit/2bfbbefca014ba5add4b7d96d5b50aa0e476c075) chore(ui/ui): eliminate remaining mbt2pion publish | 2.71 | 3.67 | 15.23 | 38.36 | 59.04 | 33.61 | 68.66 | 103.7 | 124.28 |
| [6dfc70c60](https://github.com/AFK-surf/monoid/commit/6dfc70c60e598dd23c945bfee1153f829d9203c0) feat(core,mbui): PR-B2b topic policy evolution, MB | 2.71 | 3.67 | 15.23 | 38.36 | 59.04 | 33.61 | 68.66 | 103.52 | 111.06 |
| [6c31cadf0](https://github.com/AFK-surf/monoid/commit/6c31cadf0c75ed2e9e19c8f16e784377010ead51) feat(mbui): jump to NewChat with current chat @ref | 2.7 | 3.66 | 15.2 | 38.26 | 58.91 | 33.51 | 68.53 | 103.3 | 126.98 |
| [4e97bdec0](https://github.com/AFK-surf/monoid/commit/4e97bdec08523a8bdb980f04d6664ebece312599) feat(vault): workspace vault discovery, join reque | 2.7 | 3.66 | 15.2 | 38.25 | 58.9 | 33.51 | 68.53 | 103.17 | 132.24 |
| [e65a7cd01](https://github.com/AFK-surf/monoid/commit/e65a7cd01f8b7a0b511c6ab99689af00a795534b) feat(pion-core): unshadow runtime stubs and close  | 2.7 | 3.66 | 15.2 | 38.25 | 58.9 | 33.51 | 68.53 | 103.17 | 132.24 |
| [deaa0f205](https://github.com/AFK-surf/monoid/commit/deaa0f205acec647467c79c8f9addb3baca1ee74) chore(mbui): clean up mbt2pion publish diagnostics | 2.7 | 3.66 | 15.2 | 38.25 | 58.9 | 33.51 | 68.53 | 103.17 | 132.24 |
| [a3fbb3cea](https://github.com/AFK-surf/monoid/commit/a3fbb3cea7aec57ad9595b3b3da2e5d58984ebcf) feat(mbui): add grouped '+' tab picker to the righ | 2.7 | 3.66 | 15.2 | 38.25 | 58.9 | 33.51 | 68.53 | 103.11 | 130.82 |
| [e37478849](https://github.com/AFK-surf/monoid/commit/e374788490f89c16fd776c274863811a7f9e49d5) perf(ui/gles): batch independent glass captures, d | 2.7 | 3.66 | 15.2 | 38.24 | 58.88 | 33.5 | 68.53 | 103.14 | 128.79 |
| [f31d101b1](https://github.com/AFK-surf/monoid/commit/f31d101b1b113d4a520d6bc2a1c07b42a99dea61) perf(changelog): ask with If-None-Match and keep t | 2.7 | 3.66 | 15.2 | 38.24 | 58.88 | 33.5 | 68.53 | 103.14 | 128.79 |
| [ab4324b51](https://github.com/AFK-surf/monoid/commit/ab4324b51e045544fe4267a908524c9e9e06d9fe) fix(ui): fix dark-mode Role 4 tab droplet meniscus | 2.7 | 3.66 | 15.19 | 38.24 | 58.92 | 33.5 | 68.53 | 103.14 | 129.35 |
| [4912e2dc1](https://github.com/AFK-surf/monoid/commit/4912e2dc1c8b82bfb73b1e9ab4fa8f817636cda8) refactor(ui): clear mbt2pion publish diagnostics i | 2.7 | 3.66 | 15.19 | 38.23 | 58.92 | 33.5 | 68.53 | 103.37 | 120.52 |
| [8ff4458de](https://github.com/AFK-surf/monoid/commit/8ff4458de9750c2ed47998ecf42847eefbc6a7d7) chore(ui/ui): idiomatic array loops & explicit typ | 2.7 | 3.66 | 15.19 | 38.23 | 58.92 | 33.5 | 68.53 | 103.37 | 120.52 |
| [31da00470](https://github.com/AFK-surf/monoid/commit/31da004703f0d4e6e788e3a5164fcb0650671d81) fix(mbui): drop the rest ground behind chat bar ta | 2.7 | 3.66 | 15.19 | 38.23 | 58.92 | 33.5 | 68.53 | 103.37 | 120.52 |
| [a5422d092](https://github.com/AFK-surf/monoid/commit/a5422d092dc3e44a286b4e40ccc4638601073af1) refactor(ui): make ui/headless and ui/motion idiom | 2.7 | 3.66 | 15.19 | 38.24 | 58.92 | 33.5 | 68.55 | 103.94 | 134.47 |
| [1f5d32c4f](https://github.com/AFK-surf/monoid/commit/1f5d32c4f387626e7452ce61be621992bfa4a4dd) fix(ui): stop menu text jitter during expand, coll | 2.7 | 3.66 | 15.19 | 38.23 | 58.9 | 33.49 | 68.52 | 103.09 | 125.09 |
| [04a80feec](https://github.com/AFK-surf/monoid/commit/04a80feec38312ba0245b925de4f307305cfc6fb) fix(ui,mbui): dissolve outgoing sticky section hea | 2.7 | 3.66 | 15.19 | 38.23 | 58.9 | 33.5 | 68.52 | 103.17 | 108.29 |
| [982bd89ab](https://github.com/AFK-surf/monoid/commit/982bd89ab2ef6d8a578ff89ece6ea26f9cd52ef3) fix(ui): keep player controls as they were when a  | 2.7 | 3.66 | 15.19 | 38.23 | 58.9 | 33.5 | 68.52 | 103.17 | 108.29 |
| [d2732be96](https://github.com/AFK-surf/monoid/commit/d2732be96b991b95b1c99bddba34e3904efa3457) fix(mbui): bud the tab bar's ＋ smoothly without co | 2.7 | 3.66 | 15.19 | 38.23 | 58.9 | 33.5 | 68.52 | 103.27 | 129.85 |
| [e032c1f68](https://github.com/AFK-surf/monoid/commit/e032c1f68a1a0a5895d3fa156354cccb22f93f70) style(mbui): refine media progress and video corne | 2.7 | 3.66 | 15.19 | 38.23 | 58.9 | 33.5 | 68.52 | 102.99 | 134.59 |
| [f871f191f](https://github.com/AFK-surf/monoid/commit/f871f191fb6b70898b646b5c585d76e25d04dd03) fix(mbui): drop the hover ring on the rail's works | 2.7 | 3.66 | 15.18 | 38.23 | 58.89 | 33.49 | 68.5 | 103.11 | 107.15 |
| [b0dccfbe3](https://github.com/AFK-surf/monoid/commit/b0dccfbe3fd70202888515630bb6f93fd5c4b99a) fix(core): force vault readStation after direct RP | 2.69 | 3.64 | 15.12 | 38.17 | 58.71 | 33.44 | 68.35 | 103.32 | 125.98 |
| [0abb12bcc](https://github.com/AFK-surf/monoid/commit/0abb12bcc4aa6372df8ff881fe936ba9c8cd241f) fix(ui,mbui): tighten filter pill to 28pt capsule  | 2.69 | 3.64 | 15.12 | 38.17 | 58.71 | 33.44 | 68.35 | 103.32 | 125.98 |
| [36e832ca1](https://github.com/AFK-surf/monoid/commit/36e832ca1da5f831119dcdaf2e551cff9e2f1343) perf(ui,mbui): snap sliding pane offsets, defer la | 2.69 | 3.64 | 15.12 | 38.17 | 58.71 | 33.44 | 68.35 | 103.3 | 136.48 |
| [f4121f666](https://github.com/AFK-surf/monoid/commit/f4121f66695c19b5891d7787469d542723fc762c) refactor(android,core): use monotonic dispatch tok | 2.69 | 3.64 | 15.12 | 38.17 | 58.71 | 33.44 | 68.35 | 103.3 | 136.48 |
| [83640c3cc](https://github.com/AFK-surf/monoid/commit/83640c3cc46c4a2313039a2f29cbafcf31d7f069) perf(station): join streamed frame pieces once in  | 2.69 | 3.64 | 15.11 | 38.16 | 58.69 | 33.44 | 68.35 | 103.35 | 135.75 |
| [a876a5380](https://github.com/AFK-surf/monoid/commit/a876a53806f66277bd14f3637dd1806cf6a2f471) fix(safe-mode): guide unprotected moved-lock stati | 2.69 | 3.64 | 15.11 | 38.16 | 58.69 | 33.44 | 68.35 | 103.35 | 135.75 |
| [87ddbc239](https://github.com/AFK-surf/monoid/commit/87ddbc2398952eaccee54590777881c4b8a84687) fix(mbui): narrow loading image breathing amplitud | 2.69 | 3.64 | 15.11 | 38.16 | 58.69 | 33.44 | 68.35 | 103.35 | 135.75 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [0ef14d118](https://github.com/AFK-surf/monoid/commit/0ef14d1188dd4ea47d13845a074bbc6532c7ec42) fix(station): await in-flight stateDir removal acr | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.64 |
| [ea9ed02cb](https://github.com/AFK-surf/monoid/commit/ea9ed02cb073cd8425848a6c9e62387b97015213) fix(mbui): open the model panel at its foot and ke | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.56 |
| [1f8e7b096](https://github.com/AFK-surf/monoid/commit/1f8e7b0965b35bf1c8c48739c2a43e437c92a2d1) feat(ui,mbui): add DataTable and fixed-header wide | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.75 |
| [c1f8f8ff5](https://github.com/AFK-surf/monoid/commit/c1f8f8ff5a7b143832b0b2a674f18675296345f3) fix(ui): align dialog/sheet heads, iOS 27 38pt geo | 0.59 | 0.78 | 3.03 | 4.06 | 7.54 | 2.23 | 6.31 | 57.62 |
| [a93db9c1d](https://github.com/AFK-surf/monoid/commit/a93db9c1d22daed4cc35a4f90254216426dd4e5f) feat(ui): add View::covered_box, SleepScope.frozen | 0.59 | 0.78 | 3.03 | 4.06 | 7.53 | 2.23 | 6.31 | 57.57 |
| [b504fd14e](https://github.com/AFK-surf/monoid/commit/b504fd14ef3e5f49e3ebd883363b7946a0641e93) feat(mbui): pick a preset's stations in the statio | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.62 |
| [bbd8d2fc0](https://github.com/AFK-surf/monoid/commit/bbd8d2fc064414d898ae25517f296fdcbcf3a5c2) feat(mbui): align Profiles quota share picture wit | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.74 |
| [835f3aec8](https://github.com/AFK-surf/monoid/commit/835f3aec8d4510ceadc415b02a745a65247b977d) fix(cloud): drain queued frames and skip duplicate | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.43 |
| [e352d3138](https://github.com/AFK-surf/monoid/commit/e352d3138e4714abbf6309d4b0183a5a34d1828b) fix(cloud): allow rig owners to upload custom stat | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.29 | 57.75 |
| [7d10e1bae](https://github.com/AFK-surf/monoid/commit/7d10e1bae342fcc0f29ad04552f8dc2e0b6ee29b) perf(ui/text): O(1) CJK range lookup, lazy rich li | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.93 |
| [0d1a636af](https://github.com/AFK-surf/monoid/commit/0d1a636afb53cf81c9b5ecf2bf34702869b54c10) docs(releases): 0.1.11718 stable notes (#9095) | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.29 | 57.49 |
| [9f2817e54](https://github.com/AFK-surf/monoid/commit/9f2817e54f553ef17254858e404889232dd16ca3) feat(mbui): compact grouped Profiles & Connects ro | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.29 | 57.84 |
| [89089da80](https://github.com/AFK-surf/monoid/commit/89089da803552093d1ba066dc83c94f3d1c0aaf1) ci(mbui): speed up pages test build on release/* a | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.29 | 57.77 |
| [2bfbbefca](https://github.com/AFK-surf/monoid/commit/2bfbbefca014ba5add4b7d96d5b50aa0e476c075) chore(ui/ui): eliminate remaining mbt2pion publish | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.29 | 58.31 |
| [6dfc70c60](https://github.com/AFK-surf/monoid/commit/6dfc70c60e598dd23c945bfee1153f829d9203c0) feat(core,mbui): PR-B2b topic policy evolution, MB | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.98 |
| [6c31cadf0](https://github.com/AFK-surf/monoid/commit/6c31cadf0c75ed2e9e19c8f16e784377010ead51) feat(mbui): jump to NewChat with current chat @ref | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.82 |
| [4e97bdec0](https://github.com/AFK-surf/monoid/commit/4e97bdec08523a8bdb980f04d6664ebece312599) feat(vault): workspace vault discovery, join reque | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.62 |
| [e65a7cd01](https://github.com/AFK-surf/monoid/commit/e65a7cd01f8b7a0b511c6ab99689af00a795534b) feat(pion-core): unshadow runtime stubs and close  | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.67 |
| [deaa0f205](https://github.com/AFK-surf/monoid/commit/deaa0f205acec647467c79c8f9addb3baca1ee74) chore(mbui): clean up mbt2pion publish diagnostics | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.62 |
| [a3fbb3cea](https://github.com/AFK-surf/monoid/commit/a3fbb3cea7aec57ad9595b3b3da2e5d58984ebcf) feat(mbui): add grouped '+' tab picker to the righ | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 58 |
| [e37478849](https://github.com/AFK-surf/monoid/commit/e374788490f89c16fd776c274863811a7f9e49d5) perf(ui/gles): batch independent glass captures, d | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.67 |
| [f31d101b1](https://github.com/AFK-surf/monoid/commit/f31d101b1b113d4a520d6bc2a1c07b42a99dea61) perf(changelog): ask with If-None-Match and keep t | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.77 |
| [ab4324b51](https://github.com/AFK-surf/monoid/commit/ab4324b51e045544fe4267a908524c9e9e06d9fe) fix(ui): fix dark-mode Role 4 tab droplet meniscus | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.59 |
| [4912e2dc1](https://github.com/AFK-surf/monoid/commit/4912e2dc1c8b82bfb73b1e9ab4fa8f817636cda8) refactor(ui): clear mbt2pion publish diagnostics i | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 58.02 |
| [8ff4458de](https://github.com/AFK-surf/monoid/commit/8ff4458de9750c2ed47998ecf42847eefbc6a7d7) chore(ui/ui): idiomatic array loops & explicit typ | 0.59 | 0.78 | 3.02 | 4.06 | 7.52 | 2.23 | 6.31 | 57.67 |
| [31da00470](https://github.com/AFK-surf/monoid/commit/31da004703f0d4e6e788e3a5164fcb0650671d81) fix(mbui): drop the rest ground behind chat bar ta | 0.59 | 0.78 | 3.02 | 4.05 | 7.52 | 2.23 | 6.31 | 57.69 |
| [a5422d092](https://github.com/AFK-surf/monoid/commit/a5422d092dc3e44a286b4e40ccc4638601073af1) refactor(ui): make ui/headless and ui/motion idiom | 0.59 | 0.78 | 3.02 | 4.05 | 7.52 | 2.23 | 6.31 | 57.92 |
| [1f5d32c4f](https://github.com/AFK-surf/monoid/commit/1f5d32c4f387626e7452ce61be621992bfa4a4dd) fix(ui): stop menu text jitter during expand, coll | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.23 | 6.28 | 57.9 |
| [04a80feec](https://github.com/AFK-surf/monoid/commit/04a80feec38312ba0245b925de4f307305cfc6fb) fix(ui,mbui): dissolve outgoing sticky section hea | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.23 | 6.28 | 57.97 |
| [982bd89ab](https://github.com/AFK-surf/monoid/commit/982bd89ab2ef6d8a578ff89ece6ea26f9cd52ef3) fix(ui): keep player controls as they were when a  | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.51 |
| [d2732be96](https://github.com/AFK-surf/monoid/commit/d2732be96b991b95b1c99bddba34e3904efa3457) fix(mbui): bud the tab bar's ＋ smoothly without co | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.59 |
| [e032c1f68](https://github.com/AFK-surf/monoid/commit/e032c1f68a1a0a5895d3fa156354cccb22f93f70) style(mbui): refine media progress and video corne | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.75 |
| [f871f191f](https://github.com/AFK-surf/monoid/commit/f871f191fb6b70898b646b5c585d76e25d04dd03) fix(mbui): drop the hover ring on the rail's works | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.69 |
| [b0dccfbe3](https://github.com/AFK-surf/monoid/commit/b0dccfbe3fd70202888515630bb6f93fd5c4b99a) fix(core): force vault readStation after direct RP | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.56 |
| [0abb12bcc](https://github.com/AFK-surf/monoid/commit/0abb12bcc4aa6372df8ff881fe936ba9c8cd241f) fix(ui,mbui): tighten filter pill to 28pt capsule  | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.53 |
| [36e832ca1](https://github.com/AFK-surf/monoid/commit/36e832ca1da5f831119dcdaf2e551cff9e2f1343) perf(ui,mbui): snap sliding pane offsets, defer la | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 65.37 |
| [f4121f666](https://github.com/AFK-surf/monoid/commit/f4121f66695c19b5891d7787469d542723fc762c) refactor(android,core): use monotonic dispatch tok | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.48 |
| [83640c3cc](https://github.com/AFK-surf/monoid/commit/83640c3cc46c4a2313039a2f29cbafcf31d7f069) perf(station): join streamed frame pieces once in  | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.49 |
| [a876a5380](https://github.com/AFK-surf/monoid/commit/a876a53806f66277bd14f3637dd1806cf6a2f471) fix(safe-mode): guide unprotected moved-lock stati | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.43 |
| [87ddbc239](https://github.com/AFK-surf/monoid/commit/87ddbc2398952eaccee54590777881c4b8a84687) fix(mbui): narrow loading image breathing amplitud | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.74 |
