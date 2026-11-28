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
/// Whether `sr` is confirmed+known by the station and lists `id` as a real (non-optimistic) screen.
pub fn live_screen_confirmed(sr : TopicState, id : String) -> Bool {
  if !sr.is_confirmed_known() {
    return false
  }
  for sc in items(sr.value, "screens") {
    let sv = Some(sc)
    if text(sv, "id") == id && !flag(sv, "opening") {
      return true
    }
  }
  false
}

///|
/// Confirmed non-optimistic user browser tab ids listed in `sr` (empty when `sr` is not confirmed+known).
pub fn confirmed_user_browser_ids(sr : TopicState) -> Array[String] {
  if !sr.is_confirmed_known() {
    return []
  }
  items(sr.value, "screens")
    .filter(fn(sc) {
      let sv = Some(sc)
      !flag(sv, "opening") && (flag(sv, "userTab") || text(sv, "id").has_prefix("browser:u_"))
    })
    .map(fn(sc) { text(Some(sc), "id") })
}

///|
/// Whether a station capability topic (`screens` / `terminals`) has settled for the current auth generation:
/// confirmed by the station, explicitly confirmed `outdated` (404), explicitly `denied` (401/403), or answered with an error
/// (never a cold-start `confirmed: false` cache).
pub fn cap_settled(st : TopicState) -> Bool {
  st.is_confirmed_known() ||
  (st.is_confirmed() && flag(st.value, "confirmed") && flag(st.value, "outdated")) ||
  (st.is_confirmed() && flag(st.value, "denied")) ||
  st.error is Some(_)
}

///|
/// The first of the chat's screens, its station's own display where it has one, else a chat-workspace terminal when
/// terminals are offered (`can_terminal`: its keys, ⌘K, the menu bar: chat.screen).
pub fn chat_remote_first(r : ChatRef, screens : Array[ChatScreen], can_terminal : Bool, src? : Source? = None) -> Unit {
  match screens {
    [s, ..] => {
      match src {
        Some(source) => {
          let sr = @signals.untracked(fn() { source.topic("screens", { "station": Json::string(r.station) }).get() })
          if live_screen_confirmed(sr, s.id) {
            open_screen(r.station, s.id, Some(s.title))
          } else if !cap_settled(sr) {
            let scope = "chat-remote-first/" + r.station
            let ssub = hold(source, scope, "screens", { "station": Json::string(r.station) })
            press_wait(
              fn() { cap_settled(ssub.get()) },
              fn() {
                let cur = ssub.untracked()
                let_go(source, scope)
                if live_screen_confirmed(cur, s.id) {
                  open_screen(r.station, s.id, Some(s.title))
                }
              },
              let_go=fn() { let_go(source, scope) },
              most=5000.0,
            )
            |> ignore
          }
          return
        }
        None => open_screen(r.station, s.id, Some(s.title))
      }
    }
    [] =>
      if can_terminal && (terminals_capable_fn.val)() {
        match src {
          Some(source) => {
            let tr = @signals.untracked(fn() { source.topic("terminals", { "station": Json::string(r.station) }).get() })
            if tr.is_confirmed_known() && flag(tr.value, "open") {
              open_terminal(r.station, "new", "", r.session)
            } else if !cap_settled(tr) {
              let scope = "chat-remote-first/" + r.station
              let tsub = hold(source, scope, "terminals", { "station": Json::string(r.station) })
              press_wait(
                fn() { cap_settled(tsub.get()) },
                fn() {
                  let cur = tsub.untracked()
                  let_go(source, scope)
                  if cur.is_confirmed_known() && flag(cur.value, "open") {
                    open_terminal(r.station, "new", "", r.session)
                  }
                },
                let_go=fn() { let_go(source, scope) },
                most=5000.0,
              )
              |> ignore
            }
            return
          }
          None => open_terminal(r.station, "new", "", r.session)
        }
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
  terms_sig? : @signals.Computed[TopicState]? = None,
  screens_sig? : @signals.Computed[TopicState]? = None,
  on_gone? : () -> Unit = fn() {  },
) -> Unit {
  let released = Ref(false)
  let release_once = fn() {
    if !released.val {
      released.val = true
      on_gone()
    }
  }
  let term_ok = can_terminal && (terminals_capable_fn.val)()
  if !can_browser && !term_ok {
    match screens {
      [] => {
        release_once()
        return
      }
      [s] => {
        let ok = match screens_sig {
          Some(ssig) => live_screen_confirmed(ssig.untracked(), s.id)
          None => true
        }
        release_once()
        if ok {
          open_screen(r.station, s.id, Some(s.title))
        }
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
        let ok = match screens_sig {
          Some(ssig) => live_screen_confirmed(ssig.untracked(), s.id)
          None => true
        }
        release_once()
        if ok {
          open_screen(r.station, s.id, Some(s.title))
        }
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
        let ok = match screens_sig {
          Some(ssig) => live_screen_confirmed(ssig.untracked(), s.id)
          None => true
        }
        release_once()
        if ok {
          open_screen(r.station, s.id, Some(s.title))
        }
      })))
    }
  }
  if has_browser {
    let listed_ids = user_tabs.map(fn(s) { s.id })
    items_out.push(Some(@sf.menu_item_of(@sf.t("web-pages.screen.openBrowserRow"), icon="web", fn() {
      match (src, screens_sig) {
        (Some(s), Some(ssig)) => {
          let sr = ssig.untracked()
          release_once()
          if !sr.is_confirmed_known() {
            return
          }
          let cur_listed = items(sr.value, "screens")
            .filter(fn(sc) {
              let sv = Some(sc)
              !flag(sv, "opening") && (flag(sv, "userTab") || text(sv, "id").has_prefix("browser:u_"))
            })
            .map(fn(sc) { text(Some(sc), "id") })
          match @settings.browser_tab_to_open(r.station, cur_listed) {
            Some(to) => open_screen(r.station, to, None)
            None =>
              if flag(sr.value, "browser") && flag(sr.value, "control") {
                open_remote_browser(s, r.station, cur_listed)
              }
          }
        }
        (Some(s), None) => {
          release_once()
          if can_browser {
            open_remote_browser(s, r.station, listed_ids)
          } else {
            match @settings.browser_tab_to_open(r.station, listed_ids) {
              Some(to) => open_screen(r.station, to, None)
              None => if !user_tabs.is_empty() { open_screen(r.station, user_tabs[0].id, None) }
            }
          }
        }
        (None, _) => {
          release_once()
          match @settings.browser_tab_to_open(r.station, listed_ids) {
            Some(to) => open_screen(r.station, to, None)
            None => if !user_tabs.is_empty() { open_screen(r.station, user_tabs[0].id, None) }
          }
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
      // Never statically disable on timeout: re-check live confirmed+known `terminals` + `open` at click time so late fresh arrival recovers.
      items_out.push(Some(@sf.menu_item_of(@sf.t("web-pages.remote.openChatTerminal"), icon="terminal", fn() {
        match terms_sig {
          Some(sig) => {
            let st = sig.untracked()
            release_once()
            if !st.is_confirmed_known() || !flag(st.value, "open") {
              return
            }
          }
          None => release_once()
        }
        open_terminal(r.station, "new", "", r.session)
      })))
    }
    for t in open_terms {
      let tv = Some(t)
      let tid = text(tv, "id")
      let cwd = text(tv, "cwd")
      let chat_id = text(tv, "chat")
      let label = chat_terminal_short(cwd) + (if chat_id == r.session && r.session != "" { " · " + r.title } else { "" })
      items_out.push(Some(@sf.menu_item_of(label, icon="terminal", fn() {
        let mut live_watch = false
        match terms_sig {
          Some(sig) => {
            let st = sig.untracked()
            release_once()
            if !st.is_confirmed_known() {
              return
            }
            let mut alive = false
            for x in items(st.value, "terminals") {
              if text(Some(x), "id") == tid && !flag(Some(x), "ended") {
                alive = true
                break
              }
            }
            if !alive {
              return
            }
            live_watch = !flag(st.value, "open")
          }
          None => release_once()
        }
        open_terminal(r.station, tid, cwd, chat_id, watch=live_watch)
      })))
    }
  }
  if !items_out.is_empty() {
    let menu_title = if can_browser || term_ok {
      @sf.t("web-pages.remote.title")
    } else {
      @sf.t("web-pages.chat.screen")
    }
    @sf.menu(items_out, from~, title=menu_title, along~, gone=release_once)
  } else {
    release_once()
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
  let scope = "chat-remote/" + r.station
  let ask_params : Map[String, Json] = { "station": Json::string(r.station) }
  let ssub = hold(src, scope, "screens", ask_params)
  if !term_ok {
    press_wait(
      fn() { cap_settled(ssub.get()) },
      fn() {
        chat_remote_menu_show(
          Some(src),
          r,
          v.screens,
          v.can_browser(),
          false,
          None,
          from,
          along,
          screens_sig=Some(ssub),
          on_gone=fn() { let_go(src, scope) },
        )
      },
      let_go=fn() { let_go(src, scope) },
      most=if !v.can_browser() && v.screens.length() == 1 { 5000.0 } else { @sf.open_hold_ms },
    )
    |> ignore
    return
  }
  let sub = hold(src, scope, "terminals", ask_params)
  press_wait(
    fn() { cap_settled(sub.get()) && cap_settled(ssub.get()) },
    fn() {
      let st = @signals.untracked(fn() { sub.get() })
      chat_remote_menu_show(
        Some(src),
        r,
        v.screens,
        v.can_browser(),
        true,
        st.value,
        from,
        along,
        terms_sig=Some(sub),
        screens_sig=Some(ssub),
        on_gone=fn() { let_go(src, scope) },
      )
    },
    let_go=fn() { let_go(src, scope) },
    most=@sf.open_hold_ms,
  )
  |> ignore
}
