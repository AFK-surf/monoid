// The composer's parts as Android's: what waits to go (its
// files in the order they were put in, a row that scrolls sideways; a picture opening in the viewer, a link opening,
// a file going up said as it goes), the quotes kept to 176, the archived chat's restore, what the buttons are called,
// a long press letting the keyboard be. Over the fake core of composer_wbtest.mbt.

///|
/// A PNG's first bytes (IHDR 1600 × 900): what a picture's size is read from.
fn png_head() -> Bytes {
  Bytes::from_array(
    [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0x06, 0x40, 0, 0, 0x03,
      0x84, 8, 6, 0, 0, 0,
    ].map(fn(i) { i.to_byte() }),
  )
}

///|
test "a picture waiting in the composer, tapped, opens in the viewer from the bytes picked, growing out of its tile, hidden while it flies: on the old page and made as nodes" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let made : Ref[Source?] = Ref(None)
    let t = fake_core(calls, made~)
    let src = made.val.unwrap()
    @sfbase.writing_add(src, @sfbase.writing(src, "ws1/st1:s-c1"), "ws1/st1", "照片.png", png_head())
    t.draw()
    t.run_for(@ui.move_most_ms)
    let id = text(Some(@sfbase.writing(src, "ws1/st1:s-c1").files.get()[0]), "id")
    let seen = "ws1/st1//draft:" + id
    let (tx, ty, tw, th, _) = match waiting_tile_at(t, seen) {
      Some(tile) => tile
      None => fail("the tile is not kept for the viewer to fly from")
    }
    // (its tile drawn whole, the viewer flying from it: the old composer's by thumb_shows, the one made as nodes the end
    // of View::shared's flight that stays, drawn nowhere while it flies)
    let tile_shows = fn() { t.flight_of(seen) is None }
    assert_true(tile_shows(), msg="its tile before")
    t.tap(tx + tw / 2.0, ty + th / 2.0)
    match viewer.get() {
      Some(v) => {
        assert_eq(v.file.path, "draft:" + id)
        assert_eq(v.id(), seen)
        // nothing to mark it into: it is in the draft already
        assert_eq(v.draft_key(), "")
        // from the bytes picked: none asked of the station
        assert_true(v.bytes.get() is Some(_))
      }
      None => fail("the viewer did not open")
    }
    // (flying out of its tile: one picture on the screen, never two)
    t.run_for(@ui.move_most_ms / 4.0)
    // (the old composer's flown by the viewer by hand, the one made as nodes by the window's tree: View::shared)
    let flies = t.flight_of(seen) is Some(_)
    assert_true(flies, msg="not flown out of its tile")
    assert_false(tile_shows(), msg="its tile while the picture flies out of it")
    assert_eq(named(calls, "station.file").length(), 0)
    // the picture is not taken out by the tap
    assert_eq(@sfbase.writing(src, "ws1/st1:s-c1").files.get().length(), 1)
    t.back()
    let shut = preview_rest()
    t.run_for(shut - t.time())
    assert_true(viewer.get() is None)
    // gone: still the end of its way out, whatever is asked after (its way out said to move, Tester::rest_of)
    t.run_for(@ui.move_most_ms)
    assert_eq(preview_rest(), shut)
    assert_true(tile_shows(), msg="its tile once the viewer is gone")
  })
}

///|
/// A picture waiting in an existing chat or a new one's composer, opened and closed as a host takes a pointer's events.
fn waiting_picture_return(new_chat : Bool) -> Unit raise {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.set_rows_on_pixels(true)
  t.drawn_again(true)
  t.check_looks(false)
  t.run_for(@ui.move_most_ms)
  if new_chat {
    t.tap_text("新建对话")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == NewChat)
  }
  let w = @sfbase.writing(src, if new_chat { "new:ws1" } else { "ws1/st1:s-c1" })
  @sfbase.writing_add(src, w, "ws1/st1", "照片.png", png_head())
  t.draw()
  t.run_for(@ui.move_most_ms)
  let id = text(Some(w.files.get()[0]), "id")
  let picture = @sfbase.writing_pictures[id]
  // (its tile where the node composer draws it: the picture drawn whole, as the frame has it)
  let drawn_whole = fn(a : Array[Double]) { a[5] == 4.0 && t.image_src(a[20].to_int()) == picture && a[11] > 0.99 }
  let tile = match t.drawn_instances().iter().find_first(drawn_whole) {
    Some(a) => (a[0], a[1], a[2], a[3])
    None => fail("the picture waiting is not drawn")
  }
  let visible = fn() {
    t.drawn_instances().iter().any(fn(a) {
      a[5] == 4.0 && t.image_src(a[20].to_int()) == picture && a[11] > 0.99 &&
      (a[0] - tile.0).abs() < 1.0 && (a[1] - tile.1).abs() < 1.0
    })
  }
  assert_true(visible(), msg="the picture is visible before opening")
  let (x, y) = (tile.0 + tile.2 / 2.0, tile.1 + tile.3 / 2.0)
  t.touch(0, x, y)
  t.touch(2, x, y)
  t.frames_owed()
  let v = viewer.get().unwrap()
  assert_true(pic_flies(t, v), msg="the preview opens from the tile")
  let opened = pic_flight_end(t, v)
  while t.time() + @ui.frame_period_default < opened {
    t.frame_at(t.time() + @ui.frame_period_default)
  }
  t.frame_at(opened + @ui.frame_period_default)
  let (cx, cy, cw, ch) = t.get(Button, label=@sf.t("common.close")).rect
  let (cx, cy) = (cx + cw / 2.0, cy + ch / 2.0)
  t.move_to(cx, cy)
  t.touch(0, cx, cy)
  t.touch(2, cx, cy)
  t.frames_owed()
  let closing = pv_leaving.get().unwrap()
  assert_true(pic_flies(t, closing) && closing.tree_back.get(), msg="the preview returns to the tile")
  let end = pic_flight_end(t, closing)
  t.frame_at((t.time() + end) / 2.0)
  assert_false(visible(), msg="the tile is hidden while the picture returns")
  while t.time() + @ui.frame_period_default < end {
    t.frame_at(t.time() + @ui.frame_period_default)
  }
  t.frame_at(end)
  t.frame_at(end + @ui.frame_period_default)
  assert_true(viewer.get() is None && pv_leaving.get() is None, msg="the preview has returned")
  assert_true(visible(), msg="the picture is visible again without another input")
}

///|
test "a picture waiting in an existing chat is visible as soon as its preview returns" {
  waiting_picture_return(false)
}

///|
test "a picture waiting in a new chat is visible as soon as its preview returns" {
  waiting_picture_return(true)
}

///|
test "a film waiting in the composer, opened, plays from the bytes picked: none asked of the station" {
  both_pages(fn() raise {
    // (the user, 2026-11-01: 我自己上传到 composer 的视频，自己不能预览？ the player asked the station for `draft:<id>`,
    // which only this device has, and said 无法播放此视频)
    let calls : Array[Made] = []
    let made : Ref[Source?] = Ref(None)
    let t = fake_core(calls, made~)
    let film = Bytes::from_array(FixedArray::makei(4096, fn(i) { (i % 251).to_byte() }))
    let a : Attachment = {
      name: "录屏.mp4",
      path: "draft:f1",
      size: film.length().to_double(),
      width: 0.0,
      height: 0.0,
      thumbhash: "",
      owner: "",
      upload: "",
      duration: 0.0,
      frames: 0,
      held: false,
    }
    // as the composer opens it (composer_picture): its bytes kept by the viewer's id of it, no session's
    @sfbase.keep_read("ws1/st1//draft:f1", film)
    @sfbase.open_preview("ws1/st1", "", a)
    t.draw()
    t.run_for(@ui.move_most_ms)
    let track = match viewer.get().unwrap().media {
      Some(m) => m.track().unwrap()
      None => fail("the player did not open")
    }
    let got : Array[(Bytes, Double, Bool)] = []
    (track.read)(1000.0, 100, fn(b, size, more) { got.push((b, size, more)) }) |> ignore
    assert_eq(got.length(), 1)
    assert_eq(got[0].0, film[1000:1100].to_owned())
    assert_eq(got[0].1, 4096.0)
    assert_false(got[0].2)
    assert_eq(named(calls, "station.file.part").length(), 0)
    t.back()
    t.run_for(preview_rest() - t.time())
  })
}

///|
test "what waits to go has its ✕ hung on its corner, its centre on the curve, a picture's and a file's card alike, on a phone and a computer alike, clear of the next; tapped, it takes it out" {
  both_pages(fn() raise {
    // (Android, then macOS: one design on every screen, sf/align.mbt)
    for platform in [2, 0] {
      let calls : Array[Made] = []
      let made : Ref[Source?] = Ref(None)
      let t = fake_core(calls, made~, platform~)
      let src = made.val.unwrap()
      let w = @sfbase.writing(src, "ws1/st1:s-c1")
      @sfbase.writing_add(src, w, "ws1/st1", "照片.png", png_head())
      @sfbase.writing_add(src, w, "ws1/st1", "第二张.png", png_head())
      @sfbase.writing_add(src, w, "ws1/st1", "build.log", @utf8.encode("夜里的构建日志"))
      t.draw()
      t.run_for(@ui.move_most_ms)
      let tiles = @sfbase.writing(src, "ws1/st1:s-c1").files.get().filter_map(fn(f) {
        waiting_tile_at(t, "ws1/st1//draft:" + text(Some(f), "id"))
      })
      assert_eq(tiles.length(), 2)
      let (fx, fy, fw, _, corner) = tiles[0]
      let next_x = tiles[1].0
      let card = match t.query(Group, label="build.log") {
        Some(g) => g.rect
        None => fail("no card for build.log (platform \{platform})")
      }
      let near = fn(a : Double, b : Double) { (a - b).abs() < 0.01 }
      // each ✕'s centre on the curve of the corner it is hung on, as far past the top as past the right edge
      for one in [
        ("照片.png", fx, fy, fw, corner),
        // (a file's card as round as a picture's: what waits, all alike)
        ("build.log", card.0, card.1, card.2, corner),
      ] {
        let (name, ox, oy, ow, corner) = one
        let (x, y, bw, bh) = match t.query(Button, label=@sf.t("web-main.file.remove", args=[("name", name)])) {
          Some(b) => b.rect
          None => fail("no ✕ on \{name} (platform \{platform})")
        }
        let m = @ui.smooth_middle(corner)
        assert_true(near(x + bw / 2.0, ox + ow - m), msg="\{name}'s ✕ across (platform \{platform}): \{x + bw / 2.0}")
        assert_true(near(y + bh / 2.0, oy + m), msg="\{name}'s ✕ down (platform \{platform}): \{y + bh / 2.0}")
        assert_true(near(oy - y, x + bw - (ox + ow)), msg="\{name}'s ✕ reach (platform \{platform})")
      }
      // the next picture the row's gap (6) past the first one's ✕, not under it
      let (x, y, bw, bh) = t.query(Button, label=@sf.t("web-main.file.remove", args=[("name", "照片.png")])).unwrap().rect
      assert_true(next_x >= x + bw + 6.0 - 0.01, msg="the next at \{next_x}, the ✕ ends at \{x + bw}")
      t.tap(x + bw / 2.0, y + bh / 2.0)
      t.draw()
      // (the one taken out fading where it stood, the rest sliding over: at rest before the next is pressed)
      t.run_for(@ui.move_most_ms)
      let (cx, cy, cw, ch) = t.query(Button, label=@sf.t("web-main.file.remove", args=[("name", "build.log")])).unwrap().rect
      t.tap(cx + cw / 2.0, cy + ch / 2.0)
      t.draw()
      let left = @sfbase.writing(src, "ws1/st1:s-c1").files.get()
      assert_eq(left.length(), 1)
      assert_eq(text(Some(left[0]), "name"), "第二张.png")
    }
  })
}

///|
test "a waiting file's card stands off the composer's frosted ground by its own ground alone, as tall as a picture beside it, on a phone and a computer alike" {
  both_pages(fn() raise {
    // (the user, 2026-10-16: 附件有点难以分辨; 2026-10-25: 背景色好分辨就行了，不用这么深阴影; @sf.composer_card)
    for platform in [2, 0] {
      let calls : Array[Made] = []
      let made : Ref[Source?] = Ref(None)
      let t = fake_core(calls, made~, platform~)
      let src = made.val.unwrap()
      let w = @sfbase.writing(src, "ws1/st1:s-c1")
      @sfbase.writing_add(src, w, "ws1/st1", "照片.png", png_head())
      @sfbase.writing_add(src, w, "ws1/st1", "build.log", @utf8.encode("夜里的构建日志"))
      t.draw()
      t.run_for(@ui.move_most_ms)
      let (x, y, cw, ch) = match t.query(Group, label="build.log") {
        Some(g) => g.rect
        None => fail("no card for build.log (platform \{platform})")
      }
      let near = fn(a : Double, b : Double) { (a - b).abs() < 0.5 }
      // (the capsule whiter than its paper: the neutral)
      let ground = @sf.theme().p.neutral_bg
      let drawn = t.drawn_rects().filter(fn(r) { near(r.0, x) && near(r.1, y) && near(r.2, cw) && near(r.3, ch) })
      assert_true(drawn.iter().any(fn(r) { r.4 == ground }), msg="its ground (platform \{platform}): \{Repr(drawn.map(fn(r) { r.4 }))}, not \{ground}")
      assert_false(t.drawn_shadows().iter().any(fn(s) { near(s.0, x) && near(s.2, cw) }), msg="a shadow under it (platform \{platform})")
      let tiles = @sfbase.writing(src, "ws1/st1:s-c1").files.get().filter_map(fn(f) {
        waiting_tile_at(t, "ws1/st1//draft:" + text(Some(f), "id"))
      })
      assert_eq(tiles.length(), 1)
      assert_true(near(ch, tiles[0].3), msg="the card \{ch} high, the picture \{tiles[0].3} (platform \{platform})")
    }
  })
}

///|
test "an archived chat says sending restores it and accepts a message without first pressing restore" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" {
        return tp
      }
      match tp.value {
        Some(Object(o)) => {
          let o2 = o.copy()
          o2["archived"] = Json::boolean(true)
          { ..tp, value: Some(Json::object(o2)) }
        }
        _ => tp
      }
    })
    assert_true(t.find("已归档，发送消息将还原") is Some(_))
    assert_true(t.find("还原对话") is Some(_))
    t.tap_text("发消息")
    t.type_text("再看一下")
    assert_eq(named(calls, "session.warm").length(), 0)
    tap_send(t)
    let sent = named(calls, "chat.send")
    assert_eq(sent.length(), 1)
    assert_eq(text(Some(sent[0].params), "text"), "再看一下")
    assert_eq(named(calls, "chat.archive").length(), 0)
  })
}

///|
test "an archived chat's restore failing says why under it, in red; tapped again it is tried again" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" {
        return tp
      }
      match tp.value {
        Some(Object(o)) => {
          let o2 = o.copy()
          o2["archived"] = Json::boolean(true)
          { ..tp, value: Some(Json::object(o2)) }
        }
        _ => tp
      }
    })
    t.tap_text("还原对话")
    let asked = named(calls, "chat.archive")
    assert_eq(asked.length(), 1)
    assert_true(t.find("正在还原") is Some(_))
    (asked[0].done)(Err({ "code": "offline", "message": "station 没有回应" }))
    t.draw()
    assert_true(t.find("station 没有回应") is Some(_))
    t.tap_text("还原对话")
    assert_eq(named(calls, "chat.archive").length(), 2)
    // tried again: what failed before is not said meanwhile
    assert_true(t.find("station 没有回应") is None)
    // the capsule back to its height without the line
    t.run_for(@ui.move_most_ms)
    // (the chat's pictures brushed in once decoded: sfpages message_files.mbt)
    t.run_for(@sfpages.reveal_ms)
    t.assert_idle()
  })
}

///|
test "its agent's cache over: the current choice opens the choices and changing it asks once" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" {
        return tp
      }
      match tp.value {
        Some(v) => { ..tp, value: Some(@sffixture.with_cache_cold(v)) }
        None => tp
      }
    })
    assert_true(t.find("缓存已过期") is Some(_))
    assert_true(t.find("重读约 $1.49") is Some(_))
    t.click(Button, label="接着聊")
    assert_true(t.get(MenuItemRadio, label="接着聊").check is Some(On))
    assert_true(t.get(MenuItemRadio, label="换新上下文").check is Some(Off))
    t.click(MenuItemRadio, label="接着聊")
    t.draw()
    assert_eq(named(calls, "session.settings").length(), 0, msg="the one taken: nothing to ask")
    t.run_for(@motion.pop_out_ms)
    t.click(Button, label="接着聊")
    t.click(MenuItemRadio, label="换新上下文")
    t.draw()
    let asked = named(calls, "session.settings")
    assert_eq(asked.length(), 1)
    assert_eq(text(Some(asked[0].params), "key"), "s-c1")
    assert_eq(field(Some(asked[0].params), "afresh"), Some(Json::boolean(true)))
    t.draw()
    assert_true(t.get(Button, label="接着聊").disabled, msg="the choice is held while the change is on its way")
    assert_eq(named(calls, "session.settings").length(), 1, msg="on its way: not asked again")
  })
}

///|
test "its agent's cache over, set to go on afresh: 换新上下文 taken, 接着聊 takes going on" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" {
        return tp
      }
      match tp.value {
        Some(Object(o)) => {
          let o2 = o.copy()
          o2["cacheCold"] = { "session": "s-c1", "status": "缓存已过期", "detail": "重读约 $1.49", "afresh": true }
          { ..tp, value: Some(Json::object(o2)) }
        }
        _ => tp
      }
    })
    assert_true(t.find("缓存已过期") is Some(_))
    assert_true(t.find("重读约 $1.49") is Some(_))
    t.click(Button, label="换新上下文")
    assert_true(t.get(MenuItemRadio, label="换新上下文").check is Some(On))
    t.click(MenuItemRadio, label="接着聊")
    t.draw()
    let asked = named(calls, "session.settings")
    assert_eq(asked.length(), 1)
    assert_eq(field(Some(asked[0].params), "afresh"), Some(Json::boolean(false)))
  })
}

///|
test "an offline station's cache choice stays visible but cannot be opened" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" { return tp }
      match tp.value {
        Some(Object(o)) => {
          let o2 = o.copy()
          o2["cacheCold"] = { "session": "s-c1", "status": "缓存已过期", "detail": "重读约 $1.49", "afresh": false }
          o2["offline"] = Json::boolean(true)
          { ..tp, value: Some(Json::object(o2)) }
        }
        _ => tp
      }
    })
    assert_true(t.get(Button, label="接着聊").disabled)
    assert_true(t.query(MenuItemRadio, label="换新上下文") is None)
    assert_eq(named(calls, "session.settings").length(), 0)
  })
}

///|
test "the cache choice can be changed from the keyboard" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = decide_core(calls, "chat-cache-cold", wide=true)
    let choice = t.get(Button, label="接着聊")
    t.ctx().focus_on(choice.id, visible=true)
    t.draw()
    assert_eq(t.focused().map(fn(n) { n.label }), Some("接着聊"), msg="the choice has keyboard focus")
    t.enter()
    t.draw()
    assert_true(t.query(MenuItemRadio, label="换新上下文") is Some(_), msg="Enter opens the choices")
    assert_eq(t.focused().map(fn(n) { n.role }), Some(MenuItemRadio), msg="the menu focuses an item")
    t.key(@ui.key_code_down)
    assert_eq(t.focused().map(fn(n) { n.label }), Some("换新上下文"), msg="Down moves to the other choice")
    t.enter()
    t.draw()
    let asked = named(calls, "session.settings")
    assert_eq(asked.length(), 1)
    assert_eq(field(Some(asked[0].params), "afresh"), Some(Json::boolean(true)))
  })
}

///|
test "Down opens the cache choice and keeps it open for the keyboard" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = decide_core(calls, "chat-cache-cold", wide=true)
    let choice = t.get(Button, label="接着聊")
    t.ctx().focus_on(choice.id, visible=true)
    t.draw()
    t.key(@ui.key_code_down)
    t.draw()
    assert_true(t.query(MenuItemRadio, label="换新上下文") is Some(_), msg="Down opens the choices")
    t.draw()
    assert_true(t.query(MenuItemRadio, label="换新上下文") is Some(_), msg="the choices stay open")
    let first = t.focused().map(fn(n) { n.label })
    assert_eq(first, Some("接着聊"), msg="Down opens the menu at its first choice, got \{Repr(first)}")
    t.key(@ui.key_code_down)
    let second = t.focused().map(fn(n) { n.label })
    assert_eq(second, Some("换新上下文"), msg="Down moves to the second choice, got \{Repr(second)}")
    t.enter()
    t.draw()
    assert_eq(named(calls, "session.settings").length(), 1)
  })
}

///|
test "choosing how to continue an expired cache keeps the draft's keyboard" {
  both_pages(fn() raise {
    for platform in [1, 2] {
      let calls : Array[Made] = []
      let t = fake_core(calls, platform~, over=fn(name, tp) {
        if name != "chat" { return tp }
        match tp.value {
          Some(v) => { ..tp, value: Some(@sffixture.with_cache_cold(v)) }
          None => tp
        }
      })
      t.tap_text("发消息")
      t.type_text("签名")
      keyboard_up(t, 300.0)
      t.click(Button, label="接着聊")
      // (the old composer's choices a menu over the field; made as nodes, on 小屏 a sheet of the window's tree
      // (sheet_shows_node), which takes the keys while it is up, the field's focus given back as it goes)
      t.click(MenuItemRadio, label="换新上下文")
      assert_eq(named(calls, "session.settings").length(), 1)
      assert_true(t.ime().0, msg="the keyboard stays after choosing")
      t.type_text("权限")
      assert_eq(t.ime().1, "签名权限")
    }
  })
}

///|
test "a cache notice on a narrow page keeps its cost together and both choices reachable" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let status = "缓存已过期"
    let detail = "重读约 $7.50"
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" {
        return tp
      }
      match tp.value {
        Some(Object(o)) => {
          let o2 = o.copy()
          o2["cacheCold"] = { "session": "s-c1", "status": Json::string(status), "detail": Json::string(detail), "afresh": true }
          { ..tp, value: Some(Json::object(o2)) }
        }
        _ => tp
      }
    })
    t.resize(360.0, 844.0)
    t.set_font_scale(1.3)
    t.draw()
    assert_eq(t.lines_of(status), [status], msg="the status fits beside the mark")
    assert_eq(t.lines_of(detail), [detail], msg="the cost stays together")
    t.click(Button, label="换新上下文")
    assert_true(t.get(MenuItemRadio, label="换新上下文").check is Some(On))
    t.click(MenuItemRadio, label="接着聊")
    let asked = named(calls, "session.settings")
    assert_eq(asked.length(), 1)
    assert_eq(field(Some(asked[0].params), "afresh"), Some(Json::boolean(false)))
  })
}

///|
test "the cache notice keeps status and cost together with a compact choice on a narrow page" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" { return tp }
      match tp.value {
        Some(v) => { ..tp, value: Some(@sffixture.with_cache_cold(v)) }
        None => tp
      }
    })
    t.resize(390.0, 844.0)
    t.draw()
    t.run_for(@ui.move_most_ms)
    let (_, last_y, _, last_h) = t.rect_of("推送截图前要先登录 gh。").unwrap()
    let (sx, sy, sw, sh) = t.rect_of("缓存已过期").unwrap()
    let (dx, dy, _, _) = t.rect_of("重读约 $1.49").unwrap()
    let (cx, cy, cw, ch) = t.get(Button, label="接着聊").rect
    assert_true(sy >= last_y + last_h, msg="cache cold sits below last message: sy=\{sy}, last_end=\{last_y + last_h}")
    assert_true(dx >= sx + sw && (dy - sy).abs() < 1.0, msg="the status and cost share a line")
    assert_true((sy + sh / 2.0 - cy - ch / 2.0).abs() < 1.0, msg="status, cost and choice fit on one line at 390pt")
    let glass = t.drawn_glass_corners().filter(fn(g) { g.0 < sx && g.0 + g.2 > cx + cw && g.1 < sy && g.1 + g.3 > cy })
    assert_eq(glass.length(), 0, msg="cache cold is an inline list row, not floating glass")
    assert_eq(t.audit(), [], msg="zero audit faults at 390x844")
    t.click(Button, label="接着聊")
    t.click(MenuItemRadio, label="换新上下文")
    assert_eq(named(calls, "session.settings").length(), 1)
  })
}

///|
test "its agent's cache over, in the wide frame: said over the composer, 换新上下文 sets it to go on afresh" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = decide_core(calls, "chat-cache-cold", wide=true)
    assert_true(t.find("缓存已过期") is Some(_))
    assert_true(t.find("重读约 $1.49") is Some(_))
    let (_, sy, _, sh) = t.rect_of("缓存已过期").unwrap()
    let (_, cy, _, ch) = t.get(Button, label="接着聊").rect
    assert_true((sy + sh / 2.0 - cy - ch / 2.0).abs() < 1.0, msg="status and choice are centred together")
    t.click(Button, label="接着聊")
    t.click(MenuItemRadio, label="换新上下文")
    t.draw()
    let asked = named(calls, "session.settings")
    assert_eq(asked.length(), 1)
    assert_eq(text(Some(asked[0].params), "key"), "s-c1")
    assert_eq(field(Some(asked[0].params), "afresh"), Some(Json::boolean(true)))
  })
}

///|
test "an empty focused composer and its cache choice stay in place while the menu has focus" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = decide_core(calls, "chat-cache-cold", wide=true)
    assert_true(t.ctx().field_focused(), msg="the composer's field has focus before the choice opens")
    let (_, before_y, _, _) = t.rect_of("缓存已过期").unwrap()
    t.click(Button, label="接着聊")
    assert_true(t.query(MenuItemRadio, label="换新上下文") is Some(_))
    // Beyond the empty composer's focus-loss delay and its shape's transition, the choice is still under the pointer.
    t.run_for(@sfpages.let_go_ms + @ui.move_most_ms)
    let (_, after_y, _, _) = t.rect_of("缓存已过期").unwrap()
    assert_true((after_y - before_y).abs() < 1.0, msg="the open choice moved from \{before_y} to \{after_y}")
    t.click(MenuItemRadio, label="换新上下文")
    t.draw()
    let asked = named(calls, "session.settings")
    assert_eq(asked.length(), 1)
    assert_eq(field(Some(asked[0].params), "afresh"), Some(Json::boolean(true)))
  })
}

///|
test "a cache choice opened over a collapsed composer leaves it collapsed" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = decide_core(calls, "chat-cache-cold", wide=true)
    t.ctx().blur()
    t.run_for(@sfpages.let_go_ms + @ui.move_most_ms)
    let (_, before_y, _, _) = t.rect_of("缓存已过期").unwrap()
    t.click(Button, label="接着聊")
    t.run_for(@sfpages.let_go_ms + @ui.move_most_ms)
    let (_, after_y, _, _) = t.rect_of("缓存已过期").unwrap()
    assert_true((after_y - before_y).abs() < 1.0, msg="the collapsed composer moved from \{before_y} to \{after_y}")
  })
}

///|
test "cache cold sits below need card with zero audit faults across sizes, font scale and English" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" { return tp }
      match tp.value {
        Some(v) => { ..tp, value: Some(@sffixture.with_cache_cold(@sffixture.with_need(v))) }
        None => tp
      }
    })
    t.resize(390.0, 844.0)
    t.draw()
    t.run_for(@ui.move_most_ms)
    let (_, ny, _, nh) = t.rect_of(@sffixture.need_state.2).unwrap()
    let (_, cy, _, _) = t.rect_of("缓存已过期").unwrap()
    assert_true(cy >= ny + nh, msg="cache cold sits below need card: ny+nh=\{ny + nh}, cy=\{cy}")
    assert_eq(t.audit(), [], msg="zero audit faults at 390x844 (1.0x)")
    t.resize(360.0, 844.0)
    t.set_font_scale(1.3)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_eq(t.audit(), [], msg="zero audit faults at 360x844 (1.3x)")
    t.set_font_scale(1.0)
    t.resize(320.0, 568.0)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_eq(t.audit(), [], msg="zero audit faults at 320x568 (1.0x)")
    // Wide desktop screen (1280x800, platform=0)
    let calls_wide : Array[Made] = []
    let t_wide = fake_core(calls_wide, platform=0, over=fn(name, tp) {
      if name != "chat" { return tp }
      match tp.value {
        Some(v) => { ..tp, value: Some(@sffixture.with_cache_cold(@sffixture.with_need(v))) }
        None => tp
      }
    })
    t_wide.resize(1280.0, 800.0)
    t_wide.draw()
    t_wide.run_for(@ui.move_most_ms)
    let faults_wide = t_wide
      .audit()
      .filter(fn(f) { !(f.contains("stillfail/sf/src/edge_node.mbt:") && f.contains("sfdesk/pane_view.mbt:")) })
    assert_eq(faults_wide, [], msg="zero audit faults at 1280x800 (1.0x): \{Repr(faults_wide)}")
    // English locale
    @sf.set_language(Some("en"))
    let calls_en : Array[Made] = []
    let t_en = fake_core(calls_en, over=fn(name, tp) {
      if name == "prefs" {
        return { ..tp, value: Some({ "lang": "en" }) }
      }
      if name != "chat" { return tp }
      match tp.value {
        Some(v) => { ..tp, value: Some(@sffixture.with_cache_cold(@sffixture.with_need(v))) }
        None => tp
      }
    })
    t_en.resize(390.0, 844.0)
    t_en.draw()
    t_en.run_for(@ui.move_most_ms)
    assert_true(t_en.find("Cache expired") is Some(_), msg="English status shown")
    assert_true(t_en.find("Reread ≈$1.49") is Some(_), msg="English detail shown")
    assert_eq(t_en.audit(), [], msg="zero audit faults in English at 390x844")
    t_en.resize(360.0, 844.0)
    t_en.set_font_scale(1.3)
    t_en.draw()
    t_en.run_for(@ui.move_most_ms)
    assert_eq(t_en.audit(), [], msg="zero audit faults in English at 360x844 (1.3x)")
    @sf.set_language(None)
  })
}

///|
test "scrolling up in a long chat moves cache cold out of the viewport with the messages" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" { return tp }
      match tp.value {
        Some(v) => { ..tp, value: Some(@sffixture.with_cache_cold(v)) }
        None => tp
      }
    })
    t.resize(390.0, 844.0)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("缓存已过期") is Some(_), msg="cache cold visible at list bottom")
    for _ in 0..<8 {
      t.wheel(195.0, 400.0, -300.0)
    }
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("缓存已过期") is None, msg="cache cold scrolled out of viewport with messages")
  })
}

///|
test "sending online hides cache cold on the send frame while offline keeps it visible and disabled" {
  both_pages(fn() raise {
    // Online send: hides immediately on send frame
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" { return tp }
      match tp.value {
        Some(v) => { ..tp, value: Some(@sffixture.with_cache_cold(v)) }
        None => tp
      }
    })
    assert_true(t.find("缓存已过期") is Some(_), msg="cache cold shown before online send")
    t.tap_text("发消息")
    t.type_text("签名")
    t.click(Button, label=@sf.t("web-main.composer.send"))
    t.draw()
    assert_true(t.find("缓存已过期") is None, msg="cache cold hidden immediately on online send frame")
    // Offline send: stays visible and chooser stays disabled
    let calls_off : Array[Made] = []
    let t_off = fake_core(calls_off, over=fn(name, tp) {
      if name != "chat" { return tp }
      match tp.value {
        Some(v) => { ..tp, value: Some(@sffixture.with_flag(@sffixture.with_cache_cold(v), "offline")) }
        None => tp
      }
    })
    assert_true(t_off.find("缓存已过期") is Some(_), msg="cache cold shown before offline send")
    t_off.tap_text("发消息")
    t_off.type_text("签名")
    t_off.click(Button, label=@sf.t("web-main.composer.send"))
    t_off.draw()
    assert_true(t_off.find("缓存已过期") is Some(_), msg="cache cold remains visible after offline send")
    assert_true(t_off.get(Button, label="接着聊").disabled, msg="cache cold chooser remains disabled offline")
  })
}

///|
test "a notice over the composer wrapped to lines: round as one line is, its mark on its first line" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let said = "「Birch」正在更新：当前显示的是之前读取的内容，更新完成后会自动重新连接，发出的消息届时送达"
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" {
        return tp
      }
      match tp.value {
        Some(Object(o)) => {
          let o2 = o.copy()
          o2["offline"] = Json::boolean(true)
          o2["updating"] = Json::boolean(true)
          o2["offlineNote"] = Json::string(said)
          { ..tp, value: Some(Json::object(o2)) }
        }
        _ => tp
      }
    })
    t.run_for(@ui.move_most_ms)
    let (wx, wy, _, wh) = t.rect_of(said).unwrap()
    let line = @sf.theme().t.meta_line
    assert_true(wh > 1.5 * line, msg="wrapped (\{wh} high)")
    let notice = t
      .drawn_glass_corners()
      .filter(fn(g) { g.0 < wx && g.0 + g.2 > wx && g.1 < wy && g.1 + g.3 > wy + wh })
    assert_eq(notice.length(), 1)
    let (gx, gy, _, _, corner) = notice[0]
    // as round as it is high on one line: its words' line and 8 over and under it
    assert_eq(corner, line / 2.0 + 8.0)
    // its mark in the middle of its round start, on its words' first line: its ring's (its lines each a piece of their
    // own; its leftmost pieces, about its middle, the ring's: the arrows in it, one hidden under it, are narrower)
    let marks = t
      .drawn_order()
      .filter(fn(d) { d.0 != 5 && d.0 != 6 && d.1 >= gx && d.1 + d.3 <= wx && d.2 >= gy && d.2 + d.4 <= wy + wh })
    assert_true(marks.length() > 0, msg="its mark drawn")
    let left = marks.fold(init=@double.infinity, fn(a, m) { if m.1 < a { m.1 } else { a } })
    let ring = marks.filter(fn(m) { m.1 < left + 0.5 })
    let mid = ring.fold(init=0.0, fn(a, m) { a + m.2 + m.4 / 2.0 }) / ring.length().to_double()
    assert_true((mid - (wy + line / 2.0)).abs() < 1.0, msg="its mark at \{mid}, its first line's middle \{wy + line / 2.0}")
    assert_true((mid - (gy + corner)).abs() < 1.0, msg="its mark at \{mid}, its round start's middle \{gy + corner}")
  })
}

///|
/// The notice drawn over the composer's ground and that ground, as drawn now (their glass, the lowest two on the page):
/// how far the notice's bottom is over the ground's top, and where that top is.
fn notice_over_ground(t : @ui.Tester) -> (Double, Double) {
  let glass = t.drawn_glass_corners().copy()
  glass.sort_by(fn(a, b) { a.1.compare(b.1) })
  let n = glass.length()
  let ground = glass[n - 1]
  let notice = glass[n - 2]
  (ground.1 - (notice.1 + notice.3), ground.1)
}

///|
test "a notice over a phone's composer goes with its ground as it opens, as far over it in every frame" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" {
        return tp
      }
      match tp.value {
        Some(Object(o)) => {
          let o2 = o.copy()
          o2["offline"] = Json::boolean(true)
          o2["offlineNote"] = Json::string("「Birch」离线")
          { ..tp, value: Some(Json::object(o2)) }
        }
        _ => tp
      }
    })
    t.run_for(@ui.move_most_ms)
    let (apart, top) = notice_over_ground(t)
    t.tap_text("发消息")
    let until = t.time() + @ui.move_most_ms
    while t.time() < until {
      let (now, _) = notice_over_ground(t)
      assert_true((now - apart).abs() < 0.5, msg="\{now} over the ground at \{t.time()}, \{apart} at rest")
      t.frame()
    }
    let (now, opened) = notice_over_ground(t)
    assert_true((now - apart).abs() < 0.5, msg="\{now} over the ground opened, \{apart} at rest")
    assert_true(top - opened > 4.0, msg="the composer opened taller: its top at \{opened}, \{top} at rest")
  })
}

///|
test "the composer's buttons say what they are: ＋ (发送文件), 发送" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls)
    t.tap_text("发消息")
    t.type_text("第一行要点")
    let labels = t.semantics().filter(fn(s) { s.role == @ui.Role::Button }).map(fn(s) { s.label })
    assert_true(labels.contains(@sf.t("web-main.composer.attach")))
    assert_true(labels.contains("发送"))
  })
}

///|
test "a long press or tap on a message leaves the keyboard up" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls)
    t.tap_text("发消息")
    t.type_text("写到一半")
    // (a message above the opened composer: a press on it is outside it)
    let (x, y) = t.find("推送截图前要先登录 gh。").unwrap()
    // the field's top (an editor's node holds its placeholder, not its words: where the input method is told it is)
    let (_, cap_y, _, _) = t.ime_rect()
    assert_true(y < cap_y - 60.0)
    t.press_at(x, y)
    t.run_for(long_press_ms)
    t.release(x, y)
    let (active, _, _, _) = t.ime()
    assert_true(active)
    // What was picked let go, then a tap on the message's words: the draft is still being written.
    t.back()
    t.tap(x, y)
    let (after, _, _, _) = t.ime()
    assert_true(after)
  })
}

///|
test "a picture restored in the composer remains visible in the sending message" {
  both_pages(fn() raise {
    new_run()
    let base = fixture("chat")
    let in_draft = Ref(true)
    let src : Source = {
      ..base,
      draft_picture: fn(_, _) {
        @ui.add_image("mem:test/restored", png_head())
        "mem:test/restored"
      },
      // Its station has not supplied a picture: the message must use the one already in the composer.
      file: fn(_, _, _) { "" },
      topic_read: fn(name, params) {
        let now = base.topic(name, params).get().snapshot()
        if name != "composer" || !in_draft.val { return now }
        let m = match now.value { Some(Object(v)) => v.copy(); _ => {} }
        m["files"] = [{ "id": "kept-1", "name": "截图.png", "size": 120, "sent": 40 }]
        m["ready"] = Json::boolean(true)
        { value: Some(Json::object(m)), error: now.error, version: now.version + 1 }
      },
      call: fn(name, params, done) {
        match name {
          "composer.take" => {
            in_draft.val = false
            done(Ok({ "text": "", "quotes": [], "attachments": [], "uploads": [{ "id": "kept-1", "name": "截图.png", "size": 120 }], "version": 2 }))
          }
          "chat.send" => ()
          _ => (base.call)(name, params, done)
        }
      },
    }
    open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
    t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
    assert_true(t.locate("img:mem:test/restored").length() > 0)
    tap_send(t)
    // (the old page's flight, send_flight: made as nodes, its row flies from the composer by itself, View::flies_in,
    // the picture its message draws held below)
    t.run_for(@sfbase.flight_most_ms)
    let points = t.locate("img:mem:test/restored")
    assert_true(points.length() > 0, msg="the sending message has no picture")
    assert_true(points.iter().any(fn(p) {
      t.drawn_images().iter().any(fn(i) { i[8] > 0.9 && p.0 >= i[0] && p.0 <= i[0] + i[2] && p.1 >= i[1] && p.1 <= i[1] + i[3] })
    }), msg="the sending message did not draw the picture: \{Repr(t.drawn_images())}")
  })
}

///|
test "a freshly picked picture remains visible throughout sending" {
  both_pages(fn() raise {
    new_run()
    let src = fixture("chat")
    open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
    t.run_for(@ui.move_most_ms)
    @sfbase.writing_add(src, @sfbase.writing(src, "ws1/st1:s-c1"), "ws1/st1", "截图.png", png_head())
    t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
    let tile = t.drawn_images().filter(fn(i) { (i[2] - 56.0).abs() < 0.5 && i[8] > 0.9 })
    assert_true(tile.length() > 0, msg="no visible picture in the composer: \{Repr(t.drawn_images())}")
    tap_send(t)
    assert_true(t.drawn_images().iter().any(fn(i) { i[2] >= 55.5 && i[8] > 0.9 }), msg="as it is sent: \{Repr(t.drawn_images())}")
    t.run_for(@sfbase.flight_len(true) * 0.4)
    let mid_imgs = t.drawn_images()
    assert_true(
      mid_imgs.iter().any(fn(i) { i[2] > 56.5 && i[8] > 0.9 }) ||
        mid_imgs.filter(fn(i) { i[2] < 56.0 && i[8] > 0.5 }).length() >= 8,
      msg="on its way: \{Repr(mid_imgs)}",
    )
    t.run_for(@sfbase.flight_len(true) + @sf.hint_back_ms)
    assert_true(t.drawn_images().iter().any(fn(i) { i[2] > 56.5 && i[8] > 0.9 }), msg="in the message: \{Repr(t.drawn_images())}")
  })
}

///|
test "a chat linked to one Slack thread: 抄送 while writing opens it to tick, and closes once ticked (chat.cc)" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" {
        return tp
      }
      match tp.value {
        Some(Object(o)) => {
          let o2 = o.copy()
          o2["cc"] = [{ "thread": 21, "place": "#still-fail", "via": "slack", "on": false }]
          { ..tp, value: Some(Json::object(o2)) }
        }
        _ => tp
      }
    })
    // (the capsule says nothing of it; opened to write, its row under the words has it)
    t.tap_text("发消息")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label=@sf.t("web-main.composer.ccLabel"))
    t.click(MenuItemCheckbox, label="#still-fail")
    let asked = named(calls, "chat.cc")
    assert_eq(asked.length(), 1)
    assert_eq(asked[0].params, { "station": "ws1/st1", "thread": 7, "to": 21, "on": true })
    t.draw()
    // (made as nodes, the menu going out on its way: pop_out_ms, menu_node's)
    t.run_for(@motion.pop_out_ms)
    // one: closed once ticked
    assert_true(t.find("#still-fail") is None, msg=t.words().map(fn(x) { x.0 }).join("|"))
  })
}

///|
test "a picture restored in the composer opens in the viewer when tapped" {
  both_pages(fn() raise {
    new_run()
    let base = fixture("chat")
    let src : Source = {
      ..base,
      draft_picture: fn(_, id) {
        let bytes = png_head()
        @sfbase.writing_kept(id, bytes)
        @ui.add_image("mem:test/restored", bytes)
        "mem:test/restored"
      },
      topic_read: fn(name, params) {
        let now = base.topic(name, params).get().snapshot()
        if name != "composer" { return now }
        let m = match now.value { Some(Object(v)) => v.copy(); _ => {} }
        m["files"] = [{ "id": "kept-1", "name": "截图.png", "size": 120, "waits": true }]
        m["ready"] = Json::boolean(true)
        { value: Some(Json::object(m)), error: now.error, version: now.version + 1 }
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
    t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
    // (the old composer's tile where it noted it, the new chat's made as nodes the end of the viewer's flight that
    // stays: waiting_tile_at)
    let (x, y, w, h, _) = match waiting_tile_at(t, "ws1/st1//draft:kept-1") {
      Some(tile) => tile
      None => fail("the restored picture tile is not kept for the viewer to fly from")
    }
    t.tap(x + w / 2.0, y + h / 2.0)
    match viewer.get() {
      Some(v) => {
        assert_eq(v.file.path, "draft:kept-1")
        assert_eq(v.id(), "ws1/st1//draft:kept-1")
        assert_true(v.bytes.get() is Some(_))
        assert_false(v.coming())
      }
      None => fail("tapping a restored picture in the composer did not open the viewer")
    }
  })
}

///|
test "a video waiting in the composer made as nodes stands on a video's black in the dark, as in the light, never the words' ink" {
  for dark in [false, true] {
    let calls : Array[Made] = []
    let made : Ref[Source?] = Ref(None)
    let t = fake_core(calls, made~)
    t.set_dark(dark)
    t.draw()
    let src = made.val.unwrap()
    let w = @sfbase.writing(src, "ws1/st1:s-c1")
    // (no picture of it yet: its tile its ground alone)
    @sfbase.writing_add(src, w, "ws1/st1", "视频.mov", b"video")
    t.run_for(@ui.move_most_ms)
    let id = text(Some(w.files.get()[0]), "id")
    let (x, y, tw, th) = match t.stays_of("ws1/st1//draft:" + id) {
      Some((r, _)) => r
      None => fail("dark \{dark}: no tile for the video")
    }
    let grounds = t.drawn_rects().filter(fn(r) { r.0 <= x + tw / 2.0 && r.0 + r.2 >= x + tw / 2.0 && r.1 <= y + th / 2.0 && r.1 + r.3 >= y + th / 2.0 }).map(fn(r) { r.4 })
    assert_true(grounds.contains(0x000000FFL), msg="dark \{dark}: \{Repr(grounds)}")
    assert_false(grounds.contains(@sf.theme().p.text), msg="dark \{dark}: \{Repr(grounds)}")
  }
}

///|
test "a picture restored in the composer made as nodes shows as the device reads it, and the viewer opens on it" {
  new_run()
  let base = fixture("chat")
  let answer : Ref[((Result[(Json, Bytes?), Json]) -> Unit)?] = Ref(None)
  let src : Source = {
    ..base,
    // (read by the device as the core answers composer.picture: here once the test says so)
    draft_picture: fn(key, id) {
      base.images.get("", "draft\u{1}" + key + "\u{1}" + id, "mem:test/restored-late", fn(_, done) { answer.val = Some(done) })
    },
    topic_read: fn(name, params) {
      let now = base.topic(name, params).get().snapshot()
      if name != "composer" { return now }
      let m = match now.value { Some(Object(v)) => v.copy(); _ => {} }
      m["files"] = [{ "id": "kept-late", "name": "截图.png", "size": 120, "waits": true }]
      m["ready"] = Json::boolean(true)
      { value: Some(Json::object(m)), error: now.error, version: now.version + 1 }
    },
  }
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  assert_true(answer.val is Some(_), msg="the device's kept picture was not asked")
  assert_eq(t.locate("img:mem:test/restored-late").length(), 0)
  // (the device has read it: its tile shows it, told, nothing else changed)
  (answer.val.unwrap())(Ok((Json::object({}), Some(png_head()))))
  t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
  assert_true(t.locate("img:mem:test/restored-late").length() > 0, msg="the restored picture did not come to its tile")
  let (x, y, tw, th) = match t.stays_of("ws1/st1//draft:kept-late") {
    Some((r, _)) => r
    None => fail("no tile for the restored picture")
  }
  t.tap(x + tw / 2.0, y + th / 2.0)
  match @sfbase.viewer.get() {
    Some(v) => {
      assert_eq(v.file.path, "draft:kept-late")
      // (no bytes of it here: what stands in for it the picture its tile shows, never a station's)
      assert_eq(v.stand_in(src), "mem:test/restored-late")
    }
    None => fail("the viewer did not open")
  }
}

///|
test "a message's picture quoted in the composer made as nodes shows as its station's comes, never a grey square for good" {
  new_run()
  let base = fixture("chat")
  let answer : Ref[((Result[(Json, Bytes?), Json]) -> Unit)?] = Ref(None)
  let src : Source = {
    ..base,
    // (its station's picture of it: here once the test says so)
    file: fn(station, key, name) {
      if name != "quoted.png" {
        return (base.file)(station, key, name)
      }
      base.images.get(station, @sfbase.file_image_id(station, key, name), "mem:test/quoted", fn(_, done) {
        answer.val = Some(done)
      })
    },
  }
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, w, { "author": "Ana", "text": "图", "ts": "ts8" }, file={
    "name": "quoted.png",
    "path": "/w/uploads/quoted.png",
    "size": 120.0,
    "owner": "s-c1",
    "width": 800.0,
    "height": 600.0,
  })
  t.run_for(@ui.move_most_ms)
  assert_true(answer.val is Some(_), msg="its station's picture was not asked")
  assert_eq(t.locate("img:mem:test/quoted").length(), 0)
  (answer.val.unwrap())(Ok((Json::object({}), Some(png_head()))))
  t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
  assert_true(t.locate("img:mem:test/quoted").length() > 0, msg="the quoted picture did not come to its tile")
}

///|
test "cacheCold notice arriving and leaving while idle eases the message list smoothly on both chat pages" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let cold = @signals.signal(false)
    let rev = @signals.signal(0)
    let t = fake_core(calls, platform=0, over=fn(name, tp) {
      if name != "chat" {
        return tp
      }
      let on = cold.get()
      let r = rev.get()
      match tp.value {
        Some(v) => {
          let value = if on { @sffixture.with_cache_cold(v) } else { v }
          { ..tp, value: Some(value), version: tp.version + r }
        }
        None => tp
      }
    })
    t.resize(1280.0, 900.0)
    t.run_for(@ui.move_most_ms * 3.0)
    t.assert_idle()
    let y_of = fn() raise {
      match t.rect_of("推送截图前要先登录 gh。") {
        Some((_, y, _, _)) => y
        None => fail("message not found")
      }
    }
    let y0 = y_of()
    // Notice arrives asynchronously while the chat sits idle: messages lift smoothly across frames, never snapping.
    cold.set(true)
    rev.set(1)
    let mut prev = y0
    let mut enter_max_step = 0.0
    for _ in 0..<45 {
      t.run_for(@ui.frame_period_default)
      let y = y_of()
      let step = (y - prev).abs()
      if step > enter_max_step {
        enter_max_step = step
      }
      prev = y
    }
    t.run_for(@ui.move_most_ms * 2.0)
    t.assert_idle()
    let y1 = y_of()
    let lift = y0 - y1
    assert_true(lift > 8.0, msg="notice should lift messages: y0=\{y0}, y1=\{y1}")
    assert_true(
      enter_max_step < lift * 0.6,
      msg="notice enter should ease smoothly, not snap in one frame: lift=\{lift}, max_step=\{enter_max_step}",
    )
    // Notice disappears asynchronously while idle: messages settle back smoothly without snapping.
    cold.set(false)
    rev.set(2)
    let mut prev_exit = y1
    let mut exit_max_step = 0.0
    for _ in 0..<60 {
      t.run_for(@ui.frame_period_default)
      let y = y_of()
      let step = (y - prev_exit).abs()
      if step > exit_max_step {
        exit_max_step = step
      }
      prev_exit = y
    }
    t.run_for(@ui.move_most_ms * 2.0)
    t.assert_idle()
    let y2 = y_of()
    assert_true((y2 - y0).abs() <= 1.0, msg="messages should settle back to y0=\{y0}, got y2=\{y2}")
    assert_true(
      exit_max_step < lift * 0.6,
      msg="notice exit should ease smoothly, not snap in one frame: lift=\{lift}, max_step=\{exit_max_step}",
    )
  })
}

///|
test "idle chat refresh updating message relative times moves no messages on both chat pages" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let tick = @signals.signal(0)
    let t = fake_core(calls, over=fn(name, tp) {
      if name != "chat" {
        return tp
      }
      let k = tick.get()
      if k == 0 {
        return tp
      }
      match tp.value {
        Some(Object(o)) => {
          let o2 = o.copy()
          match o2.get("messages") {
            Some(Array(ms)) => {
              let ms2 = ms.map(fn(m) {
                match m {
                  Object(mo) => {
                    let mo2 = mo.copy()
                    mo2["time"] = @sffixture.ago("\{k + 1} 分钟前", "10/19 09:12:00")
                    Json::object(mo2)
                  }
                  _ => m
                }
              })
              o2["messages"] = Json::array(ms2)
            }
            _ => ()
          }
          { ..tp, value: Some(Json::object(o2)), version: tp.version + k }
        }
        _ => tp
      }
    })
    t.run_for(@ui.move_most_ms)
    t.assert_idle()
    let (_, y0, _, _) = t.rect_of("推送截图前要先登录 gh。").unwrap()
    for step in 1..=3 {
      tick.set(step)
      t.draw()
      let (_, y_now, _, _) = t.rect_of("推送截图前要先登录 gh。").unwrap()
      assert_true((y_now - y0).abs() <= 0.01, msg="step \{step}: message shifted from \{y0} to \{y_now}")
      t.run_for(@ui.move_most_ms)
      let (_, y_after, _, _) = t.rect_of("推送截图前要先登录 gh。").unwrap()
      assert_true((y_after - y0).abs() <= 0.01, msg="step \{step} after settle: message shifted from \{y0} to \{y_after}")
      t.assert_idle()
    }
  })
}
