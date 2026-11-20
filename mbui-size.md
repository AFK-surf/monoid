# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [610441335](https://github.com/AFK-surf/monoid/commit/6104413355243786b5356bfd298a9ebc22fdf21b) fix(rules): defer the hash seed under moonc 0.10.2 | 2.73 | 3.69 | 14.99 | 37.01 | 56.89 | 32.45 | 66.01 | 98.04 | 119.52 |
| [ea8f4a0a7](https://github.com/AFK-surf/monoid/commit/ea8f4a0a7494995a59eb623b612694fb65970beb) fix(station): keep an account's verification link  | 2.73 | 3.69 | 14.99 | 37.01 | 56.89 | 32.45 | 66.01 | 97.9 | 125.81 |
| [b73fb6698](https://github.com/AFK-surf/monoid/commit/b73fb6698d4db710a8e7d9f39eccca3e829cac11) mbui(mac): rebind display links across sleep and s | 2.73 | 3.68 | 14.99 | 37.01 | 56.88 | 32.44 | 66.01 | 98.14 | 122.74 |
| [c5d0a2f8c](https://github.com/AFK-surf/monoid/commit/c5d0a2f8c304a233012f7b2262f841b5b51a4cbf) fix(win,core): fall back to DPAPI when Windows Hel | 2.73 | 3.69 | 14.99 | 37.09 | 56.87 | 32.52 | 66.11 | 97.62 | 120.88 |
| [4bb241178](https://github.com/AFK-surf/monoid/commit/4bb2411780548bc311cab4b69d670a1c210dddbe) feat(core): dual-track bulk routing and direct spe | 2.73 | 3.69 | 14.99 | 37.09 | 56.87 | 32.52 | 66.11 | 97.62 | 120.88 |
| [a30a38f5c](https://github.com/AFK-surf/monoid/commit/a30a38f5cd10ade0374c79759bf730b5a3bcd1c9) fix(station): atomic OAuth lock mkdir/utimes and f | 2.73 | 3.68 | 14.98 | 37.08 | 56.87 | 32.51 | 66.11 | 97.76 | 121.56 |
| [923377ccc](https://github.com/AFK-surf/monoid/commit/923377ccc4e457a8803a3c5a139d47295cc1a3c4) feat(motion,sf-ui): add universal motion primitive | 2.73 | 3.68 | 14.98 | 37.08 | 56.87 | 32.51 | 66.08 | 97.78 | 124.33 |
| [e0865e126](https://github.com/AFK-surf/monoid/commit/e0865e1261a17c9c095f26fe45e38e61dc3168fc) fix(sf-ui): keep pill button words inside the pill | 2.73 | 3.68 | 14.98 | 37.08 | 56.87 | 32.51 | 66.08 | 97.78 | 124.33 |
| [ca6d4f62c](https://github.com/AFK-surf/monoid/commit/ca6d4f62ce14b2fa80e85f87fe7df78cda108a2e) fix(station/mb): use monotonic waits and non-block | 2.73 | 3.68 | 14.98 | 37.07 | 56.85 | 32.51 | 66.08 | 97.78 | 127.22 |
| [9bffa471f](https://github.com/AFK-surf/monoid/commit/9bffa471f13206335e726b774f8d0bb5b7504e10) fix(station/mb): restore Slack Socket Mode WebSock | 2.73 | 3.68 | 14.98 | 37.07 | 56.85 | 32.5 | 66.06 | 97.73 | 121.51 |
| [e7b99f518](https://github.com/AFK-surf/monoid/commit/e7b99f5185b11db29a0c92c4e1feee06b39f9fdb) fix(mbui): judge reused blocks and over boxes apar | 2.73 | 3.68 | 14.98 | 37.07 | 56.85 | 32.5 | 66.06 | 97.73 | 121.51 |
| [1632007e3](https://github.com/AFK-surf/monoid/commit/1632007e36d2f29d608f794a9fdce94f2c0eeafd) refactor(motion): clean up 6 wild motions and comp | 2.73 | 3.68 | 14.98 | 37.07 | 56.85 | 32.5 | 66.06 | 97.73 | 121.51 |
| [97a3958fc](https://github.com/AFK-surf/monoid/commit/97a3958fcd2df0dfe772abe5a37a8e785ac51437) feat(mbui): add hover outline panel and polish cha | 2.73 | 3.68 | 14.97 | 37.07 | 56.84 | 32.5 | 66.06 | 97.73 | 120.43 |
| [011fb0afe](https://github.com/AFK-surf/monoid/commit/011fb0afe0e00dcad84e625cfaa5733d9fbb421b) fix(mbui): add View soft_min last_resort, structur | 2.73 | 3.67 | 14.96 | 37.03 | 56.78 | 32.47 | 66.01 | 97.65 | 120.43 |
| [eee9913c2](https://github.com/AFK-surf/monoid/commit/eee9913c2d79fc3b965b35125e6516f16be3a658) fix(mbui): keep word navigation in web text fields | 2.73 | 3.67 | 14.96 | 37.03 | 56.78 | 32.47 | 66.01 | 97.65 | 120.43 |
| [61794c1c3](https://github.com/AFK-surf/monoid/commit/61794c1c31c73d49c066919f1541bc57f17ca449) fix(mbui): let the files sidebar scroll to its las | 2.73 | 3.67 | 14.96 | 37.03 | 56.78 | 32.47 | 66.01 | 97.65 | 120.43 |
| [138e670f3](https://github.com/AFK-surf/monoid/commit/138e670f329b9bdd620c42508aaea7de33abef6d) fix(mbui): tell the tree where shared flights end  | 2.72 | 3.68 | 14.96 | 37.03 | 56.78 | 32.47 | 66.01 | 97.76 | 129.28 |
| [2adad9846](https://github.com/AFK-surf/monoid/commit/2adad9846baca71106ab7cf270a6b456ddf62205) fix(station): serialize move state writes and retr | 2.72 | 3.68 | 14.96 | 37.03 | 56.78 | 32.47 | 66.01 | 97.76 | 129.28 |
| [6f789f91a](https://github.com/AFK-surf/monoid/commit/6f789f91a29c080057372ef3e33bfe8472aa44e6) fix(ci): recover ci-1 checkouts and leave time for | 2.72 | 3.68 | 14.96 | 37.03 | 56.78 | 32.47 | 66.01 | 97.73 | 125.49 |
| [f3954d252](https://github.com/AFK-surf/monoid/commit/f3954d252b7ce305e6b240511974909a93b0a056) perf(mbui): park covered made nav pages at rest wh | 2.72 | 3.68 | 14.96 | 36.94 | 56.33 | 32.47 | 66.01 | 97.76 | 123.51 |
| [d74c5683d](https://github.com/AFK-surf/monoid/commit/d74c5683d0dfc7bfcde8b5951a04851b3b71de75) fix(web): enroll a console's machine as the accoun | 2.72 | 3.67 | 14.85 | 36.94 | 56.33 | 32.41 | 65.73 | 97.8 | 123.51 |
| [5edb9ef7f](https://github.com/AFK-surf/monoid/commit/5edb9ef7f092ae40dd05a125bc2db5e28aab565e) refactor(motion): converge motion tools, sf-ui len | 2.72 | 3.67 | 14.85 | 36.94 | 56.33 | 32.41 | 65.73 | 97.72 | 123.51 |
| [5b1432464](https://github.com/AFK-surf/monoid/commit/5b14324647220c24364ead4c8262f3fe912af973) fix(station): hash all MoonBit headers for the inc | 2.72 | 3.67 | 14.85 | 36.94 | 56.33 | 32.41 | 65.73 | 97.88 | 123.51 |
| [ed4d2a9a8](https://github.com/AFK-surf/monoid/commit/ed4d2a9a88be25f0b0deeb57131ee3788f5c1370) fix(scripts): load libz at run time where zlib.h i | 2.72 | 3.67 | 14.85 | 36.94 | 56.33 | 32.41 | 65.73 | 97.88 | 123.51 |
| [a36908324](https://github.com/AFK-surf/monoid/commit/a36908324aef46321019fdda2528355aae1f9643) fix(ci): restore TestFlight's iOS caches by previe | 2.72 | 3.67 | 14.85 | 36.94 | 56.33 | 32.41 | 65.73 | 97.76 | 123.51 |
| [8c92808eb](https://github.com/AFK-surf/monoid/commit/8c92808eb7faaf53b134d696ed0ec5831977063b) perf(scripts): verify SFDELTA1 chunks in delta-fas | 2.72 | 3.67 | 14.83 | 36.94 | 56.33 | 32.4 | 65.68 | 97.73 | 123.51 |
| [03747dd85](https://github.com/AFK-surf/monoid/commit/03747dd85c8c1225759846f23cb29106e224aaed) fix(sf-ui): keep a long relay name inside the stat | 2.67 | 3.59 | 14.64 | 36.94 | 56.33 | 32.4 | 65.68 | 97.73 | 121.44 |
| [98f7a7579](https://github.com/AFK-surf/monoid/commit/98f7a757955982c78df3bed9081e2fb96d3ebca2) feat(sf-ui,sfbase): the node chat page's parts and | 2.67 | 3.59 | 14.64 | 36.94 | 56.32 | 32.4 | 65.68 | 97.72 | 122.32 |
| [d0649076c](https://github.com/AFK-surf/monoid/commit/d0649076c8f3a09f020484d66458e121117cc92d) fix(mbui): fix three native motion and switch test | 2.67 | 3.59 | 14.64 | 36.94 | 56.35 | 32.4 | 65.68 | 98.01 | 127.95 |
| [963a04cee](https://github.com/AFK-surf/monoid/commit/963a04cee0c02fd32efba2b514ef7263cf5d89f4) feat(mbui): show a chat's file in Finder from its  | 2.67 | 3.59 | 14.64 | 36.94 | 56.35 | 32.4 | 65.68 | 97.58 | 111.21 |
| [1d75aef0d](https://github.com/AFK-surf/monoid/commit/1d75aef0d90882292a20ebb41a87aa703f812eb1) fix(station/mb): extract pure choose_run_on_profil | 2.67 | 3.58 | 14.64 | 36.94 | 56.33 | 32.39 | 65.67 | 97.62 | 154.51 |
| [5a2370970](https://github.com/AFK-surf/monoid/commit/5a23709704f453c3cfee73966e5b1f2aa880b303) feat(mbui): support NavTransition::layered in nav_ | 2.67 | 3.58 | 14.64 | 36.94 | 56.33 | 32.39 | 65.67 | 97.76 | 121.75 |
| [af1a63f87](https://github.com/AFK-surf/monoid/commit/af1a63f87f45807a26c47e423046ee983b972dee) fix(station): show why a platform refused a connec | 2.67 | 3.58 | 14.64 | 36.94 | 56.33 | 32.39 | 65.67 | 97.76 | 121.75 |
| [d70ea4c58](https://github.com/AFK-surf/monoid/commit/d70ea4c58335abb30a7045f9b4f3c7d8d0c84305) fix(mbui): track foot end shift in rows_steady and | 2.67 | 3.58 | 14.64 | 36.94 | 56.33 | 32.39 | 65.67 | 97.67 | 121.41 |
| [414eaf84e](https://github.com/AFK-surf/monoid/commit/414eaf84ee8e0af343c4a8db970cbb05f9abcb62) perf(scripts): speed up release delta generation ( | 2.67 | 3.58 | 14.64 | 36.94 | 56.33 | 32.39 | 65.67 | 97.52 | 119.15 |
| [3aae0e034](https://github.com/AFK-surf/monoid/commit/3aae0e034e5456924b2b4731cfa449e5f147b2a7) perf(mbui): gate Android a11y to screen readers, d | 2.67 | 3.58 | 14.64 | 36.94 | 56.33 | 32.39 | 65.67 | 97.52 | 119.15 |
| [147cbffea](https://github.com/AFK-surf/monoid/commit/147cbffeab11883ae0e572fdbb1ae16c43ad2b02) ci(android): hash APK inputs in batches and put fi | 2.67 | 3.58 | 14.64 | 36.93 | 56.33 | 32.39 | 65.67 | 97.63 | 125.92 |
| [07ab0ec5f](https://github.com/AFK-surf/monoid/commit/07ab0ec5fc0516223eee4dc38ded1f7ddee1389a) fix(station): read adb revokes without taking the  | 2.67 | 3.58 | 14.64 | 36.93 | 56.33 | 32.39 | 65.67 | 97.63 | 125.92 |
| [6b2f2c4fa](https://github.com/AFK-surf/monoid/commit/6b2f2c4fad295544428147c3355ef00bba73a635) refactor(station/mb): wire session_storage directl | 2.66 | 3.58 | 14.62 | 36.92 | 56.29 | 32.38 | 65.63 | 97.73 | 120.51 |
| [b251a55c4](https://github.com/AFK-surf/monoid/commit/b251a55c4e3f66d324cb182e76a4883372dc015c) feat(mbui): add layered NavTransition protocol, ge | 2.66 | 3.58 | 14.61 | 36.88 | 56.23 | 32.36 | 65.6 | 97.63 | 130.99 |

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [610441335](https://github.com/AFK-surf/monoid/commit/6104413355243786b5356bfd298a9ebc22fdf21b) fix(rules): defer the hash seed under moonc 0.10.2 | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 60.13 |
| [ea8f4a0a7](https://github.com/AFK-surf/monoid/commit/ea8f4a0a7494995a59eb623b612694fb65970beb) fix(station): keep an account's verification link  | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 60.13 |
| [b73fb6698](https://github.com/AFK-surf/monoid/commit/b73fb6698d4db710a8e7d9f39eccca3e829cac11) mbui(mac): rebind display links across sleep and s | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 60.13 |
| [c5d0a2f8c](https://github.com/AFK-surf/monoid/commit/c5d0a2f8c304a233012f7b2262f841b5b51a4cbf) fix(win,core): fall back to DPAPI when Windows Hel | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 60.13 |
| [4bb241178](https://github.com/AFK-surf/monoid/commit/4bb2411780548bc311cab4b69d670a1c210dddbe) feat(core): dual-track bulk routing and direct spe | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 54.07 |
| [a30a38f5c](https://github.com/AFK-surf/monoid/commit/a30a38f5cd10ade0374c79759bf730b5a3bcd1c9) fix(station): atomic OAuth lock mkdir/utimes and f | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 54.07 |
| [923377ccc](https://github.com/AFK-surf/monoid/commit/923377ccc4e457a8803a3c5a139d47295cc1a3c4) feat(motion,sf-ui): add universal motion primitive | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 54.07 |
| [e0865e126](https://github.com/AFK-surf/monoid/commit/e0865e1261a17c9c095f26fe45e38e61dc3168fc) fix(sf-ui): keep pill button words inside the pill | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 53.94 |
| [ca6d4f62c](https://github.com/AFK-surf/monoid/commit/ca6d4f62ce14b2fa80e85f87fe7df78cda108a2e) fix(station/mb): use monotonic waits and non-block | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 53.94 |
| [9bffa471f](https://github.com/AFK-surf/monoid/commit/9bffa471f13206335e726b774f8d0bb5b7504e10) fix(station/mb): restore Slack Socket Mode WebSock | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 53.94 |
| [e7b99f518](https://github.com/AFK-surf/monoid/commit/e7b99f5185b11db29a0c92c4e1feee06b39f9fdb) fix(mbui): judge reused blocks and over boxes apar | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 54.12 |
| [1632007e3](https://github.com/AFK-surf/monoid/commit/1632007e36d2f29d608f794a9fdce94f2c0eeafd) refactor(motion): clean up 6 wild motions and comp | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 54.28 |
| [97a3958fc](https://github.com/AFK-surf/monoid/commit/97a3958fcd2df0dfe772abe5a37a8e785ac51437) feat(mbui): add hover outline panel and polish cha | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 54.28 |
| [011fb0afe](https://github.com/AFK-surf/monoid/commit/011fb0afe0e00dcad84e625cfaa5733d9fbb421b) fix(mbui): add View soft_min last_resort, structur | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 54.28 |
| [eee9913c2](https://github.com/AFK-surf/monoid/commit/eee9913c2d79fc3b965b35125e6516f16be3a658) fix(mbui): keep word navigation in web text fields | 0.46 | 0.6 | 2.32 | 3.36 | 5.48 | 1.67 | 4.53 | 54.05 |
| [61794c1c3](https://github.com/AFK-surf/monoid/commit/61794c1c31c73d49c066919f1541bc57f17ca449) fix(mbui): let the files sidebar scroll to its las | 0.46 | 0.6 | 2.32 | 3.36 | 5.48 | 1.67 | 4.53 | 54.07 |
| [138e670f3](https://github.com/AFK-surf/monoid/commit/138e670f329b9bdd620c42508aaea7de33abef6d) fix(mbui): tell the tree where shared flights end  | 0.46 | 0.6 | 2.32 | 3.36 | 5.48 | 1.67 | 4.53 | 54.07 |
| [2adad9846](https://github.com/AFK-surf/monoid/commit/2adad9846baca71106ab7cf270a6b456ddf62205) fix(station): serialize move state writes and retr | 0.46 | 0.6 | 2.32 | 3.36 | 5.48 | 1.67 | 4.53 | 54.35 |
| [6f789f91a](https://github.com/AFK-surf/monoid/commit/6f789f91a29c080057372ef3e33bfe8472aa44e6) fix(ci): recover ci-1 checkouts and leave time for | 0.46 | 0.6 | 2.32 | 3.36 | 5.48 | 1.67 | 4.53 | 54.35 |
| [f3954d252](https://github.com/AFK-surf/monoid/commit/f3954d252b7ce305e6b240511974909a93b0a056) perf(mbui): park covered made nav pages at rest wh | 0.46 | 0.6 | 2.32 | 3.36 | 5.48 | 1.67 | 4.53 | 54.35 |
| [d74c5683d](https://github.com/AFK-surf/monoid/commit/d74c5683d0dfc7bfcde8b5951a04851b3b71de75) fix(web): enroll a console's machine as the accoun | 0.46 | 0.6 | 2.32 | 3.36 | 5.48 | 1.67 | 4.53 | 54.35 |
| [5edb9ef7f](https://github.com/AFK-surf/monoid/commit/5edb9ef7f092ae40dd05a125bc2db5e28aab565e) refactor(motion): converge motion tools, sf-ui len | 0.46 | 0.6 | 2.32 | 3.36 | 5.48 | 1.67 | 4.53 | 54.35 |
| [5b1432464](https://github.com/AFK-surf/monoid/commit/5b14324647220c24364ead4c8262f3fe912af973) fix(station): hash all MoonBit headers for the inc | 0.46 | 0.6 | 2.32 | 3.36 | 5.48 | 1.67 | 4.53 | 54.35 |
| [ed4d2a9a8](https://github.com/AFK-surf/monoid/commit/ed4d2a9a88be25f0b0deeb57131ee3788f5c1370) fix(scripts): load libz at run time where zlib.h i | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.1 |
| [a36908324](https://github.com/AFK-surf/monoid/commit/a36908324aef46321019fdda2528355aae1f9643) fix(ci): restore TestFlight's iOS caches by previe | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.1 |
| [8c92808eb](https://github.com/AFK-surf/monoid/commit/8c92808eb7faaf53b134d696ed0ec5831977063b) perf(scripts): verify SFDELTA1 chunks in delta-fas | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.1 |
| [03747dd85](https://github.com/AFK-surf/monoid/commit/03747dd85c8c1225759846f23cb29106e224aaed) fix(sf-ui): keep a long relay name inside the stat | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.1 |
| [98f7a7579](https://github.com/AFK-surf/monoid/commit/98f7a757955982c78df3bed9081e2fb96d3ebca2) feat(sf-ui,sfbase): the node chat page's parts and | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.1 |
| [d0649076c](https://github.com/AFK-surf/monoid/commit/d0649076c8f3a09f020484d66458e121117cc92d) fix(mbui): fix three native motion and switch test | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.1 |
| [963a04cee](https://github.com/AFK-surf/monoid/commit/963a04cee0c02fd32efba2b514ef7263cf5d89f4) feat(mbui): show a chat's file in Finder from its  | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.13 |
| [1d75aef0d](https://github.com/AFK-surf/monoid/commit/1d75aef0d90882292a20ebb41a87aa703f812eb1) fix(station/mb): extract pure choose_run_on_profil | 0.46 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.35 |
| [5a2370970](https://github.com/AFK-surf/monoid/commit/5a23709704f453c3cfee73966e5b1f2aa880b303) feat(mbui): support NavTransition::layered in nav_ | 0.46 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.35 |
| [af1a63f87](https://github.com/AFK-surf/monoid/commit/af1a63f87f45807a26c47e423046ee983b972dee) fix(station): show why a platform refused a connec | 0.46 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.28 |
| [d70ea4c58](https://github.com/AFK-surf/monoid/commit/d70ea4c58335abb30a7045f9b4f3c7d8d0c84305) fix(mbui): track foot end shift in rows_steady and | 0.46 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.28 |
| [414eaf84e](https://github.com/AFK-surf/monoid/commit/414eaf84ee8e0af343c4a8db970cbb05f9abcb62) perf(scripts): speed up release delta generation ( | 0.46 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.28 |
| [3aae0e034](https://github.com/AFK-surf/monoid/commit/3aae0e034e5456924b2b4731cfa449e5f147b2a7) perf(mbui): gate Android a11y to screen readers, d | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.08 |
| [147cbffea](https://github.com/AFK-surf/monoid/commit/147cbffeab11883ae0e572fdbb1ae16c43ad2b02) ci(android): hash APK inputs in batches and put fi | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 54.08 |
| [07ab0ec5f](https://github.com/AFK-surf/monoid/commit/07ab0ec5fc0516223eee4dc38ded1f7ddee1389a) fix(station): read adb revokes without taking the  | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 53.94 |
| [6b2f2c4fa](https://github.com/AFK-surf/monoid/commit/6b2f2c4fad295544428147c3355ef00bba73a635) refactor(station/mb): wire session_storage directl | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 53.94 |
| [b251a55c4](https://github.com/AFK-surf/monoid/commit/b251a55c4e3f66d324cb182e76a4883372dc015c) feat(mbui): add layered NavTransition protocol, ge | 0.45 | 0.59 | 2.29 | 3.37 | 5.51 | 1.68 | 4.53 | 53.94 |
