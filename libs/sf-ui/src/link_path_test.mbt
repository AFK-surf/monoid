///|
test "the file a link names on the agent's machine" {
  assert_eq(@sf.local_path_of_link("file:///w/ledger.md"), Some("/w/ledger.md"))
  assert_eq(@sf.local_path_of_link("file://localhost/w/a%20b.md#L3"), Some("/w/a b.md"))
  assert_eq(@sf.local_path_of_link("file:///C:/w/a.md"), Some("C:/w/a.md"))
  assert_eq(@sf.local_path_of_link("docs/plan.md#top"), Some("docs/plan.md"))
  assert_eq(@sf.local_path_of_link("/w/plan.md"), Some("/w/plan.md"))
  assert_eq(@sf.local_path_of_link("C:/w/plan.md"), Some("C:/w/plan.md"))
  assert_eq(@sf.local_path_of_link("https://example.com/a.md"), None)
  assert_eq(@sf.local_path_of_link("mailto:a@example.com"), None)
  assert_eq(@sf.local_path_of_link("#part"), None)
  assert_eq(@sf.local_path_of_link("//example.com/a"), None)
}
