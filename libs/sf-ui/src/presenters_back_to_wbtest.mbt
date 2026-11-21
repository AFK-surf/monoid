// Two steps further in from a panel of nodes, each a panel of nodes its button opens as its panel closes (a preset's
// dialog, its 添加目录, the folder picker): back to the first in one change (panel_back's `to`), on a phone's sheet (its
// pages) and in a desk's dialogs (each a step further in from the one before), what the steps held let go of, the first
// not; the first's back closes it as ever.

///|
/// 第一 with its 往里 opening 第二, whose 再往里 opens 第三, whose 回到第一 goes back to the first; each one's going said.
fn panels_three_deep(said : Array[String]) -> (Anchor) -> Unit {
  fn(_) {
    let step = fn(title : String, words : String, button : String, press : () -> Unit, gone : String) {
      panel_nodes(
        title,
        fn(v, close) {
          words_node(v, fn() { words }, fn() { panel_note_words }) |> ignore
          button_node(v, fn() { button }, fn() {
            if button == "回到第一" {
              press()
            } else {
              close()
              press()
            }
          })
          |> ignore
        },
        from=Unanchored,
        gone=fn() { said.push(gone) },
      )
    }
    step(
      "第一",
      "第一的内容",
      "往里",
      fn() {
        step(
          "第二",
          "第二的内容",
          "再往里",
          fn() {
            step("第三", "第三的内容", "回到第一", fn() { panel_back(to=1) |> ignore }, "third gone")
          },
          "second gone",
        )
      },
      "first gone",
    )
  }
}

///|
fn back_to_first(at : (Int, Double, Double)) -> Unit raise {
  let said : Array[String] = []
  let t = presenting_tester(at, panels_three_deep(said))
  open_it(t)
  t.tap_text("往里")
  t.run_for(@ui.move_most_ms)
  t.tap_text("再往里")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("第三的内容") is Some(_) && t.find("第一的内容") is None, msg="\{Repr(t.text_runs().map(fn(r) { r.text }))}")
  t.tap_text("回到第一")
  t.run_for(@ui.move_most_ms)
  assert_true(presenting())
  assert_true(t.find("第一的内容") is Some(_), msg="\{Repr(t.text_runs().map(fn(r) { r.text }))}")
  assert_true(t.find("第二的内容") is None && t.find("第三的内容") is None, msg="\{Repr(t.text_runs().map(fn(r) { r.text }))}")
  assert_eq(said, ["third gone", "second gone"])
  // (on the first: back closes it, nothing before it)
  if at.0 == 2 {
    t.back()
  } else {
    assert_true(t.key_named("esc"))
  }
  t.run_for(@ui.move_most_ms)
  assert_true(!presenting())
  assert_eq(said, ["third gone", "second gone", "first gone"])
}

///|
test "two steps further in, with a finger at Small: back to the first of the same sheet in one change" {
  back_to_first(phone)
}

///|
test "two steps further in, with a mouse at Large: back to the first dialog in one change" {
  back_to_first(desk)
}

///|
/// An anchored panel (depth 1) opening a dialog (depth 2, recording its depth with `panel_depth`), which goes two steps
/// further in (depths 3 and 4) whose button calls `panel_back(to=target)`: back stops at depth 2 instead of unwinding
/// past the dialog to depth 1.
fn panels_nested_four_deep(said : Array[String]) -> (Anchor) -> Unit {
  let target : Ref[Int] = Ref(1)
  fn(from) {
    let step = fn(
      title : String,
      words : String,
      button : String,
      press : () -> Unit,
      gone : String,
      at : Anchor,
      close_first : Bool,
    ) {
      panel_nodes(
        title,
        fn(v, close) {
          words_node(v, fn() { words }, fn() { panel_note_words }) |> ignore
          button_node(v, fn() { button }, fn() {
            if close_first {
              close()
            }
            press()
          })
          |> ignore
        },
        from=at,
        gone=fn() { said.push(gone) },
      )
    }
    let open_browse = fn() {
      step(
        "浏览",
        "浏览的内容",
        "选择文件夹",
        fn() { panel_back(to=target.val) |> ignore },
        "fourth gone",
        Unanchored,
        false,
      )
    }
    let open_add = fn() {
      step("添加", "添加的内容", "浏览文件夹", open_browse, "third gone", Unanchored, true)
    }
    let open_form = fn() {
      step("表单", "表单的内容", "添加目录", open_add, "second gone", Unanchored, true)
      target.val = panel_depth()
    }
    step("面板", "面板的内容", "新建", open_form, "first gone", from, true)
  }
}

///|
fn back_to_nested(at : (Int, Double, Double)) -> Unit raise {
  let said : Array[String] = []
  let t = presenting_tester(at, panels_nested_four_deep(said))
  open_it(t)
  assert_eq(panel_depth(), 1)
  t.tap_text("新建")
  t.run_for(@ui.move_most_ms)
  assert_eq(panel_depth(), 2)
  // First round: 2 -> 3 -> 4 -> back to 2
  t.tap_text("添加目录")
  t.run_for(@ui.move_most_ms)
  assert_eq(panel_depth(), 3)
  t.tap_text("浏览文件夹")
  t.run_for(@ui.move_most_ms)
  assert_eq(panel_depth(), 4)
  assert_true(t.find("浏览的内容") is Some(_) && t.find("表单的内容") is None, msg="\{Repr(t.text_runs().map(fn(r) { r.text }))}")
  t.tap_text("选择文件夹")
  t.run_for(@ui.move_most_ms)
  assert_true(presenting())
  assert_eq(panel_depth(), 2)
  assert_true(t.find("表单的内容") is Some(_), msg="\{Repr(t.text_runs().map(fn(r) { r.text }))}")
  assert_true(t.find("添加的内容") is None && t.find("浏览的内容") is None && t.find("面板的内容") is None, msg="\{Repr(t.text_runs().map(fn(r) { r.text }))}")
  assert_eq(said, ["fourth gone", "third gone"])
  // Second round from the restored dialog: 2 -> 3 -> 4 -> back to 2 again
  t.tap_text("添加目录")
  t.run_for(@ui.move_most_ms)
  t.tap_text("浏览文件夹")
  t.run_for(@ui.move_most_ms)
  t.tap_text("选择文件夹")
  t.run_for(@ui.move_most_ms)
  assert_eq(panel_depth(), 2)
  assert_true(t.find("表单的内容") is Some(_), msg="\{Repr(t.text_runs().map(fn(r) { r.text }))}")
  // Back from depth 2 returns to depth 1, then closes everything
  if at.0 == 2 {
    t.back()
  } else {
    assert_true(t.key_named("esc"))
  }
  t.run_for(@ui.move_most_ms)
  assert_eq(panel_depth(), 1)
  assert_true(t.find("面板的内容") is Some(_), msg="\{Repr(t.text_runs().map(fn(r) { r.text }))}")
  if at.0 == 2 {
    t.back()
  } else {
    assert_true(t.key_named("esc"))
  }
  t.run_for(@ui.move_most_ms)
  assert_true(!presenting())
  assert_eq(panel_depth(), 0)
}

///|
test "two steps further in from a nested panel, with a finger at Small: panel_back(to=panel_depth()) stops at the nested panel" {
  back_to_nested(phone)
}

///|
test "two steps further in from a nested panel, with a mouse at Large: panel_back(to=panel_depth()) stops at the nested dialog" {
  back_to_nested(desk)
}
