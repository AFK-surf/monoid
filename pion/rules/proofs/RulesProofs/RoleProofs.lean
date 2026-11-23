/-
Complete Lean 4 proofs for `pion/rules/packages/role` (`Role/Funs.lean`),
matching and strengthening `rules/src/role/role.mbtp` (284 lines).
-/
import Role.Funs
import RulesProofs.Common
open Aeneas Aeneas.Std Result Pion WP

namespace RulesProofs.RoleP

open RulesProofs

/-! ## Pure specification helpers matching `rules/src/role/role.mbtp` -/

def rankVal : role.Role → Int
  | .Viewer => 0
  | .Member => 1
  | .Admin => 2
  | .Owner => 3

def managing (who : role.Role) : Prop := rankVal who ≥ 2
def owning (who : role.Role) : Prop := rankVal who = 3

def oneIfVal (b : Bool) : Int := if b then 1 else 0

theorem rank_spec (r : role.Role) :
    role.rank r ⦃ v => v.val = rankVal r ⦄ := by
  cases r <;> simp [role.rank, rankVal]

theorem one_if_spec (b : Bool) :
    role.one_if b ⦃ v => v.val = oneIfVal b ⦄ := by
  cases b <;> simp [role.one_if, oneIfVal]

/-! ## 1. `lower` -/

def lowerPost (a b res : role.Role) : Prop :=
  rankVal res ≤ rankVal a ∧ rankVal res ≤ rankVal b ∧
    (rankVal res = rankVal a ∨ rankVal res = rankVal b)

theorem lower_post (a b : role.Role) :
    role.lower a b ⦃ res => lowerPost a b res ⦄ := by
  cases a <;> cases b <;> simp [role.lower, role.rank, lowerPost, rankVal]

/-! ## 2. `may` (soundness AND completeness for all 6 `Change` variants) -/

def mayRule (who : role.Role) : role.Change → Prop
  | .MemberSet was becomes =>
      managing who ∧ (was = true → owning who) ∧ (becomes = true → owning who)
  | .MemberRemove was =>
      managing who ∧ (was = true → owning who)
  | .Own mine =>
      mine = true ∨ managing who
  | .Roster =>
      managing who
  | .CloudKeys =>
      owning who
  | .Disable =>
      owning who

theorem may_post (who : role.Role) (c : role.Change) :
    role.may who c ⦃ res => res = true ↔ mayRule who c ⦄ := by
  cases c with
  | MemberSet was becomes =>
    cases who <;> cases was <;> cases becomes <;>
      simp [role.may, role.rank, mayRule, managing, owning, rankVal]
  | MemberRemove was =>
    cases who <;> cases was <;>
      simp [role.may, role.rank, mayRule, managing, owning, rankVal]
  | Own mine =>
    cases who <;> cases mine <;>
      simp [role.may, role.rank, mayRule, managing, rankVal]
  | Roster =>
    cases who <;> simp [role.may, role.rank, mayRule, managing, rankVal]
  | CloudKeys =>
    cases who <;> simp [role.may, role.rank, mayRule, owning, rankVal]
  | Disable =>
    cases who <;> simp [role.may, role.rank, mayRule, owning, rankVal]

theorem may_sound (who : role.Role) (c : role.Change) :
    role.may who c ⦃ res => res = true → mayRule who c ⦄ :=
  spec_mono (may_post who c) (fun _ h => h.mp)

theorem may_complete (who : role.Role) (c : role.Change) :
    role.may who c ⦃ res => mayRule who c → res = true ⦄ :=
  spec_mono (may_post who c) (fun _ h => h.mpr)

/-! ## 3. `own_device` (soundness, completeness, and `no_impersonation`) -/

def ownRule (by_them kept : Bool) (who : role.Role) (had_own : Bool) : Prop :=
  by_them = true ∨ kept = true ∨ (managing who ∧ had_own = false)

theorem own_post (by_them kept : Bool) (who : role.Role) (had_own : Bool) :
    role.own_device by_them kept who had_own ⦃ res =>
      (res = true ↔ ownRule by_them kept who had_own) ∧
      (res = true ∧ by_them = false ∧ kept = false → had_own = false) ⦄ := by
  cases by_them <;> cases kept <;> cases who <;> cases had_own <;>
    simp [role.own_device, role.rank, ownRule, managing, rankVal]

theorem own_sound (by_them kept : Bool) (who : role.Role) (had_own : Bool) :
    role.own_device by_them kept who had_own ⦃ res =>
      res = true → ownRule by_them kept who had_own ⦄ :=
  spec_mono (own_post by_them kept who had_own) (fun _ h => h.1.mp)

theorem own_complete (by_them kept : Bool) (who : role.Role) (had_own : Bool) :
    role.own_device by_them kept who had_own ⦃ res =>
      ownRule by_them kept who had_own → res = true ⦄ :=
  spec_mono (own_post by_them kept who had_own) (fun _ h => h.1.mpr)

theorem own_no_impersonation (by_them kept : Bool) (who : role.Role) (had_own : Bool) :
    role.own_device by_them kept who had_own ⦃ res =>
      res = true ∧ by_them = false ∧ kept = false → had_own = false ⦄ :=
  spec_mono (own_post by_them kept who had_own) (fun _ h => h.2)

/-! ## 4. `keeps_owner` -/

def oneLeft (owners : Std.I32) (was becomes : Bool) : Prop :=
  owners.val - oneIfVal was + oneIfVal becomes ≥ 1

theorem keeps_post (owners : Std.I32) (was becomes : Bool)
    (hpre : owners.val ≥ oneIfVal was) :
    role.keeps_owner owners was becomes ⦃ res => res = true ↔ oneLeft owners was becomes ⦄ := by
  unfold role.keeps_owner oneLeft oneIfVal at *
  rw [spec_ok]
  cases becomes <;> cases was
  · simp only [Bool.false_eq_true, ↓reduceIte, decide_eq_true_eq]
    have h1v : (1#i32 : Std.I32).val = 1 := by simp
    change owners.val ≥ (1#i32 : Std.I32).val ↔ owners.val - 0 + 0 ≥ 1
    omega
  · simp only [Bool.false_eq_true, ↓reduceIte, decide_eq_true_eq]
    have h2v : (2#i32 : Std.I32).val = 2 := by simp
    change owners.val ≥ (2#i32 : Std.I32).val ↔ owners.val - 1 + 0 ≥ 1
    omega
  · simp only [Bool.false_eq_true, ↓reduceIte, true_iff] at hpre ⊢
    omega
  · simp only [↓reduceIte, true_iff] at hpre ⊢
    omega

theorem keeps_sound (owners : Std.I32) (was becomes : Bool)
    (hpre : owners.val ≥ oneIfVal was) :
    role.keeps_owner owners was becomes ⦃ res => res = true → oneLeft owners was becomes ⦄ :=
  spec_mono (keeps_post owners was becomes hpre) (fun _ h => h.mp)

theorem keeps_complete (owners : Std.I32) (was becomes : Bool)
    (hpre : owners.val ≥ oneIfVal was) :
    role.keeps_owner owners was becomes ⦃ res => oneLeft owners was becomes → res = true ⦄ :=
  spec_mono (keeps_post owners was becomes hpre) (fun _ h => h.mpr)

/-! ## 5. `takes_effect` -/

theorem effect_post (own : Bool) :
    role.takes_effect own ⦃ res => res = true ↔ own = true ⦄ := by
  cases own <;> simp [role.takes_effect]

/-! ## 6. `replaces` -/

def replacesRule (own_found holds live member : Bool) : Prop :=
  own_found = false ∧ holds = true ∧ live = true ∧ member = true

theorem replaces_post (own_found holds live member : Bool) :
    role.replaces own_found holds live member ⦃ res =>
      res = true ↔ replacesRule own_found holds live member ⦄ := by
  cases own_found <;> cases holds <;> cases live <;> cases member <;>
    simp [role.replaces, replacesRule]

/-! ## 7. `admission` -/

def letIn (found theirs live member : Bool) : Prop :=
  found = true ∧ theirs = true ∧ live = true ∧ member = true

theorem admission_post (found theirs live member : Bool) :
    role.admission found theirs live member ⦃ res =>
      res = .Admitted ↔ letIn found theirs live member ⦄ := by
  cases found <;> cases theirs <;> cases live <;> cases member <;>
    simp [role.admission, letIn]

/-! ## 8. `device_signs` -/

def deviceSignsRule (app holds own member : Bool) : Prop :=
  app = true ∧ holds = true ∧ own = true ∧ member = true

theorem device_signs_post (app holds own member : Bool) :
    role.device_signs app holds own member ⦃ res =>
      res = true ↔ deviceSignsRule app holds own member ⦄ := by
  cases app <;> cases holds <;> cases own <;> cases member <;>
    simp [role.device_signs, deviceSignsRule]

/-! ## 9. `signed_by` -/

theorem signed_by_post (found whose : Bool) :
    role.signed_by found whose ⦃ res => res = true ↔ (found = true ∧ whose = true) ⦄ := by
  cases found <;> cases whose <;> simp [role.signed_by]

/-! ## 10. `cert_device_ok` -/

theorem cert_device_post (own ever : Bool) :
    role.cert_device_ok own ever ⦃ res => res = true ↔ (own = true ∨ ever = true) ⦄ := by
  cases own <;> cases ever <;> simp [role.cert_device_ok]

/-! ## 11. `cert_key_ok` -/

theorem cert_key_post (current ever had : Bool) :
    role.cert_key_ok current ever had ⦃ res =>
      res = true ↔ (current = true ∨ (ever = true ∧ had = true)) ⦄ := by
  cases current <;> cases ever <;> cases had <;> simp [role.cert_key_ok]

/-! ## 12. `key_ok` -/

theorem key_post (seen member : Bool) :
    role.key_ok seen member ⦃ res => res = true ↔ (seen = false ∧ member = true) ⦄ := by
  cases seen <;> cases member <;> simp [role.key_ok]

/-! ## 13. `binds` -/

theorem binds_post (mine own : Bool) :
    role.binds mine own ⦃ res => res = true ↔ (mine = true ∧ own = true) ⦄ := by
  cases mine <;> cases own <;> simp [role.binds]

/-! ## 14. `person_changes` -/

theorem person_changes_post (held lone : Bool) :
    role.person_changes held lone ⦃ res => res = true ↔ (held = true ∧ lone = false) ⦄ := by
  cases held <;> cases lone <;> simp [role.person_changes]

/-! ## 15. `person_admits` -/

theorem person_admits_post (pinned proved held : Bool) :
    role.person_admits pinned proved held ⦃ res =>
      res = true ↔ (pinned = true ∧ proved = true ∧ held = true) ⦄ := by
  cases pinned <;> cases proved <;> cases held <;> simp [role.person_admits]

end RulesProofs.RoleP
