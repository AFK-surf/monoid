/-
Axiom audit for every theorem in `RulesProofs`.
`pion/rules/scripts/prove-lean.sh` runs `lake env lean RulesProofs/CheckAxioms.lean`
and rejects any axiom outside `{propext, Classical.choice, Quot.sound}`.
-/
import RulesProofs.ForkProofs
import RulesProofs.HistoryProofs
import RulesProofs.RoleProofs
import RulesProofs.CoreInvariantsProofs

-- ForkProofs
#print axioms RulesProofs.ForkP.ahead_eq_ok
#print axioms RulesProofs.ForkP.aheadBool_iff
#print axioms RulesProofs.ForkP.ahead_itself
#print axioms RulesProofs.ForkP.aheadBool_asym
#print axioms RulesProofs.ForkP.ahead_both
#print axioms RulesProofs.ForkP.aheadBool_trans
#print axioms RulesProofs.ForkP.ahead_through
#print axioms RulesProofs.ForkP.aheadBool_total
#print axioms RulesProofs.ForkP.ahead_either
#print axioms RulesProofs.ForkP.step_isSome_iff_ahead
#print axioms RulesProofs.ForkP.best_loop0_body_spec
#print axioms RulesProofs.ForkP.best_chosen
#print axioms RulesProofs.ForkP.same_choice

-- HistoryProofs
#print axioms RulesProofs.HistoryP.follows_post
#print axioms RulesProofs.HistoryP.follows_sound
#print axioms RulesProofs.HistoryP.follows_complete
#print axioms RulesProofs.HistoryP.epoch_post
#print axioms RulesProofs.HistoryP.epoch_sound
#print axioms RulesProofs.HistoryP.epoch_complete
#print axioms RulesProofs.HistoryP.deletion_post
#print axioms RulesProofs.HistoryP.deletion_sound
#print axioms RulesProofs.HistoryP.deletion_complete
#print axioms RulesProofs.HistoryP.deletion_irreversible
#print axioms RulesProofs.HistoryP.item_epoch_post
#print axioms RulesProofs.HistoryP.item_epoch_sound
#print axioms RulesProofs.HistoryP.item_epoch_complete
#print axioms RulesProofs.HistoryP.unexpired_post
#print axioms RulesProofs.HistoryP.unexpired_sound
#print axioms RulesProofs.HistoryP.unexpired_complete
#print axioms RulesProofs.HistoryP.supersedes_post
#print axioms RulesProofs.HistoryP.supersedes_sound
#print axioms RulesProofs.HistoryP.supersedes_complete
#print axioms RulesProofs.HistoryP.supersedes_asymmetric
#print axioms RulesProofs.HistoryP.supersedes_total
#print axioms RulesProofs.HistoryP.item_open_post
#print axioms RulesProofs.HistoryP.item_open_sound
#print axioms RulesProofs.HistoryP.item_open_complete

-- RoleProofs
#print axioms RulesProofs.RoleP.rank_spec
#print axioms RulesProofs.RoleP.one_if_spec
#print axioms RulesProofs.RoleP.lower_post
#print axioms RulesProofs.RoleP.may_post
#print axioms RulesProofs.RoleP.may_sound
#print axioms RulesProofs.RoleP.may_complete
#print axioms RulesProofs.RoleP.own_post
#print axioms RulesProofs.RoleP.own_sound
#print axioms RulesProofs.RoleP.own_complete
#print axioms RulesProofs.RoleP.own_no_impersonation
#print axioms RulesProofs.RoleP.keeps_post
#print axioms RulesProofs.RoleP.keeps_sound
#print axioms RulesProofs.RoleP.keeps_complete
#print axioms RulesProofs.RoleP.effect_post
#print axioms RulesProofs.RoleP.replaces_post
#print axioms RulesProofs.RoleP.admission_post
#print axioms RulesProofs.RoleP.device_signs_post
#print axioms RulesProofs.RoleP.signed_by_post
#print axioms RulesProofs.RoleP.cert_device_post
#print axioms RulesProofs.RoleP.cert_key_post
#print axioms RulesProofs.RoleP.key_post
#print axioms RulesProofs.RoleP.binds_post
#print axioms RulesProofs.RoleP.person_changes_post
#print axioms RulesProofs.RoleP.person_admits_post

-- CoreInvariantsProofs
#print axioms RulesProofs.CoreInvariantsP.role_rank_eq
#print axioms RulesProofs.CoreInvariantsP.roleRankI32_val
#print axioms RulesProofs.CoreInvariantsP.lower_role_av_spec
#print axioms RulesProofs.CoreInvariantsP.admit_member_role_spec
#print axioms RulesProofs.CoreInvariantsP.admit_member_role_le_cloud
#print axioms RulesProofs.CoreInvariantsP.admit_member_role_default_le_member
#print axioms RulesProofs.CoreInvariantsP.admit_member_role_by_actor_non_manager
#print axioms RulesProofs.CoreInvariantsP.admit_member_role_by_actor_spec
#print axioms RulesProofs.CoreInvariantsP.scope_rank_vc_eq
#print axioms RulesProofs.CoreInvariantsP.scopeRankI32_val
#print axioms RulesProofs.CoreInvariantsP.vault_allows_scope_spec
#print axioms RulesProofs.CoreInvariantsP.vault_allows_scope_once_rejects_hour
#print axioms RulesProofs.CoreInvariantsP.vault_allows_scope_once_rejects_chat
#print axioms RulesProofs.CoreInvariantsP.vault_allows_scope_hour_rejects_chat
#print axioms RulesProofs.CoreInvariantsP.vault_allows_scope_chat_allows_all
#print axioms RulesProofs.CoreInvariantsP.byteRange_overlaps_spec
#print axioms RulesProofs.CoreInvariantsP.merge_loop0_spec
#print axioms RulesProofs.CoreInvariantsP.merge_loop2_spec
#print axioms RulesProofs.CoreInvariantsP.merge_loop1_spec
#print axioms RulesProofs.CoreInvariantsP.merge_loop3_spec
#print axioms RulesProofs.CoreInvariantsP.merge_ranges_spec
#print axioms RulesProofs.CoreInvariantsP.missing_loop0_spec
#print axioms RulesProofs.CoreInvariantsP.missing_ranges_spec
