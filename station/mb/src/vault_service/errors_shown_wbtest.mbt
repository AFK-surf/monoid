///|
/// An error as it is said where it is shown (a notice, a log): its words, never its package and type.
fn shown_words(e : Error) -> String raise {
  let said = "\{e}"
  assert_false(said.contains("station/"))
  said
}

///|
test "the vault's errors are said as words" {
  assert_eq(shown_words(WriteBusy), "the store's writer is busy: the message is tried again after a pause")
  assert_eq(shown_words(DecisionCardMoved), "the decision's card moved meanwhile")
}
