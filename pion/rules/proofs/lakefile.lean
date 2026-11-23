import Lake
open Lake DSL

-- Aeneas Lean backend (`AeneasVerif/aeneas` @ 1dc8ad31b1, `backends/lean`),
-- linked into `.deps/aeneas` by `pion/rules/scripts/prove-lean.sh` (never committed).
require aeneas from "./.deps/aeneas"

package «pionrulesproofs» where
  leanOptions := #[⟨`weak.linter.dupNamespace, false⟩]

@[default_target] lean_lib PionLean

lean_lib Fork where
  globs := #[.submodules `Fork]

lean_lib History where
  globs := #[.submodules `History]

lean_lib Role where
  globs := #[.submodules `Role]

lean_lib Views where
  globs := #[.submodules `Views]

lean_lib RulesProofs where
  globs := #[.submodules `RulesProofs]
