// A chat's unified way to the remote capabilities of the station it runs on (screens, browser, terminals): from its bar
// (Small, Medium and Large), its agent's card, its Station hover card and ⌘K. One screen alone (when neither browser
// nor terminal creation is offered) opens at once; otherwise a unified menu lists active agent screens, displays and
// simulators, the remote browser, and opening or resuming a terminal in this chat's workspace.

///|
/// Hook wired by sfpages at startup: whether this device's host links libghostty-vt (`terminals_here`).
// kept across runs: wired once at startup by sfapp to sfpages' terminals_here
pub let terminals_capable_fn : Ref[() -> Bool] = Ref(fn() { true })

///|
/// Whether `s` is a persistent user-opened tab of the station's browser.
fn chat_screen_user_tab(s : ChatScreen) -> Bool {
  s.id.has_prefix("browser:u_")
}

///|
/// A screen's mark by its kind: a tab of the station's browser, a simulator, else its display.
pub fn chat_screen_icon(s : ChatScreen) -> String {
  match s.kind {
    "browser" => "web"
    "simulator" => "phone"
    _ => "monitor"
  }
}

///|
/// A screen's words in a menu of them: its title, and that an agent drives it while one does.
pub fn chat_screen_label(s : ChatScreen) -> String {
  if s.agent {
    s.title + " · " + @sf.t("web-pages.chat.screenAgent")
  } else {
    s.title
  }
}

///|
/// Whether an agent drives any of the chat's screens now: its way to them marked so.
pub fn chat_screens_driven(screens : Array[ChatScreen]) -> Bool {
  screens.iter().any(fn(s) { s.agent })
}

///|
/// Whether chat view `v` offers any remote capability on its station (an active screen, opening a browser tab, or
/// opening a terminal on a host that supports terminals).
pub fn chat_has_remote(v : ChatView) -> Bool {
  v.screens.length() > 0 || v.can_browser() || (v.can_terminal() && (terminals_capable_fn.val)())
}

///|
/// Open or create a persistent remote browser tab on `station` from `src`.
pub fn open_remote_browser(src : Source, station : String, listed_ids : Array[String], url? : String = "") -> Unit {
  let target = if url != "" {
    @settings.new_browser_tab(src.call, station, listed_ids, fn(res) {
      if res is Err(e) {
        toast_later(@sf.t("android-misc.act.failed", args=[("what", @sf.t("web-pages.screen.openBrowserWhat")), ("error", text(Some(e), "message"))]))
      }
    }, url~)
  } else {
    match @settings.browser_tab_to_open(station, listed_ids) {
      Some(id) => id
      None =>
        @settings.new_browser_tab(src.call, station, listed_ids, fn(res) {
          if res is Err(e) {
            toast_later(@sf.t("android-misc.act.failed", args=[("what", @sf.t("web-pages.screen.openBrowserWhat")), ("error", text(Some(e), "message"))]))
          }
        })
    }
  }
  open_screen(station, target, None)
}

///|
/// The first of the chat's screens, its station's own display where it has one, else a chat-workspace terminal when
/// terminals are offered (`can_terminal`: its keys, ⌘K, the menu bar: chat.screen).
pub fn chat_remote_first(r : ChatRef, screens : Array[ChatScreen], can_terminal : Bool) -> Unit {
  match screens {
    [s, ..] => open_screen(r.station, s.id, Some(s.title))
    [] =>
      if can_terminal && (terminals_capable_fn.val)() {
        open_terminal(r.station, "new", "", r.session)
      }
  }
}

///|
fn chat_terminal_short(cwd : String) -> String {
  let parts = cwd.split("/").collect().filter(fn(p) { p.length() > 0 })
  match parts.last() {
    Some(last) => last.to_owned()
    None => if cwd == "" { @sf.t("core-views.terminal.title") } else { cwd }
  }
}

///|
/// Build and show the unified remote menu for chat `r`.
fn chat_remote_menu_show(
  src : Source?,
  r : ChatRef,
  screens : Array[ChatScreen],
  can_browser : Bool,
  can_terminal : Bool,
  terminals_val : Json?,
  from : @sf.Beside,
  along : @ui.Along,
) -> Unit {
  let term_ok = can_terminal && (terminals_capable_fn.val)()
  if !can_browser && !term_ok {
    match screens {
      [] => return
      [s] => {
        open_screen(r.station, s.id, Some(s.title))
        return
      }
      _ => ()
    }
  }
  let user_tabs = screens.filter(chat_screen_user_tab)
  let agent_tabs = screens.filter(fn(s) { s.kind == "browser" && !chat_screen_user_tab(s) })
  let other_screens = screens.filter(fn(s) { s.kind != "browser" })
  let open_terms = if term_ok {
    items(terminals_val, "terminals").filter(fn(t) { !flag(Some(t), "ended") })
  } else {
    []
  }
  let has_browser = !user_tabs.is_empty() || (can_browser && src is Some(_))
  let has_terms = term_ok || !open_terms.is_empty()
  // (the station's browser one part: the pages an agent drives in it and the way to its own tabs, under 浏览器, as the
  // terminals' part holds a new one and those open)
  let groups = (if !other_screens.is_empty() { 1 } else { 0 }) +
    (if has_browser || !agent_tabs.is_empty() { 1 } else { 0 }) +
    (if has_terms { 1 } else { 0 })
  let items_out : Array[@sf.MenuItem?] = []
  let add_sep = fn() {
    if !items_out.is_empty() {
      items_out.push(None)
    }
  }
  if !other_screens.is_empty() {
    if groups > 1 {
      items_out.push(Some(@sf.menu_item_of(@sf.t("web-pages.screen.section"), heading=true, fn() { })))
    }
    for s in other_screens {
      items_out.push(Some(@sf.menu_item_of(chat_screen_label(s), icon=chat_screen_icon(s), fn() {
        open_screen(r.station, s.id, Some(s.title))
      })))
    }
  }
  if has_browser || !agent_tabs.is_empty() {
    add_sep()
    if groups > 1 {
      items_out.push(Some(@sf.menu_item_of(@sf.t("web-pages.screen.browser"), heading=true, fn() { })))
    }
    for s in agent_tabs {
      items_out.push(Some(@sf.menu_item_of(chat_screen_label(s), icon=chat_screen_icon(s), fn() {
        open_screen(r.station, s.id, Some(s.title))
      })))
    }
  }
  if has_browser {
    let listed_ids = user_tabs.map(fn(s) { s.id })
    items_out.push(Some(@sf.menu_item_of(@sf.t("web-pages.screen.openBrowserRow"), icon="web", fn() {
      match src {
        Some(s) => open_remote_browser(s, r.station, listed_ids)
        None =>
          match @settings.browser_tab_to_open(r.station, listed_ids) {
            Some(to) => open_screen(r.station, to, None)
            None => if !user_tabs.is_empty() { open_screen(r.station, user_tabs[0].id, None) }
          }
      }
    })))
  }
  if has_terms {
    add_sep()
    if groups > 1 {
      items_out.push(Some(@sf.menu_item_of(@sf.t("web-pages.remote.openTerminal"), heading=true, fn() { })))
    }
    if term_ok {
      items_out.push(Some(@sf.menu_item_of(@sf.t("web-pages.remote.openChatTerminal"), icon="terminal", fn() {
        open_terminal(r.station, "new", "", r.session)
      })))
    }
    for t in open_terms {
      let tv = Some(t)
      let tid = text(tv, "id")
      let cwd = text(tv, "cwd")
      let label = chat_terminal_short(cwd) + (if text(tv, "chat") == r.session && r.session != "" { " · " + r.title } else { "" })
      items_out.push(Some(@sf.menu_item_of(label, icon="terminal", fn() {
        open_terminal(r.station, tid, cwd, text(tv, "chat"))
      })))
    }
  }
  if !items_out.is_empty() {
    let menu_title = if can_browser || term_ok {
      @sf.t("web-pages.remote.title")
    } else {
      @sf.t("web-pages.chat.screen")
    }
    @sf.menu(items_out, from~, title=menu_title, along~)
  }
}

///|
/// Legacy entry kept for callers with screens alone; prefers `chat_remote_open` when `Source` and `ChatView` are at hand.
pub fn chat_screens_open(r : ChatRef, screens : Array[ChatScreen], from~ : @sf.Beside, along? : @ui.Along = Start) -> Unit {
  chat_remote_menu_show(None, r, screens, false, false, None, from, along)
}

///|
/// Open the chat's unified remote menu (screens, agent pages, browser, chat-workspace terminal and running terminals),
/// reading `terminals` via `press_wait` when terminals are enabled so the menu opens whole in one frame.
pub fn chat_remote_open(
  src : Source,
  r : ChatRef,
  v : ChatView,
  from~ : @sf.Beside,
  along? : @ui.Along = Start,
) -> Unit {
  let term_ok = v.can_terminal() && (terminals_capable_fn.val)() && @signals.untracked(fn() { (src.asks_terminals)() })
  if !term_ok {
    chat_remote_menu_show(Some(src), r, v.screens, v.can_browser(), false, None, from, along)
    return
  }
  let scope = "chat-remote/" + r.station
  let ask_params : Map[String, Json] = { "station": Json::string(r.station) }
  let sub = hold(src, scope, "terminals", ask_params)
  press_wait(
    fn() { opens_answered(sub.get()) },
    fn() {
      let val = @signals.untracked(fn() { sub.get().value })
      let_go(src, scope)
      chat_remote_menu_show(Some(src), r, v.screens, v.can_browser(), true, val, from, along)
    },
    let_go=fn() { let_go(src, scope) },
    most=@sf.open_hold_ms,
  )
  |> ignore
}
