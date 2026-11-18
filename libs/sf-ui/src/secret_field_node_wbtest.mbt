// The library's secret's field, state line, points and uses (secret_field_node.mbt): a value masked till shown and
// copied as a secret, a mark on the first line of words of several lines, when on what used it's first line.

///|
/// A window with keyboard and mouse holding what `make` makes in a column `w` wide.
fn u15_case(make : (@view.View) -> Unit, w? : Double = 320.0) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(w))) |> ignore
      make(b)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a secret's field: masked till its eye shows it, its name over its line, copied as a secret" {
  let shown = @signals.signal(false)
  let copy = t("common.copy")
  let t = u15_case(fn(b) {
    b.box(fn(row) {
      secret_value_row_node(row, fn() { "令牌" }, fn() { "ghp_abcdefghij" }, shown=fn() { shown.get() }, mono=fn() { true }, fn(l) {
        secret_key_node(l, "eye", fn() { if shown.get() { "隐藏" } else { "显示" } }, fn() { shown.set(!shown.get()) }, icon_now=fn() {
          if shown.get() {
            "eye-off"
          } else {
            "eye"
          }
        })
        |> ignore
        secret_copy_node(l, fn() { "ghp_abcdefghij" }, fn() { true }) |> ignore
      })
    })
    |> ignore
  })
  let masked = secret_mask("ghp_abcdefghij")
  assert_eq(masked, "•".repeat(14))
  assert_true(t.rect_of(masked) is Some(_))
  assert_true(t.rect_of("ghp_abcdefghij") is None)
  let (_, ly, _, lh) = t.rect_of("令牌").unwrap()
  let (_, vy, _, _) = t.rect_of(masked).unwrap()
  assert_true(vy >= ly + lh, msg="\{vy} \{ly} \{lh}")
  assert_eq(t.audit(), [])
  t.click(Button, label="显示")
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("ghp_abcdefghij") is Some(_))
  assert_true(t.rect_of(masked) is None)
  t.click(Button, label=copy)
  assert_eq(t.clipboard(), "ghp_abcdefghij")
  assert_eq(t.clipboard_secret(), Some(secret_copied_life))
  assert_eq(t.audit(), [])
}

///|
test "a secret masked: 8 dots at least, 20 at most" {
  assert_eq(secret_mask("ab"), "•".repeat(8))
  assert_eq(secret_mask("a".repeat(40)), "•".repeat(20))
}

///|
test "a value masked by who keeps it: on one line, as it is said" {
  let t = u15_case(fn(b) {
    b.box(fn(row) {
      secret_value_row_node(row, fn() { "密码" }, fn() { "••••••••" }, mono=fn() { true }, one_line=true, fn(l) {
        secret_key_node(l, "eye", fn() { "显示" }, fn() {  }) |> ignore
      })
    })
    |> ignore
  })
  assert_true(t.rect_of("••••••••") is Some(_))
  assert_eq(t.audit(), [])
}

///|
test "a state on its line: its words across its dot's middle, one line" {
  let on = @signals.signal(false)
  let t = u15_case(fn(b) { status_banner_line_node(b, fn() { on.get() }, fn() { if on.get() { "已开启" } else { "未开启" } }) })
  assert_true(t.rect_of("未开启") is Some(_))
  on.set(true)
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("已开启") is Some(_))
  assert_eq(t.audit(), [])
}

///|
test "points: each mark on the first line of words of several lines, the rest under them" {
  let long = "第一行的话 第二行的话 第三行的话 第四行的话 第五行的话 第六行的话"
  let t = u15_case(w=180.0, fn(b) {
    icon_points_node(b, fn(p) {
      icon_point_row_node(p, "server", fn() { long }, rest=fn() { "其余的话" })
      icon_point_row_node(p, "monitor", fn() { "一台很长名字的电脑 它的名字要折到下一行去" }, look=Listed)
    })
  })
  let (_, ty, _, th) = t.rect_of(long).unwrap()
  let (_, ry, _, _) = t.rect_of("其余的话").unwrap()
  assert_true(ry >= ty + th, msg="\{ry} \{ty} \{th}")
  assert_eq(t.first_line_faults(), [])
  assert_eq(t.audit(), [])
}

///|
test "a use: when on what used it's first line, how under it in the code face where it was a command" {
  let t = u15_case(fn(b) {
    record_rows_node(b, fn(l) {
      l.box(fn(row) {
        record_row_node(
          row,
          fn(n) { words_node(n, fn() { "部署对话" }, fn() { body }) |> ignore },
          fn(h) { record_how_node(h, fn() { "gh auth status" }, fn() { true }) },
          fn() { "3 分钟前" },
        )
      })
      |> ignore
    })
  })
  let (nx, ny, nw, nh) = t.rect_of("部署对话").unwrap()
  let (wx, wy, _, wh) = t.rect_of("3 分钟前").unwrap()
  let (_, hy, _, _) = t.rect_of("gh auth status").unwrap()
  assert_true(wx > nx + nw)
  // (when across the middle of what used it's line)
  assert_true((wy + wh / 2.0 - (ny + nh / 2.0)).abs() <= 1.0, msg="\{wy} \{wh} \{ny} \{nh}")
  assert_true(hy >= ny + nh)
  assert_eq(t.audit(), [])
}

///|
test "words in the code face on one line follow the theme's size" {
  let t = u15_case(fn(b) { mono_line_node(b, fn() { "12" }, Meta, fn() { theme().p.subtle }) })
  assert_true(t.rect_of("12") is Some(_))
  assert_eq(t.audit(), [])
}
