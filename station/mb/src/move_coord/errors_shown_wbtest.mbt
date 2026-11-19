///|
/// An error as it is said where it is shown (a notice, a log): its words, never its package and type.
fn shown_words(e : Error) -> String raise {
  let said = "\{e}"
  assert_false(said.contains("station/"))
  said
}

///|
test "a move's errors are said as their words" {
  assert_eq(shown_words(PeerGone("the other station went")), "the other station went")
  assert_eq(shown_words(Said("move.busy")), "move.busy")
}
