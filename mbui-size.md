# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [05375acb0](https://github.com/AFK-surf/monoid/commit/05375acb03249cb8382a85621092229115e9dc13) perf(ui): cache iOS nav bar work and offload Apple | 2.6 | 3.52 | 14.56 | 37.37 | 56.91 | 32.64 | 66.38 | 101.01 | 127.38 |
| [f5bbb1cbf](https://github.com/AFK-surf/monoid/commit/f5bbb1cbf3a631e065cc3351ce0e0e4b6e0117d3) fix(station): read Antigravity quota through its C | 2.6 | 3.52 | 14.56 | 37.37 | 56.91 | 32.64 | 66.38 | 101.01 | 127.38 |
| [d1ae551bf](https://github.com/AFK-surf/monoid/commit/d1ae551bf9b3ab6856ec3dd5e447070aeb16ab62) fix(vault): clear pending requests on archive and  | 2.6 | 3.52 | 14.56 | 37.37 | 56.91 | 32.64 | 66.38 | 101.01 | 127.38 |
| [b69602eb8](https://github.com/AFK-surf/monoid/commit/b69602eb8f5ca6d948645eb0ccc661304326164a) fix(ui): fade every scroll box's cut ends and let  | 2.6 | 3.52 | 14.56 | 37.37 | 56.91 | 32.64 | 66.38 | 101.01 | 126.83 |
| [c07feb817](https://github.com/AFK-surf/monoid/commit/c07feb817fe57b4411b30634308ab987132005ab) fix(vault): stop personal vault splits and recover | 2.6 | 3.51 | 14.52 | 37.3 | 56.77 | 32.64 | 66.38 | 101.01 | 129.86 |
| [b9807d601](https://github.com/AFK-surf/monoid/commit/b9807d601048154932ca8681f1fa12269700ea15) fix(station): add hysteresis to overview free-disk | 2.6 | 3.51 | 14.52 | 37.3 | 56.77 | 32.64 | 66.38 | 101.01 | 118.58 |
| [b669e7119](https://github.com/AFK-surf/monoid/commit/b669e71191cbcad377e95aab41d7ccf7ac0f2ffd) fix(core-ts): cancel superseded dialAll rounds and | 2.6 | 3.51 | 14.52 | 37.3 | 56.77 | 32.64 | 66.38 | 101.01 | 118.58 |
| [0eedcfbac](https://github.com/AFK-surf/monoid/commit/0eedcfbaccf273bc1c9120f220f89961230a5b07) fix(moonbit): migrate to moon 0.1.20261126 APIs an | 2.6 | 3.51 | 14.52 | 37.3 | 56.77 | 32.64 | 66.38 | 101.01 | 118.58 |
| [2f97fb164](https://github.com/AFK-surf/monoid/commit/2f97fb1646244338b2e2e3edef61046c8c02d33a) fix(vault): allow unseen workspace members in non- | 2.59 | 3.51 | 14.52 | 37.29 | 56.75 | 32.64 | 66.38 | 101.01 | 128.51 |
| [8025986e3](https://github.com/AFK-surf/monoid/commit/8025986e3bf4f3a50f5c0bb9a992d54bfdd57cab) fix(mbui): give a full-width chat list's end colum | 2.59 | 3.51 | 14.52 | 37.29 | 56.75 | 32.64 | 66.38 | 101.01 | 128.51 |
| [f2b7529ee](https://github.com/AFK-surf/monoid/commit/f2b7529ee1c3e06d92529a1f506e91dc178ec5b6) fix(mbui): open another workspace's chat link over | 2.6 | 3.51 | 14.52 | 37.29 | 56.75 | 32.64 | 66.38 | 101.01 | 128.51 |
| [f408a3330](https://github.com/AFK-surf/monoid/commit/f408a3330ce9a9867a13f514ca79f72c7cfbb12c) feat(ui): upgrade Liquid Glass to 4-tap wide exter | 2.59 | 3.51 | 14.51 | 37.29 | 56.75 | 32.64 | 66.38 | 101.42 | 128.51 |
| [bc5c430d4](https://github.com/AFK-surf/monoid/commit/bc5c430d4d4e89b9fb101c024ea599343e6138ab) fix(mbui): center a side row's agents on its secon | 2.59 | 3.51 | 14.51 | 37.29 | 56.75 | 32.64 | 66.38 | 101.11 | 128.51 |
| [934c7bd73](https://github.com/AFK-surf/monoid/commit/934c7bd73be0b78743309db44c611cfc94157e65) feat(station): inject the session's person memory  | 2.59 | 3.51 | 14.51 | 37.29 | 56.75 | 32.64 | 66.38 | 101.11 | 128.51 |
| [89f1ea9de](https://github.com/AFK-surf/monoid/commit/89f1ea9de1bb6ac946ebbdef59a546e6780c1cce) fix(station,core): resolve slack:<connect>:<user>  | 2.59 | 3.51 | 14.51 | 37.29 | 56.75 | 32.64 | 66.38 | 101.11 | 128.51 |
| [845df874a](https://github.com/AFK-surf/monoid/commit/845df874a9c263b5775d0d0c87e0972906119bb8) fix(ui): size menu levels smoothly and open short  | 2.59 | 3.51 | 14.51 | 37.29 | 56.75 | 32.64 | 66.38 | 100.94 | 114.85 |
| [bc2a70966](https://github.com/AFK-surf/monoid/commit/bc2a70966092c363edd6313b2998242f7b098854) fix(ui): keep progressive scroll-edge blur inside  | 2.59 | 3.5 | 14.5 | 37.28 | 56.69 | 32.63 | 66.31 | 101.19 | 130.38 |
| [6d3adce4b](https://github.com/AFK-surf/monoid/commit/6d3adce4bffbf38b17f3d969316a52f90da5cba5) fix(i18n): say 指定后 in the locked project hint (#88 | 2.59 | 3.5 | 14.5 | 37.28 | 56.69 | 32.63 | 66.31 | 100.93 | 133.01 |
| [06d4c58b3](https://github.com/AFK-surf/monoid/commit/06d4c58b326228fcd7dc8609ec06a18b9b4a4aea) fix(cloud): keep what joining named to pin in memo | 2.59 | 3.5 | 14.5 | 37.28 | 56.68 | 32.63 | 66.31 | 101.19 | 114.01 |
| [7bd1fdd49](https://github.com/AFK-surf/monoid/commit/7bd1fdd4979613dce582a69d08a1f326899add22) fix(core): put unclassified first and keep project | 2.59 | 3.5 | 14.5 | 37.28 | 56.68 | 32.63 | 66.31 | 101.19 | 114.01 |
| [f50baae5c](https://github.com/AFK-surf/monoid/commit/f50baae5ce189b74980748a82a945f298bb77d27) fix(app): let a collapsed group's kept open chat g | 2.59 | 3.5 | 14.5 | 37.28 | 56.67 | 32.63 | 66.29 | 100.68 | 122.26 |
| [e843722c5](https://github.com/AFK-surf/monoid/commit/e843722c5ed5c8c27ca05314759b0e0c4f7e3f54) feat(logins): switch a loopback login to its code- | 2.59 | 3.5 | 14.5 | 37.28 | 56.67 | 32.63 | 66.29 | 100.68 | 122.26 |
| [279e124e8](https://github.com/AFK-surf/monoid/commit/279e124e8acbca450e7f85da4c5384b6744c6416) fix(mbui): say why a login card is empty when its  | 2.59 | 3.5 | 14.5 | 37.28 | 56.67 | 32.63 | 66.29 | 100.68 | 122.26 |
| [697c4cf8d](https://github.com/AFK-surf/monoid/commit/697c4cf8df4f75a0c43c1486e517790164d511e8) fix(core): show a chat's current project in its he | 2.59 | 3.5 | 14.5 | 37.28 | 56.67 | 32.63 | 66.29 | 100.68 | 99.29 |
| [2f5db8da0](https://github.com/AFK-surf/monoid/commit/2f5db8da078ed8543886d8da8f879d42de393220) fix(mbui): adapt chat bar project and tag ink to t | 2.59 | 3.5 | 14.5 | 37.28 | 56.67 | 32.63 | 66.29 | 101.07 | 128.3 |
| [22f03068f](https://github.com/AFK-surf/monoid/commit/22f03068f81b245a34bcb0c1790e4564fca6c52e) feat(station): default beta darwin-arm64 and linux | 2.59 | 3.5 | 14.5 | 37.28 | 56.67 | 32.63 | 66.29 | 101.07 | 128.3 |
| [e4e4b98cf](https://github.com/AFK-surf/monoid/commit/e4e4b98cf5ef277c6c6a2e0b141fb935a0ac92af) feat(station): add four-layer memory routing, stat | 2.59 | 3.5 | 14.5 | 37.28 | 56.67 | 32.63 | 66.29 | 100.99 | 114.63 |
| [e651c3974](https://github.com/AFK-surf/monoid/commit/e651c39749e1e7b1670323816d628d1e2a02194f) fix(screen): scale with pixel shaders when the GPU | 2.59 | 3.5 | 14.5 | 37.28 | 56.66 | 32.63 | 66.28 | 101.16 | 133.58 |
| [bd2012fe8](https://github.com/AFK-surf/monoid/commit/bd2012fe8fd018a6de405bf3b43e513b047bb505) fix(projects): unify unclassified, keep active/pin | 2.59 | 3.5 | 14.5 | 37.28 | 56.66 | 32.63 | 66.28 | 101.16 | 133.58 |
| [78711bdf0](https://github.com/AFK-surf/monoid/commit/78711bdf03fb0a562359873e556f8250c164f72d) fix(ui): turn Shift+wheel sideways on Windows (#87 | 2.59 | 3.5 | 14.5 | 37.26 | 56.66 | 32.63 | 66.28 | 101.17 | 120.2 |
| [ee875d7d4](https://github.com/AFK-surf/monoid/commit/ee875d7d4e262674de34d9c7801c42bef2da5681) feat(ui): add iOS 27.0 external environmental edge | 2.59 | 3.5 | 14.5 | 37.26 | 56.66 | 32.63 | 66.28 | 101.17 | 120.2 |
| [bd2012fe8](https://github.com/AFK-surf/monoid/commit/bd2012fe8fd018a6de405bf3b43e513b047bb505) fix(projects): unify unclassified, keep active/pin | 2.59 | 3.5 | 14.5 | 37.26 | 56.66 | 32.63 | 66.28 | 101.17 | 120.2 |
| [a64c7ab50](https://github.com/AFK-surf/monoid/commit/a64c7ab5091689f31b0d004b5adbc80ac85d2e36) perf(ui,core,shell): verify kept fonts off UI thre | 2.59 | 3.5 | 14.5 | 37.26 | 56.66 | 32.62 | 66.28 | 101.27 | 120.2 |
| [b54ef725e](https://github.com/AFK-surf/monoid/commit/b54ef725e5da47b4d2ce6a4dabf9d4cdb5186b92) feat(screen): separate stream resolution, bitrate, | 2.59 | 3.5 | 14.5 | 37.26 | 56.66 | 32.61 | 66.26 | 100.93 | 120.2 |
| [df558d46f](https://github.com/AFK-surf/monoid/commit/df558d46f7883ab02755932d033f8795c73ab3d5) fix(station): hold self-update while a login is un | 2.59 | 3.5 | 14.48 | 37.25 | 56.62 | 32.59 | 66.24 | 100.88 | 122.79 |
| [5e09001df](https://github.com/AFK-surf/monoid/commit/5e09001dfe5b86fe509687120f33a2d0c7325a75) perf(station): read every profile's allowance hour | 2.59 | 3.5 | 14.48 | 37.25 | 56.62 | 32.59 | 66.24 | 100.88 | 122.79 |
| [db07237c5](https://github.com/AFK-surf/monoid/commit/db07237c5ac95f844a7deb042638380bed2341b6) fix(shell): release an endpoint's sockets before i | 2.59 | 3.5 | 14.48 | 37.25 | 56.62 | 32.59 | 66.24 | 101.12 | 133.97 |
| [f7b33699e](https://github.com/AFK-surf/monoid/commit/f7b33699ebf908c8e198e1fd78a69fd7ead5e7a7) fix(station): block provider-restricted accounts a | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.71 | 124.98 |
| [6117ad142](https://github.com/AFK-surf/monoid/commit/6117ad1421cdbbf5cdd6934da456edf4d5303cc2) fix(station): read a rig's grants again once the p | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.71 | 124.98 |
| [91cfd340e](https://github.com/AFK-surf/monoid/commit/91cfd340e3034afd42e4da201257c1e93e8c114e) fix(station): omit commentless auto-quotes when ou | 2.59 | 3.5 | 14.48 | 37.12 | 56.62 | 32.43 | 65.85 | 100.71 | 124.98 |

## Minimal framework baseline (`libs/ui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [05375acb0](https://github.com/AFK-surf/monoid/commit/05375acb03249cb8382a85621092229115e9dc13) perf(ui): cache iOS nav bar work and offload Apple | 0.57 | 0.74 | 2.89 | 3.95 | 7.23 | 2.15 | 6.06 | 57.54 |
| [f5bbb1cbf](https://github.com/AFK-surf/monoid/commit/f5bbb1cbf3a631e065cc3351ce0e0e4b6e0117d3) fix(station): read Antigravity quota through its C | 0.57 | 0.74 | 2.89 | 3.95 | 7.23 | 2.15 | 6.06 | 57.36 |
| [d1ae551bf](https://github.com/AFK-surf/monoid/commit/d1ae551bf9b3ab6856ec3dd5e447070aeb16ab62) fix(vault): clear pending requests on archive and  | 0.57 | 0.74 | 2.89 | 3.95 | 7.23 | 2.15 | 6.06 | 57.77 |
| [b69602eb8](https://github.com/AFK-surf/monoid/commit/b69602eb8f5ca6d948645eb0ccc661304326164a) fix(ui): fade every scroll box's cut ends and let  | 0.57 | 0.74 | 2.89 | 3.95 | 7.23 | 2.15 | 6.06 | 57.43 |
| [c07feb817](https://github.com/AFK-surf/monoid/commit/c07feb817fe57b4411b30634308ab987132005ab) fix(vault): stop personal vault splits and recover | 0.57 | 0.74 | 2.88 | 3.93 | 7.21 | 2.14 | 6.04 | 57.51 |
| [b9807d601](https://github.com/AFK-surf/monoid/commit/b9807d601048154932ca8681f1fa12269700ea15) fix(station): add hysteresis to overview free-disk | 0.57 | 0.74 | 2.88 | 3.93 | 7.21 | 2.14 | 6.04 | 57.23 |
| [b669e7119](https://github.com/AFK-surf/monoid/commit/b669e71191cbcad377e95aab41d7ccf7ac0f2ffd) fix(core-ts): cancel superseded dialAll rounds and | 0.57 | 0.74 | 2.88 | 3.93 | 7.21 | 2.14 | 6.04 | 57.28 |
| [0eedcfbac](https://github.com/AFK-surf/monoid/commit/0eedcfbaccf273bc1c9120f220f89961230a5b07) fix(moonbit): migrate to moon 0.1.20261126 APIs an | 0.57 | 0.74 | 2.88 | 3.93 | 7.21 | 2.14 | 6.04 | 57.46 |
| [2f97fb164](https://github.com/AFK-surf/monoid/commit/2f97fb1646244338b2e2e3edef61046c8c02d33a) fix(vault): allow unseen workspace members in non- | 0.57 | 0.74 | 2.88 | 3.93 | 7.21 | 2.14 | 6.04 | 57.59 |
| [8025986e3](https://github.com/AFK-surf/monoid/commit/8025986e3bf4f3a50f5c0bb9a992d54bfdd57cab) fix(mbui): give a full-width chat list's end colum | 0.57 | 0.74 | 2.88 | 3.93 | 7.2 | 2.14 | 6.04 | 57.21 |
| [f2b7529ee](https://github.com/AFK-surf/monoid/commit/f2b7529ee1c3e06d92529a1f506e91dc178ec5b6) fix(mbui): open another workspace's chat link over | 0.57 | 0.74 | 2.88 | 3.93 | 7.2 | 2.14 | 6.04 | 57.21 |
| [f408a3330](https://github.com/AFK-surf/monoid/commit/f408a3330ce9a9867a13f514ca79f72c7cfbb12c) feat(ui): upgrade Liquid Glass to 4-tap wide exter | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.67 |
| [bc5c430d4](https://github.com/AFK-surf/monoid/commit/bc5c430d4d4e89b9fb101c024ea599343e6138ab) fix(mbui): center a side row's agents on its secon | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.33 |
| [934c7bd73](https://github.com/AFK-surf/monoid/commit/934c7bd73be0b78743309db44c611cfc94157e65) feat(station): inject the session's person memory  | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.33 |
| [89f1ea9de](https://github.com/AFK-surf/monoid/commit/89f1ea9de1bb6ac946ebbdef59a546e6780c1cce) fix(station,core): resolve slack:<connect>:<user>  | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.43 |
| [845df874a](https://github.com/AFK-surf/monoid/commit/845df874a9c263b5775d0d0c87e0972906119bb8) fix(ui): size menu levels smoothly and open short  | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.57 |
| [bc2a70966](https://github.com/AFK-surf/monoid/commit/bc2a70966092c363edd6313b2998242f7b098854) fix(ui): keep progressive scroll-edge blur inside  | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.35 |
| [6d3adce4b](https://github.com/AFK-surf/monoid/commit/6d3adce4bffbf38b17f3d969316a52f90da5cba5) fix(i18n): say 指定后 in the locked project hint (#88 | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.57 |
| [06d4c58b3](https://github.com/AFK-surf/monoid/commit/06d4c58b326228fcd7dc8609ec06a18b9b4a4aea) fix(cloud): keep what joining named to pin in memo | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.44 |
| [7bd1fdd49](https://github.com/AFK-surf/monoid/commit/7bd1fdd4979613dce582a69d08a1f326899add22) fix(core): put unclassified first and keep project | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.3 |
| [f50baae5c](https://github.com/AFK-surf/monoid/commit/f50baae5ce189b74980748a82a945f298bb77d27) fix(app): let a collapsed group's kept open chat g | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.61 |
| [e843722c5](https://github.com/AFK-surf/monoid/commit/e843722c5ed5c8c27ca05314759b0e0c4f7e3f54) feat(logins): switch a loopback login to its code- | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.35 |
| [279e124e8](https://github.com/AFK-surf/monoid/commit/279e124e8acbca450e7f85da4c5384b6744c6416) fix(mbui): say why a login card is empty when its  | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.69 |
| [697c4cf8d](https://github.com/AFK-surf/monoid/commit/697c4cf8df4f75a0c43c1486e517790164d511e8) fix(core): show a chat's current project in its he | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.49 |
| [2f5db8da0](https://github.com/AFK-surf/monoid/commit/2f5db8da078ed8543886d8da8f879d42de393220) fix(mbui): adapt chat bar project and tag ink to t | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.54 |
| [22f03068f](https://github.com/AFK-surf/monoid/commit/22f03068f81b245a34bcb0c1790e4564fca6c52e) feat(station): default beta darwin-arm64 and linux | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.9 |
| [e4e4b98cf](https://github.com/AFK-surf/monoid/commit/e4e4b98cf5ef277c6c6a2e0b141fb935a0ac92af) feat(station): add four-layer memory routing, stat | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.64 |
| [e651c3974](https://github.com/AFK-surf/monoid/commit/e651c39749e1e7b1670323816d628d1e2a02194f) fix(screen): scale with pixel shaders when the GPU | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.48 |
| [bd2012fe8](https://github.com/AFK-surf/monoid/commit/bd2012fe8fd018a6de405bf3b43e513b047bb505) fix(projects): unify unclassified, keep active/pin | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.35 |
| [78711bdf0](https://github.com/AFK-surf/monoid/commit/78711bdf03fb0a562359873e556f8250c164f72d) fix(ui): turn Shift+wheel sideways on Windows (#87 | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.35 |
| [ee875d7d4](https://github.com/AFK-surf/monoid/commit/ee875d7d4e262674de34d9c7801c42bef2da5681) feat(ui): add iOS 27.0 external environmental edge | 0.57 | 0.74 | 2.87 | 3.93 | 7.2 | 2.14 | 6.04 | 57.61 |
| [bd2012fe8](https://github.com/AFK-surf/monoid/commit/bd2012fe8fd018a6de405bf3b43e513b047bb505) fix(projects): unify unclassified, keep active/pin | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.33 |
| [a64c7ab50](https://github.com/AFK-surf/monoid/commit/a64c7ab5091689f31b0d004b5adbc80ac85d2e36) perf(ui,core,shell): verify kept fonts off UI thre | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.54 |
| [b54ef725e](https://github.com/AFK-surf/monoid/commit/b54ef725e5da47b4d2ce6a4dabf9d4cdb5186b92) feat(screen): separate stream resolution, bitrate, | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.25 |
| [df558d46f](https://github.com/AFK-surf/monoid/commit/df558d46f7883ab02755932d033f8795c73ab3d5) fix(station): hold self-update while a login is un | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.33 |
| [5e09001df](https://github.com/AFK-surf/monoid/commit/5e09001dfe5b86fe509687120f33a2d0c7325a75) perf(station): read every profile's allowance hour | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.05 |
| [db07237c5](https://github.com/AFK-surf/monoid/commit/db07237c5ac95f844a7deb042638380bed2341b6) fix(shell): release an endpoint's sockets before i | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.23 |
| [f7b33699e](https://github.com/AFK-surf/monoid/commit/f7b33699ebf908c8e198e1fd78a69fd7ead5e7a7) fix(station): block provider-restricted accounts a | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.44 |
| [6117ad142](https://github.com/AFK-surf/monoid/commit/6117ad1421cdbbf5cdd6934da456edf4d5303cc2) fix(station): read a rig's grants again once the p | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.38 |
| [91cfd340e](https://github.com/AFK-surf/monoid/commit/91cfd340e3034afd42e4da201257c1e93e8c114e) fix(station): omit commentless auto-quotes when ou | 0.57 | 0.74 | 2.87 | 3.93 | 7.19 | 2.14 | 6.03 | 57.44 |
