// What a member's device is given and kept on (leaf.mbt): no peers before this station's own descriptor is among
// them, and a ping with the same credential or its renewal never takes back an attachment.

///|
fn descriptor_at(byte : Int) -> Json {
  { "binding": { "endpoint": Json::array(Array::make(32, Json::number(byte.to_double()))) } }
}

///|
test "a device is given no peers until this station's own descriptor is among them" {
  let own = "41".repeat(32)
  let other = descriptor_at(0x42)
  assert_eq(leaf_peers([], own).length(), 0)
  assert_eq(leaf_peers([other], own).length(), 0)
  assert_eq(leaf_peers([other, descriptor_at(0x41)], own).length(), 2)
}

///|
test "a ping or a renewal while an attachment is made keeps it; another workspace or a shorter credential does not" {
  assert_true(still_admitted("w", 9L, "w", 9L))
  assert_true(still_admitted("w", 309L, "w", 9L))
  assert_false(still_admitted("w2", 9L, "w", 9L))
  assert_false(still_admitted("w", 8L, "w", 9L))
}
