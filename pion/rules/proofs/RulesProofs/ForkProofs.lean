/-
Complete Lean 4 proofs for `pion/rules/packages/fork` (`Fork/Funs.lean`),
matching and strengthening `rules/src/fork/fork.mbtp` (42 lines) and the
proof theorems in `rules/src/fork/fork.mbt`.
-/
import Fork.Funs
import RulesProofs.Common
open Aeneas Aeneas.Std Result Pion WP

namespace RulesProofs.ForkP

open RulesProofs

/-! ## Pure mirror of `fork.ahead` and its strict total order properties -/

def aheadBool (wa : Std.I32) (ra : Bool) (ta ha : Std.I32)
    (wb : Std.I32) (rb : Bool) (tb hb : Std.I32) : Bool :=
  if wa > wb then true
  else if wa < wb then false
  else if ra && !rb then true
  else if rb && !ra then false
  else if ta < tb then true
  else if ta > tb then false
  else decide (ha < hb)

theorem ahead_eq_ok (wa : Std.I32) (ra : Bool) (ta ha : Std.I32)
    (wb : Std.I32) (rb : Bool) (tb hb : Std.I32) :
    fork.ahead wa ra ta ha wb rb tb hb = ok (aheadBool wa ra ta ha wb rb tb hb) := rfl

theorem aheadBool_iff (wa : Std.I32) (ra : Bool) (ta ha : Std.I32)
    (wb : Std.I32) (rb : Bool) (tb hb : Std.I32) :
    aheadBool wa ra ta ha wb rb tb hb = true ↔
      wa.val > wb.val ∨
      (wa.val = wb.val ∧ ra = true ∧ rb = false) ∨
      (wa.val = wb.val ∧ ra = rb ∧ ta.val < tb.val) ∨
      (wa.val = wb.val ∧ ra = rb ∧ ta.val = tb.val ∧ ha.val < hb.val) := by
  unfold aheadBool
  by_cases hw1 : wa > wb
  · have hw1' : wa.val > wb.val := hw1
    rw [ite_eq_left hw1]; simp [hw1']
  · have hw1' : ¬ wa.val > wb.val := hw1
    rw [ite_eq_right hw1]
    by_cases hw2 : wa < wb
    · have hw2' : wa.val < wb.val := hw2
      rw [ite_eq_left hw2]
      constructor
      · intro h; cases h
      · intro h; rcases h with h | ⟨h, _⟩ | ⟨h, _⟩ | ⟨h, _⟩ <;> omega
    · have hw2' : ¬ wa.val < wb.val := hw2
      have hweq : wa.val = wb.val := by omega
      rw [ite_eq_right hw2]
      cases ra <;> cases rb
      · simp only [Bool.false_and, Bool.false_eq_true, ↓reduceIte]
        by_cases ht1 : ta < tb
        · have ht1' : ta.val < tb.val := ht1
          rw [ite_eq_left ht1]; simp [hweq, ht1']
        · have ht1' : ¬ ta.val < tb.val := ht1
          rw [ite_eq_right ht1]
          by_cases ht2 : ta > tb
          · have ht2' : ta.val > tb.val := ht2
            rw [ite_eq_left ht2]
            constructor
            · intro h; cases h
            · intro h
              rcases h with h | ⟨_, h, _⟩ | ⟨_, _, h⟩ | ⟨_, _, h, _⟩
              · omega
              · cases h
              · omega
              · omega
          · have ht2' : ¬ ta.val > tb.val := ht2
            have hteq : ta.val = tb.val := by omega
            rw [ite_eq_right ht2]
            simp only [decide_eq_true_eq]
            constructor
            · intro hh; have hh' : ha.val < hb.val := hh; simp [hweq, hteq, hh']
            · intro h
              rcases h with h | ⟨_, h, _⟩ | ⟨_, _, h⟩ | ⟨_, _, _, hh⟩
              · omega
              · cases h
              · omega
              · exact hh
      · simp only [Bool.false_and, Bool.false_eq_true, ↓reduceIte, Bool.not_false, Bool.and_self]
        constructor
        · intro h; cases h
        · intro h; rcases h with h | ⟨_, h, _⟩ | ⟨_, h, _⟩ | ⟨_, h, _⟩
          · omega
          · cases h
          · cases h
          · cases h
      · simp [hweq]
      · simp only [Bool.not_true, Bool.and_false, Bool.false_eq_true, ↓reduceIte]
        by_cases ht1 : ta < tb
        · have ht1' : ta.val < tb.val := ht1
          rw [ite_eq_left ht1]; simp [hweq, ht1']
        · have ht1' : ¬ ta.val < tb.val := ht1
          rw [ite_eq_right ht1]
          by_cases ht2 : ta > tb
          · have ht2' : ta.val > tb.val := ht2
            rw [ite_eq_left ht2]
            constructor
            · intro h; cases h
            · intro h; rcases h with h | ⟨_, _, h⟩ | ⟨_, _, h⟩ | ⟨_, _, h, _⟩
              · omega
              · cases h
              · omega
              · omega
          · have ht2' : ¬ ta.val > tb.val := ht2
            have hteq : ta.val = tb.val := by omega
            rw [ite_eq_right ht2]
            simp only [decide_eq_true_eq]
            constructor
            · intro hh; have hh' : ha.val < hb.val := hh; simp [hweq, hteq, hh']
            · intro h
              rcases h with h | ⟨_, _, h⟩ | ⟨_, _, h⟩ | ⟨_, _, _, hh⟩
              · omega
              · cases h
              · omega
              · exact hh

/-- Irreflexivity (`ahead_itself`): no child comes before itself. -/
theorem ahead_itself (w : Std.I32) (r : Bool) (t h : Std.I32) :
    fork.ahead w r t h w r t h ⦃ res => res = false ⦄ := by
  rw [ahead_eq_ok, spec_ok]
  by_contra hne
  have ht : aheadBool w r t h w r t h = true := by
    cases hb : aheadBool w r t h w r t h <;> simp_all
  rw [aheadBool_iff] at ht
  rcases ht with h1 | ⟨_, h2, h3⟩ | ⟨_, _, h3⟩ | ⟨_, _, _, h4⟩
  · omega
  · rw [h2] at h3; cases h3
  · omega
  · omega

/-- Asymmetry (`ahead_both`): not each of two children comes before the other. -/
theorem aheadBool_asym {wa : Std.I32} {ra : Bool} {ta ha : Std.I32}
    {wb : Std.I32} {rb : Bool} {tb hb : Std.I32}
    (hab : aheadBool wa ra ta ha wb rb tb hb = true) :
    aheadBool wb rb tb hb wa ra ta ha = false := by
  by_contra hne
  have hba : aheadBool wb rb tb hb wa ra ta ha = true := by
    cases h : aheadBool wb rb tb hb wa ra ta ha <;> simp_all
  rw [aheadBool_iff] at hab hba
  cases ra <;> cases rb <;> simp at hab hba <;> omega

theorem ahead_both (wa : Std.I32) (ra : Bool) (ta ha : Std.I32)
    (wb : Std.I32) (rb : Bool) (tb hb : Std.I32) :
    (do
      let x ← fork.ahead wa ra ta ha wb rb tb hb
      let y ← fork.ahead wb rb tb hb wa ra ta ha
      ok (x && y)) ⦃ res => res = false ⦄ := by
  simp only [ahead_eq_ok, b_ok, spec_ok]
  cases h : aheadBool wa ra ta ha wb rb tb hb
  · simp
  · simp [aheadBool_asym h]

/-- Transitivity (`ahead_through`). -/
theorem aheadBool_trans {wa : Std.I32} {ra : Bool} {ta ha : Std.I32}
    {wb : Std.I32} {rb : Bool} {tb hb : Std.I32}
    {wc : Std.I32} {rc : Bool} {tc hc : Std.I32}
    (hab : aheadBool wa ra ta ha wb rb tb hb = true)
    (hbc : aheadBool wb rb tb hb wc rc tc hc = true) :
    aheadBool wa ra ta ha wc rc tc hc = true := by
  rw [aheadBool_iff] at hab hbc ⊢
  rcases hab with h1 | ⟨h1, h2, h3⟩ | ⟨h1, h2, h3⟩ | ⟨h1, h2, h3, h4⟩ <;>
  rcases hbc with g1 | ⟨g1, g2, g3⟩ | ⟨g1, g2, g3⟩ | ⟨g1, g2, g3, g4⟩
  · exact Or.inl (by omega)
  · exact Or.inl (by omega)
  · exact Or.inl (by omega)
  · exact Or.inl (by omega)
  · exact Or.inl (by omega)
  · rw [h3] at g2; cases g2
  · exact Or.inr (Or.inl ⟨by omega, h2, by rw [← g2]; exact h3⟩)
  · exact Or.inr (Or.inl ⟨by omega, h2, by rw [← g2]; exact h3⟩)
  · exact Or.inl (by omega)
  · exact Or.inr (Or.inl ⟨by omega, by rw [h2]; exact g2, g3⟩)
  · exact Or.inr (Or.inr (Or.inl ⟨by omega, by rw [h2, g2], by omega⟩))
  · exact Or.inr (Or.inr (Or.inl ⟨by omega, by rw [h2, g2], by omega⟩))
  · exact Or.inl (by omega)
  · exact Or.inr (Or.inl ⟨by omega, by rw [h2]; exact g2, g3⟩)
  · exact Or.inr (Or.inr (Or.inl ⟨by omega, by rw [h2, g2], by omega⟩))
  · exact Or.inr (Or.inr (Or.inr ⟨by omega, by rw [h2, g2], by omega, by omega⟩))

theorem ahead_through (wa : Std.I32) (ra : Bool) (ta ha : Std.I32)
    (wb : Std.I32) (rb : Bool) (tb hb : Std.I32)
    (wc : Std.I32) (rc : Bool) (tc hc : Std.I32)
    (hab : aheadBool wa ra ta ha wb rb tb hb = true)
    (hbc : aheadBool wb rb tb hb wc rc tc hc = true) :
    fork.ahead wa ra ta ha wc rc tc hc ⦃ res => res = true ⦄ := by
  rw [ahead_eq_ok, spec_ok]
  exact aheadBool_trans hab hbc

/-- Totality on distinct hashes (`ahead_either`). -/
theorem aheadBool_total {wa : Std.I32} {ra : Bool} {ta ha : Std.I32}
    {wb : Std.I32} {rb : Bool} {tb hb : Std.I32}
    (hne : ha ≠ hb) :
    aheadBool wa ra ta ha wb rb tb hb = true ∨
    aheadBool wb rb tb hb wa ra ta ha = true := by
  have hne' : ha.val ≠ hb.val := fun e => hne (i32_ext e)
  rw [aheadBool_iff, aheadBool_iff]
  by_cases hw1 : wa.val > wb.val
  · exact Or.inl (Or.inl hw1)
  · by_cases hw2 : wb.val > wa.val
    · exact Or.inr (Or.inl hw2)
    · have hweq : wa.val = wb.val := by omega
      cases ra <;> cases rb
      · by_cases ht1 : ta.val < tb.val
        · exact Or.inl (Or.inr (Or.inr (Or.inl ⟨hweq, rfl, ht1⟩)))
        · by_cases ht2 : tb.val < ta.val
          · exact Or.inr (Or.inr (Or.inr (Or.inl ⟨hweq.symm, rfl, ht2⟩)))
          · have hteq : ta.val = tb.val := by omega
            by_cases hh : ha.val < hb.val
            · exact Or.inl (Or.inr (Or.inr (Or.inr ⟨hweq, rfl, hteq, hh⟩)))
            · exact Or.inr (Or.inr (Or.inr (Or.inr ⟨hweq.symm, rfl, hteq.symm, by omega⟩)))
      · exact Or.inr (Or.inr (Or.inl ⟨hweq.symm, rfl, rfl⟩))
      · exact Or.inl (Or.inr (Or.inl ⟨hweq, rfl, rfl⟩))
      · by_cases ht1 : ta.val < tb.val
        · exact Or.inl (Or.inr (Or.inr (Or.inl ⟨hweq, rfl, ht1⟩)))
        · by_cases ht2 : tb.val < ta.val
          · exact Or.inr (Or.inr (Or.inr (Or.inl ⟨hweq.symm, rfl, ht2⟩)))
          · have hteq : ta.val = tb.val := by omega
            by_cases hh : ha.val < hb.val
            · exact Or.inl (Or.inr (Or.inr (Or.inr ⟨hweq, rfl, hteq, hh⟩)))
            · exact Or.inr (Or.inr (Or.inr (Or.inr ⟨hweq.symm, rfl, hteq.symm, by omega⟩)))

theorem ahead_either (wa : Std.I32) (ra : Bool) (ta ha : Std.I32)
    (wb : Std.I32) (rb : Bool) (tb hb : Std.I32) (hne : ha ≠ hb) :
    (do
      let x ← fork.ahead wa ra ta ha wb rb tb hb
      let y ← fork.ahead wb rb tb hb wa ra ta ha
      ok (x || y)) ⦃ res => res = true ⦄ := by
  simp only [ahead_eq_ok, b_ok, spec_ok]
  rcases aheadBool_total (wa := wa) (ra := ra) (ta := ta) (wb := wb) (rb := rb) (tb := tb) hne with h | h
  · simp [h]
  · simp [h]

/-- `step` returns `some _` iff `ahead` is `true`. -/
theorem step_isSome_iff_ahead (wa : Std.I32) (ra : Bool) (ta ha : Std.I32)
    (wb : Std.I32) (rb : Bool) (tb hb : Std.I32) :
    fork.step wa ra ta ha wb rb tb hb ⦃ res =>
      res.isSome = aheadBool wa ra ta ha wb rb tb hb ⦄ := by
  unfold fork.step
  rw [ahead_eq_ok, b_ok, spec_ok]
  cases h : aheadBool wa ra ta ha wb rb tb hb
  · simp
  · simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte]
    by_cases h1 : wa ≠ wb
    · simp [h1]
    · simp only [h1, ↓reduceIte]
      by_cases h2 : ra ≠ rb
      · simp [h2]
      · simp only [h2, ↓reduceIte]
        by_cases h3 : ta ≠ tb <;> simp [h3]

/-! ## `best` loop invariant, soundness (`chosen`), and uniqueness (`same_choice`) -/

def SameLength (ws : Pion.Array Std.I32) (rs : Pion.Array Bool)
    (ts hs : Pion.Array Std.I32) : Prop :=
  rs.val.length = ws.val.length ∧ ts.val.length = ws.val.length ∧ hs.val.length = ws.val.length

def DistinctHashes (hs : Pion.Array Std.I32) : Prop :=
  ∀ i j : Nat, i < hs.val.length → j < hs.val.length → i ≠ j →
    hs.val[i]? ≠ hs.val[j]?

def BeforeAt (ws : Pion.Array Std.I32) (rs : Pion.Array Bool)
    (ts hs : Pion.Array Std.I32) (b j : Nat) : Prop :=
  aheadBool
    (ws.val[b]?.getD 0#i32) (rs.val[b]?.getD false) (ts.val[b]?.getD 0#i32) (hs.val[b]?.getD 0#i32)
    (ws.val[j]?.getD 0#i32) (rs.val[j]?.getD false) (ts.val[j]?.getD 0#i32) (hs.val[j]?.getD 0#i32) = true

def BeforeUpto (ws : Pion.Array Std.I32) (rs : Pion.Array Bool)
    (ts hs : Pion.Array Std.I32) (b limit : Nat) : Prop :=
  ∀ j : Nat, j < limit → j ≠ b → BeforeAt ws rs ts hs b j

def Chosen (ws : Pion.Array Std.I32) (rs : Pion.Array Bool)
    (ts hs : Pion.Array Std.I32) (b : Std.I32) : Prop :=
  0 ≤ b.val ∧ b.val < ws.val.length ∧ BeforeUpto ws rs ts hs b.val.toNat ws.val.length

def BestInv (ws : Pion.Array Std.I32) (rs : Pion.Array Bool)
    (ts hs : Pion.Array Std.I32) (p : Std.I32 × Std.I32) : Prop :=
  1 ≤ p.1.val ∧ p.1.val ≤ ws.val.length ∧
  0 ≤ p.2.val ∧ p.2.val < p.1.val ∧
  BeforeUpto ws rs ts hs p.2.val.toNat p.1.val.toNat

private theorem getD_of_getElem {α : Type} {l : List α} {k : Nat} (hk : k < l.length) (d : α) :
    (l[k]?).getD d = l[k] := by
  simp [hk]

theorem best_loop0_body_spec (n : Std.I32)
    (ws : Pion.Array Std.I32) (rs : Pion.Array Bool) (ts hs : Pion.Array Std.I32)
    (hn : n.val = ws.val.length) (hlen : ws.val.length ≤ 2147483647)
    (hsame : SameLength ws rs ts hs) (hdist : DistinctHashes hs)
    (p : Std.I32 × Std.I32) (hinv : BestInv ws rs ts hs p) :
    fork.best_loop0.body n ws rs ts hs p.1 p.2 ⦃ r =>
      match r with
      | .done (_, b') => Chosen ws rs ts hs b'
      | .cont p' =>
          BestInv ws rs ts hs p' ∧
          (ws.val.length - p'.1.val.toNat) < (ws.val.length - p.1.val.toNat) ⦄ := by
  obtain ⟨i, b⟩ := p
  obtain ⟨hi1, hi2, hb0, hbi, hbu⟩ := hinv
  obtain ⟨hrl, htl, hhl⟩ := hsame
  dsimp only at hi1 hi2 hb0 hbi hbu ⊢
  unfold fork.best_loop0.body
  by_cases hlt : i < n
  · have hlt' : i.val < ws.val.length := by
      have : i.val < n.val := hlt
      omega
    rw [ite_eq_left hlt]
    have hi_nat : i.val.toNat < ws.val.length := by omega
    have hb_nat : b.val.toNat < ws.val.length := by omega
    have hi_r : i.val.toNat < rs.val.length := by omega
    have hb_r : b.val.toNat < rs.val.length := by omega
    have hi_t : i.val.toNat < ts.val.length := by omega
    have hb_t : b.val.toNat < ts.val.length := by omega
    have hi_h : i.val.toNat < hs.val.length := by omega
    have hb_h : b.val.toNat < hs.val.length := by omega
    rw [arr_get_eq ws i (by omega) (by omega), b_ok]
    rw [arr_get_eq rs i (by omega) (by omega), b_ok]
    rw [arr_get_eq ts i (by omega) (by omega), b_ok]
    rw [arr_get_eq hs i (by omega) (by omega), b_ok]
    rw [arr_get_eq ws b (by omega) (by omega), b_ok]
    rw [arr_get_eq rs b (by omega) (by omega), b_ok]
    rw [arr_get_eq ts b (by omega) (by omega), b_ok]
    rw [arr_get_eq hs b (by omega) (by omega), b_ok]
    rw [ahead_eq_ok, b_ok]
    have h1v : (1#i32 : Std.I32).val = 1 := by simp
    have hi_add : (Pion.I32.add i 1#i32).val = i.val + 1 := by
      have := i32_add_val i 1#i32 (by omega) (by omega)
      rw [h1v] at this; exact this
    have hib_ne : i.val.toNat ≠ b.val.toNat := by omega
    have hhs_ne : hs.val[i.val.toNat] ≠ hs.val[b.val.toNat] := by
      intro heq
      have hd := hdist i.val.toNat b.val.toNat hi_h hb_h hib_ne
      apply hd
      simp [hi_h, hb_h, heq]
    by_cases ha : aheadBool ws.val[i.val.toNat] rs.val[i.val.toNat] ts.val[i.val.toNat] hs.val[i.val.toNat]
        ws.val[b.val.toNat] rs.val[b.val.toNat] ts.val[b.val.toNat] hs.val[b.val.toNat] = true
    · simp only [ha, ↓reduceIte, b_ok, spec_ok]
      unfold BestInv
      dsimp only
      refine ⟨⟨by omega, by omega, by omega, by omega, ?_⟩, by omega⟩
      intro j hj hjne
      have hjlt : j < i.val.toNat := by omega
      unfold BeforeAt
      rw [getD_of_getElem hi_nat, getD_of_getElem hi_r, getD_of_getElem hi_t, getD_of_getElem hi_h]
      by_cases hjb : j = b.val.toNat
      · subst hjb
        rw [getD_of_getElem hb_nat, getD_of_getElem hb_r, getD_of_getElem hb_t, getD_of_getElem hb_h]
        exact ha
      · have hbj := hbu j hjlt hjb
        unfold BeforeAt at hbj
        rw [getD_of_getElem hb_nat, getD_of_getElem hb_r, getD_of_getElem hb_t, getD_of_getElem hb_h] at hbj
        exact aheadBool_trans ha hbj
    · have haf : aheadBool ws.val[i.val.toNat] rs.val[i.val.toNat] ts.val[i.val.toNat] hs.val[i.val.toNat]
          ws.val[b.val.toNat] rs.val[b.val.toNat] ts.val[b.val.toNat] hs.val[b.val.toNat] = false := by
        cases h : aheadBool ws.val[i.val.toNat] rs.val[i.val.toNat] ts.val[i.val.toNat] hs.val[i.val.toNat]
            ws.val[b.val.toNat] rs.val[b.val.toNat] ts.val[b.val.toNat] hs.val[b.val.toNat] <;> simp_all
      simp only [haf, Bool.false_eq_true, ↓reduceIte, b_ok, spec_ok]
      unfold BestInv
      dsimp only
      refine ⟨⟨by omega, by omega, by omega, by omega, ?_⟩, by omega⟩
      intro j hj hjne
      by_cases hji : j = i.val.toNat
      · subst hji
        unfold BeforeAt
        rw [getD_of_getElem hb_nat, getD_of_getElem hb_r, getD_of_getElem hb_t, getD_of_getElem hb_h]
        rw [getD_of_getElem hi_nat, getD_of_getElem hi_r, getD_of_getElem hi_t, getD_of_getElem hi_h]
        rcases aheadBool_total (wa := ws.val[i.val.toNat]) (ra := rs.val[i.val.toNat])
            (ta := ts.val[i.val.toNat]) (wb := ws.val[b.val.toNat]) (rb := rs.val[b.val.toNat])
            (tb := ts.val[b.val.toNat]) hhs_ne with h1 | h2
        · rw [h1] at haf; cases haf
        · exact h2
      · exact hbu j (by omega) hjne
  · have hge : ¬ i.val < n.val := hlt
    rw [ite_eq_right hlt, spec_ok]
    have hieq : i.val.toNat = ws.val.length := by omega
    refine ⟨hb0, by omega, ?_⟩
    rw [← hieq]
    exact hbu

theorem best_chosen (ws : Pion.Array Std.I32) (rs : Pion.Array Bool)
    (ts hs : Pion.Array Std.I32)
    (hne : ws.val.length > 0) (hlen : ws.val.length ≤ 2147483647)
    (hsame : SameLength ws rs ts hs) (hdist : DistinctHashes hs) :
    fork.best ws rs ts hs ⦃ b => Chosen ws rs ts hs b ⦄ := by
  unfold fork.best
  dsimp only
  refine spec_bind' (Pion.Array.length_spec ws hlen) ?_
  intro n hn
  have hloop : fork.best_loop0 n ws rs ts hs 1#i32 0#i32 ⦃ r => Chosen ws rs ts hs r.2 ⦄ := by
    unfold fork.best_loop0
    refine loop.spec_decr_nat (fun p => ws.val.length - p.1.val.toNat)
      (BestInv ws rs ts hs) _ _ _ ?_ ?_
    · rintro ⟨i, b⟩ hI
      have hb := best_loop0_body_spec n ws rs ts hs hn hlen hsame hdist (i, b) hI
      dsimp only at hb ⊢
      refine spec_mono hb ?_
      rintro (x | y) hr <;> exact hr
    · dsimp only [BestInv]
      refine ⟨by simp, by simp; omega, by simp, by simp, ?_⟩
      intro j hj hjne
      have h1 : (1#i32 : Std.I32).val = 1 := by simp
      have h0 : (0#i32 : Std.I32).val = 0 := by simp
      omega
  refine spec_bind' hloop ?_
  rintro ⟨i1, b1⟩ hb1
  simpa [spec_ok] using hb1

/-- Uniqueness (`same_choice`): only one child comes before every other. -/
theorem same_choice (ws : Pion.Array Std.I32) (rs : Pion.Array Bool)
    (ts hs : Pion.Array Std.I32) (b c : Std.I32)
    (hb : Chosen ws rs ts hs b) (hc : Chosen ws rs ts hs c) :
    b = c := by
  obtain ⟨hb0, hb1, hbu⟩ := hb
  obtain ⟨hc0, hc1, hcu⟩ := hc
  by_contra hne
  have hnat : b.val.toNat ≠ c.val.toNat := by
    intro e
    apply hne
    exact i32_ext (by omega)
  have hbc : BeforeAt ws rs ts hs b.val.toNat c.val.toNat :=
    hbu c.val.toNat (by omega) (Ne.symm hnat)
  have hcb : BeforeAt ws rs ts hs c.val.toNat b.val.toNat :=
    hcu b.val.toNat (by omega) hnat
  unfold BeforeAt at hbc hcb
  have hcontra := aheadBool_asym hbc
  rw [hcb] at hcontra
  cases hcontra

end RulesProofs.ForkP
