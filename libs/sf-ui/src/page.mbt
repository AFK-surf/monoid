// A page's parts (the library: a page's parts): its frame, sections, groups of rows, rows (to
// another page, a value, a switch), cards, notes, choices. A page is drawn into whatever box it is given and laid out
// by that box's width, once, by its frame (`page`): narrower than the web's narrow app (640), as the web's mobile pages
// are (web/src/mobile/parts.tsx TopBack, LargeTitle, SectionHeader, ListCard, ListRow): back over a large title, its
// rows on rounded cards; wider, as the web's desktop pages are (web/src/styles/pages.css.ts page, pageHead, list, card;
// ui.tsx Section): their head, a column 760 wide at most in the pane's middle, sections with their titles, lists and
// cards. The parts in it read that arrangement (`look`), never measure their own box: a section in a wide page's
// 380 column is a wide one still. Their sizes are the theme's (touch's, keyboard and mouse's). How they answer the
// hand is the input's: what lights under a mouse lights under a finger's press, and a finger's press ripples.

///|
/// How a page is laid out: as the web's narrow app is (`Narrow`), or its desktop pages (`Wide`).
#derive(Eq, Debug)
pub(all) enum Look {
  Narrow
  Wide
}

///|
/// The arrangements of the pages being drawn, the innermost last (a page's frame says its own as it draws what it
/// holds; a presenter its own).
// kept across runs: pushed and popped round what a page draws (empty between them)
let looks : Array[Look] = []

///|
/// The arrangement of the page being drawn (wide, outside any).
pub fn look() -> Look {
  match looks.last() {
    Some(l) => l
    None => Wide
  }
}

///|
/// `body` drawn in arrangement `l` (a page's frame's, a presenter's).
pub fn with_look(l : Look, body : () -> Unit) -> Unit {
  looks.push(l)
  body()
  looks.pop() |> ignore
}

///|
/// The arrangement of a page as wide as `w`.
pub fn look_for(w : Double) -> Look {
  if w < narrow_most {
    Narrow
  } else {
    Wide
  }
}

///|
/// A page that takes no frame's arrangement (a remote screen's, whole in what it is given), drawn as a page `w` wide is
/// arranged.
pub fn arranged(w : Double, wide~ : () -> Unit, narrow~ : () -> Unit) -> Unit {
  match look_for(w) {
    Wide => wide()
    Narrow => narrow()
  }
}

///|
/// The widest a page is laid out as the narrow app is (the web's: max-width 640, where its narrow app takes over).
pub let narrow_most : Double = 640.0

// ── the frame ───────────────────────────────────────────────────────────

///|
/// What the frame a page is shown in gives it (the stack's, the pane's): where back goes, said as its words (None:
/// nowhere, the page at the stack's root or beside a list that is the way back), how far down the page starts under
/// what stands over it (the status bar, a place's top bar), the room it keeps at its foot (the navigation bar, the
/// bottom bar), and whether the frame's own bar names the page already (a place's top page under Home's top bar: no
/// title of its own then). The page draws its bar and what it shows within these and works none of them out itself.
pub(all) struct PageFrame {
  back : String?
  top : Double
  foot : Double
  named : Bool
}

///|
/// What a page made once says of itself to the frame that names it (its bar: `named`), as it changes: its title, what
/// it is for said by a mark beside it ("" none; not its lead, what it holds says under its title). Compared by what it
/// says.
#derive(Eq)
pub(all) struct PageSaid {
  title : String
  about : String
  /// what back over it says where it is back to a page that names it otherwise ("": as the frame says it; page_node's
  /// `back_as`)
  back : String
}

///|
/// A frame that gives a page nothing: nowhere back, no room over or under it.
pub let no_frame : PageFrame = { back: None, top: 0.0, foot: 0.0, named: false }

///|
/// What a page says of itself to a bar of the frame's over it (a panel of its own on the tape: the bar a chat's page
/// has there): back (where it goes, said; what it does), its title, what it is for (`about`), what it is of (`small`),
/// whether it has a head of its own that says its name (`own_head`), what it does.
pub(all) struct PageBar {
  back : (String, () -> Unit)?
  title : String
  about : String
  small : String
  own_head : Bool
  actions : (() -> Unit)?
}

///|
/// What a place's top page under the frame's own bar does (its `named`), given to that bar as the page is drawn: the
/// bar holds it at its end and takes it from here (用量's days, 连接's filter).
// kept across runs: said by the page as it is drawn, taken by the bar over it
pub let named_actions : Ref[(() -> Unit)?] = Ref(None)

///|
/// A wide setting's title, using the shared row-title weight at the input's text size.
fn setting_title() -> @ui.TextStyle {
  theme().rows.title.then(row_title_weight)
}

///|
// kept across runs: a value (no field of it changes)
let rows_head_narrow : @ui.Style = @ui.css("w=Full px=S2 gap=S1_5").then(@ui.style(pb=room(title_card_narrow)))

///|
// kept across runs: a value (no field of it changes)
let rows_head_narrow_first : @ui.Style = rows_head_narrow.then(@ui.css("pt=S0_5"))

///|
// kept across runs: a value (no field of it changes)
let rows_head_wide : @ui.Style = @ui.css("w=Full px=S3 gap=S1_5").then(@ui.style(pb=room(title_card_wide)))

///|
// kept across runs: a value (no field of it changes)
let rows_head_wide_first : @ui.Style = rows_head_wide.then(@ui.css("pt=S3"))

///|
/// How far a card stands under the small title over it, whichever part says it (a section's title, a heading, a
/// list's head): wide, the web's sectionHead's 10 (parts.css.ts); narrow, SectionHeader's 6.
pub let title_card_wide : Double = 10.0

///|
pub let title_card_narrow : Double = 6.0

///|
/// How many narrow cards (a group's) what is drawn now stands in.
let in_card : Ref[Int] = Ref(0)

///|
// kept across runs: a value (no field of it changes)
let pg_said_row_square : @ui.Style = @ui.css("row w=Full gap=S3 align=ACenter").then(
  @ui.style(px=room(pg_room_in), py=list_words_room),
)

///|
/// Words on one line, cut short where their room is less.
// kept across runs: a value (no field of it changes)
let cut_words : @ui.TextStyle = @ui.text_style(w=Cut, wrap=false)

///|
/// How many rows' ends what is drawn now is at.
// kept across runs: counted up and down round what a row's end draws (0 between them)
let row_ends : Ref[Int] = Ref(0)

///|
/// Whether a button of words alone drawn now is at a row's end, on either width: its words on the line where
/// the row's value would end, its ground reaching past them by its own room, out to a list card's edge (the row's
/// words room and the card's pad, 16, a button's own), as one at a section's head reaches to the column's.
pub fn at_row_end() -> Bool {
  row_ends.val > 0
}

///|
/// A row's title, distinct from its note and value on every page width and input.
let row_title_weight : @ui.TextStyle = @ui.text_style(weight=Medium)

///|
/// A row's title said strongly (`strong`: who or what a row is, the account's, the workspace's).
// kept across runs: a value (no field of it changes)
let row_strong : @ui.TextStyle = @ui.text_style(weight=Bold)

///|
// kept across runs: a value (no field of it changes)
let figure_beside : @ui.Style = @ui.css("row w=Full gap=S6 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let figure_under : @ui.Style = @ui.css("w=Full gap=S4 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let figure_words_beside : @ui.Style = @ui.style(w=grow, gap=S2_5, align=AStart)

///|
// kept across runs: a value (no field of it changes)
let figure_words_under : @ui.Style = @ui.css("w=Full gap=S2_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let switch_row_note : @ui.TextStyle = meta.then(full_words).then(@ui.text_style(balance=true))

///|
/// A dial's figure (Dial): what is left large (`number` and its `unit`), `fill` of its ten cells lit (0–100) in its
/// `level`'s colour (green while plenty; amber, warn, red), its `label` and a quiet `note` under. `turns`: pressed, it
/// says itself the other way (a CPU's idle and busy: dials_node's `press`).
#derive(Eq)
pub(all) struct Dial {
  number : String
  unit : String
  fill : Int
  level : String
  label : String
  note : String
  // what `label` and `note` say where their line has not the room ("": nothing shorter)
  label_short : String
  note_short : String
  turns : Bool
}

///|
// kept across runs: a value (no field of it changes)
let dl_rows : @ui.Style = @ui.css("w=Full gap=S4")

///|
// kept across runs: a value (no field of it changes)
let dl_row_wide : @ui.Style = @ui.css("row gap=S9 align=AStart")

///|
/// The ways of a narrow row, the room of the line.
// kept across runs: a value (no field of it changes)
let dl_row_ways : @ui.Style = @ui.css("row w=Full")

///|
// kept across runs: a value (no field of it changes)
let dl_row_narrow : @ui.Style = @ui.css("row w=Full gap=S4 align=AStart")

///|
/// Between the dials' lines (quotaDials: 12).
let dl_lines : Double = 12.0

///|
// kept across runs: a value (no field of it changes)
let dl_dial_wide : @ui.Style = @ui.css("min_w=S24 gap=S0_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let dl_dial_wide_fixed : @ui.Style = @ui.css("w=S24 gap=S0_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let dl_dial_narrow : @ui.Style = @ui.style(w=grow, gap=S0_5, align=AStart)

///|
/// Its figure (quotaDialNumber: the display size, 600, the words' ink while there is plenty).
// kept across runs: a value (no field of it changes)
let dl_number : @ui.TextStyle = @ui.text_style(size=code_big_size, weight=Semibold, color=Fg, wrap=false)

///|
/// Its figure's size, which its unit (quotaDialUnit: the meta size, 500, muted) is a part of: the two are one line's
/// runs, so the unit stands on the figure's baseline.
let dl_number_size : Double = 28.0

///|
/// Its ten cells (quotaDialCells: 4 over and 6 under; a cell 8 by 14, 2 apart, round 2; narrow 6 wide), those not lit
/// in the line's colour: the least a mark with nothing in it is drawn, seen on the card they are on (the neutral
/// ground under words was not: 1.03 to 1 in the dark, 2026-10-26).
// kept across runs: a value (no field of it changes)
let dl_cells_wide : @ui.Style = @ui.css("row gap=SPx pt=S1 pb=S1_5")

///|
// kept across runs: a value (no field of it changes)
let dl_cells_narrow : @ui.Style = @ui.css("row gap=S0_5 pt=S1 pb=S1_5")

///|
// kept across runs: a value (no field of it changes)
let dl_cell_wide : @ui.Style = @ui.css("w=S2 h=S3_5 radius=Sm bg=Line mr=SPx")

///|
// kept across runs: a value (no field of it changes)
let dl_cell_narrow : @ui.Style = @ui.css("w=S1_5 h=S3_5 radius=Sm bg=Line")

///|
// kept across runs: a value (no field of it changes)
let dl_label : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let dl_reset : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
/// A dial's name and its note in lines of dials (dials_node's `lines`): as wide as its dial, going on under themselves
/// where they are longer, never cut.
// kept across runs: a value (no field of it changes)
let dl_label_lines : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Medium, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let dl_reset_lines : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let dl_detail : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

// ── styles: narrow (web/src/mobile/parts.css.ts) ────────────────────────

///|
// kept across runs: a value (no field of it changes)
let pg_title : @ui.TextStyle = large_title.then(@ui.text_style(w=Cut))

///|
/// What the page is for under its title (PageNote: 24 from the page's sides, in its room 12; 10 under it, the
/// secondary words).
// kept across runs: a value (no field of it changes)
pub let pg_lead_box : @ui.Style = @ui.css("w=Full px=S3 pb=S2_5")

///|
// kept across runs: a value (no field of it changes)
pub let pg_lead : @ui.TextStyle = secondary.then(full_words)

///|
let pg_foot : Double = 30.0

///|
// kept across runs: a value (no field of it changes)
let pg_heading : @ui.TextStyle = body.then(strong)

///|
/// A narrow page's room: what it holds 12 from its sides (ListCard's), its frame's to give (narrow_list), as a panel gives what it holds the room it leaves. What reaches the page's
/// sides on purpose goes out across it (page_bleed).
// kept across runs: a value (no field of it changes)
pub let pg_room : @ui.Style = @ui.style(w=Full, px=room(pg_room_in))

///|
let pg_room_in : Double = 12.0

///|
/// A narrow page's room in a panel of its own (the tape's, laid out Medium: in_pane): its cards cards of the panel's,
/// `panel_card_in` from its sides (the user, 2026-11-03: 面板里可以放卡片); on a phone's screen, pg_room.
pub fn pg_room_now() -> @ui.Style {
  if in_pane() {
    pg_room_pane
  } else {
    pg_room
  }
}

///|
// kept across runs: a value (no field of it changes)
let pg_room_pane : @ui.Style = @ui.style(w=Full, px=room(panel_card_in))

///|
/// A card on a narrow page (in its room): 10 under each.
// kept across runs: a value (no field of it changes)
pub let pg_card_room : @ui.Style = @ui.css("w=Full pb=S2_5")

///|
// kept across runs: a value (no field of it changes)
pub let pg_note_box : @ui.Style = @ui.css("w=Full px=S3 pt=S2 pb=S1")

///|
// kept across runs: a value (no field of it changes)
pub let pg_note : @ui.TextStyle = secondary.then(full_words)

///|
// kept across runs: a value (no field of it changes)
pub let pg_note_bad : @ui.TextStyle = pg_note.then(bad)

///|
/// A row of a card (ListRow): its words a row's room in all round (list_words_room: 16 from the card's edge, as a
/// menu's), what it holds 12 apart, its ground concentric with the card's; lit under the pointer, or a finger's press.
// kept across runs: a value (no field of it changes)
pub let pg_row : @ui.Style = @ui.css("row w=Full gap=S3 radius=Inner align=ACenter hovered{bg=Hover}").then(
  @ui.style(p=list_words_room),
)

///|
// kept across runs: a value (no field of it changes)
pub let pg_said_row : @ui.Style = @ui.css("row w=Full gap=S3 radius=Inner align=ACenter").then(@ui.style(p=list_words_room))

///|
// kept across runs: a value (no field of it changes)
pub let pg_row_words : @ui.Style = @ui.style(w=grow)

///|
// kept across runs: a value (no field of it changes)
pub let pg_row_title : @ui.TextStyle = body.then(row_title_weight).then(one_line).then(full_words)

///|
/// A row's title where what it says follows it in the line (narrow, over its note).
// kept across runs: a value (no field of it changes)
let pg_row_title_in : @ui.TextStyle = body.then(row_title_weight).then(one_line)

///|
// kept across runs: a value (no field of it changes)
let pg_switch_title : @ui.TextStyle = body.then(row_title_weight).then(full_words)

///|
// kept across runs: a value (no field of it changes)
pub let pg_value : @ui.TextStyle = value

///|
pub let pg_chevron : Double = 14.0

///|
/// The words under a row's title (the secondary's, in lines).
// kept across runs: a value (no field of it changes)
pub let pg_link_note : @ui.TextStyle = secondary.then(full_words)

// ── styles: wide (web/src/styles/pages.css.ts) ──────────────────────────

///|
pub let wide_heading : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg, w=Full)

///|
/// What a wide row says at its end (the meta's 12, muted, on one line).
// kept across runs: a value (no field of it changes)
pub let wide_value : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
/// Its title (22 on 32, 600: the web's 34 off the line scale, its nearest).
// kept across runs: a value (no field of it changes)
let desk_title : @ui.TextStyle = @ui.text_style(size=Heading, leading=L8, weight=Semibold, color=Fg, wrap=false, w=Cut)

///|
let desk_back_icon : Double = 14.0

///|
// kept across runs: a value (no field of it changes)
let desk_back_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let desk_back_lit : @ui.TextStyle = desk_back_words.then(@ui.text_style(color=Fg))

///|
/// A block's lane across the pane, its column in the middle: 792 at most, 24 from the pane's sides at least (its blocks'
/// own 16 inside it: the 760 column).
// kept across runs: a value (no field of it changes)
pub let desk_lane : @ui.Style = @ui.css("w=Full px=S6 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
pub let desk_lane_column : @ui.Style = @ui.style(w=Full, max_w=Fixed(desk_lane_most))

///|
pub let desk_lane_most : Double = 792.0

///|
pub let desk_lane_in : Double = 24.0

///|
let desk_foot_h : Double = 80.0

///|
/// A page's head of its own (an account's): where a title's head would stand.
// kept across runs: a value (no field of it changes)
pub let desk_own_head : @ui.Style = @ui.css("w=Full px=S4 pt=S10")

///|
pub let desk_column_most : Double = 760.0

///|
pub let desk_column_in : Double = 16.0

///|
let desk_hint_most : Double = 624.0

///|
// kept across runs: a value (no field of it changes)
pub let desk_hint_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
/// A card of words (pages.css.ts card: 20 in, its rows 14 apart, the settings' corner on the card's ground; a row of
/// it: cardRow, 12 apart in its middle; its words cardRowText, 2 apart, the ui's 13 on 20, the title in 600).
// kept across runs: a value (no field of it changes)
pub let card_surface : @ui.Style = @ui.css("w=Full gap=S3_5 radius=Xl3 bg=Card").then(@ui.style(p=room(card_pad)))

///|
// kept across runs: a value (no field of it changes)
pub let desk_card : @ui.Style = card_surface

///|
// kept across runs: a value (no field of it changes)
pub let card_row : @ui.Style = @ui.css("row w=Full gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
pub let card_text : @ui.Style = @ui.style(w=grow, gap=S0_5)

///|
// kept across runs: a value (no field of it changes)
pub let desk_card_text : @ui.Style = card_text

///|
// kept across runs: a value (no field of it changes)
pub let card_strong : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
pub let desk_strong : @ui.TextStyle = card_strong

///|
// kept across runs: a value (no field of it changes)
pub let card_body : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
pub let desk_words : @ui.TextStyle = card_body

///|
// kept across runs: a value (no field of it changes)
pub let card_muted : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
pub let desk_muted : @ui.TextStyle = card_muted

///|
/// A list on a wide page: a list card (the narrow page's ListCard, at the column's edges: list_pad in, its rows 2
/// apart), each row 52 high at least, 10 by 10 in, its parts 12 apart, its corner concentric with the card's; one that
/// opens on the pointer's ground; its title in 500, what is under it the meta's 12 muted, red where it is wrong; a chevron 16.
/// How high it is at least goes by the native input (the theme's items'): 36 with keyboard and mouse, a finger's 44 with
/// touch, no taller than a press needs (rule 2; the user, 2026-10-26: 「浪费空间」; 2026-10-27: 大屏最小 36).
pub fn desk_row_least() -> Double {
  theme().items.least
}

///|
pub let desk_chevron : Double = 16.0

///|
pub let desk_mark : Double = 14.0

///|
/// A card of a panel's, on its ground as its other cards are (the ink at 5%: info_list's, a choice's): a card's own ground is
/// the panel's, unseen on it.
// kept across runs: a value (no field of it changes)
let panel_card_group : @ui.Style = panel_card_ground.then(@ui.style(radius=rounded(card_corner)))

///|
/// A card of a panel's, its ground alone (panel_card_group's, its corners left to what draws it: a card's piece,
/// card_piece_node).
// kept across runs: a value (no field of it changes)
let panel_card_ground : @ui.Style = @ui.css("w=Full bg=A(Fg,O5) clip")

///|
// kept across runs: a value (no field of it changes)
let panel_card_rows : @ui.Style = @ui.style(p=room(corner_inset))

///|
pub let desk_list : @ui.Style = @ui.style(w=Full, p=list_room, gap=S0_5, radius=list_card_radius, bg=Card)

///|
/// The same in a panel of its own (in_pane): a card of the panel's, its words 24 in from its edges, its rows' grounds
/// the ladder's inset in (wide_list_link_pane: reaching past their rows to there), a card's corner, its rows as close
/// as a list card's; what stands at a row's end in its corners stands outside them, as far in as its words (the user,
/// 2026-11-03: 就按第 3 版).
pub fn desk_list_card() -> @ui.Style {
  if in_pane() {
    desk_list_pane
  } else {
    desk_list
  }
}

///|
// kept across runs: a value (no field of it changes)
let desk_list_pane : @ui.Style = @ui.style(
  w=Full,
  px=room(corner_inset),
  py=room(card_pad - wide_row_pad),
  gap=S0_5,
  radius=card_radius,
  bg=Card,
)

///|
/// How far a wide list's row's words stand under its top and over its foot (wide_list_row_ground's and
/// wide_in_list's py=S2_5).
let wide_row_pad : Double = 10.0

///|
pub let desk_list_out : Double = 12.0

///|
/// How far in from its end a row on a panel's card has what it holds at its end (a model's picker, 更新): its words'
/// room, or as far as holds it out of the card's corner where that is more (the card's 26 round, its words 24 in: 2
/// more; the user's 第 3 版, 2026-11-03: a control stays out of its card's corner, its row's spacing as it was).
pub let card_control_end : Double = text_in + dmax(0.0, card_corner - panel_words)

///|
/// Whether the card the rows now made stand on holds them the ladder's inset from its top and foot, each its own ground
/// (a settings page's list card: rows_held).
// kept across runs: said around a card's rows as they are made, put back after
let rows_held_now : Ref[Bool] = Ref(false)

///|
/// `body`'s rows made on a card that holds them the ladder's inset from its top and foot (rows_held_now).
/// They are on a card (in_card) as a group's are: their words a row's padding in from their grounds, which round in
/// the card's corners (2026-11-06: a settings card's link rows 4 nearer its edge than its other rows' words, their
/// grounds square).
pub fn rows_held(body : () -> Unit) -> Unit {
  let was = rows_held_now.val
  rows_held_now.val = true
  in_card.val += 1
  body()
  in_card.val -= 1
  rows_held_now.val = was
}

///|
// kept across runs: a value (no field of it changes)
pub let desk_list_text : @ui.Style = @ui.style(w=grow, gap=S0_5)

///|
// kept across runs: a value (no field of it changes)
pub let desk_list_title : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, wrap=false).then(row_title_weight)

///|
// kept across runs: a value (no field of it changes)
pub let wide_list_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
pub let list_note : @ui.TextStyle = wide_list_note

///|
// kept across runs: a value (no field of it changes)
pub let list_note_bad : @ui.TextStyle = list_note.then(@ui.text_style(color=Danger))

///|
// kept across runs: a value (no field of it changes)
pub let desk_note_bad : @ui.TextStyle = list_note_bad

///|
// kept across runs: a value (no field of it changes)
let wide_block : @ui.Style = @ui.css("w=Full gap=S3")

///|
/// A heading's words that do something: room round them for a finger (4), the link's ink.
// kept across runs: a value (no field of it changes)
let pg_action : @ui.Style = @ui.css("p=S1 radius=Lg")

///|
// kept across runs: a value (no field of it changes)
let pg_action_words : @ui.TextStyle = @ui.text_style(size=Body, color=Link, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pg_action_bad : @ui.TextStyle = pg_action_words.then(bad)

///|
/// A finger's target (44 at least) and its mark in it.
let touch_target : Double = 44.0

///|
let touch_glyph : Double = 20.0

///|
/// A page's own head: wide, its mark 32 on its name's line, 12 from its words, the lines under them from the mark's
/// start, 28 over what follows; narrow, its mark 40, 12 from its words, 16 over what follows, its words from the top.
// kept across runs: a value (no field of it changes)
let head_wide : @ui.Style = @ui.css("w=Full pb=S7 gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let head_narrow : @ui.Style = @ui.css("w=Full px=S1 gap=S1_5")

///|
/// Narrow, its mark, its name and what it does: a line across its middle.
// kept across runs: a value (no field of it changes)
let head_top_narrow : @ui.Style = @ui.css("row w=Full gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let head_narrow_foot : @ui.Style = @ui.css("pb=S4")

///|
// kept across runs: a value (no field of it changes)
let head_mark_wide : @ui.Style = @ui.css("w=S8 h=S8 radius=Md bg=Neutral align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let head_mark_narrow : @ui.Style = @ui.css("w=S10 h=S10 radius=Lg bg=Neutral align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let head_name_line : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let head_name_wide : @ui.TextStyle = @ui.text_style(size=Heading, weight=Semibold, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let head_name_lines : @ui.TextStyle = @ui.text_style(size=Heading, weight=Bold, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let head_line : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, w=Full)

///|
/// How it stands, under its lines (8 apart).
// kept across runs: a value (no field of it changes)
let head_state : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let head_actions : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
/// Its name's line: its name, what it does at its end (narrow: from the top, the large title in as many lines as it
/// takes; wide: across their middle), 12 apart.
// kept across runs: a value (no field of it changes)
let head_name_row : @ui.Style = @ui.css("row w=Full gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)

///|
/// Its name and what follows it, wide, taking what the line leaves what it does.
// kept across runs: a value (no field of it changes)
let head_name_grow : @ui.Style = @ui.style(w=grow)

///|
// kept across runs: a value (no field of it changes)
let head_warn_red : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Danger, w=Full)

///|
// kept across runs: a value (no field of it changes)
let head_warn_amber : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=WarnInk, w=Full)

///|
// kept across runs: a value (no field of it changes)
let pg_loose : @ui.Style = @ui.css("w=Full px=S3 pb=S2_5 gap=S3")

///|
/// Its mark's box's side (what draws in it is given it): 32 wide, 40 narrow.
let head_mark_wide_side : Double = 32.0

///|
let head_mark_narrow_side : Double = 40.0

///|
/// How far in from its end a row on a list card has what it holds at its end (a
/// switch, a choice): its words' room, or as far as holds it out of the card's corner where that is more (a list
/// card's 24 round, its rows 6 in: 18; the user's 第 3 版, 2026-11-03: a control stays out of its card's corner).
pub let list_control_end : Double = dmax(text_in, list_card_corner - list_pad)

///|
// kept across runs: a value (no field of it changes)
let wide_apart : @ui.Style = @ui.css("w=Full mb=S7")

///|
/// A head's first line: its dot, its tags (narrow), what it is, 6 apart.
// kept across runs: a value (no field of it changes)
let head_line_row : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let head_line_narrow : @ui.TextStyle = pg_lead

///|
/// What stands over a group's rows and tells of them (rows_head's, as nodes), in `parent`: in as far as their words
/// (narrow, those on its card; wide, a wide list's rows'), 6 between its lines, the rows as far under it as under any
/// small title over a card; `first`, its own room over it (narrow 2, wide 12). `body` makes what it holds.
#callsite(autofill(loc))
pub fn rows_head_node(parent : @view.View, body : (@view.View) -> Unit, first? : Bool = false, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(h) {
    style_node(h, fn() {
      match look_node(h) {
        Narrow => if first { rows_head_narrow_first } else { rows_head_narrow }
        Wide => if first { rows_head_wide_first } else { rows_head_wide }
      }
    })
    body(h)
  })
  |> ignore
}

///|
/// A page made once laid out by the width of the box it is given (`width`), as page_node lays one out: `wide` makes it
/// where that is wide, `narrow` where narrow, each lent its arrangement (look_node), made again only as the arrangement
/// changes. For a page whose two arrangements are not a page_node's (the files' page: Finder's window wide, a folder
/// in its own frame narrow; a station's screen on a simulator, what debugs its app beside the device or under it). As
/// tall as what holds it gives it, never what it holds props up (a stage laid out by the room it is given).
#callsite(autofill(loc))
pub fn by_look_node(
  parent : @view.View,
  width : () -> Double,
  wide : (@view.View) -> Unit,
  narrow : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(b) {
    b.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
    b.pick(fn() { look_for(width()) }, at_once=true, fn(p, look) {
      p.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      look_lent(p, look)
      match look {
        Wide => wide(p)
        Narrow => narrow(p)
      }
    })
  })
  |> ignore
}

///|
/// What a row of a page's list keeps under it, as group_rows_node lays its rows apart (a wide list's 2: desk_list_gap;
/// on a narrow card none, its rows meeting), laid on `v` (the row's room): its padding under it as the page is laid out.
#callsite(autofill(loc))
pub fn row_apart_node(v : @view.View, loc~ : SourceLoc) -> Unit {
  v.padding(
    loc~,
    By(fn() {
      match look_node(v) {
        Wide => (0.0, 0.0, 0.0, desk_list_gap)
        Narrow => (0.0, 0.0, 0.0, 0.0)
      }
    }),
  )
  |> ignore
}
