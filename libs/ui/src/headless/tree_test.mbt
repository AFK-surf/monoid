// Hierarchical tree control (`@headless.tree`, `Tree::item`) and tri-state cascade check logic
// (`@headless.tree_checked_states`, `@headless.toggle_tree_check`), under `window` (window_test.mbt) so zero-draw is
// enforced.

///|
fn tr_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
test "tree_checked_states & toggle_tree_check: Cascade aggregates enabled leaves and skips disabled; Independent toggles alone" {
  let nodes : Array[@headless.TreeCheckNode[String]] = [
    { key: "root", children: ["a", "b"], disabled: false },
    { key: "a", children: ["a1", "a2", "a3"], disabled: false },
    { key: "a1", children: [], disabled: false },
    { key: "a2", children: [], disabled: false },
    { key: "a3", children: [], disabled: true },
    { key: "b", children: [], disabled: false },
  ]
  // Only a1 checked -> a is Indeterminate, root is Indeterminate, a3 (disabled) ignored
  let s1 = @headless.tree_checked_states(nodes, ["a1"])
  // Toggle parent "a" -> checks remaining enabled leaf a2 (skips disabled a3) -> a becomes Checked, root Indeterminate
  let c2 = @headless.toggle_tree_check(nodes, ["a1"], "a")
  let s2 = @headless.tree_checked_states(nodes, c2)
  // Toggle disabled leaf "a3" -> no-op
  let c_noop = @headless.toggle_tree_check(nodes, c2, "a3")
  // Toggle "root" -> checks all enabled leaves (a1, a2, b) -> root Checked
  let c3 = @headless.toggle_tree_check(nodes, c2, "root")
  let s3 = @headless.tree_checked_states(nodes, c3)
  // Toggle "root" again -> unchecks all enabled leaves -> all Unchecked
  let c4 = @headless.toggle_tree_check(nodes, c3, "root")
  let s4 = @headless.tree_checked_states(nodes, c4)
  // Independent mode: toggling "a" checks only "a"
  let ci = @headless.toggle_tree_check(nodes, [], "a", strategy=Independent)
  let si = @headless.tree_checked_states(nodes, ci, strategy=Independent)
  assert_eq(
    (s1, c2, s2, c_noop == c2, s3, c4, s4, ci, si),
    (
      [
        ("root", Indeterminate),
        ("a", Indeterminate),
        ("a1", Checked),
        ("a2", Unchecked),
        ("a3", Unchecked),
        ("b", Unchecked),
      ],
      ["a1", "a2"],
      [
        ("root", Indeterminate),
        ("a", Checked),
        ("a1", Checked),
        ("a2", Checked),
        ("a3", Unchecked),
        ("b", Unchecked),
      ],
      true,
      [
        ("root", Checked),
        ("a", Checked),
        ("a1", Checked),
        ("a2", Checked),
        ("a3", Unchecked),
        ("b", Checked),
      ],
      [],
      [
        ("root", Unchecked),
        ("a", Unchecked),
        ("a1", Unchecked),
        ("a2", Unchecked),
        ("a3", Unchecked),
        ("b", Unchecked),
      ],
      ["a"],
      [
        ("root", Unchecked),
        ("a", Checked),
        ("a1", Unchecked),
        ("a2", Unchecked),
        ("a3", Unchecked),
        ("b", Unchecked),
      ],
    ),
  )
}

///|
test "tree: WAI-ARIA navigation (↓/↑/Home/End, → expand/enter child, ← collapse/parent), typeahead, selection, and a11y" {
  let expanded = @signals.signal(["src"])
  let selected = @signals.signal("")
  let visible_rows = fn() -> Array[(String, String, String?, Bool, Int)] {
    let out : Array[(String, String, String?, Bool, Int)] = [("src", "src", None, true, 1)]
    if expanded.get().contains("src") {
      out.push(("app", "app.mbt", Some("src"), false, 2))
      out.push(("lib", "lib", Some("src"), true, 2))
      if expanded.get().contains("lib") {
        out.push(("core", "core.mbt", Some("lib"), false, 3))
      }
    }
    out.push(("readme", "README.md", None, false, 1))
    out
  }
  let t = window(fn(root) {
    @headless.tree(
      root,
      fn() { "文件树" },
      fn(k) { selected.get() == k },
      fn(k) { selected.set(k) },
      fn(k) { expanded.get().contains(k) },
      fn(k, to) {
        let cur = expanded.untracked()
        if to {
          if !cur.contains(k) {
            expanded.set(cur + [k])
          }
        } else {
          expanded.set(cur.filter(fn(x) { x != k }))
        }
      },
      fn(v, tr) {
        v.each(visible_rows, fn(row) { row.0 }, at_once=true, fn(slot, row_sig) {
          let (key, name, parent_key, has_kids, lvl) = row_sig.untracked()
          tr.item(
            slot,
            key,
            fn() { name },
            parent_key?=parent_key,
            has_children=fn() { has_kids },
            level=lvl,
            check=fn() { if key == "src" { Some(Indeterminate) } else if key == "app" { Some(Checked) } else { None } },
            in_node=true,
            fn(n, _) { n.width(Is(Some(140.0))).height(Is(Some(24.0))) |> ignore },
          )
          |> ignore
        })
      },
    )
    |> ignore
  })
  t.set_a11y(true)
  let has_tree = t.query(Listbox, label="文件树") is Some(_)
  let src_said = t.get(Option, label="src")
  let app_said = t.get(Option, label="app.mbt")
  // Focus "src" (already expanded): → enters first child "app.mbt"
  t.act(Option, Focus, label="src")
  t.key(@ui.key_code_right)
  let enter_child = tr_focus(t)
  // ↓ moves to "lib" (collapsed): → expands "lib", second → enters "core.mbt"
  t.key(@ui.key_code_down)
  let on_lib = tr_focus(t)
  t.key(@ui.key_code_right)
  t.draw()
  let lib_expanded = expanded.untracked().contains("lib")
  t.key(@ui.key_code_right)
  let on_core = tr_focus(t)
  // Enter selects "core"
  t.enter()
  let sel_core = selected.untracked()
  // ← on leaf "core.mbt" jumps to parent "lib"; second ← collapses "lib"
  t.key(@ui.key_code_left)
  let back_to_lib = tr_focus(t)
  t.key(@ui.key_code_left)
  t.draw()
  let lib_collapsed = !expanded.untracked().contains("lib")
  // Typeahead 'r' jumps to "README.md"; Home -> "src"; End -> "README.md"
  t.key(@ui.key_of_char('r'))
  let ta_readme = tr_focus(t)
  t.key(@ui.key_code_home)
  let at_home = tr_focus(t)
  t.key(@ui.key_code_end)
  let at_end = tr_focus(t)
  assert_eq(
    (
      has_tree,
      src_said.description,
      src_said.expanded,
      src_said.check,
      app_said.description,
      app_said.expanded,
      app_said.check,
    ),
    (true, "level 1", Some(true), Some(@view.Check::Mixed), "level 2", None, Some(@view.Check::On)),
  )
  assert_eq(
    (
      enter_child,
      on_lib,
      lib_expanded,
      on_core,
      sel_core,
      back_to_lib,
      lib_collapsed,
      ta_readme,
      at_home,
      at_end,
    ),
    ("app.mbt", "lib", true, "core.mbt", "core", "lib", true, "README.md", "src", "README.md"),
  )
}

///|
test "tree: collapsing a parent while a descendant holds focus recovers focus to that parent (not next sibling)" {
  let expanded = @signals.signal(["folder"])
  let visible_rows = fn() -> Array[(String, String, String?, Bool, Int)] {
    let out : Array[(String, String, String?, Bool, Int)] = [("folder", "Folder", None, true, 1)]
    if expanded.get().contains("folder") {
      out.push(("child", "Child", Some("folder"), false, 2))
    }
    out.push(("sibling", "Sibling", None, false, 1))
    out
  }
  let t = window(fn(root) {
    @headless.tree(
      root,
      fn() { "目录" },
      fn(_) { false },
      fn(_) {  },
      fn(k) { expanded.get().contains(k) },
      fn(k, to) {
        if to {
          expanded.set([k])
        } else {
          expanded.set([])
        }
      },
      fn(v, tr) {
        v.each(visible_rows, fn(row) { row.0 }, at_once=true, fn(slot, row_sig) {
          let (key, name, parent_key, has_kids, lvl) = row_sig.untracked()
          tr.item(
            slot,
            key,
            fn() { name },
            parent_key?=parent_key,
            has_children=fn() { has_kids },
            level=lvl,
            in_node=true,
            fn(n, _) { n.width(Is(Some(120.0))).height(Is(Some(24.0))) |> ignore },
          )
          |> ignore
        })
      },
    )
    |> ignore
  })
  // Focus "Child", then externally collapse "folder" -> focus must recover to "Folder", not "Sibling"
  t.act(Option, Focus, label="Child")
  assert_eq(tr_focus(t), "Child")
  expanded.set([])
  t.draw()
  assert_eq(tr_focus(t), "Folder")
}

///|
test "tree: rtl=true flips ←/→ expand and collapse keys" {
  let expanded = @signals.signal(false)
  let t = window(fn(root) {
    @headless.tree(
      root,
      fn() { "RTL树" },
      fn(_) { false },
      fn(_) {  },
      fn(k) { k == "p" && expanded.get() },
      fn(k, to) { if k == "p" { expanded.set(to) } },
      rtl=true,
      fn(v, tr) {
        tr.item(
          v,
          "p",
          fn() { "Parent" },
          has_children=fn() { true },
          level=1,
          fn(n, _) { n.width(Is(Some(100.0))).height(Is(Some(24.0))) |> ignore },
        )
        |> ignore
      },
    )
    |> ignore
  })
  t.act(Option, Focus, label="Parent")
  // In RTL: ← expands, → collapses
  t.key(@ui.key_code_left)
  let after_left = expanded.untracked()
  t.key(@ui.key_code_right)
  let after_right = expanded.untracked()
  assert_eq((after_left, after_right), (true, false))
}
