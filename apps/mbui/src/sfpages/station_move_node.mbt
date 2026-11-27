// Moving a station's things to another station of its workspace, module by module (the core's `stationMove` topic,
// client/core-ts/src/move.ts, of the station's move/: each module on its own, its needs first, progress inside it,
// everything undoable: the owner, 2026-11-14). Rarely used and risky, so no row of the station's page offers it: its ⋯
// has 迁移到另一台 station while it is online and offers moving, which opens this page, a step further in from it; its station's
// page shows one row of it only while something of it is moved, moving, stopped or failed (station_move_section).
// No sentence explains it (the owner, 2026-11-14: 「字太多了，应该用更结构化更所见即所得的方式设计 UI」). Its first card
// the station it goes to, chosen in one row (a chevron after its name while there is one to choose) and remembered for
// this station on this device, and at its end the page's main action, 全部迁移 (the main case is retiring a station:
// 左子健, 2026-11-13), 移出 workspace once all of it is there; what moves now, with 停止; the modules that have items one
// card, a row each (its name, done of total, its one action and a chevron on its first line, what it needs in a line
// under it), one opened (by a press, or by itself where something of it moves, failed or stopped) showing its items in
// the same card under its row, where each stands and its own action at its end (迁移, 迁回, 重试), why under it, a page
// more as the list is scrolled to its end; 全部迁回 in its ⋯. While a turn runs 停止 is the only action: the station
// answers any other a 409, so the core offers none. Everything said is the core's or the app's words by a module's id;
// a press is a call to the core, a refusal said on the row it was pressed on.

///|
/// Station `address`'s 迁移 (its ⋯'s 迁移到另一台 station) made once in node `v`, as wide as `width` gives it.
pub fn station_move_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  address : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let s = fn() { station_of(core, here(), address) }
  // (where the station says it takes no moves (its overview's `move.offered`: a stable one from before moving graduated),
  // as a link opened of one, the page goes back to where it was opened from, never one of a turn that would be refused)
  v.reacts(fn() { (core.move_on)() && (s() is None || @settings.move_said(s())) }, fn(on) {
    if !on {
      on_back()
    }
  })
  let title = fn() {
    match text(s(), "name") {
      "" => @sf.t("web-pages.stations.move.title")
      name => @sf.t("web-pages.stations.move.title") + " · " + name
    }
  }
  // (the station it goes to, as chosen on this device; what moves of it to there, its modules closed)
  let to = fn() { @settings.move_target(core, address) }
  let base = fn() { @settings.move_of(core, address, to(), "") }
  let view = fn() { base().value }
  let targets = fn() { items(view(), "targets") }
  let chosen = fn() {
    let t = to()
    t != "" && targets().iter().any(fn(x) { text(Some(x), "station") == t && move_target_can(x) })
  }
  let modules = fn() { items(view(), "modules") }
  // (the module open: the one pressed open, else the first that opens by itself; "" none)
  let pressed : @signals.Signal[String?] = @signals.signal(None, same=fn(a, b) { a == b })
  let open = fn() {
    match pressed.get() {
      Some(m) => m
      None =>
        match modules().iter().find_first(fn(m) { flag(Some(m), "opens") }) {
          Some(m) => text(Some(m), "id")
          None => ""
        }
    }
  }
  // (how many of the open module's items: a page more as its list is scrolled to its end)
  let limit : @signals.Signal[Int] = @signals.signal(@settings.move_page, same=fn(a, b) { a == b })
  let rows = fn() {
    match open() {
      "" => None
      m => move_module_of(@settings.move_of(core, address, to(), m, limit=limit.get()).value, m)
    }
  }
  let shown_items = fn(m : String) {
    match rows() {
      Some(r) if open() == m => items(Some(r), "items")
      _ => []
    }
  }
  let module_of = fn(id : String) -> Json? {
    let ms = modules()
    for i = 0; i < ms.length(); i = i + 1 {
      if text(Some(ms[i]), "id") == id {
        return Some(ms[i])
      }
    }
    None
  }
  let item_of = fn(m : String, id : String) -> Json? {
    let xs = shown_items(m)
    for i = 0; i < xs.length(); i = i + 1 {
      if text(Some(xs[i]), "id") == id {
        return Some(xs[i])
      }
    }
    None
  }
  let toggle = fn(id : String) {
    let now = @signals.untracked(open)
    limit.set(@settings.move_page)
    pressed.set(Some(if now == id { "" } else { id }))
  }
  let blocks = fn() {
    if !flag(s(), "online") {
      return ["offline"]
    }
    match view() {
      None => return ["wait"]
      _ => ()
    }
    let out = ["to"]
    if !chosen() {
      return out
    }
    if field(view(), "moving") is Some(Object(_)) {
      out.push("now")
    }
    // (every module empty: its card's one line)
    if modules().is_empty() {
      if text(view(), "nothing") != "" {
        out.push("nothing")
      }
      return out
    }
    for m in modules() {
      let id = text(Some(m), "id")
      out.push("m/" + id)
      if open() == id {
        for x in shown_items(id) {
          out.push("i/" + id + "/" + text(Some(x), "id"))
        }
      }
    }
    // (the modules' one card's foot a piece of its own: what opens under a module opens between, its ends as they were)
    out.push("foot")
    out
  }
  // (a call pressed: answered at once, what it does shown as the topic tells it; refused, said on the row pressed)
  let call = fn(name : String, params : Array[(String, Json)]) {
    let all : Array[(String, Json)] = [("station", str(address))]
    (core.call)(name, obj(all + params), fn(r) { if r is Err(_) { @ui.haptic(Reject) } })
  }
  let calls = ["move.start", "move.back"]
  let module_on = fn(id : String) { [("station", address), ("module", id), ("item", "")] }
  let item_on = fn(m : String, id : String) { [("station", address), ("module", m), ("item", id)] }
  let module_act = fn(id : String, action : String) {
    if action == "back" {
      call("move.back", [("from", str(@signals.untracked(to))), ("module", str(id))])
    } else {
      call("move.start", [("to", str(@signals.untracked(to))), ("module", str(id)), ("all", Json::boolean(true))])
    }
  }
  // (迁移 and 重试 alike: that item moved, what it needs first)
  let item_act = fn(m : String, id : String, action : String) {
    if action == "back" {
      call("move.back", [("from", str(@signals.untracked(to))), ("module", str(m)), ("item", str(id))])
    } else {
      call("move.start", [("to", str(@signals.untracked(to))), ("module", str(m)), ("item", str(id)), ("withNeeds", Json::boolean(true))])
    }
  }
  // its ⋯: 全部迁移 and 全部迁回, each asked once, naming the station and how many
  let actions = fn(a : @view.View) {
    a.show(fn() { chosen() && field(view(), "allBack") is Some(Object(_)) }, fn(m) {
      @sf.icon_action_opens_node(m, "more", fn() { @sf.t("common.more") }, fn(at) {
        let v = @signals.untracked(view)
        @sf.menu(station_move_menu(v, fn(back) { station_move_all_confirm(core, address, v, back) }), from=Node(at), along=End)
      })
      |> ignore
    })
  }
  @sf.page_node(
    v,
    title,
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    actions~,
    near_foot=(
      400.0,
      fn() { rows().map(fn(r) { flag(Some(r), "more") }).unwrap_or(false) && limit.get() < @settings.move_shown_most },
      fn() {
        let now = limit.untracked()
        limit.set(@cmp.minimum(now + @settings.move_page, @settings.move_shown_most))
      },
    ),
    blocks,
    fn(b, key) {
      match key {
        "offline" => @sf.page_note_node(b, fn() { @sf.t("web-pages.automaticDecisions.offline") })
        "wait" =>
          @sf.waiting_node(b, fn(w) { station_move_sample(w) }, error=fn() {
            match base().error {
              Some(e) => error_text(e)
              None => ""
            }
          })
        "to" =>
          station_move_to_node(b, core, address, to, targets, fn() { if chosen() { view() } else { None } }, fn() {
            match @signals.untracked(s) {
              Some(_) as st => station_remove_ask(core, @signals.untracked(here), st)
              None => ()
            }
          })
        "now" =>
          station_move_now_node(b, fn() { field(view(), "moving") }, fn() {
            call("move.stop", [])
          }, fn() { is_doing(core, ["move.stop"], [("station", address)]) })
        _ if key.has_prefix("m/") => {
          let id = key.unsafe_substring(start=2, end=key.length())
          let first = @signals.untracked(fn() { text(modules().get(0), "id") }) == id
          @sf.card_piece_node(b, fn() { if first { @sf.CardTop } else { @sf.CardBetween } }, wide_list=true, fn(card) {
            station_move_module_node(card, id, fn() { module_of(id) }, fn() { open() == id }, fn() { toggle(id) }, fn(action) {
              module_act(id, action)
            }, fn() { is_doing(core, calls, module_on(id)) }, fn() { failed_of(core, calls, module_on(id)) })
          })
        }
        "foot" => @sf.card_piece_node(b, fn() { @sf.CardFoot }, wide_list=true, fn(_) {  })
        "nothing" =>
          @sf.group_node(b, fn(g) { @sf.link_row_node(g, fn() { text(view(), "nothing") }, fn() {  }, goes=false) })
        _ if key.has_prefix("i/") => {
          let rest = key.unsafe_substring(start=2, end=key.length())
          let cut = rest.find("/").unwrap_or(0)
          let m = rest.unsafe_substring(start=0, end=cut)
          let id = rest.unsafe_substring(start=cut + 1, end=rest.length())
          @sf.card_piece_node(b, fn() { @sf.CardBetween }, wide_list=true, fn(card) {
            // (under its module's row, in from it)
            card.box(fn(i) {
              i.padding(Is((@sf.text_in, 0.0, 0.0, 0.0))) |> ignore
              station_move_item_node(i, fn() { item_of(m, id) }, fn(action) { item_act(m, id, action) }, fn() {
                is_doing(core, calls, item_on(m, id))
              }, fn() { failed_of(core, calls, item_on(m, id)) })
            })
            |> ignore
          })
        }
        _ => ()
      }
    },
  )
}

///|
/// The module `id` of what was read (`v`: a stationMove value), as the open module's items come in it.
fn move_module_of(v : Json?, id : String) -> Json? {
  let ms = items(v, "modules")
  for i = 0; i < ms.length(); i = i + 1 {
    if text(Some(ms[i]), "id") == id {
      return Some(ms[i])
    }
  }
  None
}

///|
/// Whether the things may go to `x`, a station the core lists (none: its `why` says what stands in the way).
fn move_target_can(x : Json) -> Bool {
  text(Some(x), "why") == ""
}

///|
/// Where its things go (in `b`): one row, the station chosen among the others of the workspace (each its name and its
/// room; one it may not go to faint, why and what makes it one under it; a chevron after the name chosen), or that
/// there is no other; at its end the page's main action once one is
/// chosen (`v`, what the core says of it then): 全部迁移, asked once; with all of it there, 移出 workspace (`remove`, the
/// station's own); none while a turn runs, nor the chevron or the choice.
fn station_move_to_node(
  b : @view.View,
  core : Core,
  address : String,
  to : () -> String,
  targets : () -> Array[Json],
  v : () -> Json?,
  remove : () -> Unit,
) -> Unit {
  let name = fn() {
    let t = to()
    let ts = targets()
    for i = 0; i < ts.length(); i = i + 1 {
      let x = ts[i]
      if text(Some(x), "station") == t && move_target_can(x) {
        return text(Some(x), "name")
      }
    }
    @sf.t("web-pages.stations.move.choose")
  }
  // (what the action at its end is now: none, 全部迁移, 移出 workspace)
  let main = fn() {
    if flag(v(), "allThere") {
      "remove"
    } else if field(v(), "allMove") is Some(Object(_)) {
      "all"
    } else {
      ""
    }
  }
  @sf.group_node(b, fn(g) {
    // (made again only as there comes to be an action at its end or none: which it is, the action alone)
    g.pick(fn() { main() != "" }, fn(r, acts) {
      @sf.link_row_opens_node(
        r,
        fn() { @sf.t("web-pages.stations.move.to") },
        fn(at) {
          // (none to choose while a turn runs: its chevron absent, a press nothing)
          guard !(field(@signals.untracked(v), "moving") is Some(Object(_))) else { return }
          let marks = @signals.untracked(fn() {
            let (topic, params) = @sfbase.station_rows_ask(@sfbase.workspace_of(address))
            @sfbase.stations_of((core.topic)(topic, params).get().value)
          })
          let all = @signals.untracked(targets).map(fn(x) {
            let id = text(Some(x), "station")
            // (a station's id here, its address its workspace's and that: topics.ts #moveShown)
            let there = @sfbase.workspace_of(address) + "/" + id
            let (emoji, icon) = @sfbase.station_mark_in(marks, there)
            @sfbase.station_choice(
              id,
              text(Some(x), "name"),
              emoji,
              icon,
              address=there,
              note=text(Some(x), "why"),
              value=text(Some(x), "free"),
              disabled=!move_target_can(x),
            )
          })
          guard !all.is_empty() else { return }
          @sf.pick("", all, @signals.untracked(to), fn(id) { @settings.move_target_set(core, address, id) }, from=Node(at), along=End)
        },
        value=fn() { if targets().is_empty() { @sf.t("web-pages.stations.move.none") } else { name() } },
        // (a chevron after its name while there is a station to choose, before the action at its end)
        chevron=false,
        tail=fn(e) { station_move_chevron(e, fn() { "chevron-right" }) },
        tail_shown=fn() { !targets().is_empty() && !(field(v(), "moving") is Some(Object(_))) },
        control?=if acts {
          Some(fn(c : @view.View) {
            c.pick(main, fn(a, what) {
              if what == "remove" {
                @sf.button_node(a, fn() { @sf.t("web-pages.stations.retire.remove") }, remove, tone=Primary) |> ignore
              } else {
                @sf.button_node(a, fn() { @sf.t("web-pages.stations.move.all") }, fn() {
                  station_move_all_confirm(core, address, @signals.untracked(v), false)
                }, tone=Primary)
                |> ignore
              }
            })
          })
        } else {
          None
        },
      )
    })
  })
}

///|
/// What moves now (in `b`): its module, its item and how far, in a line with a spinner before it (its bar is its item's,
/// in its module's list: one line here, 停止 across its middle in its card's corner as a row's own); 停止 at its end
/// (`stop`), 正在停止… and not to be pressed once asked (the core's `stopping`) or while the call goes (`asking`).
fn station_move_now_node(b : @view.View, moving : () -> Json?, stop : () -> Unit, asking : () -> Bool) -> Unit {
  let stopping = fn() { flag(moving(), "stopping") || asking() }
  @sf.group_node(b, fn(g) {
    @sf.link_row_node(
      g,
      fn() { text(moving(), "line") },
      fn() {  },
      goes=false,
      lead=LeadLine(fn(l) { @sf.spinner_node(l, size=st_row_glyph) |> ignore }),
      control=fn(c) {
        @sf.row_end_button_node(
          c,
          fn() { @sf.t(if flag(moving(), "stopping") { "web-pages.stations.move.stopping" } else { "web-pages.stations.move.stop" }) },
          stop,
          disabled=stopping,
        )
        |> ignore
      },
    )
  })
}

///|
/// A thin bar of how far (`part`: 0 to 1, None not known), as wide as the row's words.
fn station_move_bar(r : @view.View, part : () -> Double?) -> Unit {
  r.box(fn(bar) {
    bar.grow(Is(1.0)) |> ignore
    @sf.progress_node(bar, part, fn() { @ui.tree_theme().line }, fn() { @sf.theme().p.accent }, h=2.0) |> ignore
  })
  |> ignore
}

///|
/// A module's row (in `card`, a piece of the modules' card), module `id`: its name, the modules it needs in a line of
/// words under it (依赖 账号、连接…; none where it needs none), done of total at its first line's end with its one action
/// (迁移, 迁回; none while a turn runs) and after it a chevron, down, up while its items are open, all of it as high as
/// that line's words (line_end_node), so the row is as tall with its action or without it, a refusal coming under it or
/// not; pressed, its items open or shut (`toggle`); a refusal of its action in place of what it needs while the core
/// keeps it, in amber.
fn station_move_module_node(
  card : @view.View,
  id : String,
  m : () -> Json?,
  is_open : () -> Bool,
  toggle : () -> Unit,
  act : (String) -> Unit,
  doing : () -> Bool,
  failed : () -> String?,
) -> Unit {
  let needs = fn() {
    match strings(m(), "needs") {
      [] => ""
      all =>
        @sf.t("web-pages.stations.move.needs", args=[
          ("names", all.map(fn(n) { @sf.t("web-pages.stations.move.need." + n) }).join(@sf.t("web-main.list.separator"))),
        ])
    }
  }
  let act_now = fn() { text(m(), "action") }
  // (made again only as a refusal comes or goes, its note's ink with it: its action at its end comes and goes in it)
  card.pick(fn() { failed() is Some(_) }, fn(r, refused) {
    @sf.link_row_node(
      r,
      fn() { @sf.t("web-pages.stations.move.module." + id) },
      toggle,
      value=fn() { text(m(), "count") },
      note=fn() { failed().unwrap_or(needs()) },
      lacks=refused,
      folds=is_open,
      control=fn(e) {
        @sf.line_end_node(e, fn(c) {
          c.show(fn() { act_now() != "" }, fn(a) {
            @sf.row_end_button_node(
              a,
              fn() { @sf.t(if act_now() == "back" { "web-pages.stations.move.back" } else { "web-pages.stations.move.move" }) },
              fn() { act(@signals.untracked(act_now)) },
              busy=doing,
              disabled=doing,
            )
            |> ignore
          })
          station_move_chevron(c, fn() { if is_open() { "chevron-up" } else { "chevron-down" } })
        })
      },
    )
  })
}

///|
/// A row's chevron (`mark`: its icon's name now), made in `e` at its first line's end as a row's own is.
fn station_move_chevron(e : @view.View, mark : () -> String) -> Unit {
  e.box(fn(c) {
    c.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
    @sf.icon_node(c, mark(), @sf.pg_chevron, By(fn() { @sf.theme().p.subtle }), name_now=mark) |> ignore
  })
  |> ignore
}

///|
/// An item's row (in `card`, a piece of its module's card): its label on its first line, where it stands at that line's
/// end (迁移中 with how far and a bar under its line; 已迁移; 已停 · 等「…」; 失败, 无法迁移 with why under it; nothing
/// where it is here), on a line of its own under the label where both have not the room, never the label cut short; and
/// after it its own action (迁移 here, 迁回 there, 重试 failed; none moving, stopped, where it cannot move or while a turn
/// runs), on its first line as high as that line's words (the row's own line_end, its lines being under it), so the
/// row is as tall with it or without it; a refusal of it under
/// it, in amber.
fn station_move_item_node(
  card : @view.View,
  x : () -> Json?,
  act : (String) -> Unit,
  doing : () -> Bool,
  failed : () -> String?,
) -> Unit {
  let state = fn() { text(x(), "state") }
  let value = fn() {
    match text(field(x(), "progress"), "text") {
      "" => text(x(), "stateText")
      p => text(x(), "stateText") + " · " + p
    }
  }
  let note = fn() {
    match failed() {
      Some(why) => why
      None => text(x(), "note")
    }
  }
  let part = fn() {
    let p = field(x(), "progress")
    let total = number(p, "total")
    if total > 0.0 { Some(number(p, "done") / total) } else { None }
  }
  let action = fn() { text(x(), "action") }
  // (made again only as there comes to be an action at its end or none: which it is, and its bar as it moves or not,
  // follow it in the row)
  card.pick(fn() { action() != "" }, fn(r, acts) {
    let bad = fn() { state() == "failed" }
    let words = fn() {
      match action() {
        "back" => "web-pages.stations.move.back"
        "retry" => "common.retry"
        _ => "web-pages.stations.move.move"
      }
    }
    @sf.link_row_node(
      r,
      fn() { text(x(), "label") },
      fn() {  },
      value~,
      value_bad=bad,
      // (where it stands, a stopped one's with the whole name of what it waits for, onto a line more under its label
      // where even a line of its own has not the room: 「Stopped · waiting for "Slack · 星火"」 at words 1.3 in English)
      value_wraps=true,
      note~,
      lacks=true,
      goes=false,
      // (something under its first line always, its bar while it moves, nothing else: so where it stands goes under its
      // label where the line has not the room for both, as a row with lines under it lays them, never the label cut)
      below=fn(b) { station_move_bar(b, part) },
      below_open=fn() { if state() == "moving" { 1.0 } else { 0.0 } },
      control?=if !acts {
        None
      } else {
        // (the button alone: with lines always under its first (`below`), the row puts it on that line, as high as it,
        // itself: link_row's `under`)
        Some(fn(c : @view.View) {
          @sf.row_end_button_node(c, fn() { @sf.t(words()) }, fn() { act(@signals.untracked(action)) }, busy=doing, disabled=doing)
          |> ignore
        })
      },
    )
  })
}

///|
/// Its ⋯ (station_move_node's), of what was read (`v`): 全部迁回 where something is there, asked first (`ask`: true
/// moving back; 全部迁移 is the page's main action, at its first card's end).
fn station_move_menu(v : Json?, ask : (Bool) -> Unit) -> Array[@sf.MenuItem?] {
  let out : Array[@sf.MenuItem?] = []
  if field(v, "allBack") is Some(Object(_)) {
    out.push(Some(@sf.menu_item_of(@sf.t("web-pages.stations.move.allBack"), icon="arrow-left", fn() { ask(true) })))
  }
  out
}

///|
/// 全部迁移 (or, `back`, 全部迁回) asked once: the station it goes to and how many, as the core says them (`v`), then the
/// call. Its station's own words where it is refused (a toast: nothing of the page was pressed).
pub fn station_move_all_confirm(core : Core, address : String, v : Json?, back : Bool) -> Unit {
  let all = field(v, if back { "allBack" } else { "allMove" })
  let to = text(v, "to")
  @sf.confirm(
    text(all, "title"),
    text(all, "text"),
    @sf.t(if back { "web-pages.stations.move.allBack" } else { "web-pages.stations.move.all" }),
    fn() {
      if back {
        @settings.act(core, @sf.t("web-pages.stations.move.allBack"), "move.back", obj([("station", str(address)), ("from", str(to)), ("all", Json::boolean(true))]))
      } else {
        @settings.act(core, @sf.t("web-pages.stations.move.all"), "move.start", obj([("station", str(address)), ("to", str(to)), ("all", Json::boolean(true))]))
      }
    },
  )
}

///|
/// What its page holds while nothing is (its bones): the row it goes to, and three modules' cards.
fn station_move_sample(w : @view.View) -> Unit {
  @sf.group_node(w, fn(g) {
    @sf.link_row_node(g, fn() { @sf.t("web-pages.stations.move.to") }, fn() {  }, value=fn() { "Maple" }, goes=false)
  })
  for id in ["accounts", "chats", "jobs"] {
    @sf.group_node(w, fn(g) {
      @sf.link_row_node(g, fn() { @sf.t("web-pages.stations.move.module." + id) }, fn() {  }, value=fn() { "0 / 12" }, goes=false)
    })
  }
}

///|
/// Its 迁移 on its station's page (station_view_node's "move", while @settings.move_shown), under its head: one row,
/// where it moves (迁移到 Maple), done of total of all of it, what stands out under it (the worst first), opening this
/// page.
fn station_move_section(b : @view.View, core : Core, address : String) -> Unit {
  let v = fn() { @settings.move_of(core, address, "", "").value }
  @sf.group_node(b, fn(g) {
    @sf.link_row_node(g, fn() { text(v(), "title") }, fn() { (core.push)(StationMove(address)) }, value=fn() { text(v(), "count") }, note=fn() {
      text(v(), "note")
    })
  })
}

///|
/// Its ⋯'s 迁移到另一台 station (station_menu_items'), while it is online and offers moving; None otherwise.
fn station_move_item(core : Core, s : Json?) -> @sf.MenuItem? {
  guard (core.move_on)() && @settings.move_offered(s) else { return None }
  let address = text(s, "station")
  Some(@sf.menu_item_of(@sf.t("web-pages.stations.move.menu"), icon="move", further=true, fn() { (core.push)(StationMove(address)) }))
}
