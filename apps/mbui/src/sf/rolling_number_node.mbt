// A number that rolls (an odometer's): its characters each in a slot of its own, counted from its right end (ones,
// tens, hundreds…, a sign or a mark after it in its own), its digits all one width (tabular), so a change leaves every
// slot whose character stays as it is where it is, still; a slot whose character changes rolls the new one in (from
// under it as the number grows, from over it as it falls) and the old one out the other way, on a spring from the
// moment it changed, cut to its slot, its top and foot faded a little while it rolls. Each slot's roll is drawn where it
// is drawn (View::moved_by: by its own height at the moment drawn), nothing laid out again for it; at rest nothing reads
// the clock and nothing is faded.

///|
/// What a rolling number is now, as its slots read it: the words, which way it went last (1 up, -1 down, 0 neither:
/// as it was first), counted so a change to the same words still tells.
#derive(Eq)
priv struct RollNow {
  words : String
  dir : Double
}

///|
/// A number in `parent` that rolls as it changes: `value()` written by `format` (its digits by default), in `style()`
/// (its digits made one width: tabular). Slots counted from its right end, each its character's own; one whose
/// character changes rolls (@motion.digit_spring), the rest still. `rolls`: whether a change now rolls (asked at the
/// change; while not, the new character there at once: a number running under the hand, a slider dragged, each
/// step of it no roll of its own). The node.
#callsite(autofill(loc))
pub fn rolling_number_node(
  parent : @view.View,
  value : () -> Int,
  format? : (Int) -> String = fn(n) { n.to_string() },
  style? : () -> @ui.TextStyle = fn() { theme().rows.title },
  rolls? : () -> Bool = fn() { true },
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(v) {
    let first = @signals.untracked(value)
    let now : @signals.Signal[RollNow] = @signals.signal({ words: format(first), dir: 0.0 })
    let last = Ref(first)
    v.reacts(value, at_start=false, fn(n) {
      let dir = if n > last.val { 1.0 } else if n < last.val { -1.0 } else { 0.0 }
      last.val = n
      now.set({ words: format(n), dir })
    })
    let look = fn() { style().then(rolling_tabular) }
    v.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
    // (its slots from its left, each by how far it is from the right end: what a slot is keeps its key as the number
    // grows or shrinks at its left)
    v.each(
      fn() {
        let n = rolling_chars(now.get().words).length()
        Array::makei(n, fn(i) { n - 1 - i })
      },
      fn(k) { k },
      fn(slot, place) {
        let char_now = fn() {
          let cs = rolling_chars(now.get().words)
          let i = cs.length() - 1 - place.untracked()
          if i >= 0 && i < cs.length() {
            cs[i].to_string()
          } else {
            ""
          }
        }
        rolling_slot(loc~, slot, char_now, fn() { now.get().dir }, look, rolls)
      },
      // (a slot come or gone at its left end makes its way along the row: the rest move over as it does)
      along_row=true,
    )
  })
}

///|
/// The characters of `w`, one a slot.
fn rolling_chars(w : String) -> Array[Char] {
  let out = []
  for c in w {
    out.push(c)
  }
  out
}

///|
/// What a rolling number's words are drawn in, on top of what is said: its digits one width.
let rolling_tabular : @ui.TextStyle = @ui.text_style(tabular=true)

///|
/// How far a rolling slot's top and foot are faded while it rolls (points).
let roll_fade : Double = 3.0

///|
/// One slot `s` of a rolling number: `char_now()` its character, `dir()` which way the number went last, in `look()`.
/// Its character drawn where it is laid out at rest; changed, the new one rolled in from under it (`dir` up) or over it
/// and the old one out the other way.
#callsite(autofill(loc))
fn rolling_slot(
  s : @view.View,
  char_now : () -> String,
  dir : () -> Double,
  look : () -> @ui.TextStyle,
  rolls : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  let held = @signals.untracked(char_now)
  // (the character it rolls in and the one it rolls out, which way, how far: none rolling as it is made)
  let shown : @signals.Signal[String] = @signals.signal(held)
  let gone : @signals.Signal[String] = @signals.signal("")
  let way_dir = Ref(1.0)
  let roll = @motion.NodeWay::new(1.0)
  s.reacts(fn() { (char_now(), dir()) }, at_start=false, fn(now) {
    let (c, d) = now
    if c == shown.untracked() {
      return
    }
    if !@signals.untracked(rolls) {
      // (no roll now: the new one there at once, nothing of the old left)
      gone.set("")
      shown.set(c)
      roll.put(1.0)
      return
    }
    gone.set(shown.untracked())
    shown.set(c)
    way_dir.val = if d < 0.0 { -1.0 } else { 1.0 }
    roll.go_from(s, 0.0, 1.0, @motion.digit_spring)
  })
  // (the old one shown while the roll goes: once it is in, nothing left of it, the way's own end telling so)
  let rolling = fn() { roll.goes(s) }
  s
  .clips(Is(true))
  .fades(By(fn() { if rolling() { (0.0, roll_fade, 0.0, roll_fade) } else { (0.0, 0.0, 0.0, 0.0) } }))
  |> ignore
  // (where each is as its slot is drawn: by its own height at that moment, nothing laid out again)
  let ends = fn(_w : Double, _h : Double) {
    roll.target() |> ignore
    roll.end()
  }
  s.box(made_for=loc, fn(w) {
    styled_words(w, fn() { shown.get() }, look)
    .moved_by(fn(_w, h, at) { (0.0, way_dir.val * h * (1.0 - dmin(1.0, roll.value_at(at)))) }, ends)
    |> ignore
  })
  |> ignore
  s.show(fn() { rolling() && gone.get() != "" }, at_once=true, fn(o) {
    o.over(Is(true)) |> ignore
    o.box(made_for=loc, fn(w) {
      styled_words(w, fn() { gone.get() }, look)
      .moved_by(fn(_w, h, at) { (0.0, -way_dir.val * h * dmin(1.0, roll.value_at(at))) }, ends)
      |> ignore
    })
    |> ignore
  })
}
