///|
test "an endpoint that gives no more connections ends the front only where it is the one bound now" {
  let bound : Json = 7
  // The endpoint bound now ends: unbidden, the front ends for the launcher to start another.
  assert_true(accept_ended_unbidden(Some(bound), 7))
  // One let go after another was bound in its place (`Mesh::bind` binds the new before it lets the old go): quiet.
  assert_false(accept_ended_unbidden(Some(bound), 6))
  // One let go with none bound in its place yet (a fixed port, let go before the next is bound): quiet.
  assert_false(accept_ended_unbidden(None, 7))
}

///|
test "a bind with another key never takes the endpoint the station's key holds" {
  let bound : Json = 7
  // Another key while one is bound: refused (a process that inherited the front's socket, with a key of its own).
  assert_true(foreign_key_bind(Some(bound), "aa", "bb"))
  // The same key (a handover's next Node, or its options changed): bound as before.
  assert_false(foreign_key_bind(Some(bound), "aa", "aa"))
  // None bound yet, or none since the front started: the first key binds.
  assert_false(foreign_key_bind(None, "aa", "bb"))
  assert_false(foreign_key_bind(None, "", "bb"))
  assert_false(foreign_key_bind(Some(bound), "", "bb"))
}
