// A table's copy key (2026-10-26 用户：「支持一下表格导出，可以复制 markdown，csv，或者复制图片」): an icon button hung
// past the table's right edge, in line with its head's row, whatever the input, taking no room and over nothing of it
// (「应该悬挂在右边，而不是占着实际位置」「不要压在表格上」: a row of its own over the table was 「太拉」, and over its corner,
// as a code block's key is, it lies over the head's words): in what scrolls, after the table, so beside it where the
// message has room, past its end, scrolled to, where it is as wide as the message. Its menu copies the table as
// Markdown or as CSV (as the core wrote them: markdown.ts tableMarkdown, tableCsv) or as a picture of it (its shot: the
// table whole, as wide as its columns, on the page's ground; on a phone saved to its photo album: picture_out_way).
// Shown as the table is pointed at (2026-10-30 用户：「表格右边的按钮改成 hover 表格那一行才显示」), its menu open or
// it saying it copied, always to a finger: what a pointer over a thing shows (@sf.pointed_or_finger); its room kept
// either way, so nothing moves as it comes and goes.
//
// Hung to the table's right, over nothing (the user, 2026-10-26: 「不要压在表格上」); a row over it and a button
// inside its corner were tried and refused.

///|
/// The key's size (icon_button's), and how far it is from the table and from what follows it (a press's room round it).
let table_key_size : Double = 32.0

///|
let table_key_gap : Double = @ui.Space::S1_5.px()

///|
/// The room the key takes past the table: its gap either side of it.
let table_key_room : Double = table_key_gap + table_key_size + table_key_gap

///|
let table_shot_in : Double = @ui.Space::S4.px()

///|
/// A table's picture's pixels a point at the least (the screen's where it has more): as sharp pasted from a screen of
/// one as from a Mac's.
let table_shot_scale : Double = 2.0
