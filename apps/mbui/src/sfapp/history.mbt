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
  // (its facts' labels, each list's the same, so their labels' column is as wide in each: @sf.facts_list_node's, 76
  // at least; a figure's label the core's, in that column too)
  let labels = [
    tr("android-chat.history.detail.runtime"),
    tr("android-chat.history.detail.process"),
    tr("android-chat.agent.history"),
    tr("android-chat.history.detail.name"),
    tr("android-chat.history.detail.machine"),
  ]
  // its facts, `top` over them, 10 under them: a fact a row each, what it says beside its label
  let facts = fn(p : @view.View, top : Double, body : (@sf.FactsList) -> Unit) {
    @sf.facts_list_node(p, labels, least=details_label_w, style=fn() { @ui.style(w=Full, pt=@sf.room_of(top), pb=S2_5) }, body)
    |> ignore
  }
  let said = fn(words : () -> String) {
    fn(w : @view.View) {
      @sf.words_node(w, words, fn() { details_value }).grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0)))
      |> ignore
    }
  }
  let group = fn(p : @view.View, name : () -> String) {
    p.box(fn(g) {
      g.padding(Is((0.0, 14.0, 0.0, 4.0))) |> ignore
      @sf.words_node(g, name, fn() { details_group }) |> ignore
    })
    |> ignore
  }
  v.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
  v.scrolls(@view.Scroll::new(), bar=@ui.tree_scroll_bar(), fn(held) {
    held.padding(Is((18.0, 0.0, 18.0, 30.0))) |> ignore
    held.box(fn(st) {
      st.padding(Is((0.0, 2.0, 0.0, 0.0))) |> ignore
      @sfpages.agent_status_node(st, src, a)
    })
    |> ignore
    agent_tiles_node(held, card, 14.0, tips~)
    agent_notes_node(held, card, 10.0)
    held.box(fn(gap) { gap.height(Is(Some(6.0))) |> ignore }) |> ignore
    // How it runs is picked in the same panel as elsewhere in the app.
    run_row_node(held, a, fn(from) {
      @sfpages.open_triple_panel(src, r.station, "session:" + key, from, saved=@sf.t("web-pages.chat.pickSaved"))
    })
    facts(held, 12.0, fn(b) {
      @sf.fact_row_node(b, labels[0], said(fn() { text(s(), "runtimeText") }))
      @sf.fact_row_node(b, labels[1], said(fn() { text(s(), "processText") }), show=fn() { text(s(), "processText") != "" })
      // (and after it what it has going in the background and its checklist, a mark that opens them from the foot:
      // the first to give way)
      @sf.fact_row_node(
        b,
        labels[2],
        fn(w) {
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
        },
        show=fn() { text(card(), "work") != "" },
      )
    })
    held.show(at_once=true, fn() { usage().length() > 0 }, fn(u) {
      group(u, fn() { tr("android-chat.agent.usage") })
      // (its figures, as many as the core has, each labelled as it says: a row each as a fact's is, its label in the
      // column the facts' labels are, as @sf.facts_list_node measures it, at the default size of words 76)
      u.box(fn(b) {
        b.padding(Is((0.0, 6.0, 0.0, 10.0))) |> ignore
        let label_w = fn(n : @view.View) {
          n.words_redone() |> ignore
          let size = @sf.theme().t.ui * n.words_scale()
          labels.fold(init=details_label_w, fn(m, l) { dmax(m, @ui.text_advance(l, size~).ceil()) })
        }
        b.each(fn() { Array::makei(usage().length(), fn(i) { i }) }, fn(i) { i }, fn(x, i) {
          let k = i.untracked()
          let one = fn() { usage().get(k) }
          // (the row in its slot: as tall as a fact's at least, by what it holds)
          x.box(fn(f) {
            @sf.style_node(f, fn() { details_figure })
            @sf.words_node(f, fn() { text(one(), "label") }, fn() { details_figure_label })
            .width(By(fn() { Some(label_w(f)) }))
            .shrink(Is(0.0))
            |> ignore
            said(fn() { text(one(), "value") })(f)
          })
          |> ignore
        })
      })
      |> ignore
    })
    group(held, fn() { "Station" })
    facts(held, 6.0, fn(b) {
      @sf.fact_row_node(b, labels[3], said(fn() {
        let name = @sfpages.history_station_name(src, r.station, r.station_name)
        @sfbase.shown_read(at)
        name
      }))
      @sf.fact_row_node(b, labels[4], said(fn() { text(host(), "identity") }), show=fn() { host() is Some(Object(_)) })
    })
  })
  |> ignore
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
fn agent_notes_node(
  v : @view.View,
  card : () -> Json?,
  top : Double,
  px? : Double = @sf.text_in,
  pb? : Double = 8.0,
) -> Unit {
  let notes = fn() { items(card(), "attention") }
  v.show(at_once=true, fn() { notes().length() > 0 }, fn(b) {
    b.padding(Is((px, top, px, pb))).gap(Is(2.0)) |> ignore
    b.each(fn() { Array::makei(notes().length(), fn(i) { i }) }, fn(i) { i }, fn(x, i) {
      let k = i.untracked()
      let n = fn() { notes().get(k) }
      @sf.words_node(x, fn() { text(n(), "text") }, fn() { if text(n(), "level") == "amber" { note_amber } else { note_red } })
      |> ignore
    })
  })
}

///|
// kept across runs: a value (no field of it changes)
let note_red : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger)

///|
// kept across runs: a value (no field of it changes)
let note_amber : @ui.TextStyle = @ui.text_style(size=Meta, color=WarnInk)

///|
/// The details' labels' column (as @sf.facts_list_node makes it: as wide as the widest label, this at least), a
/// figure's row across it.
let details_label_w : Double = 76.0

///|
/// A figure's row (a fact's, as @sf.facts_list_node lays it out): 28 high at least, its label and its value 12 apart
/// across its middle; its label as a fact's is (13, muted).
// kept across runs: a value (no field of it changes)
let details_figure : @ui.Style = @ui.style(row=true, w=Full, min_h=Fixed(@sf.fact_row_h), gap=S3, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let details_figure_label : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let details_value : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let details_group : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

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
  let plan = fn() { text(field(a(), "account"), "planText") }
  v.box(fn(o) {
    o.padding(Is((0.0, 6.0, 0.0, 0.0))) |> ignore
    @sf.action_box_node(o, fn() { @settings.join([model() + rest(), plan()], " · ") }, fn(b) {
      let (x, y, w, h) = b.placed_window_now()
      press(At(x, y, w, h))
    }, fn(b) {
      b
      .row(Is(true))
      .padding(Is((12.0, 10.0, 12.0, 10.0)))
      .gap(Is(6.0))
      .radius(Is(@sf.row_corner))
      .edge(By(fn() { (1.0, @sf.theme().p.line) }))
      .lines_up(Is(Some(Start)))
      |> ignore
      @sf.first_line_node(b, Ui, fn(l) {
        l.pick(at_once=true, fn() { (text(field(s(), "maker"), "id"), text(s(), "runtime")) }, fn(m, k) {
          @sf.maker_mark_node(m, k.0, k.1, 15.0) |> ignore
        })
      })
      |> ignore
      // how it runs on its line, its account's allowance under it, a line of its own
      b.box(fn(w) {
        w.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        // (the model's name whole, what follows it giving way first: cut short itself only beside the least of that)
        // (its account's tier after the line, as a profile row's title_after: the line giving way first)
        w.box(fn(line) {
          line.row(Is(true)).lines_up(Is(Some(Middle))).min_width(Is(Some(0.0))) |> ignore
          @sf.name_line_node(line, model, fn() { run_model }, rest, fn() { run_rest }).shrink(Is(1.0)) |> ignore
          line.show(fn() { plan() != "" }, fn(a) {
            a.margin(Is((8.0, 0.0, 0.0, 0.0))) |> ignore
            @sf.row_tag_node(a, plan)
          })
        })
        |> ignore
        w.show(at_once=true, fn() { @sfbase.has_quota(quota()) }, fn(q) {
          q.row(Is(true)).padding(Is((0.0, 4.0, 0.0, 0.0))) |> ignore
          @sfbase.quota_chips_node(q, quota)
        })
      })
      |> ignore
      @sf.first_line_node(b, Ui, fn(l) {
        @sf.icon_node(l, "chevron-down", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
      })
      |> ignore
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
/// Its turns' value with the mark of its work past its turns after it (work_mark_node): one line, its words cut short only
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
