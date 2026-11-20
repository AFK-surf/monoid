// Where a tab beside a chat is shown: in the chat's side panel, or over the whole window (全屏), one way for every kind
// (the user, 2026-11-17: 「这些东西的展示都做成一样的交互…用同一套逻辑，后续方便做成独立窗口」). Pressed, it opens over
// the whole window; with the command key held, in the panel (the user, 2026-11-20: 「默认应该全屏预览，cmd+点击开在右
// 边」, turning round 2026-11-17's 「大屏默认在右边展示，cmd+点击全屏」). Over the whole window it is the same tab drawn by
// the same nodes as in the panel (sfdesk's tab_full_layer_node), what it holds (a file's viewer, a service's page and
// its native view, kept past its node) the tab's, so it moves between the two as it is; the panel shows nothing of it
// meanwhile. Asked by a press without the command key (full_asked), the panel's 全屏, or what opens a page saying so
// (open_page_full). One put in the panel only to go over the whole window (`lone`) goes with it as it is closed
// (back, Escape), and stays in the panel only by 移到侧边 (tab_full_beside).

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
/// Whether the tab over the whole window was put in its chat's panel only to go there (`lone`: not in the panel before,
/// nor sent there by 移到侧边): closed, it leaves the panel too (tab_full_close).
// kept across runs: put back by pages.mbt's reset
let full_lone : Ref[Bool] = Ref(false)

///|
/// What takes tab `f` out of its chat's panel at once, the panel not sliding (sfdesk's, set as its layer is made): a
/// `lone` tab closed over the whole window.
// kept across runs: a function set once by sfdesk
pub let tab_full_drop : Ref[(TabFull) -> Unit] = Ref(fn(_) {  })

///|
/// Whether a press now asks for what it opens over the whole window: unless the command key of the system the person
/// types with is held (@ui.keys_system: ⌘ on Apple's, Ctrl elsewhere; a browser's the system under it, so ⌘ in one on
/// a Mac, where Ctrl and a press is the context menu), which asks for it in the panel beside the chat. Read here once,
/// never by a page.
pub fn full_asked() -> Bool {
  let primary = match @ui.keys_system() {
    0 | 1 => @ui.mod_cmd
    _ => @ui.mod_ctrl
  }
  (@ui.mods_held() & primary) == 0
}

///|
/// Tab `tab` of chat `r`'s side panel over the whole window; `lone`: put in the panel only to go there (full_lone).
pub fn tab_full_open(r : ChatRef, tab : String, lone? : Bool = false) -> Unit {
  // (in a window of its own: that window to the front instead, window.mbt's tab_window_front)
  if tab_window_front(r, tab) is Some(_) {
    return
  }
  tab_viewer_moves(r.station + ":" + r.session, tab)
  full_lone.val = lone
  tab_full.set(Some({ chat: r, tab }))
}

///|
/// Whether the tab over the whole window is `lone` (full_lone): what a tab put in its place keeps (a picture stepped).
pub fn tab_full_lone() -> Bool {
  tab_full.untracked() is Some(_) && full_lone.val
}

///|
/// The tab over the whole window closed (back, Escape, its chat left): back in its chat's side panel where it was there
/// before, else out of it too (full_lone).
pub fn tab_full_close() -> Unit {
  match tab_full.untracked() {
    Some(f) => {
      let lone = full_lone.val
      tab_full_beside()
      if lone {
        (tab_full_drop.val)(f)
      }
    }
    None => ()
  }
}

///|
/// The tab over the whole window back in its chat's side panel, staying there (移到侧边).
pub fn tab_full_beside() -> Unit {
  match tab_full.untracked() {
    Some(f) => {
      tab_viewer_moves(f.chat.station + ":" + f.chat.session, f.tab)
      full_lone.val = false
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
/// Whether page `p`, put beside a chat as a tab now, was asked over the whole window (open_page_full, or opened without
/// the command key held): taken, once.
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
/// What open_page notes of page `p` as it is opened: a page that lands beside a chat asked over the whole window, the
/// command key not held as it was pressed (a web service's link, a visualization's: full_asked); one asked so before and
/// opened no more, forgotten.
fn full_page_noted(p : Page) -> Unit {
  match p {
    Service(_, _) | PreviewFile(_, _, _, _) if full_asked() => full_page.val = Some(p)
    _ => if full_page.val != Some(p) { full_page.val = None }
  }
}

///|
fn tab_full_reset() -> Unit {
  tab_full.set(None)
  full_lone.val = false
  full_page.val = None
}
