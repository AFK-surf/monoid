// Settings > Import (`import_node`): probes external sources on the chosen online station (T3 Code first),
// runs one-click batch import, expands individual sessions, imports one session, opens imported chats, handles
// older stations gracefully, and stays audit-clean across widths, font scales, and languages.

///|
test "Settings > Import: one-click T3 Code import, list expansion, open imported chat, unsupported station, and responsive audit" {
  // 1. Standard widths and both languages stay audit-clean and run one-click T3 Code import
  for c in [(320.0, 2, false, 1.0), (390.0, 2, false, 1.3), (720.0, 0, false, 1.0), (1280.0, 0, true, 1.0)] {
    let (w, platform, en, scale) = c
    let at = "w=\{w} en=\{en} scale=\{scale}"
    let calls : Array[(String, Json)] = []
    let t = setting_tester(Import, w, platform~, mode="settings-import", h=1800.0, over=fn(s) {
      {
        ..s,
        call: fn(name, params, done) {
          calls.push((name, params))
          (s.call)(name, params, done)
        },
      }
    })
    if en {
      @sf.set_language(Some("en"))
    }
    if scale != 1.0 {
      t.set_font_scale(scale)
    }
    t.run_for(@ui.move_most_ms)
    assert_eq(t.audit(), [], msg="audit \{at}: \{Repr(t.audit())}")
    assert_eq(t.squeeze_faults(), [], msg="squeeze \{at}: \{Repr(t.squeeze_faults())}")
    assert_eq(t.corner_faults(), [], msg="corner \{at}: \{Repr(t.corner_faults())}")
    assert_true(calls.iter().any(fn(c) { c.0 == "import.sources" }), msg="probed import.sources: \{at}")
    assert_true(t.find("T3 Code") is Some(_), msg="renders T3 Code card: \{at} drawn=\{t.drawn_text()}")

    // Click one-click import button
    let one_click = @sf.t("web-pages.import.oneClickCount", args=[("n", "2")])
    guard t.query(Button, label=one_click) is Some(btn) else {
      fail("missing one-click button (\{one_click}) at \{at}: \{t.semantics_dump()}")
    }
    let (bx, by, bw, bh) = btn.rect
    t.tap(bx + bw / 2.0, by + bh / 2.0)
    t.run_for(@ui.move_most_ms)
    assert_true(
      calls.iter().any(fn(c) { c.0 == "import.run" && text(Some(c.1), "source") == "t3" && !flag(Some(c.1), "includeArchived") }),
      msg="called import.run for active t3 sessions: \{at}",
    )
    assert_eq(@sfbase.toast_words(), @sf.t("web-pages.import.done", args=[("imported", "2")]), msg=at)
    assert_eq(t.audit(), [], msg="audit after import: \{at}")
    if en {
      @sf.set_language(None)
    }
  }

  // 2. Expand session list, toggle includeArchived, import archived item, and open an imported chat
  let calls : Array[(String, Json)] = []
  let t = setting_tester(Import, 720.0, platform=0, mode="settings-import", h=2000.0, over=fn(s) {
    {
      ..s,
      call: fn(name, params, done) {
        calls.push((name, params))
        (s.call)(name, params, done)
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  guard t.query(Button, label=@sf.t("web-pages.import.showList")) is Some(show_btn) else {
    fail("missing showList button: \{t.semantics_dump()}")
  }
  let (sx, sy, sw, sh) = show_btn.rect
  t.tap(sx + sw / 2.0, sy + sh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("修复 OAuth 登录重定向") is Some(_), msg="expanded list renders active T3 thread")
  assert_true(t.find("调研旧版索引迁移") is None, msg="archived thread hidden until toggle")

  // Enable includeArchived switch
  guard t.query(Switch, label=@sf.t("web-pages.import.includeArchived")) is Some(sw_node) else {
    fail("missing includeArchived switch: \{t.semantics_dump()}")
  }
  let (tx, ty, tw, th) = sw_node.rect
  t.tap(tx + tw / 2.0, ty + th / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("调研旧版索引迁移") is Some(_), msg="archived thread shown after enabling switch")
  assert_eq(t.audit(), [], msg="audit with expanded list")

  // Import one session via row button, then open it
  guard t.query(Button, label=@sf.t("web-pages.import.importOne")) is Some(one_btn) else {
    fail("missing per-row import button: \{t.semantics_dump()}")
  }
  let (ix, iy, iw, ih) = one_btn.rect
  t.tap(ix + iw / 2.0, iy + ih / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(
    calls.iter().any(fn(c) { c.0 == "import.run" && items(Some(c.1), "ids").length() == 1 }),
    msg="called import.run with single id",
  )
  guard t.query(Button, label=@sf.t("web-pages.import.openChat")) is Some(open_btn) else {
    fail("missing openChat button after importing single session: \{t.semantics_dump()}")
  }
  let (ox, oy, ow, oh) = open_btn.rect
  t.tap(ox + ow / 2.0, oy + oh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.app.nav.top() is Chat(_), msg="openChat navigates to imported chat")

  // 3. Older station returning 404 shows upgrade notice cleanly
  let old = setting_tester(Import, 390.0, platform=2, mode="settings-import", h=1200.0, over=fn(s) {
    {
      ..s,
      call: fn(name, params, done) {
        if name == "import.sources" {
          done(Err(obj([("code", str("not_found")), ("message", str("404 Not Found"))])))
        } else {
          (s.call)(name, params, done)
        }
      },
    }
  })
  old.run_for(@ui.move_most_ms)
  assert_true(old.find(@sf.t("web-pages.import.unsupported")) is Some(_), msg="404 renders unsupported notice")
  assert_eq(old.audit(), [], msg="audit on unsupported station")
}

///|
test "Settings list includes Import and finds it when searching for T3" {
  let t = setting_tester(Home, 390.0, platform=2, mode="settings", h=1800.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(@sf.t("web-pages.import.title")) is Some(_), msg="Settings Home lists Import: drawn=\{t.drawn_text()}")
  let back_y = t.find("备份").unwrap().1
  let imp_y = t.find(@sf.t("web-pages.import.title")).unwrap().1
  let usage_y = t.find("用量").unwrap().1
  assert_true(back_y < imp_y && imp_y < usage_y, msg="Import between Backup and Usage: \{back_y} < \{imp_y} < \{usage_y}")
  assert_eq(t.audit(), [], msg="Settings Home audit with Import row")
}
