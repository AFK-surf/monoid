// 安全 and 开启安全模式 (security.mbt) alone, at each width, with a finger and with a mouse: its people and their
// devices, its stations; turning it off asked first; what turning it on would sign, and back. A new device is approved
// only by the code typed on it (lock_wait_node.mbt): nothing here approves one with a press.

///|
test "安全码: a wrong code keeps the keyboard for another try; approval puts it away" {
  let approved = Ref(false)
  let answers : Array[(Result[Json, Json]) -> Unit] = []
  let t = setting_tester(Security, 390.0, platform=2, mode="lock-upgrade", over=fn(base) {
    {
      ..base,
      call: fn(name, params, done) {
        if name == "lock.pairCode" {
          answers.push(done)
        } else {
          (base.call)(name, params, done)
        }
      },
      topic_read: fn(name, params) {
        // (`approved` is the test's own: told by fixture_changed, which this read follows)
        @settings.fixture_followed()
        let topic = base.topic(name, params).get().snapshot()
        if name == "lock" && approved.val {
          {
            ..topic,
            value: Some({
              "available": Json::boolean(true),
              "locked": Json::boolean(true),
              "signs": Json::boolean(true),
              "me": { "waiting": Json::boolean(false), "unsigned": Json::boolean(false) },
            }),
            version: topic.version + 1,
          }
        } else {
          topic
        }
      },
    }
  })
  assert_true(t.ime().0)
  assert_eq(t.ime_action(), @hostapi.ime_action_number)
  t.type_text("123456")
  assert_eq(answers.length(), 1)
  answers[0](Err(Json::string("wrong")))
  t.frame()
  assert_true(t.ime().0)
  assert_eq(t.ime().1, "")
  t.type_text("654321")
  assert_eq(answers.length(), 2)
  // The core can publish approval before the call's answer arrives.
  approved.val = true
  @settings.fixture_changed()
  t.frame()
  assert_false(t.ime().0)
  answers[1](Ok(Json::object({})))
}

///|
test "安全, at each width and with either hand: the viewer's own devices, the other members, the stations" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Security, w, platform~)
    let at = "\{w} platform \{platform}"
    // (我的设备: a row each, this one marked 此设备 after its name, not said again under it)
    assert_true(drawn_whole(t, "我的设备"), msg=at)
    assert_true(drawn_whole(t, "此设备"), msg=at)
    assert_true(drawn_whole(t, "still.fail Android · 受信任"), msg=at)
    // (this one first, then the most lately used, whatever app each is: no app's name over them, no person's)
    scrolled_to(t, w, "客户端")
    let order = ["林的 MacBook Pro", "Chrome · macOS", "示例工作站", "客户端"].map(fn(n) {
      t.find(n).map(fn(p) { p.1 }).unwrap_or(-1.0)
    })
    for i in 1..<order.length() {
      assert_true(order[i - 1] >= 0.0 && order[i - 1] < order[i], msg="\{at}: \{Repr(order)}")
    }
    assert_false(drawn_whole(t, "still.fail 桌面版"), msg=at)
    assert_false(drawn_whole(t, "其他"), msg=at)
    assert_false(drawn_whole(t, "林"), msg=at)
    // (其他成员: their devices counted, their role at the end; their devices only in their panel)
    scrolled_to(t, w, "1 台受信任设备")
    assert_true(drawn_whole(t, "其他成员"), msg=at)
    assert_true(drawn_whole(t, "Ana"), msg=at)
    assert_true(drawn_whole(t, "管理员"), msg=at)
    assert_true(t.find("Ana 的 MacBook Air") is None, msg=at)
    scrolled_to(t, w, "受保护")
    assert_true(t.find("受保护") is Some(_), msg=at)
    assert_true(t.find("成员和设备") is None, msg=at)
  }
}

///|
/// The inks the glyphs of `words` are drawn in (each glyph's top left within their box), as drawn last.
fn inks_of(t : @ui.Tester, words : String) -> Array[Int64] {
  match t.rect_of(words) {
    Some((x, y, w, h)) =>
      t.drawn_glyphs().filter(fn(g) { g.0 >= x - 2.0 && g.0 <= x + w + 2.0 && g.1 >= y - 2.0 && g.1 <= y + h + 2.0 }).map(fn(g) { g.2 })
    None => []
  }
}

///|
test "安全, at each width and with either hand: a web page's days left alone in amber, at its row's end" {
  for (w, platform) in page_cases {
    let t = setting_tester(Security, w, platform~)
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "Chrome · macOS")
    let warn = @sf.theme().p.warn_ink >> 8
    let left = inks_of(t, "剩余 4 天")
    assert_true(left.length() > 0 && left.iter().all(fn(c) { c >> 8 == warn }), msg="\{at}: \{Repr(left)}")
    let rest = inks_of(t, "still.fail 网页版 · 2 天前使用过")
    assert_true(rest.length() > 0 && !rest.iter().any(fn(c) { c >> 8 == warn }), msg="\{at}: \{Repr(rest)}")
    // (on its row's line, after its name)
    let (lx, ly, _, _) = t.rect_of("剩余 4 天").unwrap()
    let (nx, ny, nw, nh) = t.rect_of("Chrome · macOS").unwrap()
    assert_true(lx > nx + nw && ly < ny + nh, msg=at)
  }
}

///|
test "安全, at each width and with either hand: a device of one's own opens 续期 and 移除 beside it, 移除 in red; this one and someone else's open nothing" {
  for (w, platform) in page_cases {
    let t = setting_tester(Security, w, platform~)
    let at = "\{w} platform \{platform}"
    // (this device: nothing to do about it from here)
    tap_words(t, "Pixel 9")
    t.run_for(@ui.move_most_ms)
    assert_false(@sf.presenting(), msg=at)
    scrolled_to(t, w, "Chrome · macOS")
    tap_words(t, "Chrome · macOS")
    t.run_for(@ui.move_most_ms)
    assert_true(@sf.presenting(), msg=at)
    assert_true(drawn_whole(t, "续期"), msg=at)
    assert_true(drawn_whole(t, "移除"), msg=at)
    let renew = inks_of(t, "续期")
    let remove = inks_of(t, "移除")
    // (its glyphs red; under a sheet the page's own words there stay drawn under it)
    assert_true(remove.filter(fn(c) { c >> 8 == @sf.theme().p.red >> 8 }).length() >= 2, msg="\{at}: \{Repr(remove)}")
    assert_true(renew.length() > 0 && !renew.iter().any(fn(c) { c >> 8 == @sf.theme().p.red >> 8 }), msg="\{at}: \{Repr(renew)}")
    @sf.close_presented()
    t.run_for(@ui.move_most_ms)
  }
}

///|
test "安全, at each width and with either hand: another member opens their devices in a panel, nothing to take out there" {
  for (w, platform) in page_cases {
    let t = setting_tester(Security, w, platform~)
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "1 台受信任设备")
    tap_words(t, "Ana")
    t.run_for(@ui.move_most_ms)
    assert_true(@sf.presenting(), msg=at)
    assert_true(drawn_whole(t, "Ana 的 MacBook Air"), msg=at)
    assert_true(drawn_whole(t, "still.fail 桌面版 · 5 天前使用过 · 受信任"), msg=at)
    assert_true(drawn_whole(t, "ana@example.com · 管理员"), msg=at)
    assert_false(drawn_whole(t, "移除"), msg=at)
    assert_false(drawn_whole(t, "续期"), msg=at)
    @sf.close_presented()
    t.run_for(@ui.move_most_ms)
  }
}

///|
test "安全, at each width and with either hand: a station's own mark before its name" {
  for (w, platform) in page_cases {
    let t = setting_tester(Security, w, platform~)
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "Maple")
    // (what is drawn small before a station's name on its line: Willow's mark more than Maple's, which has none)
    let before = fn(name : String) {
      let (nx, ny, _, nh) = t.rect_of(name).unwrap()
      t.drawn_instances().filter(fn(i) { i[2] < 32.0 && i[3] < 32.0 && i[0] + i[2] <= nx && i[1] < ny + nh && i[1] + i[3] > ny }).length()
    }
    assert_true(before("Willow") > before("Maple"), msg="\{at}: \{before("Willow")} \{before("Maple")}")
  }
}

///|
test "安全, at each width and with either hand: no row of a lock of one's own, the workspace's safe mode alone" {
  // (to people there is one safe mode, the user, 2026-11-10: its row was at the page's top, on every app but the web)
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Security, w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("安全模式已开启") is Some(_), msg=at)
    let named = t.words().filter(fn(x) { x.0.contains("个人锁") || x.0.contains("以你的名义批准") })
    assert_eq(named.length(), 0, msg="\{at}: \{Repr(named)}")
  }
}

///|
test "protecting a station keeps its button and label, with the spinner inside and no repeated press" {
  for (w, platform) in page_cases {
    let at = "\{w} platform \{platform}"
    let idle = setting_tester(Security, w, platform~)
    scrolled_to(idle, w, "Maple")
    assert_false(idle.get(Button, label="保护").disabled, msg=at)
    tap_words(idle, "保护")
    idle.frame()
    assert_true(@sf.presenting(), msg=at)
    assert_true(idle.find("保护 Maple？") is Some(_), msg=at)
    @sf.close_presented()

    let busy = setting_tester(Security, w, platform~, mode="settings-security-protecting")
    scrolled_to(busy, w, "Maple")
    busy.run_for(@ui.move_most_ms)
    let button = busy.get(Button, label="保护")
    assert_true(button.disabled, msg=at)
    assert_true(busy.find("保护") is Some(_), msg=at)
    let (x, y, width, height) = button.rect
    assert_true(busy.drawn_rects().iter().any(fn(r) {
      r.4 == @sf.theme().p.hover && r.0 <= x && r.1 <= y && r.0 + r.2 >= x + width && r.1 + r.3 >= y + height
    }), msg="button ground: \{at}")
    assert_true(busy.drawn_instances().iter().any(fn(i) {
      i[5] == 10.0 && i[0] >= x && i[1] >= y && i[0] + i[2] <= x + width && i[1] + i[3] <= y + height
    }), msg="spinner inside the button: \{at}")
    busy.tap(x + width / 2.0, y + height / 2.0)
    busy.frame()
    assert_false(@sf.presenting(), msg=at)
  }
}

///|
test "a station's protect button follows its request through failure, retry and success" {
  for (w, platform) in page_cases {
    let running = Ref(false)
    let joined = Ref(false)
    let requests : Array[Json] = []
    let answers : Array[(Result[Json, Json]) -> Unit] = []
    let t = setting_tester(Security, w, platform~, over=fn(base) {
      {
        ..base,
        call: fn(name, params, done) {
          if name == "lock.joinStation" {
            requests.push(params)
            running.val = true
            answers.push(done)
            @settings.fixture_changed()
          } else {
            (base.call)(name, params, done)
          }
        },
        topic_read: fn(name, params) {
          // (`running` and `joined` are the test's own: told by fixture_changed, which this read follows)
          @settings.fixture_followed()
          let read = base.topic(name, params).get().snapshot()
          if name == "doing" && running.val {
            { ..read, value: Some({ "doing": [{ "call": "lock.joinStation", "stage": "running", "params": { "workspace": "ws1", "station": "st2" } }] }) }
          } else if name == "lock" && joined.val {
            match read.value {
              Some(Object(lock)) => {
                let changed = lock.copy()
                changed["stations"] = Json::array(items(read.value, "stations").map(fn(st) {
                  match st {
                    Object(fields) if text(Some(st), "id") == "st2" => {
                      let fields = fields.copy()
                      fields["protected"] = Json::boolean(true)
                      Json::object(fields)
                    }
                    _ => st
                  }
                }))
                { ..read, value: Some(Json::object(changed)) }
              }
              _ => read
            }
          } else {
            read
          }
        },
      }
    })
    scrolled_to(t, w, "Maple")
    tap_words(t, "保护")
    t.frame()
    let (x, y, width, height) = t.get(Button, label="保护").rect
    t.tap(x + width / 2.0, y + height / 2.0)
    t.frame()
    assert_eq(answers.length(), 1)
    assert_eq(requests[0], { "workspace": "ws1", "station": "st2" })
    assert_true(t.get(Button, label="保护").disabled)
    running.val = false
    @settings.fixture_changed()
    answers[0](Err({ "message": "offline" }))
    t.frame()
    assert_false(t.get(Button, label="保护").disabled)
    // The first confirmation is still drawn as it closes; retry at a declared later moment.
    t.run_for(@ui.move_most_ms)
    tap_words(t, "保护")
    t.frame()
    assert_true(@sf.presenting())
    let (x, y, width, height) = t.get(Button, label="保护").rect
    t.tap(x + width / 2.0, y + height / 2.0)
    t.frame()
    assert_eq(answers.length(), 2)
    joined.val = true
    running.val = false
    @settings.fixture_changed()
    answers[1](Ok({}))
    t.frame()
    assert_true(t.query(Button, label="保护") is None)
    assert_eq(t.words().filter(fn(word) { word.0 == "受保护" && word.5 > 0.5 }).length(), 2)
  }
}

///|
/// The menu of the viewer's own device `name` opened by its row (its name pressed), then 移除 in it pressed.
fn removed_from_menu(t : @ui.Tester, w : Double, name : String) -> Unit raise {
  scrolled_to(t, w, name)
  tap_words(t, name)
  t.run_for(@ui.move_most_ms)
  tap_words(t, "移除")
  t.run_for(@ui.move_most_ms)
}

///|
test "安全, at each width and with either hand: another device of one's own taken out, asked first; not this one, nor someone else's" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Security, w, platform~)
    let at = "\{w} platform \{platform}"
    removed_from_menu(t, w, "林的 MacBook Pro")
    assert_true(@sf.presenting(), msg=at)
    assert_true(t.find("移除「林的 MacBook Pro · still.fail 桌面版」？") is Some(_), msg=at)
    assert_true(t.find("该设备将无法再访问受保护的 station，重新批准后才能使用") is Some(_), msg=at)
    @sf.close_presented()
    t.frame()
    // (no 移除 on the page itself: what is done about a device is in its menu; someone else's is theirs alone to take
    // out, so their panel has none either, though the viewer owns the workspace; the user, 2026-11-10)
    let t = setting_tester(Security, w, platform~)
    scrolled_to(t, w, "1 台受信任设备")
    assert_false(drawn_whole(t, "移除"), msg=at)
  }
}

///|
test "安全, at each width and with either hand: 关闭安全模式 asks first, the workspace's name typed" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Security, w, platform~)
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "关闭安全模式")
    tap_words(t, "关闭安全模式")
    t.frame()
    assert_true(@sf.presenting(), msg=at)
    assert_true(t.find("关闭安全模式？") is Some(_), msg=at)
  }
}

///|
test "开启安全模式, at each width and with either hand: its people, the devices and stations it would sign; 取消 goes back" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(SecurityOpen, w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("Ana · MacBook") is Some(_), msg=at)
    assert_true(t.find("林 · 此设备") is Some(_), msg=at)
    scrolled_to(t, w, "批准并开启")
    assert_true(t.find("Willow") is Some(_), msg=at)
    assert_true(t.find("批准并开启") is Some(_), msg=at)
    tap_words(t, "取消")
    t.draw()
    assert_false(app.nav.pages().contains(Setting(SecurityOpen)), msg=at)
  }
}

///|
/// What the fixture's `settings-security-pending` has pending (its sentences, as the core makes them).
let pending_waiting : String = "移除设备 林的 MacBook Pro（2024 款 · 公司配的那台 · 放在办公室）：已记下，等 Willow、Maple 上线后生效"

///|
let pending_failed : String = "把 Ana 改为成员：没有生效。「Ana」在这之后又被改过，请查看现在的状态，仍然需要的话再操作一次"

///|
let pending_why : String = "这台设备已不在安全模式中"

///|
/// What `t.audit()` says of the pending section: its faults that name its words (the page's others, a device's 续期 under
/// 44 on a tablet, are the sweeps' bars').
fn pending_faults(t : @ui.Tester) -> Array[String] {
  let marks = ["移除设备 林的", "把 Ana 改为", "续期 Chrome", pending_why, "知道了", "以下改动"]
  t.audit().filter(fn(f) { marks.iter().any(fn(m) { f.contains(m) }) })
}

///|
test "安全, at each width and with either hand: nothing pending, no section of it" {
  for (w, platform) in page_cases {
    let t = setting_tester(Security, w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("安全模式已开启") is Some(_), msg=at)
    assert_true(t.find("以下改动还没有生效") is None, msg=at)
    assert_true(t.find("知道了") is None, msg=at)
  }
}

///|
test "安全, at each width and with either hand: what is pending under the state, each sentence whole, a failed one's 知道了" {
  for (w, platform) in page_cases {
    let t = setting_tester(Security, w, platform~, mode="settings-security-pending")
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    let (_, state) = t.find("安全模式已开启").unwrap()
    let (_, head) = t.find("以下改动还没有生效").unwrap()
    let (_, waiting) = t.find(pending_waiting).unwrap()
    let (_, failed) = t.find(pending_failed).unwrap()
    assert_true(t.find("续期 Chrome · macOS：没有生效。请查看现在的状态，仍然需要的话再操作一次") is Some(_), msg=at)
    assert_true(t.find(pending_why) is Some(_), msg=at)
    // (first after the state, before 成员; oldest first)
    assert_true(state < head && head < waiting && waiting < failed, msg=at)
    scrolled_to(t, w, "Pixel 9")
    let (_, failed) = t.find(pending_failed).unwrap()
    let (_, people) = t.find("Pixel 9").unwrap()
    assert_true(failed < people, msg=at)
    // (whole: no word of it cut, nothing over another)
    let faults = pending_faults(t)
    assert_eq(faults.length(), 0, msg="\{at}: \{Repr(faults)}")
    // (two failed ones' buttons; the waiting one has none)
    let drawn = t.words().filter(fn(x) { x.0 == "知道了" && x.5 > 0.5 })
    assert_eq(drawn.length(), 2, msg=at)
  }
}

///|
test "安全, at each width and with either hand: 知道了 drops its failed change by its id, the others where they were" {
  for (w, platform) in page_cases {
    let asked : Array[(String, Json)] = []
    let t = setting_tester(Security, w, platform~, mode="settings-security-pending", over=fn(base) {
      {
        ..base,
        call: fn(name, params, done) {
          asked.push((name, params))
          (base.call)(name, params, done)
        },
      }
    })
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    let (_, waiting) = t.find(pending_waiting).unwrap()
    let (_, why) = t.find(pending_why).unwrap()
    // (the first 知道了, the failed change's that is not the last)
    let shown = t.words().filter(fn(x) { x.0 == "知道了" && x.5 > 0.5 })
    guard shown.length() == 2 else { fail("\{at}: \{shown.length()} 知道了 drawn") }
    let first = if shown[0].2 < shown[1].2 { shown[0] } else { shown[1] }
    t.tap(first.1 + first.3 / 2.0, first.2 + first.4 / 2.0)
    t.frame()
    let dropped = asked.filter(fn(c) { c.0 == "lock.pendingDismiss" })
    assert_eq(dropped.length(), 1, msg=at)
    assert_eq(dropped[0].1, { "workspace": "ws1", "id": "p2" }, msg=at)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find(pending_failed) is None, msg=at)
    // (the one above it where it was; the heading stays while some are left)
    assert_eq(t.find(pending_waiting).unwrap().1, waiting, msg=at)
    assert_true(t.find(pending_why).unwrap().1 < why, msg=at)
    assert_true(t.find("以下改动还没有生效") is Some(_), msg=at)
    let faults = pending_faults(t)
    assert_eq(faults.length(), 0, msg="\{at}: \{Repr(faults)}")
  }
}

///|
test "安全, at each width and with either hand: a change gone as the core says so goes, the section with the last" {
  for (w, platform) in page_cases {
    let t = setting_tester(Security, w, platform~, mode="settings-security-pending")
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    let (_, failed) = t.find(pending_failed).unwrap()
    // (a station took the waiting one: the core drops it)
    @settings.fixture_pending_set(["p2", "p3"])
    t.run_for(@ui.move_most_ms)
    assert_true(t.find(pending_waiting) is None, msg=at)
    assert_true(t.find(pending_failed).unwrap().1 < failed, msg=at)
    @settings.fixture_pending_set([])
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("以下改动还没有生效") is None, msg=at)
    assert_true(t.find(pending_failed) is None, msg=at)
    assert_true(t.find("安全模式已开启") is Some(_), msg=at)
    let faults = pending_faults(t)
    assert_eq(faults.length(), 0, msg="\{at}: \{Repr(faults)}")
  }
}

///|
/// The fixture's pending changes by id, each by words of its sentence.
let pending_words : Array[(String, String)] = [
  ("p1", "移除设备 林的"),
  ("p2", "把 Ana 改为"),
  ("p3", "续期 Chrome"),
]

///|
/// The corners of the piece of the section's card change `id` is drawn on (the smallest ground drawn round its
/// sentence: top left, then round it), and whether they are what its place among `ids` makes them: the first rounded
/// at the top, the last at the foot, one alone both, none between.
fn pending_corners_wrong(t : @ui.Tester, ids : Array[String], at : String) -> Array[String] {
  let wrong = []
  let rects = t.drawn_rect_corners().filter(fn(r) { (r.4 & 0xFFL) > 0L })
  for j, id in ids {
    guard pending_words.search_by(p => p.0 == id) is Some(k) else { continue }
    guard t.rect_of(pending_words[k].1) is Some((x, y, w, h)) else {
      wrong.push("\{at} \{id}: not drawn")
      continue
    }
    let round = rects.filter(fn(r) { r.0 <= x && r.1 <= y && r.0 + r.2 >= x + w && r.1 + r.3 >= y + h })
    guard round.length() > 0 else {
      wrong.push("\{at} \{id}: no ground round it")
      continue
    }
    let mut piece = round[0]
    for r in round {
      if r.2 * r.3 < piece.2 * piece.3 {
        piece = r
      }
    }
    let (tl, tr, br, bl) = piece.5
    let top = j == 0
    let foot = j == ids.length() - 1
    let ok = (tl > 0.0) == top && (tr > 0.0) == top && (br > 0.0) == foot && (bl > 0.0) == foot
    if !ok {
      wrong.push("\{at} \{id} (\{j + 1} of \{ids.length()}): corners \{tl}, \{tr}, \{br}, \{bl}")
    }
  }
  wrong
}

///|
test "安全, at each width and with either hand: a change taken from the middle or the top leaves the card's corners right" {
  for (w, platform) in page_cases {
    for gone in [["p1", "p3"], ["p2", "p3"]] {
      let t = setting_tester(Security, w, platform~, mode="settings-security-pending")
      t.run_for(@ui.move_most_ms)
      let at = "\{w} platform \{platform}"
      let before = pending_corners_wrong(t, ["p1", "p2", "p3"], at)
      assert_eq(before, [], msg=at)
      @settings.fixture_pending_set(gone)
      t.run_for(@ui.move_most_ms)
      let after = pending_corners_wrong(t, gone, "\{at}, left \{Repr(gone)}")
      assert_eq(after, [], msg=at)
    }
  }
}

///|
test "安全, at each width and with either hand: a removal answered pending says its sentence, not 已移除" {
  for (w, platform) in page_cases {
    let said = "移除设备 林的 MacBook Pro：已记下，等 Maple 上线后生效"
    let t = setting_tester(Security, w, platform~, over=fn(base) {
      {
        ..base,
        call: fn(name, params, done) {
          if name == "lock.removeDevice" {
            done(Ok({ "pending": { "id": "p9", "text": said, "state": "waiting", "stations": ["Maple"] } }))
          } else {
            (base.call)(name, params, done)
          }
        },
      }
    })
    let at = "\{w} platform \{platform}"
    removed_from_menu(t, w, "林的 MacBook Pro")
    assert_true(@sf.presenting(), msg=at)
    t.run_for(@ui.move_most_ms)
    // (the dialog's own 移除: its button, the last made)
    let buttons = t.all(Button, label="移除")
    guard buttons.length() > 0 else { fail("\{at}: no 移除 button in the dialog") }
    let (x, by, bw, bh) = buttons[buttons.length() - 1].rect
    t.tap(x + bw / 2.0, by + bh / 2.0)
    t.frame()
    assert_eq(@sfbase.toast_words(), said, msg=at)
  }
}

///|
test "people added, answered with a change of the lock no station took yet: its sentence in the done words' place" {
  let said = "添加成员 new@example.com：已记下，等 Maple 上线后生效"
  let made : Ref[Source?] = Ref(None)
  let t = setting_tester(Workspace, 390.0, platform=2, over=fn(base) {
    let src : Source = {
      ..base,
      call: fn(name, params, done) {
        if name == "workspace.addMembers" {
          done(Ok({ "joined": [], "added": [Json::string("new@example.com")], "already": [], "pending": { "id": "p9", "text": said, "state": "waiting", "stations": ["Maple"] } }))
        } else {
          (base.call)(name, params, done)
        }
      },
    }
    made.val = Some(src)
    src
  })
  let core = @sfbase.settings_core(made.val.unwrap(), rig_workspace)
  let here = @settings.here_of(core, rig_workspace.id, rig_workspace.name)
  @settings.open_add_people(core, here, Some({ "role": "owner", "members": [], "added": [] }))
  t.run_for(@ui.move_most_ms)
  let (x, y) = t.find("name@example.com，可粘贴多个").unwrap()
  t.tap(x + 4.0, y + 4.0)
  t.frame()
  t.type_text("new@example.com")
  t.frame()
  t.click(Button, label="添加")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(said) is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  // (not the done words: 「1 人首次登录 still.fail 时自动加入。」)
  assert_true(t.find("1 人首次登录") is None, msg=t.words().map(fn(w) { w.0 }).join("|"))
}

///|
/// The upgrade of safe mode as the fixture's `settings-security-upgrade-…` say it (the core's sentences).
let upgrade_title : String = "安全模式有一项升级尚未完成"

///|
let upgrade_maple : String = "等待 station Maple：请将它更新到最新版本并保持在线；已不再使用的话，请在它的页面上选择「从 workspace 移除」"

///|
let upgrade_ana : String = "等待 Ana：请其在自己的受信任设备上将 still.fail 更新到最新版本并打开一次"

///|
let upgrade_device : String = "等待 Ana 的设备「Pixel 8 · still.fail Android」：请其在另一台受信任设备上打开「设置 › 安全」并完成一次验证；该设备已不再使用的话，请其将它移除"

///|
let upgrade_mini : String = "等待「个人」的 station 家里的 mini：请将它更新到最新版本并保持在线；已不再使用的话，请在它的页面上选择「从 workspace 移除」"

///|
/// Each state of the upgrade the fixture has: its mode's end, the first line it shows, and how many 更新 are drawn.
let upgrade_states : Array[(String, String, Int)] = [
  ("station", upgrade_maple, 1),
  ("station-not", upgrade_maple, 0),
  ("member", upgrade_ana, 0),
  ("device", upgrade_device, 0),
  ("many", upgrade_maple, 1),
  ("other", upgrade_mini, 1),
  ("updating", upgrade_maple, 0),
]

///|
/// What `t.audit()` says of the upgrade's section: its faults that name its words.
fn upgrade_faults(t : @ui.Tester) -> Array[String] {
  let marks = ["安全模式有一项升级", "等待", "以及另外"]
  t.audit().filter(fn(f) { marks.iter().any(fn(m) { f.contains(m) }) })
}

///|
/// The 更新 drawn whole and shown.
fn updates_drawn(t : @ui.Tester) -> Array[(String, Double, Double, Double, Double, Double)] {
  t.words().filter(fn(x) { x.0 == "更新" && x.5 > 0.5 }).map(fn(x) { (x.0, x.1, x.2, x.3, x.4, x.5) })
}

///|
test "安全, at each width and with either hand: no upgrade waited for, no section of it" {
  for (w, platform) in page_cases {
    let t = setting_tester(Security, w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("安全模式已开启") is Some(_), msg=at)
    assert_true(t.find(upgrade_title) is None, msg=at)
  }
}

///|
test "安全, at each width and with either hand: the upgrade's title and what it waits for under the state, above its people, each sentence whole, 更新 beside a station this person may update" {
  for state in upgrade_states {
    let (mode, first, updates) = state
    for (w, platform) in page_cases {
      let t = setting_tester(Security, w, platform~, mode="settings-security-upgrade-" + mode)
      t.run_for(@ui.move_most_ms)
      let at = "\{mode} \{w} platform \{platform}"
      guard t.find("安全模式已开启") is Some((_, state_y)) else { fail("\{at}: no state") }
      guard t.find(upgrade_title) is Some((_, title_y)) else { fail("\{at}: no title") }
      guard t.find(first) is Some((_, first_y)) else { fail("\{at}: no \{first}") }
      // (first after the state, before its people)
      assert_true(state_y < title_y && title_y < first_y, msg=at)
      assert_eq(updates_drawn(t).length(), updates, msg=at)
      if mode == "many" {
        scrolled_to(t, w, "以及另外 3 项")
        assert_true(t.find("等待 周宁 的设备「周宁的 MacBook Air · still.fail 桌面版」：请其在另一台受信任设备上打开「设置 › 安全」并完成一次验证；该设备已不再使用的话，请其将它移除") is Some(_), msg=at)
      }
      let last = if mode == "many" { "以及另外 3 项" } else { first }
      scrolled_to(t, w, "Pixel 9")
      let (_, last_y) = t.find(last).unwrap()
      let (_, people_y) = t.find("Pixel 9").unwrap()
      assert_true(last_y < people_y, msg=at)
      let faults = upgrade_faults(t)
      assert_eq(faults.length(), 0, msg="\{at}: \{Repr(faults)}")
    }
  }
}

///|
test "安全, at each width and with either hand: 更新 sends software.update for that station once, and nothing while it is asked" {
  for case in [("station", "ws1/st2"), ("other", "ws2/st9")] {
    let (mode, station) = case
    for (w, platform) in page_cases {
      let asked : Array[Json] = []
      let answers : Array[(Result[Json, Json]) -> Unit] = []
      let t = setting_tester(Security, w, platform~, mode="settings-security-upgrade-" + mode, over=fn(base) {
        {
          ..base,
          call: fn(name, params, done) {
            if name == "software.update" {
              asked.push(params)
              answers.push(done)
            } else {
              (base.call)(name, params, done)
            }
          },
        }
      })
      t.run_for(@ui.move_most_ms)
      let at = "\{mode} \{w} platform \{platform}"
      let shown = updates_drawn(t)
      guard shown.length() == 1 else { fail("\{at}: \{shown.length()} 更新 drawn") }
      let (_, x, y, bw, bh, _) = shown[0]
      t.tap(x + bw / 2.0, y + bh / 2.0)
      t.frame()
      assert_eq(asked.length(), 1, msg=at)
      assert_eq(asked[0], { "station": Json::string(station), "id": "station" }, msg=at)
      // (pressed again where it was while asked: nothing more sent, a ring in its place)
      t.tap(x + bw / 2.0, y + bh / 2.0)
      t.frame()
      t.run_for(@ui.move_most_ms)
      assert_eq(asked.length(), 1, msg=at)
      assert_eq(updates_drawn(t).length(), 0, msg=at)
      // (answered: 更新 again, as the core says it may be)
      answers[0](Ok(Json::object({})))
      t.run_for(@ui.move_most_ms)
      assert_eq(updates_drawn(t).length(), 1, msg=at)
    }
  }
}

///|
/// What an upgraded workspace's safe mode says to an owner who cannot turn it off or on again (the fixture's `rootText`).
let root_said : String = "安全模式由 Ana 开启"

///|
/// The words of the page that start with `start` (a sentence's first line), drawn and shown.
fn lock_said_from(t : @ui.Tester, start : String) -> Bool {
  t.words().iter().any(fn(x) { x.0.has_prefix(start) && x.5 > 0.5 })
}

///|
/// Whether `words` are drawn whole and shown (not as part of longer words: 开启安全模式 in 重新开启安全模式).
fn drawn_whole(t : @ui.Tester, words : String) -> Bool {
  t.words().iter().any(fn(x) { x.0 == words && x.5 > 0.5 })
}

///|
/// The page in `mode`, safe mode's calls of this device held: each asked of the made-up core as it would be (at work),
/// answered only as the test says (`answer`).
fn lock_held_tester(mode : String, w : Double, platform : Int, asked : Array[(String, Json)], answers : Array[(Result[Json, Json]) -> Unit]) -> @ui.Tester {
  setting_tester(Security, w, platform~, mode~, over=fn(base) {
    {
      ..base,
      call: fn(name, params, done) {
        if name == "lock.confirmSigner" || name == "lock.open" || name == "lock.pair" {
          asked.push((name, params))
          @settings.fixture_lock_doing(name, params) |> ignore
          answers.push(done)
        } else {
          (base.call)(name, params, done)
        }
      },
    }
  })
}

///|
test "安全, at each width and with either hand: let in by its person's own lock without its signer, 验证 asks lock.confirmSigner once, a ring on it meanwhile, then trusted; no approval asked" {
  for (w, platform) in page_cases {
    let asked : Array[(String, Json)] = []
    let answers : Array[(Result[Json, Json]) -> Unit] = []
    let t = lock_held_tester("settings-security-confirm", w, platform, asked, answers)
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    assert_true(lock_said_from(t, "此设备需完成一次验证"), msg=at)
    // (no approval asked: none would let it in, the core refusing it as waiting in no workspace)
    assert_true(t.find("发送批准请求") is None, msg=at)
    let faults = t.audit()
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
    scrolled_to(t, w, "验证")
    tap_words(t, "验证")
    t.frame()
    // (pressed again while asked: nothing more sent)
    tap_words(t, "验证")
    t.run_for(@ui.move_most_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(asked[0].0, "lock.confirmSigner", msg=at)
    assert_eq(asked[0].1, { "workspace": "ws1" }, msg=at)
    @settings.fixture_lock_done()
    answers[0](Ok(Json::null()))
    t.run_for(@ui.move_most_ms)
    assert_false(lock_said_from(t, "此设备需完成一次验证"), msg=at)
    assert_true(t.find("安全模式已开启") is Some(_), msg=at)
  }
}

///|
test "安全, at each width and with either hand: an upgraded workspace on by another owner alone: who and the way out, no 关闭安全模式" {
  for (w, platform) in page_cases {
    let t = setting_tester(Security, w, platform~, mode="settings-security-root")
    let at = "\{w} platform \{platform}"
    assert_true(t.find("安全模式已开启") is Some(_), msg=at)
    scrolled_to(t, w, root_said)
    t.run_for(@ui.move_most_ms)
    assert_true(lock_said_from(t, root_said), msg=at)
    assert_false(drawn_whole(t, "关闭安全模式"), msg=at)
  }
}

///|
test "安全, at each width and with either hand: an upgraded workspace off by another owner alone: who and the way out, no 开启安全模式" {
  for (w, platform) in page_cases {
    let t = setting_tester(Security, w, platform~, mode="settings-security-root-off")
    let at = "\{w} platform \{platform}"
    t.run_for(@ui.move_most_ms)
    assert_true(lock_said_from(t, root_said), msg=at)
    assert_false(drawn_whole(t, "开启安全模式"), msg=at)
    assert_false(drawn_whole(t, "重新开启安全模式"), msg=at)
    let faults = t.audit()
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
  }
}

///|
test "安全, at each width and with either hand: off by this person, 重新开启安全模式 asks lock.open once with no page of its own, a ring on it meanwhile, then on" {
  for (w, platform) in page_cases {
    let asked : Array[(String, Json)] = []
    let answers : Array[(Result[Json, Json]) -> Unit] = []
    let t = lock_held_tester("settings-security-again", w, platform, asked, answers)
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    assert_false(drawn_whole(t, "开启安全模式"), msg=at)
    let faults = t.audit()
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
    tap_words(t, "重新开启安全模式")
    t.frame()
    tap_words(t, "重新开启安全模式")
    t.run_for(@ui.move_most_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(asked[0].0, "lock.open", msg=at)
    assert_eq(asked[0].1, { "workspace": "ws1" }, msg=at)
    assert_false(app.nav.pages().contains(Setting(SecurityOpen)), msg=at)
    @settings.fixture_lock_done()
    answers[0](Ok(Json::null()))
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("安全模式已开启") is Some(_), msg=at)
    assert_false(drawn_whole(t, "重新开启安全模式"), msg=at)
  }
}

///|
test "安全, at each width and with either hand: none of its person's devices answering, 我的其它设备都不在了 asks lock.restartOwn once, then whom to ask and nothing to press; their lock begun anew elsewhere, 是我做的，继续 asks lock.forgetOwn once, then the ask to join" {
  for (w, platform) in page_cases {
    for case in [("lock-restart", "我的其它设备都不在了", "lock.restartOwn", "先将你移出再重新添加；"), ("lock-replaced", "是我做的，继续", "lock.forgetOwn", "发送批准请求")] {
      let (mode, label, call, after) = case
      let asked : Array[String] = []
      let t = setting_tester(Security, w, platform~, mode~, over=fn(base) {
        {
          ..base,
          call: fn(name, params, done) {
            if name == call {
              asked.push(name)
            }
            (base.call)(name, params, done)
          },
        }
      })
      t.run_for(@ui.move_most_ms)
      let at = "\{mode} \{w} platform \{platform}"
      assert_true(drawn_whole(t, label), msg=at)
      let faults = t.audit()
      assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
      scrolled_to(t, w, label)
      t.click(Button, label~)
      t.run_for(@ui.move_most_ms)
      assert_eq(asked, [call], msg=at)
      assert_false(drawn_whole(t, label), msg=at)
      let shown = t.words().filter(fn(x) { x.5 > 0.5 }).map(fn(x) { x.0 }).join("")
      assert_true(shown.contains(after), msg="\{at}: \{shown}")
    }
  }
}
