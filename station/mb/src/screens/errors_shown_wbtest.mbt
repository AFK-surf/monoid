///|
/// An error as it is said where it is shown (a notice, a log): its words, never its package and type.
fn shown_words(e : Error) -> String raise {
  let said = "\{e}"
  assert_false(said.contains("station/"))
  said
}

///|
test "the screens' errors are said as words" {
  assert_eq(shown_words(GrantRefused("station.screens.grant.busy")), "station.screens.grant.busy")
  assert_eq(shown_words(Failed("no display", Null)), "no display")
  assert_eq(shown_words(FsFailed("ENOENT: no such file", "ENOENT")), "ENOENT: no such file")
}
