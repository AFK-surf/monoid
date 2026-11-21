// narrow_retry_node and narrow_empty_node: what each draws, where and how big, and what a press on each does, with
// touch and with keyboard and mouse.

///|
/// A window of `platform` holding `node` in a column 360 wide and 400 tall; at rest.
fn narrow_node_tester(platform : Int, node : (@view.View) -> Unit) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform~)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(h) {
      h.width(Is(Some(360.0))).height(Is(Some(400.0))) |> ignore
      node(h)
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Presses the words `words`, in their middle.
fn narrow_press(t : @ui.Tester, words : String) -> Unit {
  let w = t.words().filter(fn(w) { w.0 == words })
  guard w.length() == 1 else { @halt.saying("\{words}: \{w.length()}") }
  t.tap(w[0].1 + w[0].3 / 2.0, w[0].2 + w[0].4 / 2.0)
  t.run_for(@ui.move_most_ms)
}

///|
test "narrow_retry_node: what could not be read and 重试 drawn; 重试 pressed, retried" {
  let words = "无法读取这个文件夹：权限不足，请到 station 上查看它的设置后再试一次"
  for platform in [2, 0] {
    let tried : Array[String] = []
    let t = narrow_node_tester(
      platform,
      fn(v) { narrow_retry_node(v, fn() { words }, narrow_failed_words, fn() { tried.push("new") }) },
    )
    let retry_label = @sf.t("web-pages.drive.retry")
    assert_true(t.find("无法读取这个文件夹") is Some(_), msg="\{platform}: problem words")
    assert_true(t.find(retry_label) is Some(_), msg="\{platform}: retry label")
    narrow_press(t, retry_label)
    assert_eq(tried, ["new"], msg="\{platform}")
  }
}

///|
test "narrow_empty_node: nothing here, with what can be done about it and without; its button pressed, done" {
  // (its words read as each run's view is made: read before any run, they are the run before's)
  let words = fn() { @sf.t("web-main.rail.filesNone") }
  for platform in [2, 0] {
    for act in [false, true] {
      let done : Array[String] = []
      let t = narrow_node_tester(
        platform,
        fn(v) {
          narrow_empty_node(v, words, if act { Some((fn() { "刷新" }, fn() { done.push("new") })) } else { None })
        },
      )
      assert_true(t.find(words()) is Some(_), msg="\{platform} \{act}: empty words")
      if act {
        assert_true(t.find("刷新") is Some(_), msg="\{platform}: action button")
        narrow_press(t, "刷新")
        assert_eq(done, ["new"], msg="\{platform}")
      } else {
        assert_true(t.find("刷新") is None, msg="\{platform}: no action button")
      }
    }
  }
}
