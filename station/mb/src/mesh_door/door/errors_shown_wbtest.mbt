///|
/// An error as it is said where it is shown (a notice, a log): its words, never its package and type.
fn shown_words(e : Error) -> String raise {
  let said = "\{e}"
  assert_false(said.contains("station/"))
  said
}

///|
test "the door's errors are said as words" {
  assert_eq(shown_words(ending("credential expired", 4001, "expired")), "credential expired")
  assert_eq(shown_words(DoorError("hello refused")), "hello refused")
  assert_eq(shown_words(WireError("line too long")), "line too long")
}
