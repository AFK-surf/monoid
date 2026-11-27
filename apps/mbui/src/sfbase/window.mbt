// A page in a window of its own (a desktop's), beside the app's. On the Mac, Windows and Linux it is a window of this run
// (@ui.window_open_here: the same program, the same core and the accounts it holds, the page shown in the window's first
// frame, what it was showing handed over, never asked for again); where the host has none (a run that is itself such a
// window), another run of the app (@ui.window_open), started with what it shows (MBUI_WINDOW, as window_text writes
// it), that shows that page alone over the same account and ends as its window closes or the app's run ends. A station's screen is the page that goes there now: from the
// side panel's bar beside a chat (sfdesk's panel.mbt) and from its viewer's 控制中心 (sfpages' screen_center_node.mbt),
// the screen leaving where it was (its view kept open for the window: window_has_screen).
// While its window is open, every way to that screen (a chat's link, its card, the station's page) brings the window
// to the front instead of opening it here too, a toast here saying so (window_front, open_page). So do a terminal, and a
// tab of a chat's side panel (SideTab: a file, a mini-program, a web service, a visualization; sfdesk's tab_full_node.mbt),
// its third place beside the panel and the whole window, only in a window of this run: what it holds the run's,
// handed over (window_has_tab), given back by its 移到侧边 (window_gives_back) or let go of as it closes (window_tab_left).
// What starts each says how its window is made (window_spec: role, title, size and least size).

///|
/// The page this window shows alone, as a window of its own (a window of this run beside its first: lone_window_tree;
/// a run of its own: MBUI_WINDOW, src/stillfail's main); None: the app's window. Each window's of the run its own.
pub let lone_page : Ref[Page?] = Ref(None)

///|
/// The page a window of its own shows (lone_page's), told as another is put in its place (lone_page_replace): what shows
/// it (sfapp's lone_tree) reads it, made again for another. Each window's own, a signal kept as its object (what one
/// window's change tells wakes none of another's), read through the object its tree took as it was made: a binding of
/// that tree may run as another window's runtime is in place.
pub let lone_shown : Ref[@signals.Signal[Page?]] = Ref(@signals.signal(None))

///|
/// The first window's lone_page as it was left for another window's runtime (first_lone_page's, while that is in place).
// kept across runs: put back by pages.mbt's reset
let first_lone : Ref[Page?] = Ref(None)

///|
/// The page the run's first window shows alone (lone_page's of window 0), whichever window's runtime is in place: what a
/// binding of the first window's tree reads (its shell), which may run as another window's is in place, where
/// lone_page is that one's.
pub fn first_lone_page() -> Page? {
  if @ui.current_window_id() == 0 {
    lone_page.val
  } else {
    first_lone.val
  }
}

///|
fn init {
  // (the first window's lone_page kept where its bindings read it while another window's runtime is in place: said
  // before lone_page's own, so it is read as the first window left it)
  @ui.window_kept(
    fn() {
      if @ui.current_window_id() == 0 {
        first_lone.val = lone_page.val
      }
      fn() {  }
    },
    fn() {  },
  )
  // (each window of the run its own page alone, and its own toast: what is said in one is said there)
  @ui.window_kept_ref(lone_page, fn() { None })
  @ui.window_kept_ref(lone_shown, fn() { @signals.signal(None) })
  @ui.window_kept(
    fn() {
      let held = app.toast
      fn() { app.toast = held }
    },
    fn() { app.toast = toast_said_new() },
  )
  @ui.when_window_closed(window_here_gone)
}

///|
/// The size a window of its own for `p` opens at, and the least it is made (WindowSpec: w, h, minW, minH, in points),
/// and its role, by the kind of page: a station's screen, a terminal, a chat's tab.
fn window_spec(p : Page) -> (String, Double, Double, Double, Double) {
  match p {
    Terminal(_) => ("terminal", 880.0, 580.0, 420.0, 300.0)
    SideTab(_) => ("tab", 960.0, 720.0, 420.0, 320.0)
    _ => ("screen", 1120.0, 760.0, 480.0, 360.0)
  }
}

///|
/// The title of a window of its own for chat tab `f` (window_text's): the file's name, a visualization's, a web
/// service's word, else its chat's title; never empty.
fn side_tab_title(f : TabFull) -> String {
  let name = match view_tab_file(f.tab) {
    Some(v) => v.file.name
    None =>
      if f.tab.has_prefix("service:") {
        svc("android-chat.preview.service")
      } else if f.tab.has_prefix("file:") {
        match (try Some(@json.parse(f.tab.exact_view(start="file:".length()).to_owned())) catch { _ => None }) {
          Some(Array([_, String(path), String(name)])) => if name != "" { name } else { path }
          _ => ""
        }
      } else {
        ""
      }
  }
  if name != "" {
    name
  } else if f.chat.title != "" {
    f.chat.title
  } else {
    svc("android-chat.preview.service")
  }
}

///|
/// The title of a window of its own showing `p` (window_text's, and what the window says as another page is put in its
/// place: sfapp's lone_tree): a screen's title, a terminal's folder, a chat's tab's name; never empty for those.
pub fn window_title(p : Page) -> String {
  match p {
    Screen(at) => if at.title != "" { at.title } else { at.screen }
    Terminal(at) => if at.cwd != "" { at.cwd } else { svc("web-pages.terminal.title") }
    SideTab(f) => side_tab_title(f)
    _ => ""
  }
}

///|
/// What a window of its own is started with to show `p` (window_page reads it back): a station's screen, a terminal, a
/// chat's tab (`screen`, `terminal`, `sideTab`), and how the window is made, as every host reads it (`role`, `title`,
/// `w`, `h`, `minW`, `minH`: window_spec); None for a page that goes in none.
pub fn window_text(p : Page) -> String? {
  let (what, title) : (Map[String, Json], String) = match p {
    Screen(at) =>
      (
        {
          "screen": {
            "station": Json::string(at.station),
            "screen": Json::string(at.screen),
            "title": Json::string(at.title),
            "owner": Json::string(window_page_owner(p)),
          },
        },
        window_title(p),
      )
    Terminal(at) if at.terminal != "" && terminal_base_id(at.terminal) != "new" =>
      (
        {
          "terminal": {
            "station": Json::string(at.station),
            "terminal": Json::string(at.terminal),
            "watch": Json::boolean(at.watch),
            "cwd": Json::string(at.cwd),
          },
        },
        window_title(p),
      )
    SideTab(f) if f.tab != "" && f.chat.station != "" && f.chat.session != "" =>
      (
        {
          "sideTab": {
            "station": Json::string(f.chat.station),
            "session": Json::string(f.chat.session),
            "chatTitle": Json::string(f.chat.title),
            "tab": Json::string(f.tab),
          },
        },
        window_title(p),
      )
    _ => return None
  }
  let (role, w, h, min_w, min_h) = window_spec(p)
  what["role"] = Json::string(role)
  what["title"] = Json::string(title)
  what["w"] = Json::number(w)
  what["h"] = Json::number(h)
  what["minW"] = Json::number(min_w)
  what["minH"] = Json::number(min_h)
  Some(Json::object(what).stringify())
}

///|
/// Creation owner parsed from `MBUI_WINDOW` for a child-process standalone screen window (`Run(what)`).
/// `None` for the normal primary app window; `Some(owner)` (possibly `""` if missing) for a child-process screen
/// window, evaluated fail-closed by `window_here_owner_state`.
// kept across runs: put back by pages.mbt's reset
let startup_window_owner : Ref[String?] = Ref(None)

///|
/// Transient `(station, screen, owner, claimed_wid)` held ONLY across the synchronous first-frame render inside
/// `@ui.window_open_here(what)` for a `Page::Screen` before `windows_here_owner[wid]` is populated.
/// The first unregistered positive `wid` matching `(station, screen)` claims it; any other unregistered `wid`
/// is denied. Cleared immediately on return.
// kept across runs: put back by pages.mbt's reset
let windows_here_opening_owner : Ref[(String, String, String, Int?)?] = Ref(None)

///|
/// Set the creation owner for a child-process standalone screen window (called only at real startup entrypoints).
pub fn set_startup_window_owner(owner : String?) -> Unit {
  startup_window_owner.val = owner
}

///|
/// Pure parser: extract the creation `owner` field from a `window_text` JSON payload when it describes a `screen`
/// window (`Some(owner)` with `""` if missing; `None` for non-screen payloads or invalid JSON). Has no side effects.
pub fn window_page_owner_of(s : String) -> String? {
  let v = @json.parse(s) catch { _ => return None }
  guard v is Object(m) else { return None }
  match m.get("screen") {
    Some(Object(at)) =>
      match at.get("owner") {
        Some(String(o)) => Some(o)
        _ => Some("")
      }
    _ => None
  }
}

///|
/// The page a window of its own was started to show (window_text's), None when it names none. Pure function (no side effects).
pub fn window_page(s : String) -> Page? {
  let v = @json.parse(s) catch { _ => return None }
  guard v is Object(m) else { return None }
  match m.get("screen") {
    Some(Object(at)) => {
      guard at.get("station") is Some(String(station)) && station != "" else { return None }
      guard at.get("screen") is Some(String(screen)) && screen != "" else { return None }
      let title = match at.get("title") {
        Some(String(t)) => t
        _ => ""
      }
      Some(Screen({ station, screen, title, until_gone: false }))
    }
    _ =>
      match (m.get("terminal"), m.get("sideTab")) {
        (Some(Object(at)), _) => {
          guard at.get("station") is Some(String(station)) && station != "" else { return None }
          guard at.get("terminal") is Some(String(terminal)) && terminal != "" else { return None }
          let watch = at.get("watch") == Some(Json::boolean(true))
          let cwd = match at.get("cwd") { Some(String(c)) => c; _ => "" }
          Some(Terminal({ station, terminal, watch, cwd }))
        }
        (_, Some(Object(at))) => {
          guard at.get("station") is Some(String(station)) && station != "" else { return None }
          guard at.get("session") is Some(String(session)) && session != "" else { return None }
          guard at.get("tab") is Some(String(tab)) && tab != "" else { return None }
          let title = match at.get("chatTitle") { Some(String(t)) => t; _ => "" }
          Some(SideTab({ chat: { station, session, title, station_name: "" }, tab }))
        }
        _ => None
      }
  }
}

///|
/// Whether `p` can be opened in a window of its own here: a desktop's app (not one such window already), a page that
/// goes in one. A chat's tab only in a window of this run (@ui.windows_here): what it shows (its viewer, its service's
/// page and site view) is this run's, handed over to that window, never shown again by another run.
pub fn window_opens_for(p : Page) -> Bool {
  lone_page.val is None &&
  @ui.window_opens() &&
  window_text(p) is Some(_) &&
  (!(p is SideTab(_)) || @ui.windows_here())
}

///|
/// How a window of its own was opened: a window of this run (its id), or another run, started with what it shows.
priv enum WindowOpened {
  Here(Int)
  Run(String)
}

///|
/// Page `p` opened in a window of its own (window_opens_for): whether it was. Where it showed, the caller takes it off;
/// a window of this run takes over what it showed (window_has_screen).
pub fn open_window(p : Page) -> Bool {
  guard window_opens_for(p) else { return false }
  if window_front(p) {
    return true
  }
  match (window_text(p), window_key(p)) {
    (Some(what), Some(key)) => {
      if @ui.windows_here() {
        // (a chat's tab: what it plays goes on there as it was, not paused as the node beside the chat goes)
        match p {
          SideTab(f) => tab_viewer_moves(f.chat.station + ":" + f.chat.session, f.tab)
          _ => ()
        }
        let owner = window_page_owner(p)
        windows_here_opening_owner.val = match p {
          Screen(at) => Some((at.station, at.screen, owner, None))
          _ => None
        }
        let wid = @ui.window_open_here(what)
        windows_here_opening_owner.val = None
        if wid > 0 {
          windows_open[key] = Here(wid)
          windows_here_show[wid] = p
          windows_here_owner[wid] = owner
          windows_here_told(p, wid)
          (window_page_given.val)(p, wid, owner)
          return true
        } else if p is SideTab(f) {
          tab_viewer_moves_cancel(f.chat.station + ":" + f.chat.session, f.tab)
        }
      }
      if p is SideTab(_) {
        return false
      }
      let opened = @ui.window_open(what)
      if opened {
        windows_open[key] = Run(what)
      }
      opened
    }
    _ => false
  }
}

///|
/// How each window of its own this run opened was opened, by what it shows (window_key): its title can differ from the
/// next way to it, the window being the same.
let windows_open : Map[String, WindowOpened] = Map([])

///|
/// The page each window of this run beside its first shows, by the window's id (open_window), while it is open.
let windows_here_show : Map[Int, Page] = Map([])

///|
/// Creation account owner of each standalone window (by window id), so subject switches cannot alias windows.
let windows_here_owner : Map[Int, String] = Map([])

///|
fn window_page_owner(p : Page) -> String {
  match p {
    Screen(at) =>
      match at.station.find("/") {
        Some(i) => workspace_owner_of(at.station.exact_view(end=i).to_owned())
        None => workspace_owner_of("")
      }
    _ => account_principal_now()
  }
}

///|
/// The chats' tabs a window of this run beside its first shows, by window_key, and its id: what the panel beside the
/// chat and the tab's own state read to know the tab is there (window_has_tab), followed.
// kept across runs: put back by pages.mbt's reset, each entry taken out as its window closes or gives it back
let tab_windows : @sf.LiveMap[String, Int] = @sf.LiveMap::new()

///|
/// Window `wid` of this run shows `p` now (open_window, lone_page_replace): a chat's tab told to tab_windows.
fn windows_here_told(p : Page, wid : Int) -> Unit {
  match (p, window_key(p)) {
    (SideTab(_), Some(key)) => tab_windows.set(key, wid)
    _ => ()
  }
}

///|
/// Window `wid` of this run shows `p` no more: a chat's tab taken out of tab_windows.
fn windows_here_untold(p : Page, wid : Int) -> Unit {
  match (p, window_key(p)) {
    (SideTab(_), Some(key)) if tab_windows.get(key) == Some(wid) => tab_windows.remove(key)
    _ => ()
  }
}

///|
/// Whether a window of this run beside its first shows tab `tab` of the chat on `station` kept by session `session`
/// now, followed: its view handed over as it opened, that window's to draw and to let go of.
pub fn window_has_tab(station : String, session : String, tab : String) -> Bool {
  tab_windows.contains(window_key(SideTab({ chat: { station, session, title: "", station_name: "" }, tab })).unwrap_or(""))
}

///|
/// Chat `r`'s tab `tab` asked here (beside the chat, over the whole window) while a window of this run beside its first
/// shows it, or a tab of the same file (view_tab_file's same_file): that window brought to the front instead, as every
/// way to a screen in a window of its own does (window_front), never the panel opened on it here too: the tab it shows;
/// None where no window shows it.
pub fn tab_window_front(r : ChatRef, tab : String) -> String? {
  let file = view_tab_file(tab)
  let shows = fn(f : TabFull) {
    f.chat.station == r.station &&
    f.chat.session == r.session &&
    (
      f.tab == tab ||
      (match (file, view_tab_file(f.tab)) {
        (Some(a), Some(b)) => a.same_file(b)
        _ => false
      })
    )
  }
  let found = windows_here_show.values().find_first(fn(p) { p is SideTab(f) && shows(f) })
  match found {
    Some(SideTab(f)) if window_front(SideTab(f)) => Some(f.tab)
    _ => None
  }
}

///|
/// What is told as a window of this run beside its first has closed on a chat's tab (sfdesk's: the tab let go of, as
/// its tab closed beside the chat would be), unless that window gave it back first (window_gives_back).
// kept across runs: a wire, set once in sfdesk's fn init
pub let window_tab_left : Ref[(TabFull) -> Unit] = Ref(fn(_) {  })

///|
/// Window `wid` of this run gives what it shows back to the first window (a chat's tab moved back beside its chat, its
/// 移到侧边), before it closes: forgotten now, nothing told as it closes (window_tab_left, window_page_left), a way to
/// it from then on opening it there.
pub fn window_gives_back(wid : Int) -> Unit {
  guard windows_here_show.get(wid) is Some(p) else { return }
  let owner = windows_here_owner.get(wid).unwrap_or_else(fn() { window_page_owner(p) })
  windows_here_show.remove(wid)
  windows_here_owner.remove(wid)
  windows_here_untold(p, wid)
  match window_key_for_owner(p, owner) {
    Some(key) if windows_open.get(key) is Some(Here(w)) && w == wid => windows_open.remove(key)
    _ => ()
  }
  // (a chat's tab: what it plays goes on beside the chat as it was, not paused as the window's node goes)
  match p {
    SideTab(f) => tab_viewer_moves(f.chat.station + ":" + f.chat.session, f.tab)
    _ => ()
  }
}

///|
/// What is told as a window of this run beside its first has closed, of the page it showed and its creation owner
/// (sfpages': a screen no window shows now let go of without aliasing another subject).
// kept across runs: a wire, set once in sfpages' fn init
pub let window_page_left : Ref[(Page, String) -> Unit] = Ref(fn(_, _) {  })

///|
/// What is told as page `p` is given to window `wid` of this run, as it opens (sfpages': a screen's pictures that
/// window's to show from then on, before the frame it left draws again), with its creation owner.
// kept across runs: a wire, set once in sfpages' fn init
pub let window_page_given : Ref[(Page, Int, String) -> Unit] = Ref(fn(_, _, _) {  })

///|
/// What `p` is for a specific `owner` account, whichever way it was opened (its title aside): None for a page that
/// goes in no window. Scoped by `owner` so a new subject cannot reuse or front another subject's standalone window.
fn window_key_for_owner(p : Page, owner : String) -> String? {
  match p {
    Screen(at) => Some(owner + "\u{2}screen\n" + at.station + "\n" + at.screen)
    Terminal(at) if at.terminal != "" && terminal_base_id(at.terminal) != "new" => Some("terminal\n" + at.station + "\n" + at.terminal)
    SideTab(f) if f.tab != "" => Some(owner + "\u{2}tab\n" + f.chat.station + "\n" + f.chat.session + "\n" + f.tab)
    _ => None
  }
}

///|
/// What `p` is, whichever way it was opened (its title aside): None for a page that goes in no window.
fn window_key(p : Page) -> String? {
  window_key_for_owner(p, window_page_owner(p))
}

///|
/// The page window `wid` of this run was opened to show (open_window), while it is open: what its tree shows in its
/// first frame (sfapp's lone_window_tree).
pub fn window_here_page(wid : Int) -> Page? {
  windows_here_show.get(wid)
}

///|
/// Whether a window of this run beside its first shows `screen` on `station` now: its view, handed over as the window
/// opened, is that window's to let go of, not the page it left here.
pub fn window_has_screen(station : String, screen : String) -> Bool {
  let ws = match station.find("/") {
    Some(i) => station.exact_view(end=i).to_owned()
    None => ""
  }
  window_has_screen_for_owner(workspace_owner_of(ws), station, screen)
}

///|
/// Whether a standalone window belonging to `owner` shows `screen` on `station` now.
pub fn window_has_screen_for_owner(owner : String, station : String, screen : String) -> Bool {
  for wid, p in windows_here_show {
    if p is Screen(at) && at.station == station && at.screen == screen && windows_here_owner.get(wid) == Some(owner) {
      return true
    }
  }
  false
}

///|
/// Tri-state ownership verification for standalone screen windows:
/// - `Matched`: creation owner verified against active workspace owner; safe to mount `screen_node`.
/// - `Waiting`: child-process standalone screen window waiting for the first complete `workspaces` snapshot (never
///   falls back to `subs[0]` and never opens `screen.view` while waiting).
/// - `Denied`: owner missing, revoked, or mismatched; must not mount `screen_node`.
#derive(Eq)
pub(all) enum WindowOwnerState {
  Matched
  Waiting
  Denied
}

///|
/// Evaluate tri-state ownership for window `wid` showing `screen` on `station`.
pub fn window_here_owner_state(wid : Int, station : String, screen? : String = "") -> WindowOwnerState {
  let ws = match station.find("/") {
    Some(i) => station.exact_view(end=i).to_owned()
    None => ""
  }
  let expected_opt : String? = if wid > 0 {
    match windows_here_owner.get(wid) {
      Some(o) => Some(o)
      None =>
        if !windows_here_show.contains(wid) {
          match windows_here_opening_owner.val {
            Some((st, sc, o, claimed)) if sc != "" && screen != "" && st == station && sc == screen =>
              match claimed {
                None => {
                  windows_here_opening_owner.val = Some((st, sc, o, Some(wid)))
                  Some(o)
                }
                Some(cwid) if cwid == wid => Some(o)
                _ => None
              }
            _ => None
          }
        } else {
          None
        }
    }
  } else {
    match startup_window_owner.val {
      None => return Matched
      Some(expected) => Some(expected)
    }
  }
  guard expected_opt is Some(expected) else { return Denied }
  if expected == "" || workspace_is_revoked(ws) {
    return Denied
  }
  if wid <= 0 && !workspace_owners_synced() {
    return Waiting
  }
  match workspace_explicit_owner_of(ws) {
    Some(actual) => if actual == expected { Matched } else { Denied }
    None =>
      if !workspace_owners_synced() {
        Waiting
      } else if workspace_owner_pending_for(ws, expected) {
        Waiting
      } else {
        Denied
      }
  }
}

///|
/// Convenience predicate returning `true` iff `window_here_owner_state(wid, station, screen~) == Matched`.
pub fn window_here_owner_matches(wid : Int, station : String, screen? : String = "") -> Bool {
  window_here_owner_state(wid, station, screen~) == Matched
}

///|
/// Whether a window of this run beside its first shows `terminal` on `station` now.
pub fn window_has_terminal(station : String, terminal : String) -> Bool {
  windows_here_show.values().any(fn(p) { p is Page::Terminal(at) && at.station == station && at.terminal == terminal })
}

///|
/// The page this window shows alone changed to `next` (a screen's child popup followed, another of its station's
/// screens switched to): in a window of this run beside its first, what it shows and how a way to it finds it too, so
/// that the screen it left is no window's and a way to `next` brings this window to the front.
pub fn lone_page_replace(next : Page) -> Unit {
  let was = lone_page.val
  lone_page.val = Some(next)
  lone_shown.val.set(Some(next))
  let wid = @ui.current_window_id()
  guard wid > 0 && windows_here_show.contains(wid) else { return }
  match windows_here_show.get(wid) {
    Some(p) => windows_here_untold(p, wid)
    None => ()
  }
  let prev_owner = windows_here_owner.get(wid).unwrap_or("")
  windows_here_show[wid] = next
  windows_here_owner[wid] = window_page_owner(next)
  windows_here_told(next, wid)
  match was.bind(fn(w) { window_key_for_owner(w, prev_owner) }) {
    Some(key) if windows_open.get(key) is Some(Here(w)) && w == wid => windows_open.remove(key)
    _ => ()
  }
  match window_key(next) {
    Some(key) => windows_open[key] = Here(wid)
    None => ()
  }
}

///|
/// Window `wid` of this run closed (@ui.when_window_closed): forgotten, and what it showed told (window_page_left).
fn window_here_gone(wid : Int) -> Unit {
  guard windows_here_show.get(wid) is Some(p) else { return }
  let owner = windows_here_owner.get(wid).unwrap_or_else(fn() { window_page_owner(p) })
  windows_here_show.remove(wid)
  windows_here_owner.remove(wid)
  windows_here_untold(p, wid)
  match window_key_for_owner(p, owner) {
    Some(key) if windows_open.get(key) is Some(Here(w)) && w == wid => windows_open.remove(key)
    _ => ()
  }
  match p {
    SideTab(f) => (window_tab_left.val)(f)
    _ => (window_page_left.val)(p, owner)
  }
}

///|
/// The window showing `p`, where one is open, brought to the front and a toast here saying so: whether it was (the
/// page is then not to be opened here as well). A window closed since is forgotten. (A chat's tab says no toast: the
/// only words there are a screen's, and its window come to the front says it.)
pub fn window_front(p : Page) -> Bool {
  guard lone_page.val is None && window_key(p) is Some(key) else { return false }
  guard windows_open.get(key) is Some(opened) else { return false }
  let there = match opened {
    Here(wid) => @ui.window_front_here(wid)
    Run(what) => @ui.window_front(what)
  }
  if there {
    if !(p is SideTab(_)) {
      toast_later(@sf.t("web-pages.screen.windowOpen"))
    }
  } else {
    windows_open.remove(key)
  }
  there
}
