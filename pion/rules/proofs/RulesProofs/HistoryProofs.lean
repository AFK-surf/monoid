/-
Complete Lean 4 proofs for `pion/rules/packages/history` (`History/Funs.lean`),
matching and strengthening `rules/src/history/history.mbtp` (158 lines).
-/
import History.Funs
import RulesProofs.Common
open Aeneas Aeneas.Std Result Pion WP

namespace RulesProofs.HistoryP

open RulesProofs

/-! ## Specifications matching `rules/src/history/history.mbtp` -/

def followsRule (copy : Bool) (held next : Std.I64) : Prop :=
  (copy = true ∧ next.val > held.val) ∨ (copy = false ∧ next.val = held.val + 1)

def epochTaken (gone : Bool) (prev next : Std.I64) : Prop :=
  next.val ≥ prev.val ∧ (gone = true → next.val > prev.val)

def stays (was now : Bool) : Prop :=
  was = true → now = true

def itemEpochTaken (deleted copy : Bool) (epoch vault : Std.I64) : Prop :=
  epoch.val ≤ vault.val ∧ (deleted = false ∧ copy = false → epoch.val = vault.val)

def inTime (lasts : Bool) (exp now : Std.I64) : Prop :=
  lasts = true → exp.val > now.val

def supersedesRule (seq_a : Std.I64) (deleted_a : Bool) (epoch_a : Std.I64)
    (seq_b : Std.I64) (deleted_b : Bool) (epoch_b : Std.I64) (text : Std.I32) : Prop :=
  seq_a.val > seq_b.val ∨
  (seq_a.val = seq_b.val ∧ deleted_a = true ∧ deleted_b = false) ∨
  (seq_a.val = seq_b.val ∧ deleted_a = deleted_b ∧ epoch_a.val > epoch_b.val) ∨
  (seq_a.val = seq_b.val ∧ deleted_a = deleted_b ∧ epoch_a.val = epoch_b.val ∧ text.val > 0)

/-! ## 1. `follows` -/

theorem follows_post (copy : Bool) (held next : Std.I64)
    (h0 : 0 ≤ held.val) (h1 : held.val < 9007199254740991) :
    history.follows copy held next ⦃ res => res = true ↔ followsRule copy held next ⦄ := by
  unfold history.follows followsRule
  rw [spec_ok]
  have h1v : (Pion.I32.to_int64 1#i32).val = 1 := by simp [Pion.I32.to_int64]
  have hadd : (Pion.I64.add held (Pion.I32.to_int64 1#i32)).val = held.val + 1 := by
    have := i64_add_val held (Pion.I32.to_int64 1#i32) (by omega) (by omega)
    rw [h1v] at this
    exact this
  cases copy
  · simp only [Bool.false_eq_true, ↓reduceIte, false_and, true_and, false_or]
    constructor
    · intro h
      have heq : next = Pion.I64.add held (Pion.I32.to_int64 1#i32) := by
        simpa [beq_iff_eq] using h
      rw [heq, hadd]
    · intro h
      have heq : next = Pion.I64.add held (Pion.I32.to_int64 1#i32) :=
        i64_ext (by omega)
      simp [heq]
  · simp only [↓reduceIte, true_and, Bool.true_eq_false, false_and, or_false]
    constructor
    · intro h
      have hgt : next > held := of_decide_eq_true h
      exact hgt
    · intro h
      exact decide_eq_true h

theorem follows_sound (copy : Bool) (held next : Std.I64)
    (h0 : 0 ≤ held.val) (h1 : held.val < 9007199254740991) :
    history.follows copy held next ⦃ res => res = true → followsRule copy held next ⦄ :=
  spec_mono (follows_post copy held next h0 h1) (fun _ h => h.mp)

theorem follows_complete (copy : Bool) (held next : Std.I64)
    (h0 : 0 ≤ held.val) (h1 : held.val < 9007199254740991) :
    history.follows copy held next ⦃ res => followsRule copy held next → res = true ⦄ :=
  spec_mono (follows_post copy held next h0 h1) (fun _ h => h.mpr)

/-! ## 2. `epoch_ok` -/

theorem epoch_post (gone : Bool) (prev next : Std.I64) :
    history.epoch_ok gone prev next ⦃ res => res = true ↔ epochTaken gone prev next ⦄ := by
  unfold history.epoch_ok epochTaken
  rw [spec_ok]
  by_cases hlt : next < prev
  · have hlt' : next.val < prev.val := hlt
    rw [ite_eq_left hlt]
    constructor
    · intro h; cases h
    · intro ⟨hge, _⟩; omega
  · have hlt' : ¬ next.val < prev.val := hlt
    rw [ite_eq_right hlt]
    cases gone
    · simp only [Bool.false_and, Bool.false_eq_true, ↓reduceIte, IsEmpty.forall_iff, and_true, true_iff]
      omega
    · simp only [Bool.true_and, forall_const]
      by_cases heq : next = prev
      · subst heq
        simp
      · have hne : next.val ≠ prev.val := fun h => heq (i64_ext h)
        have hbf : (next == prev) = false := beq_false_of_ne heq
        simp only [hbf, Bool.false_eq_true, ↓reduceIte, true_iff]
        omega

theorem epoch_sound (gone : Bool) (prev next : Std.I64) :
    history.epoch_ok gone prev next ⦃ res => res = true → epochTaken gone prev next ⦄ :=
  spec_mono (epoch_post gone prev next) (fun _ h => h.mp)

theorem epoch_complete (gone : Bool) (prev next : Std.I64) :
    history.epoch_ok gone prev next ⦃ res => epochTaken gone prev next → res = true ⦄ :=
  spec_mono (epoch_post gone prev next) (fun _ h => h.mpr)

/-! ## 3. `deletion_ok` (`stays`: once deleted, irreversible) -/

theorem deletion_post (was now : Bool) :
    history.deletion_ok was now ⦃ res => res = true ↔ stays was now ⦄ := by
  unfold history.deletion_ok stays
  rw [spec_ok]
  cases was <;> cases now <;> simp

theorem deletion_sound (was now : Bool) :
    history.deletion_ok was now ⦃ res => res = true → stays was now ⦄ :=
  spec_mono (deletion_post was now) (fun _ h => h.mp)

theorem deletion_complete (was now : Bool) :
    history.deletion_ok was now ⦃ res => stays was now → res = true ⦄ :=
  spec_mono (deletion_post was now) (fun _ h => h.mpr)

theorem deletion_irreversible :
    history.deletion_ok true false = ok false := by
  rfl

/-! ## 4. `item_epoch_ok` -/

theorem item_epoch_post (deleted copy : Bool) (epoch vault : Std.I64) :
    history.item_epoch_ok deleted copy epoch vault ⦃ res =>
      res = true ↔ itemEpochTaken deleted copy epoch vault ⦄ := by
  unfold history.item_epoch_ok itemEpochTaken
  rw [spec_ok]
  by_cases hgt : epoch > vault
  · have hgt' : epoch.val > vault.val := hgt
    rw [ite_eq_left hgt]
    constructor
    · intro h; cases h
    · intro ⟨hle, _⟩; omega
  · have hgt' : ¬ epoch.val > vault.val := hgt
    rw [ite_eq_right hgt]
    cases deleted <;> cases copy
    · simp only [Bool.not_false, Bool.and_self, Bool.true_and, true_and, forall_const]
      by_cases heq : epoch = vault
      · subst heq
        simp
      · have hne : epoch.val ≠ vault.val := fun h => heq (i64_ext h)
        have hbt : (epoch != vault) = true := bne_iff_ne.mpr heq
        simp [hbt, hne]
    · simp only [Bool.not_false, Bool.not_true, Bool.and_false, Bool.false_and,
        Bool.false_eq_true, ↓reduceIte, true_iff]
      exact ⟨by omega, fun h => by cases h.2⟩
    · simp only [Bool.not_true, Bool.not_false, Bool.false_and, Bool.false_eq_true,
        ↓reduceIte, true_iff]
      exact ⟨by omega, fun h => by cases h.1⟩
    · simp only [Bool.not_true, Bool.false_and, Bool.false_eq_true,
        ↓reduceIte, true_iff]
      exact ⟨by omega, fun h => by cases h.1⟩

theorem item_epoch_sound (deleted copy : Bool) (epoch vault : Std.I64) :
    history.item_epoch_ok deleted copy epoch vault ⦃ res =>
      res = true → itemEpochTaken deleted copy epoch vault ⦄ :=
  spec_mono (item_epoch_post deleted copy epoch vault) (fun _ h => h.mp)

theorem item_epoch_complete (deleted copy : Bool) (epoch vault : Std.I64) :
    history.item_epoch_ok deleted copy epoch vault ⦃ res =>
      itemEpochTaken deleted copy epoch vault → res = true ⦄ :=
  spec_mono (item_epoch_post deleted copy epoch vault) (fun _ h => h.mpr)

/-! ## 5. `unexpired` -/

theorem unexpired_post (lasts : Bool) (exp now : Std.I64) :
    history.unexpired lasts exp now ⦃ res => res = true ↔ inTime lasts exp now ⦄ := by
  unfold history.unexpired inTime
  rw [spec_ok]
  cases lasts
  · simp
  · simp only [Bool.not_true, Bool.false_or, decide_eq_true_eq, forall_const]
    rfl

theorem unexpired_sound (lasts : Bool) (exp now : Std.I64) :
    history.unexpired lasts exp now ⦃ res => res = true → inTime lasts exp now ⦄ :=
  spec_mono (unexpired_post lasts exp now) (fun _ h => h.mp)

theorem unexpired_complete (lasts : Bool) (exp now : Std.I64) :
    history.unexpired lasts exp now ⦃ res => inTime lasts exp now → res = true ⦄ :=
  spec_mono (unexpired_post lasts exp now) (fun _ h => h.mpr)

/-! ## 6. `supersedes` (soundness, completeness, asymmetry, totality) -/

theorem supersedes_post (seq_a : Std.I64) (deleted_a : Bool) (epoch_a : Std.I64)
    (seq_b : Std.I64) (deleted_b : Bool) (epoch_b : Std.I64) (text : Std.I32) :
    history.supersedes seq_a deleted_a epoch_a seq_b deleted_b epoch_b text ⦃ res =>
      res = true ↔ supersedesRule seq_a deleted_a epoch_a seq_b deleted_b epoch_b text ⦄ := by
  unfold history.supersedes supersedesRule
  rw [spec_ok]
  by_cases hs1 : seq_a > seq_b
  · have hs1' : seq_a.val > seq_b.val := hs1
    rw [ite_eq_left hs1]
    simp [hs1']
  · have hs1' : ¬ seq_a.val > seq_b.val := hs1
    rw [ite_eq_right hs1]
    by_cases hs2 : seq_a < seq_b
    · have hs2' : seq_a.val < seq_b.val := hs2
      rw [ite_eq_left hs2]
      constructor
      · intro h; cases h
      · intro h; rcases h with h | ⟨h, _⟩ | ⟨h, _⟩ | ⟨h, _⟩ <;> omega
    · have hs2' : ¬ seq_a.val < seq_b.val := hs2
      have hseq : seq_a.val = seq_b.val := by omega
      rw [ite_eq_right hs2]
      cases deleted_a <;> cases deleted_b
      · simp only [Bool.false_and, Bool.false_eq_true, ↓reduceIte]
        by_cases he1 : epoch_a > epoch_b
        · have he1' : epoch_a.val > epoch_b.val := he1
          rw [ite_eq_left he1]
          simp [hseq, he1']
        · have he1' : ¬ epoch_a.val > epoch_b.val := he1
          rw [ite_eq_right he1]
          by_cases he2 : epoch_a < epoch_b
          · have he2' : epoch_a.val < epoch_b.val := he2
            rw [ite_eq_left he2]
            constructor
            · intro h; cases h
            · intro h
              rcases h with h | ⟨_, h, _⟩ | ⟨_, _, h⟩ | ⟨_, _, h, _⟩
              · omega
              · cases h
              · omega
              · omega
          · have he2' : ¬ epoch_a.val < epoch_b.val := he2
            have heq : epoch_a.val = epoch_b.val := by omega
            rw [ite_eq_right he2]
            simp only [decide_eq_true_eq]
            have h0v : (0#i32 : Std.I32).val = 0 := by simp
            constructor
            · intro ht
              have ht' : text.val > 0 := by
                change text.val > (0#i32 : Std.I32).val at ht
                omega
              simp [hseq, heq, ht']
            · intro h
              rcases h with h | ⟨_, h, _⟩ | ⟨_, _, h⟩ | ⟨_, _, _, ht⟩
              · omega
              · cases h
              · omega
              · change text.val > (0#i32 : Std.I32).val; omega
      · simp only [Bool.false_and, Bool.false_eq_true, ↓reduceIte, Bool.not_false, Bool.and_self]
        constructor
        · intro h; cases h
        · intro h
          rcases h with h | ⟨_, h, _⟩ | ⟨_, h, _⟩ | ⟨_, h, _⟩
          · omega
          · cases h
          · cases h
          · cases h
      · simp [hseq]
      · simp only [Bool.not_true, Bool.and_false, Bool.false_eq_true, ↓reduceIte]
        by_cases he1 : epoch_a > epoch_b
        · have he1' : epoch_a.val > epoch_b.val := he1
          rw [ite_eq_left he1]
          simp [hseq, he1']
        · have he1' : ¬ epoch_a.val > epoch_b.val := he1
          rw [ite_eq_right he1]
          by_cases he2 : epoch_a < epoch_b
          · have he2' : epoch_a.val < epoch_b.val := he2
            rw [ite_eq_left he2]
            constructor
            · intro h; cases h
            · intro h; rcases h with h | ⟨_, _, h⟩ | ⟨_, _, h⟩ | ⟨_, _, h, _⟩
              · omega
              · cases h
              · omega
              · omega
          · have he2' : ¬ epoch_a.val < epoch_b.val := he2
            have heq : epoch_a.val = epoch_b.val := by omega
            rw [ite_eq_right he2]
            simp only [decide_eq_true_eq]
            have h0v : (0#i32 : Std.I32).val = 0 := by simp
            constructor
            · intro ht
              have ht' : text.val > 0 := by
                change text.val > (0#i32 : Std.I32).val at ht
                omega
              simp [hseq, heq, ht']
            · intro h
              rcases h with h | ⟨_, _, h⟩ | ⟨_, _, h⟩ | ⟨_, _, _, ht⟩
              · omega
              · cases h
              · omega
              · change text.val > (0#i32 : Std.I32).val; omega

theorem supersedes_sound (seq_a : Std.I64) (deleted_a : Bool) (epoch_a : Std.I64)
    (seq_b : Std.I64) (deleted_b : Bool) (epoch_b : Std.I64) (text : Std.I32) :
    history.supersedes seq_a deleted_a epoch_a seq_b deleted_b epoch_b text ⦃ res =>
      res = true → supersedesRule seq_a deleted_a epoch_a seq_b deleted_b epoch_b text ⦄ :=
  spec_mono (supersedes_post seq_a deleted_a epoch_a seq_b deleted_b epoch_b text) (fun _ h => h.mp)

theorem supersedes_complete (seq_a : Std.I64) (deleted_a : Bool) (epoch_a : Std.I64)
    (seq_b : Std.I64) (deleted_b : Bool) (epoch_b : Std.I64) (text : Std.I32) :
    history.supersedes seq_a deleted_a epoch_a seq_b deleted_b epoch_b text ⦃ res =>
      supersedesRule seq_a deleted_a epoch_a seq_b deleted_b epoch_b text → res = true ⦄ :=
  spec_mono (supersedes_post seq_a deleted_a epoch_a seq_b deleted_b epoch_b text) (fun _ h => h.mpr)

/-- Asymmetry of `supersedes` when text comparison is antisymmetric (`¬(tab > 0 ∧ tba > 0)`). -/
theorem supersedes_asymmetric (seq_a : Std.I64) (deleted_a : Bool) (epoch_a : Std.I64)
    (seq_b : Std.I64) (deleted_b : Bool) (epoch_b : Std.I64)
    (tab tba : Std.I32) (htext : ¬ (tab.val > 0 ∧ tba.val > 0)) :
    ¬ (supersedesRule seq_a deleted_a epoch_a seq_b deleted_b epoch_b tab ∧
       supersedesRule seq_b deleted_b epoch_b seq_a deleted_a epoch_a tba) := by
  intro ⟨hab, hba⟩
  unfold supersedesRule at hab hba
  cases deleted_a <;> cases deleted_b <;> simp at hab hba <;> omega

/-- Totality of `supersedes` on distinct canonical texts (`tab > 0 ∨ tba > 0`). -/
theorem supersedes_total (seq_a : Std.I64) (deleted_a : Bool) (epoch_a : Std.I64)
    (seq_b : Std.I64) (deleted_b : Bool) (epoch_b : Std.I64)
    (tab tba : Std.I32) (htext : tab.val > 0 ∨ tba.val > 0) :
    supersedesRule seq_a deleted_a epoch_a seq_b deleted_b epoch_b tab ∨
    supersedesRule seq_b deleted_b epoch_b seq_a deleted_a epoch_a tba := by
  unfold supersedesRule
  by_cases hs : seq_a.val > seq_b.val
  · exact Or.inl (Or.inl hs)
  · by_cases hs' : seq_b.val > seq_a.val
    · exact Or.inr (Or.inl hs')
    · have hseq : seq_a.val = seq_b.val := by omega
      cases deleted_a <;> cases deleted_b
      · by_cases he : epoch_a.val > epoch_b.val
        · exact Or.inl (Or.inr (Or.inr (Or.inl ⟨hseq, rfl, he⟩)))
        · by_cases he' : epoch_b.val > epoch_a.val
          · exact Or.inr (Or.inr (Or.inr (Or.inl ⟨hseq.symm, rfl, he'⟩)))
          · have heq : epoch_a.val = epoch_b.val := by omega
            rcases htext with ht | ht
            · exact Or.inl (Or.inr (Or.inr (Or.inr ⟨hseq, rfl, heq, ht⟩)))
            · exact Or.inr (Or.inr (Or.inr (Or.inr ⟨hseq.symm, rfl, heq.symm, ht⟩)))
      · exact Or.inr (Or.inr (Or.inl ⟨hseq.symm, rfl, rfl⟩))
      · exact Or.inl (Or.inr (Or.inl ⟨hseq, rfl, rfl⟩))
      · by_cases he : epoch_a.val > epoch_b.val
        · exact Or.inl (Or.inr (Or.inr (Or.inl ⟨hseq, rfl, he⟩)))
        · by_cases he' : epoch_b.val > epoch_a.val
          · exact Or.inr (Or.inr (Or.inr (Or.inl ⟨hseq.symm, rfl, he'⟩)))
          · have heq : epoch_a.val = epoch_b.val := by omega
            rcases htext with ht | ht
            · exact Or.inl (Or.inr (Or.inr (Or.inr ⟨hseq, rfl, heq, ht⟩)))
            · exact Or.inr (Or.inr (Or.inr (Or.inr ⟨hseq.symm, rfl, heq.symm, ht⟩)))

/-! ## 7. `item_open` -/

theorem item_open_post (was : Bool) :
    history.item_open was ⦃ res => res = true ↔ was = false ⦄ := by
  unfold history.item_open
  rw [spec_ok]
  cases was <;> simp

theorem item_open_sound (was : Bool) :
    history.item_open was ⦃ res => res = true → was = false ⦄ :=
  spec_mono (item_open_post was) (fun _ h => h.mp)

theorem item_open_complete (was : Bool) :
    history.item_open was ⦃ res => was = false → res = true ⦄ :=
  spec_mono (item_open_post was) (fun _ h => h.mpr)

end RulesProofs.HistoryP
