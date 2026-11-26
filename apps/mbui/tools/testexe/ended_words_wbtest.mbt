///|
test "a long native stack leaves the halt's words and source in the failure summary" {
  let reason = "the selected tab should be visible"
  let source = "  at tabs_test.mbt:4:3-4:22@example"
  let stack = Array::makei(15, fn(i) { "    at frame\{i} (???:0)" })
  let noise = Array::makei(20, fn(i) { "step \{i}" })
  let halt = [reason, source, reason, "PanicError"]
  let end = ["    ...", "Aborted (core dumped)"]
  let detail = ended_words(noise + halt + stack + end)
  assert_eq(detail.length(), 12)
  assert_eq(detail[2:].to_owned(), halt + stack[:4].to_owned() + end)
}

///|
test "a short stack stays whole and ordinary long output keeps its final lines" {
  let stack = Array::makei(6, fn(i) { "    at frame\{i}" })
  let short = ["the tab is missing", "PanicError"] + stack
  assert_eq(ended_words(short), short)
  let ordinary = Array::makei(20, fn(i) { "    at step \{i}" })
  assert_eq(ended_words(ordinary), ordinary[8:].to_owned())
}
