# Working on pion/rules (for agents)

- Pure Pion port of `rules/` (workspace lock, personal lock, fork choice, roster/state4, D6/D7/bind/rootOut, and vault rules), with zero MoonBit or `World` dependencies, compiling to both Native and `wasm32`.
- `rules/AGENTS.md` and `rules/src/*/*.mbt` are the single source of truth for all signing formats, hash tags (`stillfail-lock/1 sig`, `stillfail-vault*/1`, `stillfail-lock-bind/1`), fork-choice tie-breakers, and D6/D7 semantics. Never diverge from them.
- `js/rules-wasm.mjs` instantiates `js/rules.wasm` lazily on first call so module loading never invokes `Math.random` or `crypto.getRandomValues` (Cloudflare Worker compatibility).
- String ordering in `roster`, `chain`, and `supersedes` matches MoonBit's `String::compare` (UTF-16 length first, then UTF-16 code units); canonical JSON key ordering matches JS `Array.prototype.sort()` (lexicographical UTF-16 code units). Lone surrogates are preserved via WTF-8 in `form::Json`.
- Run fast checks after any edit:
  - `pionc fmt --check pion/rules`
  - `pionc check --json pion/rules`
  - `pionc test --json pion/rules`
  - `bash pion/rules/build.sh`
  - `node --test pion/rules/test/parity.test.mjs`
