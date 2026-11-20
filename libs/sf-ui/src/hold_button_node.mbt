// A button that is held to be done (按住确认), for what is not to be done by a slip of the hand: held, its ink fills it
// from its start as long as it is held (@motion.HoldWay: a line in time, its whole length however motion is set), its
// words over the fill turned to the ground's ink at the fill's edge, so a word half under it reads as clearly; let go
// short of full, the fill drains back from where it was; full, done (felt under a finger) and, where it can be undone,
// the button turns in place (its ground and words together: moves_for) into 撤销 for a while, back to itself after.
// What it is to the keyboard and a screen reader is mbui's headless button's: pressed by them, it is done at once (no
// hold is asked of one who cannot hold), as by a hold.

///|
/// A button in `parent` held `hold_ms` to do `confirm`: `label` its words, `danger` red (else the primary's ink);
/// faded and taking nothing while `disabled`. `undo`: done, the button is `undo_label` for its time (ms), pressed then
/// to undo (`undo`'s function), back to itself once it is over. Its height and round ends a button's (button_height).
/// `moves`: given what moves as it turns into its undo and back, so what is beside it goes with it (Moves::moves_with).
/// The node.
#callsite(autofill(loc))
pub fn hold_button_node(
  parent : @view.View,
  label : () -> String,
  confirm : () -> Unit,
  hold_ms? : Double = hold_button_ms,
  danger? : Bool = true,
  disabled? : () -> Bool = fn() { false },
  undo? : (() -> Unit, Double),
  undo_label? : () -> String = fn() { t("android-chat.marks.undo") },
  moves? : (@motion.Moves) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let height = button_height()
  // (done and undoable now: its undo's time due, let go as it is over)
  let undoing : @signals.Signal[Bool] = @signals.signal(false)
  let undo_due = Ref(fn() {  })
  let words = fn() { if undoing.get() { undo_label() } else { label() } }
  // (done at `v`'s cause's moment (a hold come to its full, a key's or a screen reader's press): felt under a finger,
  // undoable for a while where it can be)
  let done = fn(v : @view.View) {
    if @ui.pointing() is Finger {
      @ui.haptic(Confirm)
    }
    confirm()
    match undo {
      Some((_, ms)) => {
        @view.transition(within=v, fn() { undoing.set(true) })
        (undo_due.val)()
        undo_due.val = v.at_moment(v.cause_at() + ms, fn() {
          undo_due.val = fn() {  }
          @view.transition(within=v, fn() { undoing.set(false) })
        })
      }
      None => ()
    }
  }
  @headless.button(
    made_for=loc,
    parent,
    words,
    disabled~,
    // (a press of the pointer's or a finger's that goes down while it is to be held is the hold's, none as it is let
    // go: asked as it goes down, so the press that held it to its full, turning it into its undo, does not undo it as
    // it is let go; while it is its undo, a press as any. The keys' and a screen reader's presses as ever: done at once)
    hold=@headless.Hold::new(@ui.touch_slop(), @ui.long_press_ms, fn() { false }, taps=fn() { undoing.untracked() }),
    fn(v) {
      if undoing.untracked() {
        // (undone: itself again at once)
        match undo {
          Some((f, _)) => {
            (undo_due.val)()
            undo_due.val = fn() {  }
            @view.transition(within=v, fn() { undoing.set(false) })
            f()
          }
          None => ()
        }
      } else {
        done(v)
      }
    },
    fn(v, b) {
    let live = fn() { !disabled() && !undoing.get() }
    let fill_ink = fn() {
      let p = theme().p
      if danger { p.red } else { p.primary }
    }
    let ink_on_fill = fn() { if theme().dark && !danger { theme().p.bg } else { 0xFFFFFFFFL } }
    // (its hold: from the press as it is held, done at its full)
    let hold = @motion.hold_way(v, hold_ms, live~, fn() { done(v) })
    v.owns(fn() { (undo_due.val)() }) |> ignore
    let hand = @motion.NodeWay::new(0.0)
    v.reacts(fn() { live() && (b.focus_shown() || b.hovered()) }, fn(on) { hand.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms) })
    let seen = @motion.NodeWay::new(if @signals.untracked(disabled) { 0.45 } else { 1.0 })
    v.reacts(disabled, fn(off) { seen.go_ms(v, if off { 0.45 } else { 1.0 }, dur_ms) })
    let words_ink = fn() { if undoing.get() { theme().p.text } else { fill_ink() } }
    v
    .focus_ring_theme()
    .row(Is(true))
    .height(Is(Some(height)))
    .padding(Is((button_padx, 0.0, button_padx, 0.0)))
    .lines_up(Is(Some(Middle)))
    .radius(Is(height / 2.0))
    .clips(Is(true))
    .ground(By(fn() {
      let p = theme().p
      over(if undoing.get() { p.chip } else { alpha(fill_ink(), hold_button_ground) }, alpha(p.hover, hand.shown(v)))
    }))
    .alpha(By(fn() { seen.shown(v) }))
    |> ignore
    let th = @signals.untracked(theme)
    let look : @view.WordsLook = { size: th.t.ui, weight: if th.touch { 600 } else { 500 }, line: th.t.ui_line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
    v.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
    let said = v.box(fn(w) { w.words(By(words), look~).ink(By(words_ink)) |> ignore })
    v.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
    // (the fill: over all of it, slid in from its start as far as the hold has come, what it holds slid back as far so it
    // stays where it is laid out: its edge the fill's, the words under it in the ground's ink; by its own width at the
    // moment drawn, nothing laid out again; made while it is held or draining)
    v.show(fn() { hold.holding() || hold.progress_on(v) > 0.0 }, at_once=true, fn(f) {
      f
      .over(Is(true))
      .clips(Is(true))
      .ground(By(fill_ink))
      .moved_by(fn(w, _h, at) { (-w * (1.0 - dmin(1.0, dmax(0.0, hold.at(at)))), 0.0) }, fn(_w, _h) { hold.end() })
      |> ignore
      f.box(fn(inner) {
        inner
        .over(Is(true))
        .row(Is(true))
        .padding(Is((button_padx, 0.0, button_padx, 0.0)))
        .lines_up(Is(Some(Middle)))
        .moved_by(fn(w, _h, at) { (w * (1.0 - dmin(1.0, dmax(0.0, hold.at(at)))), 0.0) }, fn(_w, _h) { hold.end() })
        |> ignore
        inner.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
        inner.box(fn(w) { w.words(By(label), look~).ink(By(ink_on_fill)) |> ignore }) |> ignore
        inner.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
      })
      |> ignore
    })
    // (turned into its undo and back: its ground and its words together, in place)
    let m = @motion.moves_for(v, words, spec=button_reshape)
    m.reshapes(v)
    m.moves_with(said)
    match moves {
      Some(f) => f(m)
      None => ()
    }
    },
  )
}

///|
/// How long a button held to be done is held by default, and how strong its ink's ground is at rest.
pub let hold_button_ms : Double = 900.0

///|
let hold_button_ground : Double = 0.12
