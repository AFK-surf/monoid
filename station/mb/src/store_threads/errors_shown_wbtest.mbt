///|
/// An error as it is said where it is shown (a notice, a log): its words, never its package and type.
fn shown_words(e : Error) -> String raise {
  let said = "\{e}"
  assert_false(said.contains("station/"))
  said
}

///|
test "the store's errors are said as words" {
  assert_eq(shown_words(StoreError("database is locked")), "database is locked")
  assert_eq(shown_words(MessageWriteBusy), "another connection writes: the message was not written, and is tried again")
  assert_eq(shown_words(SessionChatUnavailable), "session chat is still being prepared")
  assert_eq(shown_words(DecisionSessionsUnavailable), "decision session lookup is not ready")
  assert_eq(shown_words(CcSessionsUnavailable(["s1"])), "copy destinations are still being prepared")
  assert_eq(shown_words(Stale), "the outbox's entry is stale")
  assert_eq(shown_words(Aborted), "the worker was closed while a scan read")
}
