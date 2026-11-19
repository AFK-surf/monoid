///|
/// An error as it is said where it is shown (a notice, a log): its words, never its package and type.
fn shown_words(e : Error) -> String raise {
  let said = "\{e}"
  assert_false(said.contains("station/"))
  said
}

///|
test "a refused request is said as its message" {
  assert_eq(shown_words(Refused(403, "only an admin may")), "only an admin may")
  assert_eq(shown_words(Moved("the chat moved", Null)), "the chat moved")
  assert_eq(shown_words(DriveErr("not_found", "no such file")), "no such file")
}
