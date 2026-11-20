# Upstream Official Test Corpora

Compact gzipped fixtures extracted directly from upstream official test suites for
`station/test/mb-upstream-corpora.test.ts`:

| Fixture | Upstream Source | Commit / Version | License | Count |
| --- | --- | --- | --- | --- |
| `jsontestsuite.json.gz` | `nst/JSONTestSuite` (`test_parsing/`) | `1ef36fa01286573e846ac449e8683f8833c5b26a` | MIT | 318 (`95 y_`, `188 n_`, `35 i_`) |
| `node-path.json.gz` | `nodejs/node` (`test/parallel/test-path-{join,dirname,basename,isabsolute,relative,extname}.js`) | `3c26849e1724c8789d8789229e3051f4e8110198` | MIT | 6 test files (POSIX + Win32) |
| `wpt-urltestdata.json.gz` | `web-platform-tests/wpt` (`url/resources/urltestdata.json`, `base === null`) | `c9fcb443701f254bfea4a3372fdd580a64d1cace` | BSD-3-Clause | 562 |
| `wycheproof.json.gz` | `C2SP/wycheproof` (`testvectors_v1/{aes_gcm,ecdh_secp256r1,ecdsa_secp256r1_sha256,rsa_signature_2048_sha256}_test.json`) | `65ca494727a52944c204441c860b039e6786b99b` | Apache-2.0 | 1,467 (112 AES-GCM + 612 ECDH + 484 ECDSA + 259 RSA) |
| `pngsuite.json.gz` | Willem van Schaik's official PNGSuite (`PngSuite-2017jul19.tgz`) | `2017jul19` | PNGSuite (free to use/distribute) | 176 (162 valid + 14 `x*` corrupt) |
