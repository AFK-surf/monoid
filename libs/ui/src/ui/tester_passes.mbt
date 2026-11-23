// What causes the window's tree to be laid out lays it out a few times, never over and over: each cause a Tester's
// frames meet is held to `layout_passes_most` passes of the tree's layout (Tree::laid_out, each that laid out or placed
// something): each event a host hands it between frames (an input, the core's messages taken together), and, outside
// them, each moment (a frame's own, each moment come due on the tree's timeline, the changes a test or a host told at
// one moment, together). A cause that lays the tree out more is a change committed piece by piece, each piece laying it
// out again, which no check of what a frame shows finds: #6525's frame settled each of its 28 answers as a change of
// its own, 56 passes, every test green, and a Mac's send hung 300 ms. So no test writes a count of its own: whichever
// meets such a cause fails, saying how many passes it ran, its moment and what ran each, where the tree keeps sources
// (view's passes.mbt: run again inside another for what it told, or what laid the tree out, and where what was first
// marked and first due in it was made). Held by the cause, never by the frame: a frame at 7 a second draws what one at
// 120 does over seventeen of its moments, each held the same at both.

///|
/// The most layout passes of the window's tree one cause (an event between frames, a moment outside them) may run.
/// Measured over every test (2026-11-16): the window's tree alone and every replay at most 8 at any moment; a host's
/// frame that has old views beside the tree (the tree brought as the frame begins and again as it is built, the old
/// views' islands asking where they are laid out, the passes run again for sizes followed and what waited) at most 11,
/// a window's first frame or one it is resized in. A cause that commits piece by piece goes far past it (#6525: 56; a
/// moment's changes each settled under the pointer: 79), so no file is let off it.
pub let layout_passes_most : Int = 12

///|
/// The window's tree's passes counted from now, those before let go (a Tester made: what made its first frame is
/// counted with that frame).
fn passes_begin() -> Unit {
  passes_counted_now()
}

///|
/// What is wrong with the passes the causes since the frame before ran, said: None where none ran over
/// `layout_passes_most`. Taken: what is asked next is of what came after.
fn Tester::passes_said(self : Tester) -> String? {
  guard view_app.val is Some(tree) else { return None }
  let (_, event_most) = tree.event_passes_taken()
  let (moment, moment_most) = tree.moment_passes_taken()
  guard moment_most > layout_passes_most || event_most > layout_passes_most else {
    tree.passes_said() |> ignore
    return None
  }
  let (what, lines) = if moment_most > layout_passes_most {
    (
      "laid out \{moment_most} times as of the moment \{moment}",
      tree.passes_said(at=moment),
    )
  } else {
    ("laid out \{event_most} times in one event between frames", tree.passes_said(events=true))
  }
  let causes : Map[String, Int] = Map([])
  let order : Array[String] = []
  for line in lines {
    if !causes.contains(line) {
      order.push(line)
    }
    causes[line] = causes.get(line).unwrap_or(0) + 1
  }
  let said = order.iter().take(12).map(fn(l) { "  \{causes.get(l).unwrap_or(0)}× \{l}" }).collect()
  Some(
    "the window's tree \{what} (at most \{layout_passes_most}: mbui's src/ui/tester_passes.mbt), the frame at " +
    "\{self.fake.time}, the Tester made at \{looks_made_at.val}" +
    (if said.is_empty() { "" } else { "; what ran them:\n" + said.join("\n") }),
  )
}

///|
/// The causes since the frame before held to their passes (Tester::passes_said): stopped on.
fn Tester::hold_passes(self : Tester) -> Unit {
  match self.passes_said() {
    Some(said) => @halt.saying(said)
    None => ()
  }
}

///|
/// What the frame's own checks ran after it (none of the app's causes), let go of: counted from here for the next.
fn passes_counted_now() -> Unit {
  guard view_app.val is Some(tree) else { return }
  tree.event_passes_taken() |> ignore
  tree.moment_passes_taken() |> ignore
  tree.passes_said() |> ignore
}
