// An agent's execution history, a page of its own (slice 8: still.fail apps/android chat/screens/History.kt HistoryScreen,
// Steps, Item, Message, Group, StepRow, Folding, Whole, PhaseLine, Details; ui/ToolStep.kt): what it received and what
// it sent, drawn alike (a line saying what and where, then its words in brief beside a bar); what it did in between,
// grouped, each group opening to its calls and thoughts, a call opening to what it asked for (a command, an edit as a
// diff, a file, a patch, a plan, its fields) and what came back. Its details: where it stands, its figures, how it
// runs, the station. What it shows is the core's `history {station, key}` view; a call in brief is read whole as it is
// opened (`history.detail`), the page before as the reader nears the top (`history.older`).
//
// Opened at an entry (a link's `?history=…&entry=…`), that entry's item comes near the top, for a moment marked. A
// Slack user's name offers 这是我 or 不是我 (`slack.identity`); a place is a way there.

///|
fn history_params(r : ChatRef, key : String) -> Map[String, Json] {
  { "station": Json::string(r.station), "key": Json::string(key) }
}

///|
/// The history's page left: what it followed let go.
fn history_left(src : Source, r : ChatRef, key : String) -> Unit {
  (src.leave)("history", history_params(r, key), @sfbase.TopicLeave::Legacy)
  // the station's figures its details read
  @sfbase.let_go(src, @sfbase.history_scope(r.station, key))
  // (what 详情 pressed handed its details and they did not read: let go)
  @sfbase.shown_read(@sfpages.history_details_at(r.station, key))
  history_placed.remove("history/" + r.station + "/" + key)
  history_short.remove("history/" + r.station + "/" + key)
}

///|
/// The head's short line, made once in `v`: only what is worth a look now (sfpages' history_attention_node: a quota
/// running out, its chip with what it says and more in its tip, in `tips`; the disk filling up, amber; an account that
/// cannot run, red), as `a` says it; 8 of room while there is none.
fn history_summary_node(v : @view.View, a : () -> Json?, tips : @sf.TipLayer) -> Unit {
  v.pick(at_once=true, fn() { items(a(), "attention").length() > 0 }, fn(p, any) {
    if !any {
      p.height(Is(Some(8.0))) |> ignore
      return
    }
    p.box(fn(r) {
      r.row(Is(true)).wraps(Is(Some(6.0))).padding(Is((18.0, 6.0, 18.0, 8.0))).gap(Is(10.0)).lines_up(Is(Some(Start))) |> ignore
      @sfpages.history_attention_node(r, a, tips, history_note_amber, history_note_red)
    })
    |> ignore
  })
}

///|
/// What needs seeing to that is no quota: the caption's, the disk amber, an account red.
// kept across runs: a value (no field of it changes)
let history_note_amber : @ui.TextStyle = @ui.text_style(size=Caption, color=WarnInk)

///|
// kept across runs: a value (no field of it changes)
let history_note_red : @ui.TextStyle = @ui.text_style(size=Caption, color=Danger)

///|
/// How a history's steps were put in place as it opened, by its list's key: at
/// its newest, followed (true), or at an entry, not followed (false). Not there: not put in place yet.
let history_placed : Map[String, Bool] = Map([])

///|
/// The histories whose page before, asked for an entry before what was loaded, could not be had: put in place with
/// what there is.
let history_short : Map[String, Bool] = Map([])

///|
/// Its details, made once in `v` and scrolling in it, as agent `a`, its card and its station say them now: where it
/// stands and its figures as its card has them, how it runs in a line (its model's panel opened from it), what it runs
/// on and has done, what it used, the station.
fn history_details_node(v : @view.View, src : Source, r : ChatRef, key : String, a : () -> Json?, tips : @sf.TipLayer) -> Unit {
  let s = fn() { field(a(), "session") }
  let (card_topic, card_params) = @sfpages.agent_card_ask(r.station, key)
  // (what 详情 pressed asked, handed to it till it has read it: sfbase's shown_read, said as the last of what it asked
  // is read, the stations' rows its station is named from, as the details are built: said as its card was read, the
  // rows handed over were let go at that frame's end before the station's row read them, and asked again)
  let at = @sfpages.history_details_at(r.station, key)
  let card = fn() { src.topic(card_topic, card_params).get().value }
  let usage = fn() { @sfpages.history_usage(src, r.station, key) }
  let (host_topic, host_params) = @sfpages.history_host_ask(r.station)
  let host_held = @sfbase.hold(src, @sfbase.history_scope(r.station, key), host_topic, host_params)
  let host = fn() { host_held.get().value }
  // a line of it: its name in a 76 column, what it says beside it
  let detail = fn(p : @view.View, label : () -> String, value : (@view.View) -> Unit) {
    p.box(fn(l) {
      l.row(Is(true)).gap(Is(16.0)) |> ignore
      l.box(fn(n) {
        n.width(Is(Some(76.0))).shrink(Is(0.0)) |> ignore
        @sf.words_node(n, label, fn() { details_label }) |> ignore
      })
      |> ignore
      l.box(fn(w) {
        w.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        value(w)
      })
      |> ignore
    })
    |> ignore
  }
  let said = fn(words : () -> String) { fn(w : @view.View) { @sf.words_node(w, words, fn() { details_value }) |> ignore } }
  let group = fn(p : @view.View, name : () -> String) {
    p.box(fn(g) {
      g.padding(Is((0.0, 14.0, 0.0, 4.0))) |> ignore
      @sf.words_node(g, name, fn() { details_group }) |> ignore
    })
    |> ignore
  }
  let rows = fn(p : @view.View, top : Double, body : (@view.View) -> Unit) {
    p.box(fn(b) {
      b.padding(Is((0.0, top, 0.0, 10.0))).gap(Is(8.0)) |> ignore
      body(b)
    })
    |> ignore
  }
  v.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
  v.scrolls(@view.Scroll::new(), bar=@ui.tree_scroll_bar(), fn(held) {
    held.padding(Is((18.0, 0.0, 18.0, 30.0))) |> ignore
    held.box(fn(st) {
      st.padding(Is((0.0, 2.0, 0.0, 0.0))) |> ignore
      agent_status_node(st, src, a)
    })
    |> ignore
    agent_tiles_node(held, card, 14.0, tips~)
    agent_notes_node(held, card, 10.0)
    held.box(fn(gap) { gap.height(Is(Some(6.0))) |> ignore }) |> ignore
    // How it runs is picked in the same panel as elsewhere in the app.
    run_row_node(held, a, fn(from) {
      @sfpages.open_triple_panel(src, r.station, "session:" + key, from, saved=@sf.t("web-pages.chat.pickSaved"))
    })
    rows(held, 12.0, fn(b) {
      detail(b, fn() { tr("android-chat.history.detail.runtime") }, said(fn() { text(s(), "runtimeText") }))
      b.show(at_once=true, fn() { text(s(), "processText") != "" }, fn(x) {
        detail(x, fn() { tr("android-chat.history.detail.process") }, said(fn() { text(s(), "processText") }))
      })
      // (and after it what it has going in the background and its checklist, a mark that opens them from the foot:
      // the first to give way)
      b.show(at_once=true, fn() { text(card(), "work") != "" }, fn(x) {
        detail(x, fn() { tr("android-chat.agent.history") }, fn(w) {
          w.box(fn(t) {
            @sf.style_node(t, fn() { details_turns }, in_row=true)
            t.fits(Is(true)).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(t, fn() { text(card(), "work") }, fn() { details_turns_words })
            .shrink(Is(1.0))
            .min_width(Is(Some(0.0)))
            .fit_whole(Is(true))
            |> ignore
            @sfpages.work_mark_node(t, src, r.station, key, details_turns_mark, details_turns_link, link=details_turns_link, lead=" · ", smallest=true)
          })
          |> ignore
        })
      })
    })
    held.show(at_once=true, fn() { usage().length() > 0 }, fn(u) {
      group(u, fn() { tr("android-chat.agent.usage") })
      rows(u, 6.0, fn(b) {
        b.each(fn() { Array::makei(usage().length(), fn(i) { i }) }, fn(i) { i }, fn(x, i) {
          let k = i.untracked()
          let one = fn() { usage().get(k) }
          detail(x, fn() { text(one(), "label") }, said(fn() { text(one(), "value") }))
        })
      })
    })
    group(held, fn() { "Station" })
    rows(held, 6.0, fn(b) {
      detail(b, fn() { tr("android-chat.history.detail.name") }, said(fn() {
        let name = station_name_of(src, r)
        @sfbase.shown_read(at)
        name
      }))
      b.show(at_once=true, fn() { host() is Some(Object(_)) }, fn(x) {
        detail(x, fn() { tr("android-chat.history.detail.machine") }, said(fn() { text(host(), "identity") }))
      })
    })
  })
  |> ignore
}

///|
/// Where it stands (agent_status's, as nodes) in `v`, as `a` says it now: the library's dot of its tone (tone_state) on
/// the first line's middle, its words and, muted, for how long, counting on each second from when it began.
fn agent_status_node(v : @view.View, src : Source, a : () -> Json?) -> Unit {
  let s = fn() { field(a(), "session") }
  v.box(fn(row) {
    row.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Start))) |> ignore
    // (the library's dot, in a box as tall as its words' first line at the system's size of words, across its middle)
    row.box(fn(d) {
      d
      .height(By(fn() { Some(@sf.node_sp(d, @ui.tree_theme().text_size(Meta).1)) }))
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .shrink(Is(0.0))
      |> ignore
      @sf.state_dot_node(d, fn() { tone_state(text(s(), "tone")) })
    })
    |> ignore
    // (its clock made again as what it counts from changes)
    row.pick(at_once=true, fn() { since_from(src, a()) }, fn(w, from) {
      w.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      let tick = match from {
        Some((at, till)) => @sfpages.steps_seconds(w, src, at, till?=till)
        None => fn() { 0 }
      }
      w
      .words_runs(By(fn() {
        tick() |> ignore
        let since = since_words(src, a())
        let runs = [@ui.span(text(s(), "statusText"))]
        if since != "" {
          runs.push(@ui.span(" · " + since, color=@sf.theme().p.muted))
        }
        runs
      }))
      .words_look(By(fn() { @ui.style_words(status_words) }))
      .ink(By(fn() { @ui.style_ink(status_words) }))
      |> ignore
    })
  })
  |> ignore
}

///|
/// Where its words stand: the meta's, 18 a line, in the ink.
// kept across runs: a value (no field of it changes)
let status_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg)

///|
/// When what agent `a`'s status counts from began and for how long at most it counts (ms; none: on), none when it
/// counts nothing (when it was last at it, as the core says it).
fn since_from(src : Source, a : Json?) -> (Double, Double?)? {
  let wait = field(a, "wait")
  match wait {
    Some(Object(_)) => {
      let from = number(wait, "since")
      Some((from, opt_number(wait, "seconds").map(fn(sec) { sec * second_ms })))
    }
    _ =>
      match opt_number(a, "since") {
        Some(at) => Some((at, None))
        None => {
          ignore(src)
          None
        }
      }
  }
}

///|
/// For how long agent `a` has stood where it does (agent_since's words, read at the time it is drawn): at work since
/// its turn began, waiting as long as it has (of at most), else when it was last at it.
fn since_words(src : Source, a : Json?) -> String {
  let wait = field(a, "wait")
  let since = opt_number(a, "since")
  if wait is None && since is None {
    return text(field(field(field(a, "session"), "time"), "lastActiveAt"), "ago")
  }
  let now = (src.now)()
  match wait {
    Some(Object(_)) => {
      let from = number(wait, "since")
      match opt_number(wait, "seconds") {
        Some(sec) => elapsed(dmin(now, from + sec * second_ms) - from) + " / " + elapsed(sec * second_ms)
        None => elapsed(now - from)
      }
    }
    _ => {
      let from = since.unwrap_or(now)
      elapsed(now - from)
    }
  }
}

///|
/// The figures that say most (agent_tiles', as nodes) in `v`, `top` over them, as `card` says them now: the library's
/// figures of an agent's card (@sfpages.usage_tiles_node's roomy ones: what it cost, the cache's hit rate, how full its
/// context is, each large over its name, side by side; a context worth a look in its level's colour; its tip in
/// `tips`). None while none is known.
fn agent_tiles_node(v : @view.View, card : () -> Json?, top : Double, tips? : @sf.TipLayer = @sf.TipLayer::new(fn() { None })) -> Unit {
  @sfpages.usage_tiles_node(v, card, tips, roomy=true, top~)
}


///|
/// What is wrong (agent_notes', as nodes) in `v`, `top` over it, as `card` says it now: a line each in its level's
/// colour. Nothing while nothing is.
fn agent_notes_node(v : @view.View, card : () -> Json?, top : Double) -> Unit {
  let notes = fn() { items(card(), "attention") }
  v.show(at_once=true, fn() { notes().length() > 0 }, fn(o) {
    o.box(fn(b) {
      b.padding(Is((@sf.text_in, top, @sf.text_in, 8.0))).gap(Is(2.0)) |> ignore
      b.each(fn() { Array::makei(notes().length(), fn(i) { i }) }, fn(i) { i }, fn(x, i) {
        let k = i.untracked()
        let n = fn() { notes().get(k) }
        @sf.words_node(x, fn() { text(n(), "text") }, fn() { if text(n(), "level") == "amber" { note_amber } else { note_red } })
        |> ignore
      })
    })
    |> ignore
  })
}

///|
// kept across runs: a value (no field of it changes)
let note_red : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger)

///|
// kept across runs: a value (no field of it changes)
let note_amber : @ui.TextStyle = @ui.text_style(size=Meta, color=WarnInk)

///|
// kept across runs: a value (no field of it changes)
let details_label : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let details_value : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let details_group : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// What the history's details read as they are first drawn (all but the chat's agent, the head's), each as it is read
/// by: its card, its figures, its station's machine, the stations' rows its station is named from. What 详情 pressed
/// asks first (history_node's head).
fn history_details_asks(r : ChatRef, key : String) -> Array[(String, Map[String, Json])] {
  [
    @sfpages.agent_card_ask(r.station, key),
    @sfpages.history_ask(r.station, key),
    @sfpages.history_host_ask(r.station),
    @sfbase.station_rows_ask(station_scope_of(r)),
  ]
}

///|
/// The workspace chat `r`'s station is of: its address's.
fn station_scope_of(r : ChatRef) -> String {
  match r.station.find("/") {
    Some(i) => r.station.exact_view(end=i).to_owned()
    None => r.station
  }
}

///|
/// A station's name, from the stations the app knows (its address's workspace's), else as the chat's row said it.
fn station_name_of(src : Source, r : ChatRef) -> String {
  match station_marks(src, station_scope_of(r)).iter().find_first(fn(
    s,
  ) {
    s.address == r.station
  }) {
    Some(s) => s.name
    None => r.station_name
  }
}

///|
/// How it runs, in one line (run_row's, as nodes) in `v`, as `a` says it now: the model (cut short last), how hard it
/// thinks, the account, its allowance under them; a hairline round it. `press` as it is tapped, given where it is (the
/// model picker opened beside it).
fn run_row_node(v : @view.View, a : () -> Json?, press : (@sf.Anchor) -> Unit) -> Unit {
  let s = fn() { field(a(), "session") }
  let model = fn() {
    match opt_text(s(), "model") {
      Some(m) =>
        match text(s(), "modelName") {
          "" => m
          n => n
        }
      None => tr("android-chat.pick.model")
    }
  }
  let rest = fn() {
    let name = text(field(a(), "account"), "name")
    let effort = match text(s(), "effort") {
      "" => tr("android-chat.pick.effort.default")
      e => e
    }
    let account = if flag(s(), "profilePinned") { name } else { fill("android-chat.history.run.auto", [("name", name)]) }
    " · " + effort + " · " + account
  }
  let quota = fn() { field(field(a(), "account"), "quota") }
  v.box(fn(o) {
    o.padding(Is((0.0, 6.0, 0.0, 0.0))) |> ignore
    o.box(fn(b) {
      b
      .row(Is(true))
      .padding(Is((12.0, 10.0, 12.0, 10.0)))
      .gap(Is(6.0))
      .radius(Is(10.0))
      .edge(By(fn() { (1.0, @sf.theme().p.line) }))
      .lines_up(Is(Some(Middle)))
      |> ignore
      @sf.presses_node(b, fn() {
        let (x, y, w, h) = b.placed_window_now()
        press(At(x, y, w, h))
      })
      b.says(By(fn() { Some(@view.said(Button, label=model() + rest())) })) |> ignore
      b.pick(at_once=true, fn() { (text(field(s(), "maker"), "id"), text(s(), "runtime")) }, fn(m, k) {
        @sf.maker_mark_node(m, k.0, k.1, 15.0) |> ignore
      })
      // how it runs on its line, its account's allowance under it, a line of its own
      b.box(fn(w) {
        w.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        // (the model's name whole, what follows it giving way first: cut short itself only beside the least of that)
        @sf.name_line_node(w, model, fn() { run_model }, rest, fn() { run_rest }) |> ignore
        w.show(at_once=true, fn() { @sf.has_quota(quota()) }, fn(q) {
          q.row(Is(true)).padding(Is((0.0, 4.0, 0.0, 0.0))) |> ignore
          @sf.quota_chips_node(q, quota)
        })
      })
      |> ignore
      @sf.icon_node(b, "chevron-down", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let run_model : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let run_rest : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
/// The boxes of a step drawn so far, numbered for where each is scrolled to (within the step's scope).
let boxed_n : Ref[Int] = { val: 0 }

///|
/// The steps' parts as the core read them (`history.tool`), by what was asked.
let tool_parts : Map[String, Json] = Map([])

///|
/// Its turns' value with the mark of its work past its turns after it (work_mark): one line, its words cut short only
/// once the mark has given way.
// kept across runs: a value (no field of it changes)
let details_turns : @ui.Style = @ui.style(row=true, w=@sf.grow, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let details_turns_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let details_turns_link : @ui.TextStyle = @ui.text_style(size=Meta, color=Link, wrap=false)

///|
/// The mark after them: quieter than them (12, muted), a link's ink under the finger.
// kept across runs: a value (no field of it changes)
let details_turns_mark : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)
