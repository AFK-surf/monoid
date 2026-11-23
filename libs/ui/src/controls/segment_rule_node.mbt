// The lines down between the segments of one capsule (a bar's group of buttons drawn as one pill): rule_down, giving
// way while the hand is on a segment beside one, as a segmented control's do (the user: 对照 iOS，鼠标 hover 上去之后
// 竖线应该消失). The segments come and go in structures of their own, made before or after the lines beside them, so
// each is told to the capsule's Segments as it is made and let go, and a line reads them through it.

///|
/// The segments of one capsule, by their place in it (left to right), as they are made and let go.
pub struct Segments {
  priv made : @signals.Signal[Int]
  priv held : Map[Int, @view.View]
}

///|
/// A capsule's segments, none made yet.
pub fn Segments::new() -> Segments {
  { made: @signals.signal(0), held: {} }
}

///|
/// `v` made as segment `at` of the capsule (told as it is made: let go with it).
pub fn Segments::made(self : Segments, at : Int, v : @view.View) -> Unit {
  self.held[at] = v
  self.made.set(@signals.untracked(fn() { self.made.get() }) + 1)
  v.owns(fn() {
    if self.held.get(at) is Some(w) && w.id() == v.id() {
      self.held.remove(at)
      self.made.set(@signals.untracked(fn() { self.made.get() }) + 1)
    }
  })
  |> ignore
}

///|
/// Whether the hand is on segment `at` (lit_node's), none made there: not.
fn Segments::lit(self : Segments, at : Int) -> Bool {
  self.made.get() |> ignore
  match self.held.get(at) {
    Some(v) => lit_node(v)
    None => false
  }
}

///|
/// A line down in `parent` (a row) between the two segments of `segs` that `beside()` says (their places: which they
/// are may change as segments come and go): rule_down, `tall` high, fading out while the hand is on either of them and
/// back as it leaves (at once where a finger let go). One within a single segment says it twice.
#callsite(autofill(loc))
pub fn segment_rule_node(
  parent : @view.View,
  segs : Segments,
  beside : () -> (Int, Int),
  tall? : Double = 12.0,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(r) {
    r.width(Is(Some(rule_w))).height(Is(Some(tall))).shrink(Is(0.0)) |> ignore
    let gone = @motion.hover_fade(r, fn() {
      let (a, b) = beside()
      segs.lit(a) || segs.lit(b)
    }, duration_ms=dur_ms, instant_off=fn() {
      @ui.pointing() is Finger
    })
    r.ground(By(fn() { alpha(rule_color(), 1.0 - gone()) })) |> ignore
  })
}
