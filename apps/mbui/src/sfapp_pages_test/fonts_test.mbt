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
  // scroll past style cards & pairing matrix into the contextual font picker
  t.wheel(200.0, 620.0, 520.0)
  t.run_for(@ui.move_most_ms)
  // the interface's faces, each with how big it is to fetch (in thousands, as Android says it)
  assert_true(t.query(Button, label="Inter") is Some(_))
  assert_true(t.find("458 kB") is Some(_))
  assert_true(t.query(Button, label="思源黑体") is Some(_))
  assert_true(t.find("11 MB") is Some(_))
  assert_true(t.query(Button, label="JetBrains Mono") is None)
  // each shown in itself: its preview given to a face of its own
  assert_true(@ui.face_given(preview_faces_from))
  // code's: click 代码 zone in sticky preview -> code faces, 默认 in the app's own (JetBrains Mono)
  tap_place(t, "代码")
  t.draw()
  assert_true(t.query(Button, label="Fira Code") is Some(_))
  assert_true(t.find("91 kB") is Some(_))
  assert_true(t.query(Button, label="思源黑体") is None)
  assert_true(@ui.face_given(own_code_face))
}

///|
test "a face picked: kept as the device's, fetched, unzipped and checked, and what people write set in it; 跟随界面 puts it back" {
  let t = settings_tester("fonts")
  tap_place(t, "正文")
  t.draw()
  t.wheel(200.0, 620.0, 520.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="跟随界面") is Some(_))
  assert_false(@ui.face_given(@hostapi.face_text))
  tap_picker_row(t, "霞鹜文楷")
  t.draw()
  // fetched (the core had none of it), its two files unzipped, checked, and given for what people write
  assert_true(face_here("lxgw-wenkai"))
  assert_true(@ui.face_given(@hostapi.face_text))
  // here: no size said any more
  assert_true(t.find("26 MB") is None)
  // the interface's stays the app's own
  assert_false(@ui.face_given(@hostapi.face_ui))
  tap_picker_row(t, "跟随界面")
  t.draw()
  assert_false(face_here("lxgw-wenkai"))
  assert_false(@ui.face_given(@hostapi.face_text))
}

///|
test "a face being fetched: how far said on its row, the app's own standing in until it is here" {
  let t = settings_tester("fonts", mode="settings-fonts-coming", shows="settings-fonts-coming")
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
/// Find the center of an exact font picker row button by its semantic label (never collides with style card subtitles).
fn picker_row_center(t : @ui.Tester, name : String) -> (Double, Double) raise {
  guard t.query(Button, label=name) is Some(s) else { fail("no picker row: " + name) }
  (s.rect.0 + s.rect.2 / 2.0, s.rect.1 + s.rect.3 / 2.0)
}

///|
fn tap_picker_row(t : @ui.Tester, name : String) -> Unit raise {
  let (x, y) = picker_row_center(t, name)
  t.tap(x, y)
}

///|
/// Tap a role zone in the sticky preview card (works at any scroll position because the preview is sticky).
fn tap_place(t : @ui.Tester, place : String) -> Unit raise {
  guard t.query(Button, label=place) is Some(s) else { fail("no role button: " + place) }
  t.tap(s.rect.0 + s.rect.2 / 2.0, s.rect.1 + s.rect.3 / 2.0)
}

///|
/// Tap a script slot button in the 3-role pairing matrix (`role_idx`: 0=ui, 1=text, 2=code; `is_cjk`: false=primary, true=cjk).
fn tap_matrix_slot(t : @ui.Tester, role_idx : Int, is_cjk : Bool) -> Unit {
  let prefix = if is_cjk {
    "中文 · "
  } else if role_idx == 2 {
    "等宽 · "
  } else {
    "西文 · "
  }
  let matches = t.semantics().filter(fn(s) { s.role is Button && s.label.has_prefix(prefix) })
  let idx = if is_cjk { role_idx } else if role_idx == 2 { 0 } else { role_idx }
  let s = matches[idx]
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
  for place in ["界面", "正文"] {
    let t = settings_tester("fonts")
    if place == "正文" {
      tap_place(t, place)
      t.draw()
    }
    t.wheel(200.0, 620.0, 520.0)
    t.run_for(@ui.move_most_ms)
    // Distinguish the preview face without making the chat wrap and move the row out from under the pointer.
    t.face_wider(preview_faces_from + 2, 0.01)
    t.draw()
    let text_before = preview_width(t, "Safari 和 Chrome 都试过了。")
    let inline_before = preview_width(t, "preventDefault")
    let mine_before = preview_width(t, "登录页在 Safari 上点了没反应")
    let name_before = preview_width(t, "Claude")
    let (x, y) = picker_row_center(t, "思源宋体")
    t.move_to(x, y)
    t.draw()
    t.draw()
    let text_after = preview_width(t, "Safari 和 Chrome 都试过了。")
    let mine_after = preview_width(t, "登录页在 Safari 上点了没反应")
    let name_after = preview_width(t, "Claude")
    let row_after = t.query(Button, label="思源宋体").map(fn(s) { (s.rect.0, s.rect.1) })
    assert_true(text_after > text_before, msg="place=\{place} row_before=\{Repr((x, y))} row_after=\{Repr(row_after)} text=\{text_before},\{text_after} mine=\{mine_before},\{mine_after} name=\{name_before},\{name_after}")
    assert_eq(preview_width(t, "preventDefault"), inline_before)
    t.move_to(x, 4.0)
    t.draw()
    t.draw()
    assert_eq(preview_width(t, "Safari 和 Chrome 都试过了。"), text_before)
  }
}

///|
test "pointing at a code face tries it on inline code and the code block, keeping prose in its own face" {
  let t = settings_tester("fonts")
  tap_place(t, "代码")
  t.wheel(200.0, 620.0, 520.0)
  t.run_for(@ui.move_most_ms)
  t.face_wider(preview_faces_from + 5, 0.3)
  t.draw()
  let text_before = preview_width(t, "Safari 和 Chrome 都试过了。")
  let inline_before = preview_width(t, "preventDefault")
  let block_before = preview_width(t, "form.onsubmit")
  let (x, y) = picker_row_center(t, "Fira Code")
  t.move_to(x, y)
  t.draw()
  t.draw()
  assert_eq(preview_width(t, "Safari 和 Chrome 都试过了。"), text_before)
  assert_true(preview_width(t, "preventDefault") > inline_before)
  assert_true(preview_width(t, "form.onsubmit") > block_before)
  t.move_to(x, 4.0)
  t.draw()
  t.draw()
  assert_eq(preview_width(t, "preventDefault"), inline_before)
  assert_eq(preview_width(t, "form.onsubmit"), block_before)
}

///|
test "pointing at 跟随界面 previews the interface face even when a different text face is chosen" {
  let t = settings_tester("fonts")
  t.ui_face_wider(0.05)
  t.wheel(200.0, 620.0, 520.0)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "思源黑体")
  t.draw()
  tap_place(t, "正文")
  t.draw()
  tap_picker_row(t, "霞鹜文楷")
  t.draw()
  assert_true(@ui.face_given(@hostapi.face_ui))
  assert_true(@ui.face_given(@hostapi.face_text))
  let text_before = preview_width(t, "Safari 和 Chrome 都试过了。")
  let mine_before = preview_width(t, "登录页在 Safari 上点了没反应")
  let (x, y) = picker_row_center(t, "跟随界面")
  t.move_to(x, y)
  t.draw()
  t.draw()
  assert_true(preview_width(t, "Safari 和 Chrome 都试过了。") > text_before)
  assert_true(preview_width(t, "登录页在 Safari 上点了没反应") > mine_before)
  t.move_to(x, 4.0)
  t.draw()
  t.draw()
  assert_eq(preview_width(t, "Safari 和 Chrome 都试过了。"), text_before)
  assert_eq(preview_width(t, "登录页在 Safari 上点了没反应"), mine_before)
}

///|
test "pointing at an interface face leaves a separately chosen text face alone" {
  let t = settings_tester("fonts")
  tap_place(t, "正文")
  t.wheel(200.0, 620.0, 520.0)
  t.run_for(@ui.move_most_ms)
  tap_picker_row(t, "霞鹜文楷")
  t.draw()
  tap_place(t, "界面")
  t.face_wider(preview_faces_from + 2, 0.05)
  t.draw()
  let text_before = preview_width(t, "Safari 和 Chrome 都试过了。")
  let name_before = preview_width(t, "Claude")
  let (x, y) = picker_row_center(t, "思源宋体")
  t.move_to(x, y)
  t.draw()
  t.draw()
  assert_eq(preview_width(t, "Safari 和 Chrome 都试过了。"), text_before)
  assert_true(preview_width(t, "Claude") > name_before)
}

///|
test "a face pointed at tried in the chat above them: the chat held at its tallest while the pointer is on the faces, nothing under it shaking" {
  let t = settings_tester("fonts")
  t.wheel(200.0, 620.0, 520.0)
  t.run_for(@ui.move_most_ms)
  // 思源黑体 set wide enough that their message wraps once more in it, 思源宋体 a little
  t.face_wider(preview_faces_from + 1, 0.6)
  t.face_wider(preview_faces_from + 2, 0.3)
  t.draw()
  let before = picker_row_center(t, "Inter")
  let (x, y) = picker_row_center(t, "思源黑体")
  t.move_to(x, y)
  t.draw()
  // tried: the chat taller, the faces moved down once, and held there as the row now under the pointer is tried
  let moved = picker_row_center(t, "Inter")
  assert_true(moved.1 > before.1)
  // the hand still on the same spot, moving a little (the row under it now another, narrower one): nothing moves
  for i in 0..<4 {
    t.move_to(x + 1.0 + i.to_double(), y)
    t.draw()
    assert_eq(picker_row_center(t, "Inter"), moved)
  }
  // along the faces (a narrower one tried, the gaps between rows): still held
  let (x2, y2) = moved
  t.move_to(x2, y2)
  t.draw()
  t.draw()
  assert_eq(picker_row_center(t, "Inter"), moved)
  // the pointer gone off the faces: as before
  t.move_to(x, 4.0)
  t.draw()
  t.draw()
  assert_eq(picker_row_center(t, "Inter"), before)
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
  // Hovering a style card must never trigger fonts.fetch; repeated hover/leave triggers 0 words_forgotten
  let (px, py) = t.find("现代无衬线").unwrap()
  let before_hover = fetched.val
  t.move_to(px + 4.0, py + 4.0)
  t.draw()
  t.draw()
  assert_eq(fetched.val, before_hover)
  let forgotten_after_first = @ui.words_forgotten_count()
  t.move_to(px, 4.0)
  t.draw()
  t.move_to(px + 4.0, py + 4.0)
  t.draw()
  assert_eq(@ui.words_forgotten_count(), forgotten_after_first)
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
  let t = settings_tester("fonts")
  // Switch to 界面 · 中文 via pairing matrix and pick 思源宋体
  tap_matrix_slot(t, 0, true)
  t.draw()
  t.wheel(200.0, 620.0, 520.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="思源宋体") is Some(_))
  assert_true(t.query(Button, label="Inter") is None)
  tap_picker_row(t, "思源宋体")
  t.draw()
  assert_true(@ui.face_given(@hostapi.face_ui_cjk))
  // Switch to 正文 (still on 中文): should show 跟随界面 with 当前：思源宋体 and 不单独指定（随西文）
  tap_place(t, "正文")
  t.draw()
  assert_true(t.find("当前：思源宋体") is Some(_))
  assert_true(t.query(Button, label="不单独指定（随西文）") is Some(_))
  // Pick 不单独指定（随西文） -> textCjk="none"
  tap_picker_row(t, "不单独指定（随西文）")
  t.draw()
  assert_false(@ui.face_given(@hostapi.face_text_cjk))
  // Restore 跟随界面 -> textCjk=null
  tap_picker_row(t, "跟随界面")
  t.draw()
  assert_true(@ui.face_given(@hostapi.face_ui_cjk))
  assert_false(@ui.face_given(@hostapi.face_text_cjk))
}

///|
test "hovering CJK row previews locally with 0 words_forgotten and never pollutes inline code" {
  let t = settings_tester("fonts")
  tap_matrix_slot(t, 1, true)
  t.draw()
  t.wheel(200.0, 620.0, 520.0)
  t.run_for(@ui.move_most_ms)
  // Give 思源宋体's preview slot extra width so CJK text widens when hovered
  t.face_wider(preview_faces_from + 2, 0.05)
  t.draw()
  let forgotten_before = @ui.words_forgotten_count()
  let text_before = preview_width(t, "Safari 和 Chrome 都试过了。")
  let inline_before = preview_width(t, "preventDefault")
  let (x, y) = picker_row_center(t, "思源宋体")
  t.move_to(x, y)
  t.draw()
  t.draw()
  // Zero global glyph invalidation!
  assert_eq(@ui.words_forgotten_count(), forgotten_before)
  assert_true(preview_width(t, "Safari 和 Chrome 都试过了。") > text_before)
  assert_eq(preview_width(t, "preventDefault"), inline_before)
  t.move_to(x, 4.0)
  t.draw()
  t.draw()
  assert_eq(@ui.words_forgotten_count(), forgotten_before)
  assert_eq(preview_width(t, "Safari 和 Chrome 都试过了。"), text_before)
}

///|
test "local font panel: smart filter pills (仅中文 / 仅等宽 / 全部) and localized name search via set_local_font_info" {
  let t = wide_tester([])
  t.host_says_finger(Some(false))
  t.set_local_fonts("[\"PingFang SC\",\"JetBrains Mono\",\"Helvetica\"]")
  t.set_local_font_info(
    "[{\"name\":\"PingFang SC\",\"localized\":\"苹方-简\",\"mono\":false,\"serif\":false,\"cjk\":true},{\"name\":\"JetBrains Mono\",\"localized\":\"JetBrains Mono\",\"mono\":true,\"serif\":false,\"cjk\":false},{\"name\":\"Helvetica\",\"localized\":\"Helvetica\",\"mono\":false,\"serif\":false,\"cjk\":false}]",
  )
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  // Switch to 界面 · 中文 so smart default filter is 仅中文
  tap_matrix_slot(t, 0, true)
  t.draw()
  t.wheel(900.0, 520.0, 520.0)
  t.run_for(@ui.move_most_ms)
  guard t.query(Button, label="本机字体") is Some(s) else { fail("no 本机字体") }
  t.tap(s.rect.0 + s.rect.2 / 2.0, s.rect.1 + s.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  // Smart default 仅中文 shows 苹方-简 and hides Helvetica
  assert_true(t.find("苹方-简") is Some(_))
  assert_true(t.find("Helvetica") is None)
  // Switch to 仅等宽
  t.tap_text("仅等宽")
  t.draw()
  assert_true(t.find("JetBrains Mono") is Some(_))
  assert_true(t.find("苹方-简") is None)
  // Switch to 全部
  t.tap_text("全部")
  t.draw()
  assert_true(t.find("Helvetica") is Some(_))
  assert_true(t.find("苹方-简") is Some(_))
  // Hovering a local font uses isolated local_try_face (slot 7)
  let (lx, ly) = t.find("苹方-简").unwrap()
  t.move_to(lx + 4.0, ly + 4.0)
  t.draw()
  assert_eq(t.family_given(local_try_face), "PingFang SC")
}

///|
test "collapsible advanced typography section: expand, toggle autospace & ligatures, reset to defaults" {
  let t = wide_tester([])
  t.host_says_finger(Some(false))
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  // Scroll down to collapsible section; collapsed by default so inner controls are not visible
  t.wheel(900.0, 520.0, 750.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("排版与字号细节") is Some(_))
  assert_true(t.find("正文阅读字号") is None)
  // Expand
  t.tap_text("排版与字号细节")
  t.run_for(@ui.move_most_ms)
  t.wheel(900.0, 520.0, 600.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("正文阅读字号") is Some(_))
  assert_true(t.find("正文行距") is Some(_))
  assert_true(t.find("中西文自动留白") is Some(_))
  assert_true(t.find("正文 Abc") is Some(_))
  assert_true(t.find("代码连字") is Some(_))
  // Pick 舒展 line height card -> updates prose_line_scale and bumps typography_version
  let ver_before = typography_version()
  t.tap_text("舒展")
  t.draw()
  assert_true(prose_line_scale() > 1.13)
  assert_true(typography_version() > ver_before)
  // Toggle 中西文自动留白 off
  assert_true(@ui.cjk_autospace())
  guard t.query(Switch, label="中西文自动留白") is Some(sw) else { fail("no 中西文自动留白 switch") }
  t.tap(sw.rect.0 + sw.rect.2 / 2.0, sw.rect.1 + sw.rect.3 / 2.0)
  t.draw()
  assert_false(@ui.cjk_autospace())
  // Reset to defaults restores lineHeight and cjkAutoSpace
  t.wheel(900.0, 520.0, 450.0)
  t.run_for(@ui.move_most_ms)
  let resets = t.words().filter(fn(w) { w.0 == "恢复默认" && w.5 > 0.5 })
  assert_true(resets.length() > 0)
  let r_btn = resets[resets.length() - 1]
  t.tap(r_btn.1 + r_btn.3 / 2.0, r_btn.2 + r_btn.4 / 2.0)
  t.draw()
  assert_eq(prose_line_scale(), 1.0)
  assert_true(@ui.cjk_autospace())
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
  assert_true(t.find("第 2999 条") is Some(_))
  // Scale prose to 130% + relaxed line height via prefs.set
  (src.call)("prefs.set", { "typography": { "textSize": 130, "lineHeight": "relaxed" } }, fn(_) {  })
  t.run_for(@ui.move_most_ms)
  assert_true(prose_text_scale() > 1.29)
  assert_true(prose_line_scale() > 1.13)
  assert_true(typography_version() > ver0)
  // Scaling typography does not trigger global glyph cache invalidation
  assert_eq(@ui.words_forgotten_count(), forgotten0)
  // At-foot state preserved: unique foot message "第 2999 条" stays in viewport near the bottom
  let foot_after = t.find("第 2999 条")
  assert_true(foot_after is Some((_, fy)) && fy >= 80.0 && fy <= 760.0)
  // (b) Scroll up into history (past long_reply), pick a FULL unique numbered message (e.g. "第 NNNN 条" / "第 NNNN 步"), scale typography, verify same unique message stays in viewport with bounded delta
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
    anchor_after is Some((_, y)) && y >= 0.0 && y <= 800.0 && (y - before_y).abs() < 260.0,
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
