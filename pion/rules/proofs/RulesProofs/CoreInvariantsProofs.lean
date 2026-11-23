/-
Complete Lean 4 proofs for the 3 `client-core` pure security/algorithm kernels
extracted directly from `pion/client-core/packages/views/src/{auth_view,vault_crypto_view,downloads_view}.pion`
(`Views/Funs.lean`):
1. `admit_member_role` & `admit_member_role_by_actor` (role capping & actor authorization)
2. `vault_allows_scope` (vault grant duration cap `once <= hour <= chat`)
3. `merge_ranges` & `missing_ranges` (half-open byte range coalescing & exact set difference)
-/
import Views.Funs
import RulesProofs.Common
open Aeneas Aeneas.Std Result ControlFlow Pion WP

set_option maxRecDepth 10000

namespace RulesProofs.CoreInvariantsP

open RulesProofs

/-! ## 1. `admit_member_role` & `admit_member_role_by_actor` -/

def roleRankVal (r : String) : Int :=
  if r = "viewer" then 0
  else if r = "member" then 1
  else if r = "admin" then 2
  else if r = "owner" then 3
  else -1

def roleRankI32 (r : String) : Std.I32 :=
  if r = "viewer" then 0#i32
  else if r = "member" then 1#i32
  else if r = "admin" then 2#i32
  else if r = "owner" then 3#i32
  else (-1)#i32

theorem role_rank_eq (r : String) :
    views.role_rank r = ok (roleRankI32 r) := rfl

theorem roleRankI32_val (r : String) :
    (roleRankI32 r).val = roleRankVal r := by
  unfold roleRankI32 roleRankVal
  split_ifs <;> simp

theorem lower_role_av_spec (a b : String) :
    views.lower_role_av a b ⦃ res =>
      (res = a ∨ res = b) ∧
      roleRankVal res ≤ roleRankVal a ∧
      roleRankVal res ≤ roleRankVal b ⦄ := by
  unfold views.lower_role_av
  rw [role_rank_eq, b_ok, role_rank_eq, b_ok, spec_ok]
  have ha := roleRankI32_val a
  have hb := roleRankI32_val b
  by_cases hle : roleRankI32 a ≤ roleRankI32 b
  · have hle' : (roleRankI32 a).val ≤ (roleRankI32 b).val := hle
    rw [ite_eq_left hle]
    exact ⟨Or.inl rfl, le_refl _, by omega⟩
  · have hle' : ¬ (roleRankI32 a).val ≤ (roleRankI32 b).val := hle
    rw [ite_eq_right hle]
    exact ⟨Or.inr rfl, by omega, le_refl _⟩

theorem admit_member_role_spec (noted_role : Option String) (cloud_role : String) :
    views.admit_member_role noted_role cloud_role ⦃ res =>
      ∀ r, res = some r →
        0 ≤ roleRankVal r ∧
        roleRankVal r ≤ roleRankVal cloud_role ∧
        (match noted_role with
         | some nr => roleRankVal r ≤ roleRankVal nr
         | none => roleRankVal r ≤ 1) ⦄ := by
  unfold views.admit_member_role
  rw [role_rank_eq, b_ok]
  have hc := roleRankI32_val cloud_role
  by_cases hlt : roleRankI32 cloud_role < 0#i32
  · rw [ite_eq_left hlt, spec_ok]
    intro r hr; cases hr
  · rw [ite_eq_right hlt]
    have hc0 : 0 ≤ roleRankVal cloud_role := by
      have h0 : (0#i32 : Std.I32).val = 0 := by simp
      have : ¬ (roleRankI32 cloud_role).val < (0#i32 : Std.I32).val := hlt
      omega
    cases noted_role with
    | none =>
      simp only [b_ok]
      refine spec_bind' (lower_role_av_spec "member" cloud_role) ?_
      intro res ⟨hres, hle1, hle2⟩
      rw [spec_ok]
      intro r hr
      injection hr with hrr
      subst hrr
      have hmem : roleRankVal "member" = 1 := by simp [roleRankVal]
      rw [hmem] at hle1
      have hr0 : 0 ≤ roleRankVal res := by
        rcases hres with rfl | rfl
        · omega
        · exact hc0
      exact ⟨hr0, hle2, hle1⟩
    | some nr =>
      dsimp only
      rw [role_rank_eq, b_ok]
      have hnr := roleRankI32_val nr
      by_cases hge : roleRankI32 nr ≥ 0#i32
      · rw [ite_eq_left hge, b_ok]
        have hnr0 : 0 ≤ roleRankVal nr := by
          have h0 : (0#i32 : Std.I32).val = 0 := by simp
          have : (roleRankI32 nr).val ≥ (0#i32 : Std.I32).val := hge
          omega
        refine spec_bind' (lower_role_av_spec nr cloud_role) ?_
        intro res ⟨hres, hle1, hle2⟩
        rw [spec_ok]
        intro r hr
        injection hr with hrr
        subst hrr
        have hr0 : 0 ≤ roleRankVal res := by
          rcases hres with rfl | rfl
          · exact hnr0
          · exact hc0
        exact ⟨hr0, hle2, hle1⟩
      · rw [ite_eq_right hge, b_ok, spec_ok]
        intro r hr; cases hr

/-- `admit_member_role` never elevates above `cloud_role`. -/
theorem admit_member_role_le_cloud (noted_role : Option String) (cloud_role : String) :
    views.admit_member_role noted_role cloud_role ⦃ res =>
      ∀ r, res = some r → 0 ≤ roleRankVal r ∧ roleRankVal r ≤ roleRankVal cloud_role ⦄ :=
  spec_mono (admit_member_role_spec noted_role cloud_role)
    (fun _ h r hr => ⟨(h r hr).1, (h r hr).2.1⟩)

/-- `admit_member_role` with no `noted_role` defaults to at most `"member"` (rank 1). -/
theorem admit_member_role_default_le_member (cloud_role : String) :
    views.admit_member_role none cloud_role ⦃ res =>
      ∀ r, res = some r → roleRankVal r ≤ 1 ⦄ :=
  spec_mono (admit_member_role_spec none cloud_role)
    (fun _ h r hr => (h r hr).2.2)

/-- Non-managers (`actor ≠ "owner" ∧ actor ≠ "admin"`, e.g. `"member"` / `"viewer"`) can never approve anyone. -/
theorem admit_member_role_by_actor_non_manager (actor_role : String)
    (noted_role existing_role : Option String) (cloud_role : String)
    (h1 : actor_role ≠ "owner") (h2 : actor_role ≠ "admin") :
    views.admit_member_role_by_actor actor_role noted_role existing_role cloud_role ⦃ res =>
      res = none ⦄ := by
  unfold views.admit_member_role_by_actor
  have hb1 : (actor_role != "owner") = true := bne_iff_ne.mpr h1
  have hb2 : (actor_role != "admin") = true := bne_iff_ne.mpr h2
  simp [hb1, hb2]

/-- An `"admin"` can never approve an `"owner"`, and any approved role is valid and `≤ cloud_role`. -/
theorem admit_member_role_by_actor_spec (actor_role : String)
    (noted_role existing_role : Option String) (cloud_role : String) :
    views.admit_member_role_by_actor actor_role noted_role existing_role cloud_role ⦃ res =>
      (actor_role = "admin" → res ≠ some "owner") ∧
      (∀ r, res = some r →
        (actor_role = "owner" ∨ actor_role = "admin") ∧
        0 ≤ roleRankVal r ∧
        roleRankVal r ≤ roleRankVal cloud_role) ⦄ := by
  unfold views.admit_member_role_by_actor
  by_cases hact : ((actor_role != "owner") && (actor_role != "admin")) = true
  · simp only [hact, ↓reduceIte, spec_ok]
    exact ⟨(fun _ h => nomatch h), (fun _ h => nomatch h)⟩
  · have hactf : ((actor_role != "owner") && (actor_role != "admin")) = false := by
      cases h : ((actor_role != "owner") && (actor_role != "admin")) <;> simp_all
    have hact_or : actor_role = "owner" ∨ actor_role = "admin" := by
      by_contra hcon
      push Not at hcon
      have hb1 : (actor_role != "owner") = true := bne_iff_ne.mpr hcon.1
      have hb2 : (actor_role != "admin") = true := bne_iff_ne.mpr hcon.2
      rw [hb1, hb2] at hactf
      cases hactf
    simp only [hactf, Bool.false_eq_true, ↓reduceIte]
    rw [role_rank_eq, b_ok]
    have hc := roleRankI32_val cloud_role
    by_cases hclt : roleRankI32 cloud_role < 0#i32
    · rw [ite_eq_left hclt, spec_ok]
      exact ⟨(fun _ h => nomatch h), (fun _ h => nomatch h)⟩
    · rw [ite_eq_right hclt]
      have hc0 : 0 ≤ roleRankVal cloud_role := by
        have h0 : (0#i32 : Std.I32).val = 0 := by simp
        have : ¬ (roleRankI32 cloud_role).val < (0#i32 : Std.I32).val := hclt
        omega
      by_cases hadm_c : ((actor_role == "admin") && (cloud_role == "owner")) = true
      · simp only [hadm_c, ↓reduceIte, spec_ok]
        exact ⟨(fun _ h => nomatch h), (fun _ h => nomatch h)⟩
      · have hadm_cf : ((actor_role == "admin") && (cloud_role == "owner")) = false := by
          cases h : ((actor_role == "admin") && (cloud_role == "owner")) <;> simp_all
        simp only [hadm_cf, Bool.false_eq_true, ↓reduceIte]
        have hstep : ∀ chosen : String, 0 ≤ roleRankVal chosen →
            (do
              let final_role ← views.lower_role_av chosen cloud_role
              if ((actor_role == "admin") && (final_role == "owner")) then
                ok (none : Option String)
              else
                ok (some final_role : Option String)) ⦃ res =>
              (actor_role = "admin" → res ≠ some "owner") ∧
              (∀ r, res = some r →
                (actor_role = "owner" ∨ actor_role = "admin") ∧
                0 ≤ roleRankVal r ∧
                roleRankVal r ≤ roleRankVal cloud_role) ⦄ := by
          intro chosen hch0
          refine spec_bind' (lower_role_av_spec chosen cloud_role) ?_
          intro fr ⟨hfr, _, hle_c⟩
          have hfr0 : 0 ≤ roleRankVal fr := by
            rcases hfr with rfl | rfl
            · exact hch0
            · exact hc0
          by_cases hadm_f : ((actor_role == "admin") && (fr == "owner")) = true
          · simp only [hadm_f, ↓reduceIte, spec_ok]
            exact ⟨(fun _ h => nomatch h), (fun _ h => nomatch h)⟩
          · have hadm_ff : ((actor_role == "admin") && (fr == "owner")) = false := by
              cases h : ((actor_role == "admin") && (fr == "owner")) <;> simp_all
            simp only [hadm_ff, Bool.false_eq_true, ↓reduceIte, spec_ok]
            refine ⟨?_, ?_⟩
            · intro ha hsome
              injection hsome with hfeq
              subst ha; subst hfeq
              simp at hadm_ff
            · intro r hr
              injection hr with hreq
              subst hreq
              exact ⟨hact_or, hfr0, hle_c⟩
        cases noted_role with
        | some nr =>
          dsimp only
          rw [role_rank_eq, b_ok]
          have hnr := roleRankI32_val nr
          by_cases hnrlt : roleRankI32 nr < 0#i32
          · rw [ite_eq_left hnrlt, b_ok, spec_ok]
            exact ⟨(fun _ h => nomatch h), (fun _ h => nomatch h)⟩
          · rw [ite_eq_right hnrlt]
            have hnr0 : 0 ≤ roleRankVal nr := by
              have h0 : (0#i32 : Std.I32).val = 0 := by simp
              have : ¬ (roleRankI32 nr).val < (0#i32 : Std.I32).val := hnrlt
              omega
            by_cases hadm_n : ((actor_role == "admin") && (nr == "owner")) = true
            · simp only [hadm_n, ↓reduceIte, b_ok, spec_ok]
              exact ⟨(fun _ h => nomatch h), (fun _ h => nomatch h)⟩
            · have hadm_nf : ((actor_role == "admin") && (nr == "owner")) = false := by
                cases h : ((actor_role == "admin") && (nr == "owner")) <;> simp_all
              simp only [hadm_nf, Bool.false_eq_true, ↓reduceIte, b_ok]
              exact hstep nr hnr0
        | none =>
          simp only [b_ok]
          cases existing_role with
          | none =>
            simp only [b_ok]
            exact hstep "member" (by simp [roleRankVal])
          | some er =>
            dsimp only
            rw [role_rank_eq, b_ok]
            have her := roleRankI32_val er
            by_cases herge : roleRankI32 er ≥ 0#i32
            · rw [ite_eq_left herge, b_ok]
              have her0 : 0 ≤ roleRankVal er := by
                have h0 : (0#i32 : Std.I32).val = 0 := by simp
                have : (roleRankI32 er).val ≥ (0#i32 : Std.I32).val := herge
                omega
              exact hstep er her0
            · rw [ite_eq_right herge, b_ok]
              exact hstep "member" (by simp [roleRankVal])

/-! ## 2. `vault_allows_scope` (`once <= hour <= chat`) -/

def scopeRankVal (s : String) : Int :=
  if s = "once" then 0
  else if s = "hour" then 1
  else if s = "chat" then 2
  else -1

def scopeRankI32 (s : String) : Std.I32 :=
  if s = "once" then 0#i32
  else if s = "hour" then 1#i32
  else if s = "chat" then 2#i32
  else (-1)#i32

theorem scope_rank_vc_eq (s : String) :
    views.scope_rank_vc s = ok (scopeRankI32 s) := rfl

theorem scopeRankI32_val (s : String) :
    (scopeRankI32 s).val = scopeRankVal s := by
  unfold scopeRankI32 scopeRankVal
  split_ifs <;> simp

theorem vault_allows_scope_spec (lasts : Option String) (grant_scope : String) :
    views.vault_allows_scope lasts grant_scope ⦃ res =>
      res = true ↔
        0 ≤ scopeRankVal grant_scope ∧
        scopeRankVal grant_scope ≤ (match lasts with | some l => scopeRankVal l | none => 2) ⦄ := by
  unfold views.vault_allows_scope
  rw [scope_rank_vc_eq, b_ok]
  have hsr := scopeRankI32_val grant_scope
  by_cases hlt : scopeRankI32 grant_scope < 0#i32
  · have hlt' : scopeRankVal grant_scope < 0 := by
      have h0 : (0#i32 : Std.I32).val = 0 := by simp
      have : (scopeRankI32 grant_scope).val < (0#i32 : Std.I32).val := hlt
      omega
    rw [ite_eq_left hlt, spec_ok]
    constructor
    · intro h; cases h
    · intro ⟨h0, _⟩; omega
  · have hge' : 0 ≤ scopeRankVal grant_scope := by
      have h0 : (0#i32 : Std.I32).val = 0 := by simp
      have : ¬ (scopeRankI32 grant_scope).val < (0#i32 : Std.I32).val := hlt
      omega
    rw [ite_eq_right hlt]
    cases lasts with
    | none =>
      rw [spec_ok]
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      have h2v : (2#i32 : Std.I32).val = 2 := by simp
      have h0v : (0#i32 : Std.I32).val = 0 := by simp
      constructor
      · intro ⟨_, hle⟩
        have hle' : (scopeRankI32 grant_scope).val ≤ (2#i32 : Std.I32).val := hle
        exact ⟨hge', by omega⟩
      · intro ⟨_, hle⟩
        refine ⟨?_, ?_⟩
        · change (2#i32 : Std.I32).val ≥ (0#i32 : Std.I32).val; omega
        · change (scopeRankI32 grant_scope).val ≤ (2#i32 : Std.I32).val; omega
    | some l =>
      dsimp only
      rw [scope_rank_vc_eq, b_ok, spec_ok]
      have hl := scopeRankI32_val l
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      have h0v : (0#i32 : Std.I32).val = 0 := by simp
      constructor
      · intro ⟨hcap0, hle⟩
        have hle' : (scopeRankI32 grant_scope).val ≤ (scopeRankI32 l).val := hle
        exact ⟨hge', by omega⟩
      · intro ⟨_, hle⟩
        refine ⟨?_, ?_⟩
        · change (scopeRankI32 l).val ≥ (0#i32 : Std.I32).val; omega
        · change (scopeRankI32 grant_scope).val ≤ (scopeRankI32 l).val; omega

/-- Strict duration hierarchy `once <= hour <= chat`. -/
theorem vault_allows_scope_once_rejects_hour :
    views.vault_allows_scope (some "once") "hour" = ok false := by
  simp [views.vault_allows_scope, views.scope_rank_vc]

theorem vault_allows_scope_once_rejects_chat :
    views.vault_allows_scope (some "once") "chat" = ok false := by
  simp [views.vault_allows_scope, views.scope_rank_vc]

theorem vault_allows_scope_hour_rejects_chat :
    views.vault_allows_scope (some "hour") "chat" = ok false := by
  simp [views.vault_allows_scope, views.scope_rank_vc]

theorem vault_allows_scope_chat_allows_all :
    views.vault_allows_scope (some "chat") "once" = ok true ∧
    views.vault_allows_scope (some "chat") "hour" = ok true ∧
    views.vault_allows_scope (some "chat") "chat" = ok true := by
  refine ⟨?_, ?_, ?_⟩ <;> simp [views.vault_allows_scope, views.scope_rank_vc]

/-! ## 3. `merge_ranges` & `missing_ranges` (half-open byte intervals) -/

def ValidRange (r : views.ByteRange) : Prop :=
  r.start.val < r.«end».val

def AllValid (l : List views.ByteRange) : Prop :=
  ∀ r ∈ l, ValidRange r

def InRange (x : Int) (r : views.ByteRange) : Prop :=
  r.start.val ≤ x ∧ x < r.«end».val

def InRanges (x : Int) (l : List views.ByteRange) : Prop :=
  ∃ r ∈ l, InRange x r

def RangeLe (a b : views.ByteRange) : Prop :=
  a.start.val < b.start.val ∨ (a.start.val = b.start.val ∧ a.«end».val ≤ b.«end».val)

def SortedRanges (l : List views.ByteRange) : Prop :=
  ∀ p q : Nat, (hp : p < l.length) → (hq : q < l.length) → p < q → RangeLe (l[p]'hp) (l[q]'hq)

def DisjointSorted (l : List views.ByteRange) : Prop :=
  ∀ p q : Nat, (hp : p < l.length) → (hq : q < l.length) → p < q →
    (l[p]'hp).«end».val < (l[q]'hq).start.val

def Overlaps (a b : views.ByteRange) : Prop :=
  a.start.val < b.«end».val ∧ b.start.val < a.«end».val

theorem rangeLe_trans {a b c : views.ByteRange} (hab : RangeLe a b) (hbc : RangeLe b c) :
    RangeLe a c := by
  unfold RangeLe at *
  rcases hab with h1 | ⟨h1, h2⟩ <;> rcases hbc with g1 | ⟨g1, g2⟩
  · exact Or.inl (by omega)
  · exact Or.inl (by omega)
  · exact Or.inl (by omega)
  · exact Or.inr ⟨by omega, by omega⟩

theorem rangeLe_refl (a : views.ByteRange) : RangeLe a a :=
  Or.inr ⟨rfl, le_refl _⟩

theorem byteRange_overlaps_spec (a b : views.ByteRange) :
    views.ByteRange.overlaps a b ⦃ res => res = true ↔ Overlaps a b ⦄ := by
  unfold views.ByteRange.overlaps Overlaps
  rw [spec_ok]
  simp only [Bool.and_eq_true, decide_eq_true_eq]
  rfl

/-! ### Stage A: `merge_ranges_loop0` (filter valid ranges) -/

def Loop0Inv (ranges : Pion.Array views.ByteRange) (p : Std.I32 × Pion.Array views.ByteRange) : Prop :=
  0 ≤ p.1.val ∧ p.1.val ≤ ranges.val.length ∧
  p.2.val.length ≤ p.1.val.toNat ∧
  AllValid p.2.val ∧
  (∀ x : Int, InRanges x p.2.val ↔
    ∃ k : Nat, ∃ hk : k < ranges.val.length, k < p.1.val.toNat ∧ InRange x (ranges.val[k]'hk))

theorem merge_loop0_body_spec (n : Std.I32) (ranges : Pion.Array views.ByteRange)
    (hn : n.val = ranges.val.length) (hlen : ranges.val.length ≤ 2147483647)
    (p : Std.I32 × Pion.Array views.ByteRange) (hinv : Loop0Inv ranges p) :
    views.merge_ranges_loop0.body n ranges p.1 p.2 ⦃ r =>
      match r with
      | .done (_, valid) =>
          valid.val.length ≤ ranges.val.length ∧
          AllValid valid.val ∧
          (∀ x : Int, InRanges x valid.val ↔ InRanges x ranges.val)
      | .cont p' =>
          Loop0Inv ranges p' ∧
          (ranges.val.length - p'.1.val.toNat) < (ranges.val.length - p.1.val.toNat) ⦄ := by
  obtain ⟨i, valid⟩ := p
  obtain ⟨hi0, hi1, hvlen, hval, hcov⟩ := hinv
  dsimp only at hi0 hi1 hvlen hval hcov ⊢
  unfold views.merge_ranges_loop0.body
  by_cases hlt : i < n
  · have hlt' : i.val < ranges.val.length := by
      have : i.val < n.val := hlt
      omega
    rw [ite_eq_left hlt]
    rw [arr_get_eq ranges i hi0 hlt', b_ok]
    set cur := ranges.val[i.val.toNat]'(by omega)
    have h1v : (1#i32 : Std.I32).val = 1 := by simp
    have hi_add : (Pion.I32.add i 1#i32).val = i.val + 1 := by
      have := i32_add_val i 1#i32 (by omega) (by omega)
      rw [h1v] at this; exact this
    by_cases hgt : cur.«end» > cur.start
    · have hgt' : cur.start.val < cur.«end».val := hgt
      rw [ite_eq_left hgt, b_ok, spec_ok]
      unfold Loop0Inv; dsimp only
      refine ⟨⟨by omega, by omega, ?_, ?_, ?_⟩, by omega⟩
      · simp only [Pion.Array.push, List.length_append, List.length_singleton]; omega
      · intro r hr
        simp only [Pion.Array.push, List.mem_append, List.mem_singleton] at hr
        rcases hr with hr | rfl
        · exact hval r hr
        · exact hgt'
      · intro x
        simp only [InRanges, Pion.Array.push, List.mem_append, List.mem_singleton]
        constructor
        · rintro ⟨r, hr | rfl, hxr⟩
          · obtain ⟨k, hkr, hk, hxk⟩ := (hcov x).mp ⟨r, hr, hxr⟩
            exact ⟨k, hkr, by omega, hxk⟩
          · exact ⟨i.val.toNat, by omega, by omega, hxr⟩
        · rintro ⟨k, hkr, hk, hxk⟩
          by_cases hki : k < i.val.toNat
          · obtain ⟨r, hr, hxr⟩ := (hcov x).mpr ⟨k, hkr, hki, hxk⟩
            exact ⟨r, Or.inl hr, hxr⟩
          · have hkeq : k = i.val.toNat := by omega
            subst hkeq
            exact ⟨cur, Or.inr rfl, hxk⟩
    · have hle' : cur.«end».val ≤ cur.start.val := by
        have : ¬ cur.«end».val > cur.start.val := hgt
        omega
      rw [ite_eq_right hgt, b_ok, spec_ok]
      unfold Loop0Inv; dsimp only
      refine ⟨⟨by omega, by omega, by omega, hval, ?_⟩, by omega⟩
      intro x
      rw [hcov x]
      constructor
      · rintro ⟨k, hkr, hk, hxk⟩; exact ⟨k, hkr, by omega, hxk⟩
      · rintro ⟨k, hkr, hk, hxk⟩
        by_cases hki : k < i.val.toNat
        · exact ⟨k, hkr, hki, hxk⟩
        · have hkeq : k = i.val.toNat := by omega
          subst hkeq
          change InRange x cur at hxk
          unfold InRange at hxk
          omega
  · have hge : ¬ i.val < n.val := hlt
    rw [ite_eq_right hlt, spec_ok]
    have hieq : i.val.toNat = ranges.val.length := by omega
    refine ⟨by omega, hval, ?_⟩
    intro x
    rw [hcov x]
    constructor
    · rintro ⟨k, hkr, hk, hxk⟩
      exact ⟨ranges.val[k]'hkr, List.getElem_mem hkr, hxk⟩
    · rintro ⟨r, hr, hxr⟩
      obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem hr
      exact ⟨k, hk, by omega, hxr⟩

theorem merge_loop0_spec (n : Std.I32) (ranges : Pion.Array views.ByteRange)
    (hn : n.val = ranges.val.length) (hlen : ranges.val.length ≤ 2147483647) :
    views.merge_ranges_loop0 n ranges 0#i32 (Pion.Array.ofList []) ⦃ r =>
      r.2.val.length ≤ ranges.val.length ∧
      AllValid r.2.val ∧
      (∀ x : Int, InRanges x r.2.val ↔ InRanges x ranges.val) ⦄ := by
  unfold views.merge_ranges_loop0
  refine loop.spec_decr_nat (fun p => ranges.val.length - p.1.val.toNat)
    (Loop0Inv ranges) _ _ _ ?_ ?_
  · rintro ⟨i, valid⟩ hI
    have hb := merge_loop0_body_spec n ranges hn hlen (i, valid) hI
    dsimp only at hb ⊢
    refine spec_mono hb ?_
    rintro (x | y) hr <;> exact hr
  · refine ⟨by simp, by simp, by simp [Pion.Array.ofList], ?_, ?_⟩
    · intro r hr; simp [Pion.Array.ofList] at hr
    · intro x; simp [InRanges, Pion.Array.ofList]

/-! ### Stage B: `merge_ranges_loop2` & `merge_ranges_loop1` (insertion sort) -/

def PrefixSorted (l : List views.ByteRange) (m : Nat) : Prop :=
  ∀ p q : Nat, (hp : p < l.length) → (hq : q < l.length) → p < q → q < m →
    RangeLe (l[p]'hp) (l[q]'hq)

def Loop2Inv (orig : List views.ByteRange) (i_nat : Nat) (cur : views.ByteRange)
    (p : Std.I32 × Pion.Array views.ByteRange) : Prop :=
  -1 ≤ p.1.val ∧ p.1.val < i_nat ∧
  p.2.val.length = orig.length ∧
  AllValid p.2.val ∧
  -- elements in `[0..j]` and `[j+2..i]` match `orig` shifted, and setting `j+1` to `cur` gives a Perm of `orig`
  (p.2.val.set (p.1.val + 1).toNat cur).Perm orig ∧
  -- `valid[0..j]` is sorted
  (∀ a b : Nat, (ha : a < p.2.val.length) → (hb : b < p.2.val.length) →
    a < b → (b : Int) ≤ p.1.val → RangeLe (p.2.val[a]'ha) (p.2.val[b]'hb)) ∧
  -- `valid[j+2..i]` is sorted
  (∀ a b : Nat, (ha : a < p.2.val.length) → (hb : b < p.2.val.length) →
    p.1.val + 2 ≤ a → a < b → b ≤ i_nat → RangeLe (p.2.val[a]'ha) (p.2.val[b]'hb)) ∧
  -- every element in `valid[0..j]` is `≤` every element in `valid[j+2..i]`
  (∀ a b : Nat, (ha : a < p.2.val.length) → (hb : b < p.2.val.length) →
    (a : Int) ≤ p.1.val → p.1.val + 2 ≤ b → b ≤ i_nat → RangeLe (p.2.val[a]'ha) (p.2.val[b]'hb)) ∧
  -- `cur` is strictly less than (or `≤`) every element in `valid[j+2..i]`
  (∀ b : Nat, (hb : b < p.2.val.length) →
    p.1.val + 2 ≤ b → b ≤ i_nat → RangeLe cur (p.2.val[b]'hb))

private theorem mem_of_mem_set {α : Type} {l : List α} {k : Nat} {x y : α}
    (h : y ∈ l.set k x) : y ∈ l ∨ y = x := by
  obtain ⟨idx, hidx, rfl⟩ := List.getElem_of_mem h
  by_cases he : k = idx
  · subst he; right; simp [List.getElem_set_self]
  · left; rw [List.getElem_set_ne he]; exact List.getElem_mem (by simp at hidx; exact hidx)

private theorem perm_set_shift {α : Type} {l orig : List α} {k : Nat} {cur : α}
    (hk : k + 1 < l.length) (hperm : (l.set (k + 1) cur).Perm orig) :
    ((l.set (k + 1) (l[k]'(by omega))).set k cur).Perm orig := by
  have hswap : ((l.set (k + 1) (l[k]'(by omega))).set k cur).Perm (l.set (k + 1) cur) := by
    set l' := l.set (k + 1) cur
    have hlen : l'.length = l.length := by simp [l']
    have h1' : k < l'.length := by omega
    have h2' : k + 1 < l'.length := by omega
    have hsp := List.set_set_perm h1' h2'
    have heq : (l'.set k (l'[k + 1]'h2')).set (k + 1) (l'[k]'h1') =
        (l.set (k + 1) (l[k]'(by omega))).set k cur := by
      apply List.ext_getElem
      · simp [l']
      · intro idx hi1 hi2
        have hidx : idx < l.length := by simpa [l'] using hi1
        by_cases h_k1 : idx = k + 1
        · subst h_k1
          simp [l']
        · by_cases h_k : idx = k
          · subst h_k
            simp [l']
          · have h1 : k + 1 ≠ idx := Ne.symm h_k1
            have h2 : k ≠ idx := Ne.symm h_k
            simp [l', h1, h2]
    rw [← heq]
    exact hsp
  exact hswap.trans hperm

theorem merge_loop2_body_spec (orig : List views.ByteRange) (i_nat : Nat)
    (cur : views.ByteRange) (_hcur_v : ValidRange cur)
    (hi_lt : i_nat < orig.length) (hlen : orig.length ≤ 2147483647)
    (p : Std.I32 × Pion.Array views.ByteRange) (hinv : Loop2Inv orig i_nat cur p) :
    views.merge_ranges_loop2.body cur p.1 p.2 ⦃ r =>
      match r with
      | .done (j', valid') =>
          -1 ≤ j'.val ∧ j'.val < i_nat ∧
          valid'.val.length = orig.length ∧
          AllValid valid'.val ∧
          (valid'.val.set (j'.val + 1).toNat cur).Perm orig ∧
          PrefixSorted (valid'.val.set (j'.val + 1).toNat cur) (i_nat + 1)
      | .cont p' =>
          Loop2Inv orig i_nat cur p' ∧
          (p'.1.val + 1).toNat < (p.1.val + 1).toNat ⦄ := by
  obtain ⟨j, valid⟩ := p
  obtain ⟨hj0, hj1, hvlen, hval, hperm, hs1, hs2, hcross, hcur_le⟩ := hinv
  dsimp only at hj0 hj1 hvlen hval hperm hs1 hs2 hcross hcur_le ⊢
  unfold views.merge_ranges_loop2.body
  have h0v : (0#i32 : Std.I32).val = 0 := by simp
  have h1v : (1#i32 : Std.I32).val = 1 := by simp
  by_cases hjge : j ≥ 0#i32
  · have hjge' : 0 ≤ j.val := by
      have : j.val ≥ (0#i32 : Std.I32).val := hjge
      omega
    have hj_lt : j.val < valid.val.length := by omega
    rw [ite_eq_left hjge]
    rw [arr_get_eq valid j hjge' hj_lt, b_ok]
    set vj := valid.val[j.val.toNat]'(by omega)
    have hgt_step : ∀ hgt_prop : vj.start.val > cur.start.val ∨
        (vj.start.val = cur.start.val ∧ vj.«end».val > cur.«end».val),
        (do
          let valid1 ← Pion.Array.set valid (Pion.I32.add j 1#i32) vj
          let j1 := Pion.I32.sub j 1#i32
          (ok (cont (j1, valid1)) : Result (ControlFlow (Std.I32 × Pion.Array views.ByteRange) (Std.I32 × Pion.Array views.ByteRange)))) ⦃ r =>
          match r with
          | .done (j', valid') =>
              -1 ≤ j'.val ∧ j'.val < i_nat ∧
              valid'.val.length = orig.length ∧
              AllValid valid'.val ∧
              (valid'.val.set (j'.val + 1).toNat cur).Perm orig ∧
              PrefixSorted (valid'.val.set (j'.val + 1).toNat cur) (i_nat + 1)
          | .cont p' =>
              Loop2Inv orig i_nat cur p' ∧
              (p'.1.val + 1).toNat < (j.val + 1).toNat ⦄ := by
      intro hgt_prop
      have hj_add : (Pion.I32.add j 1#i32).val = j.val + 1 := by
        have := i32_add_val j 1#i32 (by omega) (by omega)
        rw [h1v] at this; exact this
      have hj_sub : (Pion.I32.sub j 1#i32).val = j.val - 1 := by
        have := i32_sub_val j 1#i32 (by omega) (by omega)
        rw [h1v] at this; exact this
      rw [arr_set_eq valid (Pion.I32.add j 1#i32) vj (by omega) (by omega), b_ok, spec_ok]
      have hidx_eq : (Pion.I32.add j 1#i32).val.toNat = j.val.toNat + 1 := by omega
      have hsub_eq : ((Pion.I32.sub j 1#i32).val + 1).toNat = j.val.toNat := by omega
      have hcur_le_vj : RangeLe cur vj := by
        unfold RangeLe
        rcases hgt_prop with h1 | ⟨h1, h2⟩
        · exact Or.inl (by omega)
        · exact Or.inr ⟨h1.symm, by omega⟩
      unfold Loop2Inv; dsimp only
      refine ⟨⟨by omega, by omega, by simp [hvlen], ?_, ?_, ?_, ?_, ?_, ?_⟩, by omega⟩
      · intro r hr
        have := mem_of_mem_set hr
        rcases this with h | rfl
        · exact hval r h
        · exact hval vj (List.getElem_mem (by omega))
      · rw [hidx_eq, hsub_eq]
        have hperm' : (valid.val.set (j.val.toNat + 1) cur).Perm orig := by
          have : (j.val + 1).toNat = j.val.toNat + 1 := by omega
          rwa [← this]
        exact perm_set_shift (by omega) hperm'
      · intro a b ha hb hab hb_le
        have hne_a : (Pion.I32.add j 1#i32).val.toNat ≠ a := by omega
        have hne_b : (Pion.I32.add j 1#i32).val.toNat ≠ b := by omega
        simp only [List.getElem_set_ne hne_a, List.getElem_set_ne hne_b]
        exact hs1 a b (by simp at ha; exact ha) (by simp at hb; exact hb) hab (by omega)
      · intro a b ha hb ha_ge hab hb_le
        have hne_b : (Pion.I32.add j 1#i32).val.toNat ≠ b := by omega
        simp only [List.getElem_set_ne hne_b]
        by_cases ha_eq : a = j.val.toNat + 1
        · subst ha_eq
          simp only [hidx_eq, List.getElem_set_self]
          exact hcross j.val.toNat b (by omega) (by simp at hb; exact hb) (by omega) (by omega) hb_le
        · have hne_a : (Pion.I32.add j 1#i32).val.toNat ≠ a := by omega
          simp only [List.getElem_set_ne hne_a]
          exact hs2 a b (by simp at ha; exact ha) (by simp at hb; exact hb) (by omega) hab hb_le
      · intro a b ha hb ha_le hb_ge hb_le
        have hne_a : (Pion.I32.add j 1#i32).val.toNat ≠ a := by omega
        simp only [List.getElem_set_ne hne_a]
        by_cases hb_eq : b = j.val.toNat + 1
        · subst hb_eq
          simp only [hidx_eq, List.getElem_set_self]
          exact hs1 a j.val.toNat (by simp at ha; exact ha) (by omega) (by omega) (by omega)
        · have hne_b : (Pion.I32.add j 1#i32).val.toNat ≠ b := by omega
          simp only [List.getElem_set_ne hne_b]
          exact hcross a b (by simp at ha; exact ha) (by simp at hb; exact hb) (by omega) (by omega) hb_le
      · intro b hb hb_ge hb_le
        by_cases hb_eq : b = j.val.toNat + 1
        · subst hb_eq
          simp only [hidx_eq, List.getElem_set_self]
          exact hcur_le_vj
        · have hne_b : (Pion.I32.add j 1#i32).val.toNat ≠ b := by omega
          simp only [List.getElem_set_ne hne_b]
          exact hcur_le b (by simp at hb; exact hb) (by omega) hb_le
    have hdone_step : RangeLe vj cur →
        PrefixSorted (valid.val.set (j.val + 1).toNat cur) (i_nat + 1) := by
      intro hvj_le a b ha hb hab hb_lt
      have hk : (j.val + 1).toNat = j.val.toNat + 1 := by omega
      simp only [hk]
      by_cases ha_eq : a = j.val.toNat + 1
      · subst ha_eq
        have hne_b : j.val.toNat + 1 ≠ b := by omega
        simp only [List.getElem_set_self, List.getElem_set_ne hne_b]
        exact hcur_le b (by simp at hb; exact hb) (by omega) (by omega)
      · by_cases hb_eq : b = j.val.toNat + 1
        · subst hb_eq
          have hne_a : j.val.toNat + 1 ≠ a := by omega
          simp only [List.getElem_set_self, List.getElem_set_ne hne_a]
          by_cases ha_j : a = j.val.toNat
          · subst ha_j; exact hvj_le
          · exact rangeLe_trans (hs1 a j.val.toNat (by simp at ha; exact ha) (by omega) (by omega) (by omega)) hvj_le
        · have hne_a : j.val.toNat + 1 ≠ a := by omega
          have hne_b : j.val.toNat + 1 ≠ b := by omega
          simp only [List.getElem_set_ne hne_a, List.getElem_set_ne hne_b]
          by_cases hb_le_j : (b : Int) ≤ j.val
          · exact hs1 a b (by simp at ha; exact ha) (by simp at hb; exact hb) hab hb_le_j
          · by_cases ha_le_j : (a : Int) ≤ j.val
            · exact hcross a b (by simp at ha; exact ha) (by simp at hb; exact hb) ha_le_j (by omega) (by omega)
            · exact hs2 a b (by simp at ha; exact ha) (by simp at hb; exact hb) (by omega) hab (by omega)
    by_cases hsgt : vj.start > cur.start
    · rw [ite_eq_left hsgt, b_ok]
      simp only [↓reduceIte, b_ok]
      exact hgt_step (Or.inl hsgt)
    · rw [ite_eq_right hsgt, b_ok]
      by_cases hseq : vj.start = cur.start
      · rw [ite_eq_left hseq, b_ok, b_ok]
        by_cases hegt : vj.«end» > cur.«end»
        · have hdec : decide (vj.«end» > cur.«end») = true := decide_eq_true hegt
          simp only [hdec, ↓reduceIte, b_ok]
          exact hgt_step (Or.inr ⟨by rw [hseq], hegt⟩)
        · have hdec : decide (vj.«end» > cur.«end») = false := decide_eq_false hegt
          simp only [hdec, Bool.false_eq_true, ↓reduceIte, spec_ok]
          refine ⟨hj0, hj1, hvlen, hval, hperm, hdone_step ?_⟩
          have : ¬ vj.«end».val > cur.«end».val := hegt
          exact Or.inr ⟨by rw [hseq], by omega⟩
      · rw [ite_eq_right hseq, b_ok]
        simp only [Bool.false_eq_true, ↓reduceIte, spec_ok]
        refine ⟨hj0, hj1, hvlen, hval, hperm, hdone_step ?_⟩
        have h1 : ¬ vj.start.val > cur.start.val := hsgt
        have h2 : vj.start.val ≠ cur.start.val := fun e => hseq (i64_ext e)
        exact Or.inl (by omega)
  · have hjneg : j.val = -1 := by
      have : ¬ j.val ≥ (0#i32 : Std.I32).val := hjge
      omega
    rw [ite_eq_right hjge, b_ok]
    simp only [Bool.false_eq_true, ↓reduceIte, spec_ok]
    refine ⟨hj0, hj1, hvlen, hval, hperm, ?_⟩
    intro a b ha hb hab hb_lt
    have hk : (j.val + 1).toNat = 0 := by omega
    simp only [hk]
    have hne_b : 0 ≠ b := by omega
    simp only [List.getElem_set_ne hne_b]
    by_cases ha0 : a = 0
    · subst ha0
      simp only [List.getElem_set_self]
      exact hcur_le b (by simp at hb; exact hb) (by omega) (by omega)
    · have hne_a : 0 ≠ a := by omega
      simp only [List.getElem_set_ne hne_a]
      exact hs2 a b (by simp at ha; exact ha) (by simp at hb; exact hb) (by omega) hab (by omega)

theorem merge_loop2_spec (orig : List views.ByteRange) (i_nat : Nat)
    (cur : views.ByteRange) (hcur_v : ValidRange cur)
    (hi_lt : i_nat < orig.length) (hlen : orig.length ≤ 2147483647)
    (j : Std.I32) (valid : Pion.Array views.ByteRange)
    (hinv : Loop2Inv orig i_nat cur (j, valid)) :
    views.merge_ranges_loop2 cur j valid ⦃ r =>
      -1 ≤ r.1.val ∧ r.1.val < i_nat ∧
      r.2.val.length = orig.length ∧
      AllValid r.2.val ∧
      (r.2.val.set (r.1.val + 1).toNat cur).Perm orig ∧
      PrefixSorted (r.2.val.set (r.1.val + 1).toNat cur) (i_nat + 1) ⦄ := by
  unfold views.merge_ranges_loop2
  refine loop.spec_decr_nat (fun p => (p.1.val + 1).toNat)
    (Loop2Inv orig i_nat cur) _ _ _ ?_ hinv
  rintro ⟨j', v'⟩ hI
  have hb := merge_loop2_body_spec orig i_nat cur hcur_v hi_lt hlen (j', v') hI
  dsimp only at hb ⊢
  refine spec_mono hb ?_
  rintro (x | y) hr <;> exact hr

def Loop1Inv (orig : List views.ByteRange) (p : Std.I32 × Pion.Array views.ByteRange) : Prop :=
  1 ≤ p.1.val ∧ p.1.val ≤ orig.length ∧
  p.2.val.length = orig.length ∧
  AllValid p.2.val ∧
  p.2.val.Perm orig ∧
  PrefixSorted p.2.val p.1.val.toNat

theorem merge_loop1_body_spec (n : Std.I32) (orig : List views.ByteRange)
    (hn : n.val = orig.length) (hlen : orig.length ≤ 2147483647)
    (p : Std.I32 × Pion.Array views.ByteRange) (hinv : Loop1Inv orig p) :
    views.merge_ranges_loop1.body n p.1 p.2 ⦃ r =>
      match r with
      | .done (_, valid') =>
          valid'.val.length = orig.length ∧
          AllValid valid'.val ∧
          valid'.val.Perm orig ∧
          SortedRanges valid'.val
      | .cont p' =>
          Loop1Inv orig p' ∧
          (orig.length - p'.1.val.toNat) < (orig.length - p.1.val.toNat) ⦄ := by
  obtain ⟨i, valid⟩ := p
  obtain ⟨hi1, hi2, hvlen, hval, hperm, hps⟩ := hinv
  dsimp only at hi1 hi2 hvlen hval hperm hps ⊢
  unfold views.merge_ranges_loop1.body
  have h1v : (1#i32 : Std.I32).val = 1 := by simp
  by_cases hlt : i < n
  · have hlt' : i.val < orig.length := by
      have : i.val < n.val := hlt
      omega
    rw [ite_eq_left hlt]
    rw [arr_get_eq valid i (by omega) (by omega), b_ok]
    set cur := valid.val[i.val.toNat]'(by omega)
    have hcur_v : ValidRange cur := hval cur (List.getElem_mem (by omega))
    have hj_val : (Pion.I32.sub i 1#i32).val = i.val - 1 := by
      have := i32_sub_val i 1#i32 (by omega) (by omega)
      rw [h1v] at this; exact this
    have hi_add : (Pion.I32.add i 1#i32).val = i.val + 1 := by
      have := i32_add_val i 1#i32 (by omega) (by omega)
      rw [h1v] at this; exact this
    have hinv2 : Loop2Inv orig i.val.toNat cur (Pion.I32.sub i 1#i32, valid) := by
      unfold Loop2Inv; dsimp only
      refine ⟨by omega, by omega, hvlen, hval, ?_, ?_, ?_, ?_, ?_⟩
      · have hk : ((Pion.I32.sub i 1#i32).val + 1).toNat = i.val.toNat := by omega
        rw [hk]
        have hset : valid.val.set i.val.toNat cur = valid.val := List.set_getElem_self (by omega)
        rw [hset]
        exact hperm
      · intro a b ha hb hab hble
        exact hps a b ha hb hab (by omega)
      · intro a b ha hb ha_ge hab hble; omega
      · intro a b ha hb ha_le hb_ge hble; omega
      · intro b hb hb_ge hble; omega
    refine spec_bind' (merge_loop2_spec orig i.val.toNat cur hcur_v (by omega) hlen
        (Pion.I32.sub i 1#i32) valid hinv2) ?_
    rintro ⟨j1, valid1⟩ ⟨hj10, hj11, hv1len, hv1val, hv1perm, hv1ps⟩
    dsimp only at hj10 hj11 hv1len hv1val hv1perm hv1ps ⊢
    have hj1_add : (Pion.I32.add j1 1#i32).val = j1.val + 1 := by
      have := i32_add_val j1 1#i32 (by omega) (by omega)
      rw [h1v] at this; exact this
    change (do
      let valid2 ← Pion.Array.set valid1 (Pion.I32.add j1 1#i32) cur
      ok (cont (Pion.I32.add i 1#i32, valid2))) ⦃ _ ⦄
    rw [arr_set_eq valid1 (Pion.I32.add j1 1#i32) cur (by omega) (by omega), b_ok, spec_ok]
    have hidx : (Pion.I32.add j1 1#i32).val.toNat = (j1.val + 1).toNat := by omega
    rw [hidx]
    unfold Loop1Inv; dsimp only
    refine ⟨⟨by omega, by omega, by simp [hv1len], ?_, hv1perm, ?_⟩, by omega⟩
    · intro r hr
      rcases mem_of_mem_set hr with h | rfl
      · exact hv1val r h
      · exact hcur_v
    · have hi_nat_eq : (Pion.I32.add i 1#i32).val.toNat = i.val.toNat + 1 := by omega
      rw [hi_nat_eq]
      exact hv1ps
  · have hge : ¬ i.val < n.val := hlt
    rw [ite_eq_right hlt, spec_ok]
    have hieq : i.val.toNat = orig.length := by omega
    refine ⟨hvlen, hval, hperm, ?_⟩
    intro p q hp hq hpq
    exact hps p q hp hq hpq (by omega)

theorem merge_loop1_spec (n : Std.I32) (valid : Pion.Array views.ByteRange)
    (hn : n.val = valid.val.length) (hne : valid.val.length ≥ 1)
    (hlen : valid.val.length ≤ 2147483647) (hval : AllValid valid.val) :
    views.merge_ranges_loop1 n 1#i32 valid ⦃ r =>
      r.2.val.length = valid.val.length ∧
      AllValid r.2.val ∧
      r.2.val.Perm valid.val ∧
      SortedRanges r.2.val ⦄ := by
  unfold views.merge_ranges_loop1
  refine loop.spec_decr_nat (fun p => valid.val.length - p.1.val.toNat)
    (Loop1Inv valid.val) _ _ _ ?_ ?_
  · rintro ⟨i, v⟩ hI
    have hb := merge_loop1_body_spec n valid.val hn hlen (i, v) hI
    dsimp only at hb ⊢
    refine spec_mono hb ?_
    rintro (x | y) hr <;> exact hr
  · unfold Loop1Inv; dsimp only
    refine ⟨by simp, by simp; omega, rfl, hval, List.Perm.refl _, ?_⟩
    intro p q hp hq hpq hq1
    have h1v : (1#i32 : Std.I32).val = 1 := by simp
    omega

/-! ### Stage C: `merge_ranges_loop3` (coalesce sorted intervals) -/

def Loop3Inv (valid : Pion.Array views.ByteRange) (p : Std.I32 × Pion.Array views.ByteRange) : Prop :=
  1 ≤ p.1.val ∧ p.1.val ≤ valid.val.length ∧
  0 < p.2.val.length ∧ p.2.val.length ≤ p.1.val.toNat ∧
  AllValid p.2.val ∧
  DisjointSorted p.2.val ∧
  (∀ (m : Nat) (hm : m < valid.val.length), p.1.val.toNat ≤ m →
    ∀ hlast : p.2.val.length - 1 < p.2.val.length,
    (p.2.val[p.2.val.length - 1]'hlast).start.val ≤ (valid.val[m]'hm).start.val) ∧
  (∀ x : Int, InRanges x p.2.val ↔
    ∃ k : Nat, ∃ hk : k < valid.val.length, k < p.1.val.toNat ∧ InRange x (valid.val[k]'hk))

theorem merge_loop3_body_spec (n : Std.I32) (valid : Pion.Array views.ByteRange)
    (hn : n.val = valid.val.length) (hlen : valid.val.length ≤ 2147483647)
    (hval : AllValid valid.val) (hsort : SortedRanges valid.val)
    (p : Std.I32 × Pion.Array views.ByteRange) (hinv : Loop3Inv valid p) :
    views.merge_ranges_loop3.body n valid p.1 p.2 ⦃ r =>
      match r with
      | .done (_, out) =>
          out.val.length ≤ valid.val.length ∧
          AllValid out.val ∧
          DisjointSorted out.val ∧
          (∀ x : Int, InRanges x out.val ↔ InRanges x valid.val)
      | .cont p' =>
          Loop3Inv valid p' ∧
          (valid.val.length - p'.1.val.toNat) < (valid.val.length - p.1.val.toNat) ⦄ := by
  obtain ⟨i, out⟩ := p
  obtain ⟨hi1, hi2, hout0, hout_le, hout_val, hout_ds, hlast_le, hcov⟩ := hinv
  dsimp only at hi1 hi2 hout0 hout_le hout_val hout_ds hlast_le hcov ⊢
  unfold views.merge_ranges_loop3.body
  have h1v : (1#i32 : Std.I32).val = 1 := by simp
  by_cases hlt : i < n
  · have hlt' : i.val < valid.val.length := by
      have : i.val < n.val := hlt
      omega
    rw [ite_eq_left hlt]
    rw [arr_get_eq valid i (by omega) hlt', b_ok]
    set cur := valid.val[i.val.toNat]'(by omega)
    have hcur_v : ValidRange cur := hval cur (List.getElem_mem (by omega))
    obtain ⟨olen, holen_v, holen_eq⟩ := arr_len_eq out (by omega)
    rw [holen_eq, b_ok]
    have hli_v : (Pion.I32.sub olen 1#i32).val = out.val.length - 1 := by
      have := i32_sub_val olen 1#i32 (by omega) (by omega)
      rw [h1v] at this; omega
    have hli_nat : (Pion.I32.sub olen 1#i32).val.toNat = out.val.length - 1 := by omega
    dsimp only
    rw [arr_get_eq out (Pion.I32.sub olen 1#i32) (by omega) (by omega), b_ok]
    set last := out.val[(Pion.I32.sub olen 1#i32).val.toNat]'(by omega)
    have hlast_eq : last = out.val[out.val.length - 1]'(by omega) := by
      simp only [last, hli_nat]
    have hlast_v : ValidRange last := hout_val last (List.getElem_mem (by omega))
    have hlast_start_le : last.start.val ≤ cur.start.val := by
      rw [hlast_eq]
      exact hlast_le i.val.toNat (by omega) (le_refl _) (by omega)
    have hi_add : (Pion.I32.add i 1#i32).val = i.val + 1 := by
      have := i32_add_val i 1#i32 (by omega) (by omega)
      rw [h1v] at this; exact this
    by_cases hov : cur.start ≤ last.«end»
    · have hov' : cur.start.val ≤ last.«end».val := hov
      rw [ite_eq_left hov]
      set next_end := if cur.«end» > last.«end» then cur.«end» else last.«end»
      have hne_ge_cur : cur.«end».val ≤ next_end.val := by
        dsimp only [next_end]
        by_cases h : cur.«end» > last.«end»
        · rw [ite_eq_left h]
        · rw [ite_eq_right h]; have : ¬ cur.«end».val > last.«end».val := h; omega
      have hne_ge_last : last.«end».val ≤ next_end.val := by
        dsimp only [next_end]
        by_cases h : cur.«end» > last.«end»
        · rw [ite_eq_left h]; have : cur.«end».val > last.«end».val := h; omega
        · rw [ite_eq_right h]
      have hne_or : next_end = cur.«end» ∨ next_end = last.«end» := by
        dsimp only [next_end]
        by_cases h : cur.«end» > last.«end»
        · left; rw [ite_eq_left h]
        · right; rw [ite_eq_right h]
      rw [arr_set_eq out (Pion.I32.sub olen 1#i32) (views.ByteRange.mk last.start next_end)
        (by omega) (by omega), b_ok, b_ok, spec_ok]
      rw [hli_nat]
      unfold Loop3Inv; dsimp only
      refine ⟨⟨by omega, by omega, by simp only [List.length_set]; omega, by simp only [List.length_set]; omega, ?_, ?_, ?_, ?_⟩, by omega⟩
      · intro r hr
        rcases mem_of_mem_set hr with h | rfl
        · exact hout_val r h
        · unfold ValidRange; dsimp only; unfold ValidRange at hlast_v; omega
      · intro p q hp hq hpq
        have hne_p : out.val.length - 1 ≠ p := by simp at hq; omega
        simp only [List.getElem_set_ne hne_p]
        by_cases hq_last : q = out.val.length - 1
        · subst hq_last
          simp only [List.getElem_set_self]
          have := hout_ds p (out.val.length - 1) (by simp at hp; exact hp) (by omega) (by omega)
          rw [← hlast_eq] at this
          exact this
        · have hne_q : out.val.length - 1 ≠ q := by omega
          simp only [List.getElem_set_ne hne_q]
          exact hout_ds p q (by simp at hp; exact hp) (by simp at hq; exact hq) hpq
      · intro m hm hm_ge _hlast
        simp only [List.length_set, List.getElem_set_self]
        rw [hlast_eq]
        exact hlast_le m hm (by omega) (by omega)
      · intro x
        constructor
        · rintro ⟨r, hr, hxr⟩
          rcases mem_of_mem_set hr with hr' | rfl
          · obtain ⟨k, hkv, hk, hxk⟩ := (hcov x).mp ⟨r, hr', hxr⟩
            exact ⟨k, hkv, by omega, hxk⟩
          · unfold InRange at hxr; dsimp only at hxr
            by_cases hxl : x < last.«end».val
            · obtain ⟨k, hkv, hk, hxk⟩ := (hcov x).mp ⟨last, List.getElem_mem (by omega), ⟨hxr.1, hxl⟩⟩
              exact ⟨k, hkv, by omega, hxk⟩
            · rcases hne_or with heq | heq
              · rw [heq] at hxr
                refine ⟨i.val.toNat, by omega, by omega, ?_⟩
                change InRange x cur
                unfold InRange; omega
              · rw [heq] at hxr; omega
        · rintro ⟨k, hkv, hk, hxk⟩
          by_cases hki : k < i.val.toNat
          · obtain ⟨r, hr, hxr⟩ := (hcov x).mpr ⟨k, hkv, hki, hxk⟩
            obtain ⟨idx, hidx, rfl⟩ := List.getElem_of_mem hr
            by_cases hlast_idx : idx = out.val.length - 1
            · subst hlast_idx
              refine ⟨views.ByteRange.mk last.start next_end, ?_, ?_⟩
              · have hmem := List.getElem_mem (l := out.val.set (out.val.length - 1) (views.ByteRange.mk last.start next_end)) (n := out.val.length - 1) (by simp only [List.length_set]; omega)
                rwa [List.getElem_set_self (by simp only [List.length_set]; omega)] at hmem
              · rw [← hlast_eq] at hxr
                unfold InRange at hxr ⊢; dsimp only; omega
            · refine ⟨out.val[idx]'hidx, ?_, hxr⟩
              have hne : out.val.length - 1 ≠ idx := by omega
              have hmem := List.getElem_mem (l := out.val.set (out.val.length - 1) (views.ByteRange.mk last.start next_end)) (n := idx) (by simp only [List.length_set]; omega)
              rwa [List.getElem_set_ne hne (by simp only [List.length_set]; omega)] at hmem
          · have hkeq : k = i.val.toNat := by omega
            subst hkeq
            change InRange x cur at hxk
            refine ⟨views.ByteRange.mk last.start next_end, ?_, ?_⟩
            · have hmem := List.getElem_mem (l := out.val.set (out.val.length - 1) (views.ByteRange.mk last.start next_end)) (n := out.val.length - 1) (by simp only [List.length_set]; omega)
              rwa [List.getElem_set_self (by simp only [List.length_set]; omega)] at hmem
            · unfold InRange at hxk ⊢; dsimp only; omega
    · have hgt' : last.«end».val < cur.start.val := by
        have : ¬ cur.start.val ≤ last.«end».val := hov
        omega
      rw [ite_eq_right hov, b_ok, spec_ok]
      unfold Loop3Inv; dsimp only
      refine ⟨⟨by omega, by omega, by simp only [Pion.Array.push, List.length_append, List.length_singleton]; omega, by simp only [Pion.Array.push, List.length_append, List.length_singleton]; omega, ?_, ?_, ?_, ?_⟩, by omega⟩
      · intro r hr
        simp only [Pion.Array.push, List.mem_append, List.mem_singleton] at hr
        rcases hr with hr | rfl
        · exact hout_val r hr
        · exact hcur_v
      · intro p q hp hq hpq
        simp only [Pion.Array.push] at hp hq ⊢
        by_cases hq_new : q = out.val.length
        · subst hq_new
          have hp_lt : p < out.val.length := by omega
          rw [List.getElem_append_left hp_lt, List.getElem_append_right (le_refl _)]
          simp only [Nat.sub_self, List.getElem_cons_zero]
          by_cases hp_last : p = out.val.length - 1
          · subst hp_last
            rw [← hlast_eq]
            exact hgt'
          · have h1 := hout_ds p (out.val.length - 1) hp_lt (by omega) (by omega)
            rw [← hlast_eq] at h1
            unfold ValidRange at hlast_v
            omega
        · have hq_lt : q < out.val.length := by simp at hq; omega
          have hp_lt : p < out.val.length := by omega
          rw [List.getElem_append_left hp_lt, List.getElem_append_left hq_lt]
          exact hout_ds p q hp_lt hq_lt hpq
      · intro m hm hm_ge _hlast
        simp only [Pion.Array.push, List.length_append, List.length_singleton, Nat.add_sub_cancel]
        rw [List.getElem_append_right (le_refl _)]
        simp only [Nat.sub_self, List.getElem_cons_zero]
        have hle_m := hsort i.val.toNat m (by omega) hm (by omega)
        change RangeLe cur (valid.val[m]'hm) at hle_m
        unfold RangeLe at hle_m
        rcases hle_m with h1 | ⟨h1, _⟩ <;> omega
      · intro x
        simp only [InRanges, Pion.Array.push, List.mem_append, List.mem_singleton]
        constructor
        · rintro ⟨r, hr | rfl, hxr⟩
          · obtain ⟨k, hkv, hk, hxk⟩ := (hcov x).mp ⟨r, hr, hxr⟩
            exact ⟨k, hkv, by omega, hxk⟩
          · exact ⟨i.val.toNat, by omega, by omega, hxr⟩
        · rintro ⟨k, hkv, hk, hxk⟩
          by_cases hki : k < i.val.toNat
          · obtain ⟨r, hr, hxr⟩ := (hcov x).mpr ⟨k, hkv, hki, hxk⟩
            exact ⟨r, Or.inl hr, hxr⟩
          · have hkeq : k = i.val.toNat := by omega
            subst hkeq
            exact ⟨cur, Or.inr rfl, hxk⟩
  · have hge : ¬ i.val < n.val := hlt
    rw [ite_eq_right hlt, spec_ok]
    have hieq : i.val.toNat = valid.val.length := by omega
    refine ⟨by omega, hout_val, hout_ds, ?_⟩
    intro x
    rw [hcov x]
    constructor
    · rintro ⟨k, hkv, hk, hxk⟩
      exact ⟨valid.val[k]'hkv, List.getElem_mem hkv, hxk⟩
    · rintro ⟨r, hr, hxr⟩
      obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem hr
      exact ⟨k, hk, by omega, hxr⟩

theorem merge_loop3_spec (n : Std.I32) (valid : Pion.Array views.ByteRange)
    (hn : n.val = valid.val.length) (hne : valid.val.length ≥ 1)
    (hlen : valid.val.length ≤ 2147483647) (hval : AllValid valid.val)
    (hsort : SortedRanges valid.val) :
    views.merge_ranges_loop3 n valid 1#i32 (Pion.Array.ofList [valid.val[0]'(by omega)]) ⦃ r =>
      r.2.val.length ≤ valid.val.length ∧
      AllValid r.2.val ∧
      DisjointSorted r.2.val ∧
      (∀ x : Int, InRanges x r.2.val ↔ InRanges x valid.val) ⦄ := by
  unfold views.merge_ranges_loop3
  refine loop.spec_decr_nat (fun p => valid.val.length - p.1.val.toNat)
    (Loop3Inv valid) _ _ _ ?_ ?_
  · rintro ⟨i, out⟩ hI
    have hb := merge_loop3_body_spec n valid hn hlen hval hsort (i, out) hI
    dsimp only at hb ⊢
    refine spec_mono hb ?_
    rintro (x | y) hr <;> exact hr
  · unfold Loop3Inv; dsimp only
    refine ⟨by simp, by simp; omega, by simp [Pion.Array.ofList], by simp [Pion.Array.ofList], ?_, ?_, ?_, ?_⟩
    · intro r hr
      simp [Pion.Array.ofList] at hr
      subst hr
      exact hval _ (List.getElem_mem (by omega))
    · intro p q hp hq hpq
      simp [Pion.Array.ofList] at hq
      omega
    · intro m hm hm_ge _hlast
      simp only [Pion.Array.ofList, List.length_singleton, Nat.sub_self, List.getElem_cons_zero]
      have h1v : (1#i32 : Std.I32).val = 1 := by simp
      have h0m : 0 < m := by omega
      have hle := hsort 0 m (by omega) hm h0m
      unfold RangeLe at hle
      rcases hle with h1 | ⟨h1, _⟩ <;> omega
    · intro x
      have h1v : (1#i32 : Std.I32).val = 1 := by simp
      simp only [InRanges, Pion.Array.ofList, List.mem_singleton]
      constructor
      · rintro ⟨r, rfl, hxr⟩
        exact ⟨0, by omega, by omega, hxr⟩
      · rintro ⟨k, hkv, hk, hxk⟩
        have hk0 : k = 0 := by omega
        subst hk0
        exact ⟨valid.val[0]'(by omega), rfl, hxk⟩

/-- Full functional correctness of `merge_ranges`:
    produces valid, sorted, strictly disjoint half-open intervals covering the exact same bytes. -/
theorem merge_ranges_spec (ranges : Pion.Array views.ByteRange)
    (hlen : ranges.val.length ≤ 2147483647) :
    views.merge_ranges ranges ⦃ out =>
      out.val.length ≤ ranges.val.length ∧
      AllValid out.val ∧
      DisjointSorted out.val ∧
      (∀ x : Int, InRanges x out.val ↔ InRanges x ranges.val) ⦄ := by
  unfold views.merge_ranges
  dsimp only
  obtain ⟨n, hn, hneq⟩ := arr_len_eq ranges hlen
  rw [hneq, b_ok]
  refine spec_bind' (merge_loop0_spec n ranges hn hlen) ?_
  rintro ⟨i1, valid1⟩ ⟨hv1len, hv1val, hv1cov⟩
  dsimp only at hv1len hv1val hv1cov
  change (do
    let __t_3 ← Pion.Array.length valid1
    if __t_3 ≤ 1#i32 then ok valid1
    else
      let __t_4 ← Pion.Array.length valid1
      let (i_11, valid2) ← views.merge_ranges_loop1 __t_4 1#i32 valid1
      let __t_18 ← Pion.Array.get valid2 0#i32
      let out := (Pion.Array.ofList [__t_18] : Pion.Array views.ByteRange)
      let __t_19 ← Pion.Array.length valid2
      let (i_21, out1) ← views.merge_ranges_loop3 __t_19 valid2 1#i32 out
      ok out1) ⦃ _ ⦄
  obtain ⟨m, hm, hmeq⟩ := arr_len_eq valid1 (by omega)
  rw [hmeq, b_ok]
  by_cases hle1 : m ≤ 1#i32
  · have hle1' : valid1.val.length ≤ 1 := by
      have h1v : (1#i32 : Std.I32).val = 1 := by simp
      have : m.val ≤ (1#i32 : Std.I32).val := hle1
      omega
    rw [ite_eq_left hle1, spec_ok]
    refine ⟨hv1len, hv1val, ?_, hv1cov⟩
    intro p q hp hq hpq; omega
  · have hgt1 : valid1.val.length ≥ 2 := by
      have h1v : (1#i32 : Std.I32).val = 1 := by simp
      have : ¬ m.val ≤ (1#i32 : Std.I32).val := hle1
      omega
    rw [ite_eq_right hle1, b_ok]
    refine spec_bind' (merge_loop1_spec m valid1 hm (by omega) (by omega) hv1val) ?_
    rintro ⟨_, valid2⟩ ⟨hv2len, hv2val, hv2perm, hv2sort⟩
    dsimp only at hv2len hv2val hv2perm hv2sort
    change (do
      let __t_18 ← Pion.Array.get valid2 0#i32
      let out := (Pion.Array.ofList [__t_18] : Pion.Array views.ByteRange)
      let __t_19 ← Pion.Array.length valid2
      let (i_21, out1) ← views.merge_ranges_loop3 __t_19 valid2 1#i32 out
      ok out1) ⦃ _ ⦄
    rw [arr_get_eq valid2 0#i32 (by simp) (by simp; omega), b_ok]
    obtain ⟨m3, hm3, hm3eq⟩ := arr_len_eq valid2 (by omega)
    rw [hm3eq, b_ok]
    have h0_eq : (0#i32 : Std.I32).val.toNat = 0 := by simp
    simp only [h0_eq]
    refine spec_bind' (merge_loop3_spec m3 valid2 hm3 (by omega) (by omega) hv2val hv2sort) ?_
    rintro ⟨_, out1⟩ ⟨ho_len, ho_val, ho_ds, ho_cov⟩
    dsimp only at ho_len ho_val ho_ds ho_cov
    change ok out1 ⦃ _ ⦄
    rw [spec_ok]
    refine ⟨by omega, ho_val, ho_ds, ?_⟩
    intro x
    rw [ho_cov x, ← hv1cov x]
    unfold InRanges
    constructor
    · rintro ⟨r, hr, hxr⟩; exact ⟨r, hv2perm.subset hr, hxr⟩
    · rintro ⟨r, hr, hxr⟩; exact ⟨r, hv2perm.symm.subset hr, hxr⟩

/-! ### Stage D: `missing_ranges` (exact set difference `want \ covered`) -/

def MissingInv (merged : Pion.Array views.ByteRange) (want : views.ByteRange)
    (p : Std.I32 × Std.I64 × Pion.Array views.ByteRange) : Prop :=
  0 ≤ p.1.val ∧ p.1.val ≤ merged.val.length ∧
  want.start.val ≤ p.2.1.val ∧
  AllValid p.2.2.val ∧
  DisjointSorted p.2.2.val ∧
  (∀ r ∈ p.2.2.val, want.start.val ≤ r.start.val ∧ r.«end».val < p.2.1.val ∧ r.«end».val ≤ want.«end».val) ∧
  (∀ k : Nat, (hk : k < merged.val.length) → k < p.1.val.toNat → (merged.val[k]'hk).«end».val ≤ p.2.1.val) ∧
  (∀ x : Int, InRanges x p.2.2.val ↔
    (want.start.val ≤ x ∧ x < p.2.1.val ∧ x < want.«end».val ∧ ¬InRanges x merged.val))

def MissingDone (merged : Pion.Array views.ByteRange) (want : views.ByteRange)
    (p : Std.I32 × Std.I64 × Pion.Array views.ByteRange) : Prop :=
  want.start.val ≤ p.2.1.val ∧
  AllValid p.2.2.val ∧
  DisjointSorted p.2.2.val ∧
  (∀ r ∈ p.2.2.val, want.start.val ≤ r.start.val ∧ r.«end».val < p.2.1.val ∧ r.«end».val ≤ want.«end».val) ∧
  (∀ x : Int, InRanges x p.2.2.val ↔
    (want.start.val ≤ x ∧ x < p.2.1.val ∧ x < want.«end».val ∧ ¬InRanges x merged.val)) ∧
  (∀ x : Int, p.2.1.val ≤ x → x < want.«end».val → ¬InRanges x merged.val)

theorem missing_loop0_body_spec (n : Std.I32) (merged : Pion.Array views.ByteRange)
    (want : views.ByteRange)
    (hn : n.val = merged.val.length) (hlen : merged.val.length ≤ 2147483647)
    (hm_val : AllValid merged.val) (hm_ds : DisjointSorted merged.val)
    (p : Std.I32 × Std.I64 × Pion.Array views.ByteRange) (hinv : MissingInv merged want p) :
    views.missing_ranges_loop0.body n merged want p.1 p.2.1 p.2.2 ⦃ r =>
      match r with
      | .done res => MissingDone merged want res
      | .cont p' =>
          MissingInv merged want p' ∧
          (merged.val.length - p'.1.val.toNat) < (merged.val.length - p.1.val.toNat) ⦄ := by
  obtain ⟨i, cursor, out⟩ := p
  obtain ⟨hi0, hi1, hcur_ge, hout_val, hout_ds, hout_bnd, hprev_end, hcov⟩ := hinv
  dsimp only at hi0 hi1 hcur_ge hout_val hout_ds hout_bnd hprev_end hcov ⊢
  unfold views.missing_ranges_loop0.body
  have h1v : (1#i32 : Std.I32).val = 1 := by simp
  by_cases hlt : i < n
  · have hlt' : i.val < merged.val.length := by
      have : i.val < n.val := hlt
      omega
    rw [ite_eq_left hlt]
    rw [arr_get_eq merged i hi0 hlt', b_ok]
    set c := merged.val[i.val.toNat]'(by omega)
    have hc_v : ValidRange c := hm_val c (List.getElem_mem (by omega))
    have hi_add : (Pion.I32.add i 1#i32).val = i.val + 1 := by
      have := i32_add_val i 1#i32 (by omega) (by omega)
      rw [h1v] at this; exact this
    by_cases hce : c.«end» ≤ cursor
    · have hce' : c.«end».val ≤ cursor.val := hce
      rw [ite_eq_left hce, spec_ok]
      unfold MissingInv; dsimp only
      refine ⟨⟨by omega, by omega, hcur_ge, hout_val, hout_ds, hout_bnd, ?_, hcov⟩, by omega⟩
      intro k hkm hk
      by_cases hki : k < i.val.toNat
      · exact hprev_end k hkm hki
      · have hkeq : k = i.val.toNat := by omega
        subst hkeq; exact hce'
    · have hce' : cursor.val < c.«end».val := by
        have : ¬ c.«end».val ≤ cursor.val := hce
        omega
      rw [ite_eq_right hce]
      by_cases hcs_ge : c.start ≥ want.«end»
      · have hcs_ge' : want.«end».val ≤ c.start.val := hcs_ge
        rw [ite_eq_left hcs_ge, spec_ok]
        unfold MissingDone; dsimp only
        refine ⟨hcur_ge, hout_val, hout_ds, hout_bnd, hcov, ?_⟩
        intro x hx1 hx2 ⟨r, hr, hxr⟩
        obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem hr
        by_cases hki : k < i.val.toNat
        · have := hprev_end k hk hki
          unfold InRange at hxr; omega
        · by_cases hkeq : k = i.val.toNat
          · subst hkeq; change InRange x c at hxr; unfold InRange at hxr; omega
          · have hds := hm_ds i.val.toNat k (by omega) hk (by omega)
            change c.«end».val < (merged.val[k]'hk).start.val at hds
            unfold ValidRange at hc_v; unfold InRange at hxr; omega
      · have hcs_lt' : c.start.val < want.«end».val := by
          have : ¬ c.start.val ≥ want.«end».val := hcs_ge
          omega
        rw [ite_eq_right hcs_ge]
        have hcur_lt_end : c.«end» > cursor := hce'
        have hnone_between : ∀ x : Int, cursor.val ≤ x → x < c.start.val → ¬InRanges x merged.val := by
          intro x hx1 hx2 ⟨r, hr, hxr⟩
          obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem hr
          by_cases hki : k < i.val.toNat
          · have := hprev_end k hk hki; unfold InRange at hxr; omega
          · by_cases hkeq : k = i.val.toNat
            · subst hkeq; change InRange x c at hxr; unfold InRange at hxr; omega
            · have hds := hm_ds i.val.toNat k (by omega) hk (by omega)
              change c.«end».val < (merged.val[k]'hk).start.val at hds
              unfold ValidRange at hc_v; unfold InRange at hxr; omega
        have hstep_out : ∀ out1 : Pion.Array views.ByteRange,
            AllValid out1.val →
            DisjointSorted out1.val →
            (∀ r ∈ out1.val, want.start.val ≤ r.start.val ∧ r.«end».val < c.«end».val ∧ r.«end».val ≤ want.«end».val) →
            (∀ x : Int, InRanges x out1.val ↔
              (want.start.val ≤ x ∧ x < c.«end».val ∧ x < want.«end».val ∧ ¬InRanges x merged.val)) →
            (do
              let cursor1 ← (if c.«end» > cursor then ok c.«end» else ok cursor)
              if cursor1 ≥ want.«end» then
                (ok (done (i, cursor1, out1)) : Result (ControlFlow (Std.I32 × Std.I64 × Pion.Array views.ByteRange) (Std.I32 × Std.I64 × Pion.Array views.ByteRange)))
              else
                ok (cont (Pion.I32.add i 1#i32, cursor1, out1))) ⦃ r =>
              match r with
              | .done res => MissingDone merged want res
              | .cont p' =>
                  MissingInv merged want p' ∧
                  (merged.val.length - p'.1.val.toNat) < (merged.val.length - i.val.toNat) ⦄ := by
          intro out1 ho1v ho1ds ho1bnd ho1cov
          rw [ite_eq_left hcur_lt_end, b_ok]
          by_cases hce_end : c.«end» ≥ want.«end»
          · have hce_end' : want.«end».val ≤ c.«end».val := hce_end
            rw [ite_eq_left hce_end, spec_ok]
            unfold MissingDone; dsimp only
            refine ⟨by omega, ho1v, ho1ds, ho1bnd, ho1cov, ?_⟩
            intro x hx1 hx2; omega
          · rw [ite_eq_right hce_end, spec_ok]
            unfold MissingInv; dsimp only
            refine ⟨⟨by omega, by omega, by omega, ho1v, ho1ds, ho1bnd, ?_, ho1cov⟩, by omega⟩
            intro k hkm hk
            by_cases hki : k < i.val.toNat
            · have := hprev_end k hkm hki; omega
            · have hkeq : k = i.val.toNat := by omega
              subst hkeq; exact le_refl _
        by_cases hcs_gt : c.start > cursor
        · have hcs_gt' : cursor.val < c.start.val := hcs_gt
          rw [ite_eq_left hcs_gt, b_ok]
          refine hstep_out (Pion.Array.push out (views.ByteRange.mk cursor c.start)) ?_ ?_ ?_ ?_
          · intro r hr
            simp only [Pion.Array.push, List.mem_append, List.mem_singleton] at hr
            rcases hr with hr | rfl
            · exact hout_val r hr
            · exact hcs_gt'
          · intro p q hp hq hpq
            simp only [Pion.Array.push] at hp hq ⊢
            by_cases hq_new : q = out.val.length
            · subst hq_new
              have hp_lt : p < out.val.length := by omega
              rw [List.getElem_append_left hp_lt, List.getElem_append_right (le_refl _)]
              simp only [Nat.sub_self, List.getElem_cons_zero]
              exact (hout_bnd (out.val[p]'hp_lt) (List.getElem_mem hp_lt)).2.1
            · have hq_lt : q < out.val.length := by simp at hq; omega
              have hp_lt : p < out.val.length := by omega
              rw [List.getElem_append_left hp_lt, List.getElem_append_left hq_lt]
              exact hout_ds p q hp_lt hq_lt hpq
          · intro r hr
            simp only [Pion.Array.push, List.mem_append, List.mem_singleton] at hr
            rcases hr with hr | rfl
            · obtain ⟨h1, h2, h3⟩ := hout_bnd r hr
              exact ⟨h1, by omega, h3⟩
            · unfold ValidRange at hc_v; dsimp only; exact ⟨hcur_ge, hc_v, by omega⟩
          · intro x
            simp only [InRanges, Pion.Array.push, List.mem_append, List.mem_singleton]
            constructor
            · rintro ⟨r, hr | rfl, hxr⟩
              · obtain ⟨h1, h2, h3, h4⟩ := (hcov x).mp ⟨r, hr, hxr⟩
                exact ⟨h1, by omega, h3, h4⟩
              · unfold InRange at hxr; dsimp only at hxr
                unfold ValidRange at hc_v
                exact ⟨by omega, by omega, by omega, hnone_between x hxr.1 hxr.2⟩
            · intro ⟨h1, h2, h3, h4⟩
              by_cases hxc : x < cursor.val
              · obtain ⟨r, hr, hxr⟩ := (hcov x).mpr ⟨h1, hxc, h3, h4⟩
                exact ⟨r, Or.inl hr, hxr⟩
              · by_cases hxcs : x < c.start.val
                · exact ⟨views.ByteRange.mk cursor c.start, Or.inr rfl, by unfold InRange; dsimp only; omega⟩
                · exfalso
                  exact h4 ⟨c, List.getElem_mem (by omega), ⟨by omega, h2⟩⟩
        · have hcs_le' : c.start.val ≤ cursor.val := by
            have : ¬ c.start.val > cursor.val := hcs_gt
            omega
          rw [ite_eq_right hcs_gt, b_ok]
          refine hstep_out out hout_val hout_ds ?_ ?_
          · intro r hr
            obtain ⟨h1, h2, h3⟩ := hout_bnd r hr
            exact ⟨h1, by omega, h3⟩
          · intro x
            rw [hcov x]
            constructor
            · intro ⟨h1, h2, h3, h4⟩; exact ⟨h1, by omega, h3, h4⟩
            · intro ⟨h1, h2, h3, h4⟩
              by_cases hxc : x < cursor.val
              · exact ⟨h1, hxc, h3, h4⟩
              · exfalso
                exact h4 ⟨c, List.getElem_mem (by omega), ⟨by omega, h2⟩⟩
  · have hge : ¬ i.val < n.val := hlt
    rw [ite_eq_right hlt, spec_ok]
    have hieq : i.val.toNat = merged.val.length := by omega
    unfold MissingDone; dsimp only
    refine ⟨hcur_ge, hout_val, hout_ds, hout_bnd, hcov, ?_⟩
    intro x hx1 _ ⟨r, hr, hxr⟩
    obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem hr
    have := hprev_end k hk (by omega)
    unfold InRange at hxr; omega

theorem missing_loop0_spec (n : Std.I32) (merged : Pion.Array views.ByteRange)
    (want : views.ByteRange)
    (hn : n.val = merged.val.length) (hlen : merged.val.length ≤ 2147483647)
    (hm_val : AllValid merged.val) (hm_ds : DisjointSorted merged.val) :
    views.missing_ranges_loop0 n merged want 0#i32 want.start (Pion.Array.ofList []) ⦃ r =>
      MissingDone merged want r ⦄ := by
  unfold views.missing_ranges_loop0
  refine loop.spec_decr_nat (fun p => merged.val.length - p.1.val.toNat)
    (MissingInv merged want) _ _ _ ?_ ?_
  · rintro ⟨i, cursor, out⟩ hI
    have hb := missing_loop0_body_spec n merged want hn hlen hm_val hm_ds (i, cursor, out) hI
    dsimp only at hb ⊢
    refine spec_mono hb ?_
    rintro (x | y) hr <;> exact hr
  · unfold MissingInv; dsimp only
    refine ⟨by simp, by simp, le_refl _, ?_, ?_, ?_, ?_, ?_⟩
    · intro r hr; simp [Pion.Array.ofList] at hr
    · intro p q hp hq hpq; simp [Pion.Array.ofList] at hq
    · intro r hr; simp [Pion.Array.ofList] at hr
    · intro k _ hk; simp at hk
    · intro x
      simp only [InRanges, Pion.Array.ofList, List.not_mem_nil, false_and, exists_false, false_iff]
      intro ⟨h1, h2, _, _⟩; omega

/-- Full functional correctness of `missing_ranges`:
    outputs valid, sorted, strictly disjoint half-open sub-intervals contained in `want`,
    with zero overlap with `covered`, and covering the exact set difference `want \ covered`. -/
theorem missing_ranges_spec (want : views.ByteRange) (covered : Pion.Array views.ByteRange)
    (hlen : covered.val.length ≤ 2147483647) :
    views.missing_ranges want covered ⦃ out =>
      AllValid out.val ∧
      DisjointSorted out.val ∧
      (∀ r ∈ out.val, want.start.val ≤ r.start.val ∧ r.«end».val ≤ want.«end».val) ∧
      (∀ r ∈ out.val, ∀ c ∈ covered.val, ValidRange c → ¬Overlaps r c) ∧
      (∀ x : Int, InRanges x out.val ↔ (InRange x want ∧ ¬InRanges x covered.val)) ⦄ := by
  unfold views.missing_ranges
  by_cases hempty : want.«end» ≤ want.start
  · have hempty' : want.«end».val ≤ want.start.val := hempty
    rw [ite_eq_left hempty, spec_ok]
    refine ⟨?_, ?_, ?_, ?_, ?_⟩
    · intro r hr; simp [Pion.Array.ofList] at hr
    · intro p q hp hq hpq; simp [Pion.Array.ofList] at hq
    · intro r hr; simp [Pion.Array.ofList] at hr
    · intro r hr; simp [Pion.Array.ofList] at hr
    · intro x
      simp only [InRanges, Pion.Array.ofList, List.not_mem_nil, false_and, exists_false, false_iff]
      intro ⟨⟨h1, h2⟩, _⟩; omega
  · have hnonempty : want.start.val < want.«end».val := by
      have : ¬ want.«end».val ≤ want.start.val := hempty
      omega
    rw [ite_eq_right hempty]
    refine spec_bind' (merge_ranges_spec covered hlen) ?_
    intro merged ⟨hmlen, hm_val, hm_ds, hm_cov⟩
    obtain ⟨n, hn, hneq⟩ := arr_len_eq merged (by omega)
    rw [hneq, b_ok]
    refine spec_bind' (missing_loop0_spec n merged want hn (by omega) hm_val hm_ds) ?_
    rintro ⟨_, cursor1, out1⟩ ⟨hcur1_ge, ho1_val, ho1_ds, ho1_bnd, ho1_cov, ho1_tail⟩
    dsimp only at hcur1_ge ho1_val ho1_ds ho1_bnd ho1_cov ho1_tail
    change (if cursor1 < want.«end» then
      ok (Pion.Array.push out1 (views.ByteRange.mk cursor1 want.«end»))
    else
      ok out1) ⦃ _ ⦄
    have hno_ov : ∀ l : List views.ByteRange,
        AllValid l →
        (∀ x : Int, InRanges x l ↔ (InRange x want ∧ ¬InRanges x covered.val)) →
        (∀ r ∈ l, ∀ c ∈ covered.val, ValidRange c → ¬Overlaps r c) := by
      intro l hl_v hl_cov r hr c hc hcv hov
      have hrv := hl_v r hr
      unfold Overlaps at hov
      set x := max r.start.val c.start.val
      have hxr : InRange x r := ⟨le_max_left _ _, max_lt hrv hov.2⟩
      have hxc : InRange x c := ⟨le_max_right _ _, max_lt hov.1 hcv⟩
      have hnot := ((hl_cov x).mp ⟨r, hr, hxr⟩).2
      exact hnot ⟨c, hc, hxc⟩
    by_cases htail : cursor1 < want.«end»
    · have htail' : cursor1.val < want.«end».val := htail
      simp only [htail, ↓reduceIte, spec_ok]
      have hfinal_val : AllValid (Pion.Array.push out1 (views.ByteRange.mk cursor1 want.«end»)).val := by
        intro r hr
        simp only [Pion.Array.push, List.mem_append, List.mem_singleton] at hr
        rcases hr with hr | rfl
        · exact ho1_val r hr
        · exact htail'
      have hfinal_cov : ∀ x : Int,
          InRanges x (Pion.Array.push out1 (views.ByteRange.mk cursor1 want.«end»)).val ↔
          (InRange x want ∧ ¬InRanges x covered.val) := by
        intro x
        rw [← hm_cov x]
        simp only [InRanges, Pion.Array.push, List.mem_append, List.mem_singleton]
        constructor
        · rintro ⟨r, hr | rfl, hxr⟩
          · obtain ⟨h1, _, h3, h4⟩ := (ho1_cov x).mp ⟨r, hr, hxr⟩
            exact ⟨⟨h1, h3⟩, h4⟩
          · unfold InRange at hxr; dsimp only at hxr
            exact ⟨⟨by omega, hxr.2⟩, ho1_tail x hxr.1 hxr.2⟩
        · intro ⟨⟨h1, h2⟩, h3⟩
          by_cases hxc : x < cursor1.val
          · obtain ⟨r, hr, hxr⟩ := (ho1_cov x).mpr ⟨h1, hxc, h2, h3⟩
            exact ⟨r, Or.inl hr, hxr⟩
          · exact ⟨views.ByteRange.mk cursor1 want.«end», Or.inr rfl, by unfold InRange; dsimp only; omega⟩
      refine ⟨hfinal_val, ?_, ?_, hno_ov _ hfinal_val hfinal_cov, hfinal_cov⟩
      · intro p q hp hq hpq
        simp only [Pion.Array.push] at hp hq ⊢
        by_cases hq_new : q = out1.val.length
        · subst hq_new
          have hp_lt : p < out1.val.length := by omega
          rw [List.getElem_append_left hp_lt, List.getElem_append_right (le_refl _)]
          simp only [Nat.sub_self, List.getElem_cons_zero]
          exact (ho1_bnd (out1.val[p]'hp_lt) (List.getElem_mem hp_lt)).2.1
        · have hq_lt : q < out1.val.length := by simp at hq; omega
          have hp_lt : p < out1.val.length := by omega
          rw [List.getElem_append_left hp_lt, List.getElem_append_left hq_lt]
          exact ho1_ds p q hp_lt hq_lt hpq
      · intro r hr
        simp only [Pion.Array.push, List.mem_append, List.mem_singleton] at hr
        rcases hr with hr | rfl
        · obtain ⟨h1, _, h3⟩ := ho1_bnd r hr; exact ⟨h1, h3⟩
        · exact ⟨hcur1_ge, le_refl _⟩
    · have htail' : want.«end».val ≤ cursor1.val := by
        have : ¬ cursor1.val < want.«end».val := htail
        omega
      simp only [htail, ↓reduceIte, spec_ok]
      have hfinal_cov : ∀ x : Int, InRanges x out1.val ↔ (InRange x want ∧ ¬InRanges x covered.val) := by
        intro x
        rw [ho1_cov x, ← hm_cov x]
        unfold InRange
        constructor
        · intro ⟨h1, _, h3, h4⟩; exact ⟨⟨h1, h3⟩, h4⟩
        · intro ⟨⟨h1, h2⟩, h3⟩; exact ⟨h1, by omega, h2, h3⟩
      refine ⟨ho1_val, ho1_ds, ?_, hno_ov _ ho1_val hfinal_cov, hfinal_cov⟩
      intro r hr
      obtain ⟨h1, _, h3⟩ := ho1_bnd r hr
      exact ⟨h1, h3⟩

end RulesProofs.CoreInvariantsP
