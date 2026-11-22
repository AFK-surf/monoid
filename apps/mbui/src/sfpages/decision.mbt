// What a post asks, under it in its chat on the desktop (still.fail web/src/Decisions.tsx MessageDecision,
// DecisionOptions; Chat.tsx AskDismiss; Decisions.css.ts decision, options, settledLine; Chat.css.ts askDismiss): who
// decides, then the options while it waits for the viewer (numbered, pressing one answers with it: decision.answer);
// once settled, how it went in one quiet line. A login card stays as its login goes, and goes as its options do once
// it ended, its line in its place; an agent's request about a vault
// item is answered on its own card. 忽略 lets go what no one has decided (decision.dismiss). Answered or let go, on
// screen or not, what is under the post changes from that moment (sfbase's list_turns.mbt Turns::in_turn, `start`):
// the options, 忽略 with them, fade out as their room closes, and the line saying how it went comes in their place, its
// room opening as theirs closes, its words fading in after them (sfbase's under_post.mbt).

///|
/// What was let go here (by its post: seq_key), gone at once: back if letting it go failed. Read by member, so that
/// a chat's row kept as its nodes is built again as its 忽略 is pressed, and only that row.
// kept across runs: put back by rows_reset
pub let dismissed : @signals.Keyed[String] = @signals.keyed()

///|
/// What is under a post (decision): 8 under its words, at the column's start.
// kept across runs: a value (no field of it changes)
let decision_box : @ui.Style = @ui.css("w=Full gap=S1_5 align=AStart")

///|
/// What comes and goes under a post with options (its options, 忽略, how it went): rooms with no gap of their own
/// between them, the one that needs one holding it (under_post's `lead`).
// kept across runs: a value (no field of it changes)
let decision_rooms : @ui.Style = @ui.css("w=Full align=AStart")

///|
/// The options: 8 over them.
// kept across runs: a value (no field of it changes)
let options_room : @ui.Style = @ui.css("w=Full pt=S0_5 align=AStart")

///|
/// How it was settled, who decides (settledLine): 12 on 18, the subtle ink.
// kept across runs: a value (no field of it changes)
let settled_line : @ui.TextStyle = @ui.text_style(size=settled_size, leading=settled_leading, color=Subtle)

///|
// kept across runs: a value (no field of it changes)
let settled_size : @ui.TextSize = Meta

///|
// kept across runs: a value (no field of it changes)
let settled_leading : @ui.Leading = L5

///|
/// How it went, in the options' place: 4 more over it than msg_main's gap, 8 in all under what is over it (a file's
/// card over it would have it hug the card's foot).
// kept across runs: a value (no field of it changes)
let outcome_room : @ui.Style = @ui.css("align=AStart pt=S1")

///|
/// 忽略 (askDismiss): 6 under the options, 12 on 18 in the subtle ink, the text's and underlined under the pointer.
// kept across runs: a value (no field of it changes)
let dismiss_room : @ui.Style = @ui.css("pt=S0_5")

///|
// kept across runs: a value (no field of it changes)
let dismiss_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Subtle, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let dismiss_words_hot : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Fg, wrap=false)

///|
/// An agent's request as its card in place of its post's words: a little under the post's head, as a card under a
/// post's words is, not on it as a line of words is (over @sf.ask_card_room or its room for a file).
// kept across runs: a value (no field of it changes)
let ask_card_under_head : @ui.Style = @ui.css("mt=S2")
