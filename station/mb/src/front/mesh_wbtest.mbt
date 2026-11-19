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
