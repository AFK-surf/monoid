// The relay's panel (sfpages relay.mbt, open_relay) on each screen: a sheet from the foot on a phone's window (by touch
// and with keyboard and mouse), a dialog in a wide window's middle. What it shows as its places are read, not read, none
// connected, none there; the bots to go on through; a place picked and let go of; a Slack message's link typed; its foot's
// 取消 and 接力 (not ready, busy); where the keyboard's focus is as it opens and as a place is picked and let go of.

///|
/// The three screens the relay opens on: a sheet with a finger, a phone's window with a mouse, a wide one.
let relay_screens : Array[(Int, Bool)] = [(2, false), (0, false), (0, true)]

///|
/// The station's bots (three Slack ones of one workspace and a Feishu one), as `chat.relayPlaces` answers.
fn relay_two_connects() -> Json {
  {
    "connects": [
      { "id": "slack-1", "kind": "slack", "name": "星火助手", "team": "星火", "places": [] },
      { "id": "slack-2", "kind": "slack", "name": "星火二号", "team": "星火", "places": [] },
      { "id": "slack-3", "kind": "slack", "name": "星火三号", "team": "星火", "places": [] },
      { "id": "feishu-1", "kind": "feishu", "name": "飞书助手", "team": "星火", "places": [] },
    ],
  }
}

///|
/// A row the picker offers (relay-pick.ts RelayRow).
fn relay_row(connect : String, kind : String, id : String, name : String, note : String) -> Json {
  {
    "key": kind + ":T/" + id,
    "connect": connect,
    "kind": kind,
    "place": { "id": id, "name": name, "kind": "channel" },
    "name": name,
    "note": note,
    "aside": Json::null(),
  }
}

///|
/// What the core's picker shows for what is asked (relay-pick.ts relayView, made up here): a Slack message's link typed,
/// its thread; "zzz", nothing that matches; "产", the Feishu bot's group; all asked for, three; else the one relayed to
/// before under 最近接力过, 显示全部 3 个 under it, a connect not read. A place picked: who replies there (`via`), the
/// one picked or 星火助手, in it; 星火二号 joins it as it relays, 星火三号 only a person there can invite.
fn relay_made_view(params : Json) -> Json {
  let query = text(Some(params), "query")
  let chosen = match opt_text(Some(params), "bot") {
    Some("slack-2") => "slack-2"
    _ => "slack-1"
  }
  let base = fn(rows : Array[Json], recent : Bool, total : Int, empty : Json, unread : Array[Json], link : Json) -> Json {
    let view : Map[String, Json] = {
      "link": link,
      "bot": "slack-1",
      "bots": [],
      "rows": Json::array(rows),
      "recent": recent,
      "total": Json::number(total.to_double()),
      "empty": empty,
      "unread": Json::array(unread),
    }
    if text(Some(params), "place") != "" {
      view["via"] = {
        "bot": chosen,
        "joins": chosen == "slack-2",
        "bots": [
          { "id": "slack-1", "label": "星火助手", "state": "in" },
          { "id": "slack-2", "label": "星火二号", "state": "join" },
          { "id": "slack-3", "label": "星火三号", "state": "invite", "invite": "/invite @星火三号" },
        ],
      }
    }
    Json::object(view)
  }
  if query.has_prefix("https://") {
    base([], false, 0, Json::null(), [], Json::string(query))
  } else if query == "zzz" {
    base([], false, 0, Json::string("noMatch"), [], Json::null())
  } else if query == "产" {
    base([relay_row("feishu-1", "feishu", "oc1", "产品群", "普通群 · 接管群会话")], false, 1, Json::null(), [], Json::null())
  } else if flag(Some(params), "all") {
    base(
      [
        relay_row("slack-1", "slack", "C1", "#dev", "新 thread"),
        relay_row("slack-1", "slack", "C2", "#ops", "新 thread"),
        relay_row("slack-1", "slack", "C3", "#qa", "新 thread"),
      ],
      false,
      3,
      Json::null(),
      [],
      Json::null(),
    )
  } else {
    base([relay_row("slack-1", "slack", "C1", "#dev", "新 thread")], true, 3, Json::null(), [Json::string("飞书超时")], Json::null())
  }
}

///|
/// A source whose relay calls are answered here and recorded in `calls`: the places as `places` says (None: never
/// answered, the picker reading still), the picker's view by relay_made_view, chat.relay held where `hold` (busy); the
/// rest by fixture `over`'s.
fn relay_src(
  calls : Array[Made],
  places? : Result[Json, Json]? = Some(Ok(relay_two_connects())),
  hold? : Bool = false,
  over? : String = "home",
) -> Source {
  let base = fixture(over)
  {
    ..base,
    call: fn(name, params, done) {
      match name {
        "chat.relayPlaces" => {
          calls.push({ name, params, bytes: None, done })
          match places {
            Some(Ok(v)) => done(Ok(v))
            Some(Err(e)) => done(Err(e))
            None => ()
          }
        }
        "chat.relayView" => {
          calls.push({ name, params, bytes: None, done })
          done(Ok(relay_made_view(params)))
        }
        "chat.relay" => {
          calls.push({ name, params, bytes: None, done })
          if !hold {
            done(Ok({ "place": "#dev" }))
          }
        }
        _ => (base.call)(name, params, done)
      }
    },
  }
}

///|
/// The relay opened over the app on `platform` (390 × 844, made 1200 × 800 where `wide`), come to where it rests.
fn relay_over(src : Source, platform~ : Int, wide~ : Bool) -> @ui.Tester {
  new_run()
  @sf.presenters_reset()
  home_sheet_at_start.val = false
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform~)
  if wide {
    t.resize(1200.0, 800.0)
  }
  t.run_for(@ui.move_most_ms)
  @sfpages.open_relay(src, { station: "s1", session: "x", title: "整理发布清单", station_name: "" }, 1.0, from=Unanchored)
  t.frame()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// The relay's panel (sheet or dialog) as a screen reader finds it, if it is up.
fn relay_dialog(t : @ui.Tester) -> @ui.SemNode? {
  t.semantics().iter().find_first(fn(s) { !s.hidden && s.role == @ui.Role::Dialog })
}

///|
/// 取消 pressed: the relay closed, gone once its way out is over (what it held kept till it opens again: closed by
/// what it holds, the presenters tell it no `gone`).
fn relay_cancelled(t : @ui.Tester, at : String) -> Unit raise {
  relay_press(t, "取消")
  t.run_for(@ui.move_most_ms)
  presented_rested(t)
  assert_true(relay_dialog(t) is None, msg="\{at}: still up after 取消")
  assert_true(t.find("接力到频道") is None, msg=at)
}

///|
/// The button `label` pressed where a screen reader finds it (the foot's, under an input method raised too).
fn relay_press(t : @ui.Tester, label : String) -> Unit raise {
  let b = t.get(Button, label~)
  let (x, y, w, h) = b.rect
  t.tap(x + w / 2.0, y + h / 2.0)
}

///|
/// Whether 接力 (or 接力到 …) is there and can be pressed.
fn relay_go_ready(t : @ui.Tester, label : String) -> Bool {
  t.all(Button, label~, disabled=false).length() > 0
}

///|
test "接力到频道 on each screen: as it opens, the keyboard's focus on its search in a wide window's dialog, on nothing in a phone's window's sheet; a place picked gives it to the note, let go of back to the search, the input method up" {
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let calls : Array[Made] = []
    let t = relay_over(relay_src(calls), platform~, wide~)
    assert_true(relay_dialog(t) is Some(_), msg=at)
    if wide {
      assert_true(t.focus_said().has_prefix("TextField \"搜索频道或群，或粘贴 Slack 消息链接\""), msg="\{at}: \{t.focus_said()}")
      assert_true(t.ime().0, msg=at)
    } else {
      assert_eq(t.focus_said(), "none", msg=at)
      assert_true(!t.ime().0, msg=at)
    }
    t.tap_text("#dev")
    // (the note has the keys, its input method up, in the frame the press is taken in: as the old one did)
    assert_true(t.focus_said().has_prefix("TextField \"例如：@某人 帮看下这个方案\""), msg="\{at}, the press's frame: \{t.focus_said()}")
    assert_true(t.ime().0, msg="\{at}, the press's frame")
    t.run_for(@ui.move_most_ms)
    assert_true(t.focus_said().has_prefix("TextField \"例如：@某人 帮看下这个方案\""), msg="\{at}: \{t.focus_said()}")
    assert_true(t.ime().0, msg=at)
    t.tap_text("#dev")
    t.run_for(@ui.move_most_ms)
    assert_true(t.focus_said().has_prefix("TextField \"搜索频道或群，或粘贴 Slack 消息链接\""), msg="\{at}: \{t.focus_said()}")
    assert_true(t.ime().0, msg=at)
    relay_cancelled(t, at)
  }
}

///|
test "接力到频道 on each screen, its places read: no bots to pick first, 最近接力过 over the one relayed to before, 显示全部 under it, a connect not read; 接力 not ready till a place is picked" {
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let calls : Array[Made] = []
    let t = relay_over(relay_src(calls), platform~, wide~)
    let words = t.words().map(fn(w) { w.0 }).join("|")
    // (the bot is a step after the place: none offered over the search)
    assert_true(t.find("星火助手") is None, msg="\{at}: \{words}")
    assert_true(t.find("飞书助手") is None, msg=at)
    assert_true(t.find("搜索频道或群，或粘贴 Slack 消息链接") is Some(_), msg=at)
    assert_true(t.find("最近接力过") is Some(_), msg=at)
    assert_true(t.find("#dev") is Some(_), msg=at)
    assert_true(t.find("显示全部 3 个") is Some(_), msg=at)
    assert_true(t.find("读取失败：飞书超时") is Some(_), msg=at)
    // in order down the column: the search, 最近接力过, #dev, 显示全部, what was not read
    let y = fn(w : String) { t.rect_of(w).unwrap().1 }
    assert_true(y("搜索频道或群，或粘贴 Slack 消息链接") < y("最近接力过"), msg=at)
    assert_true(y("最近接力过") < y("#dev"), msg=at)
    assert_true(y("#dev") < y("显示全部 3 个"), msg=at)
    assert_true(y("显示全部 3 个") < y("读取失败：飞书超时"), msg=at)
    // nothing picked: 接力 there, not to be pressed; pressed, nothing relayed
    assert_true(t.all(Button, label="接力").length() == 1, msg=at)
    assert_true(!relay_go_ready(t, "接力"), msg=at)
    relay_press(t, "接力")
    t.frame()
    assert_eq(named(calls, "chat.relay").length(), 0, msg=at)
    // 显示全部: all of them asked for and shown, 最近接力过 and it gone
    t.tap_text("显示全部 3 个")
    t.run_for(@ui.move_most_ms)
    assert_true(named(calls, "chat.relayView").iter().any(fn(m) { flag(Some(m.params), "all") }), msg=at)
    assert_true(t.find("#qa") is Some(_), msg=at)
    assert_true(t.find("最近接力过") is None, msg=at)
    assert_true(t.find("显示全部 3 个") is None, msg=at)
    relay_cancelled(t, at)
  }
}

///|
test "接力到频道 on each screen: a place picked, 换一个 shows the bots of its workspace and where each stands; one that joins it picked replies there, relayed through it joining it; a search that finds none says so" {
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let calls : Array[Made] = []
    let t = relay_over(relay_src(calls), platform~, wide~)
    // the search typed into: none matches; cleared, the places back
    t.tap_text("搜索频道或群，或粘贴 Slack 消息链接")
    t.type_text("zzz")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("没有匹配的频道或群") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    relaying.query.set("")
    t.run_for(@ui.move_most_ms)
    t.tap_text("#dev")
    t.run_for(@ui.move_most_ms)
    // asked who replies there: the place's key
    assert_true(named(calls, "chat.relayView").iter().any(fn(m) { text(Some(m.params), "place") == "slack:T/C1" }), msg=at)
    assert_true(t.find("星火助手") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    assert_true(t.find("由哪个机器人回复") is None, msg=at)
    t.tap_text("换一个")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("由哪个机器人回复") is Some(_), msg=at)
    assert_true(t.find("在频道里") is Some(_), msg=at)
    assert_true(t.find("接力时加入") is Some(_), msg=at)
    assert_true(t.find("需要频道里的人邀请") is Some(_), msg=at)
    assert_true(t.find("复制邀请") is Some(_), msg=at)
    // one only a person there can invite: not taken
    t.tap_text("星火三号")
    t.run_for(@ui.move_most_ms)
    assert_eq(relaying.bot.get(), "", msg=at)
    // one that joins it: replies there, the choice closed, said so under the place
    t.tap_text("星火二号")
    t.run_for(@ui.move_most_ms)
    assert_eq(relaying.bot.get(), "slack-2", msg=at)
    assert_true(t.find("由哪个机器人回复") is None, msg=at)
    assert_true(t.find(" · 接力时加入") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    assert_eq(t.audit(), [], msg=at)
    relay_press(t, "接力到 #dev")
    t.run_for(@ui.move_most_ms)
    let relayed = named(calls, "chat.relay")
    assert_eq(relayed.length(), 1, msg=at)
    assert_eq(text(Some(relayed[0].params), "connect"), "slack-2", msg=at)
    assert_eq(text(Some(relayed[0].params), "channel"), "C1", msg=at)
    assert_true(flag(Some(relayed[0].params), "join"), msg=at)
    presented_rested(t)
    assert_true(relay_dialog(t) is None, msg="\{at}: still up once relayed")
  }
}

///|
test "接力到频道 on each screen: a place picked in place of the search, 更换 on it, who replies there under it, the note; pressed again, the search and the places back" {
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let calls : Array[Made] = []
    let t = relay_over(relay_src(calls), platform~, wide~)
    t.tap_text("#dev")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("新 thread · 更换") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    assert_true(t.find("那里由") is Some(_), msg=at)
    assert_true(t.find("开头附一句（可选）") is Some(_), msg=at)
    assert_true(t.find("例如：@某人 帮看下这个方案") is Some(_), msg=at)
    assert_true(t.find("搜索频道或群，或粘贴 Slack 消息链接") is None, msg=at)
    assert_true(t.find("最近接力过") is None, msg=at)
    relay_via_at_right(t)
    // under the place: who replies there, then the note
    let y = fn(w : String) { t.rect_of(w).unwrap().1 }
    assert_true(y("#dev") < y("那里由"), msg=at)
    assert_true(y("那里由") < y("开头附一句（可选）"), msg=at)
    assert_true(y("开头附一句（可选）") < y("例如：@某人 帮看下这个方案"), msg=at)
    assert_true(relay_go_ready(t, "接力到 #dev"), msg=at)
    // pressed again: let go of
    t.tap_text("#dev")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("接力到 #dev") is None, msg=at)
    assert_true(t.find("开头附一句（可选）") is None, msg=at)
    assert_true(t.find("搜索频道或群，或粘贴 Slack 消息链接") is Some(_), msg=at)
    assert_true(t.find("最近接力过") is Some(_), msg=at)
    relay_cancelled(t, at)
  }
}

///|
test "接力到频道 on each screen: a Slack message's link typed offers its thread, the note under it, 接力 relays it there with the note" {
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let calls : Array[Made] = []
    let t = relay_over(relay_src(calls), platform~, wide~)
    let link = "https://x.slack.com/archives/C1/p1"
    t.tap_text("搜索频道或群，或粘贴 Slack 消息链接")
    t.type_text(link)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("接力到这个 Slack thread") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    assert_true(t.find("已有 thread · agent 先读之前的消息") is Some(_), msg=at)
    assert_true(t.find("开头附一句（可选）") is Some(_), msg=at)
    assert_true(relay_go_ready(t, "接力"), msg=at)
    t.tap_text("例如：@某人 帮看下这个方案")
    t.type_text("看下")
    t.frame()
    // (how tall it stands as it is relayed: its title to its foot)
    let y = fn(w : String) { t.rect_of(w).unwrap().1 }
    let tall = y("取消") - y("接力到频道")
    relay_press(t, "接力")
    t.frame()
    // relayed: on its way out, all it showed kept as it was, the thread and the note, a sheet as tall, till it is gone
    let mut frames = 0
    while t.find("接力到频道") is Some(_) && frames < 120 {
      assert_true(t.find("接力到这个 Slack thread") is Some(_), msg="\{at}: the thread gone on its way out")
      assert_true(t.find("开头附一句（可选）") is Some(_), msg="\{at}: the note gone on its way out")
      if !wide {
        // (as tall within 0.01: each place drawn is its own sum on the sheet's way, parting in its last bit)
        let now = y("取消") - y("接力到频道")
        assert_true((now - tall).abs() < 0.01, msg="\{at}: its height on its way out, \{frames} frames on: \{now}, \{tall} as it was")
      }
      t.frame()
      frames += 1
    }
    assert_true(frames > 1, msg="\{at}: gone at once")
    let relayed = named(calls, "chat.relay")
    assert_eq(relayed.length(), 1, msg=at)
    assert_eq(text(Some(relayed[0].params), "link"), link, msg=at)
    assert_eq(text(Some(relayed[0].params), "connect"), "slack-1", msg=at)
    assert_eq(text(Some(relayed[0].params), "note"), "看下", msg=at)
    t.run_for(@ui.move_most_ms)
    presented_rested(t)
    assert_true(relay_dialog(t) is None, msg="\{at}: still up once relayed")
    assert_true(t.find("已接力到 #dev") is Some(_), msg=at)
  }
}

///|
test "接力到频道 on each screen: 接力 pressed while the station relays it, busy, relayed once however often it is pressed; 取消 closes it" {
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let calls : Array[Made] = []
    let t = relay_over(relay_src(calls, hold=true), platform~, wide~)
    t.tap_text("#dev")
    t.run_for(@ui.move_most_ms)
    relay_press(t, "接力到 #dev")
    t.frame()
    assert_true(relaying.busy.get(), msg=at)
    relay_press(t, "接力到 #dev")
    t.frame()
    assert_eq(named(calls, "chat.relay").length(), 1, msg=at)
    t.run_for(@ui.move_most_ms)
    assert_true(relay_dialog(t) is Some(_), msg="\{at}: gone while it relays")
    assert_true(t.find("接力到 #dev") is Some(_), msg=at)
    // 取消 while it relays: closed, what it was relaying left to go on (not let go of)
    relay_press(t, "取消")
    t.run_for(@ui.move_most_ms)
    presented_rested(t)
    assert_true(relay_dialog(t) is None, msg=at)
    assert_true(relaying.busy.get(), msg="\{at}: let go of while it relays")
    @sfbase.relay_reset()
  }
}

///|
test "接力到频道 on each screen: its places being read, not read, none connected, none joined, each said in their place" {
  let none_joined : Json = { "connects": [{ "id": "slack-1", "kind": "slack", "name": "星火助手", "team": "星火", "places": [] }] }
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    // being read
    let t = relay_over(relay_src([], places=None), platform~, wide~)
    assert_true(t.find("正在读取频道…") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    assert_true(!relay_go_ready(t, "接力"), msg=at)
    relay_cancelled(t, at)
    // not read
    let t = relay_over(relay_src([], places=Some(Err({ "code": "offline", "message": "站点不在线" }))), platform~, wide~)
    assert_true(t.find("站点不在线") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    assert_true(t.find("正在读取频道…") is None, msg=at)
    relay_cancelled(t, at)
    // none connected
    let t = relay_over(relay_src([], places=Some(Ok({ "connects": [] }))), platform~, wide~)
    assert_true(t.find("这个站点还没有连上 Slack、飞书或 Group") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    relay_cancelled(t, at)
    // the bot in none: the core says so (the kept answer for the fixture's one bot lists two; this one, none)
    let calls : Array[Made] = []
    let base = relay_src(calls, places=Some(Ok(none_joined)))
    let src : Source = {
      ..base,
      call: fn(name, params, done) {
        if name == "chat.relayView" {
          done(
            Ok({
              "link": Json::null(),
              "bot": "slack-1",
              "bots": [],
              "rows": [],
              "recent": false,
              "total": 0,
              "empty": "noPlaces",
              "unread": [],
            }),
          )
        } else {
          (base.call)(name, params, done)
        }
      },
    }
    let t = relay_over(src, platform~, wide~)
    assert_true(t.find("机器人还没加入任何频道或群") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    relay_cancelled(t, at)
  }
}

///|
/// `src` with the people of where the note goes answered (two: pengxiao, Peng Xiao; peter), and whom the note can
/// mention as the core answers (relay_mentions_kept).
fn relay_with_people(src : Source) -> Source {
  let people : Json = [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao" }, { "id": "U2", "name": "peter" }]
  {
    ..src,
    call: fn(name, params, done) {
      match name {
        "chat.relayPeople" => done(Ok({ "people": people }))
        "chat.relayMentions" => done(Ok(relay_mentions_kept(text(Some(params), "note"))))
        _ => (src.call)(name, params, done)
      }
    },
  }
}

///|
test "接力到频道 on each screen: an @ typed in the note offers the people there under it; one pressed is put in for it, the panel staying" {
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let t = relay_over(relay_with_people(relay_src([])), platform~, wide~)
    t.tap_text("#dev")
    t.run_for(@ui.move_most_ms)
    t.type_text("看下 @p")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("可以 @ 的人") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    assert_true(t.find("pengxiao") is Some(_), msg=at)
    assert_true(t.find("Peng Xiao") is Some(_), msg=at)
    assert_true(t.find("peter") is Some(_), msg=at)
    // beside the note, on the side with room for it (over it on a phone's window, the input method up there; under it
    // in a dialog), not over it: its head, then each in the order offered
    let y = fn(w : String) { t.rect_of(w).unwrap().1 }
    assert_true(y("peter") < y("开头附一句（可选）") || y("开头附一句（可选）") < y("可以 @ 的人"), msg=at)
    assert_true(y("可以 @ 的人") < y("pengxiao"), msg=at)
    assert_true(y("pengxiao") < y("peter"), msg=at)
    let (px, py, pw, ph) = t.rect_of("peter").unwrap()
    t.tap(px + pw / 2.0, py + ph / 2.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(relaying.note.text(), "看下 @peter ", msg=at)
    assert_true(t.find("可以 @ 的人") is None, msg=at)
    assert_true(relay_dialog(t) is Some(_), msg="\{at}: the panel went with the menu")
    relay_cancelled(t, at)
  }
}

///|
test "接力到频道: what it shows asked of the core once for each thing asked, again only as what is typed, the place picked, the bot or all changes" {
  let calls : Array[Made] = []
  let t = relay_over(relay_src(calls), platform=0, wide=true)
  assert_eq(named(calls, "chat.relayView").length(), 1)
  // a place picked: asked who replies there, once; let go of: asked as at first, once
  t.tap_text("#dev")
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.relayView").length(), 2)
  // another bot: asked again, once
  t.tap_text("换一个")
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.relayView").length(), 2)
  t.tap_text("星火二号")
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.relayView").length(), 3)
  t.tap_text("#dev")
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.relayView").length(), 4)
  // typed into: asked again, once
  t.type_text("zzz")
  t.run_for(@ui.move_most_ms)
  let asked = named(calls, "chat.relayView")
  assert_eq(asked.length(), 5)
  assert_eq(text(Some(asked[4].params), "query"), "zzz")
  relay_cancelled(t, "wide")
}

///|
test "接力到频道: what the core answers for it after it closed falls on nothing, not on the next time it opens" {
  let calls : Array[Made] = []
  let base = relay_src(calls)
  // (its views held: answered here when the test says)
  let held : Array[(Json) -> Unit] = []
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "chat.relayView" {
        held.push(fn(v) { done(Ok(v)) })
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  let t = relay_over(src, platform=0, wide=true)
  assert_eq(held.length(), 1)
  assert_true(t.find("正在读取频道…") is Some(_))
  relay_cancelled(t, "the first")
  @sfpages.open_relay(src, { station: "s1", session: "x", title: "整理发布清单", station_name: "" }, 1.0, from=Unanchored)
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_eq(held.length(), 2)
  // the first opening's answer, late: nothing shown of it
  held[0]({ "link": Json::null(), "bot": "slack-1", "bots": [], "rows": [], "recent": false, "total": 0, "empty": "noMatch", "unread": [] })
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("没有匹配的频道或群") is None, msg=t.words().map(fn(w) { w.0 }).join("|"))
  assert_true(t.find("正在读取频道…") is Some(_))
  // this one's: shown
  held[1](relay_made_view({ "query": "" }))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("#dev") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  relay_cancelled(t, "the second")
}

///|
test "接力到频道: relayed and gone, opened again as it was at first: nothing typed, nothing picked, no note, its places offered" {
  let src = relay_src([])
  let t = relay_over(src, platform=0, wide=true)
  t.tap_text("#dev")
  t.run_for(@ui.move_most_ms)
  t.type_text("看下")
  t.frame()
  relay_press(t, "接力到 #dev")
  t.frame()
  t.run_for(@ui.move_most_ms)
  presented_rested(t)
  assert_true(relay_dialog(t) is None, msg="still up once relayed")
  @sfpages.open_relay(src, { station: "s1", session: "x", title: "整理发布清单", station_name: "" }, 1.0, from=Unanchored)
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_eq((relaying.query.text(), relaying.note.text(), relaying.picked.get() is None, relaying.busy.get()), ("", "", true, false))
  assert_true(t.find("#dev") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  assert_true(t.find("开头附一句（可选）") is None)
  // (its foot's 接力 for nothing picked: not to be pressed)
  assert_eq(t.all(Button, label="接力到 #dev").length(), 0)
  assert_true(t.all(Button, label="接力").length() == 1 && !relay_go_ready(t, "接力"))
  relay_cancelled(t, "again")
}

///|
test "接力到频道 on each screen, opened from a chat whose message field has the keyboard's focus: Escape closes it, the focus back in that field" {
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    new_run()
    @sf.presenters_reset()
    let src = relay_src([], over="chat")
    open_chat(chat_a)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform~)
    if wide {
      t.resize(1200.0, 800.0)
    }
    t.run_for(@ui.move_most_ms)
    t.act(TextField, Focus, label="发消息")
    t.draw()
    assert_eq(t.focused().map(fn(s) { s.label }), Some("发消息"), msg=at)
    @sfpages.open_relay(src, chat_a, 1.0, from=Unanchored)
    t.frame()
    t.run_for(@ui.move_most_ms)
    presented_rested(t)
    assert_true(relay_dialog(t) is Some(_), msg=at)
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    presented_rested(t)
    assert_true(relay_dialog(t) is None, msg="\{at}: still up after Escape")
    assert_eq(t.focused().map(fn(s) { s.label }), Some("发消息"), msg=at)
  }
}

///|
test "接力到频道 on each screen: a place picked and let go of (更换): what was typed in the search and the places as they were, the keys back in the search" {
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let t = relay_over(relay_src([]), platform~, wide~)
    t.tap_text("搜索频道或群，或粘贴 Slack 消息链接")
    t.type_text("产")
    t.run_for(@ui.move_most_ms)
    t.tap_text("产品群")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("接力到 产品群") is Some(_), msg="\{at}: \{t.words().map(fn(w) { w.0 }).join("|")}")
    t.tap_text("产品群")
    t.run_for(@ui.move_most_ms)
    assert_eq(relaying.query.text(), "产", msg=at)
    assert_true(t.find("产品群") is Some(_), msg=at)
    assert_true(t.focus_said().has_prefix("TextField \"搜索频道或群，或粘贴 Slack 消息链接\""), msg="\{at}: \{t.focus_said()}")
    assert_true(t.ime().0, msg=at)
    relay_cancelled(t, at)
  }
}

///|
test "接力到频道 with more places than its list shows: what goes on past its foot is faded out into the room over 取消 and 接力, never cut sharp mid-row" {
  for screen in relay_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let calls : Array[Made] = []
    let base = relay_src(calls)
    let rows = []
    for i in 0..<20 {
      rows.push(relay_row("slack-1", "slack", "C\{i}", "#chan\{i}", "新 thread"))
    }
    let src = {
      ..base,
      call: fn(name, params, done) {
        if name == "chat.relayView" {
          done(
            Ok({
              "link": Json::null(),
              "bot": "slack-1",
              "bots": [],
              "rows": Json::array(rows),
              "recent": false,
              "total": 20.0,
              "empty": Json::null(),
              "unread": [],
            }),
          )
        } else {
          (base.call)(name, params, done)
        }
      },
    }
    let t = relay_over(src, platform~, wide~)
    // (each place's words faded towards one foot, as far as the list goes on past it: a fade's height, ending where
    // the foot's buttons' room ends, over them)
    let (_, dy, _, dh) = relay_dialog(t).unwrap().rect
    let mut foot = -1.0
    for f in t.drawn_fades() {
      if f.6 > 0.0 && f.1 >= dy && f.1 < dy + dh {
        assert_true(foot < 0.0 || foot == f.5, msg="\{at}: two feet \{foot} \{f.5}")
        foot = f.5
        assert_eq(f.6, 24.0, msg=at)
      }
    }
    assert_true(foot > 0.0, msg="\{at}: nothing faded out towards its foot")
    let (_, by, _, _) = t.get(Button, label="取消").rect
    assert_true(foot <= by + 0.5, msg="\{at}: faded out at \{foot}, past 取消's top \{by}")
    assert_true(foot >= by - 24.5, msg="\{at}: faded out at \{foot}, a fade's height and more over 取消's top \{by}")
  }
}
