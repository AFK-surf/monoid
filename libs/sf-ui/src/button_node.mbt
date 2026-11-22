// The library's button (button's) as a node of the window's tree, made once: its ground the tone's, a step towards the
// page or the hover's where the hand is on it (dur_ms, eased out, from the moment that changed); faded while it cannot
// be pressed; at work, a spinner's room opening before its words (a Move as far as that room) and the spinner turning
// in it, coming in as it opens; its words changed, its ground and its words going together to where they are laid out
// (moves_for: the same cause, one length). All of that is its look, over mbui's headless button (@headless.button),
// whose it is that it is read out a button, pressed where it is laid out and by the keyboard, and when it is neither.

///|
/// The button in `parent`: `label` its words, `tone` its look, `busy` while what it does is under way (not pressed
/// again, a spinner before its words), `disabled` while it cannot be pressed (faded), `across` as wide as what holds it
/// gives (its words in its middle); `press` done as it is pressed. `done`: what it did is done (发布 → 发布中 → 已发布):
/// a tick drawn by its stroke where the spinner turned, while it says so. With an `icon`, at work and done in the icon's
/// own place, its words not moved (the icon giving way to the spinner, the spinner to the tick); without, in a room
/// opened before its words as at work, kept open from at work to done, closed once neither. Pressed, its ground a step
/// deeper than under the hand and the whole of it sunk a little, springing back as it is let go (@motion.press_feel):
/// at rest and under the hand alone drawn exactly as it was. In a panel coming in its surface first, all of it
/// (its ground, its icon, its spinner, its words) with the rest of what the panel holds: the panel's content's. Its
/// words changing go to their place for that cause. `card_words`: in a card's foot corner, its words where the card's
/// begin (card_foot_words's: its padding as far in as that corner leaves them; one with an icon keeps its ends).
/// `default_on`: while it is its layer's default, pressed by Enter that nothing with the focus takes (a dialog's primary
/// button; never one that cannot be undone: @view.View::default_press).
/// `on_night`: on a stage, on the night whatever the theme (the old button's `on_night`: the primary the white, its words
/// the night; the others the white at 12%). Pressed while `disabled` and not `busy`, shaken across where it is drawn
/// (refused_shake), its press not run.
/// The node.
#callsite(autofill(loc))
pub fn button_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  tone? : Tone = Plain,
  busy? : () -> Bool = fn() { false },
  disabled? : () -> Bool = fn() { false },
  across? : Bool = false,
  icon? : String = "",
  card_words? : Bool = false,
  default_on? : () -> Bool,
  on_night? : Bool = false,
  done? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  button_by(loc~, parent, label, fn(_) { press() }, tone, busy, disabled, across, icon, card_words, default_on~, on_night~, done~)
}

///|
/// button_node's button that opens what goes beside it (a menu under it): `open` given the button itself as it is
/// pressed, where it is placed then.
#callsite(autofill(loc))
pub fn button_opens_node(
  parent : @view.View,
  label : () -> String,
  open : (@view.View) -> Unit,
  tone? : Tone = Plain,
  icon? : String = "",
  loc~ : SourceLoc,
) -> @view.View {
  button_by(loc~, parent, label, open, tone, fn() { false }, fn() { false }, false, icon, false, default_on=None)
}

///|
/// button_node's button, `press` given the button itself as it is pressed.
#callsite(autofill(loc))
fn button_by(
  parent : @view.View,
  label : () -> String,
  press : (@view.View) -> Unit,
  tone : Tone,
  busy : () -> Bool,
  disabled : () -> Bool,
  across : Bool,
  icon : String,
  card_words : Bool,
  default_on~ : (() -> Bool)?,
  on_night? : Bool = false,
  done? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let live = fn() { !disabled() && !busy() }
  let solid = tone == Primary || tone == DangerSolid
  // (a primary button its layer's default where none is said: Enter in a dialog, a sheet or a panel (a modal layer's
  // alone, @view.Tree::default_of) that nothing with the focus takes presses it,
  // as a dialog's default button is (the owner, 2026-11-16: 照苹果的来); a red one never, so that Enter does not do
  // what cannot be undone; a panel with two primaries has none, @view.Tree::default_of)
  let default_on = match default_on {
    Some(f) => Some(f)
    None => if tone == Primary { Some(fn() { true }) } else { None }
  }
  let height = button_height()
  // (what it is to the hand, the keyboard and a screen reader is mbui's headless button's: read out a button called by
  // its label, pressed and focused only while not disabled, Enter and Space pressing it. At work is disabled to all of
  // those, and told apart by the eye alone: said to the component as disabled, its spinner this look's. Here, its look)
  // (its press's feel, told how big it is as the press goes down by the gesture: nothing read of its layout; a hold
  // of its own none, a press held however long still its press)
  let feel_of : Ref[@motion.PressFeel?] = Ref(None)
  let hold = @headless.Hold::new(@ui.touch_slop(), @ui.long_press_ms, fn() { false }, down=fn(d) {
    if feel_of.val is Some(f) {
      f.down(d)
    }
  })
  @headless.button(made_for=loc, parent, label, press, disabled=fn() { !live() }, default_on?, hold~, fn(v, b) {
    v.focus_ring_theme() |> ignore
    // (the hand on it (the keyboard's focus shown on it, a pointer over it: which of the button's states light it is
    // this look's): how far its ground has gone towards its lit one; at work, how far its spinner is in and how far its
    // room is open; done, how far its tick is drawn; how faded it is)
    // (pressed, it is lit as under the hand (its ground eased there as ever), and sunk a little, springing back as it is
    // let go (@motion.press_feel); pressed where it was lit already (a mouse's click under the pointer, the keys'
    // focus on it), a step deeper too, where the hand's step alone had nothing left to show)
    let lit = fn() {
      (busy() && (tone == Ghost || tone == GhostDanger)) || (live() && (b.focus_shown() || b.hovered() || b.pressed()))
    }
    let feel = @motion.press_feel(v, live~, hovers=false)
    feel_of.val = Some(feel)
    let pressed = fn() { dmin(1.0, dmax(0.0, feel.pressed_on(v))) }
    let hand = @motion.NodeWay::new(if @signals.untracked(lit) { 1.0 } else { 0.0 })
    let deeper = lit_before_press(v, b, hand)
    let turning = @motion.NodeWay::new(if @signals.untracked(busy) { 1.0 } else { 0.0 })
    let marked = fn() { busy() || done() }
    let open = @motion.NodeWay::new(if @signals.untracked(marked) { 1.0 } else { 0.0 })
    // (its tick drawn by its stroke as it comes to be done; whole at once where it is done as it is made)
    let tick = @motion.NodeWay::new(if @signals.untracked(done) { 1.0 } else { 0.0 })
    let seen = @motion.NodeWay::new(if @signals.untracked(disabled) { 0.45 } else { 1.0 })
    v.reacts(lit, fn(on) { hand.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms) })
    v.reacts(busy, fn(on) { turning.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms) })
    v.reacts(marked, fn(on) { if icon == "" { open.go(v, if on { 1.0 } else { 0.0 }, button_reshape) } else { open.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms) } })
    v.reacts(done, fn(on) { if on { tick.go_from(v, 0.0, 1.0, button_tick_in) } else { tick.go_ms(v, 0.0, dur_ms) } })
    v.reacts(disabled, fn(off) { seen.go_ms(v, if off { 0.45 } else { 1.0 }, dur_ms) })
    // (pressed while it cannot be (not at work: a press then is on its way already), shaken where it is drawn: told
    // from a press that missed it, refused_shake)
    refused_shake(v, fn() { disabled() && !busy() })
    // (its ground, edge and words' ink as the tone has them, the hand's step as far as it has gone; pressed, that step
    // whole and one more: a solid one a shade darker, a quiet one the hover's ink once more over it)
    let looks_by = fn(h : Double) {
      let t = theme()
      let p = t.p
      if on_night {
        // (on a stage: the night under it whatever the theme, the primary the white, the others the white thinned)
        return match tone {
          Primary | DangerSolid => {
            let g = mix(0xFFFFFFFFL, h, share_ink)
            (g, g, share_ground)
          }
          _ => {
            let g = mix(stage_plain_lit, h, stage_plain)
            (g, g, share_ink)
          }
        }
      }
      match tone {
        Primary => {
          let g = mix(p.primary_hover, h, p.primary)
          (g, g, p.bg)
        }
        DangerSolid => {
          let g = mix(mix(p.red, 0.85, p.canvas), h, p.red)
          (g, g, if t.dark { p.bg } else { 0xFFFFFFFFL })
        }
        Danger => {
          let g = over(p.chip, alpha(p.hover, h))
          (g, g, p.red)
        }
        Ghost => (alpha(p.hover, h), 0L, p.text)
        GhostDanger => (alpha(p.hover, h), 0L, p.red)
        Plain => {
          let g = over(p.chip, alpha(p.hover, h))
          (g, g, p.text)
        }
      }
    }
    let looks = fn() {
      // (its press's way followed whether or not it deepens: what deepens it is told as it goes down)
      let pressed_now = pressed()
      let pr = if deeper.val { pressed_now } else { 0.0 }
      let (g, e, ink) = looks_by(hand.shown(v))
      if pr <= 0.0 {
        (g, e, ink)
      } else if solid {
        (over(g, alpha(button_press_shade, pr)), over(e, alpha(button_press_shade, pr)), ink)
      } else {
        let deeper = alpha(theme().p.hover, pr)
        (over(g, deeper), if e == 0L { 0L } else { over(e, deeper) }, ink)
      }
    }
    let gap = fn() { if theme().touch { 8.0 } else { 6.0 } }
    let padx = if card_words && icon == "" && !across { card_foot_words_in(height) } else { button_padx }
    v
    .row(Is(true))
    .min_height(Is(Some(height)))
    .lines_up(Is(Some(Middle)))
    .radius(Is(height / 2.0))
    .ground(By(fn() { looks().0 }))
    .alpha(By(fn() { seen.shown(v) }))
    |> ignore
    // (its ends giving way alike where what holds it is narrower than its words and their ends: across, or in a row
    // that lends it ends_give_lent)
    let ends_give = across || v.lent(ends_give_lent).unwrap_or(false)
    if across {
      // (as wide as what holds it, whichever way that lays out: its own height kept)
      v.width_share(Is(1.0)).padding(Is((0.0, 2.0, 0.0, 2.0))) |> ignore
    } else if ends_give {
      // (as wide as its words and their ends, narrower as what is beside it needs: its ends coming down first)
      v.shrink(Is(1.0)).min_width(Is(Some(0.0))).padding(Is((0.0, 2.0, 0.0, 2.0))) |> ignore
    } else {
      v.padding(Is((padx, 2.0, padx, 2.0))) |> ignore
      if v.lent(foot_fills_lent).unwrap_or(false) {
        // (at a sheet's foot, in a thumb's reach: its share of the foot's width, as the old button's there, foot_fills;
        // never narrower than its words and its ends need, what is beside it giving way first, as the old one's `keep`)
        v.grow(Is(1.0)).basis(Is(Some(0.0))).keeps_held(Is(true)).max_width(Is(None), within=true) |> ignore
      }
    }
    // (what it holds in its middle, however wide it is laid out (as wide as a column, stretched by what holds it): as
    // the old one's justify=JCenter. Where its ends give way, their room is these two's: as wide as its words and their
    // ends as it is, each end coming down alike where it is laid out narrower than that (a foot's half, or beside a
    // button that keeps its own, at a large size of words), its words in its middle still, never pushed past its far
    // end as its own padding would)
    let side = fn(s : @view.View) {
      s.grow(Is(1.0)) |> ignore
      if ends_give {
        s.shrink(Is(1.0)).basis(Is(Some(padx))).min_width(Is(Some(0.0))) |> ignore
      }
    }
    v.box(side) |> ignore
    // (the spinner's ink and its ring, and the tick's: the words' where it is solid, the accent's where not)
    let mark_ink = fn() {
      let (_, _, ink) = looks()
      if solid { ink } else { theme().p.accent }
    }
    let ring_ink = fn() {
      let (_, _, ink) = looks()
      if solid { alpha(ink, 0.3) } else { theme().p.line_strong }
    }
    // (a spinner in `room`, as far in as `shown` says: faded and grown from `about`, gone as the tick comes)
    let spinner_in = fn(room : @view.View, shown : () -> Double, about : @view.Pivot) {
      spinner_shown_node(room, ring_ink, mark_ink, fn() { turning.shown(v) * (1.0 - tick.shown(v)) }, shown, about) |> ignore
    }
    // (the tick in `room`, drawn by its stroke as far as its way has it)
    let tick_in = fn(room : @view.View) {
      room
      .width(Is(Some(button_icon)))
      .height(Is(Some(button_icon)))
      .lines(By(fn() { [@paint.line(button_tick_points, width=button_tick_w, color=mark_ink(), upto=dmax(0.0, tick.shown(v)))] }))
      |> ignore
    }
    if icon == "" {
      // (the spinner's room before its words, while it is at work or done and till its room has closed after: as wide
      // as it is open, the spinner growing from its start as it opens, the tick drawn where it turned; none of it, and
      // nothing turning, at rest)
      v.show(fn() { marked() || open.shown(v) > 0.0 }, fn(room) {
        spin_room_node(room, gap, fn() { open.shown(v) })
        room.show(fn() { busy() || turning.shown(v) > 0.0 }, at_once=true, fn(o) {
          o.over(Is(true)) |> ignore
          spinner_in(o, fn() { open.shown(v) }, At(0.0, 0.5))
        })
        room.show(fn() { done() || tick.shown(v) > 0.0 }, at_once=true, fn(o) {
          o.over(Is(true)) |> ignore
          tick_in(o)
        })
      })
    } else {
      // (its icon before its words: button's `icon`. At work the spinner takes its place, done the tick: in its own
      // room, the icon going as the spinner comes, never the two side by side (the user, 2026-11-14: 「这个怪怪的」, a
      // spinner and the refresh mark before 刷新 together), its words where they were all along. By its ink: as far in
      // from the end as the words are from the other, the grid's room round its strokes taking none, so the two ends
      // look alike: button's draw_icon by_ink)
      let (ink_l, ink_r) = match icon_numbers(icon) {
        Some(d) => @ui.shapes_ink_in(icon_shapes(d, button_icon / 24.0, 0x000000FFL), button_icon)
        None => (0.0, 0.0)
      }
      let rest = fn() { dmin(1.0, dmax(1.0 - open.shown(v), 0.0)) }
      v.box(fn(room) {
        room.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
        icon_node(room, icon, button_icon, By(fn() { looks().2 }))
        .margin(Is((-ink_l, 0.0, -ink_r, 0.0)))
        .alpha(By(fn() { seen_at(rest()) }))
        .scale(By(rest), about=At(0.5, 0.5))
        |> ignore
        room.box(fn(g) { g.width(By(fn() { Some(gap()) })) |> ignore }) |> ignore
        // (over the icon's own square: the spinner and the tick, made while they show)
        room.show(fn() { busy() || turning.shown(v) > 0.0 }, at_once=true, fn(o) {
          o.over(Is(true)).margin(Is((-ink_l, 0.0, 0.0, 0.0))) |> ignore
          spinner_in(o, fn() { 1.0 - rest() }, At(0.5, 0.5))
        })
        room.show(fn() { done() || tick.shown(v) > 0.0 }, at_once=true, fn(o) {
          o.over(Is(true)).margin(Is((-ink_l, 0.0, 0.0, 0.0))) |> ignore
          tick_in(o)
        })
      })
      |> ignore
    }
    let words = v.box(fn(w) {
      let th = @signals.untracked(theme)
      w
      .words(By(label), look={ size: th.t.ui, weight: if th.touch { 600 } else { 500 }, line: th.t.ui_line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 })
      .ink(By(fn() { looks().2 }))
      |> ignore
    })
    v.box(side) |> ignore
    // (its words changed: its ground from the shape it had, its words from where they were, together: reshape and
    // layout by its words)
    let m = @motion.moves_for(v, label, spec=button_reshape)
    m.reshapes(v)
    m.moves_with(words)
  })
}

///|
/// Whether what a node is in is a row whose buttons (button_node) give their ends' room alike where it is too narrow for
/// their words and ends, before any words are cut or pushed past a button's end: lent by viewer_frame_act_node to its
/// foot's row on a small screen, where 保存到相册 keeps its own beside 取消 and 复制 at a large size of words.
// kept across runs: what each row lends its buttons, let go with it
let ends_give_lent : @view.Lent[Bool] = @view.Lent::new()

///|
/// A spinner's room before a button's words (button_node's, way_in_button_node's): as wide as the spinner and `gap`
/// after it as far as `open` says it is open, as tall as the spinner.
fn spin_room_node(room : @view.View, gap : () -> Double, open : () -> Double) -> Unit {
  room.width(By(fn() { Some((button_icon + gap()) * dmax(open(), 0.0)) })).height(Is(Some(button_icon))) |> ignore
}

///|
/// A button's spinner in `room` (button_node's, way_in_button_node's), its ring and arc in those inks: as far in as
/// `shown` says, faded by it and by how far it turns (`turning`), grown from `about`. The spinner's node.
fn spinner_shown_node(
  room : @view.View,
  ring : () -> Int64,
  arc : () -> Int64,
  turning : () -> Double,
  shown : () -> Double,
  about : @view.Pivot,
) -> @view.View {
  spinner_node(room, size=button_icon, ring~, arc~).alpha(By(fn() { turning() * seen_at(shown()) })).scale(By(fn() { dmax(shown(), 0.0) }), about~)
}

///|
/// Whether a press of button `b` (its node `v`, its hand's step `hand`) went down where it was lit already, the step
/// at its end before the press's moment (a pointer resting on it, the keys' focus): told as each press goes down, the
/// one way the look reads it said at the same moment (PressFeel), so what reads it follows.
fn lit_before_press(v : @view.View, b : @headless.Button, hand : @motion.NodeWay) -> Ref[Bool] {
  let deeper = Ref(false)
  v.reacts(fn() { b.pressed() }, at_start=false, fn(down) {
    if down {
      let at = v.cause_at()
      deeper.val = @signals.untracked(fn() { hand.target() }) >= 1.0 && hand.starts_at() < at
    }
  })
  deeper
}

///|
/// How a button's tick is drawn as it comes to be done (its stroke from its start, eased out), its points in its
/// 16-point square (round ends and joins: a pen's), how wide, and the shade a solid one's ground darkens by pressed.
let button_tick_in : @motion.Spec = @motion.tween(240.0, ease=Out)

///|
let button_tick_points : Array[(Double, Double)] = [(3.5, 8.5), (6.75, 11.5), (12.5, 4.75)]

///|
let button_tick_w : Double = 2.0

///|
let button_press_shade : Int64 = 0x0000001FL
