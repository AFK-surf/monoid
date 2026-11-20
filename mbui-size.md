# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [e354a8b79](https://github.com/AFK-surf/monoid/commit/e354a8b798d1d87f9eae929c2c8f2616b3fcb670) fix(station/mb): make a cold session's actor befor | 2.65 | 3.56 | 14.53 | 36.75 | 55.95 | 32.24 | 65.3 | 97.47 | 123.92 |
| [68a571407](https://github.com/AFK-surf/monoid/commit/68a571407a202c9da63c0c8429838fe30f747e55) feat(mbui): support trackpad horizontal swipe pagi | 2.65 | 3.56 | 14.53 | 36.75 | 55.95 | 32.24 | 65.3 | 97.6 | 121.49 |
| [3560e4f21](https://github.com/AFK-surf/monoid/commit/3560e4f21eb763d39258ce8e3d79637fb1b95206) feat(mbui): make the working mark a turning ring ( | 2.65 | 3.56 | 14.53 | 36.75 | 55.95 | 32.24 | 65.3 | 97.6 | 121.49 |
| [60c853356](https://github.com/AFK-surf/monoid/commit/60c85335667d39e05bf996020dc28e6fc6806ba7) feat(mbui): turn a station's CPU dial between idle | 2.65 | 3.56 | 14.53 | 36.75 | 55.95 | 32.24 | 65.3 | 97.6 | 121.49 |
| [e4cd89e1e](https://github.com/AFK-surf/monoid/commit/e4cd89e1efd309fa2bba1cda05cd717f6d84d243) fix(mbui): check node generation in inner FLIP and | 2.65 | 3.56 | 14.53 | 36.75 | 55.94 | 32.24 | 65.3 | 97.62 | 144.33 |
| [a7ea726f1](https://github.com/AFK-surf/monoid/commit/a7ea726f1a91b42aa61c1d879a3d930a9fab15b0) perf(mbui): use keyframe seeks during video scrub  | 2.65 | 3.56 | 14.53 | 36.75 | 55.94 | 32.24 | 65.3 | 97.62 | 144.33 |
| [5ce3832ae](https://github.com/AFK-surf/monoid/commit/5ce3832ae387a615ddc87ea9a22ba02efae31c82) refactor(station/mb): extract shared host_world an | 2.65 | 3.56 | 14.53 | 36.74 | 55.93 | 32.24 | 65.3 | 97.65 | 130.24 |
| [d58e89c56](https://github.com/AFK-surf/monoid/commit/d58e89c56ff720ca9fb83f8570c429794f5218ff) docs: notes for stable 0.1.10157 (#7553) | 2.65 | 3.56 | 14.53 | 36.74 | 55.93 | 32.24 | 65.3 | 97.65 | 130.24 |
| [3412edbc0](https://github.com/AFK-surf/monoid/commit/3412edbc09d5120f3eec92a9e51873969de105cb) feat(mbui): cap farthest-corner shift on View::sca | 2.65 | 3.56 | 14.52 | 36.74 | 55.93 | 32.23 | 65.28 | 97.37 | 130.24 |
| [fc16aebfe](https://github.com/AFK-surf/monoid/commit/fc16aebfe588120daf8aee436396ca5ede254b75) fix(mbui): count tree marks and open row grounds i | 2.65 | 3.56 | 14.52 | 36.74 | 55.93 | 32.23 | 65.28 | 97.5 | 122.31 |
| [97ebdfd69](https://github.com/AFK-surf/monoid/commit/97ebdfd69129f3b404a2f399be8f2ab1e125542a) feat(mbui): add swipe-back hint on wide frames and | 2.65 | 3.56 | 14.52 | 36.74 | 55.93 | 32.23 | 65.28 | 97.5 | 122.31 |
| [1889203ca](https://github.com/AFK-surf/monoid/commit/1889203caa71d297d82a02e596aababbb8a8b2f5) refactor(station/mb): replace thin helper forwarde | 2.65 | 3.56 | 14.52 | 36.74 | 55.93 | 32.23 | 65.28 | 97.5 | 122.31 |
| [9c3780fa9](https://github.com/AFK-surf/monoid/commit/9c3780fa9d6a9aed1e2010e9c870df569c4f3917) fix(mbui): a stream's sound clock counts what is h | 2.65 | 3.56 | 14.52 | 36.74 | 55.93 | 32.23 | 65.28 | 97.58 | 125.13 |
| [22affa29a](https://github.com/AFK-surf/monoid/commit/22affa29a3a9d45b90a6fec33bdaa862f8dccaa1) fix(vault): set up a second trusted device by itse | 2.65 | 3.56 | 14.52 | 36.74 | 55.93 | 32.23 | 65.28 | 97.58 | 125.13 |
| [ef2877a44](https://github.com/AFK-surf/monoid/commit/ef2877a44d016e6e7147731708fa1cbb5f325769) feat(mbui): widen reader column to 48em in chat si | 2.64 | 3.55 | 14.52 | 36.74 | 55.92 | 32.22 | 65.28 | 97.47 | 125.53 |
| [016b09ab0](https://github.com/AFK-surf/monoid/commit/016b09ab078c6e7d252b8aec08c54482ca0be870) refactor(mbui): move TipOwner to mbui/headless, dr | 2.64 | 3.55 | 14.52 | 36.74 | 55.91 | 32.22 | 65.27 | 97.39 | 119.12 |
| [8626a69df](https://github.com/AFK-surf/monoid/commit/8626a69df10482fa7d193a3eabffbabefc292c5e) fix(mbui): update profile overview share menu and  | 2.64 | 3.55 | 14.52 | 36.74 | 55.91 | 32.22 | 65.27 | 97.39 | 119.12 |
| [b208ce089](https://github.com/AFK-surf/monoid/commit/b208ce089e603e1f6d2b8d31eb5ce6150974ac8c) fix(mbui): set a list's FLIP rest before telling i | 2.64 | 3.55 | 14.52 | 36.74 | 55.91 | 32.22 | 65.27 | 97.39 | 119.12 |
| [3ea0dccaf](https://github.com/AFK-surf/monoid/commit/3ea0dccaf788da7a9571ad76cb8b14716abb9a04) fix(mbui): align model picker dividers flush as 0. | 2.64 | 3.55 | 14.52 | 36.73 | 55.9 | 32.22 | 65.25 | 97.5 | 126.33 |
| [69aa1eb7c](https://github.com/AFK-surf/monoid/commit/69aa1eb7ca3ce8077bdd74b42e3d99784c0381d3) fix(ci): retry Cloudflare's account per put try, a | 2.64 | 3.55 | 14.52 | 36.73 | 55.9 | 32.22 | 65.25 | 97.5 | 126.33 |
| [5fb64b3fb](https://github.com/AFK-surf/monoid/commit/5fb64b3fbbd4f4167795c17bcdc307e138a213df) fix(mbui): prevent blank foot_room and stale place | 2.64 | 3.55 | 14.52 | 36.73 | 55.89 | 32.21 | 65.25 | 97.63 | 117.42 |
| [0d3abc0b9](https://github.com/AFK-surf/monoid/commit/0d3abc0b93865341cbee4601628a4f265ee7f4fb) refactor(station): share the runtimes' live wire h | 2.64 | 3.55 | 14.52 | 36.73 | 55.89 | 32.21 | 65.25 | 97.63 | 117.42 |
| [4d9824f0f](https://github.com/AFK-surf/monoid/commit/4d9824f0f0bf463196c1661a0b8ae9411516f23f) feat(mbui): scroll-to-bottom key in a file tab's t | 2.64 | 3.55 | 14.52 | 36.73 | 55.89 | 32.21 | 65.25 | 97.68 | 122.56 |
| [a0f3ba38f](https://github.com/AFK-surf/monoid/commit/a0f3ba38f84d2cd799e728c69abf22ead9ecc841) refactor(station): share the builders' SQLite help | 2.64 | 3.55 | 14.52 | 36.73 | 55.89 | 32.21 | 65.25 | 97.68 | 122.56 |
| [a1159d02f](https://github.com/AFK-surf/monoid/commit/a1159d02fe8a0d89eb6b1cea188d9181b9643eee) refactor(station): type cross-slice asks as LiveBu | 2.64 | 3.55 | 14.52 | 36.73 | 55.89 | 32.21 | 65.25 | 97.54 | 125.05 |
| [a0d09c1b9](https://github.com/AFK-surf/monoid/commit/a0d09c1b9c81b30482ccce2321403095672b0988) fix(mbui): let go of an old view's focus while its | 2.64 | 3.55 | 14.52 | 36.73 | 55.89 | 32.22 | 65.25 | 97.67 | 117.03 |
| [d88c8b63f](https://github.com/AFK-surf/monoid/commit/d88c8b63f7f61c50c79526f6a17b33b8cfd869a0) refactor(station-mb): deduplicate shared JS/JSON a | 2.64 | 3.55 | 14.51 | 36.73 | 55.89 | 32.22 | 65.25 | 97.67 | 119.2 |
| [0dd687991](https://github.com/AFK-surf/monoid/commit/0dd68799112a53d8e8a1660e1ed4b6e16ca6717a) refactor(mbui): move Zoom to mbui/motion and Media | 2.64 | 3.55 | 14.51 | 36.73 | 55.89 | 32.22 | 65.25 | 97.34 | 119.5 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
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
| [e354a8b79](https://github.com/AFK-surf/monoid/commit/e354a8b798d1d87f9eae929c2c8f2616b3fcb670) fix(station/mb): make a cold session's actor befor | 0.45 | 0.59 | 2.27 | 3.35 | 5.45 | 1.67 | 4.48 | 54.45 |
| [68a571407](https://github.com/AFK-surf/monoid/commit/68a571407a202c9da63c0c8429838fe30f747e55) feat(mbui): support trackpad horizontal swipe pagi | 0.45 | 0.59 | 2.27 | 3.35 | 5.45 | 1.67 | 4.48 | 54.45 |
| [3560e4f21](https://github.com/AFK-surf/monoid/commit/3560e4f21eb763d39258ce8e3d79637fb1b95206) feat(mbui): make the working mark a turning ring ( | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.12 |
| [60c853356](https://github.com/AFK-surf/monoid/commit/60c85335667d39e05bf996020dc28e6fc6806ba7) feat(mbui): turn a station's CPU dial between idle | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.05 |
| [e4cd89e1e](https://github.com/AFK-surf/monoid/commit/e4cd89e1efd309fa2bba1cda05cd717f6d84d243) fix(mbui): check node generation in inner FLIP and | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.05 |
| [a7ea726f1](https://github.com/AFK-surf/monoid/commit/a7ea726f1a91b42aa61c1d879a3d930a9fab15b0) perf(mbui): use keyframe seeks during video scrub  | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.13 |
| [5ce3832ae](https://github.com/AFK-surf/monoid/commit/5ce3832ae387a615ddc87ea9a22ba02efae31c82) refactor(station/mb): extract shared host_world an | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.13 |
| [d58e89c56](https://github.com/AFK-surf/monoid/commit/d58e89c56ff720ca9fb83f8570c429794f5218ff) docs: notes for stable 0.1.10157 (#7553) | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.1 |
| [3412edbc0](https://github.com/AFK-surf/monoid/commit/3412edbc09d5120f3eec92a9e51873969de105cb) feat(mbui): cap farthest-corner shift on View::sca | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.1 |
| [fc16aebfe](https://github.com/AFK-surf/monoid/commit/fc16aebfe588120daf8aee436396ca5ede254b75) fix(mbui): count tree marks and open row grounds i | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.1 |
| [97ebdfd69](https://github.com/AFK-surf/monoid/commit/97ebdfd69129f3b404a2f399be8f2ab1e125542a) feat(mbui): add swipe-back hint on wide frames and | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.02 |
| [1889203ca](https://github.com/AFK-surf/monoid/commit/1889203caa71d297d82a02e596aababbb8a8b2f5) refactor(station/mb): replace thin helper forwarde | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.12 |
| [9c3780fa9](https://github.com/AFK-surf/monoid/commit/9c3780fa9d6a9aed1e2010e9c870df569c4f3917) fix(mbui): a stream's sound clock counts what is h | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.12 |
| [22affa29a](https://github.com/AFK-surf/monoid/commit/22affa29a3a9d45b90a6fec33bdaa862f8dccaa1) fix(vault): set up a second trusted device by itse | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.28 |
| [ef2877a44](https://github.com/AFK-surf/monoid/commit/ef2877a44d016e6e7147731708fa1cbb5f325769) feat(mbui): widen reader column to 48em in chat si | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.28 |
| [016b09ab0](https://github.com/AFK-surf/monoid/commit/016b09ab078c6e7d252b8aec08c54482ca0be870) refactor(mbui): move TipOwner to mbui/headless, dr | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.28 |
| [8626a69df](https://github.com/AFK-surf/monoid/commit/8626a69df10482fa7d193a3eabffbabefc292c5e) fix(mbui): update profile overview share menu and  | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.26 |
| [b208ce089](https://github.com/AFK-surf/monoid/commit/b208ce089e603e1f6d2b8d31eb5ce6150974ac8c) fix(mbui): set a list's FLIP rest before telling i | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.08 |
| [3ea0dccaf](https://github.com/AFK-surf/monoid/commit/3ea0dccaf788da7a9571ad76cb8b14716abb9a04) fix(mbui): align model picker dividers flush as 0. | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.08 |
| [69aa1eb7c](https://github.com/AFK-surf/monoid/commit/69aa1eb7ca3ce8077bdd74b42e3d99784c0381d3) fix(ci): retry Cloudflare's account per put try, a | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.12 |
| [5fb64b3fb](https://github.com/AFK-surf/monoid/commit/5fb64b3fbbd4f4167795c17bcdc307e138a213df) fix(mbui): prevent blank foot_room and stale place | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.12 |
| [0d3abc0b9](https://github.com/AFK-surf/monoid/commit/0d3abc0b93865341cbee4601628a4f265ee7f4fb) refactor(station): share the runtimes' live wire h | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.26 |
| [4d9824f0f](https://github.com/AFK-surf/monoid/commit/4d9824f0f0bf463196c1661a0b8ae9411516f23f) feat(mbui): scroll-to-bottom key in a file tab's t | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 54.26 |
| [a0f3ba38f](https://github.com/AFK-surf/monoid/commit/a0f3ba38f84d2cd799e728c69abf22ead9ecc841) refactor(station): share the builders' SQLite help | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 53.89 |
| [a1159d02f](https://github.com/AFK-surf/monoid/commit/a1159d02fe8a0d89eb6b1cea188d9181b9643eee) refactor(station): type cross-slice asks as LiveBu | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 53.89 |
| [a0d09c1b9](https://github.com/AFK-surf/monoid/commit/a0d09c1b9c81b30482ccce2321403095672b0988) fix(mbui): let go of an old view's focus while its | 0.45 | 0.59 | 2.27 | 3.35 | 5.44 | 1.66 | 4.48 | 53.89 |
| [d88c8b63f](https://github.com/AFK-surf/monoid/commit/d88c8b63f7f61c50c79526f6a17b33b8cfd869a0) refactor(station-mb): deduplicate shared JS/JSON a | 0.45 | 0.59 | 2.27 | 3.35 | 5.43 | 1.66 | 4.46 | 53.68 |
| [0dd687991](https://github.com/AFK-surf/monoid/commit/0dd68799112a53d8e8a1660e1ed4b6e16ca6717a) refactor(mbui): move Zoom to mbui/motion and Media | 0.45 | 0.59 | 2.27 | 3.35 | 5.43 | 1.66 | 4.46 | 53.68 |
