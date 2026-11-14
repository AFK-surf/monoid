// Moving a station's things to another station of its workspace, module by module (the core's `stationMove` topic,
// client/core-ts/src/move.ts, of the station's move/: each module on its own, its needs first, progress inside it,
// everything undoable: the owner, 2026-11-14). Rarely used and risky, so no row of the station's page offers it: its ⋯
// has 迁移到另一台… while it is online and offers moving, which opens this page, a step further in from it; its 迁移
// shows on the station's page only while something of it is moved, moving, stopped or failed (station_move_section).
// No sentence explains it (the owner, 2026-11-14: 「字太多了，应该用更结构化更所见即所得的方式设计 UI」): the station it goes
// to, chosen in one row and remembered for this station on this device; what moves now; each module a card, its needs
// as chips, done of total and a thin bar, its one action at its first line; opened (by itself where something of it
// moves, failed or stopped), its items a row each, where it stands at the row's end and why under it, its own action
// in its menu, a page more as its list is scrolled to its end. Everything said is the core's; a press is a call to it,
// a refusal said on the row it was pressed on.

///|
/// Station `address`'s 迁移 (its ⋯'s 迁移到另一台…) made once in node `v`, as wide as `width` gives it.
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
    t != "" && targets().iter().any(fn(x) { text(Some(x), "station") == t })
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
    match modules().iter().find_first(fn(m) { text(Some(m), "id") == id }) {
      Some(m) => Some(m)
      None => None
    }
  }
  let item_of = fn(m : String, id : String) -> Json? {
    match shown_items(m).iter().find_first(fn(x) { text(Some(x), "id") == id }) {
      Some(x) => Some(x)
      None => None
    }
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
    for m in modules() {
      let id = text(Some(m), "id")
      out.push("m/" + id)
      if open() == id {
        for x in shown_items(id) {
          out.push("i/" + id + "/" + text(Some(x), "id"))
        }
      }
      // (its card's foot a piece of its own: what opens under its head opens between, the card's ends as they were)
      out.push("f/" + id)
    }
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
  let item_act = fn(m : String, id : String, action : String) {
    if action == "back" {
      call("move.back", [("from", str(@signals.untracked(to))), ("module", str(m)), ("item", str(id))])
    } else {
      call("move.start", [("to", str(@signals.untracked(to))), ("module", str(m)), ("item", str(id)), ("withNeeds", Json::boolean(true))])
    }
  }
  // its ⋯: 全部迁移 and 全部迁回, each asked once, naming the station and how many
  let actions = fn(a : @view.View) {
    a.show(fn() { chosen() && (field(view(), "allMove") is Some(Object(_)) || field(view(), "allBack") is Some(Object(_))) }, fn(m) {
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
        "to" => station_move_to_node(b, core, address, to, targets)
        "now" => station_move_now_node(b, fn() { field(view(), "moving") })
        _ if key.has_prefix("m/") => {
          let id = key.unsafe_substring(start=2, end=key.length())
          @sf.card_piece_node(b, fn() { @sf.CardTop }, wide_card=true, fn(card) {
            station_move_module_node(card, id, fn() { module_of(id) }, fn() { open() == id }, fn() { toggle(id) }, fn(action) {
              module_act(id, action)
            }, fn() { is_doing(core, calls, module_on(id)) }, fn() { failed_of(core, calls, module_on(id)) })
          })
        }
        _ if key.has_prefix("f/") => @sf.card_piece_node(b, fn() { @sf.CardFoot }, wide_card=true, fn(_) {  })
        _ if key.has_prefix("i/") => {
          let rest = key.unsafe_substring(start=2, end=key.length())
          let cut = rest.find("/").unwrap_or(0)
          let m = rest.unsafe_substring(start=0, end=cut)
          let id = rest.unsafe_substring(start=cut + 1, end=rest.length())
          @sf.card_piece_node(b, fn() { @sf.CardBetween }, wide_card=true, fn(card) {
            station_move_item_node(card, fn() { item_of(m, id) }, fn(action) { item_act(m, id, action) }, fn() {
              is_doing(core, calls, item_on(m, id))
            }, fn() { failed_of(core, calls, item_on(m, id)) })
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
  match items(v, "modules").iter().find_first(fn(m) { text(Some(m), "id") == id }) {
    Some(m) => Some(m)
    None => None
  }
}

///|
/// Where its things go (in `b`): one row, the station chosen among those the core offers (each its name and its room),
/// or that there is none to go to.
fn station_move_to_node(b : @view.View, core : Core, address : String, to : () -> String, targets : () -> Array[Json]) -> Unit {
  let name = fn() {
    let t = to()
    match targets().iter().find_first(fn(x) { text(Some(x), "station") == t }) {
      Some(x) => text(Some(x), "name")
      None => @sf.t("web-pages.stations.move.choose")
    }
  }
  @sf.group_node(b, fn(g) {
    @sf.link_row_opens_node(
      g,
      fn() { @sf.t("web-pages.stations.move.to") },
      fn(at) {
        let now = @signals.untracked(to)
        let all = @signals.untracked(targets).map(fn(x) {
          let id = text(Some(x), "station")
          let free = text(Some(x), "free")
          let label = if free == "" { text(Some(x), "name") } else { text(Some(x), "name") + " · " + free }
          Some(@sf.menu_item_of(label, chosen=id == now, fn() { @settings.move_target_set(core, address, id) }))
        })
        guard !all.is_empty() else { return }
        @sf.menu(all, from=Node(at), along=End)
      },
      value=fn() { if targets().is_empty() { @sf.t("web-pages.stations.move.none") } else { name() } },
    )
  })
}

///|
/// What moves now (in `b`): its module, its item and how far, a spinner before it and a bar under its line.
fn station_move_now_node(b : @view.View, moving : () -> Json?) -> Unit {
  let part = fn() {
    let p = field(moving(), "progress")
    let total = number(p, "total")
    if total > 0.0 { Some(number(p, "done") / total) } else { None }
  }
  @sf.group_node(b, fn(g) {
    @sf.link_row_node(
      g,
      fn() { text(moving(), "line") },
      fn() {  },
      goes=false,
      lead=LeadLine(fn(l) { @sf.spinner_node(l, size=st_row_glyph) |> ignore }),
      below=fn(r) { station_move_bar(r, part) },
      below_open=fn() { 1.0 },
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
/// A module's head (in `card`, its card's first piece), module `id`: its name, the modules it needs in a line of words
/// under it (依赖 账号、连接…; none where it needs none), done of total at its first line's end with its one action (迁移,
/// 迁回) there, a thin bar under it all (none for a module with nothing); pressed, its items open or shut (`toggle`); a
/// refusal of its action in place of what it needs while the core keeps it, in amber.
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
  let total = fn() { number(m(), "total") }
  let action = fn() { text(m(), "action") }
  let needs = fn() {
    match strings(m(), "needs") {
      [] => ""
      all =>
        @sf.t("web-pages.stations.move.needs", args=[
          ("names", all.map(fn(n) { @sf.t("web-pages.stations.move.need." + n) }).join(@sf.t("web-main.list.separator"))),
        ])
    }
  }
  card.pick(fn() { (total() > 0.0, action(), failed() is Some(_)) }, fn(r, k) {
    let (some, act_now, refused) = k
    @sf.link_row_node(
      r,
      fn() { @sf.t("web-pages.stations.move.module." + id) },
      toggle,
      value=fn() { text(m(), "count") },
      note=fn() { failed().unwrap_or(needs()) },
      lacks=refused,
      goes=some,
      folds?=if some { Some(is_open) } else { None },
      control?=if act_now == "" {
        None
      } else {
        Some(fn(c : @view.View) {
          @sf.row_end_button_node(
            c,
            fn() { @sf.t(if act_now == "back" { "web-pages.stations.move.back" } else { "web-pages.stations.move.move" }) },
            fn() { act(act_now) },
            busy=doing,
            disabled=doing,
          )
          |> ignore
        })
      },
      below?=if some {
        Some(fn(b : @view.View) {
          station_move_bar(b, fn() {
            let t = total()
            if t > 0.0 { Some(number(m(), "done") / t) } else { Some(0.0) }
          })
        })
      } else {
        None
      },
      below_open=fn() { if some { 1.0 } else { 0.0 } },
    )
  })
}

///|
/// An item's row (in `card`, a piece of its module's card): its label, where it stands at its end (迁移中 with how far
/// and a bar under its line; 已迁移; 已停 · 等「…」; 失败, 无法迁移 with why under it; nothing where it is here), its own
/// action in its menu (迁移, 迁回); a refusal of it under it, in amber.
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
  card.pick(fn() { (text(x(), "action"), state() == "moving") }, fn(r, k) {
    let (action, moving) = k
    let below = if moving { Some(fn(b : @view.View) { station_move_bar(b, part) }) } else { None }
    let below_open = fn() { if moving { 1.0 } else { 0.0 } }
    let bad = fn() { state() == "failed" }
    if action == "" {
      @sf.link_row_node(r, fn() { text(x(), "label") }, fn() {  }, value~, value_bad=bad, note~, lacks=true, goes=false, below?, below_open~)
      return
    }
    @sf.link_row_opens_node(
      r,
      fn() { text(x(), "label") },
      fn(at) {
        guard !@signals.untracked(doing) else { return }
        let label = @sf.t(if action == "back" { "web-pages.stations.move.back" } else { "web-pages.stations.move.move" })
        @sf.menu([Some(@sf.menu_item_of(label, icon=if action == "back" { "arrow-left" } else { "arrow-right" }, fn() { act(action) }))], from=Node(at), along=End)
      },
      value~,
      value_bad=bad,
      note~,
      lacks=true,
      chevron=false,
      below?,
      below_open~,
    )
  })
}

///|
/// Its ⋯ (station_move_node's), of what was read (`v`): 全部迁移 and 全部迁回 where each has something to do, each
/// asked first (`ask`: true moving back).
fn station_move_menu(v : Json?, ask : (Bool) -> Unit) -> Array[@sf.MenuItem?] {
  let out : Array[@sf.MenuItem?] = []
  if field(v, "allMove") is Some(Object(_)) {
    out.push(Some(@sf.menu_item_of(@sf.t("web-pages.stations.move.all"), icon="move", fn() { ask(false) })))
  }
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
/// Its 迁移 on its station's page (station_view_node's "move", while @settings.move_shown): each module of which
/// something is not simply here, a row with how it stands, opening this page.
fn station_move_section(b : @view.View, core : Core, address : String) -> Unit {
  let modules = fn() {
    items(@settings.move_of(core, address, "", "").value, "modules").filter(fn(m) {
      number(Some(m), "done") > 0.0 || text(Some(m), "mark") != ""
    })
  }
  st_section_node(b, fn() { @sf.t("web-pages.stations.move.section") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.each(modules, fn(m) { text(Some(m), "id") }, fn(row, m) {
        let mv = fn() { Some(m.get()) }
        let id = @signals.untracked(fn() { text(mv(), "id") })
        @sf.link_row_node(row, fn() { @sf.t("web-pages.stations.move.module." + id) }, fn() { (core.push)(StationMove(address)) }, value=fn() {
          match text(mv(), "markText") {
            "" => text(mv(), "count")
            mark => mark + " · " + text(mv(), "count")
          }
        })
      })
    })
  })
}

///|
/// Its ⋯'s 迁移到另一台… (station_menu_items'), while it is online and offers moving; None otherwise.
fn station_move_item(core : Core, s : Json?) -> @sf.MenuItem? {
  guard @settings.move_offered(s) else { return None }
  let address = text(s, "station")
  Some(@sf.menu_item_of(@sf.t("web-pages.stations.move.menu"), icon="move", fn() { (core.push)(StationMove(address)) }))
}
