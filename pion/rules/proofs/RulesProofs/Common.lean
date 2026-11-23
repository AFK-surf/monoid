/-
Shared helpers for `pion/rules` and `pion/client-core` Lean 4 proofs over
`pionc extract-lean` generated code.
-/
import PionLean
open Aeneas Aeneas.Std Result Pion WP

namespace RulesProofs

theorem b_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← (ok x : Result α); f y) = f x := by simp

theorem spec_bind' {α β : Type} {m : Result α} {k : α → Result β} {P : Post α} {Q : Post β}
    (h : spec m P) (hk : ∀ x, P x → spec (k x) Q) : spec (m >>= k) Q := by
  rw [bind_tc_eq]
  exact spec_bind h hk

theorem i32_add_val (a b : Std.I32) (h0 : -2147483648 ≤ a.val + b.val)
    (h1 : a.val + b.val ≤ 2147483647) : (Pion.I32.add a b).val = a.val + b.val := by
  have e : (Pion.I32.add a b).bv = a.bv + b.bv := by simp
  have e2 : (Pion.I32.add a b).val = (a.bv + b.bv).toInt := by rw [← e]; rfl
  rw [e2, BitVec.toInt_add]
  have ea : a.bv.toInt = a.val := rfl
  have eb : b.bv.toInt = b.val := rfl
  rw [ea, eb]
  exact Int.bmod_eq_of_le_mul_two (by norm_num; omega) (by norm_num; omega)

theorem i32_sub_val (a b : Std.I32) (h0 : -2147483648 ≤ a.val - b.val)
    (h1 : a.val - b.val ≤ 2147483647) : (Pion.I32.sub a b).val = a.val - b.val := by
  have e : (Pion.I32.sub a b).bv = a.bv - b.bv := by simp
  have e2 : (Pion.I32.sub a b).val = (a.bv - b.bv).toInt := by rw [← e]; rfl
  rw [e2, BitVec.toInt_sub]
  have ea : a.bv.toInt = a.val := rfl
  have eb : b.bv.toInt = b.val := rfl
  rw [ea, eb]
  exact Int.bmod_eq_of_le_mul_two (by norm_num; omega) (by norm_num; omega)

theorem i64_add_val (a b : Std.I64) (h0 : -9223372036854775808 ≤ a.val + b.val)
    (h1 : a.val + b.val ≤ 9223372036854775807) : (Pion.I64.add a b).val = a.val + b.val := by
  have e : (Pion.I64.add a b).bv = a.bv + b.bv := by simp
  have e2 : (Pion.I64.add a b).val = (a.bv + b.bv).toInt := by rw [← e]; rfl
  rw [e2, BitVec.toInt_add]
  have ea : a.bv.toInt = a.val := rfl
  have eb : b.bv.toInt = b.val := rfl
  rw [ea, eb]
  exact Int.bmod_eq_of_le_mul_two (by norm_num; omega) (by norm_num; omega)

theorem i32_ext {a b : Std.I32} (h : a.val = b.val) : a = b := by
  cases a; cases b
  congr
  exact BitVec.eq_of_toInt_eq h

theorem i64_ext {a b : Std.I64} (h : a.val = b.val) : a = b := by
  cases a; cases b
  congr
  exact BitVec.eq_of_toInt_eq h

theorem arr_len_eq {α : Type} (a : Pion.Array α) (h : a.val.length ≤ 2147483647) :
    ∃ n : Std.I32, n.val = a.val.length ∧ a.length = ok n := by
  refine ⟨Std.I32.ofIntCore a.val.length
    ⟨by simp [IScalarTy.numBits], by simp [IScalarTy.numBits]; omega⟩, ?_, ?_⟩
  · simp
  · simp [Pion.Array.length, lengthOf, h]

theorem arr_get_eq {α : Type} (a : Pion.Array α) (i : Std.I32) (h0 : 0 ≤ i.val)
    (h1 : i.val < a.val.length) : a.get i = ok (a.val[i.val.toNat]'(by omega)) := by
  simp [Pion.Array.get, listGet, h0, h1]

theorem arr_set_eq {α : Type} (a : Pion.Array α) (i : Std.I32) (x : α) (h0 : 0 ≤ i.val)
    (h1 : i.val < a.val.length) : a.set i x = ok ⟨a.val.set i.val.toNat x⟩ := by
  simp [Pion.Array.set, listSet, h0, h1]

end RulesProofs
