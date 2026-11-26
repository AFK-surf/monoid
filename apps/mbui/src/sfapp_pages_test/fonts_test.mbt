// 外观 › 字体 (settings/fonts.mbt) and the faces the app is then set in (faces.mbt), over the settings'
// fixture and its made-up faces (fonts_fixture.mbt).

///|
test "外观's 字体 row: the faces at a glance, opening the page: the places, a chat as they set it, the faces with their sizes" {
  let t = settings_tester("appearance")
  assert_true(t.find("字体") is Some(_))
  // none chosen: the app's own, its setting's row (after 主题)
  assert_true(t.find("默认") is Some(_))
  // (its words whole: 拖入 chat 的文件's note says 默认 too)
  let said = t.words().filter(fn(w) { w.0 == "默认" && w.5 > 0.5 })
  assert_eq(said.length(), 1)
  t.tap(said[0].1 + said[0].3 / 2.0, said[0].2 + said[0].4 / 2.0)
  t.run_for(@ui.move_most_ms)
  // the places in the pairing matrix & sticky preview
  for w in ["界面", "正文", "代码"] {
    assert_true(t.find(w) is Some(_))
  }
  // the chat as the faces set it: their message, the agent's under its name
  assert_true(t.find("登录页在 Safari 上点了没反应") is Some(_))
  assert_true(t.find("Claude") is Some(_))
  // open 界面西文 slot popover: strictly Latin curated faces (no CJK, no mono)
  tap_matrix_slot(t, 0, false)
  t.run_for(@ui.move_most_ms)
  // the interface's Latin faces, each with how big it is to fetch (in thousands, as Android says it)
  assert_true(t.query(Button, label="Inter") is Some(_))
  assert_true(t.find("458 kB") is Some(_))
  assert_true(t.query(Button, label="思源黑体") is None)
  assert_true(t.query(Button, label="JetBrains Mono") is None)
  // each shown in itself: its preview given to a face of its own
  assert_true(@ui.face_given(preview_faces_from))
  // close popover by tapping outside, then open 界面中文 slot popover: strictly CJK curated faces
  t.tap(8.0, 8.0)
  t.run_for(@ui.move_most_ms)
  tap_matrix_slot(t, 0, true)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="思源黑体") is Some(_))
  assert_true(t.find("11 MB") is Some(_))
  assert_true(t.query(Button, label="Inter") is None)
  // code's: close popover and open 代码等宽 slot -> code faces, 默认 in the app's own (JetBrains Mono)
  t.tap(8.0, 8.0)
  t.run_for(@ui.move_most_ms)
  tap_matrix_slot(t, 2, false)
  t.run_for(@ui.move_most_ms)
  let _ = picker_row_center(t, "Fira Code")
  assert_true(t.query(Button, label="Fira Code") is Some(_))
  assert_true(t.find("91 kB") is Some(_))
  assert_true(t.query(Button, label="思源黑体") is None)
  assert_true(@ui.face_given(own_code_face))
}

///|
test "a face picked: kept as the device's, fetched, unzipped and checked, and what people write set in it; 跟随界面 puts it back" {
  let t = settings_tester("fonts")
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="跟随界面") is Some(_))
  assert_false(@ui.face_given(@hostapi.face_text_cjk))
  tap_picker_row(t, "霞鹜文楷")
  t.run_for(@ui.move_most_ms)
  // fetched (the core had none of it), its two files unzipped, checked, and given for what people write (CJK)
  assert_true(face_here("lxgw-wenkai"))
  assert_true(@ui.face_given(@hostapi.face_text_cjk))
  // the interface's stays the app's own
  assert_false(@ui.face_given(@hostapi.face_ui_cjk))
  // reopen 正文中文: here -> no size said any more, and 跟随界面 puts it back
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("26 MB") is None)
  tap_picker_row(t, "跟随界面")
  t.run_for(@ui.move_most_ms)
  assert_false(face_here("lxgw-wenkai"))
  assert_false(@ui.face_given(@hostapi.face_text_cjk))
}

///|
test "a face being fetched: how far said on its row, the app's own standing in until it is here" {
  let t = settings_tester("fonts", mode="settings-fonts-coming", shows="settings-fonts-coming")
  tap_place(t, "界面")
  t.draw()
  t.wheel(200.0, 620.0, 520.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("正在下载 42%") is Some(_))
  assert_false(face_here("noto-sans-sc"))
  assert_false(@ui.face_given(@hostapi.face_ui))
}

///|
/// The made-up prefs with each place's face's files said kept here (`path`, as the core says it of those this device
/// keeps: client/core-ts/src/fonts.ts setKeptAt), at `/data/` and the file's weight.
fn kept_here(base : Source) -> Source {
  {
    ..base,
    topic_read: fn(name, params) {
      let t = base.topic(name, params).get().snapshot()
      if name == "prefs" {
        match field(t.value, "faces") {
          Some(Object(faces)) =>
            for place in ["ui", "text", "code"] {
              for f in items(faces.get(place), "files") {
                match f {
                  Object(m) => m["path"] = ToJson::to_json("/data/" + number(Some(f), "weight").to_int().to_string())
                  _ => ()
                }
              }
            }
          _ => ()
        }
      }
      t
    },
  }
}

///|
test "a face kept here: given by where its files are the frame the prefs come, the first page set in it, nothing asked of the core" {
  new_run()
  let base = fixture("home")
  (base.call)("prefs.set", { "fonts": { "ui": "noto-sans-sc" } }, fn(_) {  })
  let asked = Ref(0)
  let src : Source = {
    ..kept_here(base),
    read_bytes: fn(name, params, done) {
      if name == "fonts.file" {
        asked.val += 1
      }
      (base.read_bytes)(name, params, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.draw()
  assert_true(t.find("整理发布清单") is Some(_))
  assert_true(face_here("noto-sans-sc"))
  assert_true(@ui.face_given(@hostapi.face_ui))
  assert_eq(asked.val, 0)
}

///|
test "a face's file the host cannot read where it is: had through the core instead, unzipped and checked" {
  new_run()
  let base = fixture("home")
  // fetched, kept as fetched (gzipped): what the host cannot read as a face
  (base.call)("fonts.fetch", { "id": "lxgw-wenkai" }, fn(_) {  })
  let asked = Ref(0)
  let src : Source = {
    ..kept_here(base),
    read_bytes: fn(name, params, done) {
      if name == "fonts.file" {
        asked.val += 1
      }
      (base.read_bytes)(name, params, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  // (the face chosen once the host is set so: the app's tree gives the places' faces as its window is first given,
  // before anything of it is laid out, and as they are chosen)
  t.set_unreadable_font("/data/500")
  (base.call)("prefs.set", { "fonts": { "text": "lxgw-wenkai" } }, fn(_) {  })
  t.draw()
  t.draw()
  assert_eq(asked.val, 2)
  assert_true(face_here("lxgw-wenkai"))
  assert_true(@ui.face_given(@hostapi.face_text))
}

///|
test "an SVG picture with Chinese in its text: 思源黑体 had from the core for it, once" {
  new_run()
  let base = fixture("home")
  let fetched = Ref(0)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "fonts.fetch" {
        fetched.val += 1
      }
      (base.call)(name, params, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.draw()
  let own = @sfbase.vector_faces(b"<svg xmlns='http://www.w3.org/2000/svg'><text>Hello</text></svg>").length()
  t.draw()
  assert_eq(fetched.val, 0)
  // 流程
  let zh = b"<svg xmlns='http://www.w3.org/2000/svg'><text>\xe6\xb5\x81\xe7\xa8\x8b</text></svg>"
  assert_eq(@sfbase.vector_faces(zh).length(), own)
  // (asked by the frame that wanting it brings, nothing else happening)
  t.run_for(@ui.move_most_ms)
  assert_eq(fetched.val, 1)
  assert_eq(@sfbase.vector_faces(zh).length(), own + 1)
  t.draw()
  assert_eq(fetched.val, 1)
}

///|
/// Find the center of an exact font picker row button inside the open V8 Popover / Sheet,
/// scrolling the popover's own 265pt scroll list when the row is clipped outside the visible window.
fn picker_row_center(t : @ui.Tester, name : String) -> (Double, Double) raise {
  for _ in 0..<10 {
    match t.query(Button, label=name) {
      Some(s) => {
        let cx = s.rect.0 + s.rect.2 / 2.0
        let cy = s.rect.1 + s.rect.3 / 2.0
        let fields = t.semantics().filter(fn(f) { f.role is TextField })
        if fields.length() > 0 {
          let f = fields[fields.length() - 1].rect
          let list_top = f.1 + f.3 + 8.0
          let list_bot = list_top + 250.0
          if cy >= list_top + 8.0 && cy <= list_bot - 8.0 {
            return (cx, cy)
          }
          let dir = if cy < list_top + 8.0 { -110.0 } else { 110.0 }
          t.wheel(f.0 + f.2 / 2.0, list_top + 80.0, dir)
          t.run_for(@ui.move_most_ms)
        } else {
          return (cx, cy)
        }
      }
      None => {
        t.wheel(200.0, 360.0, 120.0)
        t.run_for(@ui.move_most_ms)
      }
    }
  }
  guard t.query(Button, label=name) is Some(s) else {
    fail("no picker row: " + name + " (picker_open=" + @sfpages.font_picker_open.untracked().to_string() + ")")
  }
  (s.rect.0 + s.rect.2 / 2.0, s.rect.1 + s.rect.3 / 2.0)
}

///|
fn tap_picker_row(t : @ui.Tester, name : String) -> Unit raise {
  let (x, y) = picker_row_center(t, name)
  t.tap(x, y)
}

///|
/// Tap a role zone in the live preview card (scrolls back to top on narrow viewports).
fn tap_place(t : @ui.Tester, place : String) -> Unit raise {
  for _ in 0..<6 {
    match t.query(Button, label=place) {
      Some(s) if s.rect.1 + s.rect.3 / 2.0 >= 40.0 => {
        t.tap(s.rect.0 + s.rect.2 / 2.0, s.rect.1 + s.rect.3 / 2.0)
        return
      }
      _ => {
        t.wheel(200.0, 480.0, -360.0)
        t.run_for(@ui.move_most_ms)
      }
    }
  }
  guard t.query(Button, label=place) is Some(s) else { fail("no role button: " + place) }
  t.tap(s.rect.0 + s.rect.2 / 2.0, s.rect.1 + s.rect.3 / 2.0)
}

///|
/// Open a specific `(role_idx, is_cjk)` slot trigger directly in the V8 3x2 pairing card
/// (`role_idx`: 0=ui, 1=text, 2=code; `is_cjk`: false=Latin/Mono, true=CJK).
fn tap_matrix_slot(t : @ui.Tester, role_idx : Int, is_cjk : Bool) -> Unit raise {
  let labels = [["界面西文", "界面中文"], ["正文西文", "正文中文"], ["代码等宽", "代码中文"]]
  let slot_label = labels[role_idx][if is_cjk { 1 } else { 0 }]
  for _ in 0..<8 {
    match t.query(Button, label=slot_label) {
      Some(s) => {
        let cx = s.rect.0 + s.rect.2 / 2.0
        let cy = s.rect.1 + s.rect.3 / 2.0
        if cy >= 56.0 && cy <= 760.0 {
          t.tap(cx, cy)
          return
        }
        let delta = if cy > 760.0 { 220.0 } else { -220.0 }
        t.wheel(cx, 360.0, delta)
        t.run_for(@ui.move_most_ms)
      }
      None => {
        t.wheel(195.0, 360.0, 220.0)
        t.run_for(@ui.move_most_ms)
      }
    }
  }
  guard t.query(Button, label=slot_label) is Some(s) else { fail("no slot trigger: " + slot_label) }
  t.tap(s.rect.0 + s.rect.2 / 2.0, s.rect.1 + s.rect.3 / 2.0)
}

///|
/// The width of the words as laid out, independent of where their line is on the page.
fn preview_width(t : @ui.Tester, words : String) -> Double raise {
  let rects = t.run_rects(words)
  assert_eq(rects.length(), 1)
  rects[0].2
}

///|
test "pointing at an interface or text face tries it on the whole message, keeping inline code in its own face" {
  for role_idx in [0, 1] {
    let t = wide_fonts_tester()
    tap_matrix_slot(t, role_idx, true)
    t.run_for(@ui.move_most_ms)
    // Distinguish the preview face without making the chat wrap and move the row out from under the pointer.
    t.face_wider(preview_faces_from + 2, 0.01)
    t.draw()
    let text_before = preview_width(t, "按钮的点击在表单提交之前被")
    let inline_before = preview_width(t, "preventDefault")
    let mine_before = preview_width(t, "登录页在 Safari 上点了没反应")
    let name_before = preview_width(t, "Claude")
    let (x, y) = picker_row_center(t, "思源宋体")
    t.move_to(x, y)
    t.draw()
    t.draw()
    let text_after = preview_width(t, "按钮的点击在表单提交之前被")
    let mine_after = preview_width(t, "登录页在 Safari 上点了没反应")
    let name_after = preview_width(t, "Claude")
    let row_after = t.query(Button, label="思源宋体").map(fn(s) { (s.rect.0, s.rect.1) })
    assert_true(text_after > text_before, msg="role_idx=\{role_idx} row_before=\{Repr((x, y))} row_after=\{Repr(row_after)} text=\{text_before},\{text_after} mine=\{mine_before},\{mine_after} name=\{name_before},\{name_after}")
    assert_eq(preview_width(t, "preventDefault"), inline_before)
    t.move_to(x, 4.0)
    t.draw()
    t.draw()
    assert_eq(preview_width(t, "按钮的点击在表单提交之前被"), text_before)
  }
}

///|
test "pointing at a code face tries it on inline code and the code block, keeping prose in its own face" {
  let t = wide_fonts_tester()
  tap_place(t, "代码")
  t.draw()
  t.face_wider(preview_faces_from + 5, 0.3)
  t.draw()
  let text_before = preview_width(t, "按钮的点击在表单提交之前被")
  let inline_before = preview_width(t, "preventDefault")
  let block_before = preview_width(t, "form.onsubmit")
  let (x, y) = picker_row_center(t, "Fira Code")
  t.move_to(x, y)
  t.draw()
  t.draw()
  assert_eq(preview_width(t, "按钮的点击在表单提交之前被"), text_before)
  assert_true(preview_width(t, "preventDefault") > inline_before)
  assert_true(preview_width(t, "form.onsubmit") > block_before)
  t.move_to(x, 4.0)
  t.draw()
  t.draw()
  assert_eq(preview_width(t, "preventDefault"), inline_before)
  assert_eq(preview_width(t, "form.onsubmit"), block_before)
}

///|
/// Open 外观 › 字体 in a desktop wide window (`1280×800`, where `sticky_head` pins the live preview above the picker).
fn wide_fonts_tester() -> @ui.Tester {
  let t = wide_tester([])
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "pointing at 跟随界面 previews the interface face even when a different text face is chosen" {
  let t = wide_fonts_tester()
  t.face_wider(@hostapi.face_ui_cjk, 0.05)
  tap_matrix_slot(t, 0, true)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "思源黑体")
  t.run_for(@ui.move_most_ms)
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "霞鹜文楷")
  t.run_for(@ui.move_most_ms)
  assert_true(@ui.face_given(@hostapi.face_ui_cjk))
  assert_true(@ui.face_given(@hostapi.face_text_cjk))
  let text_before = preview_width(t, "按钮的点击在表单提交之前被")
  let mine_before = preview_width(t, "登录页在 Safari 上点了没反应")
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  let (x, y) = picker_row_center(t, "跟随界面")
  t.move_to(x, y)
  t.draw()
  t.draw()
  assert_true(preview_width(t, "按钮的点击在表单提交之前被") > text_before)
  assert_true(preview_width(t, "登录页在 Safari 上点了没反应") > mine_before)
  t.move_to(x, 4.0)
  t.draw()
  t.draw()
  assert_eq(preview_width(t, "按钮的点击在表单提交之前被"), text_before)
  assert_eq(preview_width(t, "登录页在 Safari 上点了没反应"), mine_before)
}

///|
test "pointing at an interface face leaves a separately chosen text face alone" {
  let t = wide_fonts_tester()
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "霞鹜文楷")
  t.run_for(@ui.move_most_ms)
  tap_matrix_slot(t, 0, true)
  t.run_for(@ui.move_most_ms)
  t.face_wider(preview_faces_from + 2, 0.05)
  t.draw()
  let text_before = preview_width(t, "按钮的点击在表单提交之前被")
  let time_before = preview_width(t, "3 分钟前")
  let (x, y) = picker_row_center(t, "思源宋体")
  t.move_to(x, y)
  t.draw()
  t.draw()
  assert_eq(preview_width(t, "按钮的点击在表单提交之前被"), text_before)
  assert_true(preview_width(t, "3 分钟前") > time_before)
}

///|
test "a face pointed at tried in the chat above them: the chat held at its tallest while the pointer is on the faces, nothing under it shaking" {
  let t = wide_fonts_tester()
  tap_matrix_slot(t, 0, true)
  t.run_for(@ui.move_most_ms)
  // 思源黑体 set wide enough that their message wraps once more in it, 思源宋体 a little
  t.face_wider(preview_faces_from + 1, 0.6)
  t.face_wider(preview_faces_from + 2, 0.3)
  t.draw()
  let before = picker_row_center(t, "思源宋体")
  let (x, y) = picker_row_center(t, "思源黑体")
  t.move_to(x, y)
  t.draw()
  // tried: the chat taller, held at its tallest while picker is open so rows stay completely stable
  let moved = picker_row_center(t, "思源宋体")
  // moving pointer across rows while picker is open: nothing shakes
  for i in 0..<4 {
    t.move_to(x + 1.0 + i.to_double(), y)
    t.draw()
    assert_eq(picker_row_center(t, "思源宋体"), moved)
  }
  let (x2, y2) = moved
  t.move_to(x2, y2)
  t.draw()
  t.draw()
  assert_eq(picker_row_center(t, "思源宋体"), moved)
  // close popover -> height lock releases and preview returns to resting height
  t.tap(8.0, 8.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfpages.font_picker_open.untracked(), -1)
  // reopen -> 思源宋体 returns to its pre-hover resting position
  tap_matrix_slot(t, 0, true)
  t.run_for(@ui.move_most_ms)
  assert_eq(picker_row_center(t, "思源宋体"), before)
}

///|
test "curated presets: hover triggers 0 fetches; click overwrites all 6 slots, resets CJK optics, preserves reading typography" {
  new_run()
  let base = fixture("home")
  // Pre-set custom reading typography + custom CJK optics + custom codeCjk
  (base.call)(
    "prefs.set",
    {
      "fonts": { "ui": "lxgw-wenkai", "codeCjk": "maple-mono" },
      "typography": { "textSize": 120, "lineHeight": "relaxed", "uiCjkScale": 115, "uiCjkWeight": 100, "cjkAutoSpace": false },
    },
    fn(_) {  },
  )
  let fetched = Ref(0)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "fonts.fetch" {
        fetched.val += 1
      }
      (base.call)(name, params, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1200.0, h=820.0, platform=0)
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  // Hovering a style card must never trigger fonts.fetch; cold-start first hover + repeated hover/leave trigger 0 words_forgotten
  let (px, py) = t.find("现代无衬线").unwrap()
  let before_hover = fetched.val
  let before_forgotten = @ui.words_forgotten_count()
  t.move_to(px + 4.0, py + 4.0)
  t.draw()
  t.draw()
  assert_eq(fetched.val, before_hover)
  assert_eq(@ui.words_forgotten_count(), before_forgotten)
  t.move_to(px, 4.0)
  t.draw()
  t.move_to(px + 4.0, py + 4.0)
  t.draw()
  assert_eq(@ui.words_forgotten_count(), before_forgotten)
  // Clicking "现代无衬线" applies all 6 slots (clearing codeCjk), resets CJK optics, and preserves textSize/lineHeight/cjkAutoSpace
  t.tap(px + 4.0, py + 4.0)
  t.run_for(@ui.move_most_ms)
  let prefs = src.topic("prefs", {}).get().value
  let fonts = field(prefs, "fonts")
  let typo = field(prefs, "typography")
  assert_eq(text(fonts, "ui"), "inter")
  assert_eq(text(fonts, "uiCjk"), "noto-sans-sc")
  assert_eq(text(fonts, "text"), "")
  assert_eq(text(fonts, "textCjk"), "")
  assert_eq(text(fonts, "code"), "jetbrains-mono")
  assert_eq(text(fonts, "codeCjk"), "")
  // CJK optics reset to defaults (100 / 0)
  assert_eq(number(typo, "uiCjkScale").round().to_int(), 100)
  assert_eq(number(typo, "uiCjkWeight").round().to_int(), 0)
  // Reading typography preserved
  assert_eq(number(typo, "textSize").round().to_int(), 120)
  assert_eq(text(typo, "lineHeight"), "relaxed")
  assert_false(flag(typo, "cjkAutoSpace"))
  assert_true(prose_text_scale() > 1.19)
  assert_true(prose_line_scale() > 1.13)
}

///|
test "script switch: CJK slots, textCjk='none' breaks uiCjk inheritance, restoring followUi reconnects" {
  let t = wide_fonts_tester()
  // Open 界面中文 slot directly and pick 思源宋体
  tap_matrix_slot(t, 0, true)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="思源宋体") is Some(_))
  assert_true(t.query(Button, label="Inter") is None)
  tap_picker_row(t, "思源宋体")
  t.run_for(@ui.move_most_ms)
  assert_true(@ui.face_given(@hostapi.face_ui_cjk))
  // Open 正文中文: should show 跟随界面 with 当前：思源宋体 and 不单独指定（随西文）
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  let _ = picker_row_center(t, "跟随界面")
  assert_true(t.find("当前：思源宋体") is Some(_))
  assert_true(t.query(Button, label="不单独指定（随西文）") is Some(_))
  // Pick 不单独指定（随西文） -> textCjk="none"
  tap_picker_row(t, "不单独指定（随西文）")
  t.run_for(@ui.move_most_ms)
  assert_false(@ui.face_given(@hostapi.face_text_cjk))
  // Reopen 正文中文 and restore 跟随界面 -> textCjk=null
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "跟随界面")
  t.run_for(@ui.move_most_ms)
  assert_true(@ui.face_given(@hostapi.face_ui_cjk))
  assert_false(@ui.face_given(@hostapi.face_text_cjk))
}

///|
test "hovering CJK row previews locally with 0 words_forgotten and never pollutes inline code" {
  let t = wide_fonts_tester()
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  // Give 思源宋体's preview slot extra width so CJK text widens when hovered
  t.face_wider(preview_faces_from + 2, 0.05)
  t.draw()
  let forgotten_before = @ui.words_forgotten_count()
  let text_before = preview_width(t, "按钮的点击在表单提交之前被")
  let inline_before = preview_width(t, "preventDefault")
  let (x, y) = picker_row_center(t, "思源宋体")
  t.move_to(x, y)
  t.draw()
  t.draw()
  // Zero global glyph invalidation!
  assert_eq(@ui.words_forgotten_count(), forgotten_before)
  assert_true(preview_width(t, "按钮的点击在表单提交之前被") > text_before)
  assert_eq(preview_width(t, "preventDefault"), inline_before)
  t.move_to(x, 4.0)
  t.draw()
  t.draw()
  assert_eq(@ui.words_forgotten_count(), forgotten_before)
  assert_eq(preview_width(t, "按钮的点击在表单提交之前被"), text_before)
}

///|
test "local font panel: smart filter toggle (仅中文 / 仅等宽 / 全部) and localized name search via set_local_font_info" {
  let t = wide_tester([])
  t.host_says_finger(Some(false))
  t.set_local_fonts("[\"PingFang SC\",\"JetBrains Mono\",\"Helvetica\"]")
  t.set_local_font_info(
    "[{\"name\":\"PingFang SC\",\"localized\":\"苹方-简\",\"mono\":false,\"serif\":false,\"cjk\":true},{\"name\":\"JetBrains Mono\",\"localized\":\"JetBrains Mono\",\"mono\":true,\"serif\":false,\"cjk\":false},{\"name\":\"Helvetica\",\"localized\":\"Helvetica\",\"mono\":false,\"serif\":false,\"cjk\":false}]",
  )
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  // Open 界面中文 unified popover: both 精选字体 and 本机字体 are shown, smart-filtered to CJK
  tap_matrix_slot(t, 0, true)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("精选字体") is Some(_))
  assert_true(t.find("本机字体") is Some(_))
  // Smart default 仅中文 shows 苹方-简 and hides Helvetica (scroll popover list to local section)
  let _ = picker_row_center(t, "苹方-简")
  assert_true(t.find("苹方-简") is Some(_))
  assert_true(t.find("Helvetica") is None)
  // Toggle to 全部 -> reveals Helvetica alongside 苹方-简
  tap_picker_row(t, "全部")
  t.run_for(@ui.move_most_ms)
  let _ = picker_row_center(t, "Helvetica")
  assert_true(t.find("Helvetica") is Some(_))
  assert_true(t.find("苹方-简") is Some(_))
  // Hovering a local font uses isolated local_try_face (slot 7)
  let (lx, ly) = picker_row_center(t, "苹方-简")
  t.move_to(lx, ly)
  t.draw()
  assert_eq(t.family_given(local_try_face), "PingFang SC")
  // Close and open 代码等宽 -> smart default shows JetBrains Mono and hides 苹方-简
  t.tap(8.0, 8.0)
  t.run_for(@ui.move_most_ms)
  tap_matrix_slot(t, 2, false)
  t.run_for(@ui.move_most_ms)
  let _ = picker_row_center(t, "JetBrains Mono")
  assert_true(t.find("JetBrains Mono") is Some(_))
  assert_true(t.find("苹方-简") is None)
}

///|
test "collapsible advanced typography section: expand, toggle autospace & ligatures, reset to defaults" {
  let t = wide_tester([])
  t.host_says_finger(Some(false))
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  // Top-level reading controls (正文阅读字号 & 正文行距) are immediately visible without expanding
  assert_true(t.find("正文阅读字号") is Some(_))
  assert_true(t.find("正文行距") is Some(_))
  // Pick 舒展 line height right on the main page -> updates prose_line_scale and bumps typography_version
  let ver_before = typography_version()
  t.tap_text("舒展")
  t.draw()
  assert_true(prose_line_scale() > 1.13)
  assert_true(typography_version() > ver_before)
  // Scroll down so the collapsed advanced toggle is in the viewport
  t.wheel(700.0, 520.0, 320.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("阅读与排版") is Some(_))
  assert_true(t.find("代码相对字号") is None)
  // Expand advanced drawer
  t.tap_text("阅读与排版")
  t.run_for(@ui.move_most_ms)
  t.wheel(700.0, 520.0, 360.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("代码相对字号") is Some(_))
  assert_true(t.find("中西文自动留白") is Some(_))
  assert_true(t.find("正文 Abc") is Some(_))
  assert_true(t.find("代码连字") is Some(_))
  // Toggle 中西文自动留白 off -> summary shows 已调 1 项 (outer lineHeight is NOT counted in advanced drawer)
  assert_true(@ui.cjk_autospace())
  guard t.query(Switch, label="中西文自动留白") is Some(sw) else { fail("no 中西文自动留白 switch") }
  t.tap(sw.rect.0 + sw.rect.2 / 2.0, sw.rect.1 + sw.rect.3 / 2.0)
  t.draw()
  assert_false(@ui.cjk_autospace())
  // Changing global CJK weight (writes uiCjkWeight/codeCjkWeight) counts as 1 visible control -> 已调 2 项
  t.tap_text("偏粗")
  t.draw()
  for _ in 0..<6 {
    if t.words().any(fn(w) { w.0 == "恢复默认排版" && w.5 > 0.5 }) {
      break
    }
    t.wheel(700.0, 520.0, -240.0)
    t.run_for(@ui.move_most_ms)
  }
  assert_true(t.find("已调 2 项") is Some(_))
  // Scoped 恢复默认排版 restores cjkAutoSpace & CJK weight while PRESERVING outer lineHeight ("relaxed")
  let resets = t.words().filter(fn(w) { w.0 == "恢复默认排版" && w.5 > 0.5 })
  assert_true(resets.length() > 0)
  let r_btn = resets[resets.length() - 1]
  t.tap(r_btn.1 + r_btn.3 / 2.0, r_btn.2 + r_btn.4 / 2.0)
  t.draw()
  assert_true(prose_line_scale() > 1.13)
  assert_true(@ui.cjk_autospace())
  assert_true(t.find("已调 2 项") is None)
}

///|
test "preview charset guard: every CJK char in font preview & V4 specimens exists in published preview-*.ttf" {
  fresh_app()
  // Exact CJK characters baked into published preview-*.ttf by scripts/fonts.py (NAMES + existing web-pages.appearance.fonts.* + punctuation).
  let published_cjk = "思源黑体思源宋体霞鹜文楷字体界面正文和代码各用什么默认跟随本机无法读取预览天地玄黄宇宙洪荒登录页在上点了没反应分钟前都试过了搜索没有匹配的按钮点击表单提交之前被吞掉改成里处理，。：、·…“”‘’（）"
  let preview_strings = [
    @sf.t("web-pages.appearance.fonts.sampleMine"),
    @sf.t("web-pages.appearance.fonts.sampleTime"),
    @sf.t("web-pages.appearance.fonts.sampleText"),
    @sfpages.fp_sample_code,
    @sf.t("web-pages.appearance.fonts.sampleAfter"),
    @sf.t("web-pages.appearance.fonts.sampleCjk"),
    "Aa 字",
    "Aa 字体",
    "正文Abc",
    "正文 Abc",
  ]
  for s in preview_strings {
    for ch in s {
      let cp = ch.to_int()
      if cp >= 0x2E80 {
        assert_true(
          published_cjk.contains_char(ch),
          msg="preview char '\{ch}' (U+\{cp}) is missing from published preview-*.ttf charset",
        )
      }
    }
  }
}

///|
test "chat typography scaling: enlarging textSize preserves at-foot state, exact numbered history anchor, and composer CJK input" {
  new_run()
  let src = fixture("chat-long")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1200.0, h=800.0, platform=0)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  t.run_for(@ui.move_most_ms)
  assert_eq(prose_text_scale(), 1.0)
  assert_eq(code_text_scale(), 1.0)
  let ver0 = typography_version()
  let forgotten0 = @ui.words_forgotten_count()
  // (a) Verify unique foot message "第 2999 条" is visible at foot before scaling
  let (_, fy_before) = t.find("第 2999 条").unwrap()
  // Scale prose to 130% + relaxed line height via prefs.set
  (src.call)("prefs.set", { "typography": { "textSize": 130, "lineHeight": "relaxed" } }, fn(_) {  })
  t.run_for(@ui.move_most_ms)
  assert_true(prose_text_scale() > 1.29)
  assert_true(prose_line_scale() > 1.13)
  assert_true(typography_version() > ver0)
  // Scaling typography does not trigger global glyph cache invalidation
  assert_eq(@ui.words_forgotten_count(), forgotten0)
  // At-foot state preserved strictly: last message stays pinned at the foot (wheeling down moves it by <= 2.0pt)
  let foot_after = t.find("第 2999 条")
  let fy_after = match foot_after {
    Some((_, fy)) => fy
    None => fail("第 2999 条 disappeared after scaling")
  }
  t.wheel(700.0, 360.0, 240.0)
  t.run_for(@ui.move_most_ms)
  let fy_pinned = match t.find("第 2999 条") {
    Some((_, fy)) => fy
    None => fail("第 2999 条 disappeared after foot wheel check")
  }
  assert_true(
    (fy_after - fy_pinned).abs() <= 2.0,
    msg="not strictly at foot after scaling: fy_after=\{fy_after} fy_pinned=\{fy_pinned} fy_before=\{fy_before}",
  )
  // (b) Scroll up into history (past long_reply), pick a FULL unique numbered message (e.g. "第 NNNN 条" / "第 NNNN 步"), scale typography, verify same unique message stays anchored within <= 40pt
  t.wheel(700.0, 360.0, -1400.0)
  t.run_for(@ui.move_most_ms)
  let mut full_anchor = ""
  let mut before_y = 0.0
  for seq in 2900..<3000 {
    for suffix in [" 条", " 步"] {
      let cand = "第 \{seq}\{suffix}"
      match t.find(cand) {
        Some((_, y)) if y > 80.0 && y < 680.0 => {
          full_anchor = cand
          before_y = y
        }
        _ => ()
      }
    }
  }
  assert_true(full_anchor != "")
  (src.call)("prefs.set", { "typography": { "textSize": 115, "lineHeight": "normal" } }, fn(_) {  })
  t.run_for(@ui.move_most_ms)
  let anchor_after = t.find(full_anchor)
  let after_y_str = match anchor_after {
    Some((_, y)) => "\{y}"
    None => "none"
  }
  assert_true(
    anchor_after is Some((_, y)) && y >= 0.0 && y <= 800.0 && (y - before_y).abs() <= 40.0,
    msg="full_anchor=\{full_anchor} before_y=\{before_y} after_y=\{after_y_str}",
  )
  // (c) Verify composer accepts Chinese IME composition (preedit) and commit cleanly at enlarged scale
  let fields = t.semantics().filter(fn(s) { s.role is TextField })
  assert_true(fields.length() > 0)
  let (fx, fy, fw, fh) = fields[0].rect
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  t.frame()
  t.compose("zhongwen")
  t.frame()
  t.type_text("中文排版测试")
  t.frame()
  assert_eq(t.semantics().filter(fn(s) { s.role is TextField })[0].value, "中文排版测试")
}

///|
test "local hover triggers 0 words_forgotten; hovering Classic Default after local Menlo bypasses Menlo" {
  let t = wide_tester([])
  t.host_says_finger(Some(false))
  t.set_local_fonts("[\"Menlo\",\"Helvetica Neue\",\"PingFang SC\"]")
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  t.ui_face_wider(0.04)
  t.draw()
  // Open 界面 row and switch to inline local font tab, hover two consecutive families -> 0 global words_forgotten
  tap_place(t, "界面")
  t.draw()
  t.wheel(700.0, 520.0, 320.0)
  t.run_for(@ui.move_most_ms)
  t.tap_text("本机字体")
  t.run_for(@ui.move_most_ms)
  let forgotten0 = @ui.words_forgotten_count()
  let (mx, my) = t.find("Menlo").unwrap()
  t.move_to(mx, my)
  t.draw()
  let (hx, hy) = t.find("Helvetica Neue").unwrap()
  t.move_to(hx, hy)
  t.draw()
  assert_eq(@ui.words_forgotten_count(), forgotten0)
  // Apply local Menlo to ui
  t.tap(mx, my)
  t.run_for(@ui.move_most_ms)
  let w_menlo = preview_width(t, "Claude")
  // Scroll back up to style cards and hover Classic Default -> preview must NOT stay on Menlo width
  for _ in 0..<6 {
    t.wheel(700.0, 520.0, -300.0)
    t.run_for(@ui.move_most_ms)
  }
  let (cx, cy) = t.find("经典默认").unwrap()
  t.move_to(cx + 4.0, cy + 4.0)
  t.draw()
  t.draw()
  let w_hover_default = preview_width(t, "Claude")
  assert_true(w_hover_default < w_menlo - 1.0, msg="hover=\{w_hover_default} menlo=\{w_menlo}")
  // Clicking Classic Default matches hovered preview
  t.tap(cx + 4.0, cy + 4.0)
  t.run_for(@ui.move_most_ms)
  let w_applied_default = preview_width(t, "Claude")
  assert_true((w_hover_default - w_applied_default).abs() < 4.0, msg="hover=\{w_hover_default} applied=\{w_applied_default}")
}

///|
test "short viewport 390x300 scrolls to and selects style cards and font rows; reset all + undo restores" {
  new_run()
  let src = fixture("settings")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=300.0, platform=0)
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  // Scroll down past the non-sticky preview card to reach style cards
  for _ in 0..<10 {
    match t.find("现代无衬线") {
      Some((_, y)) if y >= 72.0 && y <= 240.0 => break
      Some((_, y)) => {
        t.wheel(195.0, 150.0, if y > 240.0 { 80.0 } else { -80.0 })
        t.run_for(@ui.move_most_ms)
      }
      None => {
        t.wheel(195.0, 150.0, 80.0)
        t.run_for(@ui.move_most_ms)
      }
    }
  }
  let (sx, sy) = t.find("现代无衬线").unwrap()
  assert_true(sy >= 0.0 && sy <= 300.0)
  t.tap(sx + 4.0, sy + 4.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(text(field(src.topic("prefs", {}).get().value, "fonts"), "ui"), "inter")
  // Tap 界面中文 slot trigger to open Bottom Sheet and select 思源宋体
  for _ in 0..<12 {
    match t.query(Button, label="界面中文") {
      Some(s) if s.rect.1 + s.rect.3 / 2.0 >= 40.0 && s.rect.1 + s.rect.3 / 2.0 <= 260.0 => {
        t.tap(s.rect.0 + s.rect.2 / 2.0, s.rect.1 + s.rect.3 / 2.0)
        t.run_for(@ui.move_most_ms)
        break
      }
      _ => {
        t.wheel(195.0, 150.0, 140.0)
        t.run_for(@ui.move_most_ms)
      }
    }
  }
  for _ in 0..<12 {
    match t.query(Button, label="思源宋体") {
      Some(s) if s.rect.1 + s.rect.3 / 2.0 >= 40.0 && s.rect.1 + s.rect.3 / 2.0 <= 280.0 => break
      _ => {
        t.wheel(195.0, 200.0, 100.0)
        t.run_for(@ui.move_most_ms)
      }
    }
  }
  guard t.query(Button, label="思源宋体") is Some(fb) else { fail("no 思源宋体 picker button") }
  let fy = fb.rect.1 + fb.rect.3 / 2.0
  assert_true(fy >= 0.0 && fy <= 300.0)
  t.tap(fb.rect.0 + fb.rect.2 / 2.0, fy)
  t.run_for(@ui.move_most_ms)
  assert_eq(text(field(src.topic("prefs", {}).get().value, "fonts"), "uiCjk"), "noto-serif-sc")
  // Scroll back to 全部恢复默认 in the 推荐风格 header, click it, then 撤销 restores ui=inter & uiCjk=noto-serif-sc
  for _ in 0..<12 {
    match t.query(Button, label="全部恢复默认") {
      Some(s) if s.rect.1 + s.rect.3 / 2.0 >= 40.0 && s.rect.1 + s.rect.3 / 2.0 <= 260.0 => break
      Some(s) => {
        let dir = if s.rect.1 + s.rect.3 / 2.0 > 260.0 { 120.0 } else { -120.0 }
        t.wheel(195.0, 150.0, dir)
        t.run_for(@ui.move_most_ms)
      }
      None => {
        t.wheel(195.0, 150.0, -160.0)
        t.run_for(@ui.move_most_ms)
      }
    }
  }
  t.click(Button, label="全部恢复默认")
  t.run_for(@ui.move_most_ms)
  assert_eq(text(field(src.topic("prefs", {}).get().value, "fonts"), "ui"), "")
  assert_eq(text(field(src.topic("prefs", {}).get().value, "fonts"), "uiCjk"), "")
  t.click(Button, label="撤销")
  t.run_for(@ui.move_most_ms)
  assert_eq(text(field(src.topic("prefs", {}).get().value, "fonts"), "ui"), "inter")
  assert_eq(text(field(src.topic("prefs", {}).get().value, "fonts"), "uiCjk"), "noto-serif-sc")
}

///|
test "cross-breakpoint resize 1280 -> 390 -> 1280 preserves slot selection and open picker cleanly" {
  new_run()
  let src = fixture("settings")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=820.0, platform=0)
  t.set_local_fonts("[\"Menlo\",\"PingFang SC\"]")
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  assert_eq(@settings.fonts_at.untracked(), 1)
  assert_eq(@settings.fonts_script_at.untracked(), 1)
  assert_eq(@sfpages.font_picker_open.untracked(), 3)
  assert_true(@sfpages.local_open.untracked())
  t.resize(390.0, 820.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(@settings.fonts_at.untracked(), 1)
  assert_eq(@settings.fonts_script_at.untracked(), 1)
  // Reopen 正文中文 cleanly on Small (Bottom Sheet)
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfpages.font_picker_open.untracked(), 3)
  assert_true(@sfpages.local_open.untracked())
  t.resize(1280.0, 820.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(@settings.fonts_at.untracked(), 1)
  assert_eq(@settings.fonts_script_at.untracked(), 1)
  // Reopen 正文中文 cleanly on Large (Popover)
  tap_matrix_slot(t, 1, true)
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfpages.font_picker_open.untracked(), 3)
  assert_true(@sfpages.local_open.untracked())
}

///|
test "undo_reset emits core-ts typographyPut-safe payload (no *Own keys, preserves inherited textCjkScale/Weight as null)" {
  new_run()
  let base = fixture("settings")
  // Set uiCjk + uiCjkScale=115 without setting textCjkScaleOwn -> textCjkScale inherits from uiCjkScale
  (base.call)(
    "prefs.set",
    {
      "fonts": { "ui": "inter", "uiCjk": "noto-sans-sc" },
      "typography": { "textSize": 115, "uiCjkScale": 115 },
    },
    fn(_) {  },
  )
  let undo_payload : Ref[Json?] = Ref(None)
  let recording = Ref(false)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if recording.val && name == "prefs.set" {
        undo_payload.val = Some(params)
      }
      (base.call)(name, params, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=820.0, platform=0)
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="全部恢复默认")
  t.run_for(@ui.move_most_ms)
  recording.val = true
  t.click(Button, label="撤销")
  t.run_for(@ui.move_most_ms)
  let typo = field(undo_payload.val, "typography")
  assert_true(typo is Some(Object(_)))
  assert_true(field(typo, "textCjkScaleOwn") is None)
  assert_true(field(typo, "textCjkWeightOwn") is None)
  assert_eq(field(typo, "textCjkScale"), Some(Json::null()))
  assert_eq(field(typo, "textCjkWeight"), Some(Json::null()))
  assert_eq(number(typo, "textSize").round().to_int(), 115)
  assert_eq(number(typo, "uiCjkScale").round().to_int(), 115)
}

///|
test "preview markdown_node and code block scale synchronously when textSize changes" {
  new_run()
  let src = fixture("settings")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=820.0, platform=0)
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  let prose_before = preview_width(t, "按钮的点击在表单提交之前被")
  let inline_before = preview_width(t, "preventDefault")
  let block_before = preview_width(t, "form.onsubmit")
  (src.call)("prefs.set", { "typography": { "textSize": 125 } }, fn(_) {  })
  t.run_for(@ui.move_most_ms)
  let prose_after = preview_width(t, "按钮的点击在表单提交之前被")
  let inline_after = preview_width(t, "preventDefault")
  let block_after = preview_width(t, "form.onsubmit")
  let prose_ratio = prose_after / prose_before
  let inline_ratio = inline_after / inline_before
  let block_ratio = block_after / block_before
  // Exact single-scale check (~1.25x, never double-scaled 1.56x)
  assert_true(prose_ratio > 1.18 && prose_ratio < 1.35, msg="prose_ratio=\{prose_ratio}")
  assert_true(inline_ratio > 1.18 && inline_ratio < 1.35, msg="inline_ratio=\{inline_ratio}")
  assert_true(block_ratio > 1.18 && block_ratio < 1.35, msg="block_ratio=\{block_ratio}")
}

///|
test "Web platform (platform=4) shows 代码连字 switch; codeScale max=110% and cjkScale max=115% match core-ts bounds" {
  new_run()
  let src = fixture("settings")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=820.0, platform=4)
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  t.tap_text("阅读与排版")
  t.run_for(@ui.move_most_ms)
  t.wheel(700.0, 520.0, 480.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("中西文自动留白") is Some(_))
  assert_true(t.find("代码连字") is Some(_))
  guard t.query(Switch, label="代码连字") is Some(lig_sw) else { fail("no 代码连字 switch on web") }
  t.tap(lig_sw.rect.0 + lig_sw.rect.2 / 2.0, lig_sw.rect.1 + lig_sw.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_false(flag(field(src.topic("prefs", {}).get().value, "typography"), "codeLigatures"))
  // Verify slider max bounds by dragging 代码相对字号 and 中文相对大小 thumbs to the right end
  guard t.query(Slider, label="代码相对字号") is Some(cs) else { fail("no 代码相对字号 slider") }
  let cs_cy = cs.rect.1 + cs.rect.3 / 2.0
  let cs_x0 = cs.rect.0 + cs.rect.2 * 0.6
  let cs_x1 = cs.rect.0 + cs.rect.2 - 2.0
  t.press_at(cs_x0, cs_cy)
  t.run_for(@ui.move_most_ms)
  t.move_to(cs_x1, cs_cy)
  t.run_for(@ui.move_most_ms)
  t.release(cs_x1, cs_cy)
  t.run_for(@ui.move_most_ms)
  assert_eq(number(field(src.topic("prefs", {}).get().value, "typography"), "codeScale").round().to_int(), 110)
  guard t.query(Slider, label="中文相对大小") is Some(cks) else { fail("no 中文相对大小 slider") }
  let cks_cy = cks.rect.1 + cks.rect.3 / 2.0
  let cks_x0 = cks.rect.0 + cks.rect.2 * 0.5
  let cks_x1 = cks.rect.0 + cks.rect.2 - 2.0
  t.press_at(cks_x0, cks_cy)
  t.run_for(@ui.move_most_ms)
  t.move_to(cks_x1, cks_cy)
  t.run_for(@ui.move_most_ms)
  t.release(cks_x1, cks_cy)
  t.run_for(@ui.move_most_ms)
  assert_eq(number(field(src.topic("prefs", {}).get().value, "typography"), "uiCjkScale").round().to_int(), 115)
}

///|
test "390pt narrow role row with long local font names keeps role title visible and within viewport" {
  new_run()
  let src = fixture("settings")
  (src.call)(
    "prefs.set",
    {
      "fonts": { "ui": "local:Hiragino Maru Gothic ProN", "uiCjk": "local:Hiragino Kaku Gothic StdN" },
      "typography": { "textSize": 130 },
    },
    fn(_) {  },
  )
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  // Preset cards show needed download sizes in subtitle
  assert_true(t.find("44 MB") is Some(_))
  assert_true(t.find("55 MB") is Some(_))
  // Role row button & title stay intact and within 390pt width despite long combined local family names
  t.wheel(195.0, 500.0, 260.0)
  t.run_for(@ui.move_most_ms)
  guard t.query(Button, label="界面西文") is Some(slot) else { fail("no 界面西文 slot") }
  assert_true(slot.rect.0 >= 0.0 && slot.rect.0 + slot.rect.2 <= 390.5)
  assert_true(t.find("标题与按钮") is Some(_))
}

///|
test "V8 responsive audit: 390x844, 320x560, 1.3x font scale, and EN locale have 0 audit faults" {
  let cases : Array[(String, Double, Double, Double, String)] = [
    ("390x844-zh", 390.0, 844.0, 1.0, "zh"),
    ("320x560-zh", 320.0, 560.0, 1.0, "zh"),
    ("390x844-1.3x", 390.0, 844.0, 1.3, "zh"),
    ("390x844-en", 390.0, 844.0, 1.0, "en"),
  ]
  let errs : Array[String] = []
  for c in cases {
    let (tag, w, h, fscale, lang) = c
    new_run()
    let base = fixture("settings")
    let src : Source = if lang == "en" {
      {
        ..base,
        topic_read: fn(name, params) {
          let got = base.topic(name, params).get().snapshot()
          if name != "prefs" { return got }
          let o = match got.value {
            Some(Object(m)) => m.copy()
            _ => {}
          }
          o["lang"] = Json::string("en")
          { ..got, value: Some(Json::object(o)) }
        },
      }
    } else {
      base
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform=2)
    if fscale != 1.0 {
      t.set_font_scale(fscale)
    }
    app.nav.replace(Setting(@settings.Route::Fonts))
    t.run_for(@ui.move_most_ms)
    let a1 = t.audit()
    if a1.length() > 0 { errs.push("top \{tag}: " + a1.join(" | ")) }
    // Scroll down to reading bar & advanced section, expand advanced, and audit
    let adv_lbl = if lang == "en" { "Reading & typography" } else { "阅读与排版" }
    for _ in 0..<8 {
      if t.find(adv_lbl) is Some((_, ay)) && ay >= 60.0 && ay <= h - 60.0 {
        break
      }
      t.wheel(w / 2.0, h / 2.0, 260.0)
      t.run_for(@ui.move_most_ms)
    }
    let a2 = t.audit()
    if a2.length() > 0 { errs.push("mid \{tag}: " + a2.join(" | ")) }
    match t.find(adv_lbl) {
      Some((ax, ay)) => {
        t.tap(ax + 4.0, ay + 4.0)
        t.run_for(@ui.move_most_ms)
        t.wheel(w / 2.0, h / 2.0, 360.0)
        t.run_for(@ui.move_most_ms)
        let a3 = t.audit()
        if a3.length() > 0 { errs.push("adv \{tag}: " + a3.join(" | ")) }
      }
      None => errs.push("no advanced toggle for \{tag}")
    }
    @sf.set_language(None)
  }
  assert_eq(errs, [], msg=errs.join("\n"))
}

///|
test "code sample responds to 代码中文 hover via code_cjk_override and ignores prose line_scale" {
  let t = wide_fonts_tester()
  // Give 思源宋体's preview slot extra width so CJK inside fp_sample_code ("表单") widens when hovering 代码中文
  t.face_wider(preview_faces_from + 2, 0.25)
  t.draw()
  let code_w_before = preview_width(t, "// 表单")
  let code_h_before = t.run_rects("form.onsubmit")[0].3
  tap_matrix_slot(t, 2, true)
  t.run_for(@ui.move_most_ms)
  let (x, y) = picker_row_center(t, "思源宋体")
  t.move_to(x, y)
  t.draw()
  t.draw()
  assert_true(preview_width(t, "// 表单") > code_w_before, msg="code sample CJK should widen on 代码中文 hover")
  t.tap(8.0, 8.0)
  t.run_for(@ui.move_most_ms)
  // Changing prose lineHeight ("relaxed") must not inflate the code sample's line height
  t.tap_text("舒展")
  t.run_for(@ui.move_most_ms)
  let code_h_after = t.run_rects("form.onsubmit")[0].3
  assert_true((code_h_after - code_h_before).abs() < 0.5, msg="code_h_before=\{code_h_before} code_h_after=\{code_h_after}")
}

///|
test "failed fonts.fetch (NotHad) retries on re-picking the same font and succeeds once available" {
  new_run()
  let base = fixture("settings")
  let fail_fetch = Ref(true)
  let fetch_calls = Ref(0)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "fonts.fetch" {
        fetch_calls.val += 1
        if fail_fetch.val {
          done(Err(Json::object({ "code": Json::string("offline"), "message": Json::string("offline") })))
          return
        }
      }
      (base.call)(name, params, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=820.0, platform=0)
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  // First pick fails -> NotHad cached, face_here is false
  tap_matrix_slot(t, 0, true)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "思源黑体")
  t.run_for(@ui.move_most_ms)
  assert_eq(fetch_calls.val, 1)
  assert_false(face_here("noto-sans-sc"))
  // Network recovers -> re-picking 思源黑体 clears NotHad, issues 2nd fonts.fetch, and loads
  fail_fetch.val = false
  tap_matrix_slot(t, 0, true)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "思源黑体")
  t.run_for(@ui.move_most_ms)
  assert_eq(fetch_calls.val, 2)
  assert_true(face_here("noto-sans-sc"))
}

///|
test "host rejecting face_add_family keeps face_here false and re-clicking local row retries once available" {
  new_run()
  let src = fixture("settings")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=820.0, platform=0)
  t.set_local_fonts("[\"MissingFont\"]")
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  let h = @hostapi.host()
  let orig_add_family = h.face_add_family
  let reject = Ref(true)
  let calls = Ref(0)
  h.face_add_family = fn(face, family) {
    if family == "MissingFont" {
      calls.val += 1
      if reject.val {
        false
      } else {
        orig_add_family(face, family)
      }
    } else {
      orig_add_family(face, family)
    }
  }
  (src.call)("prefs.set", { "fonts": { "ui": "local:MissingFont", "uiCjk": "local:MissingFont" } }, fn(_) {  })
  t.run_for(@ui.move_most_ms)
  assert_false(face_here("local:MissingFont"))
  assert_false(@ui.face_given(@hostapi.face_ui_cjk))
  // Host recovers -> re-clicking the same local font row in 界面西文 retries and succeeds
  reject.val = false
  let before_calls = calls.val
  tap_matrix_slot(t, 0, false)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "MissingFont")
  t.run_for(@ui.move_most_ms)
  h.face_add_family = orig_add_family
  assert_true(calls.val > before_calls)
  assert_true(face_here("local:MissingFont"))
  assert_true(@ui.face_given(@hostapi.face_ui))
}

///|
test "local try slot (@hostapi.face_try) obeys codeLigatures toggle on hover and live toggle" {
  let t = wide_tester([])
  t.host_says_finger(Some(false))
  t.set_local_fonts("[\"Menlo\",\"Fira Code\"]")
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  // Expand 阅读与排版 and turn OFF 代码连字 first
  t.wheel(700.0, 520.0, 320.0)
  t.run_for(@ui.move_most_ms)
  t.tap_text("阅读与排版")
  t.run_for(@ui.move_most_ms)
  t.wheel(700.0, 520.0, 360.0)
  t.run_for(@ui.move_most_ms)
  guard t.query(Switch, label="代码连字") is Some(sw) else { fail("no 代码连字 switch") }
  t.tap(sw.rect.0 + sw.rect.2 / 2.0, sw.rect.1 + sw.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  // Scroll back up to pairing matrix
  t.wheel(700.0, 520.0, -700.0)
  t.run_for(@ui.move_most_ms)
  let h = @hostapi.host()
  let orig_lig = h.face_set_ligatures
  let seen : Array[(Int, Bool)] = []
  h.face_set_ligatures = fn(face, on) {
    seen.push((face, on))
    orig_lig(face, on)
  }
  // Open 代码等宽 and hover local Menlo while 代码连字 is OFF -> slot 7 receives ligatures=false
  tap_matrix_slot(t, 2, false)
  t.run_for(@ui.move_most_ms)
  let (mx, my) = picker_row_center(t, "Menlo")
  t.move_to(mx, my)
  t.draw()
  t.draw()
  assert_true(seen.iter().any(fn(p) { p.0 == @hostapi.face_try && p.1 == false }))
  // Close popover, scroll down, turn 代码连字 back ON -> loaded slot 7 receives ligatures=true
  t.tap(8.0, 8.0)
  t.run_for(@ui.move_most_ms)
  t.wheel(700.0, 520.0, 700.0)
  t.run_for(@ui.move_most_ms)
  guard t.query(Switch, label="代码连字") is Some(sw2) else {
    h.face_set_ligatures = orig_lig
    fail("no 代码连字 switch")
  }
  seen.clear()
  t.tap(sw2.rect.0 + sw2.rect.2 / 2.0, sw2.rect.1 + sw2.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  h.face_set_ligatures = orig_lig
  assert_true(seen.iter().any(fn(p) { p.0 == @hostapi.face_try && p.1 == true }))
}

///|
test "settings-fonts-code fixture opens V8 code slot picker with JetBrains Mono and Fira Code visible" {
  let t = settings_tester("fonts", mode="settings-fonts-code", shows="settings-fonts-code")
  assert_eq(@sfpages.font_picker_open.untracked(), 4)
  assert_true(t.query(Button, label="JetBrains Mono") is Some(_))
  assert_true(t.query(Button, label="Fira Code") is Some(_))
}

///|
test "preset switch from 雅致阅读 to 现代无衬线 clears host text slot 2 instead of leaving stale Inter" {
  let t = wide_fonts_tester()
  t.set_local_fonts("[\"Georgia\"]")
  t.tap_text("雅致阅读")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.faces_in[@hostapi.face_text], "inter")
  assert_true(@ui.face_given(@hostapi.face_text))
  let h = @hostapi.host()
  let orig_clear = h.face_clear
  let cleared : Array[Int] = []
  h.face_clear = fn(face) {
    cleared.push(face)
    orig_clear(face)
  }
  t.tap_text("现代无衬线")
  t.run_for(@ui.move_most_ms)
  h.face_clear = orig_clear
  assert_true(cleared.contains(@hostapi.face_text))
  assert_eq(@sfbase.faces_in[@hostapi.face_text], "")
  assert_false(@ui.face_given(@hostapi.face_text))
  // Switching UI to local:Georgia keeps text slot 2 cleared (following UI, no stale Inter)
  tap_matrix_slot(t, 0, false)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "Georgia")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.faces_in[@hostapi.face_ui], "local:Georgia")
  assert_eq(@sfbase.faces_in[@hostapi.face_text], "")
  assert_false(@ui.face_given(@hostapi.face_text))
}

///|
test "set_local_font_info alone (without set_local_fonts) shows local fonts section in picker" {
  let t = wide_tester([])
  t.set_local_font_info("[{\"name\":\"Menlo\",\"localized\":\"Menlo\",\"mono\":true,\"cjk\":false}]")
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  tap_matrix_slot(t, 2, false)
  t.run_for(@ui.move_most_ms)
  let _ = picker_row_center(t, "Menlo")
  assert_true(t.query(Button, label="Menlo") is Some(_))
}

///|
test "resetting code font to default clears host slot 3 even when built-in default code face bytes are empty" {
  let t = wide_fonts_tester()
  // Load non-default code font (Fira Code) into host slot 3
  tap_matrix_slot(t, 2, false)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "Fira Code")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.faces_in[@hostapi.face_code], "fira-code")
  assert_true(@ui.face_given(@hostapi.face_code))
  // Simulate Web before built-in jetbrains_mono.ttf bytes arrive
  @sfbase.default_code_face_override.val = Some(b"")
  let h = @hostapi.host()
  let orig_clear = h.face_clear
  let cleared : Array[Int] = []
  h.face_clear = fn(face) {
    cleared.push(face)
    orig_clear(face)
  }
  // Reset code font back to default ("") -> must clear slot 3 immediately instead of leaving fira-code
  tap_matrix_slot(t, 2, false)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "默认")
  t.run_for(@ui.move_most_ms)
  h.face_clear = orig_clear
  assert_true(cleared.contains(@hostapi.face_code))
  assert_eq(@sfbase.faces_in[@hostapi.face_code], "")
  assert_false(@ui.face_given(@hostapi.face_code))
  // Once built-in bytes arrive later, slot 3 loads the default code face normally
  @sfbase.default_code_face_override.val = None
  t.draw()
  assert_eq(@sfbase.faces_in[@hostapi.face_code], "")
  assert_true(@ui.face_given(@hostapi.face_code))
}

///|
test "fonts.file verified=true with zipped=false loads chosen face and vector_cjk_had without UI sha256" {
  new_run()
  let base = fixture("home")
  (base.call)("prefs.set", { "fonts": { "ui": "lxgw-wenkai" } }, fn(_) {  })
  let file_reads = Ref(0)
  let keeps = Ref(0)
  let src : Source = {
    ..base,
    read_bytes: fn(name, params, done) {
      if name == "fonts.file" {
        file_reads.val += 1
        // Non-matching bytes prove UI-thread @zip.sha256 is skipped when core sets zipped=false, verified=true.
        done(Ok(({ "zipped": false, "verified": true }, b"verified-off-ui-ttf")))
      } else {
        (base.read_bytes)(name, params, done)
      }
    },
    call_bytes: fn(name, params, bytes, done) {
      if name == "fonts.keep" {
        keeps.val += 1
      }
      (base.call_bytes)(name, params, bytes, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.draw()
  assert_true(face_here("lxgw-wenkai"))
  assert_true(@ui.face_given(@hostapi.face_ui))
  assert_eq(file_reads.val, 2)
  assert_eq(keeps.val, 0)
  // vector_cjk_had also loads through face_files with zipped=false, verified=true.
  let own = @sfbase.vector_faces(b"<svg xmlns='http://www.w3.org/2000/svg'><text>Hi</text></svg>").length()
  let zh = b"<svg xmlns='http://www.w3.org/2000/svg'><text>\xe6\xb5\x81\xe7\xa8\x8b</text></svg>"
  assert_eq(@sfbase.vector_faces(zh).length(), own)
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.vector_faces(zh).length(), own + 1)
  assert_eq(file_reads.val, 3)
  assert_eq(keeps.val, 0)
}

///|
test "fonts.file zipped=false without verified (or missing zipped) still validates sha256 and rejects bad bytes" {
  for reply in [
    ({ "zipped": false } : Json),
    ({ "verified": true } : Json),
  ] {
    new_run()
    let base = fixture("home")
    (base.call)("prefs.set", { "fonts": { "ui": "noto-sans-sc" } }, fn(_) {  })
    let src : Source = {
      ..base,
      read_bytes: fn(name, params, done) {
        if name == "fonts.file" {
          done(Ok((reply, b"corrupted-ttf-bytes")))
        } else {
          (base.read_bytes)(name, params, done)
        }
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    t.draw()
    assert_false(face_here("noto-sans-sc"))
    assert_false(@ui.face_given(@hostapi.face_ui))
  }
}

///|
test "fonts.file returning not_found after core clears a damaged file triggers fonts.fetch and recovers" {
  new_run()
  let base = fixture("home")
  (base.call)("prefs.set", { "fonts": { "ui": "noto-sans-sc" } }, fn(_) {  })
  let fetched = Ref(0)
  let reads = Ref(0)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "fonts.fetch" {
        fetched.val += 1
      }
      (base.call)(name, params, done)
    },
    read_bytes: fn(name, params, done) {
      if name == "fonts.file" {
        reads.val += 1
        if reads.val == 1 {
          done(Err({ "code": "not_found", "message": "damaged and cleared" }))
        } else {
          (base.read_bytes)(name, params, done)
        }
      } else {
        (base.read_bytes)(name, params, done)
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.draw()
  assert_eq(fetched.val, 1)
  assert_eq(reads.val, 2)
  assert_true(face_here("noto-sans-sc"))
  assert_true(@ui.face_given(@hostapi.face_ui))
}

///|
test "multi-file face recovers in one selection when both weights return not_found after damage cleanup" {
  new_run()
  let base = fixture("home")
  (base.call)("prefs.set", { "fonts": { "ui": "lxgw-wenkai" } }, fn(_) {  })
  let fetched = Ref(0)
  let reads = Ref(0)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "fonts.fetch" {
        fetched.val += 1
      }
      (base.call)(name, params, done)
    },
    read_bytes: fn(name, params, done) {
      if name == "fonts.file" {
        reads.val += 1
        // Read 1 (weight 400) and read 3 (weight 500) each fail with not_found (simulating both files damaged);
        // reads 2 and 4 succeed after their respective fonts.fetch, without re-reading weight 400 on the second fetch.
        if reads.val == 1 || reads.val == 3 {
          done(Err({ "code": "not_found", "message": "damaged and cleared" }))
        } else {
          (base.read_bytes)(name, params, done)
        }
      } else {
        (base.read_bytes)(name, params, done)
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.draw()
  assert_eq(reads.val, 4)
  assert_eq(fetched.val, 2)
  assert_true(face_here("lxgw-wenkai"))
  assert_true(@ui.face_given(@hostapi.face_ui))
}
