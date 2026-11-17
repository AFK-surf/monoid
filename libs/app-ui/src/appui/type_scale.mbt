// Words: five roles, each a size, a line and an icon's size that goes beside it, said at a root size of 14 and drawn
// at the root the app says (`set_type_root`), each worked out to whole device pixels (`whole_rem`) so no size of
// the scale lands between two and blurs. Two weights only: 400 and 500 (`weight_regular`, `weight_medium`).
//
// Compact (a finger's screen, `set_type_root(compact=true)`): what a control says (Ui) keeps a phone's 16, never the
// desktop's 13 shrunk, and a title is 24, set a little tighter.

///|
/// A role of words.
#derive(Eq, Debug)
pub(all) enum TextRole {
  /// a note under something, a time, a count: 12 on 16
  Caption
  /// what a control or a row says: 13 on 18 (compact 16 on 22)
  Ui
  /// a paragraph: 14 on 22
  Body
  /// a section's or a card's heading: 16 on 22
  Heading
  /// a page's title: 22 on 28 (compact 24 on 30)
  Title
}

///|
pub let weight_regular : Int = 400

///|
pub let weight_medium : Int = 500

///|
/// `size_at_base` (a size said at a root of `base`) at the root `root`, on whole device pixels (`pixel_scale` of them
/// a point): the same share of the root, never between two pixels.
pub fn whole_rem(
  size_at_base : Double,
  root : Double,
  base? : Double = 14.0,
  pixel_scale? : Double = 1.0,
) -> Double {
  let s = size_at_base * root / base
  if pixel_scale <= 0.0 {
    return s
  }
  (s * pixel_scale).round() / pixel_scale
}

///|
/// The root the words are drawn at, and whether the screen is a finger's (compact): the app's say.
#derive(Eq, Debug)
pub(all) struct TypeRoot {
  root : Double
  compact : Bool
}

///|
// kept across runs: said by the app as it starts and as the person changes the size of words
let type_root_said : @signals.Signal[TypeRoot] = @signals.signal({ root: 14.0, compact: false })

///|
/// The root size of words from now on (14: the scale as said), and whether the screen is a finger's.
pub fn set_type_root(root? : Double = 14.0, compact? : Bool = false) -> Unit {
  type_root_said.set({ root, compact })
}

///|
/// The root as it is said now (read where it is drawn, so what reads it follows).
pub fn type_root() -> TypeRoot {
  type_root_said.get()
}

///|
/// The role's size and line at the root of 14, as the screen is (compact or not).
fn TextRole::at_base(self : TextRole, compact : Bool) -> (Double, Double) {
  match self {
    Caption => (12.0, 16.0)
    Ui => if compact { (16.0, 22.0) } else { (13.0, 18.0) }
    Body => (14.0, 22.0)
    Heading => (16.0, 22.0)
    Title => if compact { (24.0, 30.0) } else { (22.0, 28.0) }
  }
}

///|
/// How big the role's words are now, at `pixel_scale` device pixels a point.
pub fn TextRole::size(self : TextRole, pixel_scale? : Double = 1.0) -> Double {
  let r = type_root()
  whole_rem(self.at_base(r.compact).0, r.root, pixel_scale~)
}

///|
/// How tall one of its lines is now: what an icon or a mark beside its first line is as tall as, and centred in.
pub fn TextRole::line_height(self : TextRole, pixel_scale? : Double = 1.0) -> Double {
  let r = type_root()
  whole_rem(self.at_base(r.compact).1, r.root, pixel_scale~)
}

///|
/// The icon that goes beside it: 14 by a caption, 16 by what a control says and by a paragraph, 20 by a heading and a
/// title.
pub fn TextRole::icon_size(self : TextRole) -> Double {
  match self {
    Caption => 14.0
    Ui | Body => 16.0
    Heading | Title => 20.0
  }
}

///|
/// How far apart its letters are set besides their own spacing: a large title's a little tighter.
fn TextRole::tracking(self : TextRole) -> Double {
  match self {
    Title => -0.01
    _ => 0.0
  }
}

///|
/// The look of words in `role` at `weight` (400 or 500), on one line unless `wrap`, at `pixel_scale`.
pub fn text_look(
  role : TextRole,
  weight? : Int = weight_regular,
  wrap? : Bool = false,
  pixel_scale? : Double = 1.0,
) -> @view.WordsLook {
  {
    size: role.size(pixel_scale~),
    weight: if weight >= weight_medium { weight_medium } else { weight_regular },
    line: role.line_height(pixel_scale~),
    wrap,
    tracking: Ems(role.tracking()),
    balance: false,
    max_lines: 0,
  }
}

///|
/// Words in `parent`: `text` in `role`, its ink `ink`, at `weight`, wrapped where `wrap`; drawn on the node's own pixels
/// as the root says. The node.
#callsite(autofill(loc))
pub fn text_node(
  parent : @view.View,
  text : () -> String,
  role : TextRole,
  ink : () -> Int64,
  weight? : Int = weight_regular,
  wrap? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(w) {
    w
    .words(By(text))
    .words_look(By(fn() { text_look(role, weight~, wrap~, pixel_scale=w.pixel_scale()) }))
    .ink(By(ink))
    |> ignore
    if wrap {
      w.shrink(Is(1.0)) |> ignore
    }
  })
}
