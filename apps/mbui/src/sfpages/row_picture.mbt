// Who is in a chat, small at its row's second line's end (still.fail web/src/RowPicture.tsx RowAside, Face;
// RowPicture.css.ts), as the chats' lists draw it with a finger and with a mouse alike: its agents' marks (a maker's
// once) and its people's faces, those that lead first.

///|
/// Whether a row shows who is in it at its end (row_aside: its agents, the people where they are not all the viewer).
pub fn row_aside_shows(item : ChatItem, lead : String) -> Bool {
  @sfbase.row_agent_groups(item).length() > 0 || row_with_people(item, lead)
}

///|
fn row_with_people(item : ChatItem, lead : String) -> Bool {
  let people = item.people
  people.length() > 0 && (lead == "people" || people.iter().any(fn(p) { !p.mine }))
}

///|
/// Twice the distance from the end of the aside to the centre of its last visible part. The extra pixel after a
/// creator's face belongs outside the face, and a +N takes the width of its words rather than that of an icon.
fn row_aside_end_w_at(item : ChatItem, lead : String, more_w : (Int) -> Double) -> Double {
  let groups = @sfbase.row_agent_groups(item)
  let faces = row_with_people(item, lead)
  if faces && (lead != "people" || groups.is_empty()) {
    let count = item.people.length()
    if count > aside_most {
      more_w(count - aside_most)
    } else {
      let last = item.people[count - 1]
      @sf.theme().chat_list.face_d + (if count > 1 && last.id == item.creator { 2.0 * face_gap_w } else { 0.0 })
    }
  } else if groups.length() > aside_most {
    more_w(groups.length() - aside_most)
  } else if groups.is_empty() {
    @sf.theme().chat_list.face_d
  } else {
    aside_agent_w
  }
}

///|
/// A face at a row's end (its size the theme's chats' list): 3 over the one before it (RowPicture.css.ts aside
/// overlap(3)); its ground a pixel round it, who started it ringed 2 out; three shown at most.
let face_over : Double = 3.0

///|
/// What stands at a row's end, measured as its styles lay it (aside_row, aside_agents, aside_agent, aside_faces,
/// face_gap): 2 in, an agent 16 and 4 apart, the agents and the people 6 apart, a pixel after who started it.
let aside_in : Double = 2.0

///|
let aside_agent_w : Double = 16.0

///|
let aside_agent_gap : Double = 4.0

///|
let aside_parts_gap : Double = 6.0

///|
let face_gap_w : Double = 1.0

///|
let face_ring_in : Double = 1.0

///|
let face_ring_out : Double = 2.0

///|
let aside_most : Int = 3

///|
/// What stands at a row's second line's end: the agents and the people 6 apart, each 2 in.
// kept across runs: a value (no field of it changes)
let aside_row : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let aside_agents : @ui.Style = @ui.css("row pl=S0_5 gap=S1 align=ACenter")

///|
/// An agent's mark in a column 16 wide and high.
// kept across runs: a value (no field of it changes)
let aside_agent : @ui.Style = @ui.css("w=S4 h=S4 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let aside_faces : @ui.Style = @ui.css("row pl=S0_5 align=ACenter")

///|
/// How many more than are shown: 12, muted.
// kept across runs: a value (no field of it changes)
let aside_more : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

