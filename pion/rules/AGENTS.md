# Working on pion/rules (for agents)

- Pure Pion port of `rules/` (workspace lock, personal lock, fork choice, roster/state4, D6/D7/bind/rootOut, and vault rules), with zero MoonBit or `World` dependencies, compiling to both Native and `wasm32`.
- `rules/AGENTS.md` and `rules/src/*/*.mbt` are the single source of truth for all signing formats, hash tags (`stillfail-lock/1 sig`, `stillfail-vault*/1`, `stillfail-lock-bind/1`), fork-choice tie-breakers, and D6/D7 semantics. Never diverge from them.
- `js/rules-wasm.mjs` instantiates `js/rules.wasm` lazily on first call so module loading never invokes `Math.random` or `crypto.getRandomValues` (Cloudflare Worker compatibility).
- `wasm_entry`'s `rules_sha256_hex_into` writes directly into the freshly allocated, unshared linear-memory buffer of `Bytes::new(64).to_string()`; never pass a shared or immortal `String` to it.
- `shared/rules-runtime.ts` defaults to `pion` in Node when `PION_RULES_AT` (`pion/rules/js/rules-wasm.mjs`, or the bundled `pion-rules` copy beside `main.js`) is present, and keeps `moonbit` as the default in Cloudflare Workers / non-Node (zero `fs`/RNG at load) and as the instant rollback path via `STILLFAIL_RULES_MODE=moonbit` (`shadow` + `STILLFAIL_RULES_SHADOW_STRICT=1` diffs both ports).
- String ordering in `roster`, `chain`, and `supersedes` matches MoonBit's `String::compare` (UTF-16 length first, then UTF-16 code units); canonical JSON key ordering matches JS `Array.prototype.sort()` (lexicographical UTF-16 code units). Lone surrogates are preserved via WTF-8 in `form::Json`.
- `packages/{fork,history,role}` and the 3 pure security/algorithm kernels in `pion/client-core/packages/views` (`admit_member_role` / `admit_member_role_by_actor`, `vault_allows_scope`, `merge_ranges` / `missing_ranges`) are annotated with `#verify` and formally proved in Lean 4 under `proofs/` (zero `sorry`/`admit`/`bv_decide`/`native_decide`, standard axioms only, differential-tested against native Pion).
- Run fast checks after any edit:
  - `pionc fmt --check pion/rules`
  - `pionc check --json pion/rules`
  - `pionc test --json pion/rules`
  - `sh pion/rules/scripts/prove-lean.sh`
  - `bash pion/rules/build.sh`
  - `node --test pion/rules/test/parity.test.mjs`
