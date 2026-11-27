///|
test "clear_opened_secrets clears only locked V1 instance while keeping V2 plaintext intact" {
  vault_instances_reset()
  let inv1 : Ref[Bool] = Ref(false)
  let inv2 : Ref[Bool] = Ref(false)
  let s1 : VaultScope = { account: "acc1", workspace: "wsA", vault: "v1", item: "item-v1", vault_gen: vault_gen_of("wsA", "v1"), stay_id: 1 }
  let s2 : VaultScope = { account: "acc1", workspace: "wsA", vault: "v2", item: "item-v2", vault_gen: vault_gen_of("wsA", "v2"), stay_id: 2 }
  let id1 = vault_instance_new(s1, on_invalidate=fn() { inv1.val = true })
  let id2 = vault_instance_new(s2, on_invalidate=fn() { inv2.val = true })
  let inst1 = vault_instances.instances.get(id1).unwrap()
  let inst2 = vault_instances.instances.get(id2).unwrap()
  inst1.plain.set(Some({ "secret": "s1" }))
  inst1.fields.set([{ "key": "token", "value": "s1" }])
  inst1.shown.set("token", true)
  inst2.plain.set(Some({ "secret": "s2" }))
  inst2.fields.set([{ "key": "token", "value": "s2" }])
  inst2.shown.set("token", true)
  // Locking V1 clears V1's plaintext, fields, shown flags, and runs on_invalidate without touching V2
  clear_opened_secrets(ws="wsA", vault="v1")
  assert_true(opened_plain(id1) is None)
  assert_eq(opened_fields(id1).length(), 0)
  assert_false(item_field_shown(id1, "token"))
  assert_true(inv1.val)
  assert_true(opened_plain(id2) is Some(_))
  assert_eq(opened_fields(id2).length(), 1)
  assert_true(item_field_shown(id2, "token"))
  assert_false(inv2.val)
  // Global / VaultAll clears all remaining opened secrets
  clear_opened_secrets()
  assert_true(opened_plain(id2) is None)
  assert_eq(opened_fields(id2).length(), 0)
  assert_false(item_field_shown(id2, "token"))
  assert_true(inv2.val)
  vault_instance_dispose(id1)
  vault_instance_dispose(id2)
}
