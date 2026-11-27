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
/// A secret's field shown in a column `w` wide, its `value` on as many lines as it takes, its eye and 复制 at its end:
/// the Tester, then the value's rectangle and the eye's.
fn u15_shown(value : String, w : Double) -> (@ui.Tester, (Double, Double, Double, Double), (Double, Double, Double, Double)) {
  let t = u15_case(w~, fn(b) {
    b.box(fn(row) {
      secret_value_row_node(row, fn() { "私钥" }, fn() { value }, mono=fn() { true }, fn(l) {
        secret_key_node(l, "eye-off", fn() { "隐藏" }, fn() {  }) |> ignore
        secret_copy_node(l, fn() { value }, fn() { true }) |> ignore
      })
    })
    |> ignore
  })
  (t, t.rect_of(value).unwrap(), t.get(Button, label="隐藏").rect)
}

///|
test "a secret's keys by its value's first line: across the middle of one line, at the top of several" {
  // (one line: the keys across its middle, as they were)
  let (t1, (_, vy1, _, vh1), (_, ey1, _, eh1)) = u15_shown("ghp_abcdefghij", 320.0)
  let one = ey1 + eh1 / 2.0 - vy1
  assert_true((ey1 + eh1 / 2.0 - (vy1 + vh1 / 2.0)).abs() <= 1.0, msg="\{ey1} \{eh1} \{vy1} \{vh1}")
  assert_eq(t1.audit(), [])
  // (four lines and more: the keys where they are by one, by its first line, not across the middle of all of them)
  let long = "MIIEvQIBADAN BgkqhkiG9w0B AQEFAASCBKcw ggSjAgEAAoIB AQC7VJTUt9Us 8cKjMzEfYyjiW A4R4/M2bS1GB"
  let copy = t("common.copy")
  let (tl, (vx, vy, vw, vh), (ex, ey, _, eh)) = u15_shown(long, 200.0)
  assert_true(vh >= 4.0 * vh1 - 1.0, msg="\{vh} \{vh1}")
  assert_true(ex >= vx + vw, msg="\{ex} \{vx} \{vw}")
  assert_true((ey + eh / 2.0 - vy - one).abs() <= 1.0, msg="\{ey} \{eh} \{vy} \{one}")
  assert_true(ey + eh <= vy + vh / 2.0, msg="\{ey} \{eh} \{vy} \{vh}")
  let (_, cy, _, ch) = tl.get(Button, label=copy).rect
  assert_true((cy + ch / 2.0 - (ey + eh / 2.0)).abs() <= 0.5, msg="\{cy} \{ey}")
  assert_eq(tl.audit(), [])
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
test "a use: when on the baseline of what used it's first line, how under it in the code face where it was a command" {
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
  let (wx, _, _, _) = t.rect_of("3 分钟前").unwrap()
  let (_, hy, _, _) = t.rect_of("gh auth status").unwrap()
  assert_true(wx > nx + nw)
  // (when on the baseline of what used it's line, whatever size its words are: Body here)
  let base_of = fn(words : String) {
    t.text_runs().filter(fn(r) { r.text == words })[0].base
  }
  let (nb, wb) = (base_of("部署对话"), base_of("3 分钟前"))
  assert_true((nb - wb).abs() <= 0.01, msg="\{nb} \{wb}")
  assert_true(hy >= ny + nh)
  assert_eq(t.audit(), [])
}

///|
test "words in the code face on one line follow the theme's size" {
  let t = u15_case(fn(b) { mono_line_node(b, fn() { "12" }, Meta, fn() { theme().p.subtle }) })
  assert_true(t.rect_of("12") is Some(_))
  assert_eq(t.audit(), [])
}

///|
test "a use: when (Meta, L5) on the baseline of what used it's first line (Ui, L6), on one line or two, lines as the web's or the host's, the system's size of words 1 or 1.3" {
  let short = "部署对话"
  let long = "一个很长名字的对话它的名字要折到下一行去还要再长一些才行"
  let name_look = @ui.text_style(size=Ui, leading=L6, color=Fg, w=Full)
  for web in [true, false] {
    @ui.set_web_lines(web)
    for scale in [1.0, 1.3] {
      for name in [short, long] {
        let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, platform=if web { 0 } else { 2 })
        t.check_looks(false)
        @ui.set_view_app(fn(root) {
          root.box(fn(b) {
            b.width(Is(Some(260.0))) |> ignore
            record_rows_node(b, fn(l) {
              l.box(fn(row) {
                record_row_node(
                  row,
                  fn(n) {
                    words_node(n, fn() { name }, fn() { name_look }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                  },
                  fn(h) { record_how_node(h, fn() { "gh auth status" }, fn() { true }) },
                  fn() { "3 分钟前" },
                )
              })
              |> ignore
            })
          })
          |> ignore
        })
        if scale != 1.0 {
          t.set_font_scale(scale)
        }
        t.draw()
        let runs = t.text_runs()
        let lines = runs.filter(fn(r) { r.text != "" && name.contains(r.text) })
        assert_true(lines.length() > 0, msg="web=\{web} scale=\{scale}: name not drawn")
        let mut first = lines[0]
        for r in lines {
          if r.top < first.top {
            first = r
          }
        }
        if name == long {
          assert_true(lines.iter().any(fn(r) { r.top > first.top + 1.0 }), msg="web=\{web} scale=\{scale}: name on one line")
        }
        let w = runs.filter(fn(r) { r.text == "3 分钟前" })
        assert_true(w.length() > 0, msg="web=\{web} scale=\{scale}: when not drawn")
        assert_true(
          (first.base - w[0].base).abs() <= 0.01,
          msg="web=\{web} scale=\{scale} name=\{name}: name base=\{first.base} when base=\{w[0].base}",
        )
        assert_eq(t.audit(), [])
      }
    }
  }
  @ui.set_web_lines(false)
}
