// What wants the viewer and they have not looked at yet, beside the rail's bell or under 待处理 (still.fail
// web/src/Attention.tsx, Attention.css.ts): the stations' trouble (with the bell, and in 待处理 of its own), then
// each workspace's chats that came to want the viewer and were not read since (the core's `workspaceMarks` items),
// then what is left up long (the viewer's own, the others' folded: open_jobs.mbt), below the chats so that what waits
// on the viewer is never pushed down by a service left up all week;
// each leading to its chat: a card until read (then its row still says it), a failure until the chat runs again,
// an unread chat the app's number counts until read (全部已读 reads them at once, leaving cards and failures);
// one let go here neither (忽略: a card's `decision.dismiss`, a failure's `prefs.failsGone` until it fails again). A
// station's trouble is the same: listed until the panel has shown it, then the Station's place
// says it, until the trouble changes (kept on this device).
//
// Only what has come to you and you have not seen; there is no list of every open decision (奏 removed, the user,
// 2026-10-30: 「把奏删掉吧」).

///|
/// What the panel keeps: what was let go in it (忽略) until the core no longer lists it, by station and chat; the
/// stations' trouble as looked at before it opened, as it shows it while open (None: closed).
priv struct Attention {
  /// (followed: a panel of nodes lists a row no longer once it is let go here, and again if that could not be done)
  gone : @sf.LiveMap[String, Bool]
  mut trouble_seen : String?
  /// A clearing already asked of this core, until its prefs change or the station has trouble again. A call's
  /// answer can arrive before the prefs topic; no frame in between sends the same write again.
  trouble_forgotten : Map[String, (Int, String, String)]
}

///|
let attention : Attention = { gone: @sf.LiveMap::new(), trouble_seen: None, trouble_forgotten: {} }

///|
fn attention_reset() -> Unit {
  attention.gone.clear()
  attention.trouble_seen = None
  attention.trouble_forgotten.clear()
}

///|
/// 待处理's panel opened or closed, whatever does it: closed, this opening of it over (what it kept as it opened, the
/// stations' trouble as looked at before, let go: the next opening reads it anew), at that moment.
fn attention_set(open : Bool) -> Unit {
  if !open {
    attention.trouble_seen = None
  } else {
    // (beside the rail's bell where it is as it opens, whatever opens it: rail_node's)
    attention_from.val = rail_place_at("attention")
  }
  wide.attention_open.set(open)
}

///|
/// 待处理's panel open (a screen's fixture).
pub fn open_attention() -> Unit {
  attention_set(true)
}

///|
/// The panel 300 wide (300 at least), 10 past the rail's bell, 6 under
/// 待处理.
let attention_w : Double = 300.0

///|
let attention_off_rail : Double = 10.0

///|
let attention_off_side : Double = 6.0

///|
/// What is wrong with the workspace's stations, in words (the chats' `trouble`, useStationTrouble); "" none.
fn station_trouble_words(src : Source, w : Workspace) -> String {
  chats_trouble_words(@sfbase.chats_topic(src, w.id).value)
}

///|
fn chats_trouble_words(chats : Json?) -> String {
  text(field(chats, "trouble"), "text")
}

///|
/// What this device did with the stations' trouble (`seen`; `gone` from before it was no longer listed once seen): the
/// words it had then, "" none (the prefs' `trouble`, by `<workspace>\n<what>`).
fn trouble_kept(src : Source, w : Workspace, what : String) -> String {
  match field(field(src.topic("prefs", {}).get().value, "trouble"), w.id + "\n" + what) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn trouble_keep(src : Source, w : Workspace, what : String, words : Json) -> Unit {
  let m : Map[String, Json] = Map([])
  m[w.id + "\n" + what] = words
  (src.call)("prefs.set", Json::object({ "trouble": Json::object(m) }), @sfbase.answer_unread)
}

///|
/// The stations all reached: what was kept of their trouble let go.
fn trouble_forget(src : Source, w : Workspace) -> Unit {
  // No value yet (for example just after switching workspaces) says nothing about whether its stations recovered.
  let chats = @sfbase.chats_topic(src, w.id)
  guard chats.error is None && chats.value is Some(value) else { return }
  let seen = trouble_kept(src, w, "seen")
  let gone = trouble_kept(src, w, "gone")
  if chats_trouble_words(Some(value)) != "" || (seen == "" && gone == "") {
    attention.trouble_forgotten.remove(w.id)
    return
  }
  let (generation, _) = (src.generation)("prefs", {})
  let clearing = (generation, seen, gone)
  if attention.trouble_forgotten.get(w.id) == Some(clearing) { return }
  attention.trouble_forgotten[w.id] = clearing
  let patch : Map[String, Json] = Map([])
  patch[w.id + "\nseen"] = Json::null()
  patch[w.id + "\ngone"] = Json::null()
  (src.call)("prefs.set", { "trouble": Json::object(patch) }, @sfbase.answer_unread)
}

///|
/// The stations' trouble listed in the bell: not looked at before (while the panel is open, before it opened); ""
/// none.
fn bell_trouble(src : Source, w : Workspace) -> String {
  let words = station_trouble_words(src, w)
  let seen = match attention.trouble_seen {
    Some(s) => s
    None => trouble_kept(src, w, "seen")
  }
  if words == seen {
    ""
  } else {
    words
  }
}

///|
/// Whether the bell has its dot (the rail's, 小屏 Home's top bar's): something in its panel, the chats (less what was let
/// go here), the stations' trouble not looked at or the viewer's own left up long it has not shown yet (never another's:
/// the core's `lit`).
pub fn bell_lit(src : Source, w : Workspace) -> Bool {
  // (each read whatever the others hold: what it reads never comes and goes with another's value, its topics held
  // all along, not let go of as 待处理 comes to list a chat and asked again as it lists none; sfapp's
  // bell_reads_wbtest)
  let chats = attention_groups(src, w, true).length() > 0
  let trouble = bell_trouble(src, w) != ""
  let jobs = long_jobs_lit(src, w)
  chats || trouble || jobs
}

///|
/// A wanting chat by its station and chat, a failure by itself (keyOf: the same chat failing again is listed anew).
fn attention_key(i : Json) -> String {
  let v = Some(i)
  if text(v, "failure") != "" {
    return text(v, "failure")
  }
  let session = text(v, "session")
  let chat = text(v, "station") + "/" + (if session != "" { session } else { number(v, "thread").to_int64().to_string() })
  // (read here: what is said in it after is listed anew)
  if text(v, "kind") == "done" {
    chat + "@" + number(v, "seq").to_int64().to_string()
  } else {
    chat
  }
}

///|
/// Workspace `ws`'s mark as the core says it (its name, its mark, its 待处理).
fn attention_mark(src : Source, ws : String) -> Json? {
  field(field(src.topic("workspaceMarks", @sfbase.marks_asked()).get().value, "workspaces"), ws)
}

///|
/// The unread 待处理 lists, read up to their last message: gone at once, back if that could not be done.
fn attention_read_all(src : Source, list : Array[Json]) -> Unit {
  for i in list {
    let v = Some(i)
    let key = attention_key(i)
    attention.gone[key] = true
    act(
      src,
      @sf.t("web-main.attention.readAll"),
      "",
      "chat.read",
      { "station": Json::string(text(v, "station")), "thread": Json::number(number(v, "thread")), "seq": field(v, "seq").unwrap() },
      failed=fn() { attention.gone.remove(key) },
    )
  }
}

///|
/// 待处理 as a panel of its own, where there is no bell to open it beside (小屏's Home, its top bar's bell): its rows
/// and its foot nodes, each following what it lists (the stations' trouble, the core's marks, what is left up long,
/// what was let go here) as that changes. As it opens, what it shows of the stations' trouble and of what is left up
/// long is looked at, as the panel beside the bell's (kept: no longer lighting the bell), listed while it is open.
pub fn open_attention_panel(src : Source, w : Workspace, from : @sf.Anchor) -> Unit {
  attention_present(
    src,
    w,
    from,
    @sf.t("web-main.attention.entry"),
    true,
    fn(close) { close },
    tall=0.92,
    hugs=true,
    grows=true,
    gone=fn() { attention.trouble_seen = None },
  )
}

///|
/// 待处理's panel presented by `from` (titled `title`, "" none): as it opens, the stations' trouble as looked at before
/// kept for while it is open, and where it lists them (`railed`: the bell's, 小屏's own), what it shows of the
/// stations' trouble and of what is left up long looked at (kept: no longer lighting the bell); its rows
/// (attention_rows_node) and its foot (attention_foot_node) given what closes it, as `closes` makes that of the
/// panel's own close. `w`, `side`, `along`, `offset`: beside what opened it (panel_nodes'); `gone` as it closes unsaid.
fn attention_present(
  src : Source,
  w : Workspace,
  from : @sf.Anchor,
  title : String,
  railed : Bool,
  closes : (() -> Unit) -> () -> Unit,
  width? : Double = @sf.panel_w,
  side? : @ui.Side = Bottom,
  along? : @ui.Along = Start,
  offset? : Double = @sf.panel_offset,
  tall? : Double = 0.98,
  hugs? : Bool = true,
  grows? : Bool = false,
  foot_style? : @ui.Style = att_foot,
  gone? : () -> Unit = fn() {  },
) -> Unit {
  attention.trouble_seen = Some(trouble_kept(src, w, "seen"))
  let now = station_trouble_words(src, w)
  if railed && now != "" {
    trouble_keep(src, w, "seen", Json::string(now))
  }
  // the services left up long it lists: shown, no longer lighting it (still listed)
  if railed && long_jobs_lit(src, w) {
    long_jobs_seen(src, w)
  }
  // its stations all reached again: a trouble later in the same words is new
  trouble_forget(src, w)
  @sf.panel_nodes(
    title,
    fn(v, close) { attention_rows_node(v, src, w, railed, closes(close)) },
    from~,
    w=width,
    side~,
    along~,
    offset~,
    tall~,
    hugs~,
    hugs_wide=true,
    grows~,
    foot=fn(v, close) {
      // (across the foot's row, its words at its start as the old foot's were)
      v.box(fn(b) {
        @sf.style_node(b, fn() { att_sheet }, in_row=true)
        attention_foot_node(b, src, w, closes(close), style=foot_style)
      })
      |> ignore
    },
    gone~,
  )
}

///|
/// In a box of its own, what it holds stays within the sheet's sides, under its title.
// kept across runs: a value (no field of it changes)
let att_sheet : @ui.Style = @ui.css("w=Full")

///|
/// Each workspace's chats in 待处理 (the core's marks' items), the one in view's first, those let go here left out
/// when `shown`: (workspace, its name, its chats).
fn attention_groups(src : Source, w : Workspace, shown : Bool) -> Array[(String, String, Array[Json])] {
  let marks = src.topic("workspaceMarks", @sfbase.marks_asked()).get().value
  let groups : Array[(String, String, Array[Json])] = []
  match field(marks, "workspaces") {
    Some(Object(by)) => {
      let order = by.keys().to_array()
      order.sort_by(fn(a, b) { if a == w.id { -1 } else if b == w.id { 1 } else { 0 } })
      for ws in order {
        let list = items(by.get(ws), "items").filter(fn(i) { !shown || !attention.gone.contains(attention_key(i)) })
        if list.length() > 0 {
          groups.push((ws, text(by.get(ws), "workspaceName"), list))
        }
      }
    }
    _ => ()
  }
  groups
}

///|
/// What 忽略 does to a row of 待处理 (`i`, the core's item), where it can be let go: a failure, until the chat fails again
/// (kept on this device: prefs' failsGone); a decision waiting on the viewer (the core says where it is in the chat).
/// Gone at once, listed again if that could not be done.
fn attention_dismiss(src : Source, i : Json) -> (() -> Unit)? {
  let v = Some(i)
  let key = attention_key(i)
  let thread = number(v, "thread")
  let seq = field(v, "seq")
  let failure = text(v, "failure")
  if text(v, "kind") == "alert" && failure != "" {
    Some(fn() {
      attention.gone[key] = true
      let m : Map[String, Json] = Map([])
      m[text(v, "workspace")] = Json::array([Json::string(failure)])
      act(
        src,
        @sf.t("web-main.decisions.dismissWhat"),
        "",
        "prefs.set",
        { "failsGone": Json::object(m) },
        // not let go: listed again
        failed=fn() { attention.gone.remove(key) },
      )
    })
  } else if text(v, "kind") == "wait" && thread > 0.0 && seq is Some(Number(_, ..)) {
    Some(fn() {
      attention.gone[key] = true
      act(
        src,
        @sf.t("web-main.decisions.dismissWhat"),
        "",
        "decision.dismiss",
        { "station": Json::string(text(v, "station")), "thread": Json::number(thread), "seq": seq.unwrap() },
        // not let go: listed again
        failed=fn() { attention.gone.remove(key) },
      )
    })
  } else {
    None
  }
}

///|
/// What 忽略's tip says of a row of 待处理 (the core's item `v`).
fn attention_note(v : Json?) -> String {
  @sf.t(if text(v, "kind") == "alert" { "web-main.attention.dismissFailNote" } else { "web-main.attention.dismissNote" })
}

///|
/// A row of 待处理 (`i`, the core's item, of workspace `ws`) pressed: its chat beside the board in view, or over Home
/// in its workspace (switched to where it is not `w`).
fn attention_go(src : Source, w : Workspace, ws : String, i : Json, close : () -> Unit) -> Unit {
  let v = Some(i)
  let session = text(v, "session")
  close()
  let chat : ChatRef = {
    station: text(v, "station"),
    session: if session != "" { session } else { "thread:" + number(v, "thread").to_int64().to_string() },
    title: text(v, "title"),
    station_name: text(v, "stationName"),
  }
  if ws == w.id && @sfbase.notice_on_board(chat) {
    return
  }
  @sfbase.history_push()
  if ws != w.id {
    app.picked.set(ws)
    (src.call)("prefs.set", Json::object({ "workspace": Json::string(ws) }), @sfbase.answer_unread)
    desk_home()
  }
  @sfbase.nav_over_home([Chat(chat)])
  @sfbase.show_chosen()
}

///|
/// The unread 待处理 lists (what 全部已读 reads), as it lists them now.
fn attention_unread(src : Source, w : Workspace) -> Array[Json] {
  attention_groups(src, w, true)
  .iter()
  .flat_map(fn(g) { g.2.iter() })
  .filter(fn(i) { text(Some(i), "kind") == "done" && number(Some(i), "thread") > 0.0 && field(Some(i), "seq") is Some(Number(_, ..)) })
  .collect()
}

///|
/// A virtualized row of 待处理's panel (attention_rows_node's panel_list_node).
#derive(Eq, Hash)
priv enum AttentionBlock {
  AttTrouble
  AttGroupHead(String)
  AttChatItem(String, String)
  AttOpenJobs
}

///|
/// Estimated row height of an attention item for panel_list_node virtualization.
let att_row_est : Double = 46.0

///|
/// What 待处理's panel holds (attention_present's), in node `v`: where it is the bell's (`railed`: the rail's, 小屏's
/// own), the stations' trouble not looked at before it opened (pressed, the Stations' place); each workspace's chats
/// that want the viewer, the one in view's first, under its name where there are several (its mark before it); where
/// it is the bell's, what is left up long (open_jobs_node: the viewer's own, the others' folded; under 待处理 in the
/// sidebar the sidebar's foot lists it); nothing waiting said where none of it is. A part with one before it 6 under
/// it; each following what it lists as that changes. Virtualized via `@sf.panel_list_node` when non-empty so large
/// workspaces only build visible items on cold open, while the empty state renders directly without list overhead.
fn attention_rows_node(v : @view.View, src : Source, w : Workspace, railed : Bool, close : () -> Unit) -> Unit {
  let plan = @signals.computed(fn(_) {
    let gs = attention_groups(src, w, true)
    let tr = if railed { bell_trouble(src, w) } else { "" }
    let has_jobs = railed && open_jobs_any(src, w)
    let sev = gs.length() > 1 || gs.iter().any(fn(g) { g.0 != w.id })
    let keys : Array[AttentionBlock] = []
    let names : Map[String, String] = Map([])
    let by_key : Map[(String, String), Json] = Map([])
    let top_gap : Map[AttentionBlock, @ui.Space] = Map([])
    if tr != "" {
      keys.push(AttTrouble)
    }
    for gi, g in gs {
      let (ws_id, ws_name, items) = g
      names[ws_id] = ws_name
      if sev {
        // (panel_label_at already carries pt=S1_5 (6px) and pb=S0_5 (2px), matching the original panel_group_node)
        keys.push(AttGroupHead(ws_id))
      }
      for ii, it in items {
        let ik = attention_key(it)
        let bk = AttChatItem(ws_id, ik)
        keys.push(bk)
        by_key[(ws_id, ik)] = it
        // (6px under trouble only when chats have no group heading of their own; items within a group sit flush)
        if !sev && gi == 0 && ii == 0 && tr != "" {
          top_gap[bk] = S1_5
        }
      }
    }
    if has_jobs {
      keys.push(AttOpenJobs)
      if tr != "" || gs.length() > 0 {
        top_gap[AttOpenJobs] = S1_5
      }
    }
    (keys, names, by_key, top_gap, tr)
  })
  let keys = @signals.computed(fn(_) { plan.get().0 })
  v.pick(at_once=true, fn() { keys.get().length() == 0 }, fn(slot, empty) {
    if empty {
      slot.box(fn(b) {
        @sf.style_node(b, fn() { att_empty })
        @sf.words_node(b, fn() { @sf.t("web-main.attention.empty") }, fn() { att_empty_words }) |> ignore
      })
      |> ignore
    } else {
      slot.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      @sf.panel_list_node(
        slot,
        fn() { keys.get() },
        est=att_row_est,
        fn(row, k) {
          let last_gap : Ref[@ui.Space?] = Ref(@signals.untracked(fn() { plan.get().3.get(k) }))
          let gap = fn() {
            let p = plan.get()
            let present = match k {
              AttTrouble => p.4 != ""
              AttGroupHead(ws_id) => p.1.contains(ws_id)
              AttChatItem(ws_id, ik) => p.2.contains((ws_id, ik))
              AttOpenJobs => p.0.contains(AttOpenJobs)
            }
            if present {
              let g = p.3.get(k)
              last_gap.val = g
              g
            } else {
              last_gap.val
            }
          }
          match k {
            AttTrouble => {
              let last_tr : Ref[String] = Ref(@signals.untracked(fn() { plan.get().4 }))
              let tr_now = fn() {
                let s = plan.get().4
                if s != "" {
                  last_tr.val = s
                  s
                } else {
                  last_tr.val
                }
              }
              @sf.panel_group_node(row, fn() { "Station" }, fn(rows) {
                attention_item_node(rows, src, fn() { { "kind": "alert", "title": Json::string(tr_now()) } }, fn() {
                  close()
                  @sfbase.go_place("stations", kept=true) |> ignore
                })
              })
            }
            AttGroupHead(ws_id) => {
              let first_item = fn() { attention_mark(src, ws_id) }
              let last_name : Ref[String] = Ref(@signals.untracked(fn() { plan.get().1.get(ws_id).unwrap_or("") }))
              let ws_name = fn() {
                match plan.get().1.get(ws_id) {
                  Some(n) => {
                    last_name.val = n
                    n
                  }
                  None => last_name.val
                }
              }
              @sf.panel_group_node(
                row,
                ws_name,
                lead=fn(l) {
                  @sf.workspace_badge_node(
                    l,
                    ws_name,
                    fn() { text(first_item(), "workspaceEmoji") },
                    fn() { text(first_item(), "workspaceIcon") },
                    att_ws_mark,
                  )
                },
                fn(_) {  },
              )
            }
            AttChatItem(ws_id, ik) => {
              let last_item : Ref[Json] = Ref(@signals.untracked(fn() { plan.get().2.get((ws_id, ik)).unwrap_or(Json::object(Map([]))) }))
              let item_sig = @signals.computed(fn(_) {
                match plan.get().2.get((ws_id, ik)) {
                  Some(it) => {
                    last_item.val = it
                    it
                  }
                  None => last_item.val
                }
              })
              attention_item_node(row, src, fn() { item_sig.get() }, top_gap=gap, fn() {
                attention_go(src, w, ws_id, @signals.untracked(fn() { item_sig.get() }), close)
              })
            }
            AttOpenJobs =>
              row.box(fn(g) {
                g.margin(By(fn() {
                  match gap() {
                    Some(sp) => (0.0, sp.px(), 0.0, 0.0)
                    None => (0.0, 0.0, 0.0, 0.0)
                  }
                }))
                |> ignore
                open_jobs_node(g, src, w, close)
              })
              |> ignore
          }
        },
      )
      |> ignore
    }
  })
}

///|
/// A row of 待处理's panel in node `row`, of the core's item `i` as it is now: its dot (amber
/// waiting on the viewer, red gone wrong, blue unread, said as an image of its kind), its title (500) and its line; 忽略
/// at its end where it can be let go, while the hand is on the row (always to a finger, which hovers over nothing),
/// its note its tip. Pressed, `go`.
fn attention_item_node(
  row : @view.View,
  src : Source,
  i : () -> Json,
  top_gap? : () -> @ui.Space? = fn() { None },
  go : () -> Unit,
) -> Unit {
  let v = fn() { Some(i()) }
  // the time, said again as each minute of a login's time left goes (attention_left's)
  let now = @sf.countdown_now_node(row, src.now, fn() { number(v(), "loginEnds") })
  let title = fn() {
    match text(v(), "title") {
      "" => @sf.t("web-main.attention.untitled")
      t => t
    }
  }
  let tips = @sf.panel_tips_of(row)
  @sf.action_box_node(row, title, fn(_) { go() }, fn(r) {
    @sf.style_node(r, fn() {
      let base = if @sf.lit_in_node(r) { att_item_on } else { att_item }
      match top_gap() {
        Some(sp) => base.then(@ui.style(mt=sp))
        None => base
      }
    })
    // (its first line: the dot, the title and 忽略, their middles on one line; the line under it from the title's edge,
    // never the dot centred on both: the user, 2026-11-14)
    r.box(fn(head) {
      @sf.style_node(head, fn() { att_head })
      head.box(fn(m) {
        @sf.style_node(m, fn() { att_mark })
        m.box(fn(dot) {
          let look = fn() -> (@ui.Color, String) {
            match text(v(), "kind") {
              "alert" => (Data(@sf.theme().p.red), "web-main.attention.alertOne")
              "done" => (@sf.mark_blue, "web-main.chatMark.done")
              _ => (Warn, "web-main.attention.waitOne")
            }
          }
          @sf.style_node(dot, fn() {
            let (ground, _) = look()
            att_dot.then(@ui.style(bg=ground))
          })
          dot.says(By(fn() { Some(@view.said(Image, label=@sf.t(look().1))) })) |> ignore
        })
        |> ignore
      })
      |> ignore
      @sf.words_node(head, title, fn() { att_title })
      .grow(Is(1.0))
      .shrink(Is(1.0))
      .basis(Is(Some(0.0)))
      .min_width(Is(Some(0.0)))
      |> ignore
      head.show(
        at_once=true,
        fn() { attention_dismiss(src, i()) is Some(_) && (!@sf.pointer_rests() || @sf.lit_in_node(r)) },
        fn(d) {
          @sf.action_box_node(d, fn() { @sf.t("web-main.attention.dismiss") }, fn(_) {
            match attention_dismiss(src, @signals.untracked(i)) {
              Some(f) => @view.transition(within=d.transitions_root(), f)
              None => ()
            }
          }, fn(x) {
            @sf.style_node(x, fn() { if @sf.lit_node(x) { att_dismiss_on } else { att_dismiss } })
            @sf.words_node(x, fn() { @sf.t("web-main.attention.dismiss") }, fn() {
              if @sf.lit_node(x) {
                att_dismiss_on_words
              } else {
                att_dismiss_words
              }
            })
            |> ignore
            match tips {
              Some(layer) => @sf.tip_node(layer, x, fn() { attention_note(v()) }) |> ignore
              None => ()
            }
          })
          |> ignore
        },
      )
    })
    |> ignore
    r.show(at_once=true, fn() { attention_line(v(), now()) != "" }, fn(u) {
      // (att_mark width S4 + att_head gap S2_5: the line starts where the title does, without redundant wrapper boxes)
      u.padding(Is((@ui.Space::S4.px() + @ui.Space::S2_5.px(), 0.0, 0.0, 0.0))) |> ignore
      @sf.words_node(u, fn() { attention_line(v(), now()) }, fn() { att_line }) |> ignore
    })
  })
  |> ignore
}

///|
/// 待处理's foot in node `v`: 全部已读 while it lists unread, 通知设置, small words, quiet, in ink
/// under the hand; following what it lists as that changes.
fn attention_foot_node(
  v : @view.View,
  src : Source,
  w : Workspace,
  close : () -> Unit,
  style? : @ui.Style = att_foot,
) -> Unit {
  v.box(fn(f) {
    @sf.style_node(f, fn() { style })
    f.show(at_once=true, fn() { attention_unread(src, w).length() > 0 }, fn(r) {
      attention_link_node(r, fn() { @sf.t("web-main.attention.readAll") }, fn() {
        attention_read_all(src, @signals.untracked(fn() { attention_unread(src, w) }))
      })
    })
    attention_link_node(f, fn() { @sf.t("web-main.attention.settings") }, fn() {
      close()
      open_settings_at(@settings.Route::Notifications)
    })
  })
  |> ignore
}

///|
/// Words to press at 待处理's foot in `parent`, quiet, in ink under the hand; read out a link.
fn attention_link_node(parent : @view.View, label : () -> String, press : () -> Unit) -> Unit {
  parent.box(fn(b) {
    @sf.presses_node(b, press)
    b.says(By(fn() { Some(@view.said(Link, label=label())) })) |> ignore
    @sf.words_node(b, label, fn() { if @sf.lit_node(b) { att_link_on } else { att_link } }) |> ignore
  })
  |> ignore
}

///|
/// A workspace's mark before its name over its chats.
let att_ws_mark : Double = 14.0

///|
/// Nothing waiting (empty): 10 by 16 in, 13, muted.
// kept across runs: a value (no field of it changes)
let att_empty : @ui.Style = @ui.css("w=Full px=S4 py=S2_5")

///|
// kept across runs: a value (no field of it changes)
let att_empty_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L6)

///|
/// A row (item): 6 by 16 in, its corner the panel's inner (--panel-in); pointed at, on the pointer's ground. Its first
/// line (att_head) over the line under it (att_under).
// kept across runs: a value (no field of it changes)
let att_item : @ui.Style = @ui.style(w=Full, px=S4, py=S1_5, radius=@sf.panel_in)

///|
/// A row's first line: its dot's column, its title and 忽略, 10 apart, their middles on one line. Its words start where
/// a long job's do above it (open_job_row), not 11 left of them.
// kept across runs: a value (no field of it changes)
let att_head : @ui.Style = @ui.css("row w=Full gap=S2_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let att_item_on : @ui.Style = att_item.then(@ui.css("bg=Hover"))

///|
/// Its dot's column: the 16 a long job's dot and a workspace's mark stand in (open_job_mark), the dot at its start, where
/// the groups' headings' words start (gaps.mbt rule 8: what else stands in the panel as far in as its rows' marks).
// kept across runs: a value (no field of it changes)
let att_mark : @ui.Style = @ui.css("w=S4 align=AStart justify=JCenter")

///|
/// Its dot, 7 round, in the amber's ink (red gone wrong).
// kept across runs: a value (no field of it changes)
let att_dot : @ui.Style = @ui.style(w=@sf.attention_dot, h=@sf.attention_dot, radius=Full)

///|
// kept across runs: a value (no field of it changes)
let att_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, leading=L6, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let att_line : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L4_75, wrap=false)

///|
/// 忽略 (dismiss): a small pill, 1 by 6 in, 12, muted; in ink on the pointer's ground pointed at. Shown only under
/// the pointer, it makes the row no taller (its words' line 19, the pill 21, the title's 20): its ground reaches the
/// 1 over and under past them (align.mbt bleed_y).
// kept across runs: a value (no field of it changes)
let att_dismiss : @ui.Style = @ui.css("px=S1_5 radius=Full").then(@sf.bleed_y(att_dismiss_bleed))

///|
let att_dismiss_bleed : Double = 1.0

///|
// kept across runs: a value (no field of it changes)
let att_dismiss_on : @ui.Style = att_dismiss.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let att_dismiss_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L4_75, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let att_dismiss_on_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, leading=L4_75, wrap=false)

///|
/// The foot (foot): its words 12 apart, 8 by 16 in and 4 under, 4 more over it.
// kept across runs: a value (no field of it changes)
let att_foot : @ui.Style = @ui.css("row w=Full gap=S3 px=S4 pt=S3 pb=S1")

///|
/// The foot beside the bell: as att_foot, its room over it the panel's foot's (8) and 4 more, 12 under what scrolls.
// kept across runs: a value (no field of it changes)
let att_foot_beside : @ui.Style = @ui.css("row w=Full gap=S3 px=S4 pt=S1 pb=S1")

///|
// kept across runs: a value (no field of it changes)
let att_link : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L4_75, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let att_link_on : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, leading=L4_75, wrap=false)

///|
/// A wanting chat's line without its lead (the core's `what`: 要你帮忙：, 出问题：, 待处理 · taken off; the dot before it
/// says that), else its station's name.
/// A login's (`loginEnds`: when it runs out of time) with how long is left as of `now`: 需要你登录 gh · 剩 12 分钟.
fn attention_line(v : Json?, now : Double) -> String {
  let line = match text(v, "what") {
    "" => text(v, "stationName")
    s => s
  }
  match attention_left(v, now) {
    "" => line
    left => line + " · " + left
  }
}

///|
/// How long is left of a login waiting for the viewer (`loginEnds`), in whole minutes rounded up, as of `now`: 剩 12
/// 分钟, 不到 1 分钟; "" where it is not known or has gone by.
fn attention_left(v : Json?, now : Double) -> String {
  let ends = number(v, "loginEnds")
  guard ends > 0.0 else { return "" }
  let minutes = ((ends - now + 59999.0) / 60000.0).floor().to_int()
  if minutes <= 0 {
    ""
  } else if minutes <= 1 {
    @sf.t("web-main.attention.loginLast")
  } else {
    @sf.t("web-main.attention.loginLeft", args=[("minutes", minutes.to_string())])
  }
}

