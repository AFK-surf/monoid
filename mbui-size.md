# mbui's sizes and idle memory (MB), each main commit that built them

Written by .github/workflows/mbui-size.yml; every line in mbui-size.jsonl (bytes).

## Full app (`apps/mbui`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle | Android idle PSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [136d854b0](https://github.com/AFK-surf/monoid/commit/136d854b0521e6857f138ea9014c558bea9802e9) fix(station): cap warm idle processes, scale turn  | 2.74 | 3.7 | 15.06 | 37.13 | 57.15 | 32.54 | 66.23 | 98.17 | 113.97 |
| [c5f717b1e](https://github.com/AFK-surf/monoid/commit/c5f717b1e8f2bd3b9b1d9a5065bdd07d2a4d3098) feat(station): Farview Stage 10A release, farview. | 2.74 | 3.7 | 15.05 | 37.12 | 57.12 | 32.54 | 66.23 | 98.17 | 127.12 |
| [f886b0cf9](https://github.com/AFK-surf/monoid/commit/f886b0cf9c69b0e1ed41eb24eebafd4478e6d2fe) feat(mbui): interactive role cursor default, theme | 2.74 | 3.7 | 15.05 | 37.11 | 57.12 | 32.54 | 66.21 | 98.4 | 129.5 |
| [41fab27ae](https://github.com/AFK-surf/monoid/commit/41fab27aee4dff32a0678e54a5d2eb4d58dd8c35) feat(mbui): add layout ergonomics, list_reused, pi | 2.74 | 3.7 | 15.05 | 37.11 | 57.12 | 32.54 | 66.21 | 98.4 | 129.5 |
| [573f1f6d9](https://github.com/AFK-surf/monoid/commit/573f1f6d9b0c4726f8455d6a7ab3d1ae18a72aae) feat(website): restore classic still.fail and youd | 2.74 | 3.7 | 15.05 | 37.11 | 57.12 | 32.54 | 66.21 | 98.4 | 129.5 |
| [b5fa8d018](https://github.com/AFK-surf/monoid/commit/b5fa8d018c4fa196b284e5a53aaabe9349116692) feat(mbui): open previews over the whole window by | 2.74 | 3.7 | 15.03 | 37.09 | 57.04 | 32.52 | 66.16 | 98.16 | 121.64 |
| [b7e9ad90b](https://github.com/AFK-surf/monoid/commit/b7e9ad90b94e4f4d15cfec864ecbc609620975e6) test(station/mb): presence closes, connect refusal | 2.74 | 3.7 | 15.03 | 37.09 | 57.03 | 32.52 | 66.15 | 98.39 | 113 |
| [096c36f6c](https://github.com/AFK-surf/monoid/commit/096c36f6c1ca839906b6e667b6effd328810d704) fix(ci): leave room for preview ios to save mbui-i | 2.74 | 3.7 | 15.03 | 37.09 | 57.03 | 32.52 | 66.15 | 98.17 | 120.01 |
| [a4e3eccff](https://github.com/AFK-surf/monoid/commit/a4e3eccff1674484b81b728d94c157d6a51072f4) feat(mbui): add workspace vault UI, member managem | 2.74 | 3.7 | 15.03 | 37.08 | 57.03 | 32.47 | 66.05 | 97.98 | 125.52 |
| [a98651b19](https://github.com/AFK-surf/monoid/commit/a98651b196b8f2e9b609ca2de48cc74431a5d2ea) perf(mbui): optimize profiles overview rendering,  | 2.74 | 3.69 | 15.01 | 37.06 | 56.95 | 32.47 | 66.05 | 97.98 | 122.47 |
| [edec068e2](https://github.com/AFK-surf/monoid/commit/edec068e2cf5070a445028717d83aaa624b7f12d) fix(station-mb): drive session_hub timers and defe | 2.73 | 3.69 | 15 | 37.03 | 56.91 | 32.47 | 66.05 | 97.98 | 122.89 |
| [48e5e6774](https://github.com/AFK-surf/monoid/commit/48e5e6774e57a407ed5f1b56bab66627c6106135) feat(comma): report stillfail_workspace metadata i | 2.73 | 3.69 | 15 | 37.03 | 56.91 | 32.47 | 66.05 | 97.98 | 122.89 |
| [fe47bab07](https://github.com/AFK-surf/monoid/commit/fe47bab076c13a892ea8a3483c1eebed469ba91d) fix(mbui): draw the working mark as spokes again,  | 2.73 | 3.69 | 15 | 37.03 | 56.91 | 32.47 | 66.05 | 98.21 | 127.87 |
| [12506b5ac](https://github.com/AFK-surf/monoid/commit/12506b5ac038ac1da968efa10789e1c51b1f5c0d) feat(station): add offline diagnostics and read-on | 2.73 | 3.69 | 15 | 37.03 | 56.91 | 32.47 | 66.05 | 98.21 | 127.87 |
| [19bb26f58](https://github.com/AFK-surf/monoid/commit/19bb26f58d3f818d77aa3f9ed375b4f2d3c6b1f6) fix(mbui): turn a page still coming in back from w | 2.73 | 3.68 | 14.98 | 37.01 | 56.86 | 32.45 | 66.01 | 98.04 | 119.16 |
| [52fc07d66](https://github.com/AFK-surf/monoid/commit/52fc07d669219243532cf4dd29deb31fc18c051e) feat(core): multi-way striped parallel downloads a | 2.73 | 3.68 | 14.98 | 37.01 | 56.86 | 32.45 | 66.01 | 98.04 | 119.16 |
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

## Minimal framework baseline (`libs/mbui` `demo`)

| commit | web app.js br | gzip | raw | APK | libmbui.so | Mac zip | Mac program | Mac idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [136d854b0](https://github.com/AFK-surf/monoid/commit/136d854b0521e6857f138ea9014c558bea9802e9) fix(station): cap warm idle processes, scale turn  | 0.46 | 0.6 | 2.33 | 3.37 | 5.51 | 1.69 | 4.57 | 54.13 |
| [c5f717b1e](https://github.com/AFK-surf/monoid/commit/c5f717b1e8f2bd3b9b1d9a5065bdd07d2a4d3098) feat(station): Farview Stage 10A release, farview. | 0.46 | 0.6 | 2.33 | 3.37 | 5.51 | 1.69 | 4.57 | 54.13 |
| [f886b0cf9](https://github.com/AFK-surf/monoid/commit/f886b0cf9c69b0e1ed41eb24eebafd4478e6d2fe) feat(mbui): interactive role cursor default, theme | 0.46 | 0.6 | 2.33 | 3.37 | 5.51 | 1.69 | 4.57 | 54.13 |
| [41fab27ae](https://github.com/AFK-surf/monoid/commit/41fab27aee4dff32a0678e54a5d2eb4d58dd8c35) feat(mbui): add layout ergonomics, list_reused, pi | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.57 | 54.25 |
| [573f1f6d9](https://github.com/AFK-surf/monoid/commit/573f1f6d9b0c4726f8455d6a7ab3d1ae18a72aae) feat(website): restore classic still.fail and youd | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.57 | 53.97 |
| [b5fa8d018](https://github.com/AFK-surf/monoid/commit/b5fa8d018c4fa196b284e5a53aaabe9349116692) feat(mbui): open previews over the whole window by | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.57 | 53.97 |
| [b7e9ad90b](https://github.com/AFK-surf/monoid/commit/b7e9ad90b94e4f4d15cfec864ecbc609620975e6) test(station/mb): presence closes, connect refusal | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.57 | 53.97 |
| [096c36f6c](https://github.com/AFK-surf/monoid/commit/096c36f6c1ca839906b6e667b6effd328810d704) fix(ci): leave room for preview ios to save mbui-i | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.57 | 53.97 |
| [a4e3eccff](https://github.com/AFK-surf/monoid/commit/a4e3eccff1674484b81b728d94c157d6a51072f4) feat(mbui): add workspace vault UI, member managem | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.57 | 53.97 |
| [a98651b19](https://github.com/AFK-surf/monoid/commit/a98651b196b8f2e9b609ca2de48cc74431a5d2ea) perf(mbui): optimize profiles overview rendering,  | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.57 | 53.97 |
| [edec068e2](https://github.com/AFK-surf/monoid/commit/edec068e2cf5070a445028717d83aaa624b7f12d) fix(station-mb): drive session_hub timers and defe | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.57 | 53.97 |
| [48e5e6774](https://github.com/AFK-surf/monoid/commit/48e5e6774e57a407ed5f1b56bab66627c6106135) feat(comma): report stillfail_workspace metadata i | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 54.3 |
| [fe47bab07](https://github.com/AFK-surf/monoid/commit/fe47bab076c13a892ea8a3483c1eebed469ba91d) fix(mbui): draw the working mark as spokes again,  | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 54.3 |
| [12506b5ac](https://github.com/AFK-surf/monoid/commit/12506b5ac038ac1da968efa10789e1c51b1f5c0d) feat(station): add offline diagnostics and read-on | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 53.9 |
| [19bb26f58](https://github.com/AFK-surf/monoid/commit/19bb26f58d3f818d77aa3f9ed375b4f2d3c6b1f6) fix(mbui): turn a page still coming in back from w | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 53.9 |
| [52fc07d66](https://github.com/AFK-surf/monoid/commit/52fc07d669219243532cf4dd29deb31fc18c051e) feat(core): multi-way striped parallel downloads a | 0.46 | 0.6 | 2.33 | 3.37 | 5.5 | 1.68 | 4.55 | 60.13 |
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
