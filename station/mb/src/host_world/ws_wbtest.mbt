///|
test "a socket's end says the Close frame's code and reason where the shell gave them, else 1005" {
  assert_eq(ws_close_of({ "end": true, "code": 4000, "reason": "replaced" }), (4000, "replaced"))
  assert_eq(ws_close_of({ "end": true, "code": 4004, "reason": "removed" }), (4004, "removed"))
  assert_eq(ws_close_of({ "end": true, "code": 1000 }), (1000, ""))
  assert_eq(ws_close_of({ "end": true }), (1005, ""))
}
