# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [36e832ca1](https://github.com/AFK-surf/monoid/commit/36e832ca1da5f831119dcdaf2e551cff9e2f1343) perf(ui,mbui): snap sliding pane offsets, defer la | 2.69 | 3.64 | 15.12 | 38.17 | 58.71 | 33.44 | 68.35 | 103.3 | 136.48 |
| [f4121f666](https://github.com/AFK-surf/monoid/commit/f4121f66695c19b5891d7787469d542723fc762c) refactor(android,core): use monotonic dispatch tok | 2.69 | 3.64 | 15.12 | 38.17 | 58.71 | 33.44 | 68.35 | 103.3 | 136.48 |
| [83640c3cc](https://github.com/AFK-surf/monoid/commit/83640c3cc46c4a2313039a2f29cbafcf31d7f069) perf(station): join streamed frame pieces once in  | 2.69 | 3.64 | 15.11 | 38.16 | 58.69 | 33.44 | 68.35 | 103.35 | 135.75 |
| [a876a5380](https://github.com/AFK-surf/monoid/commit/a876a53806f66277bd14f3637dd1806cf6a2f471) fix(safe-mode): guide unprotected moved-lock stati | 2.69 | 3.64 | 15.11 | 38.16 | 58.69 | 33.44 | 68.35 | 103.35 | 135.75 |
| [87ddbc239](https://github.com/AFK-surf/monoid/commit/87ddbc2398952eaccee54590777881c4b8a84687) fix(mbui): narrow loading image breathing amplitud | 2.69 | 3.64 | 15.11 | 38.16 | 58.69 | 33.44 | 68.35 | 103.35 | 135.75 |
| [50f121136](https://github.com/AFK-surf/monoid/commit/50f12113609f1b16914c1c2ea59ebe6ea2c6deed) fix(core): batch personal-signer and extraKeys int | 2.69 | 3.64 | 15.11 | 38.16 | 58.69 | 33.44 | 68.35 | 103.15 | 154.34 |
| [3037efae5](https://github.com/AFK-surf/monoid/commit/3037efae5bad875e4ace8e620d6ae4c1e7b36049) fix(vault): decouple per-vault KeyAsk from BoxCert | 2.69 | 3.64 | 15.11 | 38.16 | 58.69 | 33.44 | 68.35 | 103.19 | 136.76 |
| [d85d5ddf4](https://github.com/AFK-surf/monoid/commit/d85d5ddf462d064033901c44ebbc6cf026e2a993) feat(station-main): wire WholeCore into whole_daem | 2.69 | 3.64 | 15.11 | 38.16 | 58.69 | 33.42 | 68.33 | 103.22 | 117.62 |
| [bf2170d8e](https://github.com/AFK-surf/monoid/commit/bf2170d8e020e0f417ec190fc135ad9c4a994857) refactor(core,mbui): replace manual auth-gen tuple | 2.69 | 3.64 | 15.11 | 38.16 | 58.69 | 33.42 | 68.33 | 103.22 | 117.62 |
| [42bf07e01](https://github.com/AFK-surf/monoid/commit/42bf07e012517d7a7df70ae2e6c6b1f07d49ef4e) perf(station): reuse fresh Helper grants in macOS  | 2.69 | 3.64 | 15.11 | 38.14 | 58.65 | 33.41 | 68.32 | 102.91 | 130.28 |
| [387a9d744](https://github.com/AFK-surf/monoid/commit/387a9d744083b417403f1ee91bae198134fd9672) fix(ui): keep adaptive glass ink dark over kind 9  | 2.69 | 3.64 | 15.11 | 38.14 | 58.65 | 33.41 | 68.32 | 102.91 | 130.28 |
| [b9ab7e501](https://github.com/AFK-surf/monoid/commit/b9ab7e501a7a6cf1265567918fd51c296dd15e04) fix(mbui): explain why typed emails cannot be adde | 2.68 | 3.63 | 15.09 | 38.12 | 58.57 | 33.4 | 68.27 | 103.04 | 133.33 |
| [073a8026e](https://github.com/AFK-surf/monoid/commit/073a8026e80c8c8cd2fe52b033b2e6775978588e) fix(station): prevent evicting idle agy sessions w | 2.68 | 3.63 | 15.09 | 38.12 | 58.57 | 33.4 | 68.27 | 103.04 | 133.33 |
| [575cbdc10](https://github.com/AFK-surf/monoid/commit/575cbdc1071a70a38087e9e9fa5c6c45d7c08381) feat(station,core,mbui): invoke attached agent ski | 2.68 | 3.63 | 15.09 | 38.12 | 58.57 | 33.4 | 68.27 | 103.04 | 133.33 |
| [29a0c3082](https://github.com/AFK-surf/monoid/commit/29a0c30829680c42407bde6dd3bea1e333122f5f) fix(mbui): require 500ms hover dwell before peekin | 2.68 | 3.63 | 15.09 | 38.12 | 58.57 | 33.4 | 68.27 | 103.04 | 133.33 |
| [65946164d](https://github.com/AFK-surf/monoid/commit/65946164d5e902e5e9b0bb6c20a02c3506f518f7) fix(station): link session pages on the workspace' | 2.68 | 3.63 | 15.09 | 38.12 | 58.57 | 33.4 | 68.27 | 103.04 | 133.33 |
| [0ca3ccb00](https://github.com/AFK-surf/monoid/commit/0ca3ccb00dba73acf87c7aad0b71ac6fd7ebdd6b) perf(mbui): virtualize attention panel, optimize q | 2.68 | 3.63 | 15.09 | 38.12 | 58.57 | 33.4 | 68.27 | 103.04 | 133.33 |
| [136bba585](https://github.com/AFK-surf/monoid/commit/136bba5854eb3da36bd7feef8e2f5dd946d6ff0c) perf(station): rank relays by lowest measured RTT  | 2.68 | 3.63 | 15.07 | 38.1 | 58.51 | 33.39 | 68.22 | 102.94 | 118.89 |
| [b29538437](https://github.com/AFK-surf/monoid/commit/b29538437809b6fc38e2627854de6b368cbed3e1) fix(station): keep heap watch failures from crashi | 2.68 | 3.63 | 15.07 | 38.1 | 58.51 | 33.39 | 68.22 | 102.94 | 133.73 |
| [393e388aa](https://github.com/AFK-surf/monoid/commit/393e388aa729496674e510fa5d27634c8ad3130e) fix(ui): keep a sidebar row lit while the pointer  | 2.68 | 3.63 | 15.07 | 38.1 | 58.51 | 33.39 | 68.22 | 102.94 | 133.73 |
| [5c55be6c3](https://github.com/AFK-surf/monoid/commit/5c55be6c385421c96872ae6997880fe41b09e4ea) refactor(android): split FramePacer into FrameSche | 2.68 | 3.63 | 15.07 | 38.1 | 58.51 | 33.39 | 68.22 | 103.12 | 126.04 |
| [33c0e85b8](https://github.com/AFK-surf/monoid/commit/33c0e85b896bd85449de49c6c8c2667e2346b492) fix(ui): keep a rounded clip's corners when a cut  | 2.68 | 3.63 | 15.07 | 38.1 | 58.51 | 33.39 | 68.22 | 103.12 | 126.04 |
| [65c90e3d0](https://github.com/AFK-surf/monoid/commit/65c90e3d052ca3e3e269e01353a7ca4c543f5283) feat(mbui): park passive side-panel tabs via pick_ | 2.68 | 3.63 | 15.07 | 38.1 | 58.51 | 33.33 | 68.02 | 103.14 | 138.02 |
| [555d9fa17](https://github.com/AFK-surf/monoid/commit/555d9fa172a1c020ecf7717c42dac9607a22e1c4) fix(core,e2e): track Node CallAuth boundaries and  | 2.67 | 3.62 | 14.99 | 38.03 | 58.26 | 33.33 | 68.02 | 103.14 | 137.95 |
| [18522df13](https://github.com/AFK-surf/monoid/commit/18522df1332910f049465b2433e3f03f2865e22e) feat(mbui): redesign Profiles with three-tier layo | 2.67 | 3.62 | 14.99 | 38.03 | 58.26 | 33.33 | 68.02 | 103.37 | 141.85 |
| [cb5e6a579](https://github.com/AFK-surf/monoid/commit/cb5e6a57984860893580ac366bf1e4e4b9d11f3a) ci(mbui): key iOS unit store by compiler and SDK,  | 2.67 | 3.62 | 14.99 | 38.03 | 58.26 | 33.33 | 68.02 | 103.37 | 141.85 |
| [62e5252c4](https://github.com/AFK-surf/monoid/commit/62e5252c49c56c0f952eb5fabdeae3c5a4dd9c7c) feat(ui): split phone player top bar into bare tit | 2.67 | 3.62 | 14.99 | 38.03 | 58.26 | 33.33 | 68.02 | 103.37 | 141.85 |
| [8f6b37be3](https://github.com/AFK-surf/monoid/commit/8f6b37be3b0c02b179b5f3314b541c7391723dc2) fix(android): track Choreographer vsync generation | 2.67 | 3.61 | 14.99 | 38.03 | 58.24 | 33.32 | 67.99 | 103.02 | 131.83 |
| [23f501c02](https://github.com/AFK-surf/monoid/commit/23f501c02c24abddf9b9a9f2a98c2146fc7a11fd) fix(ui): fix adaptive glass ink, dark contour on b | 2.67 | 3.61 | 14.98 | 38.03 | 58.19 | 33.32 | 67.97 | 102.89 | 135.39 |
| [dcc7a90e0](https://github.com/AFK-surf/monoid/commit/dcc7a90e062b622c4da63040bb111b5c58428678) fix(mbui): relocate small-screen group pill above  | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 103.09 | 131.45 |
| [b9c66c6cf](https://github.com/AFK-surf/monoid/commit/b9c66c6cfa60f5c89eff99f8634d960b7851e918) feat(station-whole): add production OS adapters fo | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 103.09 | 131.45 |
| [fffd1fc0d](https://github.com/AFK-surf/monoid/commit/fffd1fc0db454e753b0475479c6d730704b8e703) perf(station): track borrowed-profile liveness wit | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 103.09 | 131.45 |
| [b9ded7d55](https://github.com/AFK-surf/monoid/commit/b9ded7d55686d46f159ca675666de8ab3d37ef99) fix(mbui): keep watched topics reactive on auth sc | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 103.09 | 131.45 |
| [3548369bf](https://github.com/AFK-surf/monoid/commit/3548369bf6d69f5cd5342ee6231f105a2389ae5a) perf(cloud): cache compact changelog fixes and bat | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 109.2 | 122.42 |
| [888341385](https://github.com/AFK-surf/monoid/commit/888341385d2dd34f3489cfcd2dbaf6aa5a08c24d) fix(station): offer Copilot models GitHub lists wi | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 109.2 | 122.42 |
| [c793e8932](https://github.com/AFK-surf/monoid/commit/c793e8932be884d034b45c2b5e41747bfe94fd3d) perf(cloud): single-flight cache changelog and rel | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 109.2 | 122.42 |
| [e3218e65a](https://github.com/AFK-surf/monoid/commit/e3218e65aa16b7e28b8b6c6757e38fa5f157eef0) perf(station,core): stream incremental overview-pa | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 109.2 | 122.42 |
| [36bef9f96](https://github.com/AFK-surf/monoid/commit/36bef9f96a1e71d686c5c71fe550e82cd7ec0dfc) fix(station): end a turn that stays silent after i | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 108.89 | 125.14 |
| [0c05c70eb](https://github.com/AFK-surf/monoid/commit/0c05c70ebc24863896e6e66b029a60309712c263) feat(mbui): migrate profiles/stations places to pi | 2.67 | 3.61 | 14.98 | 38.02 | 58.19 | 33.32 | 67.97 | 108.89 | 125.14 |
| [c14a4b71d](https://github.com/AFK-surf/monoid/commit/c14a4b71d0f144c24929d1021d967b1f5e1b3f05) feat(core,mbui): add authGen/vaultGen sync boundar | 2.67 | 3.61 | 14.99 | 38.02 | 58.24 | 33.33 | 67.99 | 108.89 | 125.14 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [36e832ca1](https://github.com/AFK-surf/monoid/commit/36e832ca1da5f831119dcdaf2e551cff9e2f1343) perf(ui,mbui): snap sliding pane offsets, defer la | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 65.37 |
| [f4121f666](https://github.com/AFK-surf/monoid/commit/f4121f66695c19b5891d7787469d542723fc762c) refactor(android,core): use monotonic dispatch tok | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.48 |
| [83640c3cc](https://github.com/AFK-surf/monoid/commit/83640c3cc46c4a2313039a2f29cbafcf31d7f069) perf(station): join streamed frame pieces once in  | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.49 |
| [a876a5380](https://github.com/AFK-surf/monoid/commit/a876a53806f66277bd14f3637dd1806cf6a2f471) fix(safe-mode): guide unprotected moved-lock stati | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.43 |
| [87ddbc239](https://github.com/AFK-surf/monoid/commit/87ddbc2398952eaccee54590777881c4b8a84687) fix(mbui): narrow loading image breathing amplitud | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.74 |
| [50f121136](https://github.com/AFK-surf/monoid/commit/50f12113609f1b16914c1c2ea59ebe6ea2c6deed) fix(core): batch personal-signer and extraKeys int | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.53 |
| [3037efae5](https://github.com/AFK-surf/monoid/commit/3037efae5bad875e4ace8e620d6ae4c1e7b36049) fix(vault): decouple per-vault KeyAsk from BoxCert | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.89 |
| [d85d5ddf4](https://github.com/AFK-surf/monoid/commit/d85d5ddf462d064033901c44ebbc6cf026e2a993) feat(station-main): wire WholeCore into whole_daem | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.69 |
| [bf2170d8e](https://github.com/AFK-surf/monoid/commit/bf2170d8e020e0f417ec190fc135ad9c4a994857) refactor(core,mbui): replace manual auth-gen tuple | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.53 |
| [42bf07e01](https://github.com/AFK-surf/monoid/commit/42bf07e012517d7a7df70ae2e6c6b1f07d49ef4e) perf(station): reuse fresh Helper grants in macOS  | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 65.88 |
| [387a9d744](https://github.com/AFK-surf/monoid/commit/387a9d744083b417403f1ee91bae198134fd9672) fix(ui): keep adaptive glass ink dark over kind 9  | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.69 |
| [b9ab7e501](https://github.com/AFK-surf/monoid/commit/b9ab7e501a7a6cf1265567918fd51c296dd15e04) fix(mbui): explain why typed emails cannot be adde | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.71 |
| [073a8026e](https://github.com/AFK-surf/monoid/commit/073a8026e80c8c8cd2fe52b033b2e6775978588e) fix(station): prevent evicting idle agy sessions w | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.77 |
| [575cbdc10](https://github.com/AFK-surf/monoid/commit/575cbdc1071a70a38087e9e9fa5c6c45d7c08381) feat(station,core,mbui): invoke attached agent ski | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.77 |
| [29a0c3082](https://github.com/AFK-surf/monoid/commit/29a0c30829680c42407bde6dd3bea1e333122f5f) fix(mbui): require 500ms hover dwell before peekin | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.41 |
| [65946164d](https://github.com/AFK-surf/monoid/commit/65946164d5e902e5e9b0bb6c20a02c3506f518f7) fix(station): link session pages on the workspace' | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.46 |
| [0ca3ccb00](https://github.com/AFK-surf/monoid/commit/0ca3ccb00dba73acf87c7aad0b71ac6fd7ebdd6b) perf(mbui): virtualize attention panel, optimize q | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.23 |
| [136bba585](https://github.com/AFK-surf/monoid/commit/136bba5854eb3da36bd7feef8e2f5dd946d6ff0c) perf(station): rank relays by lowest measured RTT  | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.85 |
| [b29538437](https://github.com/AFK-surf/monoid/commit/b29538437809b6fc38e2627854de6b368cbed3e1) fix(station): keep heap watch failures from crashi | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.51 |
| [393e388aa](https://github.com/AFK-surf/monoid/commit/393e388aa729496674e510fa5d27634c8ad3130e) fix(ui): keep a sidebar row lit while the pointer  | 0.59 | 0.78 | 3.02 | 4.04 | 7.5 | 2.22 | 6.28 | 57.64 |
| [5c55be6c3](https://github.com/AFK-surf/monoid/commit/5c55be6c385421c96872ae6997880fe41b09e4ea) refactor(android): split FramePacer into FrameSche | 0.59 | 0.78 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.49 |
| [33c0e85b8](https://github.com/AFK-surf/monoid/commit/33c0e85b896bd85449de49c6c8c2667e2346b492) fix(ui): keep a rounded clip's corners when a cut  | 0.59 | 0.78 | 3.02 | 4.04 | 7.5 | 2.22 | 6.28 | 58.31 |
| [65c90e3d0](https://github.com/AFK-surf/monoid/commit/65c90e3d052ca3e3e269e01353a7ca4c543f5283) feat(mbui): park passive side-panel tabs via pick_ | 0.59 | 0.78 | 3.02 | 4.04 | 7.5 | 2.22 | 6.28 | 57.18 |
| [555d9fa17](https://github.com/AFK-surf/monoid/commit/555d9fa172a1c020ecf7717c42dac9607a22e1c4) fix(core,e2e): track Node CallAuth boundaries and  | 0.59 | 0.78 | 3.02 | 4.04 | 7.5 | 2.22 | 6.28 | 57.53 |
| [18522df13](https://github.com/AFK-surf/monoid/commit/18522df1332910f049465b2433e3f03f2865e22e) feat(mbui): redesign Profiles with three-tier layo | 0.59 | 0.78 | 3.02 | 4.04 | 7.5 | 2.22 | 6.28 | 57.82 |
| [cb5e6a579](https://github.com/AFK-surf/monoid/commit/cb5e6a57984860893580ac366bf1e4e4b9d11f3a) ci(mbui): key iOS unit store by compiler and SDK,  | 0.59 | 0.78 | 3.02 | 4.04 | 7.5 | 2.22 | 6.28 | 57.71 |
| [62e5252c4](https://github.com/AFK-surf/monoid/commit/62e5252c49c56c0f952eb5fabdeae3c5a4dd9c7c) feat(ui): split phone player top bar into bare tit | 0.59 | 0.78 | 3.02 | 4.04 | 7.5 | 2.22 | 6.28 | 57.44 |
| [8f6b37be3](https://github.com/AFK-surf/monoid/commit/8f6b37be3b0c02b179b5f3314b541c7391723dc2) fix(android): track Choreographer vsync generation | 0.59 | 0.77 | 3.02 | 4.04 | 7.5 | 2.22 | 6.28 | 57.56 |
| [23f501c02](https://github.com/AFK-surf/monoid/commit/23f501c02c24abddf9b9a9f2a98c2146fc7a11fd) fix(ui): fix adaptive glass ink, dark contour on b | 0.59 | 0.77 | 3.02 | 4.04 | 7.5 | 2.22 | 6.28 | 57.67 |
| [dcc7a90e0](https://github.com/AFK-surf/monoid/commit/dcc7a90e062b622c4da63040bb111b5c58428678) fix(mbui): relocate small-screen group pill above  | 0.59 | 0.77 | 3.02 | 4.04 | 7.5 | 2.22 | 6.28 | 57.75 |
| [b9c66c6cf](https://github.com/AFK-surf/monoid/commit/b9c66c6cfa60f5c89eff99f8634d960b7851e918) feat(station-whole): add production OS adapters fo | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.69 |
| [fffd1fc0d](https://github.com/AFK-surf/monoid/commit/fffd1fc0db454e753b0475479c6d730704b8e703) perf(station): track borrowed-profile liveness wit | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.57 |
| [b9ded7d55](https://github.com/AFK-surf/monoid/commit/b9ded7d55686d46f159ca675666de8ab3d37ef99) fix(mbui): keep watched topics reactive on auth sc | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.97 |
| [3548369bf](https://github.com/AFK-surf/monoid/commit/3548369bf6d69f5cd5342ee6231f105a2389ae5a) perf(cloud): cache compact changelog fixes and bat | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.46 |
| [888341385](https://github.com/AFK-surf/monoid/commit/888341385d2dd34f3489cfcd2dbaf6aa5a08c24d) fix(station): offer Copilot models GitHub lists wi | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.51 |
| [c793e8932](https://github.com/AFK-surf/monoid/commit/c793e8932be884d034b45c2b5e41747bfe94fd3d) perf(cloud): single-flight cache changelog and rel | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.56 |
| [e3218e65a](https://github.com/AFK-surf/monoid/commit/e3218e65aa16b7e28b8b6c6757e38fa5f157eef0) perf(station,core): stream incremental overview-pa | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.64 |
| [36bef9f96](https://github.com/AFK-surf/monoid/commit/36bef9f96a1e71d686c5c71fe550e82cd7ec0dfc) fix(station): end a turn that stays silent after i | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.82 |
| [0c05c70eb](https://github.com/AFK-surf/monoid/commit/0c05c70ebc24863896e6e66b029a60309712c263) feat(mbui): migrate profiles/stations places to pi | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.74 |
| [c14a4b71d](https://github.com/AFK-surf/monoid/commit/c14a4b71d0f144c24929d1021d967b1f5e1b3f05) feat(core,mbui): add authGen/vaultGen sync boundar | 0.59 | 0.77 | 3.02 | 4.05 | 7.5 | 2.22 | 6.28 | 57.74 |
