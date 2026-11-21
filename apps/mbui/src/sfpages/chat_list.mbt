// A chat's messages on the desktop (still.fail web/src/Chat.tsx ChatShown, ChatRows, useMessageList, ToLatest, ToAsk;
// Chat.css.ts chatMessages, chatToBottom, chatToAsk; styles/session.css.ts chatList): its rows in the column 760 wide
// at most in the pane's middle, running on under the composer; following its end, the pages before and after brought
// in near its edges, put in place once (the unread line, where it was left, where the core opened it), what is read and
// where the reader is told the core: all of that as the phone's list has it too (sfbase's chat_list.mbt: list_frame
// before the rows are drawn, list_after once they are). What comes in does so at once (list_turns.mbt): a message
// eases in, an agent's comes out of its activity's picture (emit.mbt), the viewer's own flies in from the composer the
// frame it is sent (flight.mbt), existing messages show at once. Over it, the way to its end
// (⌘↓) and to what waits to be decided.

///|
/// Chat `r`'s list's key (the composer sends it to its end: the same as the phone's).
pub fn list_key(r : ChatRef) -> String {
  "chat/" + r.station + "/" + r.session
}

///|
/// What waits to be decided in the chat (the core's `asks`, their posts' seqs): none in one archived or not made yet.
fn asks_of(v : ChatView) -> Array[Double] {
  if v.archived || v.thread is None {
    []
  } else {
    v.asks
  }
}

///|
/// Which of each chat's asks the bell goes to next (by the chat's key).
pub let ask_turns : Map[String, Int] = Map([])

///|
/// What ⌘F last asked the window moved about (`chat.around`), once (-1 none).
let find_around : Ref[Double] = Ref(-1.0)

///|
/// The list's ⌘F goes along: the messages showing, the list to a message with the words marked
/// in it, its marks let go: the chat's page's list's (chat_nodes_find_list).
pub fn chat_find_list(r : ChatRef) -> FindList {
  chat_nodes_find_list(r)
}

///|
/// ⌘F let go in the chat it is open in: the words it marked, where it was going, its bar.
pub fn find_forget() -> Unit {
  let k = find_chat()
  match readings.get(k) {
    Some(rd) => {
      rd.found_at = ""
      rd.found_words = []
    }
    None => ()
  }
  go_tos.remove(k)
  go_to_words.remove(k)
  find_around.val = -1.0
  find_close()
}

///|
/// Notices over each chat's composer as last seen on the legacy list, and when that set last changed (`float_room`).
let notice_signs : Map[String, String] = Map([])

///|
let notice_at : Map[String, Double] = Map([])

///|
let notice_rooms : Map[String, Double] = Map([])

///|
/// What the list keeps of its own, let go (the package's reset).
fn list_reset() -> Unit {
  notice_signs.clear()
  notice_at.clear()
  notice_rooms.clear()
  lists_set_off.clear()
  lists_held_w.clear()
  flashing_now.val = ("", 0.0)
  ask_turns.clear()
  find_around.val = -1.0
  outline_presets.clear()
  find_goes.clear()
  outline_hover_reset()
}

///|
/// How far the rows stand in from the pane's sides: the column 760 wide at most in its middle, 40 in at least
/// .
fn native_row_inset() -> Double {
  @sf.pane_foot_rest(holds=@sf.theme().round.side) + @sf.composer_pad + 8.0
}

///|
/// What each chat list's rows were last held for on a page's way (laid_at_w): their `laid`, that way's id, the width
/// it was laid out at, and whether it was held still as it was last built.
let lists_held_w : Map[String, (String, String, Double, Bool)] = Map([])

///|
/// Each chat list on a page's way, or the moment it found it over: the way ("" over), how wide its pane was as it set
/// off, when it is there, and the moment last asked at (laid_w).
let lists_set_off : Map[String, (String, Double, Double, Double)] = Map([])

///|
fn row_side(w : Double) -> Double {
  // Inline avatars need no hanging-avatar gutter. Narrow beside the system's bars (an iPhone Duo's), the rows as wide
  // as the composer words under them, including its inner text padding; elsewhere 16 in.
  if w <= chat_narrow_w {
    return if @sf.native_on() { native_row_inset() } else { row_side_narrow }
  }
  // (beside the system's bars, an iPhone Duo's: the rows across the pane, dense_row_side in)
  if @sf.native_on() {
    return dense_row_side
  }
  dmax(row_side_least, (w - chat_column_w) / 2.0)
}

///|
/// How far in from a chat's column's left its rows' words start at width `w` (row_side): what the shell moves the
/// column by while it is laid out at another width than it is drawn (sfbase's chat_page_made, `narrower`).
pub fn chat_row_side(w : Double) -> Double {
  row_side(w)
}

///|
/// (its pictures out in that room, 29 before the words, about as far from the card's edge as the chat's title: the
/// user, 2026-10-28, 头像都贴边了)
let dense_row_side : Double = 48.0

///|
/// The column's width at most, and how far in its sides stand at least.
let chat_column_w : Double = 760.0

///|
let row_side_least : Double = 40.0

///|
/// A row's height as guessed before it is laid out.
let chat_row_est : Double = 90.0

///|
/// The rows 28 apart, one sent soon after the one before 4 under it.
let list_gap : Double = 28.0

///|
/// The widest a list is laid out narrow, and then 20 between its messages (the web's
/// mobile --list-gap) and 16 in from its sides.
pub let chat_narrow_w : Double = 700.0

///|
let list_gap_narrow : Double = 20.0

///|
let row_side_narrow : Double = 16.0

///|
let joined_gap : Double = 4.0

///|
/// The list's room over its first row (under the chat's bar: 45, and 24), under its last (24, over the composer's
/// room), and where the unread line goes under its top (about four lines of what came before it in view: 4 × 23).
let list_top : Double = 69.0

///|
/// The room under the chat's bar over the list's first row (list_top's 24): room, the bar's drawn over none of it.
let list_room : Double = list_top - bar_foot

///|
let list_foot : Double = 24.0

///|
pub let bar_foot : Double = 45.0

///|
let unread_lead : Double = 92.0

///|
/// The round buttons over the list (chatToBottom): 32 across, 6 in from the send button's side, 12 over the composer's
/// room; the bell 8 over the way to the end when both show; their icon 16; how long they come and go.
let float_side : Double = 32.0

///|
let float_in : Double = 6.0

///|
let float_lift : Double = 12.0

///|
let float_above : Double = 48.0

///|
let float_ms : Double = 160.0

///|
/// The ring's room round a picture in it (24 round 18).
let ring_room : Double = 3.0

///|
/// The message gone to flashing in the list drawn now and how far its flash is (its ts, 0 to 1): its row's band
/// (row_box), or the passage a quote quoted behind its words (passage_lit).
pub let flashing_now : Ref[(String, Double)] = Ref(("", 0.0))

///|
/// The composer's width on a chat's page (dock.css.ts, the chat's: the column and the capsule's curve each side, 760
/// and 22 each side at most, 12 clear of the pane's edges).
pub fn composer_width(pane : Double) -> Double {
  if @sf.native_on() {
    return pane - 2.0 * composer_side()
  }
  dmin(pane - 2.0 * composer_side(), composer_most)
}

///|
/// The composer's widest, its clearance from the pane's sides.
let composer_most : Double = 804.0

///|
/// (In a panel of its own, as far in as makes its box concentric with the panel's foot corners its round controls can
/// follow in turn in its own: @sf.pane_foot_in.)
pub fn composer_side() -> Double {
  @sf.pane_foot_in(holds=@sf.theme().round.side)
}

