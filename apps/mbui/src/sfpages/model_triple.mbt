// The one way a model is chosen (still.fail web/src/ModelTriple.tsx, ModelTriple.css.ts; NewChat.kt's run picker said the
// same): a control that says the model, the runtime (where it can still change and the model runs on more than one),
// how hard it thinks and who runs it, in one line; pressed, its panel through the presenters (beside it with keyboard and mouse,
// a sheet with touch): the configurations used most here nearest what opened it (a model with how it runs, the core's
// `combos`), then the starred models, each saying how it runs picked (as it last ran here), the rest past them (a
// filter over them when there are many); between them and it the runtime, the
// effort and the speed, every name whole; at its foot who runs it (the accounts in a panel of their own, from it).
// Its rows are the screen's (Theme::rows pick). Each pick is made what it runs on as it is picked (`pick.save`), a
// model closing the panel; a model another station has is drafted (`pick.set`) and borrowed first, asked in a dialog.
//
// Laid out by use, not by our controls (the user, 2026-10-30: 「不要被我们现在的控件束缚住了」): what is used more
// stands nearer the button (2026-11-01: 「那它就不应该跑到离按钮很远的最顶上去啊」).

///|
/// What the control keeps of its own (the pick is the core's): the one whose panel is open (its station and pick, ""
/// none) and that panel (@sf.last_presented), the one asked open (a screen's fixture, a page's) and whether its accounts
/// are asked open in it too (a screen's fixture), and the borrowing it asks to confirm ("" none). Each panel keeps its
/// own contents and filter while it is shown.
priv struct Triple {
  mut open : String
  mut shown : Int
  mut asked : String
  mut accounts_asked : Bool
  mut borrow_asking : String
}

///|
let triple : Triple = { open: "", shown: 0, asked: "", accounts_asked: false, borrow_asking: "" }

///|
/// One panel's filter, what it shows and its pick: what is typed in its search (`field`), whether all the models are
/// shown beside what opened it (past those used most and starred: `all`), the maker whose models they are there
/// (`kind`: the picked model's where none is asked) and whether its sidekicks are (`sidekick`). Once closed, its last
/// pick stays with it while it leaves: saving a different model may change its options and height immediately, but
/// must not rearrange the panel that is already going away.
priv struct TriplePanel {
  mut serial : Int
  field : @ui.Field
  kind : @signals.Signal[String]
  all : @signals.Signal[Bool]
  sidekick : @signals.Signal[Bool]
  mut pick : Json?
  /// the level the model picked was last brought into view in (its first, all of them, a kind's; none yet), for each
  /// of a sheet's steps ("" its first, and all of one beside what opened it): once as each is come to, not each frame,
  /// so what the person scrolled stays where they left it
  shown : Map[String, String]
  /// how its borrowing is asked, where what opened it asks it itself (a control made once: model_triple_node), given
  /// what the pick says of it; None, its control's build's dialog (borrow_dialog)
  asks : ((Json?) -> Unit)?
  /// what its stops for how hard it thinks keep (@sf.stops_node), those of each of a sheet's steps ("" its first)
  effort_stops : Map[String, @sf.Stops]
  /// the models of its first level after the configurations used most, as they stood when it opened and those come to
  /// it since: the one picked where it is not starred (where the rest are a level further) and those starred: one
  /// starred or not since stays where it was while the panel is open
  mut first : (Array[String], Array[String])?
  /// gone up from what opened it (open_triple_panel's `up`): what it keeps nearest what opened it at its foot
  up : Bool
  /// the widest its models' names have been while it is open (triple_body_node's `names_w`)
  mut names_most : Double
  /// whether it is a small panel beside what opened it, as its body found as it was made (what its foot goes by)
  mut small : Bool
}

///|
fn TriplePanel::pick_now(self : TriplePanel, src : Source, station : String, of : String) -> Json? {
  // (open, or not yet told its serial as what it holds is first made)
  if self.serial == 0 || @sf.presented_open_of(self.serial) {
    // (its last as it leaves: what it shows stays while it goes)
    match src.topic("pick", pick_params(station, of)).get().value {
      Some(_) as v => self.pick = v
      None => ()
    }
  }
  self.pick
}

///|
fn triple_reset() -> Unit {
  triple.open = ""
  triple.shown = 0
  triple.asked = ""
  triple.accounts_asked = false
  triple.borrow_asking = ""
  triple_ahead_stop()
  triple_ahead.of = ""
  // (a lease of a run before is that run's source's: let go with it)
  triple_ahead.lease = None
}

///|
/// A control drawn of its face (a new chat's: its `pick` as the page has it, NewChatPick) asks its panel's own `pick` as
/// the hand comes to it (a pointer resting over it, a finger or a pointer going down on it, a press) and opens that panel
/// once it is answered, whole: what it holds of it meanwhile (`lease`, of `of`: its station and pick), and the press
/// waiting for it to be answered (`wait`: sfbase's press_wait, which waits only while what it was pressed in stays as it
/// was, and lets go of what it asked when it stops). The panel holds it while it is open, and a borrowing asked from it
/// while that is asked.
priv struct TripleAhead {
  mut lease : @sfbase.TopicLease?
  mut of : String
  mut wait : @sfbase.PressWait?
}

///|
// kept across runs: put back by triple_reset
let triple_ahead : TripleAhead = { lease: None, of: "", wait: None }

///|
/// Whether a press waits for a panel's pick.
fn triple_waiting() -> Bool {
  triple_ahead.wait is Some(w) && w.waiting()
}

///|
/// What waits to open a panel ended, letting go of nothing (the same asked again, or the panel opened holds it).
fn triple_ahead_stop() -> Unit {
  match triple_ahead.wait {
    Some(w) => {
      triple_ahead.wait = None
      w.end()
    }
    None => ()
  }
}

///|
/// The pick `of` on `station` asked of the core ahead of its panel (held till triple_let_go), unless it is held already;
/// one held for another let go of.
fn triple_ask(src : Source, station : String, of : String) -> Unit {
  let me = station + "\u{1}" + of
  match triple_ahead.lease {
    Some(l) if triple_ahead.of == me && l.alive() => return
    Some(l) => l.cancel()
    None => ()
  }
  triple_ahead.of = me
  triple_ahead.lease = Some(src.lease_topic("pick", pick_params(station, of)))
}

///|
/// What was asked ahead of the panel of the pick `of` on `station` as it stands, read through what holds it (holding
/// nothing more: a page's own read of it would hold it while the page is there); None while it is not held.
fn triple_ahead_read(station : String, of : String) -> @sfbase.TopicState? {
  guard triple_ahead.of == station + "\u{1}" + of && triple_ahead.lease is Some(l) && l.alive() else { return None }
  @signals.untracked(fn() { l.read() })
}

///|
/// What was asked ahead of the panel of `me` let go of, where nothing reads it: its panel not open, nothing waiting to
/// open it, no borrowing of it asked, the hand not on its control (`hand`).
fn triple_let_go(me : String, hand? : Bool = false) -> Unit {
  guard triple_ahead.of == me && !hand && triple.open != me && !triple_waiting() && triple.borrow_asking != me else {
    return
  }
  match triple_ahead.lease {
    Some(l) => {
      triple_ahead.lease = None
      l.cancel()
    }
    None => ()
  }
}

///|
/// The panel of the pick `of` on `station` opened beside `from` once its own pick is answered (asked now where it is
/// not held already): at once where it is, else the moment it is, whole, never on what the control's face has nor in
/// its bones; a press that waits for it as sfbase's press_wait says (not at all once what it was pressed in is gone,
/// what it asked let go of then). Opened already, it closes (as open_triple_panel). On `side` of `from` (an agent's
/// card's: Right).
fn open_triple_whole(
  src : Source,
  station : String,
  of : String,
  from : @sf.Anchor,
  saved : String,
  side? : @ui.Side = Bottom,
  up? : Bool = false,
) -> Unit {
  let me = station + "\u{1}" + of
  if triple.open == me {
    @sf.close_presented_of(triple.shown)
    return
  }
  triple_ahead_stop()
  triple_ask(src, station, of)
  // (the pick read through what holds it, never through the page's source, which would hold it while the page is there)
  let w = @sfbase.press_wait(
    fn() {
      match triple_ahead.lease {
        Some(l) if triple_ahead.of == me => l.follow() is Some(st) && @sfbase.opens_answered(st)
        _ => false
      }
    },
    fn() {
      guard triple.open != me else { return }
      // (gone: what it held let go of where nothing else holds it)
      open_triple_panel(src, station, of, from, saved~, side~, up~, gone=fn() { triple_let_go(me) })
    },
    let_go=fn() { triple_let_go(me) },
  )
  triple_ahead.wait = if w.waiting() { Some(w) } else { None }
}

///|
/// What is at a row's end (its check, what goes with it): the rest of the row after its words, at its end.
// kept across runs: a value (no field of it changes)
let triple_end : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=S1_5, align=ACenter, justify=JEnd)

///|
/// An effort as it is said (low → 低); one the words do not know, as it is spelled, its first letter up.
pub fn effort_text(effort : String) -> String {
  let key = "web-main.model.effortLevel." + effort
  let said = @sf.t(key)
  if said != key {
    said
  } else if effort == "" {
    effort
  } else {
    effort.clamped_view(end=1).to_upper().to_owned() + effort.clamped_view(start=1).to_owned()
  }
}

///|
/// The pick's topic's params.
fn pick_params(station : String, of : String) -> Map[String, Json] {
  { "station": Json::string(station), "of": Json::string(of) }
}

///|
/// The core offers models another station could lend, with a filter off each time the panel opens. A station with
/// no models of its own still opens the panel so those models can be shown and borrowed.
fn triple_other_stations(v : Json?) -> Bool {
  field(v, "otherStations") is Some(True) || field(v, "otherStations") is Some(False)
}

///|
/// What the panel picked changed (`pick.set`): only what is given.
fn pick_draft(src : Source, station : String, of : String, patch : Map[String, Json]) -> Unit {
  let p = pick_params(station, of)
  for k, v in patch {
    p[k] = v
  }
  (src.call)("pick.set", Json::object(p), fn(res) {
    match res {
      Ok(_) => ()
      Err(e) => toast_later(@sf.t("web-main.pick.failed", args=[("error", error_words(e))]))
    }
  })
}

///|
/// What the panel picked made what it runs on at once (`pick.save` given the picks `patch`), said once done with `done`
/// ("" nothing: a change in the panel, which stays open and shows it).
fn pick_save(
  src : Source,
  station : String,
  of : String,
  patch : Map[String, Json],
  done? : String = "",
  ok? : (Json) -> Unit = fn(_) {  },
  failed? : () -> Unit = fn() {  },
) -> Unit {
  let p = pick_params(station, of)
  for k, v in patch {
    p[k] = v
  }
  act(src, @sf.t("common.save"), "pick.save/" + station + "/" + of, "pick.save", Json::object(p), done~, ok~, failed~)
}

///|
/// The panel of the pick `of` on `station` (the control's: see model_triple) opened beside `from`: from the control,
/// or from elsewhere that says what runs (an agent's card's account: `side` Right, beside the card). Opened already,
/// it closes (a trigger toggles it: one the panel does not cover, the card's, stays pressable while it is open). `up`:
/// what opened it stands low in the window, the panel going up from it (said by what opened it, where it stands as it
/// is pressed: nothing laid out is read back for it), what it keeps nearest what opened it at its foot.
pub fn open_triple_panel(
  src : Source,
  station : String,
  of : String,
  from : @sf.Anchor,
  saved? : String = "",
  side? : @ui.Side = Bottom,
  gone? : () -> Unit = fn() {  },
  asks? : (Json?) -> Unit,
  accounts? : Bool = false,
  up? : Bool = false,
) -> Unit {
  let me = station + "\u{1}" + of
  if triple.open == me {
    @sf.close_presented_of(triple.shown)
    return
  }
  triple.open = me
  // (its accounts over it as it opens: asked for by who runs it, an agent's card's 账号)
  if accounts {
    triple.accounts_asked = true
  }
  let up = up && side is Bottom
  let contents : TriplePanel = {
    serial: 0,
    field: @ui.Field::new(),
    kind: @signals.signal(triple_no_kind),
    all: @signals.signal(false),
    sidekick: @signals.signal(false),
    pick: None,
    shown: {},
    asks,
    effort_stops: {},
    first: None,
    up,
    names_most: 0.0,
    small: false,
  }
  pick_draft(src, station, of, { "open": Json::boolean(true) })
  @sf.panel_nodes(
    @sf.t("android-chat.new.model"),
    fn(b, close) { triple_panel_node(b, src, station, of, contents, saved, close) },
    from~,
    w=@double.infinity,
    // (as wide as its columns' words, no wider: 2026-10-26 用户「没啥内容也这么宽感觉会很奇怪」)
    fits=true,
    foot=fn(f, close) { triple_foot_node(f, src, station, of, contents, close, saved~) },
    // (beside what opened it, its title over its models' column, its search beside it, how hard it thinks titled over
    // its own: triple_body_node's; 2026-11-02 用户「搜索在左边区域，思考深度和模型在同一个层级」)
    heads_itself=true,
    gone=fn() {
      triple.open = ""
      let cur = @signals.untracked(fn() { src.topic("pick", pick_params(station, of)).get().value })
      if triple_selected_accounts(field(cur, "draft")) is Some([]) {
        pick_draft(src, station, of, { "open": Json::boolean(false) })
      }
      gone()
    },
    focus=false,
    fade_out_together=true,
    // (a line over its foot out to its sides: 2026-11-02 用户「下面整体一根通的分割线」, in place of 2026-10-30's none)
    ruled=true,
    // (a sheet of it goes in steps, as the app's other panels of levels do: all the models a step in, a maker's a step
    // further, each sliding in with its back key, the sheet as tall as each on its way there; 2026-11-10 用户「动效呢」,
    // of levels one in another's place at once, the sheet another height in the same frame)
    steps=true,
    // (gone up from what opened it where that stands low: what it keeps nearest it at its foot, triple_body_node's)
    side=if up { Top } else { side },
  )
  contents.serial = @sf.last_presented()
  triple.shown = contents.serial
}

///|
/// The control of the pick `of` on `station` (ModelTriple): its line, and its panel under it while open (above it
/// where the presenters flip it up). `face`: the control as a page draws it closed with itself (a new chat's: its
/// `pick`, NewChatPick, only where it runs on a model), not read on its own: its panel's own pick is asked as the hand
/// comes to it and the panel opens once that is answered (open_triple_whole); `small`: in a composer's row (its words
/// 12). `saved`: what is said once a model picked
/// (onConfirm's toast: a chat's, from its next turn; a connect's, its model bound; nothing where nothing runs on it yet,
/// a new chat's or a new connect's). `floating`: over a page rather than in a row (a new chat's over its
/// composer, narrow): a capsule of the composer's glass. `bound`: what it runs is another's to say (a preset's), its
/// panel never opened; `on_bound` what a press on it opens instead, beside it.
pub fn model_triple(
  c : @ui.Ctx,
  src : Source,
  station : String,
  of : String,
  face? : Json? = None,
  small? : Bool = false,
  floating? : Bool = false,
  saved? : String = "",
  bound? : Bool = false,
  on_bound? : (@sf.Beside) -> Unit,
) -> Unit {
  let t = @sf.theme()
  let v = match face {
    Some(_) => face
    None => src.topic("pick", pick_params(station, of)).get().value
  }
  guard v is Some(Object(_)) else { return }
  let value = field(v, "value")
  // (a face is drawn only of a control that runs on a model: there are models to pick)
  let offers = face is Some(_) || items(v, "options").length() > 0 || triple_other_stations(v)
  let vo = field(v, "valueOption")
  let account = field(v, "account")
  let me = station + "\u{1}" + of
  let dkey = "pick.save/" + station + "/" + of
  let saving = doing(dkey)
  let id = c.id("triple/" + me)
  // (`bound`: what it runs is another's to say, a preset's: shown, not opened, no chevron)
  let can = offers && !saving && !bound
  let open = triple.open == me
  let go = fn() {
    triple.asked = ""
    // (in a composer's row, at the window's foot: its panel gone up from it)
    match face {
      Some(_) => open_triple_whole(src, station, of, Of(id), saved, up=small)
      None => open_triple_panel(src, station, of, Of(id), saved~, up=small)
    }
  }
  // (drawn of its face: its panel's pick asked as the hand comes to it, ahead of the press it opens at: a pointer come
  // to rest over it, a finger or a pointer gone down on it; let go as it leaves, where nothing else holds it)
  if face is Some(_) && !src.read_only && !c.in_bones() {
    let hand = can && (c.hovered(id) || (c.press().down && c.press_within(id)))
    if hand {
      triple_ask(src, station, of)
    } else {
      triple_let_go(me)
    }
    // (pressed before it was answered: looked at again once the frame's builds are over, where opening it tells
    // outside)
    match triple_ahead.wait {
      Some(w) => c.after_build("triple-open/" + me, fn() { w.check() })
      None => ()
    }
  }
  if can && !open {
    c.on_press(id, fn() {
      go()
    })
  }
  // (`bound`, pressed: what holds it says so, `on_bound` beside it)
  match on_bound {
    Some(f) if bound && offers => c.on_press(id, fn() { f(Of(id)) })
    _ => ()
  }
  // (asked from elsewhere: opened as it is seen)
  if can && !open && triple.asked == me {
    go()
  }
  let runtime = text(value, "runtime")
  let (words, muted) = if small { (triple_words_xs, triple_muted_xs) } else { (triple_words, triple_muted) }
  c.box(
    style=match (floating, open, small) {
      // (over the page, not in a row: on the composer's glass, as the page's other choice)
      (true, _, _) => glass_chooser_box
      (false, true, false) => triple_on
      (false, false, false) => triple_style
      (false, true, true) => triple_small_on
      (false, false, true) => triple_small
    },
    glass?=if floating { Some(@sf.glass_floating()) } else { None },
    id~,
    fn() {
    if !offers {
      c.text(@sf.t("web-main.model.none"), style=muted) |> ignore
    } else {
      let model = text(value, "model")
      @sf.maker_mark(c, text(field(vo, "maker"), "id"), runtime, 14.0) |> ignore
      let name = if model == "" {
        @sf.t("web-main.model.pick")
      } else {
        // (a model not among those listed here: the name the core knows it by, never its id)
        match (text(vo, "name"), text(v, "modelText")) {
          ("", "") => model
          ("", n) => n
          (n, _) => n
        }
      }
      // (within the room it has, the most it can say: what matters least left out first, as the web's DROPS: who
      // runs it by name, then who runs it, then the runtime, then how hard it thinks; the model never: its name cut
      // short once all of them have gone)
      c.text(name, style=if small { triple_name_xs } else { triple_name }, keep=true) |> ignore
      if !flag(v, "runtimeFixed") && (flag(v, "showRuntime") || items(vo, "runtimes").length() > 1) {
        c.box(style=triple_part, drop=triple_drop_runtime, fn() {
          c.text("·", style=muted) |> ignore
          c.text(@settings.runtime_short(runtime), style=words) |> ignore
        })
        |> ignore
      }
      let effort = text(value, "effort")
      if effort != "" || items(v, "efforts").length() > 0 {
        c.box(style=triple_part, drop=triple_drop_effort, fn() {
          c.text("·", style=muted) |> ignore
          c.text(if effort == "" { @sf.t("web-main.model.defaultEffort") } else { effort_text(effort) }, style=words)
          |> ignore
        })
        |> ignore
      }
      match text(v, "fastText") {
        "" => ()
        f =>
          c.box(style=triple_part, drop=triple_drop_effort, fn() {
            c.text("·", style=muted) |> ignore
            c.text(f, style=words) |> ignore
          })
          |> ignore
      }
      match text(v, "subagentText") {
        "" => ()
        sub =>
          c.box(style=triple_part, fn() {
            c.text(sub, style=words) |> ignore
          })
          |> ignore
      }
      if account is Some(Object(_)) {
        // (each of its pieces in the control's row: its name the first to go, then the rest of it)
        let profile = field(account, "profile")
        let marked = profile is Some(Object(_))
        // (the dot before it goes with what follows it: its mark where it has one, else its name, never left alone)
        if marked {
          c.box(style=triple_part, drop=triple_drop_account, fn() {
            c.text("·", style=muted) |> ignore
            @sf.maker_mark(c, text(profile, "mark"), runtime, 14.0) |> ignore
          })
          |> ignore
        }
        let level = text(account, "level")
        c.box(style=if marked { triple_alone } else { triple_part }, drop=triple_drop_name, fn() {
          if !marked {
            c.text("·", style=muted) |> ignore
          }
          c.text(
            text(account, "text"),
            style=if level == "amber" {
              triple_amber
            } else if level == "red" {
              triple_red
            } else {
              words
            },
          )
          |> ignore
        })
        |> ignore
        if profile is Some(Object(_)) {
          c.box(style=triple_part, drop=triple_drop_account, fn() {
            @sf.quota_chips(c, field(profile, "quota"), small=true)
          })
          |> ignore
        }
      }
    }
    // what was picked on its way: a ring in place of the chevron
    if saving {
      @sf.spinner(c, size=12.0) |> ignore
    } else if !bound {
      @sf.icon(c, "chevron-down", size=12.0, color=t.p.muted) |> ignore
    }
    },
  )
  |> ignore
  // (a borrowing asked from its panel: what its own pick says of it, as what the panel asked holds it while it is
  // asked: triple_let_go)
  let asking = match face {
    Some(_) if triple.borrow_asking == me => triple_ahead_read(station, of).bind(fn(s) { s.value })
    Some(_) => None
    None => v
  }
  borrow_dialog(c, src, station, of, asking)
}

///|
/// The control of the pick `of` on `station` (model_triple's, as nodes, made once) in `parent`, its words as the core's
/// pick says them now: the model's mark and name, then (each left out where the line has not the room, what matters
/// least first) its runtime, how hard it thinks, how fast, who runs it (its mark, its name, its allowance's chips); a
/// ring in place of its chevron while what was picked is on its way; on its hover's ground while the hand is on it and
/// while its panel is open. Pressed, its panel opens beside it (open_triple_panel); borrowing a model from there is
/// asked in the presenters' confirm. `saved`: as model_triple's. Nothing while the pick is not read.
pub fn model_triple_node(parent : @view.View, src : Source, station : String, of : String, saved? : String = "") -> Unit {
  let me = station + "\u{1}" + of
  let dkey = "pick.save/" + station + "/" + of
  let v = fn() { src.topic("pick", pick_params(station, of)).get().value }
  let value = fn() { field(v(), "value") }
  let vo = fn() { field(v(), "valueOption") }
  let account = fn() { field(v(), "account") }
  let runtime = fn() { text(value(), "runtime") }
  let opened = @signals.signal(false, same=fn(a, b) { a == b })
  // borrowing a model of another station's, asked first (borrow_dialog's, put up by the presenters)
  let asks = fn(borrow : Json?) { borrow_ask(src, station, of, borrow) }
  parent.show(fn() { v() is Some(Object(_)) }, fn(o) {
    o.box(fn(b) {
      @sf.style_node(b, fn() { triple_style }, in_row=true)
      // (no wider than its row leaves it: what it says given way within it, its parts left out, its name cut last)
      b
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      |> ignore
      @sf.hover_ground_node(b, extra=fn() { opened.get() })
      let can = fn() { (items(v(), "options").length() > 0 || triple_other_stations(v())) && !doing(dkey) }
      @sf.presses_node(b, fn() {
        guard @signals.untracked(can) && triple.open != me else { return }
        triple.asked = ""
        let (x, y, w, h) = b.placed_window_now()
        opened.set(true)
        // (its panel gone up from it where it stands low in the window: short of room for it under it, more over it)
        let under = b.window().1 - (y + h)
        let up = under < triple_up_need && y > under
        open_triple_panel(src, station, of, At(x, y, w, h), saved~, gone=fn() { opened.set(false) }, asks~, up~)
      }, on=can)
      // (each part what its row holds itself, so the row leaves it out where it has not the room: View::drops)
      let part = fn(r : @view.View, drop : Int, shown : () -> Bool, body : (@view.View) -> Unit) {
        r.show(shown, fn(x) {
          @sf.style_node(x, fn() { triple_part }, in_row=true)
          x.drops(Is(drop)) |> ignore
          body(x)
        })
      }
      let dot = fn(x : @view.View) { @sf.words_node(x, fn() { "·" }, fn() { triple_muted }) |> ignore }
      b.pick(fn() { items(v(), "options").length() == 0 }, fn(r, none) {
        // (its parts in a row, as the capsule's: what has not the room left out of it, View::drops)
        r
        .row(Is(true))
        .gap(Is(triple_gap))
        .lines_up(Is(Some(Middle)))
        .fits(Is(true))
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        |> ignore
        if none {
          @sf.words_node(r, fn() { @sf.t("web-main.model.none") }, fn() { triple_muted }) |> ignore
          return
        }
        r.pick(fn() { (text(field(vo(), "maker"), "id"), runtime()) }, fn(m, k) { @sf.maker_mark_node(m, k.0, k.1, 14.0) |> ignore })
        // (within the room it has, the most it can say: model_triple's; the model never, its name cut short last)
        @sf.words_node(r, fn() {
          let model = text(value(), "model")
          if model == "" {
            @sf.t("web-main.model.pick")
          } else {
            // (a model not among those listed here, none of this station's: the name the core knows it by, never its id)
            match (text(vo(), "name"), text(v(), "modelText")) {
              ("", "") => model
              ("", n) => n
              (n, _) => n
            }
          }
        }, fn() { triple_name })
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        .cuts(Is(true))
        .allow_ellipsis(Is(true))
        // (what may be left out leaving for it first, its name cut short only then: View::fit_whole)
        .fit_whole(Is(true))
        |> ignore
        part(r, triple_drop_runtime, fn() { !flag(v(), "runtimeFixed") && (flag(v(), "showRuntime") || items(vo(), "runtimes").length() > 1) }, fn(x) {
          dot(x)
          @sf.words_node(x, fn() { @settings.runtime_short(runtime()) }, fn() { triple_words }) |> ignore
        })
        part(r, triple_drop_effort, fn() { text(value(), "effort") != "" || items(v(), "efforts").length() > 0 }, fn(x) {
          dot(x)
          @sf.words_node(x, fn() {
            let effort = text(value(), "effort")
            if effort == "" {
              @sf.t("web-main.model.defaultEffort")
            } else {
              effort_text(effort)
            }
          }, fn() { triple_words })
          |> ignore
        })
        part(r, triple_drop_effort, fn() { text(v(), "fastText") != "" }, fn(x) {
          dot(x)
          @sf.words_node(x, fn() { text(v(), "fastText") }, fn() { triple_words }) |> ignore
        })
        // (who runs it: its mark where it has one, then its name, then its allowance's chips: model_triple's)
        let profile = fn() { field(account(), "profile") }
        let marked = fn() { profile() is Some(Object(_)) }
        part(r, triple_drop_account, fn() { account() is Some(Object(_)) && marked() }, fn(x) {
          dot(x)
          x.pick(fn() { (text(profile(), "mark"), runtime()) }, fn(m, k) { @sf.maker_mark_node(m, k.0, k.1, 14.0) |> ignore })
        })
        r.show(fn() { account() is Some(Object(_)) }, fn(x) {
          @sf.style_node(x, fn() { if marked() { triple_alone } else { triple_part } }, in_row=true)
          x.drops(Is(triple_drop_name)) |> ignore
          x.show(fn() { !marked() }, dot)
          @sf.words_node(x, fn() { text(account(), "text") }, fn() {
            match text(account(), "level") {
              "amber" => triple_amber
              "red" => triple_red
              _ => triple_words
            }
          })
          |> ignore
        })
        part(r, triple_drop_account, fn() { account() is Some(Object(_)) && marked() }, fn(x) {
          @sf.quota_chips_node(x, fn() { field(profile(), "quota") }, small=true)
        })
      })
      // what was picked on its way: a ring in place of the chevron
      b.pick(fn() { doing(dkey) }, fn(e, saving) {
        if saving {
          @sf.spinner_node(e, size=12.0) |> ignore
        } else {
          @sf.icon_node(e, "chevron-down", 12.0, By(fn() { @sf.theme().p.muted })) |> ignore
        }
      })
    })
    |> ignore
  })
}

///|
/// The model of `options` whose id is `id` (one of Devin's Fusion pairs, its lead's), None where none is.
fn triple_model_of(options : Array[Json], id : String) -> Json? {
  match options.search_by(fn(o) { text(Some(o), "model") == id }) {
    Some(i) => Some(options[i])
    None =>
      if id.has_prefix("fusion-") {
        match id.find("-sidekick-") {
          Some(at) if at > 7 => {
            let lead = id.exact_view(start=7, end=at).to_owned()
            options.search_by(fn(o) { text(Some(o), "model") == lead }).map(fn(i) { options[i] })
          }
          _ => None
        }
      } else {
        None
      }
  }
}

///|
/// The panel in node `b` (its step `at` in a sheet or a dialog in steps: "" its first): what it holds as the core's
/// `pick` says it once that is read.
fn triple_panel_node(
  b : @view.View,
  src : Source,
  station : String,
  of : String,
  contents : TriplePanel,
  saved : String,
  close : () -> Unit,
  at? : String = "",
) -> Unit {
  let v = fn() { contents.pick_now(src, station, of) }
  // (made once it is read: what it reads waited for by the panel before it comes in, @sf.OpenGate, so it opens whole,
  // never in its bones; in its bones, its rows changed under the hand as the sheet rose, the sheet another height on its
  // way up)
  b.show(at_once=true, fn() { v() is Some(_) }, fn(x) {
    x.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    triple_body_node(x, src, station, of, contents, v, saved, close, at)
  })
}

///|
/// The panel's models, runtimes, how hard it thinks and how fast in node `b`, as the core's `pick` (`v()`) offers them
/// now: the filter across its top (more than 8 models), the models (one picked, `saved` said and the panel closed:
/// triple_model_row_node), and between them and what opened it how hard it thinks; what goes with the model at its
/// foot (triple_foot_node). Beside what opened it the models' room is 360 at most (the web's) and its levels are
/// in it (contents' `all`, `kind`, `sidekick`); in a sheet or a dialog in the middle of the window, its steps (`at`:
/// "" its first, "all" all of them by their makers, "kind:" and a maker's id its models, "sidekick" the sidekicks),
/// eleven rows and a half at most, less where the sheet at its most has less for them.
fn triple_body_node(
  b : @view.View,
  src : Source,
  station : String,
  of : String,
  contents : TriplePanel,
  v : () -> Json?,
  saved : String,
  close : () -> Unit,
  at : String,
) -> Unit {
  // (a sheet or a dialog in the middle: the makers, a maker's models a step further, each a step of the panel's;
  // beside what opened it all in the one panel, the makers and a maker's models side by side)
  let sheet = !@sf.in_small_panel_node(b)
  contents.small = !sheet
  // (what it keeps nearest what opened it at its foot: gone up from it, or a sheet's risen from the screen's foot)
  let up = sheet || contents.up
  let tips = @sf.panel_tips_of(b)
  let options = fn() { items(v(), "options") }
  // (typed in its first step, where its search is)
  let words = fn() {
    if sheet && at != "" {
      ""
    } else {
      contents.field.text().trim(chars=" ").to_owned().to_lower()
    }
  }
  let searching = fn() { words() != "" }
  let listed = fn() {
    let w = words()
    options().filter(fn(o) {
      let o = Some(o)
      w == "" ||
      text(o, "name").to_lower().contains(w) ||
      text(o, "model").to_lower().contains(w) ||
      items(o, "ids").iter().any(fn(i) { i is String(s) && s.to_lower().contains(w) })
    })
  }
  let model_of = fn(id : String) { triple_model_of(options(), id) }
  // two levels (2026-11-02 用户「两级优化」): first the configurations used most here (the core's `combos`), nearest
  // what opened the panel, then the models starred (`liked`), then the way to all of them; there, every model of a
  // maker (the core's `makers`, 「分组应该是模型厂商，而不是供应商」; 「我 20 个 provider 你怎么排」: a list of them, not a
  // row), each starred there by its star. Typed, every one that matches, whatever its kind. None used nor starred: all
  // of them at once.
  // (as the core says them now: one taken out (`pick.forget`) leaves the panel as it is taken out, its room closing as
  // the next of them comes in its place, the user, 2026-11-13: 「删掉常用模型，只有 x 会消失，然后关掉重新打开才能刷新」
  // 「去掉后要有补位（如果有的话），还要有动效」)
  let combos = fn() -> Array[Json] {
    items(v(), "combos").filter(fn(x) { x is Object(_) && model_of(text(Some(x), "model")) is Some(_) })
  }
  let liked = fn() -> Array[Json] {
    items(v(), "liked").filter_map(fn(j) {
      match j {
        String(s) => model_of(s)
        _ => None
      }
    })
  }
  let kinds = fn() { items(v(), "makers") }
  let kind_of = fn(o : Json) -> String { text(field(Some(o), "maker"), "id") }
  // all of them in one list while they are few, no level past it (2026-11-10: a station of six models went through
  // 全部模型 and its makers to reach one); more, those used most and starred first and the rest a level further, by
  // their makers, a maker's models a step past them (2026-11-02 用户「我 20 个 provider 你怎么排」)
  let flat = fn() { kinds().length() < 2 || options().length() <= triple_flat_most }
  let has_first = fn() { !combos().is_empty() || !liked().is_empty() }
  let all = fn() {
    searching() || (!flat() && ((if sheet { at != "" } else { contents.all.get() }) || !has_first()))
  }
  // (the kind asked for: a step's, else the one chosen in the panel; none asked for is no maker's id: the makers with
  // none known, 其他, have the id "", 2026-11-10 用户「怎么其它厂商里又有个 anthropic」)
  let kind_asked = fn() {
    if !sheet {
      contents.kind.get()
    } else if at.has_prefix("kind:") {
      at.exact_view(start=5).to_owned()
    } else {
      triple_no_kind
    }
  }
  // (the kind browsed: as asked, else the picked model's, else the first)
  let kind = fn() {
    let ks = kinds()
    let asked = kind_asked()
    if ks.iter().any(fn(k) { text(Some(k), "id") == asked }) {
      asked
    } else {
      match model_of(text(v(), "option")) {
        Some(o) if ks.iter().any(fn(k) { text(Some(k), "id") == kind_of(o) }) => kind_of(o)
        _ => ks.get(0).map(fn(k) { text(Some(k), "id") }).unwrap_or("")
      }
    }
  }
  let kind_open = fn() { !sheet || kind_asked() != triple_no_kind }
  // a maker's models by their series (2026-11-02 用户「要保留模型分组，opus 系列之类的」) where a series has more than
  // one: a name over each of two series of one model each said every name twice (2026-11-10)
  let series = fn() -> Array[(String, Array[Json])] {
    let s = searching()
    let k = kind()
    let out : Array[(String, Array[Json])] = []
    for o in listed() {
      if !s && kind_of(o) != k {
        continue
      }
      let who = match text(Some(o), "family") {
        "" => @sf.t("web-main.model.otherSeries")
        f => f
      }
      match out.search_by(fn(x) { x.0 == who }) {
        Some(i) => out[i].1.push(o)
        None => out.push((who, [o]))
      }
    }
    out
  }
  let by_series = fn() {
    let s = series()
    !searching() && s.length() > 1 && s.iter().any(fn(x) { x.1.length() > 1 })
  }
  // (no level for the model's own: 2026-11-02 用户「思考深度不再提供默认」)
  let all_efforts = fn() -> Array[(String, String)] {
    items(v(), "efforts").filter_map(fn(e) { if e is String(e) { Some((e, effort_text(e))) } else { None } })
  }
  // (none picked, the model's own where its runtime says it: 2026-11-02 用户「能拿到默认档就勾上它」)
  let effort_now = fn() {
    match text(field(v(), "draft"), "effort") {
      "" => text(v(), "effortDefault")
      e => e
    }
  }
  // (each made what it runs on at once, the panel staying open: kept for the model too, as it runs next time it is
  // picked; and by the core while the panel is open, for a model never run here picked in it next: the pick's
  // options' `usual`)
  let pick_effort = fn(e : String) {
    // (not taken: its stops back on what it runs on)
    let back = fn() {
      for _, st in contents.effort_stops {
        st.reset()
      }
    }
    pick_save(
      src,
      station,
      of,
      { "effort": if e == "" { Json::null() } else { Json::string(e) } },
      // (the core kept none of it, its `saved: false`: nothing picked yet that would think that hard, a session still on
      // its station's own model; nothing else tells the level back, so its stops would stay on what was pressed)
      ok=fn(res) {
        if field(Some(res), "saved") is Some(False) {
          back()
        }
      },
      failed=back,
    )
  }
  let picked = fn() { text(v(), "option") }
  // each column's words as wide as the widest of them picked (the models' of all of them, whatever the filter leaves):
  // the panel, as wide as what it holds, as wide whichever is picked and whatever is typed (as a segmented choice's)
  // (and never narrower than it has been while it is open: a configuration taken out, its name the widest, leaves the
  // panel as wide as it was, what is at its foot where it was)
  let names_w = fn() {
    let w = dmax(contents.names_most, triple_names_w(b, v(), combos(), all_efforts()))
    contents.names_most = w
    w
  }
  // the first level, two things told apart (the user, 2026-11-10: 「感觉常用模型配置需要跟普通的收藏模型从 ui 上区分
  // 开」; 「收藏跟常用不一样」「常用包括了思考深度和速度还有上下文长度」「是一种配置」): those used most, each a
  // configuration under their name (常用搭配), then every starred model, the one picked where it is not starred after
  // them where the rest are a level further, so it is always in sight as a model; each stays where it was while the
  // panel is open, starred or not since (contents' `first`)
  let first_ids = fn() -> (Array[String], Array[String]) {
    let f = flat()
    let lk = liked()
    let now_used : Array[String] = []
    match model_of(picked()) {
      Some(o) if !f && !lk.contains(o) => now_used.push(picked())
      _ => ()
    }
    let now_liked = lk.map(fn(o) { text(Some(o), "model") })
    match contents.first {
      Some(was) => {
        // (one starred a level further is with them once come back; in the one list of a few it stays where it is)
        if !f {
          for id in now_used {
            if !was.0.contains(id) && !was.1.contains(id) {
              was.0.push(id)
            }
          }
          for id in now_liked {
            if !was.0.contains(id) && !was.1.contains(id) {
              was.1.push(id)
            }
          }
        }
        (was.0.copy(), was.1.copy())
      }
      None => {
        contents.first = Some((now_used.copy(), now_liked.copy()))
        (now_used, now_liked)
      }
    }
  }
  // (the starred, then the one picked where it is not)
  let starred = fn() -> Array[Json] {
    let (used, lk) = first_ids()
    (lk + used).filter_map(model_of)
  }
  // (the rest of a few, past them in the same list, in the core's order)
  let others = fn() -> Array[Json] {
    if flat() {
      let (used, lk) = first_ids()
      options().filter(fn(o) { !used.contains(text(Some(o), "model")) && !lk.contains(text(Some(o), "model")) })
    } else {
      []
    }
  }
  // the models' room as tall as what it holds at each level, up to a most, scrolling in itself past that (the user,
  // 2026-11-10: 「感觉不用固定高度吧，不能做到撑开吗？定个最大高度」): beside what opened it the web's 360; in a sheet
  // eleven rows and a half (the half row says there is more), less where the sheet at its most has less for it
  let row_h = fn() { @sf.theme().rows.pick + 1.0 }
  let list_most = fn() {
    if sheet {
      let ww = @sf.over_room(b).0
      let wh = @sf.sheet_window_h_node(b)
      let vv = v()
      let foot_chips = 1 +
        (if !flag(vv, "runtimeFixed") && items(vv, "runtimes").length() > 1 { 1 } else { 0 }) +
        (if !items(vv, "sidekicks").is_empty() { 1 } else { 0 }) +
        (if flag(vv, "fastAvailable") { 1 } else { 0 }) +
        (if !items(vv, "contexts").is_empty() { 1 } else { 0 })
      let foot_two_lines = (foot_chips >= 2 && ww < 340.0) || (foot_chips >= 3 && ww < 440.0) || foot_chips >= 4
      let sheet_rest = (if at == "" { 60.0 } else { 72.0 }) +
        (if at == "" && options().length() > 8 { 42.0 } else { 0.0 }) +
        (if triple_other_stations(vv) { @sf.theme().items.least } else { 0.0 }) +
        (if all_efforts().length() > 0 { 50.0 } else { 0.0 }) +
        (if field(vv, "borrow") is Some(Object(_)) { 30.0 } else { 0.0 }) +
        85.0 +
        (if foot_two_lines { 52.0 } else { 0.0 })
      dmax(3.0 * row_h(), dmin(triple_sheet_rows * row_h(), wh * @sf.sheet_most - sheet_rest))
    } else {
      triple_list_h
    }
  }
  // beside what opened it, where the models go by level, their room is its most at every level, whichever maker's are
  // shown and whatever is typed: the panel one size all the while it is open (2026-11-10: 461 to 323 in a frame for a
  // station's 全部模型 as each level was as tall as it held). The way to all of them then at the room's foot, the models
  // from its top (2026-11-02 用户「全部模型的位置需要讲究一下」: level with the last of the levels beside them, as a
  // list's 「查看全部」 is).
  let level_h = fn() { !sheet && !flat() }
  // a step in, in a sheet or a dialog in steps: what `to` names of the models, its foot as every step's
  let step = fn(title : String, to : String) {
    @sf.panel_go_nodes(
      title,
      fn(s, close) { triple_panel_node(s, src, station, of, contents, saved, close, at=to) },
      foot=fn(f, close) { triple_foot_node(f, src, station, of, contents, close, saved~, at=to) },
    )
  }
  // the model picked in view as the panel opens and as each level is come to (2026-11-05 用户「模型选择面板打开不会自动
  // 滚动到能看见已选择模型的地方」), not while what is typed filters them: the row to bring, by its key, once for each
  // level of each step (contents' `shown`), so what the person scrolled stays where they left it. A first level opening
  // up from what opened it starts at its foot, nearest the hand, where the one picked shows from there; else at the one
  // picked.
  let level_now = fn() {
    (if !all() { "first" } else if kind_open() { "all/" + kind() } else { "all" }) + (if up { "/up" } else { "" })
  }
  let bring_key = fn() -> String {
    let combos_now = combos()
    let st = starred()
    let ot = others()
    let p = picked()
    let model_key = fn(o : Json) { "model/" + text(Some(o), "model") }
    let nearest = match (combos_now.get(0), st.last(), ot.last()) {
      (Some(x), _, _) => triple_combo_key(Some(x))
      (None, Some(o), _) | (None, None, Some(o)) => model_key(o)
      _ => ""
    }
    let is_picked = fn(o : Json) { text(Some(o), "model") == p }
    // (at the first level the configuration it runs on exactly, where one is, else its model)
    let combo_on = if all() { None } else { combos_now.search_by(fn(x) { flag(Some(x), "selected") }) }
    let (picked_key, from_foot) = match combo_on {
      Some(i) => (triple_combo_key(Some(combos_now[i])), i)
      None =>
        (
          "model/" + p,
          (if combos_now.is_empty() { 0 } else { 1 }) +
          (match (st.search_by(is_picked), ot.search_by(is_picked)) {
            (Some(j), _) => combos_now.length() + st.length() - 1 - j
            (None, Some(k)) => combos_now.length() + st.length() + ot.length() - 1 - k
            _ => 0
          }),
        )
    }
    let rows_in_view = ((if flat() { list_most() } else { list_most() - row_h() }) / row_h()).to_int()
    if !all() && up && nearest != "" && from_foot < rows_in_view - 1 {
      nearest
    } else {
      picked_key
    }
  }
  // (a row of the models' made: brought into view where it is the one to bring as its level is come to)
  let brought = fn(row : @view.View, key : String) {
    guard !@signals.untracked(searching) else { return }
    let level = @signals.untracked(level_now)
    guard contents.shown.get(at).unwrap_or("") != level && @signals.untracked(bring_key) == key else { return }
    contents.shown[at] = level
    row.tree.show_in_sight(row.id())
  }
  // a scroller of the models: `most` tall at most, giving way where the panel has less room for it
  let scroll = fn(parent : @view.View, most : () -> Double, body : (@view.View) -> Unit) {
    @sf.capped_node(parent, most, fn(col) {
      @sf.style_node(col, fn() { triple_rows })
      body(col)
    })
    .shrink(Is(1.0))
    .min_height(Is(Some(0.0)))
    |> ignore
  }
  let model_row = fn(r : @view.View, id : String) {
    triple_model_row_node(r, src, station, of, v, fn() { model_of(id) }, id, picked, names_w, saved, close, tips)
    brought(r, "model/" + id)
  }
  // a level's models (all that match what is typed), scrolling by themselves, under their series' names where those
  // tell them apart
  let model_rows = fn(parent : @view.View, most : () -> Double) {
    scroll(parent, most, fn(col) {
      let keys = fn() -> Array[String] {
        let out : Array[String] = []
        let named = by_series()
        for s in series() {
          if named {
            out.push("series/" + s.0)
          }
          for o in s.1 {
            out.push("model/" + text(Some(o), "model"))
          }
        }
        if listed().is_empty() {
          out.push("none")
        }
        out
      }
      col.each(keys, fn(k) { k }, at_once=true, fn(r, k) {
        let k = k.untracked()
        if k.has_prefix("series/") {
          triple_column_head_node(r, k.exact_view(start=7).to_owned())
        } else if k.has_prefix("model/") {
          model_row(r, k.exact_view(start=6).to_owned())
        } else {
          r.box(fn(e) {
            @sf.style_node(e, fn() { triple_empty })
            @sf.words_node(e, fn() { @sf.t("web-main.model.noMatch") }, fn() { triple_muted }) |> ignore
          })
          |> ignore
        }
      })
    })
  }
  // the makers, a row each: its mark, its name, how many of the models it makes; the one browsed lit
  let kind_rows = fn(parent : @view.View, most : () -> Double) {
    scroll(parent, most, fn(col) {
      col.each(kinds, fn(k) { text(Some(k), "id") }, at_once=true, fn(r, k) {
        let id = text(Some(k.untracked()), "id")
        let title = fn() { text(Some(k.get()), "title") }
        let on = fn() { kind_open() && id == kind() }
        triple_option_node(
          r,
          title,
          on,
          fn(row) {
            row.box(fn(m) {
              @sf.style_node(m, fn() { triple_kind_mark }, in_row=true)
              @sf.maker_mark_node(m, id, "", 14.0) |> ignore
            })
            |> ignore
            @sf.words_node(row, title, fn() { if on() { triple_picked } else { triple_words } }) |> ignore
          },
          trail=fn(e) {
            @sf.words_node(e, fn() {
              match field(Some(k.get()), "count") {
                Some(Number(n, ..)) => n.to_int().to_string()
                _ => ""
              }
            }, fn() { triple_usual })
            |> ignore
          },
          // (a maker is browsed, not picked: lit, no check)
          checks=false,
          press=fn() {
            if sheet {
              step(@signals.untracked(title), "kind:" + id)
            } else {
              contents.kind.set(id)
            }
          },
        )
        |> ignore
      })
    })
  }
  // the way to all of them, at the foot of the first level's models (2026-11-02 用户「全部模型的位置需要讲究一下」: as
  // a list's 「查看全部」 is)
  let to_all = fn(parent : @view.View) {
    triple_option_node(
      parent,
      fn() { @sf.t("web-main.model.allModels") },
      fn() { false },
      // (its chevron right after its words: 「全部模型的箭头跟在文字后面」)
      fn(row) {
        @sf.words_node(row, fn() { @sf.t("web-main.model.allModels") }, fn() { triple_words }) |> ignore
        @sf.icon_node(row, "chevron-right", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
      },
      checks=false,
      press=fn() {
        if sheet {
          step(@sf.t("web-main.model.allModels"), "all")
        } else {
          contents.all.set(true)
        }
      },
    )
    |> ignore
  }
  // the first level: those used most under their name, the starred, the rest of a few, each group apart from the next,
  // the configurations used most nearest what opened the panel; each row by its key, so one taken out of those used
  // most closes its room as the next of them opens its own where it comes, what is over and under them going with
  // their rooms (the window's tree's: View::each, the user, 2026-11-13, 「去掉后要有补位，还要有动效」)
  // (one of those used most taken out (`pick.forget`): still shown where it was while it leaves, fading, nothing to
  // press there (`leaving`, by its key, as it last was); the next of them, come in its place at the same change, held
  // back till it has gone (`held_back`), coming in then as the rest move to their places: never shown over the one
  // leaving, the user, 2026-11-13: 「去掉后要有补位（如果有的话），还要有动效」; said as the first level is made,
  // first_level's)
  let leaving : @signals.Signal[Map[String, Json]] = @signals.signal(Map([]))
  let held_back : @signals.Signal[Array[String]] = @signals.signal([])
  let shown_order : Ref[Array[String]] = Ref([])
  let combos_shown = fn() -> Array[String] {
    let lv = leaving.get()
    let held = held_back.get()
    let now = combos().map(fn(x) { triple_combo_key(Some(x)) }).filter(fn(k) { !held.contains(k) })
    let order = shown_order.val
    let ks = order.filter(fn(k) { now.contains(k) || lv.contains(k) }) + now.filter(fn(k) { !order.contains(k) })
    shown_order.val = ks
    ks
  }
  let first_keys = fn() -> Array[String] {
    let groups : Array[(String, Array[String])] = []
    let ks = combos_shown()
    if !ks.is_empty() {
      groups.push(("combos", ["head/combos", ..(if up { ks.rev() } else { ks })]))
    }
    let st = starred()
    if !st.is_empty() {
      let ks = st.map(fn(o) { "model/" + text(Some(o), "model") })
      groups.push(("starred", ks))
    }
    let ot = others()
    if !ot.is_empty() {
      let ks = ot.map(fn(o) { "model/" + text(Some(o), "model") })
      groups.push(("others", ks))
    }
    let turned = if up { groups.rev() } else { groups }
    let out : Array[String] = []
    for i, g in turned {
      if i > 0 {
        let (a, z) = if up { (g.0, turned[i - 1].0) } else { (turned[i - 1].0, g.0) }
        out.push("apart/" + a + "/" + z)
      }
      // (a group's head over its rows, whichever way it opened)
      out.append(g.1)
    }
    // (none of this station's, its other stations' not asked: said so, and where they are, never a blank column)
    if out.is_empty() && triple_other_stations(v()) && !flag(v(), "otherStations") {
      out.push("none/here")
    }
    out
  }
  let first_level = fn(parent : @view.View) {
    parent.box(fn(room) {
      @sf.style_node(room, fn() { triple_room })
      // (one taken out: leaving where it was till leave_ms past the change that took it out, the next come at that
      // change held back as long)
      let keyed = fn() -> Map[String, Json] {
        let m : Map[String, Json] = Map([])
        for x in combos() {
          m[triple_combo_key(Some(x))] = x
        }
        m
      }
      let seen : Ref[Map[String, Json]] = Ref(@signals.untracked(keyed))
      room.reacts(at_start=false, keyed, fn(now) {
        let was = seen.val
        seen.val = now
        let gone : Array[(String, Json)] = []
        for k, x in was {
          if !now.contains(k) {
            gone.push((k, x))
          }
        }
        guard !gone.is_empty() else { return }
        let came : Array[String] = []
        for k, _ in now {
          if !was.contains(k) {
            came.push(k)
          }
        }
        let lv = leaving.untracked().copy()
        for g in gone {
          lv[g.0] = g.1
        }
        leaving.set(lv)
        held_back.set(held_back.untracked() + came)
        room.at_moment(room.cause_at() + @sf.leave_ms, fn() {
          let lv = leaving.untracked().copy()
          for g in gone {
            lv.remove(g.0)
          }
          leaving.set(lv)
          held_back.set(held_back.untracked().filter(fn(k) { !came.contains(k) }))
        })
        |> ignore
      })
      room.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      room
      .height(By(fn() { if level_h() { Some(triple_list_h) } else { None } }))
      .lies_along(By(fn() { if level_h() { Between } else { Start } }))
      |> ignore
      scroll(room, fn() { if flat() { list_most() } else { list_most() - row_h() } }, fn(scrolled) {
        // (the room between them each row's own: triple_first_gap)
        // (the room past the row at the panel's far end from what opened it taken back: none there, whichever row is
        // there as rows come and go, nothing of any row's said again at once)
        let back = 1.0
        let col = scrolled.box(fn(c) {
          @sf.style_node(c, fn() { triple_first_rows })
          c.margin(Is(if up { (0.0, -back, 0.0, 0.0) } else { (0.0, 0.0, 0.0, -back) })) |> ignore
        })
        // (its combos by key once: each row reads its own, told only as that one changes)
        let combos_by = col.keyed_by(combos, fn(x) { triple_combo_key(Some(x)) })
        col.each(first_keys, fn(k) { k }, fn(r, k) {
          let k = k.untracked()
          // (each with the room between it and the next in its own, on its side towards the panel's far end from what
          // opened it, a part of what it holds, so that room opens and closes with it)
          @sf.style_node(r, fn() { triple_first_rows })
          let apart = fn() { r.box(fn(g) { @sf.style_node(g, fn() { triple_first_gap }) }) |> ignore }
          if up {
            apart()
          }
          if k.has_prefix("head/") {
            triple_column_head_node(r, @sf.t("web-main.combos.label"))
          } else if k.has_prefix("none/") {
            r.box(fn(e) {
              @sf.style_node(e, fn() { triple_empty })
              @sf.words_node(e, fn() { @sf.t("web-main.model.noneHere") }, fn() { triple_muted_lines }) |> ignore
            })
            |> ignore
          } else if k.has_prefix("apart/") {
            r.box(fn(a) { @sf.style_node(a, fn() { triple_apart }) }) |> ignore
          } else if k.has_prefix("model/") {
            model_row(r, k.exact_view(start=6).to_owned())
          } else {
            let combo = fn() {
              match combos_by.get(k) {
                Some(x) => Some(x)
                None => leaving.get().get(k)
              }
            }
            let last : Ref[Json] = Ref(@signals.untracked(combo).unwrap_or(Json::null()))
            let x = fn() {
              match combo() {
                Some(c) => {
                  last.val = c
                  Some(c)
                }
                // (taken out, as it leaves: as it was)
                None => Some(last.val)
              }
            }
            // (taken out: fading where it is, from the change that took it out, nothing to press there)
            let gone = fn() { leaving.get().contains(k) }
            let fade = @motion.Way::new(1.0)
            r.reacts(at_start=false, gone, fn(g) { if g { fade.go(0.0, @motion.tween(@sf.leave_ms, ease=Out), at=r.cause_at()) } })
            r.alpha(By(fn() { fade.shown_on(r) })) |> ignore
            triple_combo_row_node(r, src, station, of, v, x, fn() { model_of(text(x(), "model")) }, names_w, saved, close, able=fn() { !gone() })
            brought(r, k)
          }
          if !up {
            apart()
          }
        })
      })
      room.show(fn() { !flat() }, to_all)
    })
    |> ignore
  }
  // all of them: typed, those that match; else beside what opened it the makers and a maker's models side by side, a
  // way back over them to the first level where there is one; in a sheet the makers, a maker's models a step past them
  let all_level = fn(parent : @view.View) {
    parent.box(fn(room) {
      @sf.style_node(room, fn() { triple_room })
      room.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      room.height(By(fn() { if level_h() { Some(triple_list_h) } else { None } })) |> ignore
      // (the way back: beside what opened it a row over them; a step's head has its back key)
      let back_to = fn() { !searching() && !sheet && has_first() }
      room.show(at_once=true, back_to, fn(bk) {
        triple_option_node(
          bk,
          fn() { @sf.t("web-main.model.allModels") },
          fn() { false },
          fn(row) {
            @sf.icon_node(row, "chevron-left", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
            @sf.words_node(row, fn() { @sf.t("web-main.model.allModels") }, fn() { triple_picked }) |> ignore
          },
          checks=false,
          press=fn() { contents.all.set(false) },
        )
        |> ignore
      })
      let most = fn() { if back_to() { list_most() - row_h() } else { list_most() } }
      room.pick(at_once=true, fn() { (searching(), sheet && kind_asked() == triple_no_kind) }, fn(x, k) {
        x.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        match k {
          (true, _) => model_rows(x, most)
          (false, true) => kind_rows(x, most)
          (false, false) if sheet => model_rows(x, most)
          (false, false) =>
            x.box(fn(br) {
              @sf.style_node(br, fn() { triple_browse })
              br.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
              br.box(fn(kc) {
                @sf.style_node(kc, fn() { triple_kinds_column }, in_row=true)
                kind_rows(kc, most)
              })
              |> ignore
              br.box(fn(r) { @sf.style_node(r, fn() { triple_rule_v }, in_row=true) }) |> ignore
              br.box(fn(mc) {
                @sf.style_node(mc, fn() { triple_models_column }, in_row=true)
                model_rows(mc, most)
              })
              |> ignore
            })
            |> ignore
        }
      })
    })
    |> ignore
  }
  let models = fn(parent : @view.View) {
    parent.pick(at_once=true, all, fn(x, a) {
      x.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      if a {
        all_level(x)
      } else {
        first_level(x)
      }
    })
  }
  let plain_head = fn(parent : @view.View) {
    parent.pick(fn() { options().length() > 8 }, fn(x, finds) {
      if finds {
        @sf.panel_head_node(x, fn() { @sf.t("android-chat.new.model") }, end=fn(e) { triple_find_node(e, contents) }) |> ignore
      } else {
        @sf.panel_head_node(x, fn() { @sf.t("android-chat.new.model") }) |> ignore
      }
    })
  }
  // whose models it lists, where another station could lend some: this station's, or every station's (the core's
  // `otherStations`), in the title's place, a choice of two
  let scope_node = fn(parent : @view.View) {
    // (the small one, as wide as its two words, not the page's: it stands in a title's place)
    @sf.seg_node(
      parent,
      fn() { [@sf.t("web-main.model.here"), @sf.t("web-main.model.everywhere")] },
      fn() { if flag(v(), "otherStations") { 1 } else { 0 } },
      fn(i) { pick_draft(src, station, of, { "otherStations": Json::boolean(i == 1) }) },
      each_own=true,
    )
    |> ignore
  }
  // beside what opened it, its title (and its search) over the models (heads_itself); the choice of whose models in
  // the title's place where another station could lend some
  let models_head = fn(parent : @view.View) {
    parent.pick(fn() { triple_other_stations(v()) }, fn(y, scoped) {
      if scoped {
        // (the choice on the title's line; the search, where there is one, on a line of its own under it, the
        // column's width: beside the choice it had not the room)
        y.box(fn(h) {
          @sf.style_node(h, fn() { triple_scope_head })
          h.box(fn(c) { @sf.style_node(c, fn() { triple_scope_choice }, in_row=true); scope_node(c) }) |> ignore
        })
        |> ignore
        y.show(fn() { options().length() > 8 }, fn(e) {
          e.box(fn(f) {
            @sf.style_node(f, fn() { triple_search })
            triple_find_node(f, contents)
          })
          |> ignore
        })
        return
      }
      plain_head(y)
    })
  }
  // (beside what opened it no wider than its first level needs, 2026-10-26 用户「没啥内容也这么宽感觉会很奇怪」; wider
  // only at the level of all of many, their makers a column before a maker's models, and as wide from then on)
  let browsing_makers = fn() { all() && !searching() }
  let room_w = fn() { dmax(0.0, @sf.over_room(b).0 - 2.0 * @sf.panel_pad - 16.0) }
  let beside_w = fn() { dmin(room_w(), (if browsing_makers() { triple_panel_w_many } else { triple_panel_w }) - 2.0 * @sf.panel_pad) }
  // (the panel at least as wide as a row with the widest name and the widest of how it runs, and its star, where it
  // has the room)
  let row_least = fn() {
    names_w() + 14.0 + @sf.icon_button_side + 4.0 * @ui.Space::px(S1_5) + 2.0 * @ui.Space::px(S2_5) + @ui.Space::px(S3_5)
  }
  let h_effort = @sf.t("web-main.model.effort")
  let effort_w = fn() {
    let efforts = all_efforts()
    guard !efforts.is_empty() else { return 0.0 }
    b.words_redone() |> ignore
    let size = @sf.node_sp(b, @sf.theme().t.ui)
    let title = @sf.node_words_w(h_effort, size, weight=600)
    let choice = efforts.fold(init=0.0, fn(w, e) { dmax(w, @sf.node_words_w(e.1, size, weight=500)) })
    let padding = 2.0 * @ui.Space::px(S2_5)
    dmax(title + padding, choice + padding + @ui.Space::px(S1_5) + @ui.Space::px(S3_5)).ceil()
  }
  let side_mode = fn() {
    if sheet {
      at == "sidekick"
    } else {
      contents.sidekick.get()
    }
  }
  b.box(fn(all_of) {
    all_of.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    // (beside what opened it never narrower while it is open, as the old small panel's `fits` was: as wide as it is
    // laid out at each change of what sets how wide it is (its level, the maker browsed, what is typed, its words);
    // back from all of them as wide as it was there, its models no wider than their level's most, how hard it thinks
    // taking the rest)
    if sheet {
      all_of.min_width(Is(Some(0.0))) |> ignore
    } else {
      all_of.keeps_width(
        fn() {
          let th = @ui.tree_theme()
          ((all(), kind(), words(), side_mode(), names_w()), (all_of.words_redone(), th.text_size(Body)))
        },
        most=room_w,
      )
      |> ignore
    }
    all_of.pick(at_once=true, side_mode, fn(body, sidekick) {
      body.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      if sidekick {
        triple_sidekick_node(body, src, station, of, contents, v, sheet, beside_w, level_h)
        return
      }
      if sheet {
        // (the search, where the panel's head has none: a sheet's, its head its own)
        if at == "" {
          body.show(fn() { options().length() > 8 }, fn(s) {
            s.box(fn(sb) {
              @sf.style_node(sb, fn() { triple_search })
              triple_find_node(sb, contents)
            })
            |> ignore
          })
        }
        // (whose models it lists, over them, where another station could lend some: models_head's choice)
        body.show(fn() { triple_other_stations(v()) }, fn(sh) {
          sh.box(fn(h) {
            @sf.style_node(h, fn() { triple_scope_head })
            scope_node(h)
          })
          |> ignore
        })
        models(body)
        // its name and a stop for each level on one row across the sheet, the one it is at said in the thumb (stops):
        // as many levels as a model has on one line in any language, nothing opened over the sheet to pick one
        body.show(fn() { all_efforts().length() > 0 }, fn(eb) {
          eb.box(fn(row) {
            @sf.style_node(row, fn() { triple_effort_block })
            @sf.words_node(row, fn() { h_effort }, fn() { triple_head }) |> ignore
            let stops = match contents.effort_stops.get(at) {
              Some(st) => st
              None => {
                let st = @sf.Stops::new()
                contents.effort_stops[at] = st
                st
              }
            }
            @sf.stops_node(
              row,
              fn() { all_efforts().map(fn(e) { e.1 }) },
              fn() {
                let now = effort_now()
                all_efforts().search_by(fn(e) { e.0 == now }).unwrap_or(-1)
              },
              stops,
              said=h_effort,
              on_pick=fn(i) {
                match @signals.untracked(all_efforts).get(i) {
                  Some(e) => pick_effort(e.0)
                  None => ()
                }
              },
            )
            |> ignore
          })
          |> ignore
        })
      } else {
        // (the models and how hard it thinks side by side, each titled alike over it, the line between them up to the
        // panel's top: 「上面的分割线试试到顶」)
        body.box(fn(side) {
          @sf.style_node(side, fn() { triple_side_by_side })
          side
          .shrink(Is(1.0))
          .min_height(Is(Some(0.0)))
          .max_width(By(fn() { Some(if browsing_makers() { room_w() } else { beside_w() }) }))
          // Size all three columns together before any of their contents have to wrap.
          .width(By(fn() {
            if !browsing_makers() {
              None
            } else {
              let efforts = effort_w()
              let makers = @ui.Space::px(S48) + 2.0 * @ui.Space::px(S1_5) + 1.0
              let beside = if efforts > 0.0 { efforts + @ui.Space::px(S2) } else { 0.0 }
              Some(dmin(makers + row_least() + beside, room_w()))
            }
          }))
          |> ignore
          side.box(fn(mc) {
            @sf.style_node(mc, fn() { triple_models_column }, in_row=true)
            mc.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
            models_head(mc)
            models(mc)
          })
          |> ignore
          side.show(fn() { all_efforts().length() > 0 }, fn(ec) {
            ec.box(fn(col) {
              @sf.style_node(col, fn() { triple_effort_column }, in_row=true)
              col.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              // (as tall as the models beside it, its line from the panel's top to its foot's)
              let measured_effort_w : @view.Live[Double?] = By(fn() { if browsing_makers() { Some(effort_w()) } else { None } })
              col.grow(Is(1.0)).width(measured_effort_w).max_width(measured_effort_w) |> ignore
              // (the line between them out of their flow, in the middle of the room between them, from the panel's top
              // down to the line over its foot, meeting it: 「竖的那根怎么没跟横的接起来呢」)
              col.box(fn(rule) {
                @sf.style_node(rule, fn() { triple_rule_v })
                rule
                .over(Is(true))
                .width(Is(Some(1.0)))
                .margin(Is((-triple_between_rule, -@sf.panel_pad, 0.0, -@sf.panel_pad)))
                |> ignore
              })
              |> ignore
              @sf.panel_head_node(col, fn() { h_effort }) |> ignore
              triple_choices_node(col, h_effort, all_efforts, effort_now, pick_effort)
            })
            |> ignore
          })
        })
        |> ignore
      }
    })
    // the model picked is another station's: said over the foot, which borrows it rather than confirming
    all_of.show(fn() { field(v(), "borrow") is Some(Object(_)) }, fn(bw) {
      bw.box(fn(n) {
        @sf.style_node(n, fn() { triple_borrow })
        @sf.words_node(n, fn() {
          let borrow = field(v(), "borrow")
          if flag(borrow, "allowed") {
            text(borrow, "note")
          } else {
            text(borrow, "why")
          }
        }, fn() { triple_note })
        |> ignore
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// How wide a model's name column is in its rows (node `v`'s words, at the system's size of words): the widest of the
/// pick's models' names picked with how each would run after it, of what each has spent under it, and of the
/// configurations used most's names with how each runs in its capsule, so the panel is as wide whichever is picked and
/// whatever is typed (triple_body_node's).
fn triple_names_w(v : @view.View, pick : Json?, combos : Array[Json], efforts : Array[(String, String)]) -> Double {
  v.words_redone() |> ignore
  let ui = @sf.node_sp(v, @sf.theme().t.ui)
  let meta = @sf.node_sp(v, @sf.theme().t.meta)
  let note_w = fn(s : String) { @sf.node_words_w(s, meta) }
  // (one that says nothing of how it runs has never run here: it says how hard it thinks once that is set by hand in
  // the panel, so the room for the widest level is its from the start, the panel as wide whatever is set in it)
  let level_w = efforts.fold(init=0.0, fn(m, e) { dmax(m, note_w(e.1)) })
  let options = items(pick, "options")
  let usual_w = options.fold(init=0.0, fn(m, o) {
    let said = text(Some(o), "usualText")
    // (and one that says how hard it thinks, the one picked as it is set now: as wide as with the widest level)
    let own = match text(field(Some(o), "usual"), "effort") {
      "" => 0.0
      e => note_w(effort_text(e))
    }
    let w = if said == "" {
      level_w
    } else if own > 0.0 {
      note_w(said) - own + dmax(level_w, own)
    } else {
      note_w(said)
    }
    dmax(m, w)
  })
  let names = options.fold(init=0.0, fn(m, o) {
    let o = Some(o)
    let name = @sf.node_words_w(text(o, "name"), ui, weight=500)
    let name = if usual_w > 0.0 { name + @ui.Space::px(S1_5) + usual_w } else { name }
    dmax(dmax(m, name), note_w(text(field(o, "spent"), "text")))
  })
  // (and the configurations used most: a name, how it runs in a capsule after it, the capsule's sides with it)
  combos
  .fold(init=names, fn(m, x) {
    let x = Some(x)
    dmax(
      m,
      @sf.node_words_w(text(x, "name"), ui, weight=500) +
      @ui.Space::px(S1_5) +
      note_w(text(x, "text")) +
      2.0 * @ui.Space::px(S2),
    )
  })
  .ceil()
}

///|
/// The models' search where there are more than 8 of them in node `parent`: round, on the words' tint, no line round it,
/// its glass before its words, its ground deeper pointed at or typed in (2026-10-30 用户「搜索也优化一下」「感觉它不应该
/// 单独一行」: beside what opened it, at the end of the panel's head, beside its title), as tall as a small panel's rows.
fn triple_find_node(parent : @view.View, contents : TriplePanel) -> Unit {
  parent.box(fn(f) {
    @sf.icon_node(f, "search", triple_find_icon, By(fn() { @sf.theme().p.muted })) |> ignore
    let field = @ui.field(
      f,
      contents.field,
      placeholder=@sf.t("web-main.model.search"),
      line=@sf.theme().t.ui_line,
      max_lines=1,
      enter_sends=true,
      size_by=fn() { @sf.theme().t.ui },
      colors_by=fn() {
        let th = @ui.tree_theme()
        (th.fg, th.subtle, th.accent)
      },
    )
    field.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    // (its ground deeper pointed at or typed in)
    @sf.style_node(f, fn() {
      (if @sf.hovered_node(f) || field.focused() { triple_find_hot } else { triple_find }).then(@ui.style(h=Fixed(@sf.menu_row_min)))
    })
  })
  |> ignore
}

///|
/// One of what goes with the model, at the panel's foot (who runs it, what on, which sidekick, how fast, how much
/// context), in node `parent`: a capsule on the words' tint, its name `head`, what is picked now (`mark`: a runtime's
/// mark before it; `maker`: a model maker's mark before it), a chevron; `press` given the capsule itself as it is
/// pressed (what it opens beside it). All of them one part in one place (2026-11-10: two of them rows with a chevron
/// under the models, three of them words at the foot with none, read as what it says rather than what is pressed).
fn triple_chip_node(
  parent : @view.View,
  head : String,
  words : () -> String,
  press : (@view.View) -> Unit,
  mark? : () -> String = fn() { "" },
  maker? : () -> String = fn() { "" },
  look? : () -> @ui.TextStyle = fn() { triple_who_name },
) -> @view.View {
  parent.box(fn(b) {
    @sf.style_node(b, fn() { triple_who(hot=@sf.lit_node(b)) }, in_row=true)
    b.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    b.says(By(fn() { Some(@view.said(Button, label=words())) })) |> ignore
    @sf.presses_node(b, fn() { press(b) })
    @sf.words_node(b, fn() { head }, fn() { triple_who_lead }) |> ignore
    // (its mark where it has one; none, nor the room after it: the capsule as wide as its words make it)
    b.box(fn(mb) {
      mb.margin(By(fn() { if maker() == "" && mark() == "" { (0.0, 0.0, -@ui.Space::px(S1), 0.0) } else { (0.0, 0.0, 0.0, 0.0) } })) |> ignore
      mb.pick(fn() { (maker(), mark()) }, fn(m, k) {
        if k.0 != "" || k.1 != "" {
          @sf.maker_mark_node(m, k.0, k.1, triple_pick_mark) |> ignore
        }
      })
    })
    |> ignore
    @sf.words_node(b, words, look).cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
    @sf.icon_node(b, "chevron-down", triple_pick_chevron, By(fn() { @sf.theme().p.muted })) |> ignore
  })
}

///|
/// Its foot (the presenter's, where every panel's foot stands) in node `f`: what goes with the model, each a capsule
/// (who runs it: the accounts in a panel of their own, from it, on 中屏/大屏 flush with the model's panel; what on where
/// its model runs on more than one; which sidekick on Devin Fusion; how fast; how much context: on a second line where
/// one is short), and where the model picked is another station's, borrowing it (asked first). Nothing to confirm: each
/// pick is made what it runs on as it is picked (2026-11-01 用户「从第一性原理出发重新思考这个组件的使用场景」).
fn triple_foot_node(
  f : @view.View,
  src : Source,
  station : String,
  of : String,
  contents : TriplePanel,
  close : () -> Unit,
  saved? : String = "",
  at? : String = "",
) -> Unit {
  let v = fn() { contents.pick_now(src, station, of) }
  // (as its body found it is shown: a foot is lent nothing of where it is)
  let sheet = !contents.small
  // (what the pick says as it is now)
  let o = f
    o.box(fn(row) {
      @sf.style_node(row, fn() { if flag(v(), "claudeModeAvailable") { triple_mode_room } else { triple_who_room } }, in_row=true)
      row.wraps(Is(Some(@ui.Space::px(S2)))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      // who runs it, at the foot's start (the web's panel's foot, the phone's sheet's)
      let revert_none = fn() {
        let cur = @signals.untracked(fn() { src.topic("pick", pick_params(station, of)).get().value })
        if triple_selected_accounts(field(cur, "draft")) is Some([]) {
          pick_draft(src, station, of, { "open": Json::boolean(false) })
        }
      }
      let accounts = fn(from : @sf.Anchor) {
        triple.accounts_asked = false
        let serial = if contents.serial > 0 { contents.serial } else { @sf.last_presented() }
        @sf.panel_nodes(
          @sf.t("web-main.model.account"),
          fn(n, close) { triple_accounts_node(n, src, station, of, close) },
          from~,
          w=triple_accounts_w,
          gone=revert_none,
          focus=false,
          match_panel=serial,
        )
      }
      let who = triple_chip_node(
        row,
        @sf.t("web-main.model.account"),
        fn() {
          match text(v(), "who") {
            "" => @sf.t("web-main.model.selectAll")
            w => w
          }
        },
        fn(c) { accounts(Node(c)) },
        look=fn() {
          match text(v(), "whoLevel") {
            "amber" => triple_who_amber
            "red" => triple_who_red
            _ => triple_who_name
          }
        },
      )
      // (asked from elsewhere: opened as it is seen)
      if triple.accounts_asked {
        who.at_moment(who.cause_at(), fn() { accounts(Node(who)) }) |> ignore
      }
      // what it runs on where its model runs on more than one, beside who runs it (2026-11-02 用户「运行时不应该放那个
      // 位置吧」): its name and the one picked; pressed, the runtimes in a pick
      row.show(fn() { !flag(v(), "runtimeFixed") && items(v(), "runtimes").length() > 1 }, fn(x) {
        let head = @sf.t("web-main.model.runtime")
        let now = fn() { text(field(v(), "draft"), "runtime") }
        triple_chip_node(x, head, fn() { @settings.runtime_label(now()) }, mark=now, fn(c) {
          let choices = items(@signals.untracked(v), "runtimes").filter_map(fn(r) {
            if r is String(r) { Some(@sf.choice(r, @settings.runtime_label(r), icon="runtime:" + r)) } else { None }
          })
          @sf.pick(head, choices, @signals.untracked(now), fn(r) { pick_save(src, station, of, { "runtime": Json::string(r) }) }, from=Node(c), search=false)
        })
        |> ignore
      })
      // which sidekick runs with the model on Devin Fusion: its name and the one picked; pressed, a level of
      // `副模型 × 思考深度` (triple_sidekick_node)
      row.show(fn() { !items(v(), "sidekicks").is_empty() }, fn(x) {
        let head = @sf.t("web-main.model.sidekick")
        let now = fn() { text(v(), "sidekickNow") }
        let picked = fn() {
          let sks = items(v(), "sidekicks")
          sks.search_by(fn(sk) { text(Some(sk), "id") == now() }).map(fn(i) { sks[i] })
        }
        triple_chip_node(
          x,
          head,
          fn() {
            match picked() {
              Some(sk) => text(Some(sk), "text")
              None => @sf.t("web-main.model.sidekickNone")
            }
          },
          maker=fn() {
            match picked() {
              Some(sk) => text(field(Some(sk), "maker"), "id")
              None => ""
            }
          },
          mark=fn() { if now() != "" { "devin" } else { "" } },
          fn(_) {
            if sheet {
              if at == "sidekick" {
                @sf.panel_back() |> ignore
              } else {
                @sf.panel_go_nodes(
                  head,
                  fn(s, close) { triple_panel_node(s, src, station, of, contents, saved, close, at="sidekick") },
                  foot=fn(ff, close) { triple_foot_node(ff, src, station, of, contents, close, saved~, at="sidekick") },
                )
              }
            } else {
              contents.sidekick.set(!contents.sidekick.untracked())
            }
          },
        )
        |> ignore
      })
      // how fast it runs (2026-11-02 用户「速度放在面板下面，跟账号差不多的位置」): its name and how fast it runs; pressed,
      // the speeds the station offers in a pick. None picked, how fast its account runs it, said as that (`fastPlan`; 2026-11-02 用户
      // 「谁知道订阅是什么，应该直接显示具体值」)
      row.show(fn() { flag(v(), "fastAvailable") }, fn(x) {
        let head = @sf.t("web-main.model.speed")
        let choices = fn() {
          let cs = [
            @sf.choice("standard", @sf.t("web-main.model.standard")),
            // (Fast its bolt)
            @sf.choice("fast", "Fast", note=@sf.t("web-main.model.fastNote"), icon="zap"),
          ]
          if flag(v(), "ultrafastAvailable") {
            cs.push(@sf.choice("ultrafast", "Ultrafast", note=@sf.t("web-main.model.ultrafastNote"), icon="zap"))
          }
          cs
        }
        let now = fn() {
          let speed = text(field(v(), "draft"), "speed")
          if speed != "" {
            speed
          } else {
            match field(field(v(), "draft"), "fast") {
              Some(True) => "fast"
              Some(False) => "standard"
              _ => if flag(v(), "fastPlan") { "fast" } else { "standard" }
            }
          }
        }
        triple_chip_node(x, head, fn() {
          let cs = choices()
          cs.search_by(fn(ch) { ch.key == now() }).map(fn(i) { cs[i].label }).unwrap_or("")
        }, fn(c) {
          @sf.pick(head, @signals.untracked(choices), @signals.untracked(now), fn(k) {
            if k == "ultrafast" {
              pick_save(src, station, of, { "speed": Json::string(k) })
            } else {
              pick_save(src, station, of, { "fast": Json::boolean(k == "fast") })
            }
          }, from=Node(c), search=false)
        })
        |> ignore
      })
      row.show(fn() { flag(v(), "claudeModeAvailable") }, fn(x) {
        let head = @sf.t("web-main.model.claudeMode")
        let now = fn() { if flag(field(v(), "draft"), "tui") { "TUI" } else { "Print" } }
        triple_chip_node(x, head, now, fn(c) {
          let active = @signals.untracked(now)
          let default_tui = flag(@signals.untracked(v), "defaultTui")
          @sf.menu([
            Some(@sf.menu_item_of("Print", fn() { pick_save(src, station, of, { "tui": false }) }, chosen=active == "Print")),
            Some(@sf.menu_item_of("TUI", fn() { pick_save(src, station, of, { "tui": true }) }, chosen=active == "TUI")),
            None,
            Some(@sf.menu_item_of(@sf.t("web-main.model.defaultTui"), fn() {
              (src.call)("pick.defaultTui", { "tui": Json::boolean(!default_tui) }, fn(res) {
                if res is Err(e) { toast_later(@sf.t("web-main.pick.failed", args=[("error", error_words(e))])) }
              })
            }, checked=default_tui)),
          ], from=Node(c), title=head)
        })
        |> ignore
      })
      // how much context it is kept to, after how fast (2026-11-03 用户「把 opus5.5 上下文长度限制在 500k 或者 300k」
      // 「直接放最下面跟速度一样吧」): its name and the step picked; pressed, the steps in a pick, its whole window first,
      // as the core offers them (none where its runtime cannot)
      row.show(fn() { !items(v(), "contexts").is_empty() }, fn(x) {
        let head = @sf.t("web-main.model.context")
        let choices = fn() { items(v(), "contexts").map(fn(o) { @sf.choice(text(Some(o), "id"), text(Some(o), "text")) }) }
        let now = fn() { text(v(), "contextNow") }
        triple_chip_node(x, head, fn() {
          let cs = choices()
          cs.search_by(fn(ch) { ch.key == now() }).map(fn(i) { cs[i].label }).unwrap_or("")
        }, fn(c) {
          @sf.pick(head, @signals.untracked(choices), @signals.untracked(now), fn(k) {
            pick_save(src, station, of, { "context": if k == "" { Json::null() } else { Json::string(k) } })
          }, from=Node(c), search=false)
        })
        |> ignore
      })
    })
    |> ignore
    // where the model picked is another station's, borrowing it, asked first
    o.show(fn() { field(v(), "borrow") is Some(Object(_)) }, fn(x) {
      @sf.button_node(
        x,
        fn() { text(field(v(), "borrow"), "action") },
        fn() {
          let borrow = field(@signals.untracked(v), "borrow")
          triple.open = ""
          // (the panel shut first: shutting it shuts what is over it, the ask put up after it is not; asked of the
          // control's build, said before it shuts, so what the panel held of the pick is held on for it)
          if contents.asks is None {
            triple.borrow_asking = station + "\u{1}" + of
          }
          close()
          match contents.asks {
            Some(ask) => ask(borrow)
            None => ()
          }
        },
        tone=Primary,
        disabled=fn() { !flag(field(v(), "borrow"), "allowed") },
      )
      |> ignore
    })

}

///|
/// Which sidekick and how hard it thinks on Devin Fusion, a level of the panel's of its own in node `parent` (from the
/// foot's 副模型: beside what opened it in the panel's place, a row back over it; in a sheet a step): the sidekicks
/// beside how hard the one picked thinks, each picked made what it runs on at once (`pick.save`).
fn triple_sidekick_node(
  parent : @view.View,
  src : Source,
  station : String,
  of : String,
  contents : TriplePanel,
  v : () -> Json?,
  sheet : Bool,
  beside_w : () -> Double,
  level_h : () -> Bool,
) -> Unit {
  let groups = fn() { triple_sidekick_groups(v()) }
  let now = fn() { text(v(), "sidekickNow") }
  let active_group = fn() -> SidekickGroup {
    let gs = groups()
    let n = now()
    let i = gs.search_by(fn(g) { g.efforts.iter().any(fn(w) { w.0 == n }) }).unwrap_or(0)
    gs.get(i).unwrap_or({ id: "", name: "", maker: "", efforts: [] })
  }
  let active_eff_lbl = fn() {
    let g = active_group()
    let n = now()
    g.efforts.search_by(fn(w) { w.0 == n }).map(fn(i) { g.efforts[i].1 }).unwrap_or("")
  }
  let h_sidekick = @sf.t("web-main.model.sidekick")
  let h_effort = @sf.t("web-main.model.effort")
  let efforts = fn() -> Array[(String, String)] {
    let g = active_group()
    if g.id == "" || g.efforts.is_empty() {
      [("", "—")]
    } else {
      g.efforts.map(fn(w) { (w.0, w.1) })
    }
  }
  let pick_eff = fn(sid : String) {
    let g = @signals.untracked(active_group)
    let n = @signals.untracked(now)
    match g.efforts.search_by(fn(w) { w.0 == sid && sid != "" }) {
      Some(i) => {
        let chosen = g.efforts[i]
        if chosen.0 != n && chosen.2 != "" {
          pick_save(src, station, of, { "model": Json::string(chosen.2), "runtime": Json::string("devin") })
        }
      }
      None => ()
    }
  }
  let back = fn() {
    if sheet {
      @sf.panel_back() |> ignore
    } else {
      contents.sidekick.set(false)
    }
  }
  parent.box(fn(side) {
    @sf.style_node(side, fn() {
      if sheet {
        triple_side_by_side
      } else {
        triple_side_by_side.then(@ui.style(max_w=Fixed(beside_w())))
      }
    })
    side.box(fn(mc) {
      @sf.style_node(mc, fn() { triple_models_column }, in_row=true)
      if sheet {
        triple_column_head_node(mc, @sf.t("android-chat.new.model"))
      } else {
        triple_option_node(
          mc,
          fn() { h_sidekick },
          fn() { false },
          fn(row) {
            @sf.icon_node(row, "chevron-left", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
            @sf.words_node(row, fn() { h_sidekick }, fn() { triple_picked }) |> ignore
          },
          checks=false,
          press=fn() { contents.sidekick.set(false) },
        )
        |> ignore
      }
      mc.box(fn(room) {
        @sf.style_node(room, fn() { triple_room })
        room.height(By(fn() { if level_h() { Some(triple_list_h) } else { None } })) |> ignore
        room.box(fn(rows) {
          @sf.style_node(rows, fn() { triple_rows })
          rows.each(groups, fn(g) { g.name }, fn(r, g) {
            let g0 = g.untracked()
            let on = fn() { active_group().id == g.get().id }
            triple_option_node(
              r,
              fn() { g.get().name },
              on,
              fn(row) {
                if g0.maker != "" {
                  @sf.maker_mark_node(row, g0.maker, "devin", 14.0) |> ignore
                } else {
                  row.box(fn(m) { @sf.style_node(m, fn() { triple_kind_mark }, in_row=true) }) |> ignore
                }
                @sf.words_node(row, fn() { g.get().name }, fn() { if on() { triple_row_picked } else { triple_row_name } })
                .shrink(Is(1.0))
                .min_width(Is(Some(0.0)))
                |> ignore
              },
              press=fn() {
                let g = g.untracked()
                let n = @signals.untracked(now)
                if g.id == "" {
                  let target = g.efforts.get(0).map(fn(w) { w.2 }).unwrap_or("")
                  if n != "" && target != "" {
                    pick_save(src, station, of, { "model": Json::string(target), "runtime": Json::string("devin") })
                  }
                  back()
                } else {
                  let lbl = @signals.untracked(active_eff_lbl)
                  let chosen = match g.efforts.search_by(fn(w) { w.1 == lbl && lbl != "" }) {
                    Some(i) => g.efforts[i]
                    None => g.efforts[0]
                  }
                  if chosen.0 != n && chosen.2 != "" {
                    pick_save(src, station, of, { "model": Json::string(chosen.2), "runtime": Json::string("devin") })
                  }
                }
              },
            )
            |> ignore
          })
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    side.box(fn(col) {
      @sf.style_node(col, fn() { triple_effort_column }, in_row=true)
      col.box(fn(rule) {
        @sf.style_node(rule, fn() { triple_rule_v })
        rule
        .over(Is(true))
        .width(Is(Some(1.0)))
        .margin(Is((-triple_between_rule, if sheet { 0.0 } else { -@sf.panel_pad }, 0.0, -@sf.panel_pad)))
        |> ignore
      })
      |> ignore
      if sheet {
        triple_column_head_node(col, h_effort)
      } else {
        @sf.panel_head_node(col, fn() { h_effort }) |> ignore
      }
      triple_choices_node(col, h_effort, efforts, fn() { if active_group().id == "" { "" } else { now() } }, pick_eff)
    })
    |> ignore
  })
  |> ignore
}

///|
#derive(Eq)
priv struct SidekickGroup {
  id : String
  name : String
  maker : String
  efforts : Array[(String, String, String)]
}

///|
fn triple_sidekick_groups(v : Json?) -> Array[SidekickGroup] {
  let sidekicks = items(v, "sidekicks")
  let default_eff = @sf.t("web-main.model.defaultEffort")
  let groups : Array[SidekickGroup] = []
  for sk in sidekicks {
    let sv = Some(sk)
    let sid = text(sv, "id")
    let label = text(sv, "text")
    let target = text(sv, "model")
    let maker = text(field(sv, "maker"), "id")
    let (name_part, eff_part) = if sid == "" {
      (label, "")
    } else {
      match label.find(" · ") {
        Some(idx) => (label.exact_view(start=0, end=idx).to_owned(), label.exact_view(start=idx + 3).to_owned())
        None => (label, default_eff)
      }
    }
    match groups.search_by(fn(g) { g.name == name_part && (sid == "" || g.id != "") }) {
      Some(i) => groups[i].efforts.push((sid, eff_part, target))
      None => groups.push({ id: sid, name: name_part, maker, efforts: [(sid, eff_part, target)] })
    }
  }
  groups
}


///|
/// A model's row in node `r` (the model `o()`, its id `id`): its maker's mark, its name (what it has spent under it)
/// `names_w()` wide (the widest of the models'), how it runs picked right after its name (cut short first where the
/// row is short), at its end the station it comes from; beside it at its end its star, lit while it is starred:
/// pressed, starred or not (`pick.like`). Pressed, picked as the core says it runs picked (its `usual`): as it last ran
/// here; one that never ran here, with what was set by hand in the panel since it opened, where it takes it.
fn triple_model_row_node(
  r : @view.View,
  src : Source,
  station : String,
  of : String,
  v : () -> Json?,
  o : () -> Json?,
  id : String,
  picked_id : () -> String,
  names_w : () -> Double,
  saved : String,
  close : () -> Unit,
  tips : @sf.TipLayer?,
) -> Unit {
  let picked = fn() { picked_id() == id }
  let name = fn() { text(o(), "name") }
  let runs = fn() {
    match items(o(), "runtimes").get(0) {
      Some(String(r)) => r
      _ => text(field(v(), "value"), "runtime")
    }
  }
  // how it would run picked, after its name (the core's: as it last ran here; one never run here, how it was set by
  // hand in the panel since it opened; the user, 2026-11-10: 「常用模型按理说是包括思考深度的」); nothing after the one
  // picked, whose own is what the panel shows beside the models
  let usual = fn() { if picked() { "" } else { text(o(), "usualText") } }
  let liked = fn() { flag(o(), "liked") }
  // pressed: picked
  let go = fn() {
    let vv = @signals.untracked(v)
    let oo = @signals.untracked(o)
    if text(oo, "availability") == "borrowable" {
      // (another station's: borrowed first, from the foot)
      pick_draft(src, station, of, { "model": Json::string(id) })
    } else {
      // made what it runs on at once, as it last ran here, and the panel closed: nothing of it left to confirm
      triple.open = ""
      close()
      if text(vv, "option") != id || text(field(vv, "value"), "model") != text(field(vv, "draft"), "model") {
        let p : Map[String, Json] = { "model": Json::string(id) }
        match field(oo, "usual") {
          Some(Object(u)) =>
            for k in ["runtime", "effort", "fast", "speed", "tui", "context"] {
              if of != "new" || k != "tui" { p[k] = u.get(k).unwrap_or(Json::null()) }
            }
          _ => ()
        }
        pick_save(src, station, of, p, done=saved)
      }
    }
  }
  r.box(fn(line) {
    @sf.style_node(line, fn() { triple_liking })
    line.box(fn(mc) {
      @sf.style_node(mc, fn() { triple_models_column }, in_row=true)
      mc.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      triple_option_node(
        mc,
        name,
        picked,
        fn(row) {
          row.pick(fn() { (text(field(o(), "maker"), "id"), runs()) }, fn(m, k) { @sf.maker_mark_node(m, k.0, k.1, 14.0) |> ignore })
          // (all of its name in the room its column leaves it, on a second line where one is not enough: what goes with
          // the model picked beside the models takes the room its words need first)
          row.box(fn(nc) {
            @sf.style_node(nc, fn() { triple_name_column.then(@ui.style(w=Fixed(names_w()))) }, in_row=true)
            nc.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            nc.box(fn(nl) {
              @sf.style_node(nl, fn() { triple_name_line })
              nl.min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(nl, name, fn() { if picked() { triple_row_picked } else { triple_row_name } })
              .shrink(Is(1.0))
              .min_width(Is(Some(0.0)))
              |> ignore
              // (giving way to the name where the row is short: what the name leaves of it, cut short)
              nl.show(fn() { usual() != "" }, fn(u) {
                u.box(fn(ur) {
                  @sf.style_node(ur, fn() { triple_usual_room }, in_row=true)
                  ur.shrink(Is(1.0)).min_width(Is(Some(0.0))).clips(Is(true)) |> ignore
                  @sf.words_node(ur, usual, fn() { triple_usual }).cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
                })
                |> ignore
              }, along_row=true)
            })
            |> ignore
            nc.show(fn() { text(field(o(), "spent"), "text") != "" }, fn(sp) {
              @sf.words_node(sp, fn() { text(field(o(), "spent"), "text") }, fn() { triple_note }) |> ignore
            })
          })
          |> ignore
        },
        // (at its end where it comes from: its station's mark, where it is said over it on hover; else its name)
        trail=fn(e) {
          e.show(fn() { field(o(), "fromStation") is Some(Object(_)) }, fn(fs) {
            let st = fn() { field(o(), "fromStation") }
            fs.pick(fn() { text(st(), "icon") != "" || text(st(), "emoji") != "" }, fn(x, marked) {
              if marked {
                x.box(fn(m) {
                  @sf.station_mark_node(m, fn() { text(st(), "emoji") }, fn() { text(st(), "icon") }, 14.0, fn() { @sf.theme().p.muted }, fn() { 0 })
                  match tips {
                    Some(layer) => @sf.tip_node(layer, m, fn() { text(o(), "fromText") }) |> ignore
                    None => ()
                  }
                })
                |> ignore
              } else {
                @sf.words_node(x, fn() { text(st(), "name") }, fn() { triple_note_cut }) |> ignore
              }
            })
          })
        },
        tip=fn() { items(o(), "ids").filter_map(fn(i) { if i is String(s) { Some(s) } else { None } }).join("\n") },
        tips?,
        press=go,
      )
      |> ignore
    })
    |> ignore
    // (its star beside the row, not in it: a press of its own, as wide as an icon button is and as tall as the row,
    // in a slot of the row's height: icon_button's, what is pressed side by side one height)
    triple_beside_slot(line, fn(slot) {
    @sf.icon_button_node(
      slot,
      "star",
      fn() { @sf.t("web-main.model.likeModel", args=[("model", name())]) },
      fn() {
        let on = @signals.untracked(liked)
        (src.call)(
          "pick.like",
          { "station": Json::string(station), "of": Json::string(of), "model": Json::string(id), "liked": Json::boolean(!on) },
          fn(res) {
            match res {
              Ok(_) => ()
              Err(e) => toast_later(@sf.t("web-main.pick.failed", args=[("error", error_words(e))]))
            }
          },
        )
      },
      // (lit in the words' ink while starred, quiet while not: its old one's `ink`)
      ink=fn() { if liked() { @sf.theme().p.text } else { @sf.theme().p.muted } },
      icon_now=fn() { if liked() { "star-fill" } else { "star" } },
    )
    |> ignore
    })
  })
  |> ignore
}

///|
/// A slot beside a row of the models in node `line`, as tall as the row (the screen's picker rows) and no wider than
/// what `body` makes in it, its middle: an icon button at its own size (a star, what takes a configuration out), the
/// row and it one height side by side; a point further from the row than the row's own room leaves it (lit beside a
/// row lit, two apart: the theme's lit_apart), as far into the room past it, the panel as wide.
fn triple_beside_slot(line : @view.View, body : (@view.View) -> Unit) -> Unit {
  line.box(fn(slot) {
    slot
    .margin(Is((1.0, 0.0, -1.0, 0.0)))
    .height(By(fn() { Some(@sf.theme().rows.pick) }))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .row(Is(true))
    |> ignore
    body(slot)
  })
  |> ignore
}

///|
/// A configuration used most in node `r` (`x()`, one of the pick's `combos`; `o()` its model): its maker's mark, its
/// model's name, how it runs (the core's `text`) in a capsule after it, part of what the row is; drawn picked while it
/// is exactly what is drafted (`selected`). No star, a configuration is not starred: where a model's star is, what takes
/// it out of those used most (`pick.forget`, the user, 2026-11-10: 「常用模型应该是一种特定配置，并且可以删掉，跟模型没
/// 有关系」), a press of its own beside the row, the panel open; taken out, the row leaves the panel (the user,
/// 2026-11-13). Pressed, the panel closes and all of it is made what it runs on at once (`pick.save`): nothing sent
/// where it already runs on it.
fn triple_combo_row_node(
  r : @view.View,
  src : Source,
  station : String,
  of : String,
  v : () -> Json?,
  x : () -> Json?,
  o : () -> Json?,
  names_w : () -> Double,
  saved : String,
  close : () -> Unit,
  able? : () -> Bool = fn() { true },
) -> Unit {
  let on = fn() { flag(x(), "selected") }
  let name = fn() { text(x(), "name") }
  let how = fn() { text(x(), "text") }
  let label = fn() { if how() == "" { name() } else { name() + " · " + how() } }
  let params = fn() {
    let xx = @signals.untracked(x)
    let p : Map[String, Json] = { "model": Json::string(text(xx, "model")) }
    for k in ["runtime", "effort", "fast", "speed", "tui", "context"] {
      p[k] = field(xx, k).unwrap_or(Json::null())
    }
    p
  }
  let go = fn() {
    triple.open = ""
    close()
    if !@signals.untracked(on) || flag(@signals.untracked(v), "changed") {
      pick_save(src, station, of, params(), done=saved)
    }
  }
  r.box(fn(line) {
    @sf.style_node(line, fn() { triple_liking })
    line.box(fn(mc) {
      @sf.style_node(mc, fn() { triple_models_column }, in_row=true)
      mc.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      triple_option_node(
        mc,
        label,
        on,
        fn(row) {
          row.pick(fn() { (text(field(o(), "maker"), "id"), text(x(), "runtime")) }, fn(m, k) { @sf.maker_mark_node(m, k.0, k.1, 14.0) |> ignore })
          row.box(fn(nc) {
            @sf.style_node(nc, fn() { triple_name_column.then(@ui.style(w=Fixed(names_w()))) }, in_row=true)
            nc.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            nc.box(fn(nl) {
              @sf.style_node(nl, fn() { triple_name_line })
              nl.min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(nl, name, fn() { if on() { triple_row_picked } else { triple_row_name } })
              .shrink(Is(1.0))
              .min_width(Is(Some(0.0)))
              |> ignore
              // (giving way to the name where the row is short: cut short, all of it where the name leaves no room; its
              // capsule's sides too, which would else stand over what is at the row's end)
              nl.show(fn() { how() != "" }, fn(h) {
                h.box(fn(cr) {
                  @sf.style_node(cr, fn() { triple_combo_room }, in_row=true)
                  cr.shrink(Is(1.0)).min_width(Is(Some(0.0))).clips(Is(true)) |> ignore
                  cr.box(fn(cap) {
                    @sf.style_node(cap, fn() { triple_combo }, in_row=true)
                    cap.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                    @sf.words_node(cap, how, fn() { triple_combo_words }).cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
                  })
                  |> ignore
                })
                |> ignore
              }, along_row=true)
            })
            |> ignore
          })
          |> ignore
        },
        press=go,
        able~,
      )
      |> ignore
    })
    |> ignore
    // (beside it, where a model's star is: taken out of those used most)
    triple_beside_slot(line, fn(slot) {
    @sf.icon_button_node(
      slot,
      "close",
      fn() { @sf.t("web-main.model.forgetCombo", args=[("name", label())]) },
      fn() {
        let p = pick_params(station, of)
        for k, val in params() {
          p[k] = val
        }
        (src.call)("pick.forget", Json::object(p), fn(res) {
          match res {
            Ok(_) => ()
            Err(e) => toast_later(@sf.t("web-main.pick.failed", args=[("error", error_words(e))]))
          }
        })
      },
      ink=fn() { @sf.theme().p.muted },
      disabled=fn() { !able() },
    )
    |> ignore
    })
  })
  |> ignore
}

///|
/// A configuration's row's key: its model, runtime, how hard it thinks, how fast and how much context, so two of one
/// model are two.
fn triple_combo_key(x : Json?) -> String {
  let speed = text(x, "speed")
  let fast = if speed != "" {
    speed
  } else {
    match field(x, "fast") {
      Some(True) => "fast"
      Some(False) => "standard"
      _ => ""
    }
  }
  let context = match field(x, "context") {
    Some(Number(n, ..)) => n.to_int64().to_string()
    _ => ""
  }
  "combo/" + text(x, "model") + "/" + text(x, "runtime") + "/" + text(x, "effort") + "/" + fast + "/" + context
}

///|
/// A pick row's icon (a maker's mark, Fast's bolt) and its chevron.
let triple_pick_mark : Double = 14.0

///|
let triple_pick_chevron : Double = 12.0

///|
/// How hard it thinks at the panel's right in node `parent` (`choices()`: its value and its words, from the least to the
/// most; `now()` the one picked): each a row of the panel's under the one before, the one picked lit and checked, one
/// radio group called `label` (one stop of Tab's, ↑ ↓ picking along it); `pick` given the value pressed or come to.
fn triple_choices_node(
  parent : @view.View,
  label : String,
  choices : () -> Array[(String, String)],
  now : () -> String,
  pick : (String) -> Unit,
) -> Unit {
  // (@sf.radio_rows_node's: one radio group named by its column's head, one stop of Tab's, ↑ ↓ picking along it; its
  // rows the column's hair apart, triple_effort_column's)
  @sf.radio_rows_node(parent, fn() { label }, choices, now, pick, gap=@ui.Space::SPx.px(), fn(b, words, row) {
    @sf.style_node(b, fn() { triple_option_look(row.picked() || row.lit()) })
    b.min_width(Is(Some(0.0))) |> ignore
    @sf.words_node(b, words, fn() { if row.picked() { triple_picked } else { triple_words } }).cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
    b.box(fn(e) {
      @sf.style_node(e, fn() { triple_end }, in_row=true)
      e.basis(Is(None)).shrink(Is(0.0)) |> ignore
      e.pick(fn() { row.picked() }, fn(x, checked) {
        if checked {
          @sf.icon_node(x, "check", 14.0, By(fn() { @sf.theme().p.accent })) |> ignore
        } else {
          x.box(fn(k) { @sf.style_node(k, fn() { triple_check_room }, in_row=true) }) |> ignore
        }
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// A column's head (runPicker h4) in node `parent`: 4 over it, 6 under, as far in as the rows' words.
fn triple_column_head_node(parent : @view.View, words : String) -> Unit {
  parent.box(fn(h) {
    @sf.style_node(h, fn() { triple_head_box })
    @sf.words_node(h, fn() { words }, fn() { triple_head }).cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
  })
  |> ignore
}

///|
/// A row of a column (runPickerOption) in node `parent`, called `label`: as high as the screen's picker rows at least
/// (Theme::rows pick), 4 by 10 in, its ground under the hand and while `on()`; what `body` makes in it, `trail` (a
/// button of its own, the station a model comes from) at its end, a check after it while picked (its room kept while
/// not beside what opened the panel, as the web's hidden check; none at all with `checks` false); `tip()` over it while
/// it is pointed at (in `tips`); `press` done as it is pressed. Read out a button. Its node.
fn triple_option_node(
  parent : @view.View,
  label : () -> String,
  on : () -> Bool,
  body : (@view.View) -> Unit,
  trail? : (@view.View) -> Unit,
  tip? : () -> String,
  tips? : @sf.TipLayer,
  checks? : Bool = true,
  press~ : () -> Unit,
  able? : () -> Bool = fn() { true },
) -> @view.View {
  parent.box(fn(b) {
    // (across its column, as wide as its words need at least: what the column needs, the panel's columns laid out by it)
    @sf.style_node(b, fn() { triple_option_look(on() || @sf.lit_node(b)) })
    b.min_width(Is(Some(0.0))) |> ignore
    b.says(By(fn() { Some(@view.said(Button, label=label())) })) |> ignore
    @sf.presses_node(b, press, on=able)
    body(b)
    // what is at its end, at the end: the room left, never less than it needs; the check's room kept while it is not
    // picked
    let small = @sf.in_small_panel_node(b)
    b.box(fn(e) {
      @sf.style_node(e, fn() { triple_end }, in_row=true)
      // (never less than what it holds: the words before it give way first)
      e.basis(Is(None)).shrink(Is(0.0)) |> ignore
      match trail {
        Some(f) => f(e)
        None => ()
      }
      if checks {
        e.pick(on, fn(x, checked) {
          if checked {
            @sf.icon_node(x, "check", 14.0, By(fn() { @sf.theme().p.accent })) |> ignore
          } else if small {
            // (its room kept beside what opened the panel, which is as wide as its rows; a sheet's rows are the sheet's
            // width, and the room goes to their words)
            x.box(fn(k) { @sf.style_node(k, fn() { triple_check_room }, in_row=true) }) |> ignore
          }
        })
      }
    })
    |> ignore
    match (tips, tip) {
      (Some(layer), Some(t)) => @sf.tip_node(layer, b, t) |> ignore
      _ => ()
    }
  })
}

///|
/// A row of a column's look (triple_option_node's, triple_choices_node's): its ground while `lit` (under the hand, or
/// picked), as high as the screen's picker rows at least.
fn triple_option_look(lit : Bool) -> @ui.Style {
  (if lit { triple_option_on } else { triple_option_style }).then(@ui.style(min_h=Fixed(@sf.theme().rows.pick)))
}

///|
/// The explicit subset of accounts drafted (`None`: 全选, every eligible account; `Some([])`: 全不选, waiting for one
/// account to be tapped; `Some(ids)`: only those accounts).
fn triple_selected_accounts(draft : Json?) -> Array[String]? {
  match field(draft, "profiles") {
    Some(Array(xs)) => {
      let out : Array[String] = []
      for x in xs {
        if x is String(s) && s != "" && !out.contains(s) {
          out.push(s)
        }
      }
      return Some(out)
    }
    _ => ()
  }
  match text(draft, "profile") {
    "" => None
    id => Some([id])
  }
}

///|
/// The accounts (runPickerAccounts), in a panel of their own from who runs it: 全选 (tapping while all are checked
/// clears to 全不选 so tapping one account pins it directly; closing on 全不选 reverts to the saved selection), a quiet
/// rule, then each account on two crisp non-wrapping lines with 当前 at the active row's end.
fn triple_accounts_node(n : @view.View, src : Source, station : String, of : String, _close : () -> Unit) -> Unit {
  let v = fn() { src.topic("pick", pick_params(station, of)).get().value }
  let draft = fn() { field(v(), "draft") }
  let accounts = fn() { items(v(), "accounts") }
  let single_only = fn() { accounts().length() <= 1 }
  let all_on = fn() { triple_selected_accounts(draft()) is None }
  let none_on = fn() { triple_selected_accounts(draft()) is Some([]) }
  let repicking = "pick.repick/" + station + "/" + of
  n.show(fn() { text(v(), "dropped") != "" }, fn(w) {
    @sf.style_node(w, fn() { @sf.panel_words_in_node(w).then(triple_dropped_box) })
    @sf.words_node(w, fn() { text(v(), "dropped") }, fn() { triple_amber_sm }) |> ignore
  })
  @sf.choice_row_node(
    n,
    fn() { @sf.t("web-main.model.selectAll") },
    fn() { false },
    compact=true,
    disabled=single_only,
    lead=fn(l) {
      @sf.check_mark_node(l, all_on, mixed=fn() { !all_on() && !none_on() }, dimmed=single_only)
    },
    note=fn() { text(v(), "autoNote") },
    note_ink=fn() { if none_on() { @sf.theme().p.warn_ink } else { @sf.theme().p.muted } },
    trail?=if of.has_prefix("session:") {
      Some(fn(e) {
        e.show(fn() { text(v(), "repick") != "" }, fn(r) {
          r.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
          r.show(fn() { doing(repicking) }, fn(s) { @sf.spinner_node(s, size=14.0) |> ignore })
          @sf.panel_button_node(r, fn() { text(v(), "repick") }, fn() {
            if !doing(repicking) {
              let label = text(@signals.untracked(v), "repick")
              act(src, label, repicking, "pick.repick", Json::object(pick_params(station, of)), ok=fn(res) {
                match text(Some(res), "said") {
                  "" => ()
                  said => toast_later(said)
                }
              })
            }
          })
          |> ignore
        })
      })
    } else {
      None
    },
    press=fn() {
      if !@signals.untracked(single_only) {
        if @signals.untracked(all_on) {
          pick_draft(src, station, of, { "profiles": Json::array([]) })
        } else {
          pick_save(src, station, of, { "profiles": Json::null(), "profile": Json::null() })
        }
      }
    },
  )
  n.show(fn() { !accounts().is_empty() }, fn(d) {
    @sf.style_node(d, fn() { triple_accounts_rule })
    d.box(fn(l) { @sf.style_node(l, fn() { triple_rule_h }) }) |> ignore
  })
  n.each(accounts, fn(a) { text(Some(a), "id") }, fn(row, a) {
    let id = text(Some(a.untracked()), "id")
    let av = fn() { Some(a.get()) }
    let checked = fn() {
      match triple_selected_accounts(draft()) {
        None => true
        Some(sel) => sel.contains(id)
      }
    }
    @sf.choice_row_node(
      row,
      fn() { text(av(), "name") },
      fn() { false },
      compact=true,
      disabled=single_only,
      lead=fn(l) { @sf.check_mark_node(l, checked, dimmed=single_only) },
      note=fn() { text(field(av(), "quotaLine"), "text") },
      note_ink=fn() {
        match text(field(av(), "quotaLine"), "level") {
          "amber" => @sf.theme().p.warn_ink
          "red" => @sf.theme().p.red
          _ => @sf.theme().p.muted
        }
      },
      trail=fn(e) {
        e.show(fn() { flag(av(), "current") && accounts().length() > 1 }, fn(t) {
          @sf.words_node(t, fn() { @sf.t("web-main.model.current") }, fn() { triple_muted }) |> ignore
        })
      },
      press=fn() {
        if @signals.untracked(single_only) {
          return
        }
        let all_ids = @signals.untracked(accounts).map(fn(x) { text(Some(x), "id") }).filter(fn(x) { x != "" })
        let cur_ids = match triple_selected_accounts(@signals.untracked(draft)) {
          None => all_ids
          Some(xs) => xs
        }
        if cur_ids.contains(id) {
          let next = cur_ids.filter(fn(x) { x != id })
          if next.is_empty() {
            pick_draft(src, station, of, { "profiles": Json::array([]) })
          } else {
            pick_save(src, station, of, { "profiles": Json::array(next.map(fn(s) { Json::string(s) })) })
          }
        } else {
          let next = all_ids.filter(fn(x) { x == id || cur_ids.contains(x) })
          if next.length() >= all_ids.length() {
            pick_save(src, station, of, { "profiles": Json::null(), "profile": Json::null() })
          } else {
            pick_save(src, station, of, { "profiles": Json::array(next.map(fn(s) { Json::string(s) })) })
          }
        }
      },
    )
  })
}

///|
/// Borrowing the picked model's account from another station, asked first: what it does,
/// 取消 and its action.
fn borrow_dialog(c : @ui.Ctx, src : Source, station : String, of : String, v : Json?) -> Unit {
  let me = station + "\u{1}" + of
  let borrow = field(v, "borrow")
  let dkey = "pick.borrow/" + station + "/" + of
  let open = triple.borrow_asking == me && borrow is Some(Object(_))
  let lines = items(borrow, "lines").map(fn(l) {
    match l {
      String(s) => s
      _ => ""
    }
  })
  wide_confirm(c, "borrow/" + me, open, text(borrow, "title"), lines, text(borrow, "action"), doing(dkey), flag(borrow, "allowed"), fn(
    yes,
  ) {
    if yes {
      act(src, text(borrow, "action"), dkey, "pick.borrow", Json::object(pick_params(station, of)), done=@sf.t("web-main.model.borrowed"), ok=fn(_) {
        triple.borrow_asking = ""
        triple_let_go(me)
      })
    } else {
      triple.borrow_asking = ""
      triple_let_go(me)
    }
  })
}

///|
/// Borrowing a model of another station's asked first (borrow_dialog's), put up by the presenters as its panel's 借用 is
/// pressed (open_triple_panel's `asks`), what it holds nodes: its title, its lines, 取消 and its action at its foot (a
/// ring before them while it borrows), closed once it has borrowed it.
fn borrow_ask(src : Source, station : String, of : String, borrow : Json?) -> Unit {
  let dkey = "pick.borrow/" + station + "/" + of
  let lines = items(borrow, "lines").map(fn(l) {
    match l {
      String(s) => s
      _ => ""
    }
  })
  let action = text(borrow, "action")
  let allowed = flag(borrow, "allowed")
  @sf.panel_nodes(
    text(borrow, "title"),
    from=Unanchored,
    w=confirm_w,
    fn(b, _) {
      for l in lines {
        @sf.words_node(b, fn() { l }, fn() { confirm_line }) |> ignore
      }
    },
    foot=fn(f, shut) {
      f.box(fn(r) {
        @sf.style_node(r, fn() { confirm_foot })
        @sf.button_node(r, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
        r.show(fn() { doing(dkey) }, fn(s) { @sf.spinner_node(s, size=14.0) |> ignore })
        @sf.button_node(
          r,
          fn() { action },
          fn() {
            act(src, action, dkey, "pick.borrow", Json::object(pick_params(station, of)), done=@sf.t("web-main.model.borrowed"), ok=fn(_) {
              shut()
            })
          },
          tone=Primary,
          busy=fn() { doing(dkey) },
          disabled=fn() { !allowed },
        )
        |> ignore
      })
      |> ignore
    },
  )
}

///|
/// A dialog that asks before something is done (the web's Confirm, Dialog): its title, its lines, 取消 and `action`
/// (`danger`: in red). `said` told true as the action is pressed, false as 取消 is, or as Esc or a press outside closes
/// it.
fn wide_confirm(
  c : @ui.Ctx,
  key : String,
  open : Bool,
  title : String,
  lines : Array[String],
  action : String,
  busy : Bool,
  allowed : Bool,
  said : (Bool) -> Unit,
) -> Unit {
  let d = @sf.dialog(
    c,
    key,
    open,
    title,
    w=dmin(confirm_w, c.width - 32.0),
    close_label=@sf.t("common.close"),
    on_close=fn() { said(false) },
    fn() {
      for l in lines {
        c.text(l, style=confirm_line) |> ignore
      }
      c.box(style=confirm_foot, fn() {
        small_button(c, key + "/cancel", @sf.t("common.cancel"), false, true, on_press=fn() { said(false) })
        if busy {
          @sf.spinner(c, size=14.0) |> ignore
        }
        small_button(c, key + "/ok", action, true, allowed && !busy, on_press=fn() { said(true) })
      })
      |> ignore
    },
  )
  // (closed by Esc or a press outside: what the dialog says as it is built)
  if open && !d {
    said(false)
  }
}

///|
/// A small panel's small pill: 24 high, 10 in, its words in 12; `primary` dark with light
/// words, else quiet with the ground on hover; not pressed while `on` is false. `on_press` as it is pressed.
fn small_button(c : @ui.Ctx, key : String, words : String, primary : Bool, on : Bool, on_press? : () -> Unit) -> Unit {
  let id = c.id(key)
  let b = c.box(
    style=match (primary, on) {
      (true, true) => small_primary
      (true, false) => small_primary_off
      (false, _) => small_quiet
    },
    id~,
    fn() { c.text(words, style=if primary { small_primary_words } else { small_quiet_words }) |> ignore },
  )
  c.semantics(b, Button, id~, label=words)
  match on_press {
    Some(f) if on => c.on_press(id, f)
    _ => ()
  }
}

///|
/// How wide a dialog that asks is (Dialog: 420).
let confirm_w : Double = 420.0

///|
/// A part of the control's line after the model (triplePart): what it says and the dot before it, left out whole.
// kept across runs: a value (no field of it changes)
let triple_part : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
/// Who runs it by name after its mark (in the mark's part, triple_part's gap before it).
// kept across runs: a value (no field of it changes)
let triple_alone : @ui.Style = @ui.css("row align=ACenter")

///|
/// The order the control's line leaves its parts out in, short of room: who runs it by name
/// (in its part), who runs it, how hard it thinks and how fast, then the runtime.
let triple_drop_name : Int = 1

///|
let triple_drop_account : Int = 2

///|
let triple_drop_effort : Int = 3

///|
let triple_drop_runtime : Int = 4

///|
/// The triple as a row's value (28 high at its end, in its middle): a capsule, as the round controls beside it are, its
/// shape its height's wherever the row's corners are (a row's corner with it at its end 10 in would be 10 here, 8.4 in
/// a finger's taller row, its own 8 in neither).
// kept across runs: a value (no field of it changes)
let triple_style : @ui.Style = @ui.css("row h=S7 px=S2_5 gap=S1_5 align=ACenter radius=Full hovered{bg=Hover}")

///|
/// The room between a model control's parts (triple_style's gap=S1_5), as nodes: the row of them in the capsule.
let triple_gap : Double = 6.0

///|
// kept across runs: a value (no field of it changes)
let triple_on : @ui.Style = @ui.css("row h=S7 px=S2_5 gap=S1_5 align=ACenter radius=Full bg=Hover")

///|
// kept across runs: a value (no field of it changes)
let triple_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let triple_picked : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let triple_muted : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// What a column says where it has nothing to list, on as many lines as it takes.
// kept across runs: a value (no field of it changes)
let triple_muted_lines : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
/// The head of the models where whose models they are is a choice (models_head's): the choice at its start, the
/// search at its end.
// kept across runs: a value (no field of it changes)
let triple_scope_head : @ui.Style = @ui.css("row w=Full pb=S1_5 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let triple_scope_choice : @ui.Style = @ui.css("row")

///|
// kept across runs: a value (no field of it changes)
let triple_amber : @ui.TextStyle = @ui.text_style(size=Ui, color=WarnInk, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let triple_red : @ui.TextStyle = @ui.text_style(size=Ui, color=Danger, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let triple_amber_sm : @ui.TextStyle = @ui.text_style(size=Meta, color=WarnInk)

///|
// kept across runs: a value (no field of it changes)
let triple_note : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// What the station's pick is on, under 自动: cut short where what picks again beside it needs the room.
// kept across runs: a value (no field of it changes)
let triple_note_cut : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
/// A column's head (runPicker h4): 12, muted, medium; 4 over it, 6 under, as far in as the rows' words.
// kept across runs: a value (no field of it changes)
let triple_head : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let triple_search : @ui.Style = @ui.css("w=Full pb=S2")

///|
/// The search: as tall as the panel's rows (a small panel's search is 34), round, on the words' tint (deeper pointed at or typed in), its glass 12 in and 8 before its
/// words.
// kept across runs: a value (no field of it changes)
let triple_find : @ui.Style = @ui.css("row w=Full px=S3 gap=S2 align=ACenter radius=Full bg=Tint")

///|
// kept across runs: a value (no field of it changes)
let triple_find_hot : @ui.Style = @ui.css("row w=Full px=S3 gap=S2 align=ACenter radius=Full bg=TintStrong")

///|
/// The search's glass.
let triple_find_icon : Double = 14.0

///|
/// A line across (a history's under its figures; the panel's over its foot is the presenters', `ruled`: kept,
/// 2026-10-25 用户「这两个的分割线可以保留」).
// kept across runs: a value (no field of it changes)
pub let triple_rule_h : @ui.Style = @ui.css("w=Full h=SPx bg=Line")

///|
pub let triple_models_least : Double = 200.0

///|
/// A column's rows, 1 apart.
// kept across runs: a value (no field of it changes)
let triple_rows : @ui.Style = @ui.css("w=Full gap=SPx")

///|
/// The first level's rows (triple_body's), one after another, the room between them each one's own (triple_first_gap).
// kept across runs: a value (no field of it changes)
let triple_first_rows : @ui.Style = @ui.css("w=Full")

///|
/// The room between a row of the first level and the next (triple_body_node's), in the row itself, as far as
/// triple_rows' rows are apart: closing with the row as it leaves.
// kept across runs: a value (no field of it changes)
let triple_first_gap : @ui.Style = @ui.css("w=Full h=SPx")

///|
/// A row's ground, concentric with its small panel as a menu's row is (panel_in): a capsule 34 high, a taller row (an
/// account with what is left of it under its name) the ladder's 18, not a capsule as round as half its height.
// kept across runs: a value (no field of it changes)
let triple_option_style : @ui.Style = @ui.css((
  #|row w=Full px=S2_5 py=S1 gap=S1_5 align=ACenter hovered{bg=Hover}
)).then(@ui.style(radius=@sf.panel_in))


///|
// kept across runs: a value (no field of it changes)
let triple_option_on : @ui.Style = @ui.css((
  #|row w=Full px=S2_5 py=S1 gap=S1_5 align=ACenter bg=Hover
)).then(@ui.style(radius=@sf.panel_in))

///|
/// A model's name in its row: across the room left in it, on two lines where it needs them (cut short past those, a
/// name longer than any).
// kept across runs: a value (no field of it changes)
let triple_row_name : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, w=Full, max_lines=2)

///|
// kept across runs: a value (no field of it changes)
let triple_row_picked : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, w=Full, max_lines=2)

///|
/// A model's name and what is under it: as wide as said, giving way to the room its row leaves where that is less.
// kept across runs: a value (no field of it changes)
let triple_name_column : @ui.Style = @ui.css("min_w=SPx gap=SPx")

///|
/// Where a row's check is while it is not picked: the row as wide picked or not (its column's words then as wide).
// kept across runs: a value (no field of it changes)
let triple_check_room : @ui.Style = @ui.css("w=S3_5")

///|
// kept across runs: a value (no field of it changes)
let triple_liking : @ui.Style = @ui.css("row w=Full gap=SPx align=ACenter")

///|
/// All the models beside what opened the panel: the makers, a line, a maker's models.
// kept across runs: a value (no field of it changes)
let triple_browse : @ui.Style = @ui.css("row w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let triple_kinds_column : @ui.Style = @ui.css("w=S48")

///|
// kept across runs: a value (no field of it changes)
let triple_models_column : @ui.Style = @ui.style(w=@sf.grow)

///|
/// The line between them (the panel's columns', 2026-10-25 用户 kept them).
// kept across runs: a value (no field of it changes)
let triple_rule_v : @ui.Style = @ui.css("w=SPx bg=Line")

///|
/// The models and how hard it thinks side by side, 8 apart, the line between them in the middle of that.
// kept across runs: a value (no field of it changes)
let triple_side_by_side : @ui.Style = @ui.css("row w=Full gap=S2")

///|
/// Where the line between them starts, from how hard it thinks' start: in the middle of the 8 between them.
let triple_between_rule : Double = 4.5

///|
/// How hard it thinks beside the models: as wide as its words need.
// kept across runs: a value (no field of it changes)
let triple_effort_column : @ui.Style = @ui.css("gap=SPx")

///|
/// A kind's mark, as wide as a model's.
// kept across runs: a value (no field of it changes)
let triple_kind_mark : @ui.Style = @ui.css("w=S3_5 align=ACenter justify=JCenter")

///|
/// How a model runs picked, right after its name: Meta, muted, on one line.
// kept across runs: a value (no field of it changes)
let triple_usual : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
/// How one of those used most runs, after its name: a capsule on the words' tint, its words the rows' own colour.
// kept across runs: a value (no field of it changes)
let triple_combo : @ui.Style = @ui.css("row min_h=S5 px=S2 align=ACenter radius=Full bg=Tint")

///|
// kept across runs: a value (no field of it changes)
let triple_combo_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false, w=Cut)

///|
/// A configuration's capsule's room: as its words', down to nothing, the capsule cut where the name leaves less.
// kept across runs: a value (no field of it changes)
let triple_combo_room : @ui.Style = triple_usual_room.then(@ui.css("min_w=S0 clip"))

///|
/// Its room: right after the name, what the name leaves of the row.
// kept across runs: a value (no field of it changes)
let triple_usual_room : @ui.Style = @ui.style(row=true, w=@sf.grow)

///|
/// A model's name with how it runs right after it, on its words' line.
// kept across runs: a value (no field of it changes)
let triple_name_line : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let triple_empty : @ui.Style = @ui.css("px=S2_5 py=S2")

///|
// kept across runs: a value (no field of it changes)
let triple_borrow : @ui.Style = @ui.css("w=Full px=S2_5 py=S1_5")

///|
// kept across runs: a value (no field of it changes)
// Keep the first and last capsules at the panel's side insets when the body is wider than their words.
let triple_who_room : @ui.Style = @ui.style(row=true, w=@sf.grow, align=ACenter, justify=JBetween, gap=S2)

///|
// kept across runs: a value (no field of it changes)
let triple_mode_room : @ui.Style = triple_who_room.then(@ui.css("justify=JBetween"))

///|
/// Who runs it, a capsule at the foot's start as tall as the foot's buttons (@sf.button_height), so standing in the
/// panel's foot corner where they stand in the other, concentric with it, as far from its foot as from its side.
fn triple_who(hot? : Bool = false) -> @ui.Style {
  (if hot { triple_who_hot } else { triple_who_look }).then(@ui.style(h=Fixed(@sf.button_height())))
}

///|
// kept across runs: a value (no field of it changes)
let triple_who_look : @ui.Style = @ui.css("row px=S3 gap=S1 align=ACenter radius=Full bg=Tint hovered{bg=TintStrong}")

///|
/// Who runs it under the hand: its ground deeper.
// kept across runs: a value (no field of it changes)
let triple_who_hot : @ui.Style = @ui.css("row px=S3 gap=S1 align=ACenter radius=Full bg=TintStrong")

///|
// kept across runs: a value (no field of it changes)
let triple_who_lead : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let triple_who_name : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let triple_who_amber : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=WarnInk, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let triple_who_red : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Danger, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let triple_dropped_box : @ui.Style = @ui.css("w=Full pb=S1_5")

///|
// kept across runs: a value (no field of it changes)
let small_primary : @ui.Style = @ui.css("h=S6 px=S2_5 align=ACenter justify=JCenter radius=Full bg=Primary")

///|
// kept across runs: a value (no field of it changes)
let small_primary_off : @ui.Style = @ui.css((
  #|h=S6 px=S2_5 align=ACenter justify=JCenter radius=Full bg=Primary opacity=O50
))

///|
// kept across runs: a value (no field of it changes)
let small_quiet : @ui.Style = @ui.css("h=S6 px=S2_5 align=ACenter justify=JCenter radius=Full hovered{bg=Hover}")

///|
// kept across runs: a value (no field of it changes)
let small_primary_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=OnPrimary, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let small_quiet_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let confirm_line : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let confirm_foot : @ui.Style = @ui.css("row w=Full pt=S3 gap=S2 align=ACenter justify=JEnd")

///|
/// The models beside what opened it: 360 high at most (runPicker).
let triple_list_h : Double = 360.0

///|
/// How much room under its control its panel beside it needs (its models' most, its head and its foot), short of which
/// it goes up from a control with more room over it (model_triple_node).
let triple_up_need : Double = triple_list_h + 140.0

///|
/// No maker asked for (TriplePanel's `kind`, a sheet's step's): no maker's id, the makers not known having the id "".
let triple_no_kind : String = "\u{1}"

///|
/// How many models all of them are listed at once up to; more, by their makers.
let triple_flat_most : Int = 12

///|
/// How many rows the models' room shows in a sheet at most: eleven and a half, the half saying there is more.
let triple_sheet_rows : Double = 11.5

///|
/// Between those used most and the rest of a few, in their one list.
// kept across runs: a value (no field of it changes)
let triple_apart : @ui.Style = @ui.css("w=Full h=S2")

///|
/// The models' room (as tall as what it holds, to its most: triple_body's `list_most`; beside what opened it, where
/// the models go by level, its most at every level: `level_h`).
// kept across runs: a value (no field of it changes)
let triple_room : @ui.Style = @ui.css("w=Full gap=SPx")

///|
/// How hard it thinks in a sheet, under the models: its name before its stops on one line across the sheet.
// kept across runs: a value (no field of it changes)
let triple_effort_block : @ui.Style = @ui.css("row w=Full pl=S2_5 pt=S1_5 gap=S3 align=ACenter")

///|
/// The accounts' sub-panel width on 中屏/大屏, wide enough for multi-window quota summaries on one line.
let triple_accounts_w : Double = 340.0

///|
// kept across runs: a value (no field of it changes)
let triple_accounts_rule : @ui.Style = @ui.css("w=Full py=S1")

///|
/// The most the panel is wide beside its control, as wide as its columns' words within it (the web's: the models' 200
/// to 300, the runtimes' and the efforts' columns).
let triple_panel_w : Double = 520.0

///|
/// The same where its models are many: their makers a column before a maker's models.
let triple_panel_w_many : Double = 660.0

///|
// kept across runs: a value (no field of it changes)
let triple_head_box : @ui.Style = @ui.css("px=S2_5 pt=S1 pb=S1_5")

///|
/// In a composer's row (newChat's): 28 high, 8 in, its words 12.
// kept across runs: a value (no field of it changes)
let triple_small : @ui.Style = @ui.css("row h=S7 px=S2 gap=S1_5 align=ACenter radius=Lg hovered{bg=Hover}")

///|
// kept across runs: a value (no field of it changes)
let triple_small_on : @ui.Style = @ui.css("row h=S7 px=S2 gap=S1_5 align=ACenter radius=Lg bg=Hover")

///|
// kept across runs: a value (no field of it changes)
pub let triple_words_xs : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
/// The model's name in the control: its words, cut short once all that may leave the control's row has left.
// kept across runs: a value (no field of it changes)
let triple_name : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let triple_name_xs : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
pub let triple_muted_xs : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// The control of the pick `of` on `station` with its panel open (a screen's fixture).
pub fn open_triple(station : String, of : String) -> Unit {
  triple.asked = station + "\u{1}" + of
}

///|
/// The same with its accounts open over it (a screen's fixture).
pub fn open_triple_accounts(station : String, of : String) -> Unit {
  open_triple(station, of)
  triple.accounts_asked = true
}
