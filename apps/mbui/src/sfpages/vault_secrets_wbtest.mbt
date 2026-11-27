///|
test "clear_vault_ui_secrets clears only V1 VaultInstance and standalone editors while keeping V2 intact" {
  vault_dialogs_reset()
  recovery_words.clear()
  recovery_words["wsA"] = ["alpha", "beta"]
  recovery_words["wsB"] = ["gamma", "delta"]
  let inv_v1 : Ref[Bool] = Ref(false)
  let inv_v2 : Ref[Bool] = Ref(false)
  let s1 : @settings.VaultScope = {
    account: "acc1",
    workspace: "wsA",
    vault: "v1",
    item: "item-v1",
    vault_gen: @settings.vault_gen_of("wsA", "v1"),
    stay_id: 1,
  }
  let s2 : @settings.VaultScope = {
    account: "acc1",
    workspace: "wsA",
    vault: "v2",
    item: "item-v2",
    vault_gen: @settings.vault_gen_of("wsA", "v2"),
    stay_id: 2,
  }
  let id1 = @settings.vault_instance_new(s1, on_invalidate=fn() { inv_v1.val = true })
  let id2 = @settings.vault_instance_new(s2, on_invalidate=fn() { inv_v2.val = true })
  @settings.item_field_set_shown(id1, "value", true)
  @settings.item_field_set_shown(id2, "value", true)
  let f1 = @ui.Field::new(text="secret-v1")
  let f2 = @ui.Field::new(text="secret-v2")
  let closed_v1 : Ref[Bool] = Ref(false)
  let closed_v2 : Ref[Bool] = Ref(false)
  active_vault_editors[1] = (
    "wsA",
    fn() { "v1" },
    fn() {
      f1.set("")
      closed_v1.val = true
    },
  )
  active_vault_editors[2] = (
    "wsA",
    fn() { "v2" },
    fn() {
      f2.set("")
      closed_v2.val = true
    },
  )
  // Locking V1 invalidates V1's VaultInstance and standalone editor/about dialogs without touching V2 or workspace recovery_words
  clear_vault_ui_secrets("wsA", "v1")
  assert_true(inv_v1.val)
  assert_false(@settings.item_field_shown(id1, "value"))
  assert_eq(f1.text(), "")
  assert_true(closed_v1.val)
  assert_false(inv_v2.val)
  assert_true(@settings.item_field_shown(id2, "value"))
  assert_eq(f2.text(), "secret-v2")
  assert_false(closed_v2.val)
  assert_true(recovery_words.contains("wsA"))
  assert_true(recovery_words.contains("wsB"))
  // Workspace-scoped clear invalidates wsA V2 and wsA recovery_words, leaving wsB intact
  clear_vault_ui_secrets("wsA", "")
  assert_true(inv_v2.val)
  assert_false(@settings.item_field_shown(id2, "value"))
  assert_eq(f2.text(), "")
  assert_true(closed_v2.val)
  assert_false(recovery_words.contains("wsA"))
  assert_true(recovery_words.contains("wsB"))
  // Global clear wipes wsB recovery_words too
  clear_vault_ui_secrets("", "")
  assert_false(recovery_words.contains("wsB"))
  @settings.vault_instance_dispose(id1)
  @settings.vault_instance_dispose(id2)
}
