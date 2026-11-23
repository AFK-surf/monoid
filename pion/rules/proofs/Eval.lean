/-
Differential `#eval` harness comparing Lean-extracted `Fork`, `History`, `Role`,
and `Views` functions against native Pion execution (`prove-lean.sh` runs
`diff -u native.out lean.out`).
-/
import Fork.Funs
import History.Funs
import Role.Funs
import Views.Funs
open Aeneas Aeneas.Std Result Pion

namespace RulesEval

def i32 (x : Int) : Std.I32 := ⟨BitVec.ofInt _ x⟩
def i64 (x : Int) : Std.I64 := ⟨BitVec.ofInt _ x⟩

def unwrapOk {α : Type} (r : Result α) (fallback : α) : α :=
  match r.match with
  | .ok v => v
  | _ => fallback

def fmtBool (b : Bool) : String := if b then "true" else "false"

def fmtOptStr : Option String → String
  | some s => s!"some({s})"
  | none => "none"

def fmtRole : role.Role → String
  | .Viewer => "Viewer"
  | .Member => "Member"
  | .Admin => "Admin"
  | .Owner => "Owner"

def fmtAdmission : role.Admission → String
  | .Admitted => "Admitted"
  | .Unknown => "Unknown"
  | .Others => "Others"
  | .RanOut => "RanOut"
  | .NoMember => "NoMember"

def fmtRanges (rs : Pion.Array views.ByteRange) : String :=
  let parts := rs.val.map (fun r => s!"[{r.start.val},{r.«end».val})")
  "[" ++ String.intercalate "," parts ++ "]"

def runAll : IO Unit := do
  -- fork
  IO.println s!"fork.ahead.1={fmtBool (unwrapOk (fork.ahead (i32 5) false (i32 10) (i32 2) (i32 3) true (i32 1) (i32 0)) false)}"
  IO.println s!"fork.ahead.2={fmtBool (unwrapOk (fork.ahead (i32 5) true (i32 10) (i32 2) (i32 5) false (i32 1) (i32 0)) false)}"
  IO.println s!"fork.ahead.3={fmtBool (unwrapOk (fork.ahead (i32 5) false (i32 1) (i32 9) (i32 5) false (i32 2) (i32 0)) false)}"
  IO.println s!"fork.ahead.4={fmtBool (unwrapOk (fork.ahead (i32 5) false (i32 1) (i32 2) (i32 5) false (i32 1) (i32 2)) true)}"
  let b1 := unwrapOk (fork.best ⟨[i32 1, i32 3, i32 3, i32 2]⟩ ⟨[false, false, true, true]⟩ ⟨[i32 0, i32 0, i32 5, i32 0]⟩ ⟨[i32 0, i32 1, i32 2, i32 3]⟩) (i32 (-1))
  IO.println s!"fork.best.1={b1.val}"
  let b2 := unwrapOk (fork.best ⟨[i32 2, i32 2, i32 2]⟩ ⟨[false, false, false]⟩ ⟨[i32 4, i32 1, i32 1]⟩ ⟨[i32 9, i32 7, i32 3]⟩) (i32 (-1))
  IO.println s!"fork.best.2={b2.val}"
  -- history
  IO.println s!"history.follows.1={fmtBool (unwrapOk (history.follows false (i64 5) (i64 6)) false)}"
  IO.println s!"history.follows.2={fmtBool (unwrapOk (history.follows false (i64 5) (i64 7)) true)}"
  IO.println s!"history.follows.3={fmtBool (unwrapOk (history.follows true (i64 5) (i64 9)) false)}"
  IO.println s!"history.epoch.1={fmtBool (unwrapOk (history.epoch_ok true (i64 3) (i64 3)) true)}"
  IO.println s!"history.epoch.2={fmtBool (unwrapOk (history.epoch_ok true (i64 3) (i64 4)) false)}"
  IO.println s!"history.deletion.1={fmtBool (unwrapOk (history.deletion_ok true false) true)}"
  IO.println s!"history.deletion.2={fmtBool (unwrapOk (history.deletion_ok true true) false)}"
  IO.println s!"history.item_epoch.1={fmtBool (unwrapOk (history.item_epoch_ok false false (i64 2) (i64 3)) true)}"
  IO.println s!"history.item_epoch.2={fmtBool (unwrapOk (history.item_epoch_ok false true (i64 2) (i64 3)) false)}"
  IO.println s!"history.unexpired.1={fmtBool (unwrapOk (history.unexpired true (i64 10) (i64 10)) true)}"
  IO.println s!"history.unexpired.2={fmtBool (unwrapOk (history.unexpired true (i64 11) (i64 10)) false)}"
  IO.println s!"history.supersedes.1={fmtBool (unwrapOk (history.supersedes (i64 2) false (i64 1) (i64 2) true (i64 9) (i32 1)) true)}"
  IO.println s!"history.supersedes.2={fmtBool (unwrapOk (history.supersedes (i64 2) true (i64 1) (i64 2) false (i64 9) (i32 (-1))) false)}"
  IO.println s!"history.item_open.1={fmtBool (unwrapOk (history.item_open true) true)}"
  -- role
  IO.println s!"role.lower.1={fmtRole (unwrapOk (role.lower .Owner .Admin) .Viewer)}"
  IO.println s!"role.may.1={fmtBool (unwrapOk (role.may .Admin (.MemberSet false true)) true)}"
  IO.println s!"role.may.2={fmtBool (unwrapOk (role.may .Owner (.MemberSet false true)) false)}"
  IO.println s!"role.own.1={fmtBool (unwrapOk (role.own_device false false .Owner true) true)}"
  IO.println s!"role.own.2={fmtBool (unwrapOk (role.own_device false false .Admin false) false)}"
  IO.println s!"role.keeps.1={fmtBool (unwrapOk (role.keeps_owner (i32 1) true false) true)}"
  IO.println s!"role.keeps.2={fmtBool (unwrapOk (role.keeps_owner (i32 2) true false) false)}"
  IO.println s!"role.admission.1={fmtAdmission (unwrapOk (role.admission true true true true) .Unknown)}"
  IO.println s!"role.admission.2={fmtAdmission (unwrapOk (role.admission true false true true) .Unknown)}"
  IO.println s!"role.person_admits.1={fmtBool (unwrapOk (role.person_admits true true true) false)}"
  -- views (client-core invariants)
  IO.println s!"views.admit.1={fmtOptStr (unwrapOk (views.admit_member_role none "owner") none)}"
  IO.println s!"views.admit.2={fmtOptStr (unwrapOk (views.admit_member_role (some "admin") "member") none)}"
  IO.println s!"views.admit_actor.1={fmtOptStr (unwrapOk (views.admit_member_role_by_actor "admin" (some "owner") none "owner") none)}"
  IO.println s!"views.admit_actor.2={fmtOptStr (unwrapOk (views.admit_member_role_by_actor "member" (some "viewer") none "viewer") none)}"
  IO.println s!"views.admit_actor.3={fmtOptStr (unwrapOk (views.admit_member_role_by_actor "owner" (some "admin") none "owner") none)}"
  IO.println s!"views.vault_scope.1={fmtBool (unwrapOk (views.vault_allows_scope (some "once") "hour") true)}"
  IO.println s!"views.vault_scope.2={fmtBool (unwrapOk (views.vault_allows_scope (some "hour") "hour") false)}"
  IO.println s!"views.vault_scope.3={fmtBool (unwrapOk (views.vault_allows_scope none "chat") false)}"
  let mr := unwrapOk (views.merge_ranges ⟨[⟨i64 10, i64 20⟩, ⟨i64 5, i64 5⟩, ⟨i64 0, i64 8⟩, ⟨i64 8, i64 12⟩, ⟨i64 25, i64 30⟩]⟩) ⟨[]⟩
  IO.println s!"views.merge.1={fmtRanges mr}"
  let miss := unwrapOk (views.missing_ranges ⟨i64 0, i64 35⟩ ⟨[⟨i64 10, i64 20⟩, ⟨i64 5, i64 5⟩, ⟨i64 0, i64 8⟩, ⟨i64 8, i64 12⟩, ⟨i64 25, i64 30⟩]⟩) ⟨[]⟩
  IO.println s!"views.missing.1={fmtRanges miss}"

#eval runAll

end RulesEval
