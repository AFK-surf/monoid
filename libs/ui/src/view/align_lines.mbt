// What a row lines up by the first lines of what it holds, as SwiftUI's `.firstTextBaseline` and Compose's
// `AlignmentLine` (FirstBaseline) do: words of different sizes on one baseline, and an icon or a switch on the middle
// of the first line beside it, however many lines that block comes to. The layout finds those lines itself (flex's
// Baseline and FirstLineCenter, its words' measures telling where their first line is: @flex.first_line_told), so no
// part works out a margin from the theme's sizes to drop one thing onto another's line.

///|
/// Whether what it holds, along its row, shares one baseline (`on`): each one's first line's (its words', else the first
/// of what it holds on its first line, else its foot), whatever size their words are and however many lines they wrap
/// on; off, at their starts as `lines_up(Is(Some(Start)))` puts them. As it changes: layout's.
#callsite(autofill(loc))
pub fn View::lines_up_baseline(self : View, on : Live[Bool], loc~ : SourceLoc) -> View {
  self.bind(loc~, LinesUp, on, Layout, fn(on) {
    self.tree.nodes[self.at].flex.style.align_items = if on { @flex.Baseline } else { @flex.FlexStart }
  })
  self
}

///|
/// Whether what it holds, along its row, lines up on the middle of the tallest first line among them (`on`): an icon, a
/// mark, a switch or one line of words in the middle of the first line of a block of several beside it, never of the
/// block's height (Tester::first_line_faults); a block's first line its words', else the first of what it holds on its
/// first line; one with no words in it, its own middle. Off, in their middles as `lines_up(Is(Some(Middle)))` puts them.
/// As it changes: layout's.
#callsite(autofill(loc))
pub fn View::lines_up_first_line(self : View, on : Live[Bool], loc~ : SourceLoc) -> View {
  self.bind(loc~, LinesUp, on, Layout, fn(on) {
    self.tree.nodes[self.at].flex.style.align_items = if on { @flex.FirstLineCenter } else { @flex.Center }
  })
  self
}
