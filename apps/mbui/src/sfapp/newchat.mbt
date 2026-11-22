// A new chat in the Small stack: the pages'
// (sfpages new_chat.mbt), risen from the bottom over the page under it (380 ms, (.2, .8, .2, 1)) under its bar (取消,
// 新对话), over the navigation bar. The first message makes the chat and the page becomes it in place
// (@ui.Nav::become), its composer and focus kept; its scene leaves over the chat (new_chat_leaving).

///|
/// A new chat's page, rising over the page on top.
fn new_chat() -> Unit {
  fresh_reset()
  lower_sheet()
  app.menu = false
  open_page(NewChat)
}
