// Odometer-style per-character rolling slots: each character lives in a right-aligned slot keyed by distance from the
// right end, so unchanged slots stay completely still while changed slots roll the new character in (from below when
// dir >= 0, from above when dir < 0) and the old character out via `View::moved_by` with zero layout recomputation.

///|
/// Split `words` into its Unicode scalar values, one per rolling slot.
pub fn rolling_chars(words : String) -> Array[Char] {
  let out = []
  for c in words {
    out.push(c)
  }
  out
}

///|
/// Build a horizontal row of right-aligned rolling character slots in `parent`.
/// Unchanged slots remain still; a slot whose character changes rolls the incoming character in and the outgoing
/// character out on `spec` (default `digit_spring`) using `View::moved_by` (zero Flex relayout), with soft top/bottom
/// edge fade `fade_px` while rolling. When `rolls()` returns `false` at the change moment, the new character snaps
/// immediately with no outgoing ghost.
#callsite(autofill(loc))
pub fn rolling_slots_node(
  parent : @view.View,
  words : () -> String,
  dir : () -> Double,
  style : () -> @ui.TextStyle,
  ink : () -> Int64,
  rolls? : () -> Bool = fn() { true },
  spec? : Spec = digit_spring,
  fade_px? : Double = 3.0,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(v) {
    v.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
    // Key each slot by distance from the right end so prefix insertions/removals preserve right-aligned slot identity.
    v.each(
      fn() {
        let n = rolling_chars(words()).length()
        Array::makei(n, fn(i) { n - 1 - i })
      },
      fn(k) { k },
      fn(slot, place) {
        let char_now = fn() {
          let cs = rolling_chars(words())
          let i = cs.length() - 1 - place.untracked()
          if i >= 0 && i < cs.length() {
            cs[i].to_string()
          } else {
            ""
          }
        }
        rolling_slot(loc~, slot, char_now, dir, style, ink, rolls, spec, fade_px)
      },
      along_row=true,
    )
  })
}

///|
/// Single character slot within `rolling_slots_node`.
#callsite(autofill(loc))
fn rolling_slot(
  s : @view.View,
  char_now : () -> String,
  dir : () -> Double,
  style : () -> @ui.TextStyle,
  ink : () -> Int64,
  rolls : () -> Bool,
  spec : Spec,
  fade_px : Double,
  loc~ : SourceLoc,
) -> Unit {
  let held = @signals.untracked(char_now)
  let shown : @signals.Signal[String] = @signals.signal(held)
  let gone : @signals.Signal[String] = @signals.signal("")
  let way_dir = Ref(1.0)
  let roll = NodeWay::new(1.0)
  s.reacts(fn() { (char_now(), dir()) }, at_start=false, fn(now) {
    let (c, d) = now
    if c == shown.untracked() {
      return
    }
    if !@signals.untracked(rolls) {
      gone.set("")
      shown.set(c)
      roll.put(1.0)
      return
    }
    gone.set(shown.untracked())
    shown.set(c)
    way_dir.val = if d < 0.0 { -1.0 } else { 1.0 }
    roll.go_from(s, 0.0, 1.0, spec)
  })
  let rolling = fn() { roll.goes(s) }
  s
  .clips(Is(true))
  .fades(By(fn() { if rolling() { (0.0, fade_px, 0.0, fade_px) } else { (0.0, 0.0, 0.0, 0.0) } }))
  |> ignore
  let ends = fn(_w : Double, _h : Double) {
    roll.target() |> ignore
    roll.end()
  }
  s.box(made_for=loc, fn(w) {
    w
    .words(By(fn() { shown.get() }))
    .words_look(By(fn() { @ui.style_words(style()) }))
    .ink(By(ink))
    .moved_by(fn(_w, h, at) { (0.0, way_dir.val * h * (1.0 - dmin(1.0, roll.value_at(at)))) }, ends)
    |> ignore
  })
  |> ignore
  s.show(fn() { rolling() && gone.get() != "" }, at_once=true, fn(o) {
    o.over(Is(true)) |> ignore
    o.box(made_for=loc, fn(w) {
      w
      .words(By(fn() { gone.get() }))
      .words_look(By(fn() { @ui.style_words(style()) }))
      .ink(By(ink))
      .moved_by(fn(_w, h, at) { (0.0, -way_dir.val * h * dmin(1.0, roll.value_at(at))) }, ends)
      |> ignore
    })
    |> ignore
  })
}
