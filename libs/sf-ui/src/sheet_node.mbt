// A panel whose body and foot are nodes (panel_nodes) as a sheet from the foot of the window (小屏's: @kit.sheet's, the
// host's present_sheet), as nodes of the window's tree: a modal layer over the window, what is under it dimmed by the
// sheet's scrim (black at 28%, in and out over @motion.sheet_scrim_ms, CSS's ease), the sheet in the window's foot as
// tall as what it holds (sheet_most of the window at most, what it holds scrolling in it past that; one a share of the
// window tall, `tall`, that share, what it holds filling the room it leaves and laid out in it), its top corners
// the pane's, on the frosted glass of a sheet; its grabber over its title (none where what it holds heads itself,
// `heads_itself`), what it says, what it holds and its foot, laid out as the host's sheet lays a panel out
// (sheet_step); its title and what it says as they are now where it says them (`live`), its title's row there while
// it has one. It rises from below on a Move as long as its own height
// makes it (SheetRise, placed as it is drawn by how tall it is laid out: View::moved_by) and sinks away on one as
// it closes. Its top (sheet_drag_h: the grabber and the head) drags it down with the finger: let go more than
// sheet_drag_close down it closes, from where it is, else it goes back on a Move as fast as it was let go. Escape, the
// back and a press on what is above it close it (its gone told); what it holds closes it with what it was given.

///|
/// How far down a sheet's top is dragged before it closes as it is let go (@kit.sheet's, one without detents).
let sheet_drag_close : Double = 80.0

///|
/// How tall a sheet's top stands, that drags it (@kit.sheet's `drag_h`: the grabber and the head).
let sheet_drag_h : Double = 64.0

///|
/// A page of a sheet (sheet_node's `pages`): its number in its sheet (the first, the sheet's own, 0), its panel (what it
/// holds and its foot its nodes), what what it holds is given to close the sheet, what opened it.
priv struct SheetPage {
  n : Int
  x : PanelOf
  close : () -> Unit
  from : Anchor
}

///|
/// Whether panel `x` on 小屏 is a sheet of the window's tree (sheet_node), a page of one where it is a step further
/// in: not a stage.
fn sheet_panel_of(x : PanelOf) -> Bool {
  !x.stage
}

///|
/// What a sheet's title's words stand in, in its row: the room left along it, the words as wide as they are in it,
/// going on in another line where they have not the room.
// kept across runs: a value (no field of it changes)
let sheet_title_room : @ui.Style = @ui.css("w=Full align=AStart")

///|
/// A sheet's column flush with its sides (PanelNodes' `flush`) opened by a press: sheet_held's room under it alone.
// kept across runs: a value (no field of it changes)
let sheet_flush_held : @ui.Style = @ui.css("w=Full pb=S6")

///|
/// A sheet's column flush with its sides opened by nothing: sheet_panel's room under it and between its parts alone.
// kept across runs: a value (no field of it changes)
let sheet_flush_panel : @ui.Style = @ui.css("w=Full gap=S2_5").then(@ui.style(pb=room(sheet_panel_foot)))

///|
/// A sheet of the panels `pages()` in `parent` while `open()`: the last of them the one that shows, those before it
/// the ones it is a step further in from, each kept as it was left (what it holds made once, laid out and drawn off to
/// the sheet's side while it is not the one that shows); one put on slides in from the sheet's end over the one before
/// as that one slides off to its start, one taken off slides away to the end as the one before comes back, the sheet
/// going from as tall as it stood to as tall as the one that shows makes it on a Move as long (a panel's steps',
/// steps_shown's, as nodes); each past the first headed by a back key, `page_back`. `cancel` as it is closed by a
/// press over it or its top dragged down, and by Escape and the back where `page_back` says it went back no page.
/// `stood`: how tall it stood as its last page was put on or taken off (asked of `stands_by`'s then). `shown`, `gone`: as
/// dialog_layer_node's. `covered_by`: how tall the sheet over it is, while one is (it steps back under it, pushed up out
/// of its way and dimmed, as the host's sheet does: present_sheet's recede). `in_place`: presented in the place of a
/// sheet that stood so tall, gone at that moment (what was chosen in that one opened this): there at once that tall, its
/// scrim whole as that one's was, on a Move to its own height from there, not from below (@kit.sheet's `in_place`).
/// `step_back`: a step further in from a panel (the presenters' `under`): what its back key before its title, the system's
/// back and Escape do in `cancel`'s place. `stands_by`: given what says how tall it stands over the window's foot (where
/// it was last placed), asked as it closes: where what comes in its place starts. `rises`: told how tall it is laid out
/// as it begins to rise (a sheet under it pushed up out of its way so far: covered_by's for that one). `taken`: whether, closed, another
/// sheet is presented in its place: it is drawn no more then, that one there, its scrim that one's. `dims`: whether its
/// scrim dims what is under it, as it is now (presenters' scrim_owner: one scrim however many sheets are over one
/// another, whichever draws each).
fn sheet_node(
  parent : @view.View,
  open : () -> Bool,
  pages : () -> Array[SheetPage],
  cancel : () -> Unit,
  shown? : () -> Unit = fn() {  },
  gone? : () -> Unit = fn() {  },
  covered_by? : () -> Double? = fn() { None },
  rises? : (Double) -> Unit = fn(_) {  },
  in_place? : Double,
  step_back? : () -> Unit,
  page_back? : () -> Bool = fn() { false },
  stood? : () -> Double = fn() { 0.0 },
  stands_by? : (() -> Double) -> Unit = fn(_) {  },
  taken? : () -> Bool = fn() { false },
  dims? : () -> Bool = fn() { true },
) -> Unit {
  parent.show(
    open,
    fn(layer) {
      shown()
      layer.owns(gone) |> ignore
      // (the field it opens to be typed in, where what it holds says one: panel_opens_in_node; a search at hand,
      // panel_search_at_hand_node's, not on a sheet)
      let field : Ref[PanelField?] = Ref(None)
      layer.lends(panel_field_lent, field) |> ignore
      // (what its fields offer made in it: offers_layer_lent)
      offers_layer_lend(layer)
      // (how far its scrim is in; how far below its place it is, in its own heights; how far a finger has its top down)
      // (in another's place: its scrim whole from the first, where that one stood, not below)
      let dim = @motion.NodeWay::new(if in_place is Some(_) { 1.0 } else { 0.0 })
      let below = SheetRise::new()
      // (its box, once it is made: how tall it is as a way is said)
      let sheet_box : Ref[@view.View?] = Ref(None)
      // (as tall as it stood when what it shows was last put in another's place, and when: in another sheet's place
      // (`in_place`), on a Move as long as that is far; a page put on or taken off, with its slide, as long as the
      // sheet is wide; what an old body holds come to be another height, from as tall as it was seen then and as fast
      // as it went, as far; how fast it went then, its points a millisecond)
      let placed : @signals.Signal[(Double, Double, Double, Double)?] = @signals.signal(
        match in_place {
          Some(stood) => {
            below.risen = true
            Some((stood, layer.cause_at(), 0.0, 0.0))
          }
          None => None
        },
        same=fn(a, b) { a == b },
      )
      // (how far its foot reaches on under the window's: by its corner; in the place of what stood taller than it,
      // drawn so tall at first, its foot that much under the window's as it is laid out: as far as the tallest it
      // stood in the place of)
      let reach = @signals.signal(sheet_under + in_place.unwrap_or(0.0))
      // (the page that shows, and whether what it holds fills a share of the window)
      let top = fn() {
        let all = pages()
        all[all.length() - 1]
      }
      let capped_of = fn(x : PanelOf) { x.tall > 0.0 && !x.form }
      let hugs_of = fn(pg : SheetPage) { pg.x.nodes.hugs }
      let held : @signals.Signal[Double?] = @signals.signal(None)
      // (how long its way from as tall as it stood takes, `own` tall: as long as that is far, `least` at least (a page's
      // slide's, what was left of a way it carries on))
      // (how tall it was laid out as that way was said, its cause's: how long it is and how it turns are said by that
      // once, whatever what it holds comes to as it goes (a page put on, then what it holds growing as it slides in, went
      // another length each frame, a step where the Move's length passed the slide's); only where it ends follows how
      // tall it comes to, as SheetRise's plan; NaN: as tall as it is)
      let placed_plan : Ref[Double] = Ref(0.0 / 0.0)
      let plan_of = fn(own : Double) { if placed_plan.val.is_nan() { own } else { placed_plan.val } }
      let placed_ms = fn(_w : Double, own : Double, stood : Double, least : Double) {
        dmax(least, @ui.move_ms((plan_of(own) - stood).abs()))
      }
      // (that way, set out at `v` (how fast how far it is drawn off its place goes): a Move on from that speed where it
      // goes toward its end, as long as placed_ms; turned away from it (a page put on as the sheet rose, to a page
      // less tall), slowing at one rate first and back from there, as any way turned back does (come_way_by), as long
      // as that takes: how far it is drawn off its place `t` ms on, and how fast that goes)
      let placed_turned = fn(own : Double, stood : Double, v : Double) { v * (stood - plan_of(own)) < 0.0 }
      let placed_path = fn(own : Double, stood : Double, v : Double, t : Double, least : Double) {
        if placed_turned(own, stood, v) {
          // (its way said from as tall as it was planned; how far it is off its end goes as what it comes to does)
          let p = plan_of(own) - stood
          let (x, xv) = @ui.come_way_by(p, v, 0.0, 0.0, t)
          let k = if p != 0.0 { (own - stood) / p } else { 1.0 }
          (x * k, xv * k)
        } else {
          @ui.move_path(own - stood, v, t, placed_ms(0.0, own, stood, least))
        }
      }
      let placed_end = fn(own : Double, stood : Double, v : Double, least : Double) {
        if placed_turned(own, stood, v) {
          @ui.come_way_ms(plan_of(own) - stood, v, 0.0)
        } else {
          placed_ms(0.0, own, stood, least)
        }
      }
      let back = @motion.NodeWay::new(0.0)
      // (one that grows (`grows`): how tall it is where it was dragged or tapped to another height, or a finger has it;
      // as tall as what it holds till then)
      let sized = @signals.signal(false)
      let tall = @motion.NodeWay::new(0.0)
      let tall_held : @signals.Signal[Double?] = @signals.signal(None)
      // (closed with another in its place: drawn no more)
      let vanished = fn() { layer.leaving() && taken() }
      let live = fn() { !layer.leaving() }
      @ui.holds_ime_leaving(layer, active=fn() { !vanished() })
      let had_ime : Ref[Bool] = Ref(false)
      let live_win_h : Ref[Double] = Ref(0.0)
      let ime_under = fn() {
        let kb = layer.keyboard_inset()
        let in_ime = live() && (@ui.focused_editor_in_node(layer) || (had_ime.val && kb > 0.0))
        if live() {
          had_ime.val = in_ime
        }
        if in_ime { 0.0 } else { kb }
      }
      let win_h = fn() { layer.window().1 + ime_under() }
      let body_win_h = fn() {
        let wh = win_h()
        if live() {
          live_win_h.val = wh
          wh
        } else if live_win_h.val > 0.0 {
          live_win_h.val
        } else {
          wh
        }
      }
      // (how fast a finger had it going down as it let it go, closing it: what it sinks away at from there; none, from
      // rest)
      let let_go_speed : Ref[Double?] = Ref(None)
      // (as wide and as tall as it was last drawn, its foot's room past the window's taken off: what its ways' ends are
      // worked out by for @kit.sheet_rest, as moved_by works them out; and as tall as it was seen then, on its way from
      // as tall as it stood: where its height sets out from as it comes to another of its own)
      let drawn : Ref[(Double, Double, Double)] = Ref((0.0, 0.0, 0.0))
      // (while a finger drags the sheet down or it springs back, dim the scrim with its drag progress; once leaving,
      // `dim` fades out from the release alpha)
      let drag_dim_factor = fn() -> Double {
        if layer.leaving() {
          1.0
        } else if @signals.untracked(fn() { top().x.grows }) {
          match tall_held.get() {
            Some(h) => {
              let lo = sheet_grows_to[0] * win_h()
              if lo > 0.0 { dclamp(h / lo, 0.0, 1.0) } else { 1.0 }
            }
            None => 1.0
          }
        } else {
          let down = match held.get() {
            Some(y) => y
            None => back.shown(layer)
          }
          let own = dmax(drawn.val.1, sheet_drag_close)
          dclamp(1.0 - down / own, 0.0, 1.0)
        }
      }
      let live_dim = fn() -> Double { dim.shown(layer) * drag_dim_factor() }
      // (its foot drawn back by how far it is drawn off its place on its way from as tall as it stood (as tall as it was
      // last drawn): staying at the window's foot as its top goes, as the host's sheet's foot does)
      // (how far its foot was drawn back as it closed on its way from as tall as it stood: carried's; none else)
      let foot_carried : @signals.Signal[Double] = @signals.signal(0.0)
      // (its own height as it is laid out at the logic's moment, its foot's room past the window taken off: what a
      // cause reads, never what the frame drawn last had (drawn.val), which is the rate's: a way set off from it went one
      // way at 60 a second and another at 120 (history_test's closes); none where it is not laid out yet)
      // (how fast its height went as it was last asked how tall it stands (stands_by's): what a page put on or taken
      // off then sets out at from there, as a way set off again does, not from rest)
      let stood_v : Ref[Double] = Ref(0.0)
      // (and how fast that height goes then, what it holds growing or shrinking: grows_now's)
      let own_growing = fn() -> (Double, Double) {
        match sheet_box.val {
          Some(b) if b.alive() => {
            let (h, hv) = b.grows_now()
            (dmax(h - reach.untracked(), 0.0), hv)
          }
          _ => (0.0, 0.0)
        }
      }
      // (its own height laid out as the presenters last asked how tall it stands (stands_by), before what it shows is
      // changed: what a page put on then takes its rise up from)
      let stood_own : Ref[Double] = Ref(0.0)
      let own_now = fn() { own_growing().0 }
      // (how far up it is drawn back at `t`, and when that way ends)
      // (a rise taken up into a way from as tall as it was seen, as it was then and as tall as it was: what of that way
      // is its rise, which its foot rose with, not drawn back)
      let folded : Ref[(SheetRise, Double)?] = Ref(None)
      // (`own`: its own height, as the frame drawing it lays it out, or at a cause, own_now)
      let foot_back = fn(t : Double, own : Double) {
        match placed.get() {
          Some((stood, at, least, v)) => {
            let rise = match folded.val {
              Some((r, d)) => r.shown(d, t)
              None => 0.0
            }
            placed_path(own, stood, v, t - at, least).0 - rise
          }
          // (closed on that way: drawn back as far as it was then, sinking away with the sheet from there)
          None => foot_carried.get()
        }
      }
      let foot_back_end = fn() {
        let (_, own, _) = drawn.val
        match placed.get() {
          Some((stood, at, least, v)) => at + placed_end(own, stood, v, least)
          None => -1.0
        }
      }
      // (the page that shows alone: one that does not, sliding off as another comes in its place from as tall as it
      // stood, keeps its foot where it stood, as it is laid out, not drawn back by the way the sheet's height goes for
      // the page coming)
      // (`own`: a page of nodes as tall as what it holds: on its slide in, from as tall as the page before stood to as
      // tall as it is, none drawn back, its foot under what it holds as it is laid out, the sheet's top going between
      // the two; only what it holds come to another height keeps its foot at the window's. One a share of the window
      // tall, and an old body, has its foot at the window's all the way)
      let step_placed : Ref[Bool] = Ref(false)
      let back_of = fn(shows : () -> Bool, own : Bool, t : Double) {
        if shows() && !(own && step_placed.val) {
          foot_back(t, drawn.val.1)
        } else {
          0.0
        }
      }
      let foot_stays = fn(f : @view.View, shows : () -> Bool, own : Bool) {
        f.moved_by(fn(_, _, t) { (0.0, -back_of(shows, own, t)) }, fn(_, _) { foot_back_end() }) |> ignore
      }
      // (what a page holds over its foot, in `page` (`grows`: filling the room the page leaves it): cut off where its
      // foot drawn back stands over it, so none of it shows under the foot on that way (the host's sheet holds what it
      // holds in its height as it goes): a box drawn up as far as the foot is, cutting, what it holds drawn back down
      // as far)
      let body_box = fn(page : @view.View, grows : Bool, nodes : Bool, shows : () -> Bool, make : (@view.View) -> Unit) {
        page.box(fn(o) {
          // (one made of nodes that does not show, laid aside from the sheet's top as tall as it is, gives way in
          // nothing: the page's `from_top`)
          o
          .grow(Is(if grows { 1.0 } else { 0.0 }))
          .shrink(By(fn() { if !nodes || shows() { 1.0 } else { 0.0 } }))
          .min_height(Is(Some(0.0)))
          .clips(Is(true))
          |> ignore
          o.moved_by(fn(_, _, t) { (0.0, -dmax(0.0, back_of(shows, nodes, t))) }, fn(_, _) { foot_back_end() }) |> ignore
          o.box(fn(b) {
            b.moved_by(fn(_, _, t) { (0.0, dmax(0.0, back_of(shows, nodes, t))) }, fn(_, _) { foot_back_end() }) |> ignore
            make(b)
          })
          |> ignore
        })
        |> ignore
      }
      // (what an old body that shows holds built again, at that cause: whatever height it comes to, the sheet goes there
      // from as tall as it is seen at that moment and as fast as it goes then, as the host's sheet's height goes; drawn
      // once at least, else it rises as it is)
      // (its rise over at once, what was left of it taken up by a way from as tall as it is seen)
      // (`own`: how tall it was as it rose, the moment that way is taken up: its height laid out then, as the presenters
      // asked how tall it stood (stood_own) where what shows is changed already)
      let settle = fn(own : Double) {
        // (its rise as it was, for its foot: what of the way it is taken up into is its rise)
        folded.val = Some(({ risen: below.risen, way: below.way, said: @signals.signal(0) }, own))
        below.way = None
        below.risen = true
        below.said.set(below.said.untracked() + 1)
      }
      // (how tall it is seen at moment `at`, on its way from as tall as it stood and rising from below, and how fast its
      // top goes then; its rise over from then, what is left of it on that way: drawn once at least, else none)
      let seen_from = fn(at : Double, settles : Bool) -> (Double, Double, Double)? {
        // (drawn once at least: as tall as it is laid out at that moment, not as it was last drawn)
        let (_, drawn_own, _) = drawn.val
        let (own, own_v) = own_growing()
        guard drawn_own > 0.0 && own > 0.0 else { return None }
        let (dx, dv, left) = match placed.untracked() {
          Some((stood, at0, least, v)) => {
            let ms = placed_end(own, stood, v, least)
            let (dx, dv) = placed_path(own, stood, v, at - at0, least)
            (dx, dv, dmax(0.0, at0 + ms - at))
          }
          None => (0.0, 0.0, 0.0)
        }
        let (u, uv) = below.top_at(own, own_v, at)
        let rising = own - u
        if settles && rising != 0.0 && @signals.untracked(live) {
          settle(own)
        }
        // (as fast as both had it going: what is left of its rise taken up with its speed, not from rest)
        Some((own - dx - rising, dv - uv, left))
      }
      // (how far it was drawn off its place then, and how fast that went: what its sink sets out from with it)
      let carried = fn() -> (Double, Double) {
        foot_carried.set(0.0)
        let (_, drawn_own, _) = drawn.val
        let own = own_now()
        guard drawn_own > 0.0 && own > 0.0 && placed.untracked() is Some((stood, at0, least, v)) else {
          return (0.0, 0.0)
        }
        let at = layer.cause_at()
        let (dx, dv) = placed_path(own, stood, v, at - at0, least)
        guard dx != 0.0 || dv != 0.0 else { return (0.0, 0.0) }
        foot_carried.set(@signals.untracked(fn() { foot_back(at, own) }))
        placed.set(None)
        (dx, dv)
      }
      let reshaped = fn() {
        // (closed: it sinks away as tall as it was; what it holds let go of meanwhile is no height to go to)
        guard @signals.untracked(live) && @signals.untracked(open) else { return }
        let at = layer.cause_at()
        guard seen_from(at, true) is Some((stood, v, left)) else { return }
        placed_plan.val = own_now()
        step_placed.val = false
        placed.set(Some((stood, at, left, v)))
        reach.set(dmax(reach.untracked(), sheet_under + stood))
      }
      // (what it holds made first, what it reads then waited for before it rises: OpenGate; one in another's place,
      // seen there from the first, waits for nothing)
      let gate = OpenGate::new()
      layer.reacts(fn() { layer.leaving() }, fn(going) {
        if going {
          gate.stop()
          dim.go_ms(layer, 0.0, @motion.sheet_scrim_ms, ease=Out)
          // (closed on its way from as tall as it stood: it sinks away from where it is seen then, as fast as it went)
          let carried_off = carried()
          let inset = if had_ime.val { @signals.untracked(fn() { layer.keyboard_inset() }) } else { 0.0 }
          let off = (carried_off.0 - inset, carried_off.1)
          below.go(sheet_box, layer, 1.0, reach.untracked(), speed?=let_go_speed.val, off~)
          let_go_speed.val = None
        } else {
          let rise = fn() {
            // (how tall it rises, for a sheet under it to step back out of its way: covered_by's there)
            rises(own_now())
            dim.go_ms(layer, 1.0, @motion.sheet_scrim_ms, ease=Out)
            below.go(sheet_box, layer, 0.0, reach.untracked(), late=false)
          }
          if in_place is Some(_) {
            rise()
          } else {
            gate.go(layer, rise)
          }
        }
      })
      // (a sheet over it: it steps back, as far up as that one's height makes it (push_of), its veil over it as far as
      // it has gone, on a Move as far as it goes; that one gone, back down from there, as the host's (present_sheet))
      let recede = @motion.NodeWay::new(0.0)
      let pushed = @signals.signal(0.0)
      layer.reacts(covered_by, fn(h) {
        match h {
          Some(h) => pushed.set(push_of(h))
          None => ()
        }
        let way = dmax(pushed.untracked(), 1.0)
        recede.go(layer, if h is Some(_) { 1.0 } else { 0.0 }, @motion.moved(points=way))
      })
      |> ignore
      // (its title and what it says as they are now, `live`'s where it says them, as the host's sheet heads a panel:
      // sheet_body's)
      let now_of = fn(x : PanelOf) {
        match x.live {
          Some(f) => f()
          None => (x.title, "", x.description)
        }
      }
      // (back: a page back where it is past its first; a step further in from another presenter's panel, back to that
      // one; else as it is cancelled)
      let go_back = fn() {
        if !page_back() {
          match step_back {
            Some(f) => f()
            None => cancel()
          }
        }
      }
      // (each page's slide: where it is off to the sheet's side, in the sheet's widths (0 in place, -1 off to its
      // start, 1 off to its end), from where, to where, from when, how long and initial velocity (sheet-widths/ms),
      // said as a page is put on or taken off)
      let ways : Map[Int, @signals.Signal[(Double, Double, Double, Double, Double)]] = Map([])
      let way_state_at = fn(w : (Double, Double, Double, Double, Double), t : Double) -> (Double, Double) {
        if w.3 <= 0.0 {
          (w.1, 0.0)
        } else if w.4 * (w.1 - w.0) < 0.0 {
          // (turned back mid-slide: slow at one rate first and return, as placed_path does, avoiding a sharp brake)
          let sw = dmax(@signals.untracked(fn() { layer.window().0 }), 1.0)
          let (px, pv) = @ui.come_way_by(w.0 * sw, w.4 * sw, w.1 * sw, w.1 * sw, t - w.2)
          (px / sw, pv / sw)
        } else {
          let (dx, dv) = @ui.move_path(w.0 - w.1, w.4, t - w.2, w.3)
          (w.1 + dx, dv)
        }
      }
      let way_at = fn(w : (Double, Double, Double, Double, Double), t : Double) {
        way_state_at(w, t).0
      }
      // (each page off to a side once its slide there is over: laid out nowhere then, drawn and read out not at all,
      // kept as it was left; told at that moment, and taken back at the cause of its way back)
      let aways : Map[Int, @signals.Signal[Bool]] = Map([])
      // (each page's node, and how tall a page a share of the window tall (`capped`) stood as it last stopped showing:
      // as tall as it slides off and waits, whatever the page that shows from then is)
      let page_views : Map[Int, @view.View] = Map([])
      let page_stood : Map[Int, @signals.Signal[Double?]] = Map([])
      let dues : Map[Int, () -> Unit] = Map([])
      let away_after = fn(n : Int, w : (Double, Double, Double, Double, Double)) {
        match dues.get(n) {
          Some(d) => d()
          None => ()
        }
        dues.remove(n)
        guard aways.get(n) is Some(a) else { return }
        a.set(false)
        if w.1 != 0.0 {
          dues[n] = layer.at_moment(w.2 + w.3, fn() { a.set(true) })
        }
      }
      let made_with : Ref[Bool] = Ref(true)
      let shown_was : Ref[Array[Int]] = Ref(@signals.untracked(fn() { pages().map(fn(pg) { pg.n }) }))
      layer.reacts(at_start=false, fn() { pages().map(fn(pg) { pg.n }) }, fn(ids) {
        let was = shown_was.val
        shown_was.val = ids
        guard ids.length() > 0 && was.length() > 0 && ids[ids.length() - 1] != was[was.length() - 1] else { return }
        let at = layer.cause_at()
        let dur = @ui.move_ms(layer.window().0)
        // (as tall as it stood as its page was put on or taken off (`stood`, said where that was done, before
        // anything of it is laid out anew): where the page that shows from now sets out from)
        let stood = stood()
        // (as tall as it was seen then, rising or not: its rise over, that way taking it up)
        if @signals.untracked(live) {
          settle(stood_own.val)
        }
        let stood_at_v = stood_v.val
        stood_v.val = 0.0
        // (the page that showed, as tall as it was placed till now: what a share of the window keeps as it slides off,
        // a finger's drag of the sheet's height in it)
        let showed = was[was.length() - 1]
        match (page_views.get(showed), page_stood.get(showed)) {
          (Some(pv), Some(h)) => {
            let ph = pv.placed_window_now().3
            if ph > 0.0 {
              h.set(Some(ph))
            }
          }
          _ => ()
        }
        reach.set(dmax(reach.untracked(), sheet_under + stood))
        sized.set(false)
        tall_held.set(None)
        let go = fn(n : Int, to : Double) {
          match ways.get(n) {
            Some(w) => {
              let (pos, vel) = way_state_at(w.untracked(), at)
              let v0 = dclamp(vel, -0.02, 0.02)
              let sw = dmax(layer.window().0, 1.0)
              let way_dur = if v0 * (to - pos) < 0.0 {
                @ui.come_way_ms(pos * sw, v0 * sw, to * sw)
              } else {
                dur
              }
              w.set((pos, to, at, way_dur, v0))
              away_after(n, w.untracked())
            }
            None => ()
          }
        }
        // (those no longer its pages off to its end, the one that shows in place, those before it off to its start; one
        // gone that did not show (more than one page taken off at once: panel_back's `to`) off there at once, never
        // across the sheet over what comes)
        for n in was {
          if !ids.contains(n) {
            if n == showed {
              go(n, 1.0)
            } else {
              match ways.get(n) {
                Some(w) => w.set((1.0, 1.0, at, 0.0, 0.0))
                None => ()
              }
            }
          }
        }
        for i, n in ids {
          go(n, if i + 1 == ids.length() { 0.0 } else { -1.0 })
        }
        // (as long as the slide at least, longer where it has further to go: no way of a height cut short; planned by
        // the page that shows from now laid out, back in place before its height is asked)
        placed_plan.val = own_now()
        step_placed.val = true
        placed.set(Some((stood, at, dur, stood_at_v)))
      })
      // (where it stands as what is drawn is drawn, as tall as it was laid out when last drawn, for what is lifted over
      // the scrim to keep clear of: tree_sheet_place, asked as the scrim is drawn, before the sheet; not where another
      // is in its place)
      let place = fn() -> (Double, Double)? {
        let (_, own, _) = drawn.val
        guard own > 0.0 && !vanished() else { return None }
        let t = layer.drawn_at()
        let off = match placed.untracked() {
          Some((stood, at, least, v)) => placed_path(own, stood, v, t - at, least).0
          None => 0.0
        }
        Some((layer.window().1 - own + below.shown(own, t) + off, own))
      }
      tree_sheet_place.val = Some(place)
      layer.owns(fn() {
        if tree_sheet_place.val is Some(f) && physical_equal(f, place) {
          tree_sheet_place.val = None
        }
      })
      |> ignore
      layer
      .over(Is(true))
      // (its ground its scrim: what is lifted over the scrim (a row held for its menu: lift_node) drawn over it, under
      // the sheet)
      .scrim_under()
      .margin(By(fn() { (0.0, 0.0, 0.0, -ime_under()) }))
      // (modal while open: closing, what is under it its own again as it begins to go)
      .modal(By(live))
      .hides(By(fn() { layer.leaving() }))
      .held_back_goes_on()
      .ground(By(fn() { @ui.alpha(sheet_scrim, if vanished() || !dims() { 0.0 } else { live_dim() }) }))
      // (a press on what is above it its own, nothing under it pressed: closing it as it goes down)
      .presses(Is(true))
      .on_drag(fn(d) {
        if d.kind == Down && @signals.untracked(live) {
          cancel()
        }
      })
      .on_key(fn(k) {
        if k.code == @ui.key_escape && @signals.untracked(live) {
          go_back()
          true
        } else {
          false
        }
      })
      .takes_back(fn() {
        if @signals.untracked(live) {
          go_back()
        }
      })
      |> ignore
      // (the room over it: what a press closes it on)
      layer.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
      gate.collect(fn() {
      layer.box(fn(sheet) {
        sheet_box.val = Some(sheet)
        // (how tall it stands, asked as it closes: where it was last placed)
        // (as tall as it is seen at that moment, on its way and rising, where it was drawn: its rise over from then)
        stands_by(fn() {
          match seen_from(layer.cause_at(), false) {
            Some((h, v, _)) => {
              stood_v.val = v
              stood_own.val = own_now()
              h
            }
            None => {
              stood_v.val = 0.0
              dmax(0.0, @signals.untracked(win_h) - sheet.placed_window_now().1)
            }
          }
        })
        sheet
        // (its foot past the window's by its corner, as the host's: its round corners only at its top; between the
        // system's bars down the window's sides, as what goes over the window keeps clear of them: View::clear)
        .margin(By(fn() {
          let (_, right, _, left) = layer.clear()
          (left, 0.0, right, -reach.get())
        }))
        .max_height(By(fn() {
          // (one that grows: up to the window's top as a finger draws it past its most, giving way; one as tall as what
          // it holds up to its share (`hugs`), no taller than that share)
          let pg = top()
          let under = reach.get()
          let wh = win_h()
          let most = wh * (if pg.x.grows { 1.0 } else { sheet_most }) + under
          Some(if capped_of(pg.x) && hugs_of(pg) { dmin(most, pg.x.tall * wh + under) } else { most })
        }))
        .height(By(fn() {
          let pg = top()
          let under = reach.get()
          match tall_held.get() {
            Some(h) => Some(h + under)
            None =>
              if sized.get() {
                Some(tall.shown(sheet) + under)
              } else if capped_of(pg.x) && !hugs_of(pg) {
                // (its share of the window, as the host's sheet is: present_sheet's)
                Some(pg.x.tall * win_h() + under)
              } else {
                None
              }
          }
        }))
        // (another in its place: none of it drawn from then, where it is, till its layer is let go; none of it drawn
        // either while it waits under the window for what it reads (OpenGate's holding): nothing of it till it rises)
        .alpha(By(fn() { if vanished() || gate.holding() { 0.0 } else { 1.0 } }))
        // (another in its place: laid out, drawn and read out nowhere from then, nothing of it found where that one is)
        .laid_nowhere(By(vanished))
        // (below its place by its own height as it comes and goes, over the time that height takes, as tall as it is
        // laid out in the frame drawing it; down where a finger has its top, or going back)
        // (what is leaving with it, its layer, kept till it has sunk away, however tall: as the host's is, gone once it
        // has sunk and its scrim faded)
        // (in another's place: as tall as that one stood at its cause's moment, taller or shorter than it is by how
        // far its foot is under or over its place, on a Move from there as long as that is far)
        // (a page put on or taken off: the same from as tall as it stood then, with the page's slide, as long)
        .moved_by(
          fn(w, h, t) {
            let own = h - reach.get()
            let off = match placed.get() {
              Some((stood, at, least, v)) => placed_path(own, stood, v, t - at, least).0
              None => 0.0
            }
            drawn.val = (w, own, own - off)
            (0.0, below.shown(own, t) + off)
          },
          fn(_, h) {
            let own = h - reach.get()
            match placed.get() {
              Some((stood, at, least, v)) => dmax(below.ends(h=own), at + placed_end(own, stood, v, least))
              None => below.ends(h=own)
            }
          },
          holds_leaving=true,
        )
        .offset(By(fn() {
          let raised = recede.shown(layer) * pushed.get()
          match held.get() {
            Some(y) => (0.0, y - raised)
            None => (0.0, back.shown(layer) - raised)
          }
        }))
        // (a press on it its own: not over it)
        |> ground_node
        |> ignore
        // (when its motions end, as presented_rest asks: its rise or sink as long as its own height makes it, from where
        // it stood in another's place (moved_by's own end, at the height it is laid out as of the logic's moment, not
        // as the frame last drawn had it: View::moved_end), its scrim, a height it goes to, its way back from under a
        // finger, what it holds making its way in or out: each said with its cause's moment and its length)
        presented_sheet_rest(layer, fn(laid) {
          let mut e = sheet.moved_end(laid~)
          // (its pages' slides)
          for _, way in ways {
            let v = way.untracked()
            e = dmax(e, v.2 + v.3)
          }
          for x in [dim, back, tall, recede] {
            e = dmax(e, x.end())
          }
          // (what it holds making its way in or out, growing or shrinking it: each way's end as it was said)
          dmax(e, sheet.comes_end(laid~))
        })
        // (its glass: as tall as the window twice over from its top, under the window's foot whatever it is laid out to
        // (the sheet comes to another height at the cause of a page put on or taken off, or of what an old body holds,
        // drawn from as tall as it stood, moved_by: what it draws only moves with it, never another height a frame
        // later); stepped back under a sheet over it, as tall as it is, its foot over that one's (another glass in its
        // place at that cause: it comes to no other height under it))
        let ground = fn(make : (@view.View) -> Unit) {
          sheet.pick(at_once=true, fn() { covered_by() is Some(_) }, fn(g, covered) {
            g.over(Is(true)).radius(Is(pane_corner)) |> ignore
            if !covered {
              g.height(By(fn() { Some(layer.window().1 * 2.0) })) |> ignore
            }
            make(g)
          })
        }
        ground(fn(g) {
          g
          .glass(By(fn() {
            if vanished() {
              return None
            }
            let t = theme()
            Some({ ..glass_sheet(), solid: over(over(t.p.bg, alpha(0x000000FFL, 0.28 * live_dim())), alpha(t.p.card, 0.8)) })
          }))
          .shadow(Is((sheet_raised.sigma, sheet_raised.dy, sheet_raised.color)))
          |> ignore
        })
        // its top (sheet_drag_h: the grabber and the head) drags it, a node of its own over its glass and under what it
        // holds (as the host's @kit.sheet's drag_area): what a finger put down there does, as the host's
        // (@kit.sheet's): one that grows taller or shorter, settling at the detent it is let go nearer, closing let go
        // under sheet_close_below of the window, a tap on its grabber to the other end; one that does not only down,
        // closing past sheet_drag_close. The rest of it is its ground alone (ground_node: a press on it
        // its own), so a finger put down on its words or its room is the column's that scrolls them as it moves (Tree's
        // claims): never the sheet's, which would hold it and scroll nothing
        let from_y = Ref(-1.0)
        let from_h = Ref(0.0)
        sheet.box(fn(top_drag) {
          top_drag
          .over(Is(true), edges=(Some(0.0), Some(0.0), Some(0.0), None))
          .height(Is(Some(sheet_drag_h)))
          .cursor(Is(Some(Arrow)))
          .as_ground()
          .on_drag(fn(d) {
            guard @signals.untracked(live) else { return }
            if d.kind == Down {
              // (its own height as it stood then, the sheet's (not its top's, the drag's): its foot's room past the window
              // taken off)
              from_y.val = d.wy
              from_h.val = dmax(0.0, sheet.placed_window_now().3 - reach.untracked())
            }
            guard from_y.val >= 0.0 else { return }
            let dy = d.wy - from_y.val
            let total = @signals.untracked(win_h)
            // (let go: on from the speed it went at under the finger, whatever it goes to then, as the host's sheet hands
            // the finger's to its spring; points a millisecond down)
            let finger = if d.kind == Up { d.vy() } else { 0.0 }
            if @signals.untracked(fn() { top().x.grows }) {
              let top = total * sheet_most
              let to = dmax(from_h.val - dy, sheet_least_h)
              let now = sheet_stretched(to, top, total - top)
              // (as fast as the finger where it follows it; drawn past its top, as much slower as it gives way; held at its
              // least, still)
              let speed = if from_h.val - dy < sheet_least_h {
                0.0
              } else {
                finger * sheet_stretched_slope(to, top, total - top)
              }
              match d.kind {
                Down => ()
                Moved => tall_held.set(Some(now))
                Up | Off => {
                  let cur_dim = @signals.untracked(fn() {
                    let lo = sheet_grows_to[0] * win_h()
                    let f = if lo > 0.0 { dclamp(now / lo, 0.0, 1.0) } else { 1.0 }
                    dim.value_at(layer.cause_at()) * f
                  })
                  tall_held.set(None)
                  let at = if d.kind == Up && dy.abs() < @ui.touch_slop() { from_h.val } else { now }
                  tall.put(at)
                  sized.set(true)
                  if d.kind == Up && dy.abs() < @ui.touch_slop() {
                    // (a tap on its grabber, its top 30: to the other end)
                    if d.oy < sheet_grab_tap {
                      let (lo, hi) = (sheet_grows_to[0], sheet_grows_to[1])
                      tall.go(sheet, if at > (lo + hi) / 2.0 * total { lo * total } else { hi * total }, @motion.moved())
                    }
                  } else if @motion.sheet_goes_to(sheet_grows_to, at, speed, total, sheet_close_below) is None {
                    // (hand the live scrim alpha to `dim` before leaving fades it to 0, avoiding a jump back to 1)
                    dim.put(cur_dim)
                    // (sinking away from where it is, as fast as it was going down)
                    let_go_speed.val = Some(dmax(0.0, speed))
                    cancel()
                  } else {
                    let f = @motion.sheet_goes_to(sheet_grows_to, at, speed, total, sheet_close_below).unwrap_or(sheet_grows_to[0])
                    // (its height, up: its speed the other way, a second's)
                    tall.go(sheet, f * total, @motion.moved(), velocity=-speed * 1000.0)
                  }
                }
              }
            } else {
              let down = dmax(0.0, dy)
              // (as fast as the finger, down; held at its place, still)
              let speed = if dy > 0.0 { finger } else { 0.0 }
              match d.kind {
                Down => held.set(Some(0.0))
                Moved => held.set(Some(down))
                Up | Off => {
                  let cur_dim = @signals.untracked(fn() {
                    let own = dmax(drawn.val.1, sheet_drag_close)
                    dim.value_at(layer.cause_at()) * dclamp(1.0 - down / own, 0.0, 1.0)
                  })
                  held.set(None)
                  back.put(down)
                  if d.kind == Up && @motion.sheet_drag_closes(down, speed, sheet_drag_close) {
                    // (hand the live scrim alpha to `dim` before leaving fades it to 0, avoiding a jump back to 1)
                    dim.put(cur_dim)
                    // (closed from where it is: it sinks away from there, as fast as it was going down)
                    let_go_speed.val = Some(dmax(0.0, speed))
                    cancel()
                  } else {
                    // (back from its speed, a second's)
                    back.go(layer, 0.0, @motion.moved(), velocity=speed * 1000.0)
                  }
                }
              }
            }
            if d.kind == Up || d.kind == Off {
              from_y.val = -1.0
            }
          })
          |> ignore
        })
        |> ignore
        // (what it holds cut to its glass's corners, its foot past the window's by as far as the sheet's is: what lies in
        // it round as they are, as the host's sheet cuts what it holds)
        sheet.box(fn(cut) {
          cut
          .grow(Is(1.0))
          .shrink(Is(1.0))
          .min_height(Is(Some(0.0)))
          .padding(By(fn() { (0.0, 0.0, 0.0, reach.get()) }))
          .radius(Is(pane_corner))
          .clips(Is(true))
          |> ignore
          // (what it holds, as tall as the sheet less its foot's room past the window: what is read out as the sheet, a
          // dialog by its title, where it is seen)
          cut.box(fn(col) {
            col
            .grow(Is(1.0))
            .shrink(Is(1.0))
            .min_height(Is(Some(0.0)))
            .says(By(fn() { Some(@view.said(Dialog, label=now_of(top().x).0)) }))
            |> ignore
            // (the grabber: 38 × 5 in the line's colour, 12 over it and 8 under)
            col.box(fn(g) {
              style_node(g, fn() { sheet_grab_outer })
              g.box(fn(i) {
                style_node(i, fn() { sheet_grab_inner })
                i.box(fn(b) { style_node(b, fn() { sheet_grabber.then(@ui.style(bg=Data(theme().p.line))) }) }) |> ignore
              })
              |> ignore
            })
            |> ignore
            // (its pages: the one that shows in the sheet's column, as tall as it makes the sheet; the rest over it, off to
            // its sides (cut off by the sheet), kept as they were left)
            col.box(fn(stack) {
              stack
              // (what slides off to its sides cut off by it, a share of the window tall; as tall as what it holds, a
              // page taller than the one that shows, sliding off as that one comes, cut off by the sheet alone, whole
              // down to its foot)
              .clips(By(fn() { capped_of(top().x) }))
              .grow(By(fn() { if capped_of(top().x) { 1.0 } else { 0.0 } }))
              .shrink(Is(1.0))
              .min_height(Is(Some(0.0)))
              |> ignore
              stack.each(
                // (one taken off kept till it has slid away: its own move's end, View::moved_by's `holds_leaving`)
                leave=1.0,
                fn() { pages().map(fn(pg) { SheetItem::{ pg: pg } }) },
                fn(it) { it.pg.n },
                fn(page, item) {
                  // (its own page, given it by the list as it is made: no walk of the pages for it)
                  let pg = item.untracked().pg
                  let k = pg.n
                  let (x, close, from) = (pg.x, pg.close, pg.from)
                  let pressed = from != Unanchored
                  let footed = x.nodes.foot is Some(_)
                  let now = fn() { now_of(x) }
                  let capped = capped_of(x)
                  let shows = fn() { top().n == k }
                // (what it holds come to another height for a cause of its own, where it shows: the sheet from as tall
                // as it is seen)
                let page_reshaped = fn() {
                  if @signals.untracked(shows) {
                    reshaped()
                  }
                }
                  // (made with the sheet: the one that shows in place, those before it off to its start; put on since: in
                  // from the sheet's end, from its cause's moment)
                  let slide = (layer.cause_at(), @ui.move_ms(layer.window().0))
                  let way = @signals.signal(
                    if made_with.val {
                      // (the one that shows: the last of them)
                      let all = @signals.untracked(pages)
                      if all.length() == 0 || all[all.length() - 1].n == k {
                        (0.0, 0.0, 0.0, 0.0, 0.0)
                      } else {
                        (-1.0, -1.0, 0.0, 0.0, 0.0)
                      }
                    } else {
                      (1.0, 0.0, slide.0, slide.1, 0.0)
                    },
                    same=fn(a, b) { a == b },
                  )
                  ways[k] = way
                  aways[k] = @signals.signal(way.untracked().1 != 0.0)
                  let stood_h : @signals.Signal[Double?] = @signals.signal(None)
                  page_views[k] = page
                  page_stood[k] = stood_h
                  page.owns(fn() {
                    ways.remove(k)
                    aways.remove(k)
                    page_views.remove(k)
                    page_stood.remove(k)
                    match dues.get(k) {
                      Some(d) => d()
                      None => ()
                    }
                    dues.remove(k)
                  })
                  |> ignore
                  let away = aways[k]
                  // (one that does not show, sliding off as another comes in its place or waiting under it, laid out
                  // from the sheet's top: not made as tall as the page that shows, its foot jumping to where that
                  // one's is. One as tall as what it holds (not a share of the window: `capped`) measured as tall as it
                  // is, its foot where it stood under what it holds; one a share of the window tall as tall as it stood
                  // as it last showed (`stood_h`), or its share where it has not shown)
                  let own_height = !capped
                  page
                  .over(By(fn() { !shows() }), from_top=true)
                  .height(By(fn() {
                    if capped && !shows() {
                      match stood_h.get() {
                        Some(h) => Some(h)
                        None =>
                          if !hugs_of(pg) {
                            Some(dmax(0.0, x.tall * win_h() - sheet_grab_h - @ui.system_bars().bottom))
                          } else {
                            None
                          }
                      }
                    } else {
                      None
                    }
                  }))
                  // (laid out over it, as tall as the sheet would let it be where it showed: what scrolls in it the room
                  // it had, not as tall as all it holds)
                  .max_height(By(fn() {
                    if !shows() {
                      let wh = win_h()
                      let most = wh * (if x.grows { 1.0 } else { sheet_most })
                      let lim = if capped && hugs_of(pg) { dmin(most, x.tall * wh) } else { most }
                      Some(dmax(0.0, lim - sheet_grab_h - (if capped { @ui.system_bars().bottom } else { 0.0 })))
                    } else {
                      None
                    }
                  }))
                  .laid_nowhere(By(fn() { away.get() }))
              // (none of it seen)
              .alpha(By(fn() { if away.get() { 0.0 } else { 1.0 } }))
                  .grow(Is(if capped { 1.0 } else { 0.0 }))
                  .shrink(Is(1.0))
                  .min_height(Is(Some(0.0)))
                  // (one that does not show takes nothing and is not read out)
                  .presses(By(shows))
                  .hides(By(fn() { !shows() }))
                  .moved_by(
                    fn(w, _, t) { (way_at(way.get(), t) * w, 0.0) },
                    fn(_, _) {
                      let w = way.get()
                      w.2 + w.3
                    },
                    holds_leaving=true,
                  )
                  |> ignore
                  // (its title, none where what it holds heads itself (`heads_itself`): its own title's row there; one as
                  // it is now (`live`), there while it has one)
                  // (its title's words, and its step's count beside them where it says one (step_head's: 1 / 4))
                  let title_words = fn(at : @view.View) {
                    at.box(fn(l) {
                      style_node(l, fn() { dialog_title_line })
                      l.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                      // (a part of it in the accent where it is marked so: title_accent.mbt, a menu's title)
                      if title_marked(@signals.untracked(fn() { now().0 })) {
                        l.box(fn(w) {
                          w
                          .words_runs(By(fn() { title_runs(now().0, theme().p.accent_text) }))
                          .words_look(By(fn() { @ui.style_words(sheet_title_words) }))
                          .ink(By(fn() { @ui.style_ink(sheet_title_words) }))
                          .shrink(Is(1.0))
                          .min_width(Is(Some(0.0)))
                          |> ignore
                        })
                        |> ignore
                      } else {
                        words_node(l, fn() { now().0 }, fn() { sheet_title_words }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                      }
                      l.show(fn() { now().1 != "" }, fn(n) { words_node(n, fn() { now().1 }, fn() { dialog_step }) |> ignore })
                    })
                    |> ignore
                  }
                  let title_row = fn(r : @view.View) {
                    style_node(r, fn() { sheet_title_row })
                    // (its words on as many lines as they take, in the room the row leaves them, as the host's title)
                    r.box(fn(at) {
                      style_node(at, fn() { sheet_title_room }, in_row=true)
                      at.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                      title_words(at)
                    })
                    |> ignore
                  }
                  // (a step further in: its back key before its title, as a step's head has it (step_head), the row no
                  // taller for it)
                  let step_row = fn(r : @view.View) {
                    style_node(r, fn() { sheet_title_row.then(step_head_gap) })
                    r.box(fn(key) {
                      style_node(key, fn() {
                        in_line(step_back_side - @ui.tree_theme().text_size(Title).1).then(@ui.style(ml=room(-step_back_in)))
                      })
                      icon_button_node(key, "chevron-left", fn() { t("common.back") }, go_back, size=step_back_side) |> ignore
                    })
                    |> ignore
                    // (its words on as many lines as they take, in the room the row leaves them, as the host's title)
                    r.box(fn(at) {
                      style_node(at, fn() { sheet_title_room }, in_row=true)
                      at.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                      title_words(at)
                    })
                    |> ignore
                  }
                  // (what heads itself where it says so on a sheet too)
                  let heads = x.heads_itself && x.nodes.sheet_heads
                  if (k != 0 || step_back is Some(_)) && !heads {
                    page.box(step_row) |> ignore
                  } else if heads {
                    ()
                  } else if x.live is Some(_) {
                    page.show(fn() { now().0 != "" }, title_row)
                  } else if x.title != "" {
                    page.box(title_row) |> ignore
                  }
                  // (what it says, under its title, as it is now)
                  let said = fn(s : @view.View) {
                    s.show(fn() { now().2 != "" }, fn(w) {
                      style_node(w, fn() { sheet_lead_at })
                      words_node(w, fn() { now().2 }, fn() { sheet_lead }) |> ignore
                    })
                  }
                  // what it holds, scrolling where the sheet is short of room for it; a share of the window tall, filling
                  // the room it leaves, laid out in it (sheet_capped_room: its words as far in as a sheet's, sheet_step's)
                  if capped {
                    body_box(page, true, false, shows, fn(b) {
                      b.grow(Is(1.0)).shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
                      said(b)
                      b.box(fn(col) {
                        style_node(col, fn() { sheet_capped_room })
                        col.min_height(Is(Some(0.0))) |> ignore
                        // (laid out as the host's sheet lays out a capped panel's body: narrow, its words a sheet's own in,
                        // sheet_step's; sheet_capped_room: none in from its sides)
                        panel_in_lend(col, Narrow, sheet_panel_sides, sides=0.0)
                        col.lends(sheet_win_lent, body_win_h) |> ignore
                        // (what it holds come to another height for a cause of its own: the sheet from as tall as it is
                        // seen, where it shows, panel_reshaped_node)
                        col.lends(panel_reshape_lent, page_reshaped) |> ignore
                        (x.nodes.body)(col, close)
                      })
                      |> ignore
                    })
                  } else {
                    body_box(page, false, true, shows, fn(b) {
                      let scroll = @view.Scroll::new()
                      b.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
                      b.scrolls(scroll, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(s) {
                        said(s)
                        // (in from its sides as the host's sheet has a panel's: a form a share of the window tall laying
                        // out its own sides, its words as far in as a sheet's, whatever opened it (full_width), and so
                        // one said flush (PanelNodes' `flush`: a menu's, a pick's, a confirm's, a
                        // question's), the room under it as the rest's; opened by a press as far in as a pick's rows,
                        // else as its words)
                        let flush = x.nodes.flush
                        let own_sides = x.tall > 0.0 || flush
                        let room = if x.tall > 0.0 || (flush && footed) {
                          full_width
                        } else if flush {
                          if pressed { sheet_flush_held } else { sheet_flush_panel }
                        } else if pressed {
                          if footed { sheet_held_sides } else { sheet_held }
                        } else {
                          sheet_panel
                        }
                        s.box(fn(col) {
                          style_node(col, fn() { room })
                          // (holding nothing laid out, none of its room: its title and what it says straight over its
                          // foot, as the old sheet's body's box gone_empty)
                          col.gone_empty(Is(true)) |> ignore
                          // (laid out as the host's sheet lays out a panel's body, sheet_step's: narrow; its words what a
                          // sheet's rows leave of its words' in one a press opened, its rows out to its words' in one opened
                          // by nothing)
                          if own_sides {
                            panel_in_lend(col, Narrow, sheet_panel_sides, sides=0.0)
                          } else {
                            panel_in_lend(
                              col,
                              Narrow,
                              if pressed { sheet_panel_sides - sheet_row_sides } else { 0.0 },
                              // (sheet_held's, sheet_panel's px)
                              sides=if pressed { sheet_row_sides } else { sheet_panel_sides },
                              rows_out=dmax(0.0, (if pressed { sheet_row_sides } else { sheet_panel_sides }) - panel_card_in),
                            )
                          }
                          col.lends(sheet_win_lent, body_win_h) |> ignore
                          // (what it holds come to another height for a cause of its own: panel_reshaped_node)
                          col.lends(panel_reshape_lent, page_reshaped) |> ignore
                          (x.nodes.body)(col, close)
                        })
                        |> ignore
                      })
                      .clips(By(fn() { scroll.goes() }))
                      .bounds_input(By(fn() { scroll.goes() }))
                      |> ignore
                    })
                  }
                  match x.nodes.foot {
                    Some(f) => {
                      if x.ruled {
                        page.box(fn(r) {
                          style_node(r, fn() { sheet_foot_rule })
                          foot_stays(r, shows, own_height)
                        })
                        |> ignore
                      }
                      page.box(fn(row) {
                        style_node(row, fn() { if x.ruled { sheet_ruled_foot_at } else { sheet_foot_at } })
                        foot_stays(row, shows, own_height)
                        // (its buttons across it, each its share, in a thumb's reach: the host's sheet's foot_fills; where they have not the
                        // room each as wide as its words, a line each, as the old foot's flow and line_gap: ask_foot_lines)
                        row.lends(foot_fills_lent, true).wraps(Is(Some(ask_foot_lines()))).wraps_at_least(Is(true)) |> ignore
                        f(row, close)
                      })
                      |> ignore
                    }
                    None => ()
                  }
                },
              )
              made_with.val = false
            })
            |> ignore
            // (under it, the navigation bar's room: sheet_foot)
            col.box(fn(nav) { nav.height(By(fn() { Some(@ui.system_bars().bottom) })) |> ignore }) |> ignore
          })
          |> ignore
        })
        |> ignore
        // (stepped back under a sheet over it: dimmed all over as far as it has gone, the host's sheet_veil_at)
        sheet.box(fn(v) {
          v
          .over(Is(true))
          .radius(Is(pane_corner))
          // (none of it drawn while it dims nothing)
          .alpha(By(fn() { if recede.shown(layer) > 0.0 { 1.0 } else { 0.0 } }))
          .ground(By(fn() { @ui.alpha(sheet_scrim, recede.shown(layer)) }))
          |> ignore
        })
        |> ignore
        |> ignore
      })
      |> ignore
      })
      gate.seal(layer)
      // (the keys on the field it opens to be typed in, where it says one, given back as it goes; else, a search at
      // hand or none, the focus left where it is: Enter its foot's action)
      match field.val {
        Some(f) if f.keyed(true) => layer.focus_opens(f.field) |> ignore
        _ => layer.focus_returns() |> ignore
      }
    },
    // (its scrim's fade; and its sinking away, which holds it: View::moved_by)
    leave=@motion.sheet_scrim_ms,
  )
}

///|
/// How short a sheet that grows is dragged at most (@kit.sheet's).
let sheet_least_h : Double = 120.0

///|
/// Under what share of the window a sheet that grows closes as it is let go (@kit.sheet's `close_below`).
let sheet_close_below : Double = 0.3

///|
/// How far down its top a press is on its grabber (@kit.sheet's: its top 30).
let sheet_grab_tap : Double = 30.0

///|
/// How tall a sheet is drawn `h` high under a finger, its top `top` and `room` above that (@kit.sheet's stretched): as
/// high as the finger has it up to its top, past it giving way more the further it is drawn, never past the room there
/// is.
fn sheet_stretched(h : Double, top : Double, room : Double) -> Double {
  if h <= top || room <= 0.0 {
    return dmin(h, top)
  }
  let x = h - top
  top + (1.0 - 1.0 / (x * sheet_give / room + 1.0)) * room
}

///|
/// How fast a sheet drawn `h` high under a finger (sheet_stretched's) goes for each point the finger goes: as fast up to
/// its top, slower past it the further it is drawn.
fn sheet_stretched_slope(h : Double, top : Double, room : Double) -> Double {
  if h <= top || room <= 0.0 {
    return if h <= top { 1.0 } else { 0.0 }
  }
  let k = (h - top) * sheet_give / room + 1.0
  sheet_give / (k * k)
}

///|
/// How much a sheet drawn past its top gives way (@kit.sheet's: UIScrollView's rubber band's constant).
let sheet_give : Double = 0.55

///|
/// How high a sheet's top stands over its place's foot as it rises and sinks (`u`: as tall as it is, risen; none,
/// sunk): each way said once, at its cause's moment, from where its top stood then and as fast as it went (what it
/// holds growing or shrinking then, a hand's speed as it let it go), its turn and length by how tall it was then
/// (come_way_by's plan); only its end follows how tall it comes to, rising (to as tall as it is laid out), none
/// sinking (to the window's foot, however tall it is). So a sheet closed while what it holds grows or shrinks sinks on
/// from as fast as its top went, slowing first where that was up (the coordinator of the migration, 2026-11-11: as one
/// node turned back does, PR 2's whole). Where it is drawn is worked out as it is, by how tall it is laid out then
/// (View::moved_by): `h - u` below its place.
priv struct SheetRise {
  /// where it stood before its first way: risen (in another's place) or below
  mut risen : Bool
  /// its way: the cause's moment, whether up, where its top stood and how fast it went (points a ms, up), and how tall
  /// it was then
  mut way : SheetWay?
  /// told as a way is said
  said : @signals.Signal[Int]
}

///|
priv struct SheetWay {
  at : Double
  up : Bool
  u0 : Double
  v0 : Double
  plan : Double
  /// what its way keeps of its turn, worked out once (come_way_by's)
  kept : @ui.ComeKept
}

///|
fn SheetRise::new() -> SheetRise {
  { risen: false, way: None, said: @signals.signal(0) }
}

///|
/// Where its top stands at moment `t` over its place's foot, `h` tall then, and how fast it goes (points a ms, up), as
/// long as `h` goes `hv` a ms.
fn SheetRise::top_at(self : SheetRise, h : Double, hv : Double, t : Double) -> (Double, Double) {
  match self.way {
    None => if self.risen { (h, hv) } else { (0.0, 0.0) }
    Some(w) => {
      let goal = if w.up { h } else { 0.0 }
      let plan = if w.plan.is_nan() { h } else { w.plan }
      let (u, uv) = @ui.come_way_by(w.u0, w.v0, goal, if w.up { plan } else { 0.0 }, t - w.at, kept=w.kept)
      // (rising: its end as tall as it comes to, as much of how fast that goes as its way has got there)
      if w.up && hv != 0.0 {
        let (u1, _) = @ui.come_way_by(w.u0, w.v0, goal + 1.0, plan, t - w.at, kept=w.kept)
        (u, uv + (u1 - u) * hv)
      } else {
        (u, uv)
      }
    }
  }
}

///|
/// Off to `to` (1: below, 0: risen) at `n`'s cause's moment, from where its top stands then and as fast as it goes,
/// `sheet` its box (how tall it is then and how fast that goes: View::grows_now, once it is laid out); `speed`: as fast
/// as that down instead (points a millisecond: what a finger let it go at); `off`: its top that much lower then, going that
/// much slower up (points, points a ms: how far a way from as tall as it stood had it drawn off its place, carried on).
fn SheetRise::go(
  self : SheetRise,
  sheet : Ref[@view.View?],
  n : @view.View,
  to : Double,
  under : Double,
  speed? : Double,
  off? : (Double, Double) = (0.0, 0.0),
  late? : Bool = false,
) -> Unit {
  let up = to <= 0.0
  match self.way {
    Some(w) if w.up == up => return
    None if self.risen == up => return
    _ => ()
  }
  let at = n.cause_at()
  let said = fn(h : Double, hv : Double) {
    let (u, uv) = self.top_at(h, hv, at)
    let v0 = match speed {
      Some(s) => -s
      None => uv - off.1
    }
    // (`late`: what it holds laid out only once it is drawn (an old body), so not as tall as it comes to yet: rising
    // from rest at its foot, as long as how tall it is as each frame lays it out, as before; NaN)
    let plan = if late && up && u - off.0 == 0.0 && v0 == 0.0 { @double.not_a_number } else { h }
    self.way = Some({ at, up, u0: u - off.0, v0, plan, kept: @ui.come_kept() })
    self.said.set(self.said.untracked() + 1)
  }
  match sheet.val {
    Some(b) if b.alive() => {
      let (h, hv) = b.grows_now()
      said(dmax(h - under, 0.0), hv)
    }
    // (as it is first made: once it is laid out, at that moment)
    _ =>
      @signals.after_flush(fn() {
        match sheet.val {
          Some(b) if b.alive() => {
            let (h, hv) = b.grows_now()
            said(dmax(h - under, 0.0), hv)
          }
          _ => said(0.0, 0.0)
        }
      })
  }
}

///|
/// How far below its place it is drawn at moment `t`, `h` points tall: in points (what is said of it followed).
fn SheetRise::shown(self : SheetRise, h : Double, t : Double) -> Double {
  self.said.get() |> ignore
  let d = dmax(h, 0.0)
  match self.way {
    // (risen or below, no way said: there, as tall as it is)
    None => if self.risen { 0.0 } else { d }
    // (from rest at its place's foot or risen, as tall as it is now as it was then: the same way worked out as it was
    // before its top's was (in its heights), only so that each frame of a sheet whose content stands still is what it
    // was to the bit; the same curve as its top's (sheet_sink_wbtest holds them within 1e-9 of each other, on into a
    // frame laid out another height), to go once nothing compares frames with those of before)
    Some(w) if w.v0 == 0.0 && (d == w.plan || w.plan.is_nan()) && d > 0.0 && (if w.up { w.u0 == 0.0 } else { w.u0 == w.plan }) =>
      sheet_below_as_before(w.up, d, t - w.at)
    Some(_) => d - self.top_at(d, 0.0, t).0
  }
}

///|
/// How far below its place a sheet `d` tall is `t` ms into its way up (`up`) or down from rest, worked out as it was in
/// its own heights (SheetRise::shown's, for its frames to the bit).
fn sheet_below_as_before(up : Bool, d : Double, t : Double) -> Double {
  let x0 = if up { 1.0 } else { 0.0 }
  let to = 1.0 - x0
  let (dx, _) = @ui.move_path((x0 - to) * d, 0.0, t, @ui.move_ms((x0 - to).abs() * d))
  (to + dx / d) * d
}

///|
/// When its last way is over (what is said of it followed; no way said: -1), however tall it comes to: View::moved_by's.
fn SheetRise::ends(self : SheetRise, h? : Double = 0.0) -> Double {
  self.said.get() |> ignore
  match self.way {
    None => -1.0
    Some(w) => {
      // (one as long as how tall it is: `h` tall)
      let plan = if w.plan.is_nan() { dmax(h, 0.0) } else { w.plan }
      w.at + @ui.come_way_ms(w.u0, w.v0, if w.up { plan } else { 0.0 }, kept=w.kept)
    }
  }
}

///|
/// A sheet's page as its list of pages (sheet_node's View::each) has it. A page is made with what it is given as it is
/// made and keeps it (its number is its key), so it is told as the same item by its number alone: a panel and what it
/// holds are no values to compare.
priv struct SheetItem {
  pg : SheetPage
}

///|
impl Eq for SheetItem with equal(a, b) {
  a.pg.n == b.pg.n
}
