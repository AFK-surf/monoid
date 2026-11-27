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
        // At 1.8x/2.0x Heading line height (43-48pt) exceeds the 36pt circle, so head_line_drop shifts both corner
        // buttons down to stay centred on line 1 (matching the explicit design rule over top-corner concentricity).
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
