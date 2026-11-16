// How a chat's agent runs (RunSettingsScreen) made once as nodes of the window's tree, one page in every frame
// (page_node): what it is now and what it becomes, then each of what it runs as picked in the core's `pick` of
// `session:<key>`; its models and its accounts each a list of its own in the page's place (run_list), back from it to the
// page.

///|
/// How an agent runs (RunSettingsScreen) in node `v`, the session `key` on `station`: what it is now and what it
/// becomes, the changes marked (and why its account must change, when it must); then the model, how hard it thinks, how
/// fast and who runs it, each picked in the core's `pick` (`pick.set`); its button at its foot saying what it becomes
/// (不变 when nothing changed) and saving it (`pick.save`), or, another station's model, borrowing it once asked again.
/// The model and the accounts are each picked in a list of its own in the page's place (back, the system's too, to the
/// page); while it is read, a made-up agent's in its bones.
pub fn run_settings_node(
  v : @view.View,
  core : Core,
  station : String,
  key : String,
  on_back~ : () -> Unit,
  frame~ : () -> @sf.PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let of = "session:" + key
  let topic = fn() { (core.topic)("pick", { "station": str(station), "of": str(of) }).get() }
  let view = fn() { topic().value }
  let pick = fn(more : Array[(String, Json)]) { run_pick(core, station, of, more) }
  // picked from what it runs on now, each time it is opened
  if !run_opened.contains(of) {
    run_opened[of] = true
    pick([("open", Json::boolean(true))])
  }
  let list = fn() { run_list.get(of).unwrap_or("") }
  let leave_list = fn() {
    if @signals.untracked(list) == "account" && field(field(@signals.untracked(view), "draft"), "profiles") is Some(Array(xs)) && xs.is_empty() {
      pick([("open", Json::boolean(false))])
    }
    run_list.remove(of)
  }
  // (in a list: back, the bar's and the system's, to the page)
  v.show(fn() { list() != "" }, fn(s) { s.takes_back(leave_list) |> ignore })
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  // (its list at its top as the page and its own lists change places: each a list of its own from its head)
  let scroll = @view.Scroll::list()
  v.reacts(list, fn(_) { scroll.put(0.0) })
  // (its button pinned under its list, not scrolling with it, while the page shows what it picks: run_foot_node; there
  // at once with what the page shows, as its list changes for a model's or an account's at once (page_node's), never
  // making its way up after it: the page's change seen twice, switches_still's screen 32)
  let footed = fn() { list() == "" && view() is Some(_) }
  let body = v.box(fn(_) {  })
  v.show(footed, at_once=true, fn(f) { run_foot_node(f, core, station, of, view, frame) })
  @sf.page_node(
    body,
    fn() {
      match list() {
        "model" => tr("android-chat.pick.model")
        "account" => tr("android-chat.run.account.choose")
        _ => tr("android-chat.run.title")
      }
    },
    on_back=fn() { if @signals.untracked(list) != "" { leave_list() } else { on_back() } },
    frame=fn() {
      let f = frame()
      if list() != "" {
        { ..f, back: Some(tr("android-chat.run.title")) }
      } else if footed() {
        // (the frame's room at its foot the button's, under it)
        { ..f, foot: 0.0 }
      } else {
        f
      }
    },
    said?,
    width?,
    tips?,
    scroll~,
    fn() {
      match (list(), view()) {
        (_, None) => ["waiting"]
        ("model", v) => run_model_keys(v)
        ("account", v) => run_account_keys(v)
        (_, v) => run_keys(v)
      }
    },
    fn(b, k) {
      match k {
        "waiting" =>
          @sf.waiting_node(b, fill=true, error=fn() { topic().error.map(error_text).unwrap_or("") }, fn(s) {
            let sample = Some(run_sample())
            s.each(fn() { run_keys(sample) }, fn(k) { k }, fn(sb, k) {
              run_block(sb, of, fn() { sample }, fn(_) {  }, k.untracked())
            })
          })
        k if k.has_prefix("m/") || k.has_prefix("g/") || k == "filter" || k == "none" =>
          run_model_block(b, view, k, fn(m) {
            pick([("model", str(m))])
            run_list.remove(of)
          })
        k if k.has_prefix("a/") || k == "auto" || k == "account-note" => run_account_block(b, core, station, of, view, pick, k)
        k => run_block(b, of, view, pick, k)
      }
    },
  )
}

///|
/// What is picked told to the core (`pick.set`, of `of` on `station`); failed, a toast says why.
fn run_pick(core : Core, station : String, of : String, more : Array[(String, Json)]) -> Unit {
  let p = [("station", str(station)), ("of", str(of))]
  for x in more {
    p.push(x)
  }
  (core.call)("pick.set", obj(p), fn(r) {
    match r {
      Ok(_) => ()
      Err(e) => (core.say)(fill("android-chat.pick.failed", [("error", error_text(e))]))
    }
  })
}

///|
/// The run page's blocks as the core's `pick` (`v`) says it: what it was and becomes ("changes"), its model, its runtime
/// where it may change, how hard it thinks, how fast where it may be fast, who runs it (its button under the page,
/// run_foot_node).
fn run_keys(v : Json?) -> Array[String] {
  let out = ["changes", "model"]
  if !flag(v, "runtimeFixed") && strings(v, "runtimes").length() > 1 {
    out.push("runtime")
  }
  out.push("effort")
  if flag(v, "fastAvailable") {
    out.push("speed")
  }
  out.push("account")
  out
}

///|
/// The run page's block `k` (run_keys') in `b`, as the core's `pick` (`v`) says it now; what is picked told by `pick`.
fn run_block(
  b : @view.View,
  of : String,
  v : () -> Json?,
  pick : (Array[(String, Json)]) -> Unit,
  k : String,
) -> Unit {
  let draft = fn() { field(v(), "draft") }
  let runtime = fn() { text(draft(), "runtime") }
  // (a heading over what it picks, and what it means under it where it says)
  let head = fn(title : String, note : String) { @sf.section_heading_node(b, fn() { tr(title) }, note?=if note == "" { None } else { Some(fn() { tr(note) }) }) }
  match k {
    // what it was and what it becomes, a line each property, the changes marked
    "changes" =>
      @sf.page_card_node(b, fn(card) {
        let lines = fn() {
          let v = v()
          let labels = [tr("android-chat.run.label.model"), tr("android-chat.run.label.effort"), tr("android-chat.run.label.account")]
          if flag(v, "fastAvailable") {
            labels.push(tr("android-chat.run.label.speed"))
          }
          let was = strings(v, "was")
          let becomes = strings(v, "becomes")
          let rt = text(field(v, "draft"), "runtime")
          if !flag(v, "runtimeFixed") && rt != text(field(v, "value"), "runtime") {
            labels.push(@sf.t("web-main.model.runtime"))
            was.push(runtime_label(text(field(v, "value"), "runtime")))
            becomes.push(runtime_label(rt))
          }
          labels.mapi(fn(i, l) { (l, was.get(i).unwrap_or(""), becomes.get(i).unwrap_or("")) })
        }
        card.each(fn() { lines().mapi(fn(i, _) { i }) }, fn(i) { i }, fn(row, i) {
          let line = fn() { lines().get(i.get()).unwrap_or(("", "", "")) }
          let moved = fn() { line().2 != line().1 }
          @sf.style_node(row, fn() { run_line })
          row.box(fn(l) {
            l.width(By(fn() { Some(@sf.node_sp(l, run_label_w)) })).shrink(Is(0.0)) |> ignore
            @sf.words_node(l, fn() { line().0 }, fn() { run_label }) |> ignore
          })
          |> ignore
          @sf.words_node(row, fn() { line().1 }, fn() { if moved() { run_was_moved } else { run_was } }) |> ignore
          row.show(moved, fn(m) {
            m.row(Is(true)).gap(Is(run_line_gap)).lines_up(Is(Some(Middle))).grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            @sf.icon_node(m, "arrow-right", run_arrow, By(fn() { @sf.theme().p.accent })) |> ignore
            @sf.words_node(m, fn() { line().2 }, fn() { run_becomes }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          })
        })
        card.show(fn() { opt_text(v(), "force") is Some(_) }, fn(f) { @sf.words_node(f, fn() { text(v(), "force") }, fn() { run_force }) |> ignore })
        @sf.words_node(card, fn() { tr("android-chat.run.next") }, fn() { run_next }) |> ignore
      })
    "model" =>
      @sf.section_node(b, fn() { tr("android-chat.run.label.model") }, fn(s) {
        @sf.group_node(s, fn(g) {
          @sf.link_row_node(g, fn() { text(v(), "modelText") }, fn() { run_list[of] = "model" }, lead=LeadLine(fn(l) {
            l.pick(fn() { (text(field(v(), "maker"), "id"), runtime()) }, fn(m, mk) { @sf.maker_mark_node(m, mk.0, mk.1, run_mark) |> ignore })
          }))
        })
      })
    "runtime" => {
      let label = @sf.t("web-main.model.runtime")
      @sf.section_node(b, fn() { label }, fn(s) {
        @sf.group_node(s, fn(g) {
          @sf.link_row_opens_node(g, fn() { runtime_label(runtime()) }, fn(row) {
            @sf.pick(
              label,
              strings(@signals.untracked(v), "runtimes").map(fn(r) { @sf.choice(r, runtime_label(r), icon="runtime:" + r) }),
              @signals.untracked(runtime),
              fn(r) { pick([("runtime", str(r))]) },
              from=Node(row),
            )
          })
        })
      })
    }
    "effort" => {
      head("android-chat.run.effort.title", "android-chat.run.effort.note")
      let default = tr("android-chat.pick.default")
      run_chips_node(b, fn() { [default] + strings(v(), "efforts") }, fn() {
        match text(draft(), "effort") {
          "" => default
          e => e
        }
      }, fn(e) { pick([("effort", if e == default { Json::null() } else { str(e) })]) })
    }
    "speed" => {
      head("android-chat.run.label.speed", "android-chat.run.speed.note")
      let as_plan = tr("android-chat.pick.speed.follow")
      let standard = tr("android-chat.pick.speed.standard")
      run_chips_node(b, fn() { [as_plan, standard, "Fast"] }, fn() {
        match field(draft(), "fast") {
          Some(True) => "Fast"
          Some(False) => standard
          _ => as_plan
        }
      }, fn(s) { pick([("fast", if s == "Fast" { Json::boolean(true) } else if s == standard { Json::boolean(false) } else { Json::null() })]) })
    }
    "account" =>
      @sf.section_node(b, fn() { tr("android-chat.run.label.account") }, fn(s) {
        @sf.group_node(s, fn(g) {
          @sf.link_row_node(
            g,
            fn() { text(v(), "accountText") },
            fn() { run_list[of] = "account" },
            note=fn() { text(v(), "accountNote") },
            trouble=fn() { if flag(v(), "accountWarn") { tr("android-chat.run.account.warn") } else { "" } },
          )
        })
      })
    _ => ()
  }
}

///|
/// One of a few, as wide as their words, in lines where they do not fit one (History.kt EffortChips: 8 apart each way),
/// in `b`: `options()` each a chip, the one `chosen()` lit; `choose` told the one pressed.
fn run_chips_node(b : @view.View, options : () -> Array[String], chosen : () -> String, choose : (String) -> Unit) -> Unit {
  // (under its heading, on the page's ground: as far in as the heading's words narrow, flush with it wide)
  @sf.under_heading_node(b, fn(u) {
    u.box(fn(r) {
      @sf.style_node(r, fn() { run_chips })
      r.wraps(Is(Some(run_chips_gap))) |> ignore
      r.each(fn() { options() }, fn(o) { o }, fn(c, o) {
        let o = o.untracked()
        @sf.choice_chip_node(c, fn() { o }, fn() { chosen() == o }, fn() { choose(o) }) |> ignore
      })
    })
    |> ignore
  })
}

///|
/// Who runs the model's list's blocks (account_list's, as nodes), by the core's `pick` (`v`): what 全选 and
/// multi-account mean ("account-note"), 全选 ("auto"), each account ("a/<id>").
fn run_account_keys(v : Json?) -> Array[String] {
  ["account-note", "auto"] + items(v, "accounts").map(fn(a) { "a/" + text(Some(a), "id") })
}

///|
/// Whether block `k` of who runs the model is a row of its card (全选 or an account).
fn run_account_row(k : String) -> Bool {
  k == "auto" || k.has_prefix("a/")
}

///|
/// The piece of its card block `k` is among `keys`: the run of blocks around it that `row` says are rows of one card.
fn run_piece(keys : Array[String], k : String, row : (String) -> Bool) -> @sf.CardPiece {
  let mut at = -1
  for i, x in keys {
    if x == k {
      at = i
      break
    }
  }
  if at < 0 {
    return @sf.CardPiece::CardWhole
  }
  let mut first = at
  while first > 0 && row(keys[first - 1]) {
    first = first - 1
  }
  let mut last = at
  while last + 1 < keys.length() && row(keys[last + 1]) {
    last = last + 1
  }
  @sf.card_piece_of(at - first, last - first + 1)
}

///|
/// The models' list's blocks (model_list's, as nodes), by the core's `pick` (`v`): a field to filter them by where
/// there are more than 8 ("filter"), a series' name over its models where there is more than one series ("g/<series>"),
/// each model ("m/<model>"), what is said where none matches ("none").
fn run_model_keys(v : Json?) -> Array[String] {
  let models = items(v, "options")
  let find = run_model_find.text().trim(chars=" ").to_owned().to_lower()
  let out : Array[String] = []
  if models.length() > 8 {
    out.push("filter")
  }
  let shown = models.filter(fn(m) {
    let mv = Some(m)
    find == "" || [text(mv, "name"), text(mv, "model"), ..strings(mv, "ids")].iter().any(fn(w) { w.to_lower().contains(find) })
  })
  let groups : Array[(String, Array[Json])] = []
  for m in shown {
    let who = match text(Some(m), "family") {
      "" => tr("android-chat.pick.family.other")
      f => f
    }
    match groups.search_by(fn(g) { g.0 == who }) {
      Some(i) => groups[i].1.push(m)
      None => groups.push((who, [m]))
    }
  }
  for g in groups {
    if groups.length() > 1 {
      out.push("g/" + g.0)
    }
    for m in g.1 {
      out.push("m/" + text(Some(m), "model"))
    }
  }
  if shown.length() == 0 {
    out.push("none")
  }
  out
}

///|
/// What the models' list is filtered by (its field's words, the person's).
// kept across runs: what the field holds; the settings' reset empties it
let run_model_find : @ui.Field = @ui.Field::new()

///|
/// A block `k` of the models' list (run_model_keys') in `b`, as the core's `pick` (`v`) says it now: `chosen` told the
/// model pressed.
fn run_model_block(b : @view.View, v : () -> Json?, k : String, chosen : (String) -> Unit) -> Unit {
  match k {
    "filter" =>
      b.box(fn(f) {
        @sf.style_node(f, fn() { run_filter_room })
        @sf.input_node(f, run_model_find, placeholder=tr("android-chat.run.model.search"), label=tr("android-chat.run.model.search")) |> ignore
      })
      |> ignore
    "none" => @sf.page_note_node(b, fn() { tr("android-chat.run.model.none") })
    k if k.has_prefix("g/") => @sf.section_heading_node(b, fn() { k.exact_view(start=2).to_owned() })
    k => {
      let model = k.exact_view(start=2).to_owned()
      let mv = fn() { items(v(), "options").iter().find_first(fn(m) { text(Some(m), "model") == model }) }
      let runtime = fn() { text(field(v(), "draft"), "runtime") }
      let on = fn() {
        match model_option_of(items(v(), "options"), text(v(), "option")) {
          Some(o) => text(Some(o), "model") == model
          None => false
        }
      }
      // not usable here till borrowed: its name in the muted grey, until it is the one picked
      let faint = fn() { text(mv(), "availability") == "borrowable" && !on() }
      let from = fn() { field(mv(), "fromStation") }
      // (a series' models on one card, each a piece of it: the card's top, between or foot as the list now says)
      @sf.card_piece_node(b, fn() { run_piece(run_model_keys(v()), k, fn(x) { x.has_prefix("m/") }) }, wide_group=true, fn(g) {
        @sf.choice_row_node(
          g,
          fn() { text(mv(), "name") },
          on,
          press=fn() { chosen(model) },
          ink=fn() { if faint() { @sf.theme().p.muted } else { @sf.theme().p.text } },
          lead=fn(l) { l.pick(fn() { (text(field(mv(), "maker"), "id"), runtime()) }, fn(m, mk) { @sf.maker_mark_node(m, mk.0, mk.1, run_mark) |> ignore }) },
          tag=fn(t) {
            t.show(fn() { from() is Some(Object(_)) }, fn(s) {
              s.pick(fn() { @sf.has_station_mark(text(from(), "emoji"), text(from(), "icon")) }, fn(p, marked) {
                if marked {
                  @sf.station_mark_node(p, fn() { text(from(), "emoji") }, fn() { text(from(), "icon") }, run_from_mark, fn() { @sf.theme().p.muted }, fn() { 0 })
                } else {
                  @sf.words_node(p, fn() { text(from(), "name") }, fn() { model_from_words }) |> ignore
                }
              })
            })
          },
        )
      })
    }
  }
}

///|
/// A block `k` of who runs the model picked (account_list's, as nodes), in `b`, as the core's `pick` (`v`) says it now:
/// what 全选 and multi-account mean ("account-note"); 全选 ("auto": the station's pool; tapped again, 全不选, waiting for
/// one account to be tapped; beside it, the station picking its account again now where it says so); each account it
/// may be kept to ("a/<id>"), its provider's mark before it and its allowance after it. What is chosen told by `pick`.
fn run_account_block(
  b : @view.View,
  core : Core,
  station : String,
  of : String,
  v : () -> Json?,
  pick : (Array[(String, Json)]) -> Unit,
  k : String,
) -> Unit {
  let accounts = fn() { items(v(), "accounts") }
  let runtime = fn() { text(field(v(), "draft"), "runtime") }
  let all_ids = fn() { accounts().map(fn(x) { text(Some(x), "id") }).filter(fn(x) { x != "" }) }
  let single_only = fn() { accounts().length() <= 1 }
  let picked = fn() -> Array[String]? {
    let draft = field(v(), "draft")
    match field(draft, "profiles") {
      Some(Array(xs)) => {
        let out : Array[String] = []
        for x in xs {
          if x is String(s) && s != "" && !out.contains(s) {
            out.push(s)
          }
        }
        Some(out)
      }
      _ =>
        match text(draft, "profile") {
          "" => None
          id => Some([id])
        }
    }
  }
  let choose = fn(ids : Array[String]?) {
    match ids {
      None => pick([("profiles", Json::null()), ("profile", Json::null())])
      Some(xs) => pick([("profiles", Json::array(xs.map(fn(s) { str(s) })))])
    }
  }
  match k {
    "account-note" =>
      // (a step of the scale over the card under it)
      b.box(fn(n) {
        @sf.style_node(n, fn() { run_note_room })
        @sf.page_note_node(n, fn() { tr("android-chat.run.account.note") })
      })
      |> ignore
    "auto" =>
      // (全选 and each account on one card, each a piece of it)
      @sf.card_piece_node(b, fn() { run_piece(run_account_keys(v()), k, run_account_row) }, wide_group=true, fn(g) {
        @sf.choice_row_node(
          g,
          fn() { tr("android-chat.run.account.auto") },
          fn() { picked() is None },
          press=fn() {
            if !@signals.untracked(single_only) {
              choose(if @signals.untracked(picked) is None { Some([]) } else { None })
            }
          },
          note=fn() { if picked() is Some([]) { text(v(), "autoNote") } else { "" } },
          disabled=single_only,
          trail=fn(t) {
            // beside 全选: the station picks its account again now (`pick.repick`), which it took said
            t.show(fn() { text(v(), "repick") != "" }, fn(s) {
              @sf.button_node(
                s,
                fn() { text(v(), "repick") },
                fn() {
                  let repick = text(@signals.untracked(v), "repick")
                  (core.call)("pick.repick", obj([("station", str(station)), ("of", str(of))]), fn(r) {
                    match r {
                      Ok(said) =>
                        match text(Some(said), "said") {
                          "" => ()
                          words => (core.say)(words)
                        }
                      Err(e) => (core.say)(fill("android-misc.act.failed", [("what", repick), ("error", error_text(e))]))
                    }
                  })
                },
                busy=fn() { is_doing(core, ["pick.repick"], [("station", station), ("of", of)]) },
              )
              |> ignore
            })
          },
        )
      })
    k => {
      let id = k.exact_view(start=2).to_owned()
      let av = fn() { accounts().iter().find_first(fn(a) { text(Some(a), "id") == id }) }
      @sf.card_piece_node(b, fn() { run_piece(run_account_keys(v()), k, run_account_row) }, wide_group=true, fn(g) {
        @sf.choice_row_node(
          g,
          fn() { text(av(), "name") },
          fn() {
            match picked() {
              None => true
              Some(xs) => xs.contains(id)
            }
          },
          press=fn() {
            if @signals.untracked(single_only) {
              return
            }
            let all = @signals.untracked(all_ids)
            let now = match @signals.untracked(picked) {
              None => all
              Some(xs) => xs
            }
            if now.contains(id) {
              choose(Some(now.filter(fn(x) { x != id })))
            } else {
              let next = all.filter(fn(x) { x == id || now.contains(x) })
              choose(if next.length() >= all.length() { None } else { Some(next) })
            }
          },
          disabled=single_only,
          lead=fn(l) {
            l.pick(fn() { (text(av(), "runtime"), text(av(), "kind"), text(av(), "mark"), runtime()) }, fn(m, a) {
              @sf.provider_logo_node(m, if a.0 == "" { a.3 } else { a.0 }, a.1, run_mark, a.2) |> ignore
            })
          },
          // (its allowance at the row's end, before its check: its name keeps its line)
          trail=fn(t) { @sf.quota_chips_node(t, fn() { field(av(), "quota") }, marked=false, gap=run_quota_gap) },
        )
      })
    }
  }
}

///|
/// What it was and becomes, a line each (8 apart, across their middle).
// kept across runs: a value (no field of it changes)
let run_line : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
let run_line_gap : Double = 8.0

///|
/// The labels' column (as wide as the longest of them at the system's size of words: 模型, 思考强度, Runtime).
let run_label_w : Double = 64.0

///|
// kept across runs: a value (no field of it changes)
let run_was : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let run_was_moved : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let run_becomes : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=AccentText, wrap=false, w=Cut)

///|
let run_arrow : Double = 14.0

///|
// kept across runs: a value (no field of it changes)
let run_force : @ui.TextStyle = @ui.text_style(size=Caption, color=WarnInk, w=Full)

///|
// kept across runs: a value (no field of it changes)
let run_next : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, w=Full)

///|
/// A maker's or a provider's mark before a row's words.
let run_mark : Double = 18.0

///|
/// A station's mark after a model from another station.
let run_from_mark : Double = 14.0

///|
let run_quota_gap : Double = 6.0

///|
let run_chips_gap : Double = 8.0

///|
/// The chips' line (8 apart), as far in as the page's blocks.
// kept across runs: a value (no field of it changes)
let run_chips : @ui.Style = @ui.css("row w=Full gap=S2")

///|
/// The filter's room: 8 over it and 4 under.
// kept across runs: a value (no field of it changes)
let run_filter_room : @ui.Style = @ui.css("w=Full pt=S2 pb=S1")

///|
/// The button's block: what is said of borrowing over it, 12 apart.
// kept across runs: a value (no field of it changes)
let run_foot : @ui.Style = @ui.css("w=Full gap=S3")

///|
// kept across runs: a value (no field of it changes)
let run_borrow_note : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, w=Full)

///|
/// What 全选 and multi-account mean, a step of the scale over the accounts' card.
// kept across runs: a value (no field of it changes)
let run_note_room : @ui.Style = @ui.css("w=Full pb=S3")

///|
/// The run page's button in `f`, pinned under its list (RunSettingsScreen's foot: in a panel of its own, each end in
/// the foot corner it is in concentric with it, foot_capsule), as the core's `pick` (`v`) says it: the model picked
/// another station's, said so over the button, which borrows it (asked again); else what it becomes, saved.
fn run_foot_node(f : @view.View, core : Core, station : String, of : String, v : () -> Json?, frame : () -> @sf.PageFrame) -> Unit {
  f.padding(By(fn() {
    let (l, r, b) = @sf.foot_capsule(run_button_h, run_foot_side, run_foot_side)
    (l, run_foot_side, r, b + frame().foot)
  }))
  |> ignore
  f.pick(fn() { field(v(), "borrow") is Some(Object(_)) }, fn(p, borrows) {
    @sf.style_node(p, fn() { run_foot })
    if borrows {
      let borrow = fn() { field(v(), "borrow") }
      let allowed = fn() { flag(borrow(), "allowed") }
      @sf.words_node(p, fn() { if allowed() { text(borrow(), "note") } else { opt_text(borrow(), "why").unwrap_or(text(borrow(), "note")) } }, fn() {
        run_borrow_note
      })
      |> ignore
      p.pick(allowed, fn(w, allowed) {
        @sf.wide_button_node(w, fn() { text(borrow(), "action") }, fn() { confirm_borrow(core, station, of, @signals.untracked(borrow)) }, allowed, busy=fn() {
          is_doing(core, ["pick.borrow"], [("station", station), ("of", of)])
        }, enabled=fn() { allowed })
        |> ignore
      })
    } else {
      p.pick(fn() { flag(v(), "changed") }, fn(w, changed) {
        @sf.wide_button_node(
          w,
          fn() { text(v(), "saveText") },
          fn() {
            let go = @signals.untracked(fn() {
              flag(v(), "changed") && has(v(), "option") && !is_doing(core, ["pick.save"], [("station", station), ("of", of)])
            })
            // back at once, not waiting on the station; failed, a toast says why
            (core.pop)()
            if go {
              (core.call)("pick.save", obj([("station", str(station)), ("of", str(of))]), fn(r) {
                match r {
                  Ok(_) => (core.say)(tr("android-chat.run.saved"))
                  Err(e) => (core.say)(fill("android-chat.save.failed", [("error", error_text(e))]))
                }
              })
            }
          },
          changed,
          busy=fn() { is_doing(core, ["pick.save"], [("station", station), ("of", of)]) },
        )
        |> ignore
      })
    }
  })
}

///|
/// The run page's button's height (the settings' wide_button_h), and how far in it stands where no corner says.
let run_button_h : Double = 46.0

///|
let run_foot_side : Double = 12.0
