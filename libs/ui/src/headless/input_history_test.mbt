// Tests for headless InputHistory: push filtering/dedup/eviction, prev/next draft restoration, and zero-draw window wiring.

///|
test "InputHistory: ignores blank, deduplicates consecutive, evicts oldest past max_entries" {
  let h = @headless.InputHistory::new(max_entries=3)
  h.push("")
  h.push("   \t\n  ")
  assert_eq(h.entries(), [])
  h.push("first")
  h.push("first")
  h.push("second")
  h.push("first")
  assert_eq(h.entries(), ["first", "second", "first"])
  // Pushing 4th evicts oldest ("first")
  h.push("third")
  assert_eq(h.entries(), ["second", "first", "third"])
}

///|
test "InputHistory: prev saves draft, traverses history, next restores draft at bottom" {
  let h = @headless.InputHistory::new()
  assert_eq(h.prev("draft"), None)
  assert_eq(h.next(), None)
  assert_eq(h.at_history(), false)

  h.push("cmd 1")
  h.push("cmd 2")
  h.push("cmd 3")

  // First prev saves draft and returns newest
  assert_eq(h.prev("typing..."), Some("cmd 3"))
  assert_eq(h.at_history(), true)
  assert_eq(h.prev("ignored"), Some("cmd 2"))
  assert_eq(h.prev("ignored"), Some("cmd 1"))
  // Already at oldest
  assert_eq(h.prev("ignored"), None)

  // Step forward back to draft
  assert_eq(h.next(), Some("cmd 2"))
  assert_eq(h.next(), Some("cmd 3"))
  assert_eq(h.next(), Some("typing..."))
  assert_eq(h.at_history(), false)
  assert_eq(h.next(), None)

  // reset_cursor exits history browsing
  assert_eq(h.prev("wip"), Some("cmd 3"))
  h.reset_cursor()
  assert_eq((h.at_history(), h.next()), (false, None))
}

///|
test "InputHistory wired to a node with Up/Down keys obeys zero-draw" {
  let h = @headless.InputHistory::new()
  h.push("ls")
  h.push("pwd")
  let text = @signals.signal("echo")
  let t = window(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(160.0)))
      .height(Is(Some(32.0)))
      .ground(Is(c_rest))
      .presses(Is(true))
      .focusable(Is(true), keys=0)
      .says(By(fn() { Some(@view.said(TextField, label="命令", value=text.get())) }))
      .on_key(fn(k) {
        if k.code == @ui.key_code_up {
          if h.prev(text.untracked()) is Some(s) {
            text.set(s)
          }
          true
        } else if k.code == @ui.key_code_down {
          if h.next() is Some(s) {
            text.set(s)
          }
          true
        } else {
          false
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.act(TextField, Focus, label="命令")
  t.key(@ui.key_code_up)
  let s1 = t.get(TextField, label="命令").value
  t.key(@ui.key_code_up)
  let s2 = t.get(TextField, label="命令").value
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_down)
  let s3 = t.get(TextField, label="命令").value
  assert_eq((s1, s2, s3), ("pwd", "ls", "echo"))
}
