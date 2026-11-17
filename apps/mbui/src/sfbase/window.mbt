// A page in a window of its own (a desktop's), beside the app's. On the Mac, Windows and Linux it is a window of this run
// (@ui.window_open_here: the same program, the same core and the accounts it holds, the page shown in the window's first
// frame, what it was showing handed over, never asked for again); where the host has none (a run that is itself such a
// window), another run of the app (@ui.window_open), started with what it shows (MBUI_WINDOW, as window_text writes
// it), that shows that page alone over the same account and ends as its window closes or the app's run ends. A station's screen is the page that goes there now: from the
// side panel's bar beside a chat (sfdesk's panel.mbt) and from its viewer's 控制中心 (sfpages' screen_center_node.mbt),
// the screen leaving where it was (its view kept open for the window: window_has_screen).
// While its window is open, every way to that screen (a chat's link, its card, the station's page) brings the window
// to the front instead of opening it here too, a toast here saying so (window_front, open_page).

///|
/// The page this window shows alone, as a window of its own (a window of this run beside its first: lone_window_tree;
/// a run of its own: MBUI_WINDOW, src/stillfail's main); None: the app's window. Each window's of the run its own.
pub let lone_page : Ref[Page?] = Ref(None)

///|
fn init {
  // (each window of the run its own page alone, and its own toast: what is said in one is said there)
  @ui.window_kept_ref(lone_page, fn() { None })
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
/// What a window of its own is started with to show `p` (window_page reads it back): a station's screen; None for a
/// page that goes in none.
pub fn window_text(p : Page) -> String? {
  match p {
    Screen(at) =>
      Some(
        (
          {
            "screen": {
              "station": Json::string(at.station),
              "screen": Json::string(at.screen),
              "title": Json::string(at.title),
            },
          } : Json
        ).stringify(),
      )
    _ => None
  }
}

///|
/// The page a window of its own was started to show (window_text's), None when it names none.
pub fn window_page(s : String) -> Page? {
  let v = @json.parse(s) catch { _ => return None }
  guard v is Object(m) && m.get("screen") is Some(Object(at)) else { return None }
  guard at.get("station") is Some(String(station)) && station != "" else { return None }
  guard at.get("screen") is Some(String(screen)) && screen != "" else { return None }
  let title = match at.get("title") {
    Some(String(t)) => t
    _ => ""
  }
  Some(Screen({ station, screen, title, until_gone: false }))
}

///|
/// Whether `p` can be opened in a window of its own here: a desktop's app (not one such window already), a page that
/// goes in one.
pub fn window_opens_for(p : Page) -> Bool {
  lone_page.val is None && @ui.window_opens() && window_text(p) is Some(_)
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
        let wid = @ui.window_open_here(what)
        if wid > 0 {
          windows_open[key] = Here(wid)
          windows_here_show[wid] = p
          (window_page_given.val)(p, wid)
          return true
        }
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
/// What is told as a window of this run beside its first has closed, of the page it showed (sfpages': a screen no
/// window shows now let go of).
// kept across runs: a wire, set once in sfpages' fn init
pub let window_page_left : Ref[(Page) -> Unit] = Ref(fn(_) {  })

///|
/// What is told as page `p` is given to window `wid` of this run, as it opens (sfpages': a screen's pictures that
/// window's to show from then on, before the frame it left draws again).
// kept across runs: a wire, set once in sfpages' fn init
pub let window_page_given : Ref[(Page, Int) -> Unit] = Ref(fn(_, _) {  })

///|
/// What `p` is, whichever way it was opened (its title aside): None for a page that goes in no window.
fn window_key(p : Page) -> String? {
  match p {
    Screen(at) => Some(at.station + "\n" + at.screen)
    _ => None
  }
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
  windows_here_show.values().any(fn(p) { p is Screen(at) && at.station == station && at.screen == screen })
}

///|
/// The page this window shows alone changed to `next` (a screen's child popup followed, another of its station's
/// screens switched to): in a window of this run beside its first, what it shows and how a way to it finds it too, so
/// that the screen it left is no window's and a way to `next` brings this window to the front.
pub fn lone_page_replace(next : Page) -> Unit {
  let was = lone_page.val
  lone_page.val = Some(next)
  let wid = @ui.current_window_id()
  guard wid > 0 && windows_here_show.contains(wid) else { return }
  windows_here_show[wid] = next
  match was.bind(window_key) {
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
  windows_here_show.remove(wid)
  match window_key(p) {
    Some(key) if windows_open.get(key) is Some(Here(w)) && w == wid => windows_open.remove(key)
    _ => ()
  }
  (window_page_left.val)(p)
}

///|
/// The window showing `p`, where one is open, brought to the front and a toast here saying so: whether it was (the
/// page is then not to be opened here as well). A window closed since is forgotten.
pub fn window_front(p : Page) -> Bool {
  guard lone_page.val is None && window_key(p) is Some(key) else { return false }
  guard windows_open.get(key) is Some(opened) else { return false }
  let there = match opened {
    Here(wid) => @ui.window_front_here(wid)
    Run(what) => @ui.window_front(what)
  }
  if there {
    toast_later(@sf.t("web-pages.screen.windowOpen"))
  } else {
    windows_open.remove(key)
  }
  there
}
