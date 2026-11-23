// A card that asks (sf/align.mbt, 要人拍板的卡片): its title the question, the one line the answer turns on, its
// buttons in its foot corners; one alone in the middle of what it is over (a player's), all of it in its middle and its
// buttons across its foot. An agent's ask in a chat (settings' vault_ask, phone_ask) and
// what a player asks over its picture (player.mbt: 无法播放, 播放结束) alike; on the night (on_night: a player's, a
// stage's) in the night's words and buttons.
//
// Answered stays where it is: the list changes height only for what is new (the user, 2026-10-29: 「有个勾不就行了吗
// ？为啥非要冒一行字？」).

///|
/// What is asked, over the answer: its lines 2 apart.
// kept across runs: a value (no field of it changes)
pub let ask_what : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
/// Its title, 14 on 20 (the account after it quieter, its own run).
// kept across runs: a value (no field of it changes)
pub let ask_title : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, w=Full)

///|
/// A line of what is out of the ordinary, or where there is no answer to give here: 12 and quiet.
// kept across runs: a value (no field of it changes)
pub let ask_note : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4_75, color=Muted, w=Full)

///|
/// The answer's buttons, 10 apart (pages.css.ts cardFoot).
// kept across runs: a value (no field of it changes)
pub let ask_foot : @ui.Style = @ui.css("row gap=S2_5 align=ACenter")

///|
/// Between the foot's lines, where its buttons go on to a second: 8, more where a press's room is taller than a button
/// and the one under it (a finger's 44 round a button of 34).
pub fn ask_foot_lines() -> Double {
  8.0
}

///|
// kept across runs: a value (no field of it changes)
let ask_history_line : @ui.Style = @ui.css("row gap=S1 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let ask_history_mark : @ui.Style = @ui.css("justify=JCenter")
