// An empty state (空状态) as nodes of the window's tree, made once: what a page or a list with nothing in it yet shows,
// in the middle of the room it has. An icon in a quiet circle, what is empty (its title), a line saying why or what to do
// (centred, going on in lines no wider than empty_state_words_w, never cut short), and what to do about it (a button
// or two the caller makes), each under the one before.

///|
/// An empty state in `parent`, as wide as where it is, its parts in its middle: `icon` in a quiet circle 48 across, its
/// `title` (15, 600), `note` under it (13, muted, centred, in lines 320 wide at most; none, nor its room, where it is
/// ""), and what `action` makes under them (none where it is not given). The node.
#callsite(autofill(loc))
pub fn empty_state_node(
  parent : @view.View,
  icon : String,
  title : () -> String,
  note? : () -> String = fn() { "" },
  action? : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    style_node(b, fn() { empty_state_box })
    b.box(fn(mark) {
      style_node(mark, fn() { empty_state_mark })
      icon_node(mark, icon, empty_state_icon, By(fn() { theme().p.muted })) |> ignore
    })
    |> ignore
    // (its words 320 wide at most, in the middle of a line across it)
    b.box(fn(line) {
      style_node(line, fn() { empty_state_words_line })
      line.box(fn(words) {
        style_node(words, fn() { empty_state_words })
        words_node(words, title, fn() { empty_state_title }) |> ignore
        words.show(fn() { note() != "" }, at_once=true, fn(n) {
          style_node(n, fn() { empty_state_note_box })
          words_node(n, note, fn() { empty_state_note }) |> ignore
        })
      })
      |> ignore
    })
    |> ignore
    match action {
      Some(f) =>
        b.box(fn(a) {
          style_node(a, fn() { empty_state_actions })
          // (where they have not the room, going on in lines over the first, which keeps the foot)
          a.wraps(Is(Some(empty_state_lines_gap)), reverse=true) |> ignore
          f(a)
        })
        |> ignore
      None => ()
    }
  })
}

///|
/// The icon in its circle.
let empty_state_icon : Double = 24.0

///|
/// How far apart its buttons' lines are where they go on in lines.
let empty_state_lines_gap : Double = 8.0

///|
/// The whole of it: as wide as where it is, 32 in, its parts 16 apart in its middle.
// kept across runs: a value (no field of it changes)
let empty_state_box : @ui.Style = @ui.css("w=Full px=S6 py=S8 gap=S4 align=ACenter justify=JCenter")

///|
/// The icon's quiet circle, 48 across.
// kept across runs: a value (no field of it changes)
let empty_state_mark : @ui.Style = @ui.css("w=S12 h=S12 radius=Full bg=A(Fg,O5) align=ACenter justify=JCenter")

///|
/// The line its words are in the middle of, across it.
// kept across runs: a value (no field of it changes)
let empty_state_words_line : @ui.Style = @ui.css("row w=Full justify=JCenter")

///|
/// Its words: its title and the line under it 6 apart, 320 wide at most, in its middle.
// kept across runs: a value (no field of it changes)
let empty_state_words : @ui.Style = @ui.css("w=Full max_w=S80 gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let empty_state_note_box : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let empty_state_title : @ui.TextStyle = @ui.text_style(size=Body, weight=Semibold, color=Fg, center=true)

///|
// kept across runs: a value (no field of it changes)
let empty_state_note : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, center=true)

///|
/// What to do: its buttons 8 apart in a line in the middle (in lines where they have not the room: empty_state_node).
// kept across runs: a value (no field of it changes)
let empty_state_actions : @ui.Style = @ui.css("row gap=S2 justify=JCenter align=ACenter")
