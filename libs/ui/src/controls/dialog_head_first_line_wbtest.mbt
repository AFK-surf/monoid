// A dialog's head whose title takes two lines: its close button at the head's end, and a step's back key before its
// title, stand on the title's first line where they stood by a title of one line, never centred on the two lines
// (head_line_drop, dialog_step_head, panel_step_line, sheet_title_row: 「这种不应该对标题居中」). Measured as how far a
// button's middle is from the middle of its title's first line, with a title of one line and of two.

///|
/// How far the middle of the button called `button` stands under the middle of the first line of `title` in what `open`
/// presents on a window `w` wide (中屏 a dialog, 小屏 a sheet) at the system's size of words `scale`, opened by 打开; and
/// how many lines the title takes.
fn head_button_off(
  open : (Anchor) -> Unit,
  title : String,
  button : String,
  w? : Double = 1200.0,
  scale? : Double = 1.0,
) -> (Double, Int) {
  presenters_reset()
  let t = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open)),
    w~,
    h=800.0,
    platform=0,
  )
  t.check_looks(false)
  t.set_font_scale(scale)
  t.draw()
  t.tap_text("打开")
  t.run_for(@ui.move_most_ms)
  t.leave()
  t.draw()
  let words = t.words().filter(fn(x) { x.0 == title })
  let lines = t.lines_of(title).length()
  let b = t.all(Button, label=button)
  guard words.length() == 1 && lines > 0 && b.length() == 1 else {
    @halt.saying("no \{title} or \{button}: \{words.length()} \{lines} \{b.length()}")
  }
  let (_, _, y, _, h, _) = words[0]
  let first_mid = y + h / lines.to_double() / 2.0
  let (_, by, _, bh) = b[0].rect
  ((by + bh / 2.0 - first_mid).round(), lines)
}

///|
let head_long_title : String = "OPPO Find X9 Ultra 上的 still 应用申请工作区密钥库的钥匙，请核对以下信息后再授权"

///|
test "a dialog's close button stands on its title's first line, the title of one line or of two" {
  let close = t("common.close")
  let dialog = fn(title : String) {
    fn(_ : Anchor) {
      panel_nodes(title, from=Unanchored, description="此设备已在你的受信任设备中。", fn(v, _) {
        v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
      })
    }
  }
  let (one, one_lines) = head_button_off(dialog("申请钥匙"), "申请钥匙", close)
  let (two, two_lines) = head_button_off(dialog(head_long_title), head_long_title, close)
  assert_eq((one_lines, two_lines >= 2), (1, true))
  assert_eq(two, one)
}

///|
test "a step's back key in a dialog and on a sheet stands on its title's first line, the title of one line or of two" {
  let back = t("common.back")
  let stepped = fn(title : String) {
    fn(_ : Anchor) {
      panel_nodes("第一步", from=Unanchored, steps=true, fn(v, _) {
        v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
      })
      panel_go_nodes(title, fn(v, _) {
        v.box(fn(b) { words_node(b, fn() { "下一步的内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
      })
    }
  }
  // (on the first line's middle itself, at any size of words: a key a line of words tall, in_line's)
  for w in [1200.0, 390.0] {
    for scale in [0.85, 1.0, 1.3, 1.8, 2.0] {
      let at = "\{w} \{scale}"
      let (one, one_lines) = head_button_off(stepped("申请钥匙"), "申请钥匙", back, w~, scale~)
      let (two, two_lines) = head_button_off(stepped(head_long_title), head_long_title, back, w~, scale~)
      assert_eq((one_lines, two_lines >= 2), (1, true), msg=at)
      assert_eq((one, two), (0.0, 0.0), msg=at)
    }
  }
}

///|
test "a sheet's step's back key stands concentric with the sheet's top corner and flush with body words across scales" {
  for title in ["申请钥匙", head_long_title] {
    for scale in [0.85, 1.0, 1.3, 1.8, 2.0] {
      let at = "\{title} scale=\{scale}"
      let open = fn(_ : Anchor) {
        panel_nodes("第一步", from=Unanchored, steps=true, fn(v, _) {
          v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
        })
        panel_go_nodes(title, fn(v, _) {
          v.box(fn(b) { words_node(b, fn() { "下一步的内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
        })
      }
      presenters_reset()
      let back = t("common.back")
      let tt = @ui.Tester::new(
        fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
        tree=presented_tree(presenting_view(open)),
        w=390.0,
        h=800.0,
        platform=0,
      )
      tt.check_looks(false)
      tt.set_font_scale(scale)
      tt.draw()
      tt.tap_text("打开")
      tt.run_for(@ui.move_most_ms)
      tt.leave()
      tt.draw()
      let key = tt.all(Button, label=back)
      let sheet = tt.all(Dialog, label=title)
      let body = tt.words().filter(fn(x) { x.0 == "下一步的内容" })
      guard key.length() == 1 && sheet.length() == 1 && body.length() == 1 else {
        @halt.saying("\{at}: missing back/sheet/body: \{key.length()} \{sheet.length()} \{body.length()}")
      }
      let (kx, ky, kw, kh) = key[0].rect
      let (sx, sy, sw, _) = sheet[0].rect
      let title_w = tt.words().filter(fn(x) { x.0 == title })
      guard title_w.length() == 1 else { @halt.saying("\{at}: missing title") }
      let (_, tx, _, tw, _, _) = title_w[0]
      assert_eq((kw.round(), kh.round()), (44.0, 44.0), msg=at)
      assert_eq(((kx - sx).round(), (ky - sy).round()), (16.0, 16.0), msg=at)
      // Single-line title stays horizontally centred under the sheet's grabber bar
      if title == "申请钥匙" {
        assert_true(((tx + tw / 2.0) - (sx + sw / 2.0)).abs() <= 1.0, msg="\{at}: title mid \{tx + tw / 2.0} vs sheet mid \{sx + sw / 2.0}")
      }
      let cf = tt.corner_faults()
      // At 2.0x the old-view trigger button 「打开」 from presenting_view overflows its fixed 32pt test box by 1pt;
      // filter only that old-view trigger fault while auditing every node inside the presented sheet.
      let af = tt.audit().filter(fn(f) { !(scale >= 2.0 && f.contains("「打开」") && f.contains("(old view)")) })
      let cfs = cf.join("; ")
      let afs = af.join("; ")
      assert_eq(cf, [], msg="\{at}: \{cfs}")
      assert_eq(af, [], msg="\{at}: \{afs}")
    }
  }
}

///|
test "a sheet's step's back key stays concentric and unclipped in capped/full-bleed sheets and clear of grabber at 3.0x" {
  // 1) Capped sheet (tall=0.55) with clipping stack enabled: back key at (24,24), 0 corner faults, 0 audit faults.
  let open_capped = fn(_ : Anchor) {
    panel_nodes("第一步", from=Unanchored, steps=true, tall=0.55, fn(v, _) {
      v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
    })
    panel_go_nodes("申请钥匙", fn(v, _) {
      v.box(fn(b) {
        style_node(b, fn() { sheet_words_at })
        words_node(b, fn() { "下一步的内容" }, fn() { dialog_lead }) |> ignore
      })
      |> ignore
    })
  }
  presenters_reset()
  let back = t("common.back")
  let tc = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open_capped)),
    w=390.0,
    h=800.0,
    platform=0,
  )
  tc.check_looks(false)
  tc.draw()
  tc.tap_text("打开")
  tc.run_for(@ui.move_most_ms)
  tc.leave()
  tc.draw()
  let ck = tc.all(Button, label=back)
  let cs = tc.all(Dialog, label="申请钥匙")
  let cb = tc.words().filter(fn(x) { x.0 == "下一步的内容" })
  guard ck.length() == 1 && cs.length() == 1 && cb.length() == 1 else {
    @halt.saying("capped sheet missing back/sheet/body")
  }
  let (ckx, cky, ckw, ckh) = ck[0].rect
  let (csx, csy, _, _) = cs[0].rect
  let (_, _, _, _, _, _) = cb[0]
  assert_eq((ckw.round(), ckh.round()), (44.0, 44.0), msg="capped size")
  assert_eq(((ckx - csx).round(), (cky - csy).round()), (16.0, 16.0), msg="capped concentric")
  assert_eq(tc.corner_faults(), [], msg="capped corners")
  assert_eq(tc.audit(), [], msg="capped audit")

  // 2) Full-bleed sheet (tall=0.9): back key stays at (16,16), 0 corner faults, 0 audit faults.
  let open_full = fn(_ : Anchor) {
    panel_nodes("第一步", from=Unanchored, steps=true, tall=0.9, fn(v, _) {
      v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
    })
    panel_go_nodes("申请钥匙", fn(v, _) {
      v.box(fn(b) {
        style_node(b, fn() { sheet_words_at })
        words_node(b, fn() { "下一步的内容" }, fn() { dialog_lead }) |> ignore
      })
      |> ignore
    })
  }
  presenters_reset()
  let tf = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open_full)),
    w=390.0,
    h=800.0,
    platform=0,
  )
  tf.check_looks(false)
  tf.draw()
  tf.tap_text("打开")
  tf.run_for(@ui.move_most_ms)
  tf.leave()
  tf.draw()
  let fk = tf.all(Button, label=back)
  let fs = tf.all(Dialog, label="申请钥匙")
  let fb = tf.words().filter(fn(x) { x.0 == "下一步的内容" })
  guard fk.length() == 1 && fs.length() == 1 && fb.length() == 1 else {
    @halt.saying("full-bleed sheet missing back/sheet/body")
  }
  let (fkx, fky, fkw, fkh) = fk[0].rect
  let (fsx, fsy, _, _) = fs[0].rect
  assert_eq((fkw.round(), fkh.round()), (44.0, 44.0), msg="full-bleed size")
  assert_eq(((fkx - fsx).round(), (fky - fsy).round()), (16.0, 16.0), msg="full-bleed concentric")
  assert_eq(tf.corner_faults(), [], msg="full-bleed corners")
  assert_eq(tf.audit(), [], msg="full-bleed audit")

  // 3) Extreme 3.0x font scale: title row clamps below the grabber bar (y=11pt) instead of colliding with it.
  let open_3x = fn(_ : Anchor) {
    panel_nodes("第一步", from=Unanchored, steps=true, fn(v, _) {
      v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
    })
    panel_go_nodes("申请钥匙", fn(v, _) {
      v.box(fn(b) {
        style_node(b, fn() { sheet_words_at })
        words_node(b, fn() { "下一步的内容" }, fn() { dialog_lead }) |> ignore
      })
      |> ignore
    })
  }
  presenters_reset()
  let t3 = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open_3x)),
    w=390.0,
    h=800.0,
    platform=0,
  )
  t3.check_looks(false)
  t3.set_font_scale(3.0)
  t3.draw()
  t3.tap_text("打开")
  t3.run_for(@ui.move_most_ms)
  t3.leave()
  t3.draw()
  let s3 = t3.all(Dialog, label="申请钥匙")
  let w3 = t3.words().filter(fn(x) { x.0 == "申请钥匙" })
  guard s3.length() == 1 && w3.length() == 1 else {
    @halt.saying("3x sheet missing sheet/title")
  }
  let (_, s3y, _, _) = s3[0].rect
  let (_, _, w3y, _, _, _) = w3[0]
  assert_true(w3y - s3y >= 13.5, msg="3x title top \{w3y - s3y} must stay clear below grabber bar (11pt)")
}

///|
test "a stepped centred dialog's back key matches its close button's 36pt Liquid Glass disc, concentricity, and first-line alignment" {
  let back = t("common.back")
  let close = t("common.close")
  for scale in [0.85, 1.0, 1.3, 1.8, 2.0] {
    let mut one_off : Double = 0.0
    for idx, title in ["申请钥匙", head_long_title] {
      let at = "\{title} scale=\{scale}"
      let open = fn(_ : Anchor) {
        panel_nodes("第一步", from=Unanchored, fn(v, close_fn) {
          panel_row_node(v, fn() { "下一步" }, fn() {
            close_fn()
            panel_nodes(title, from=Unanchored, fn(v2, _) {
              v2.box(fn(b) { words_node(b, fn() { "下一步的内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
            })
          })
          |> ignore
          v.box(fn(b) { words_node(b, fn() { "第一步说明" }, fn() { dialog_lead }) |> ignore }) |> ignore
        })
      }
      presenters_reset()
      let tt = @ui.Tester::new(
        fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
        tree=presented_tree(presenting_view(open)),
        w=1200.0,
        h=800.0,
        platform=0,
        // At 1.8x/2.0x modal_title_size (17/22pt) line height (39.6-44pt) exceeds the 36pt circle, so head_line_drop
        // shifts both corner buttons down to stay centred on line 1 (matching the explicit design rule over top-corner
        // concentricity).
        corners_held=scale <= 1.3,
      )
      tt.check_looks(false)
      tt.set_font_scale(scale)
      tt.draw()
      tt.tap_text("打开")
      tt.run_for(@ui.move_most_ms)
      tt.tap_text("下一步")
      tt.run_for(@ui.move_most_ms)
      tt.leave()
      tt.draw()
      let key = tt.all(Button, label=back)
      let cls = tt.all(Button, label=close)
      let dlg = tt.all(Dialog, label=title)
      let words = tt.words().filter(fn(x) { x.0 == title })
      let lines = tt.lines_of(title).length()
      guard key.length() == 1 && cls.length() == 1 && dlg.length() == 1 && words.length() == 1 && lines > 0 else {
        @halt.saying("\{at}: missing nodes")
      }
      let (kx, ky, kw, kh) = key[0].rect
      let (_, cy, cw, ch) = cls[0].rect
      let (dx, dy, _, _) = dlg[0].rect
      let (_, _, wy, _, wh, _) = words[0]
      let first_mid = wy + wh / lines.to_double() / 2.0
      let key_mid = ky + kh / 2.0
      let cls_mid = cy + ch / 2.0
      // Back and close buttons in dialog_head share exact 36x36 Liquid Glass height and vertical center
      assert_eq((kw.round(), kh.round()), (36.0, 36.0), msg=at)
      assert_eq((cw.round(), ch.round()), (36.0, 36.0), msg=at)
      assert_eq((key_mid - cls_mid).round(), 0.0, msg=at)
      if idx == 0 {
        one_off = (key_mid - first_mid).round()
      } else {
        assert_eq((key_mid - first_mid).round(), one_off, msg=at)
      }
      if scale == 1.0 {
        assert_eq(((kx - dx).round(), (ky - dy).round()), (20.0, 20.0), msg=at)
        let cf = tt.corner_faults()
        let cfs = cf.join("; ")
        assert_eq(cf, [], msg="\{at}: \{cfs}")
        // Verify both 36x36 Liquid Glass corner pills are emitted over the Liquid Glass dialog surface
        let pills = tt.drawn_glass().filter(fn(g) { g.4 == 6 && g.2.round() == 36.0 && g.3.round() == 36.0 })
        assert_eq(pills.length(), 2, msg="\{at}: expected 2 36pt Liquid Glass corner pills")
      }
      let af = tt.audit().filter(fn(f) { !(scale >= 2.0 && f.contains("「打开」") && f.contains("(old view)")) })
      let afs = af.join("; ")
      assert_eq(af, [], msg="\{at}: \{afs}")
    }
  }
}

///|
test "dialog corner ladder stays isolated from global corner_ladder and rejects cross-ladder mixing" {
  assert_eq(corner_ladder, [42.0, 26.0, 24.0, 18.0, 10.0])
  assert_eq(dialog_corner_ladder, [38.0, 22.0, 14.0, 6.0])
  // Desktop pane card row-end action keeps (16, 10), unaffected by dialog_small_corner (6).
  assert_eq(corner_step(card_corner, 24.0), Some((16.0, 10.0)))
  assert_eq(corner_step(dialog_card_corner, 16.0, ladder=dialog_corner_ladder), Some((16.0, 6.0)))
  // Cross-ladder nesting (14pt box 12pt inside a 26pt page card) is still caught by corner_faults.
  let cross_tree = fn(root : @view.View) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(card) {
      card
      .width(Is(Some(240.0)))
      .height(Is(Some(140.0)))
      .padding(Is((12.0, 12.0, 12.0, 12.0)))
      .radius(Is(card_corner))
      .ground(Is(0xFFFFFFFFL))
      |> ignore
      card.box(fn(child) {
        child
        .width(Is(Some(120.0)))
        .height(Is(Some(48.0)))
        .radius(Is(dialog_row_corner))
        .ground(Is(0xEEEEEEFFL))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }
  let t = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=cross_tree,
    w=400.0,
    h=300.0,
    platform=0,
    corners_held=false,
  )
  t.check_looks(false)
  t.draw()
  let cf = t.corner_faults()
  assert_true(cf.length() > 0, msg="expected cross-ladder corner fault for 14pt inside 26pt card")
  assert_true(cf[0].contains("[42, 26, 24, 18, 10]"), msg="fault should cite only the global ladder: \{cf[0]}")

  // Same-ladder nesting (14pt box 8pt inside a 22pt dialog card) passes cleanly.
  let dialog_tree = fn(root : @view.View) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(card) {
      card
      .width(Is(Some(240.0)))
      .height(Is(Some(140.0)))
      .padding(Is((8.0, 8.0, 8.0, 8.0)))
      .radius(Is(dialog_card_corner))
      .ground(Is(0xFFFFFFFFL))
      |> ignore
      card.box(fn(child) {
        child
        .width(Is(Some(120.0)))
        .height(Is(Some(48.0)))
        .radius(Is(dialog_row_corner))
        .ground(Is(0xEEEEEEFFL))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }
  let t2 = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=dialog_tree,
    w=400.0,
    h=300.0,
    platform=0,
  )
  t2.check_looks(false)
  t2.draw()
  assert_eq(t2.corner_faults(), [])
}

///|
test "confirm verification facts card renders concentrically in wide dialog, small sheet, and inline menu confirm" {
  // 1) Wide centered dialog: fixed short title + concentric 22pt (dialog_card_corner) verification card
  presenters_reset()
  let t_wide = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      presented_nodes(root)
    },
    w=960.0,
    h=680.0,
    platform=0,
  )
  t_wide.draw()
  confirm(
    "移出成员",
    "移出后该成员无法再访问工作区内的对话与资源。",
    "移出",
    fn() {  },
    danger=true,
    facts=[("成员", "alice@example.com"), ("工作区", "Production Workspace Alpha")],
  )
  t_wide.run_for(@ui.move_most_ms)
  assert_true(t_wide.find("移出成员") is Some(_), msg="wide confirm shows fixed short title")
  assert_true(t_wide.find("alice@example.com") is Some(_), msg="wide confirm shows verified member in facts card")
  assert_true(t_wide.find("Production Workspace Alpha") is Some(_), msg="wide confirm shows verified workspace in facts card")
  let wide_cards = t_wide.drawn_rect_corners().filter(fn(r) { (r.5.0 - dialog_card_corner).abs() < 0.1 && r.4 != 0L })
  assert_true(wide_cards.length() >= 1, msg="wide confirm facts card must use concentric dialog_card_corner (22pt)")
  assert_eq(t_wide.audit(), [])
  assert_eq(t_wide.corner_faults(), [])

  // 2) Small bottom sheet: fixed short title + concentric 22pt verification card at panel_card_in (16pt) from sheet sides
  presenters_reset()
  let t_small = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      presented_nodes(root)
    },
    w=390.0,
    h=844.0,
    platform=1,
  )
  t_small.draw()
  confirm(
    "结束进程",
    "强行结束进程可能导致未保存的工作丢失。",
    "结束",
    fn() {  },
    danger=true,
    facts=[("进程", "python3"), ("PID", "48291"), ("对话", "训练脚本排查")],
  )
  t_small.run_for(@ui.move_most_ms)
  assert_true(t_small.find("结束进程") is Some(_), msg="small confirm sheet shows fixed short title")
  assert_true(t_small.find("48291") is Some(_), msg="small confirm sheet shows PID in facts card")
  assert_true(t_small.find("训练脚本排查") is Some(_), msg="small confirm sheet shows chat in facts card")
  let small_cards = t_small.drawn_rect_corners().filter(fn(r) { (r.5.0 - dialog_card_corner).abs() < 0.1 && r.4 != 0L })
  assert_true(small_cards.length() >= 1, msg="small sheet confirm facts card must use concentric dialog_card_corner (22pt)")
  assert_eq(t_small.audit(), [])
  assert_eq(t_small.corner_faults(), [])

  // 3) Medium/Large inline popover menu confirm: fixed short title + concentric row_corner verification card
  presenters_reset()
  let anchor_ref : Ref[@view.View?] = Ref(None)
  let t_menu = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(page) {
        page.padding(Is((40.0, 40.0, 40.0, 40.0))) |> ignore
        let b = button_node(page, fn() { "更多" }, fn() {
          match anchor_ref.val {
            Some(a) =>
              menu(
                [
                  Some(
                    menu_item_of("删除预设", danger=true, further=true, fn() {
                      confirm(
                        "删除预设",
                        "删除后不会影响已创建的对话。",
                        "删除",
                        fn() {  },
                        danger=true,
                        facts=[("预设", "Production API Gateway Config")],
                      )
                    }),
                  ),
                ],
                from=Node(a),
              )
            None => ()
          }
        })
        anchor_ref.val = Some(b)
      })
      |> ignore
      presented_nodes(root)
    },
    w=960.0,
    h=680.0,
    platform=0,
  )
  t_menu.draw()
  t_menu.tap_text("更多")
  t_menu.run_for(@ui.move_most_ms)
  t_menu.tap_text("删除预设")
  t_menu.leave()
  t_menu.run_for(@ui.move_most_ms)
  assert_true(t_menu.find("Production API Gateway Config") is Some(_), msg="inline menu confirm shows preset name in facts card")
  assert_eq(t_menu.audit(), [])
  assert_eq(t_menu.corner_faults(), [])
}

///|
test "small sheet grabber and modal titles match real iOS 27 geometry and contrast in light and dark" {
  // Verify 58x4pt grabber at y=6..10pt (25% light / 35% dark fg alpha, 40%/50% under more contrast),
  // root sheet title vertically aligned to step_row (both y_mid = 38pt), and wide modal/confirm 17/22pt titles.
  defer {
    set_dark(None)
    presenters_reset()
  }
  assert_true(sheet_grabber_style(false, true).base.bg == sheet_grabber_more.base.bg)
  assert_true(sheet_grabber_style(true, true).base.bg == sheet_grabber_dark_more.base.bg)
  let close_lbl = t("common.close")
  let back_lbl = t("common.back")
  for dark in [false, true] {
    presenters_reset()
    let t = @ui.Tester::new(
      fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
      tree=fn(root) {
        @ui.set_tree_theme(ui_theme_now)
        root.box(fn(bg) { bg.over(Is(true)).ground(By(fn() { theme().p.bg })) |> ignore }) |> ignore
        presented_nodes(root)
      },
      w=390.0,
      h=844.0,
      dark~,
      platform=1,
    )
    // Tester::new sets @ui's dark flag; set_dark drives controls' dark_set signal
    set_dark(Some(dark))
    t.draw()
    confirm("全部迁移", "9 项 · 1 项无法迁移", "全部迁移", fn() {  })
    t.run_for(@ui.move_most_ms)
    let sheets = t.all(Dialog, label="全部迁移")
    let titles = t.words().filter(fn(w) { w.0 == "全部迁移" && w.2 < 750.0 })
    guard sheets.length() == 1 && titles.length() >= 1 else {
      @halt.saying("dark=\{dark}: missing sheet/title")
    }
    let (sx, sy, sw, _) = sheets[0].rect
    let (_, tx, ty, tw, th, _) = titles[0]
    let root_title_mid = ty + th / 2.0 - sy
    // Root sheet title horizontally centered and vertically centered at y_mid = 38.0pt (matches step_row & iOS 27)
    assert_true(((tx + tw / 2.0) - (sx + sw / 2.0)).abs() <= 1.0, msg="dark=\{dark}: title x centered")
    assert_eq(root_title_mid.round(), 38.0, msg="dark=\{dark}: root sheet title mid \{root_title_mid}pt")
    assert_eq(th.round(), 22.0, msg="dark=\{dark}: sheet title line height \{th}pt")
    // Root titled sheet has a concentric 44x44pt Liquid Glass close key at (sx + sw - 60, sy + 16)
    let closes = t.all(Button, label=close_lbl)
    assert_eq(closes.length(), 1, msg="dark=\{dark}: expected 44pt close button on root sheet")
    let (cx, cy, cw, ch) = closes[0].rect
    assert_true((cw - 44.0).abs() <= 0.5 && (ch - 44.0).abs() <= 0.5, msg="dark=\{dark}: close size \{cw}x\{ch}")
    assert_true((cx - (sx + sw - 60.0)).abs() <= 0.5, msg="dark=\{dark}: close x \{cx} vs \{sx + sw - 60.0}")
    assert_true((cy - (sy + 16.0)).abs() <= 0.5, msg="dark=\{dark}: close y \{cy} vs \{sy + 16.0}")
    // Grabber pill: 58x4pt at y = 6..10pt from sheet top with exact iOS 27 light/dark opacity (25% / 35%)
    let grabbers = t.drawn_rect_corners().filter(fn(r) {
      (r.2 - 58.0).abs() <= 0.5 && (r.3 - 4.0).abs() <= 0.5 && (r.1 - sy - 6.0).abs() <= 0.5
    })
    assert_eq(grabbers.length(), 1, msg="dark=\{dark}: expected 58x4pt grabber at y=6..10pt")
    let alpha_byte = grabbers[0].4 & 0xFFL
    if dark {
      assert_true(alpha_byte >= 87L && alpha_byte <= 91L, msg="dark grabber alpha \{alpha_byte} expected ~89 (35%)")
    } else {
      assert_true(alpha_byte >= 62L && alpha_byte <= 66L, msg="light grabber alpha \{alpha_byte} expected ~64 (25%)")
    }
    assert_eq(t.audit(), [], msg="dark=\{dark}: audit")
    assert_eq(t.corner_faults(), [], msg="dark=\{dark}: corners")
    // Tapping the 44pt close button dismisses the sheet cleanly
    t.tap(cx + cw / 2.0, cy + ch / 2.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(t.all(Dialog, label="全部迁移").length(), 0, msg="dark=\{dark}: close button dismissed sheet")
  }
  // Restore light mode after the dark loop before running light-mode testers below
  set_dark(None)
  // Untitled menu sheet has neither back nor close button
  presenters_reset()
  let tm = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(bg) { bg.over(Is(true)).ground(By(fn() { theme().p.bg })) |> ignore }) |> ignore
      presented_nodes(root)
    },
    w=390.0,
    h=844.0,
    platform=1,
  )
  tm.draw()
  menu([Some(menu_item_of("编辑", fn() {  }))], from=At(200.0, 700.0, 20.0, 20.0))
  tm.run_for(@ui.move_most_ms)
  assert_eq(tm.all(Button, label=close_lbl).length(), 0, msg="untitled menu sheet must not show close button")
  assert_eq(tm.all(Button, label=back_lbl).length(), 0, msg="untitled menu sheet must not show back button")
  // Step sheet has BOTH 44pt concentric `<` at (16, 16) and 44pt concentric `×` at (sw - 60, 16), matching iOS 27,
  // and shares exact 38.0pt title vertical midpoint with root sheet title (zero jump on push/pop)
  presenters_reset()
  let ts = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(bg) { bg.over(Is(true)).ground(By(fn() { theme().p.bg })) |> ignore }) |> ignore
      presented_nodes(root)
    },
    w=390.0,
    h=844.0,
    platform=1,
  )
  ts.draw()
  panel_nodes("第一步", from=Unanchored, steps=true, fn(v, _) {
    v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
  })
  panel_go_nodes("申请钥匙", fn(v, _) {
    v.box(fn(b) { words_node(b, fn() { "下一步" }, fn() { dialog_lead }) |> ignore }) |> ignore
  })
  ts.run_for(@ui.move_most_ms)
  let ss = ts.all(Dialog, label="申请钥匙")
  let st = ts.words().filter(fn(w) { w.0 == "申请钥匙" })
  guard ss.length() == 1 && st.length() == 1 else { @halt.saying("step sheet missing dialog/title") }
  let (ssx, ssy, ssw, _) = ss[0].rect
  let step_title_mid = st[0].2 + st[0].4 / 2.0 - ssy
  assert_eq(step_title_mid.round(), 38.0, msg="step sheet title mid \{step_title_mid}pt")
  let step_backs = ts.all(Button, label=back_lbl)
  let step_closes = ts.all(Button, label=close_lbl)
  assert_eq(step_backs.length(), 1, msg="step sheet back button")
  assert_eq(step_closes.length(), 1, msg="step sheet close button")
  assert_true((step_backs[0].rect.0 - (ssx + 16.0)).abs() <= 0.5 && (step_backs[0].rect.1 - (ssy + 16.0)).abs() <= 0.5, msg="step back at (16, 16)")
  assert_true((step_closes[0].rect.0 - (ssx + ssw - 60.0)).abs() <= 0.5 && (step_closes[0].rect.1 - (ssy + 16.0)).abs() <= 0.5, msg="step close at (sw - 60, 16)")
  let step_audit = ts.audit()
  assert_eq(step_audit, [], msg="step sheet audit: \{Repr(step_audit)}")
  assert_eq(ts.corner_faults(), [], msg="step sheet corners")
  // Tapping `×` on step 2 closes the whole sheet at once
  ts.tap(step_closes[0].rect.0 + 22.0, step_closes[0].rect.1 + 22.0)
  ts.run_for(@ui.move_most_ms)
  assert_eq(ts.all(Dialog, label="申请钥匙").length(), 0, msg="step close button dismissed whole sheet")
  assert_eq(ts.all(Dialog, label="第一步").length(), 0, msg="step close button did not leave root step open")
  // Long stepped title + step counter ("2 / 3") on a narrow 360pt sheet: stays strictly between `<` and `×` with zero overlap
  presenters_reset()
  let tl = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(bg) { bg.over(Is(true)).ground(By(fn() { theme().p.bg })) |> ignore }) |> ignore
      presented_nodes(root)
    },
    w=360.0,
    h=740.0,
    platform=1,
  )
  tl.draw()
  panel_nodes("第一步", from=Unanchored, steps=true, fn(v, _) {
    v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
  })
  panel_go_nodes("加入工作区群聊服务器配置向导", live=fn() { ("加入工作区群聊服务器配置向导", "2 / 3", "") }, fn(v, _) {
    v.box(fn(b) { words_node(b, fn() { "下一步" }, fn() { dialog_lead }) |> ignore }) |> ignore
  })
  tl.run_for(@ui.move_most_ms)
  let lb = tl.all(Button, label=back_lbl)
  let lc = tl.all(Button, label=close_lbl)
  let ls = tl.words().filter(fn(w) { w.0 == "2 / 3" })
  let lt = tl.words().filter(fn(w) { w.0.has_prefix("加入工作区") })
  assert_eq(lb.length(), 1, msg="360pt stepped back button")
  assert_eq(lc.length(), 1, msg="360pt stepped close button")
  assert_eq(ls.length(), 1, msg="360pt stepped counter visible")
  assert_eq(lt.length(), 1, msg="360pt stepped title visible")
  assert_true(lt[0].1 >= lb[0].rect.0 + lb[0].rect.2, msg="360pt title clears back key")
  assert_true(ls[0].1 + ls[0].3 <= lc[0].rect.0, msg="360pt step counter clears close key")
  assert_eq(tl.audit(), [], msg="360pt long stepped sheet audit")
  assert_eq(tl.corner_faults(), [], msg="360pt long stepped sheet corners")
  // Wide confirm and ask dialogs both use unified 17/22pt titles with concentric 36pt Liquid Glass close keys on line 1
  presenters_reset()
  let tw = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(bg) { bg.over(Is(true)).ground(By(fn() { theme().p.bg })) |> ignore }) |> ignore
      presented_nodes(root)
    },
    w=960.0,
    h=680.0,
    platform=0,
  )
  tw.draw()
  confirm("全部迁移", "9 项 · 1 项无法迁移", "确定", fn() {  })
  tw.run_for(@ui.move_most_ms)
  let wd = tw.all(Dialog, label="全部迁移")
  let wt = tw.words().filter(fn(w) { w.0 == "全部迁移" })
  let wc = tw.all(Button, label=close_lbl)
  guard wd.length() == 1 && wt.length() == 1 && wc.length() == 1 else {
    @halt.saying("wide confirm missing dialog/title/close")
  }
  assert_eq((wt[0].2 + wt[0].4 / 2.0 - wd[0].rect.1).round(), 38.0, msg="wide confirm title mid aligned to 36pt close at 38pt")
  assert_eq(wt[0].4.round(), 22.0, msg="wide confirm title line expected 22pt")
  assert_true((wc[0].rect.2 - 36.0).abs() <= 0.5 && (wc[0].rect.3 - 36.0).abs() <= 0.5, msg="wide confirm close 36x36pt")
  assert_true((wc[0].rect.0 - (wd[0].rect.0 + wd[0].rect.2 - 56.0)).abs() <= 0.5 && (wc[0].rect.1 - (wd[0].rect.1 + 20.0)).abs() <= 0.5, msg="wide confirm close concentric at (dw - 56, 20)")
  assert_eq(tw.audit(), [])
  assert_eq(tw.corner_faults(), [])
  tw.tap(wc[0].rect.0 + 18.0, wc[0].rect.1 + 18.0)
  tw.run_for(@ui.move_most_ms)
  assert_eq(tw.all(Dialog, label="全部迁移").length(), 0, msg="wide confirm close dismissed dialog")
  ask("重命名对话", "保存", fn(_) {  })
  tw.run_for(@ui.move_most_ms)
  let ad = tw.all(Dialog, label="重命名对话")
  let at_w = tw.words().filter(fn(w) { w.0 == "重命名对话" })
  let ac = tw.all(Button, label=close_lbl)
  guard ad.length() == 1 && at_w.length() == 1 && ac.length() == 1 else {
    @halt.saying("wide ask missing dialog/title/close")
  }
  assert_eq(at_w[0].4.round(), 22.0, msg="wide ask title line expected 22pt")
  assert_true((ac[0].rect.2 - 36.0).abs() <= 0.5 && (ac[0].rect.3 - 36.0).abs() <= 0.5, msg="wide ask close 36x36pt")
  assert_eq(tw.audit(), [])
  assert_eq(tw.corner_faults(), [])
  tw.tap(ac[0].rect.0 + 18.0, ac[0].rect.1 + 18.0)
  tw.run_for(@ui.move_most_ms)
  assert_eq(tw.all(Dialog, label="重命名对话").length(), 0, msg="wide ask close dismissed dialog")
}
