// What lies over a chat's pane on the desktop round its composer (still.fail web/src/Chat.tsx, ChatPage.css.ts dropHint):
// Escape in the open chat and drop-hint styles for chat_drop_node.

///|
/// Esc in the open chat, after the frame's (not taken by what the frame opened), at its moment: to ⌘F's bar (the
/// keyboard let go: `blur`), then what is picked, then the side panel's tabs all closed (keymap.ts panel.close), but
/// where a file in the viewer is in front (sfbase's viewer_tab.mbt). Whether it took it.
fn chat_escape(src : Source, blur : () -> Unit) -> Bool {
  guard app.nav.top() is Chat(r) else { return false }
  if find_chat() != "" {
    find_forget()
    blur()
  } else if @sfbase.pk.ts != "" {
    @sfbase.pick_clear()
  } else if side_now(src, r).0.length() > 0 && @sfbase.view_tab_file(side_now(src, r).1) is None {
    // (a file in the viewer in front stays: Escape is the whole window's preview's way out, not its tab's)
    side_change(src, r, "clear", None)
  } else {
    return false
  }
  true
}

///|
/// What is said in its middle: its mark over its words, 16 apart less what the mark grows by (a card's, twice).
// kept across runs: a value (no field of it changes)
let drop_hint_box : @ui.Style = @ui.css("w=Full h=Full gap=S4 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let drop_hint_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
/// A folder's mark there, as large as a card's sheet.
let drop_folder : Double = 30.0
