// People overlapping a little (a chat's people in its bar, in its sheet): their faces side by side, each ringed in what
// they stand on so the one over another stands clear of it, the first over them all; past as many as are shown, +n.

///|
/// A face of a stack (avatar_stack_node's): who (`id`, its colour by it), their name (its initial while their picture
/// is not there), whether they have a picture at all (`pictured`), their picture's key as it is now ("" none:
/// avatar_node's `picture`).
pub(all) struct StackFace {
  id : String
  name : String
  pictured : Bool
  picture : () -> String
}

///|
/// People overlapping a little in `parent` (a row): `faces`' first `most` (0: all of them), each a face `size` across
/// (@sf.avatar_node) ringed `ring_w` in `ring()` (what the stack stands on), each ringed face `over` over the one
/// before it, the first over them all (`first_over`; false: each over the one before it); more than `most`, +n after
/// them (`more_look`). `letter`: where given, one with no picture is their initial in its look on its ground, a circle
/// `size` across (the wide bar's: on the paper), never their colour. Read out a group named `label()`
/// (none: their initials and the +n, as the stack shows them); its tip in `tips` (`tip`), where given. The stack's
/// node.
#callsite(autofill(loc))
pub fn avatar_stack_node(
  parent : @view.View,
  faces : Array[StackFace],
  size : Double,
  ring : () -> Int64,
  ring_w? : Double = 1.5,
  over? : Double = 5.0,
  first_over? : Bool = true,
  letter? : (() -> Int64, () -> @ui.TextStyle),
  most? : Int = 0,
  more_look? : () -> @ui.TextStyle = fn() { avatar_stack_more },
  label? : () -> String,
  tips? : TipLayer,
  tip? : () -> String,
  loc~ : SourceLoc,
) -> @view.View {
  let shown = if most > 0 && faces.length() > most { faces[:most].to_owned() } else { faces }
  let more = faces.length() - shown.length()
  let ringed = size + 2.0 * ring_w
  let step = ringed - over
  let n = shown.length()
  let faces_w = if n > 0 { ringed + step * (n - 1).to_double() } else { 0.0 }
  // (one node: the faces laid over it, each where its turn puts it, and the +n in its row after them; as the pages'
  // own stacks were, no box more than they made)
  parent.box(made_for=loc, fn(row) {
    row
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .shrink(Is(0.0))
    .width(Is(if more > 0 { None } else { Some(faces_w) }))
    .min_width(Is(Some(faces_w)))
    .height(Is(Some(ringed)))
    |> ignore
    // (first over them all: the last made first, each under the one after it in the tree's order; else in their order)
    for j in 0..<n {
      let i = if first_over { n - 1 - j } else { j }
      let p = shown[i]
      row.box(fn(d) {
        d
        .over(Is(true))
        .width(Is(Some(ringed)))
        .height(Is(Some(ringed)))
        .radius(Is(ringed / 2.0))
        .offset(Is((step * i.to_double(), 0.0)))
        .ground(By(ring))
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        |> ignore
        match letter {
          Some((ground, look)) if !p.pictured =>
            d.box(fn(l) {
              l
              .width(Is(Some(size)))
              .height(Is(Some(size)))
              .radius(Is(size / 2.0))
              .row(Is(true))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              .ground(By(ground))
              |> ignore
              words_node(l, fn() { initial(p.name) }, look) |> ignore
            })
            |> ignore
          _ => avatar_node(d, fn() { p.id }, fn() { p.name }, p.picture, size)
        }
      })
      |> ignore
    }
    if more > 0 {
      row.box(fn(m) {
        style_node(m, fn() { avatar_stack_more_box }, in_row=true)
        // (after the faces, which take no room of the row: laid over it)
        m.margin(Is((faces_w, 0.0, 0.0, 0.0))) |> ignore
        words_node(m, fn() { "+\{more}" }, more_look) |> ignore
      })
      |> ignore
    }
    // (read out as a group named by what it shows: nothing pressed in it)
    match label {
      Some(f) => row.says(By(fn() { Some(@view.said(Group, label=f())) })) |> ignore
      None => {
        let named = (shown.map(fn(p) { initial(p.name) }) + (if more > 0 { ["+\{more}"] } else { [] })).join(" ")
        row.says(Is(Some(@view.said(Group, label=named)))) |> ignore
      }
    }
    match (tips, tip) {
      (Some(layer), Some(f)) => tip_node(layer, row, f, within=true) |> ignore
      _ => ()
    }
  })
}

///|
/// +n after a stack: 6 after its faces, the caption's size, muted, on one line.
// kept across runs: a value (no field of it changes)
let avatar_stack_more_box : @ui.Style = @ui.css("pl=S1_5")

///|
// kept across runs: a value (no field of it changes)
let avatar_stack_more : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false)
