// A row on a group's card made of parts (a compound row with slots, as Base UI's and Radix's compound parts and
// Compose's slots are): `row_box_node` makes the row, its box, its press and how it stands on a card, a panel or a
// wide list; what it holds is said part by part on its RowScope (`lead`, `title`, `note`, `value`, `tail`, `chevron`,
// `below`), each a few arguments, in place of link_row_node's thirty-odd. The parts are said first and the row is
// made once after, by link_row_node's own making (link_row_made), so a row said in parts is drawn as link_row_node
// draws it, node for node, narrow and wide: one layout, never two that drift apart.

///|
/// How a compound row's title is drawn: `RowNormal` the row's; `RowStrong` where it names who or what it is;
/// `RowAccent` in the link's ink, where the row does something at once where it is (no chevron then: link_row_node's
/// `acts`); `RowDanger` in red, where it takes something away.
#derive(Eq)
pub(all) enum RowTone {
  RowNormal
  RowStrong
  RowAccent
  RowDanger
}

///|
/// How a compound row's note or value is drawn: `NoteMuted` quieter than its title; `NoteWarn` in amber (soon not as
/// it should be); `NoteBad` in red (what is wrong: a note so is a line of its own under the note, link_row_node's
/// `trouble`).
#derive(Eq)
pub(all) enum RowNoteTone {
  NoteMuted
  NoteWarn
  NoteBad
}

///|
/// What a compound row ends in: `ChevronRight` it goes somewhere; `ChevronOut` it goes out of the app (an arrow out);
/// `ChevronFold` it folds open what follows it (down, up while `open` says it is open, read out so); `ChevronRoom` no
/// chevron, its room kept so a list's ends line up.
pub(all) enum RowChevron {
  ChevronRight
  ChevronOut
  ChevronFold(() -> Bool)
  ChevronRoom
}

///|
/// A compound row's parts as they are said (row_box_node's `body`): `narrow` whether the row is laid out narrow (a
/// card's row) or wide (a list's), `busy` whether it is busy (pressed none, a spinner at its end where no tail is said).
/// Each part said again replaces what was said of it before.
pub struct RowScope {
  narrow : Bool
  busy : () -> Bool
  priv mut lead : RowLead
  priv mut tone : RowTone
  priv mut title_cut : Bool
  priv mut title_after : ((@view.View) -> Unit)?
  priv mut note : () -> String
  priv mut note_tone : RowNoteTone
  priv mut note_cut : Bool
  priv mut trouble : () -> String
  priv mut value : () -> String
  priv mut value_tone : RowNoteTone
  priv mut value_dot : () -> Bool
  priv mut value_cut : Bool
  priv mut tail : ((@view.View) -> Unit)?
  priv mut tail_shown : () -> Bool
  priv mut chevron : RowChevron?
  priv mut below : ((@view.View) -> Unit)?
  priv mut below_open : () -> Double
}

///|
/// Whether the row has lines under its first (a note, what is wrong, what is below): its lead and its end then stand on
/// its first line, not across the row's middle.
pub fn RowScope::has_under(self : RowScope) -> Bool {
  (self.note)() != "" || (self.trouble)() != "" || self.below is Some(_)
}

///|
/// What the row is by, before its title, made by `make`: held by its first line where lines are under it as a line
/// icon is (`icon_line`: a status's dot, a mark), else as tall as it makes itself, across the row's middle (a person's
/// picture, a tile).
pub fn RowScope::lead(self : RowScope, make : (@view.View) -> Unit, icon_line? : Bool = true) -> Unit {
  self.lead = if icon_line { LeadLine(make) } else { LeadMade(make) }
}

///|
/// One of still.fail's line icons `name` before its title, in the muted ink, by its first line.
pub fn RowScope::icon(self : RowScope, name : String) -> Unit {
  self.lead = LeadIcon(name)
}

///|
/// How its title (the row's `label`) is drawn: `tone`; `cut` short on its line where it has less room; `after` it on
/// its line (a tag: whose it is, row_tag_node), the title cut short where the line has not the room for both.
pub fn RowScope::title(
  self : RowScope,
  tone? : RowTone = RowNormal,
  cut? : Bool = false,
  after? : (@view.View) -> Unit,
) -> Unit {
  self.tone = tone
  self.title_cut = cut
  self.title_after = after
}

///|
/// A note under its title, as it says it now (`NoteMuted`, `NoteWarn`: the note; `NoteBad`: what is wrong, in red on a
/// line of its own under the note), `cut` to one line (a muted or amber note's).
pub fn RowScope::note(self : RowScope, text : () -> String, tone? : RowNoteTone = NoteMuted, cut? : Bool = false) -> Unit {
  if tone is NoteBad {
    self.trouble = text
  } else {
    self.note = text
    self.note_tone = tone
    self.note_cut = cut
  }
}

///|
/// What it says at its end of its title's line, as it says it now, in `tone`, a red dot before it while `dot` says so,
/// `cut` short where it has less room.
pub fn RowScope::value(
  self : RowScope,
  text : () -> String,
  tone? : RowNoteTone = NoteMuted,
  dot? : () -> Bool = fn() { false },
  cut? : Bool = false,
) -> Unit {
  self.value = text
  self.value_tone = tone
  self.value_dot = dot
  self.value_cut = cut
}

///|
/// What `make` makes after what it says, before its chevron, on its first line, while `shown` says (a badge, a
/// spinner, a mark).
pub fn RowScope::tail(self : RowScope, make : (@view.View) -> Unit, shown? : () -> Bool = fn() { true }) -> Unit {
  self.tail = Some(make)
  self.tail_shown = shown
}

///|
/// What it ends in (RowChevron), `ChevronRight` where not said. A row with no chevron said ends in none.
pub fn RowScope::chevron(self : RowScope, kind? : RowChevron = ChevronRight) -> Unit {
  self.chevron = Some(kind)
}

///|
/// What `make` makes under its title and note while `open` says it is any of the way open (a room opening on it, its
/// row growing round it: a progress bar).
pub fn RowScope::below(self : RowScope, make : (@view.View) -> Unit, open? : () -> Double = fn() { 1.0 }) -> Unit {
  self.below = Some(make)
  self.below_open = open
}

///|
/// A row on a group's card (group_node) in `parent`, titled `label` (its words, and what it is read out as), its parts
/// said in `body` on its RowScope. Pressed, `press` is done (lit under the hand, rippling under a finger, its focus
/// ring as the keyboard comes to it); none of that where no `press` is given (a value said). While `busy` says so, it
/// is pressed none and lit none, a spinner at its end where no tail is said. Narrow (a card's row, a panel's) or wide (a
/// list's), as its page is laid out: link_row_node's look and room in every way.
#callsite(autofill(loc))
pub fn row_box_node(
  parent : @view.View,
  label : () -> String,
  press? : () -> Unit,
  busy? : () -> Bool,
  body : (RowScope) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let s : RowScope = {
    narrow: !(look_node(parent) is Wide),
    busy: busy.unwrap_or(fn() { false }),
    lead: NoLead,
    tone: RowNormal,
    title_cut: false,
    title_after: None,
    note: fn() { "" },
    note_tone: NoteMuted,
    note_cut: false,
    trouble: fn() { "" },
    value: fn() { "" },
    value_tone: NoteMuted,
    value_dot: fn() { false },
    value_cut: false,
    tail: None,
    tail_shown: fn() { true },
    chevron: None,
    below: None,
    below_open: fn() { 1.0 },
  }
  body(s)
  let (chevron, out, folds, chevron_room) = match s.chevron {
    None => (false, false, None, false)
    Some(ChevronRight) => (true, false, None, false)
    Some(ChevronOut) => (true, true, None, false)
    Some(ChevronFold(open)) => (true, false, Some(open), false)
    Some(ChevronRoom) => (false, false, None, true)
  }
  let value_tone = s.value_tone
  link_row_made(
    loc~,
    parent,
    label,
    fn(_) { press.unwrap_or(fn() {  }) },
    value=s.value,
    value_bad=fn() { value_tone is NoteBad },
    value_warn=fn() { value_tone is NoteWarn },
    value_dot=s.value_dot,
    note=s.note,
    trouble=s.trouble,
    strong=s.tone is RowStrong,
    danger=s.tone is RowDanger,
    lacks=s.note_tone is NoteWarn,
    lead=s.lead,
    goes=press is Some(_),
    chevron~,
    out~,
    acts=s.tone is RowAccent,
    below?=s.below,
    below_open=s.below_open,
    note_cut=s.note_cut,
    title_after?=s.title_after,
    folds?,
    tail?=s.tail,
    tail_shown=s.tail_shown,
    title_cut=s.title_cut,
    value_cut=s.value_cut,
    chevron_room~,
    busy?,
  )
}
