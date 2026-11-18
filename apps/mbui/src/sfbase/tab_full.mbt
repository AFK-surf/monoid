// Where a tab beside a chat is shown: in the chat's side panel, or over the whole window (全屏), one way for every kind
// (the user, 2026-11-17: 「这些东西的展示都做成一样的交互，大屏默认在右边展示，cmd+点击全屏，在右边也提供全屏按钮，用同一
// 套逻辑，后续方便做成独立窗口」). Over the whole window it is the same tab drawn by the same nodes as in the panel
// (sfdesk's tab_full_layer_node), what it holds (a file's viewer, a service's page and its native view, kept past its
// node) the tab's, so it moves between the two as it is; the panel shows nothing of it meanwhile. Asked by a press with
// the command key held (full_held), the panel's 全屏, or what opens a page saying so (open_page_full).

///|
/// A tab of a chat's side panel shown over the whole window: the chat and the tab.
#derive(Eq)
pub(all) struct TabFull {
  chat : ChatRef
  tab : String
}

///|
/// The tab over the whole window, if one is.
// kept across runs: put back by pages.mbt's reset
pub let tab_full : @signals.Signal[TabFull?] = @signals.signal(None)

///|
/// Whether the command key of the system the person types with is held now (@ui.keys_system: ⌘ on Apple's, Ctrl
/// elsewhere; a browser's the system under it, so ⌘ in one on a Mac, where Ctrl and a press is the context menu): a press
/// with it asks for what it opens over the whole window. Read here once, never by a page.
pub fn full_held() -> Bool {
  let primary = match @ui.keys_system() {
    0 | 1 => @ui.mod_cmd
    _ => @ui.mod_ctrl
  }
  (@ui.mods_held() & primary) != 0
}

///|
/// Tab `tab` of chat `r`'s side panel over the whole window.
pub fn tab_full_open(r : ChatRef, tab : String) -> Unit {
  // (in a window of its own: that window to the front instead, window.mbt's tab_window_front)
  if tab_window_front(r, tab) is Some(_) {
    return
  }
  tab_viewer_moves(r.station + ":" + r.session, tab)
  tab_full.set(Some({ chat: r, tab }))
}

///|
/// The tab over the whole window back in its chat's side panel.
pub fn tab_full_close() -> Unit {
  match tab_full.untracked() {
    Some(f) => {
      tab_viewer_moves(f.chat.station + ":" + f.chat.session, f.tab)
      tab_full.set(None)
    }
    None => ()
  }
}

///|
/// Whether tab `tab` of the chat on `station` kept by session `session` is over the whole window now, followed.
pub fn tab_full_is(station : String, session : String, tab : String) -> Bool {
  match tab_full.get() {
    Some(f) => f.tab == tab && f.chat.station == station && f.chat.session == session
    None => false
  }
}

///|
/// The page asked to open over the whole window where it lands beside a chat (a web service, a visualization: sfdesk's
/// beside_follow), taken as its tab is put there.
// kept across runs: put back by pages.mbt's reset
let full_page : Ref[Page?] = Ref(None)

///|
/// Page `p` opened over the whole window where the layout puts it beside a chat as a tab, else where the layout has it.
pub fn open_page_full(p : Page) -> Unit {
  full_page.val = Some(p)
  open_page(p)
}

///|
/// Whether page `p`, put beside a chat as a tab now, was asked over the whole window (open_page_full, or opened with the
/// command key held): taken, once.
pub fn page_full_taken(p : Page) -> Bool {
  match full_page.val {
    Some(q) if q == p => {
      full_page.val = None
      true
    }
    _ => false
  }
}

///|
/// What open_page notes of page `p` as it is opened: a page that lands beside a chat asked over the whole window by the
/// command key held as it was pressed (a web service's link, a visualization's); one asked so before and opened no
/// more, forgotten.
fn full_page_noted(p : Page) -> Unit {
  match p {
    Service(_, _) | PreviewFile(_, _, _, _) if full_held() => full_page.val = Some(p)
    _ => if full_page.val != Some(p) { full_page.val = None }
  }
}

///|
fn tab_full_reset() -> Unit {
  tab_full.set(None)
  full_page.val = None
}
