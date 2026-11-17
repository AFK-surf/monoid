// Room: the eight steps a part's own padding and gaps are said in, the three a page stands in from the window's edges,
// and the corners. A part never types a number of room: it names a step, so two parts beside each other agree, and the
// distance between two things is said once (a gap, or a padding, never both added: mbui's gap rule 6).
//
// Corners are concentric: what lies in a rounded box's corner, as far in from both of its edges, is as round as the box
// less that distance (`concentric_radius`), never rounder, and never cut to look so (mbui's corner rule, Tester::audit):
// a card 12 round holds what lies 6 in, 6 round; a sheet 16 round, 8 in, 8 round.

///|
/// A step of a part's own room: its padding and the gaps between what it holds.
#derive(Eq, Debug)
pub(all) enum Space {
  S0
  S2
  S4
  S6
  S8
  S12
  S16
  S20
}

///|
/// How many points the step is.
pub fn Space::pt(self : Space) -> Double {
  match self {
    S0 => 0.0
    S2 => 2.0
    S4 => 4.0
    S6 => 6.0
    S8 => 8.0
    S12 => 12.0
    S16 => 16.0
    S20 => 20.0
  }
}

///|
/// The step under it (S0 stays): the side of a button where an icon leads, whose drawing has room of its own round its
/// strokes, so a step less of padding there looks as far in as the words' side does.
pub fn Space::less(self : Space) -> Space {
  match self {
    S0 | S2 => S0
    S4 => S2
    S6 => S4
    S8 => S6
    S12 => S8
    S16 => S12
    S20 => S16
  }
}

///|
/// A padding of four steps, as `View::padding` takes it: left, top, right, foot.
pub fn pad(l : Space, t : Space, r : Space, b : Space) -> (Double, Double, Double, Double) {
  (l.pt(), t.pt(), r.pt(), b.pt())
}

///|
/// The same step all round.
pub fn pad_all(s : Space) -> (Double, Double, Double, Double) {
  (s.pt(), s.pt(), s.pt(), s.pt())
}

///|
/// How far a page stands in from the window's edges: 24 on a narrow window, 32 and 40 on wider ones.
#derive(Eq, Debug)
pub(all) enum Gutter {
  G24
  G32
  G40
}

///|
/// How many points the gutter is.
pub fn Gutter::pt(self : Gutter) -> Double {
  match self {
    G24 => 24.0
    G32 => 32.0
    G40 => 40.0
  }
}

///|
/// The corner of what lies `inset` in from both edges of a box `outer` round, concentric with it (none past its arc).
pub fn concentric_radius(outer : Double, inset : Double) -> Double {
  if outer - inset > 0.0 {
    outer - inset
  } else {
    0.0
  }
}

///|
/// The corner of a card, and the room it keeps round what it holds (its rows', its buttons' corners concentric with it).
pub let card_radius : Double = 12.0

///|
pub let card_inset : Space = S6

///|
/// The corner of a sheet or a dialog, and the room it keeps round what it holds.
pub let sheet_radius : Double = 16.0

///|
pub let sheet_inset : Space = S8

///|
/// The corner of a control (a button, a row, a segment) that lies in a card's corner: concentric with the card.
pub let control_radius : Double = concentric_radius(card_radius, card_inset.pt())
