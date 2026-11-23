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
  let first = @signals.untracked(value)
  let now : @signals.Signal[RollNow] = @signals.signal({ words: format(first), dir: 0.0 })
  let last = Ref(first)
  let look = fn() { style().then(rolling_tabular) }
  let v = @motion.rolling_slots_node(
    parent,
    fn() { now.get().words },
    fn() { now.get().dir },
    look,
    fn() { @ui.style_ink(look()) },
    rolls~,
    loc~,
  )
  v.reacts(value, at_start=false, fn(n) {
    let dir = if n > last.val { 1.0 } else if n < last.val { -1.0 } else { 0.0 }
    last.val = n
    now.set({ words: format(n), dir })
  })
  v
}

///|
/// What a rolling number's words are drawn in, on top of what is said: its digits one width.
let rolling_tabular : @ui.TextStyle = @ui.text_style(tabular=true)
