// A station's screen, full screen (still.fail apps/android app/remote/ScreenViewer.kt, ScreenActivity.kt;
//): the frame fitted whole (letterboxed), zoomed in place with two fingers; while driving it, a
// tap clicks, a long press right-clicks, a drag drags, two fingers moving together scroll, and the keyboard types into
// it. Upright, the bar is above the frame (close, the title, how the view goes and who is on it, 只看/控制, pasting,
// 控制中心: screen_panel.mbt); sideways, a rail beside it; 全屏, the screen alone, sideways, its tools folded into one
// button over the frame's corner. While driving it, a copy made on the screen (text or a picture) lands on the device's clipboard, the
// device's clipboard is pasted into it, and files picked go onto its machine (how far they have got, then where they
// are, over the frame's foot). How the view is (connecting, reconnecting, ended…) is the core's: on its way, said over
// the frame as it was last shown; over (ended, gone…), said in the screen's place, gone dark. While it is in sight the
// device stays awake; out of sight the view is let go of, and opened again from the frame it showed.
//
// That is touch's. With keyboard and mouse (not a phone's) there is nothing to make
// up for a phone's hand: the viewer's bar across the window's top (the way back, the screen's name and the core's line,
// how the view goes, 控制中心, 只看/控制), the picture under it; the mouse is the screen's pointer where it is (its moves,
// its buttons, its wheel: screen_stage.mbt), the keyboard types into it once it is pressed, ⌘V pastes this device's
// clipboard there, and 全屏 is the window's.
//
// The page is made once as nodes of the window's tree (screen_node), in every place it is shown: the stack of 小屏, over
// the tape on 中屏 and over the frame on 大屏, a tab of a chat's panel and a window of its own. What it shows follows
// the view's state as the core tells it (ScreenSess's signals) and what was done here (ScreenUi's); what a hand does is
// done in its handler, at its moment.

///|
/// What the viewer keeps of a view beside the session: the frame's zoom, the trackpad's pointer, the modifiers held,
/// 全屏 and its folded tools, the press under way. What its nodes read of it is a signal, told as it changes.
// (address_field, stage_node, drops_card and mouse_pair: its tests alone read them, what the address bar holds and where
// the stage, the files' panel and the mouse's buttons are)
#warnings("-unused_field")
priv struct ScreenUi {
  zoom : @motion.Zoom
  pad : PadPointer
  held : HeldKeys
  full : @signals.Signal[Bool]
  /// its 全屏 asked beside its chat with touch: the page of it put on top over all of it (filling the window, the
  /// system's bars put away), taken off again as 全屏 is let go of (screen_unfull)
  mut full_from_tab : Bool
  /// the window made to fill the screen by its 全屏 (keyboard and mouse's), put back as it closes
  mut fulled : Bool
  /// shown as a tab beside its chat, whose tab closes it: no close of its own (the same thing twice)
  mut in_tab : Bool
  tools_open : @signals.Signal[Bool]
  /// how far the folded tools were dragged from their corner (so they cover another part of the screen)
  tools_moved : Afloat
  /// how far the mouse's buttons were dragged from theirs
  mouse_moved : Afloat
  /// the stage's size as it is laid out (told as it changes: 控制中心's 分辨率 reads it), and the frame's size it was
  /// fitted for
  box_w : @signals.Signal[Double]
  box_h : @signals.Signal[Double]
  mut fit_for : (Int, Int)?
  /// how much a device's case is round its picture each way, as shares of the picture (device_case); none: 0
  mut case_x : Double
  mut case_y : Double
  mut over_seen : Bool
  gesture : Gesture
  /// where the last tap, press held or drag driving it directly ended on the picture (0..1): where 左键 and 右键 click
  /// while the station says no pointer
  mut tapped_at : (Double, Double)?
  /// the page it is shown on, as last made (its title, whether it goes back once its screen is gone)
  mut at : ScreenAt?
  /// out of sight when no visible lease holder remains
  covered : @signals.Signal[Bool]
  /// a mouse on the stage (screen_mouse)
  mouse : MouseDrive
  /// a read of the device's clipboard under way, for a paste
  // (a handle: no value to compare)
  reading : @signals.Signal[@ui.ClipboardRead?]
  /// the read under way asked by ⌘V (Ctrl+V) on a screen that carries no clipboard: the key (its name, its modifiers)
  /// typed there as the device's text, or sent itself where the device has none; None: 粘贴手机剪贴板's, or a screen
  /// that carries one
  mut paste_from_key : (String, Int)?
  /// another paste asked while one is under way (two sentences a voice input pasted one on the other): asked as that
  /// one is done, by the key it came from as above
  mut paste_owed : ((String, Int)?)?
  /// ⌘V's V taken as a paste and still down: its going up taken too, whatever is let go of first
  mut pasted_v : Bool
  /// the modifiers held from the keys row as each key went down (by its code), for it to go up with them too
  down_with : Map[String, (String, String, Int, Int)]
  /// the device kept awake, the window sideways, a phone let turn as held: as last told to the host
  mut awake : Bool
  mut sideways_told : Bool
  mut turnable : Bool
  /// the keys row turned to the keys its first face had not the room for (keys_row's ⋯), by their names; none: its
  /// first face
  keys_turned : @signals.Signal[Array[String]]
  /// how many seconds it has been seen live (told as each is counted: 控制中心's row reads it); the frames and bits a
  /// second over the last second, once one was counted; the frames and bytes come by the last
  seen : @signals.Signal[Int]
  mut rate_frames : Int
  mut rate_bytes : Int
  mut fps : Double?
  mut bps : Double?
  /// a simulator's log as far as it was read (screen_debug.mbt)
  logs : DebugLogs
  /// 控制中心 ("center"), the view's figures ("net"), 按键 ("keys"), the tabs ("tabs") or a simulator's 日志 ("logs") or
  /// 重启 App ("apps") to open from the bar as it is made or as it is asked (a fixture's, a test's: as if pressed); ""
  /// none
  asked_panel : @signals.Signal[String]
  /// the panel this page opened over itself (控制中心 "center", 按键 "keys", the view's figures "stats", a simulator's
  /// "logs" or "apps"), the serial it was presented as (what is a step further in from it, presented after it, is its
  /// too: screen_panel_open_from) and whether the system's bars were down the side then (@sf.native_side); none since
  /// it was closed
  mut native_panel : (String, Int, Bool)?
  /// each panel this page opened or closed (`native_panel`: what shows one lit reads it)
  panels_told : @signals.Signal[Int]
  /// the address bar asked to take the keys (⌘L, a new tab): each ask
  address_asked : @signals.Signal[Int]
  /// the asks of it taken (each made address bar takes those above it)
  mut address_done : Int
  /// the address bar's field as last made
  mut address_field : @ui.Field?
  /// how its page is closed (⌘W on its last tab)
  mut close_page : () -> Unit
  /// its bar laid out narrow as last made (a touch screen upright, a narrow window): 控制中心 offers a browser's → and
  /// ⟳ then
  mut narrow_bar : Bool
  /// upright, the foot shows the keyboard's row (its 键盘 pressed), till it is put away again
  typing : @signals.Signal[Bool]
  /// the page's key catcher (screen_node's): where what is typed goes while it has the keyboard's focus
  mut catcher : @view.View?
  /// the stage as last made (screen_stage_node's): where the picture is fitted in
  mut stage_node : @view.View?
  /// the files' panel over the stage's foot and the mouse's floating buttons, as last made
  mut drops_card : @view.View?
  mut mouse_pair : @view.View?
  /// bumped when the person presses on the picture while another operates it, shaking the 接管 capsule
  held_nudge : @signals.Signal[Int]
  /// 左键 held down from its button (a press of it held: left_hold_node), a finger dragging with it till a tap on the
  /// stage or the button lets it go; where it is (where it went down, then as far as a finger dragged it) and the
  /// modifiers held round it
  left_locked : @signals.Signal[Bool]
  mut lock_at : (Double, Double)
  mut lock_mods : Int
  /// two fingers' scroll going on by itself once let go (ScrollFling)
  fling : ScrollFling
  /// where the last tap driving it directly clicked on the stage, and when (screen_tap_ripple_node draws it)
  ripple : @signals.Signal[(Double, Double, Double)?]
}

///|
let screen_uis : Map[String, ScreenUi] = Map([])

///|
fn screen_ui(key : String) -> ScreenUi {
  match screen_uis.get(key) {
    Some(u) => u
    None => {
      let u : ScreenUi = {
        zoom: screen_zoom(),
        pad: pad_pointer_new(),
        held: held_keys_new(),
        full: @signals.signal(false),
        full_from_tab: false,
        fulled: false,
        in_tab: false,
        tools_open: @signals.signal(false),
        tools_moved: afloat_new(),
        mouse_moved: afloat_new(),
        box_w: @signals.signal(0.0, same=fn(a, b) { a == b }),
        box_h: @signals.signal(0.0, same=fn(a, b) { a == b }),
        fit_for: None,
        case_x: 0.0,
        case_y: 0.0,
        over_seen: false,
        gesture: gesture_new(),
        left_locked: @signals.signal(false),
        lock_at: (0.5, 0.5),
        lock_mods: 0,
        fling: scroll_fling_new(),
        ripple: @signals.signal(None),
        tapped_at: None,
        at: None,
        covered: @signals.signal(false, same=fn(a, b) { a == b }),
        mouse: mouse_drive_new(),
        reading: @signals.signal_ref(None),
        paste_from_key: None,
        paste_owed: None,
        pasted_v: false,
        down_with: {},
        awake: false,
        sideways_told: false,
        turnable: false,
        keys_turned: @signals.signal([]),
        seen: @signals.signal(0, same=fn(a, b) { a == b }),
        rate_frames: 0,
        rate_bytes: 0,
        fps: None,
        bps: None,
        logs: debug_logs_new(),
        asked_panel: @signals.signal(""),
        native_panel: None,
        panels_told: @signals.signal(0),
        address_asked: @signals.signal(0),
        address_done: 0,
        address_field: None,
        close_page: fn() {  },
        narrow_bar: false,
        typing: @signals.signal(false, same=fn(a, b) { a == b }),
        catcher: None,
        stage_node: None,
        drops_card: None,
        mouse_pair: None,
        held_nudge: @signals.signal(0),
      }
      screen_uis[key] = u
      u
    }
  }
}

///|
/// The phases a view is over in (said in the screen's place, gone dark); `here`: this machine's own display, never
/// opened.
fn phase_over(p : String) -> Bool {
  p == "ended" || p == "outdated" || p == "gone" || p == "denied" || p == "failed" || p == "here"
}

///|
/// How long the rail's line stays said once asked for.
let rail_say_ms : Double = 3000.0

///|
/// The view's state as the core last told it, read where it is followed (what reads it told as another is taken).
fn ScreenSess::state_now(self : ScreenSess) -> Json? {
  self.said.get() |> ignore
  self.state
}

///|
/// What a page of a screen is made with: its view, what the viewer keeps of it, the title it was opened with, how it is
/// closed, where its tips are, and whether it is a tab beside its chat (`in_tab`; the only tab of a panel of its own:
/// `own_bar`, that panel's bar's style).
priv struct ScreenPage {
  s : ScreenSess
  u : ScreenUi
  title : String
  close : () -> Unit
  tips : @sf.TipLayer
  in_tab : Bool
  own_bar : (() -> @ui.Style)?
  /// a window of its own (the desktop's windows of one run), alone in it: nowhere to go back to
  lone : Bool
  /// shown as a tab at a pane's top with no row of tabs over it (远程's): its bar the pane's own, as high as a page's,
  /// its keys this far in from its start, top and end (screen_tab_bar_node)
  tab_pads : @sf.BarEnds?
  /// the workbench pane's width when shown in 远程 (decides wide vs narrow simulator arrangement; none in a chat's side panel)
  pane_width : (() -> Double)?
  /// where a window of its own takes it, what hands it there (its 在独立窗口中打开)
  on_window : (() -> Unit)?
}

///|
/// The width deciding wide vs narrow arrangement for a simulator pane: its own pane's width where given (远程's
/// workbench), 0 in a chat's side panel, else the window's — minus the trailing room reserved for the app's own
/// window buttons on Windows/Linux so the 3-zone simulator top bar folds before colliding with `- □ ×`.
fn ScreenPage::sim_width(self : ScreenPage, v : @view.View) -> Double {
  let raw = match self.pane_width {
    Some(w) => w()
    None => if self.in_tab { 0.0 } else { v.window_w() }
  }
  let keys_w = if @ui.window_keys_own_now() {
    match self.tab_pads {
      Some(pads) => (pads.end)()
      None => if self.in_tab { 0.0 } else { @sf.window_keys_room(roots=@ui.tree_corner_roots_now()) }
    }
  } else {
    0.0
  }
  dmax(0.0, raw - keys_w)
}

///|
/// Whether this page shows a simulator in the wide unified top-bar arrangement (Proposal C: mouse/keyboard wide pane —
/// 远程's workbench or standalone Viewer; touch tablets have no top bar and keep device buttons beside the device).
fn ScreenPage::sim_wide(self : ScreenPage, v : @view.View) -> Bool {
  self.s.said.get() |> ignore
  self.s.simulator() &&
  !@sf.soft_keyboard() &&
  !(!self.in_tab && @sf.native_on()) &&
  @sf.width_is_wide(Some(fn() { self.sim_width(v) }))
}

///|
/// Whether the keyboard's input goes to the screen now (the page's key catcher has the focus), followed.
fn ScreenPage::catching(self : ScreenPage) -> Bool {
  match self.u.catcher {
    Some(k) => @ui.key_catcher_focused(k)
    None => false
  }
}

///|
/// The screen's name as the core says it, else the one it was opened with, else 远程屏幕.
fn ScreenPage::said_title(self : ScreenPage) -> String {
  match opt_text(self.s.state_now(), "title") {
    Some(t) if t != "" => t
    _ => if self.title != "" { self.title } else { @sf.t("android-misc.screen.title") }
  }
}

///|
/// How the page is arranged (screen_node): the system's bars hold its actions (an iPhone Duo's); 全屏; with keyboard and
/// mouse a tab beside its chat or the viewer's bar over the picture; with touch, sideways (a rail) or upright (a bar
/// over it, a foot under it).
#derive(Eq)
priv enum ScreenLook {
  Native
  Full
  Tab
  Viewer
  Sideways
  Upright
}

///|
/// The viewer of `at.screen` on `at.station` (screen_pane_node, which says the rest).
#callsite(autofill(loc))
pub fn screen_node(
  v : @view.View,
  src : Source,
  at : ScreenAt,
  frame : () -> PageFrame,
  on_close? : () -> Unit,
  in_tab? : Bool = false,
  own_bar? : (() -> @ui.Style)? = None,
  shown? : () -> Bool = fn() { true },
  loc~ : SourceLoc,
) -> Unit {
  screen_pane_node(v, src, at, frame, on_close?, in_tab~, own_bar~, shown~, loc~)
}

///|
/// The viewer of `at.screen` on `at.station` (ScreenViewer) in node `v`: `at.title` until the core says one (the
/// link's own, or the row's it was opened from); one opened until its screen is gone (a login's page) goes back by
/// itself then. Inside the room its frame keeps over and under it (`frame`: the system's bars), unless full. `on_close`:
/// what its 关闭 does where it is not a page of the shell's (a window of its own, a chat's tab); `in_tab`: a tab beside
/// its chat, `own_bar` the bar's style of a panel it is alone in.
#callsite(autofill(loc))
pub fn screen_pane_node(
  v : @view.View,
  src : Source,
  at : ScreenAt,
  frame : () -> PageFrame,
  on_close? : () -> Unit,
  in_tab? : Bool = false,
  own_bar? : (() -> @ui.Style)? = None,
  tab_pads? : @sf.BarEnds,
  pane_width? : () -> Double,
  on_window? : () -> Unit,
  shown? : () -> Bool = fn() { true },
  loc~ : SourceLoc,
) -> Unit {
  let station = at.station
  let screen = at.screen
  v.pick(at_once=true, loc~, fn() {
    screen_revokes.get() |> ignore
    @sfbase.workspace_owners_version.get() |> ignore
    screen_key(station, screen)
  }, fn(root, key) {
    let (ws, _) = screen_workspace_and_station(station)
    let owner = @sfbase.workspace_owner_of(ws)
    if owner == "\u{3}pending" {
      root.grow(Is(1.0)).min_height(Is(Some(0.0))).lines_up(Is(Some(Middle))) |> ignore
      @sf.waiting_node(root, fn(_) {  })
      return
    }
    if owner == "\u{3}revoked" {
      root.grow(Is(1.0)).min_height(Is(Some(0.0))).lines_up(Is(Some(Middle))) |> ignore
      root.words(By(fn() { @sf.t("android-misc.screen.denied") })).ink(By(fn() { @sf.theme().p.muted })) |> ignore
      return
    }
    let s = screen_sess(src, station, screen)
    let u = screen_ui(key)
    u.in_tab = in_tab
    u.at = Some(at)
    // its 关闭: closed through the shell, the page it is; the window back as it was where its 全屏 filled the screen
    let close = fn() {
      screen_panels_close(u)
      if u.fulled && @ui.full_screen() {
        @hostapi.set_full_screen(false)
      }
      u.fulled = false
      match on_close {
        Some(f) => f()
        None => @sfbase.close_page(Screen(at)) |> ignore
      }
    }
    u.close_page = close
    let lone = on_close is Some(_) && !in_tab
    root.grow(Is(1.0)).min_height(Is(Some(0.0))).min_width(Is(Some(0.0))).clips(Is(true)) |> ignore
    // (its ground under all of it, a box of its own: the page's, 全屏 the theater's dark)
    root.box(fn(g) {
      g.over(Is(true)).ground(By(fn() { @ui.tree_theme().color(if u.full.get() { Theater } else { Bg }) })) |> ignore
    })
    |> ignore
    let tips_at : Ref[@view.View?] = Ref(None)
    let pg : ScreenPage = {
      s,
      u,
      title: at.title,
      close,
      tips: @sf.TipLayer::new(fn() { tips_at.val }),
      in_tab,
      own_bar,
      lone,
      tab_pads,
      pane_width,
      on_window,
    }
    // unseen, where the keyboard's input goes (a press on the stage gives it the focus with a mouse; 键盘 with a finger)
    screen_catcher_node(root, pg)
    screen_life_node(root, pg, src, at, shown)
    // (in place of the system's tabs where it has them, as the page shown or the window of its own it is)
    if !in_tab {
      screen_native_acts(root, pg, fn() { lone || @sfbase.app.nav.top() == Screen(at) })
    }
    // back in 全屏 leaves it first
    root.show(at_once=true, fn() { u.full.get() }, fn(b) {
      b.over(Is(true)) |> ignore
      b.takes_back(fn() { screen_unfull(u) }) |> ignore
    })
    // the page its 全屏 beside its chat put on top, closed otherwise (its tab closed, the chat left): back beside the
    // chat as it was, not full
    if !in_tab {
      root.owns(fn() {
        if u.full_from_tab {
          u.full_from_tab = false
          u.full.set(false)
        }
      })
      |> ignore
    }
    let look = fn() {
      let full = u.full.get()
      if !in_tab && @sf.native_on() && !full {
        ScreenLook::Native
      } else if full {
        Full
      } else if !@sf.soft_keyboard() {
        if in_tab {
          Tab
        } else {
          Viewer
        }
      } else {
        let (ww, wh) = root.window()
        if ww > wh {
          Sideways
        } else {
          Upright
        }
      }
    }
    root.pick(at_once=true, look, fn(p, look) {
      p.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      // inside the bars unless full (ScreenViewer.kt: windowInsetsPadding(safeDrawing); full, edge to edge, no room kept
      // for what its frame keeps it from; the system's bars there down the side: clear of them)
      p.padding(By(fn() {
        let f = frame()
        let end = if look is Native { @sf.native_clear() } else { 0.0 }
        if look is Full {
          (0.0, 0.0, 0.0, 0.0)
        } else {
          (0.0, f.top, end, f.foot)
        }
      }))
      |> ignore
      match look {
        Native => screen_native_look(p, pg)
        Full => screen_full_look(p, pg)
        Tab => screen_tab_look(p, pg)
        Viewer => screen_viewer_look(p, pg)
        Sideways => screen_sideways_look(p, pg)
        Upright => screen_upright_look(p, pg)
      }
    })
    // its tips, over all of it
    root.box(fn(t) {
      t.over(Is(true)) |> ignore
      tips_at.val = Some(t)
    })
    |> ignore
  })
}

///|
/// The system's bars hold its actions (screen_native_acts): the browser's bar over the picture where it has one, the
/// picture; 接管 over its top while someone else drives it, the keys a phone's keyboard has not over its foot while it is
/// up.
fn screen_native_look(p : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  p.show(at_once=true, fn() { browser_shown_now(s) }, fn(b) { browser_bar_node(b, pg) })
  p.box(fn(fill) {
    fill.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    // as sideways: the keys a phone's keyboard has not while it is up, else the mouse's buttons (the stage's foot's)
    screen_content_node(fill, pg, pair=fn() { !(s.driving_now() && typing_now(fill)) && mouse_shown_now(s) })
    take_over_over_node(fill, pg)
    keys_capsule_over_node(fill, pg, sides=false)
  })
  |> ignore
}

///|
/// 全屏: the picture alone, edge to edge, its tools folded into one button over its corner (full_tools_node).
fn screen_full_look(p : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  p.box(fn(fill) {
    fill.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    screen_stage_node(fill, pg, pair=fn() { !typing_now(fill) && mouse_shown_now(s) })
    take_over_over_node(fill, pg)
    keys_capsule_over_node(fill, pg, sides=true)
    full_tools_node(fill, pg)
  })
  |> ignore
}

///|
/// With keyboard and mouse beside a chat in its side panel: the panel's own tab bar above already names the screen,
/// closes it and opens it in a window of its own, so only one compact toolbar row (browser controls + 控制中心, or
/// desktop status + 组合键 + 控制中心) stands over the picture.
fn screen_tab_look(p : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  screen_tab_bar_node(p, pg)
  p.show(at_once=true, fn() { s.taking_over_now() && !pg.sim_wide(p) }, fn(t) { take_over_node(t, pg, in_bar=false, placed=true) })
  screen_content_node(p, pg)
}

///|
/// With keyboard and mouse: the viewer's bar across the window's top, always there, the picture under it (what is at the
/// top of the screen, its windows' title bars, never under the bar); the browser's bar under it where it has one.
fn screen_viewer_look(p : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  screen_viewer_bar_node(p, pg)
  p.show(at_once=true, fn() { browser_shown_now(s) }, fn(b) { browser_bar_node(b, pg) })
  screen_content_node(p, pg)
}

///|
/// Sideways with touch: the rail down its side (screen_rail_node), beside it the browser's bar where it has one (its
/// page's ← → ⟳ and address, as the picture's center takes it to be over it: screen_center_node) and the picture under
/// it, 接管 floating over its top, the keys row over its foot while the keyboard is up; the rail's line said beside it
/// once the people on it are tapped.
fn screen_sideways_look(p : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  p.row(Is(true)) |> ignore
  let said = screen_rail_node(p, pg)
  p.box(fn(col) {
    col.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    col.show(at_once=true, fn() { browser_shown_now(s) }, fn(b) { browser_bar_node(b, pg) })
    col.box(fn(fill) {
      fill.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
      // (the mouse's buttons, the keyboard down, floating over its foot's corner: the stage's foot's)
      screen_content_node(fill, pg, pair=fn() { !(s.driving_now() && typing_now(fill)) && mouse_shown_now(s) })
      take_over_over_node(fill, pg)
      keys_capsule_over_node(fill, pg, sides=false)
    })
    |> ignore
  })
  |> ignore
  rail_said_node(p, pg, said)
}

///|
/// Upright with touch: the bar over the picture (close, its name and line, 控制中心), 接管 under it while someone else
/// drives it, the picture, and under it while driving (a simulator's only while typing: it has a keyboard of its own,
/// and buttons of its own under the picture) the foot's actions or the keyboard's row.
fn screen_upright_look(p : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  screen_top_bar_node(p, pg)
  p.show(at_once=true, fn() { s.taking_over_now() }, fn(t) { take_over_node(t, pg, in_bar=false, placed=true) })
  screen_content_node(p, pg)
  p.show(at_once=true, fn() { s.driving_now() && (!s.simulator() || u.typing.get() || pg.catching()) }, fn(f) { foot_node(f, pg) })
}

///|
/// Whether the soft keyboard is up over the window `v` is in, followed.
fn typing_now(v : @view.View) -> Bool {
  v.keyboard_inset() > 0.0
}

///|
/// Whether it drives the screen now, followed as the state is told.
fn ScreenSess::driving_now(self : ScreenSess) -> Bool {
  self.said.get() |> ignore
  self.pad_set.get() |> ignore
  self.driving()
}

///|
/// Whether someone else drives it and this view may take it over (接管), followed.
fn ScreenSess::taking_over_now(self : ScreenSess) -> Bool {
  self.said.get() |> ignore
  self.can_take_over()
}

///|
/// Whether it is open now (on its way or live, not over), followed.
fn ScreenSess::open_said(self : ScreenSess) -> Bool {
  self.said.get() |> ignore
  self.failure.get() |> ignore
  self.finished.get() |> ignore
  self.open_now()
}

///|
/// Whether the mouse's buttons show now (mouse_shown), followed.
fn mouse_shown_now(s : ScreenSess) -> Bool {
  s.said.get() |> ignore
  mouse_shown(s)
}

///|
/// The page's key catcher in `root`: no room of its own (what is typed goes to the screen while it has the focus, the
/// soft keyboard over it then), taking the focus only while driving (as it stops, the focus let go and the modifiers held
/// on the keys row with it). What it is told goes to the screen (screen_keys_in).
fn screen_catcher_node(root : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  root.box(fn(o) {
    // (no room of its own: over the page's top left, of no size, so it is over nothing drawn)
    o.over(Is(true)).width(Is(Some(0.0))).height(Is(Some(0.0))) |> ignore
    @ui.key_catcher_node(
      o,
      @sf.t("android-misc.screen.title"),
      fn(k) { screen_keys_in(pg, k) },
      on=By(fn() { s.driving_now() }),
      catch_close=true,
      fn(k) {
        k.width(Is(Some(0.0))).height(Is(Some(0.0))) |> ignore
        u.catcher = Some(k)
        // the input method by what is being typed on: where the mouse last pressed, the screen's own caret not being
        // known here (screen_mouse)
        k.owns(fn() {
          match u.catcher {
            Some(c) if c.id() == k.id() => u.catcher = None
            _ => ()
          }
        })
        |> ignore
      },
    )
    |> ignore
  })
  |> ignore
  // no longer driving it (只看, the view ended): the keyboard goes, and as it stops, the modifiers held on the keys row
  root.reacts(fn() { s.driving_now() }, fn(driving) {
    if !driving {
      match u.catcher {
        Some(k) => @ui.key_catcher_focus_set(k, false)
        None => ()
      }
      u.held.take() |> ignore
      u.down_with.clear()
      u.typing.set(false)
    } else {
      // driving it on a page of its own with a keyboard (a window's, or 远程's workbench pane where no chat field sits
      // beside it; not a tab beside a chat's, whose field it would take; no soft keyboard brought up unasked): the keys
      // go to the screen straight away, so a shortcut or what a voice input types lands there without a press on the
      // picture first; never over the address bar asked for
      let addr_focused = match u.address_field {
        Some(f) => @signals.untracked(fn() { f.focused() })
        None => false
      }
      if (!pg.in_tab || pg.tab_pads is Some(_)) &&
        !@sf.soft_keyboard() &&
        u.address_asked.untracked() == 0 &&
        !addr_focused {
        match u.catcher {
          Some(k) => @ui.key_catcher_focus_set(k, true)
          None => ()
        }
      }
    }
  })
}

///|
/// What keeps the view as the page is in sight (ScreenActivity onStart / onStop): opened while the app is in sight and
/// the page not under another, let go of (its last frame kept) out of sight; asked as large as the stage is in this
/// device's pixels (自动), with what 控制中心 chose; the device awake and let turn while it is looked at; its screen
/// gone, back where it was opened from (a login's tab); a child popup opened from it while driving, followed; over,
/// out of 全屏; sideways while full; a copy made there put on this device's clipboard; the device's clipboard read for
/// a paste pasted; and the view's figures counted each second while it is live.
fn screen_life_node(root : @view.View, pg : ScreenPage, src : Source, at : ScreenAt, visible_in_host : () -> Bool) -> Unit {
  let s = pg.s
  let u = pg.u
  let key = screen_key(s.station, s.screen)
  screen_holder_next.val += 1
  let holder_id = screen_holder_next.val
  let tree_active = Ref(false)
  let shown = fn() { @ui.app_visible() && !u.covered.get() }
  if !@signals.untracked(visible_in_host) && screen_lease_visible_count(key) == 0 {
    u.covered.set(true)
  }
  let sync_lease = fn() {
    if s.is_active_principal() {
      let vis = tree_active.val && @signals.untracked(visible_in_host)
      screen_lease_set(src, key, holder_id, vis)
    }
  }
  let pending : Ref[() -> Unit] = Ref(fn() {  })
  let apply = fn() {
    let (shown, bw, bh, phase) = @signals.untracked(fn() { (shown(), u.box_w.get(), u.box_h.get(), s.phase_now()) })
    s.own_stream()
    let scale = root.pixel_scale()
    // on a phone or a tablet, a page of the station's browser is laid out for the stage it is shown on, as this
    // device's own browser would lay it out (the station takes no notice of it for other screens)
    if @sf.soft_keyboard() && bw > 0.0 && bh > 0.0 && s.fit is None {
      s.fit = Some((bw, bh, scale))
    }
    // 自动 asks for a picture as large as the stage is in this device's pixels
    if bw > 0.0 && bh > 0.0 {
      s.stage_is((bw * scale).round().to_int(), (bh * scale).round().to_int())
    }
    if shown {
      // (once the stage is laid out: asked as large as it is from the first, 自动)
      if bw > 0.0 && bh > 0.0 {
        // 画质 chosen otherwise: opened again with it; open again where it was let go, not where it is over (重新打开
        // opens that)
        s.asked_again(src)
        if !phase_over(phase) {
          s.open(src)
        }
      }
    } else {
      s.pause(src)
    }
    // while it is looked at, the device stays awake: a screen is watched more than touched
    if u.awake != shown {
      u.awake = shown
      @sfbase.keep_awake_by("screen:" + key, shown)
      // (into the device's performance record while it is kept: what warms a phone is mostly a screen looked at)
      @hostapi.perf_line("app: screen " + (if shown { "shown " } else { "hidden " }) + key)
    }
    // while it is looked at, a phone turns as it is held, the rotation lock honoured: with it on, the system offers
    // its turn button
    if u.turnable != shown {
      u.turnable = shown
      @hostapi.set_turnable(shown)
    }
  }
  let schedule_apply = fn() {
    (pending.val)()
    pending.val = root.at_moment_active(root.cause_at(), apply, while_covered=true)
  }
  root.when_active(while_covered=true, fn() {
    tree_active.val = true
    sync_lease()
    schedule_apply()
    fn() {
      tree_active.val = false
      (pending.val)()
      pending.val = fn() {  }
      sync_lease()
    }
  })
  |> ignore
  root.reacts(visible_in_host, fn(_) { sync_lease() })
  root.owns(fn() { screen_lease_release(src, key, holder_id) }) |> ignore
  root.reacts(
    fn() { (shown(), u.box_w.get(), u.box_h.get(), s.phase_now(), screen_quality(src), screen_fps(src), screen_bitrate(src), screen_chroma444(src)) },
    fn(_) { schedule_apply() },
  )
  // its screen gone (the login's tab closed as it ended): back to where it was opened from
  if at.until_gone {
    root.reacts(fn() { s.phase_now() }, fn(phase) {
      if phase == "gone" {
        (pg.close)()
      }
    })
  }
  // a child popup opened from this tab while driving: followed (returning here when its window closes), as this
  // page's tree takes its next moment, as the window it is in (a window of its own's: what the core said is taken as the
  // first's)
  let wid = @ui.current_window_id()
  root.reacts(fn() { (shown(), s.said.get()) }, fn(now) {
    guard now.0 && s.is_active_principal() && s.child_screen is Some(next) else { return }
    s.child_screen = None
    root.at_moment(root.cause_at(), fn() { @ui.as_window(wid, fn() {
      guard s.is_active_principal() else { return }
      let child_at : ScreenAt = { station: s.station, screen: next, title: "", until_gone: true }
      if pg.lone {
        // (the window shows the child first, so the screen it leaves is no window's when it is let go of)
        @sfbase.lone_page_replace(Screen({ ..child_at, until_gone: false }))
        screen_left_force(src, key)
      } else if u.in_tab {
        @sfbase.open_page(Screen(child_at))
      } else {
        @sfbase.app.nav.push(Screen(child_at))
      }
    }) })
    |> ignore
  })
  // over (ended, gone…): out of 全屏
  root.reacts(fn() { !s.open_said() }, fn(over) {
    if over && u.full.untracked() {
      screen_unfull(u)
    }
  })
  // 全屏 in sight: the window sideways (a phone's)
  root.reacts(fn() { u.full.get() && !u.covered.get() }, fn(on) {
    if on != u.sideways_told {
      u.sideways_told = on
      @hostapi.set_sideways(on)
    }
  })
  // keep the station's OS subscribed from opening so cross-OS shortcut mapping works in standalone windows before 控制中心 opens
  root.reacts(fn() { screen_os(src, s.station) }, fn(_) {  })
  // a copy made on the screen: onto the device's clipboard (screen_copies)
  root.reacts(fn() { s.copied_told.get() }, fn(_) { screen_copies(s) })
  // the device's clipboard read for a paste, once it answers (screen_pasted)
  root.reacts(
    fn() {
      match u.reading.get() {
        Some(r) => r.got()
        None => None
      }
    },
    fn(got) {
      match got {
        Some(g) => {
          u.reading.set(None)
          screen_pasted(s, u, g)
        }
        None => ()
      }
    },
  )
  // the view's figures, each second of the clock while it is live and active (screen_count's, the frames' clock's whole
  // seconds): managed via `when_active(while_covered=true)` so resting removes the timer and waking resets the fps/bps
  // baseline (preventing accumulated spikes when returning to the screen).
  let ticking : Ref[(() -> Unit)?] = Ref(None)
  let stats_active = Ref(false)
  let stop_tick = fn() {
    match ticking.val {
      Some(stop) => {
        ticking.val = None
        stop()
      }
      None => ()
    }
  }
  fn tick(at : Double) -> Unit {
    ticking.val = None
    if !stats_active.val || !root.alive() {
      return
    }
    let (frames, bytes) = s.came()
    u.fps = Some((frames - u.rate_frames).to_double())
    u.bps = Some((bytes - u.rate_bytes).to_double() * 8.0)
    u.rate_frames = frames
    u.rate_bytes = bytes
    u.seen.set(u.seen.untracked() + 1)
    ticking.val = Some(root.at_moment_active(at + second_ms, fn() { tick(at + second_ms) }, later=true, while_covered=true))
  }
  let start_tick = fn(reset_display : Bool) {
    stop_tick()
    if !stats_active.val || !root.alive() {
      return
    }
    let (frames, bytes) = s.came()
    u.rate_frames = frames
    u.rate_bytes = bytes
    if reset_display {
      u.fps = None
      u.bps = None
    }
    let next = ((root.cause_at() / second_ms).floor() + 1.0) * second_ms
    ticking.val = Some(root.at_moment_active(next, fn() { tick(next) }, later=true, while_covered=true))
  }

  let ever_rested = Ref(false)
  root.when_active(while_covered=true, fn() {
    stats_active.val = true
    if @signals.untracked(fn() { s.phase_now() == "live" }) {
      start_tick(ever_rested.val)
    }
    fn() {
      ever_rested.val = true
      stats_active.val = false
      stop_tick()
    }
  })
  |> ignore
  root.reacts(fn() { s.phase_now() == "live" }, fn(live) {
    if live {
      start_tick(false)
    } else {
      stop_tick()
    }
  })
}

///|
/// The view's phase (ScreenSess::phase), followed as the state, the call's failure or its end is told.
fn ScreenSess::phase_now(self : ScreenSess) -> String {
  self.said.get() |> ignore
  self.failure.get() |> ignore
  self.finished.get() |> ignore
  self.phase()
}

///|
/// The serial of what is open of the panel this page opened as `root` (it, or what a step further in from it shows,
/// each presented after it); 0 none.
fn screen_panel_open_from(root : Int) -> Int {
  for n = root; n <= @sf.last_presented(); n = n + 1 {
    if @sf.presented_open_of(n) {
      return n
    }
  }
  0
}

///|
/// Whether the panel this page opened as `id` is up, or one a step further in from it.
fn screen_panel_on(u : ScreenUi, id : String) -> Bool {
  match u.native_panel {
    Some((key, root, _)) => key == id && screen_panel_open_from(root) > 0
    None => false
  }
}

///|
/// Whether the panel this page opened as `id` is up (screen_panel_on), followed as it is opened or closed, here or by
/// its presenter (back, a press outside).
fn screen_panel_on_now(u : ScreenUi, id : String) -> Bool {
  @sf.presenting() |> ignore
  u.panels_told.get() |> ignore
  screen_panel_on(u, id)
}

///|
/// What this page opened over itself closed, and what a step further in from it shows: so it never outlives what it
/// was opened for (the page closed or let go, 全屏, 只看/控制 changed, the keyboard toggled, another of the system bar's
/// actions pressed: the reviewer with pengxiao, 2026-11-12; the system's bars turned to another edge, where the item it
/// was opened at is no longer: screen_native_acts).
fn screen_panels_close(u : ScreenUi) -> Unit {
  center_wait_give_up()
  match u.native_panel {
    Some((_, root, _)) => {
      let open = screen_panel_open_from(root)
      if open > 0 {
        @sf.close_presented_of(open)
      }
    }
    None => ()
  }
  if u.native_panel is Some(_) {
    u.native_panel = None
    u.panels_told.set(u.panels_told.untracked() + 1)
  }
}

///|
/// This page's panel `id` opened by `open` (what it is opened by pressed), what else it opened closed first; where it is
/// up already, closed instead.
fn screen_panel_toggle(u : ScreenUi, id : String, open : () -> Unit) -> Unit {
  let was = screen_panel_on(u, id)
  screen_panels_close(u)
  if was {
    return
  }
  open()
  u.native_panel = Some((id, @sf.last_presented(), @sf.native_side()))
  u.panels_told.set(u.panels_told.untracked() + 1)
}

///|
/// Where an action of the system's bars was pressed, in a window `w` × `h`, for what it opens to stand beside.
fn screen_native_anchor(w : Double, h : Double) -> @sf.Anchor {
  let at = @hostapi.nav_tapped_at
  if at[2] <= 0.0 && @sf.native_side() {
    return At(w - @sf.native_clear(), h / 2.0, 0.0, 0.0)
  }
  let x = if @sf.native_side() { dmin(at[0], w - @sf.native_clear()) } else { at[0] }
  At(x, at[1], at[2], at[3])
}

///|
/// The screen's actions handed to the system's bars (an iPhone Duo's), the least needed last, as the system folds those
/// it has not the room for from the end (the keyboard up, it keeps three): close, 只看/控制, the keyboard, 麦克风 (while
/// something on the screen records it, or this device's is shared), 控制中心, 按键.
/// What else there is is 控制中心's (the reviewer with pengxiao, 2026-11-12). Each but a panel's own closes what this
/// page opened over itself before it acts. Said as the page is in place of the system's tabs (not a tab beside its
/// chat), whole again as what they show changes; what it opened closes as the bars turn to another edge (down the
/// side, or across): the system says where an item is only as it is pressed, so what was opened at it would stay where
/// it was. In 全屏, the bars put away and none said (its tools folded over the picture).
fn screen_native_acts(root : @view.View, pg : ScreenPage, alive : () -> Bool) -> Unit {
  let s = pg.s
  let u = pg.u
  root.reacts(fn() { @sf.native_side() }, fn(side) {
    if u.native_panel is Some((_, _, was)) && was != side {
      screen_panels_close(u)
    }
  })
  root.reacts(
    fn() {
      guard @sf.native_on() else { return None }
      let full = u.full.get()
      Some(
        (
          if full { "" } else { pg.said_title() },
          full,
          s.choosable(),
          s.controlling(),
          s.driving_now(),
          pg.catching(),
          s.open_said(),
          s.simulator(),
          screen_panel_on_now(u, "center"),
          screen_panel_on_now(u, "keys"),
          // (麦克风: whether it is there, shared, and what it says)
          (s.mic_bar_shown(), s.mic_on.get(), s.mic_active_now()),
        ),
      )
    },
    fn(now) {
      guard now is Some((title, full, choosable, on, driving, catching, open, simulator, center_on, keys_on, mic)) else {
        return
      }
      if !@sf.native_over_up(title, alive~) || full {
        return
      }
      @sf.native_over_act("screen-close", @sf.t("android-misc.screen.close"), "close", pg.close, lead=true)
      if choosable {
        // (as mode_button: what it is now, on while driving)
        @sf.native_over_act(
          "screen-mode",
          @sf.t(if on { "android-misc.screen.drive" } else { "android-misc.screen.look" }),
          if on { "cursor" } else { "eye" },
          fn() { control_chosen(s, u, !s.controlling()) },
          active=on,
        )
      }
      if driving {
        @sf.native_over_act("screen-keyboard", @sf.t("android-misc.screen.keyboard"), "keyboard", fn() {
          keyboard_toggled(pg)
        }, active=catching)
      }
      // (as the bars' 麦克风: while something there records it, or this device's is shared)
      if mic is (true, mic_on, _) {
        @sf.native_over_act("screen-mic", @signals.untracked(fn() { s.mic_label() }), if mic_on { "mic" } else { "mic-off" }, fn() { s.toggle_mic() }, active=mic_on)
      }
      if open {
        @sf.native_over_act("screen-center", @sf.t("web-pages.screen.panel"), "sliders", fn() {
          let (w, h) = root.window()
          let from = screen_native_anchor(w, h)
          screen_panel_toggle(u, "center", fn() {
            @sf.panel_nodes(@sf.t("web-pages.screen.panel"), fn(v, done) { center_node(v, s, u, from, pg.close, done) }, from~, side=screen_panel_side(), focus=false)
          })
        }, active=center_on)
      }
      if driving && !simulator {
        @sf.native_over_act("screen-keys", @sf.t("web-pages.screen.keysPanel"), "keycap", fn() {
          let (w, h) = root.window()
          keys_open(s, u, screen_native_anchor(w, h))
        }, active=keys_on)
      }
    },
  )
}

///|
/// Multi-holder visibility lease entry for one subject-keyed screen (`(principal, workspace, station, screen)`).
/// `holders` tracks ONLY real UI holders; `passkey_keepalive` is tracked separately so an in-flight passkey never
/// masquerades as a real UI holder or prevents teardown when all UI hosts and standalone windows permanently close.
priv struct ScreenLease {
  holders : Map[Int, Bool]
  mut ever_had_holder : Bool
  mut passkey_keepalive : Bool
  mut src : Source
  mut dirty : Bool
}

///|
// kept across runs: put back as a run begins (pages.mbt's reset)
let screen_leases : Map[String, ScreenLease] = Map([])

///|
// kept across runs: put back as a run begins (pages.mbt's reset)
let screen_holder_next : Ref[Int] = Ref(0)

///|
// kept across runs: put back as a run begins (pages.mbt's reset)
let screen_lease_settle_queued : Ref[Bool] = Ref(false)

///|
fn screen_lease_visible_count(key : String) -> Int {
  screen_lease_visible_count_except(key, 0)
}

///|
fn screen_lease_visible_count_except(key : String, exclude_holder : Int) -> Int {
  match screen_leases.get(key) {
    Some(lease) => {
      let mut n = 0
      for id, vis in lease.holders {
        if vis && id != exclude_holder {
          n += 1
        }
      }
      n
    }
    None => 0
  }
}

///|
fn screen_leases_schedule_settle() -> Unit {
  if screen_lease_settle_queued.val {
    return
  }
  screen_lease_settle_queued.val = true
  @ui.after_drawn_frame(fn() {
    screen_lease_settle_queued.val = false
    screen_leases_settle()
  })
}

///|
fn screen_lease_apply_hidden(src : Source, key : String) -> Unit {
  guard screen_uis.get(key) is Some(u) else { return }
  u.covered.set(true)
  match screens_open.get(key) {
    Some(s) => s.pause(src)
    None => ()
  }
  if u.sideways_told {
    u.sideways_told = false
    @hostapi.set_sideways(false)
  }
  if u.awake {
    u.awake = false
    @sfbase.keep_awake_by("screen:" + key, false)
    @hostapi.perf_line("app: screen hidden " + key)
  }
  if u.turnable {
    u.turnable = false
    @hostapi.set_turnable(false)
  }
}

///|
/// Bumped whenever any screen session is revoked or a revoked workspace is restored so live mounted `screen_pane_node`
/// and `lone_tree` views re-evaluate against the active principal cleanly.
let screen_revokes : @signals.Signal[Int] = @signals.signal(0)

///|
/// Trackable reader of `screen_revokes` (used by `sfapp`'s `lone_tree` to verify standalone window ownership).
pub fn screen_revokes_now() -> Int {
  screen_revokes.get()
}

///|
fn screen_leases_settle() -> Unit {
  let empty_keys : Array[String] = []
  for key, lease in screen_leases {
    if !lease.dirty {
      continue
    }
    lease.dirty = false
    let held_by_window = match screens_open.get(key) {
      Some(s) => @sfbase.window_has_screen_for_owner(s.account, s.station, s.screen)
      None => false
    }
    // If ALL real UI holders have been permanently destroyed (not merely parked) and no standalone window remains,
    // cancel any in-flight passkey keepalive at batch settle so handoffs (side-panel <-> fullscreen) survive while
    // permanent teardown never leaks.
    if lease.ever_had_holder && lease.holders.is_empty() && lease.passkey_keepalive && !held_by_window {
      match screens_open.get(key) {
        Some(s) => s.passkey_stop()
        None => lease.passkey_keepalive = false
      }
      lease.dirty = false
    }
    let visible = screen_lease_visible_count(key) > 0
    let keep_alive = visible || lease.passkey_keepalive
    if lease.holders.is_empty() && !lease.passkey_keepalive {
      empty_keys.push(key)
    }
    if keep_alive {
      if visible || held_by_window {
        match screens_open.get(key) {
          Some(s) => s.set_passkey_muted(false)
          None => ()
        }
        if visible {
          match screen_uis.get(key) {
            Some(u) => u.covered.set(false)
            None => ()
          }
        }
      } else if lease.passkey_keepalive {
        // Covered/hidden while kept alive solely by passkey keepalive: keep WebAuthn/control alive, but mute audio
        // (both software PCM and native direct audio routing) so background audio never leaks out of sight.
        match screens_open.get(key) {
          Some(s) => s.set_passkey_muted(true)
          None => ()
        }
      }
    } else if !held_by_window {
      screen_lease_apply_hidden(lease.src, key)
      match screens_open.get(key) {
        Some(s) => s.passkey_muted = false
        None => ()
      }
    }
  }
  for key in empty_keys {
    if screen_leases.get(key) is Some(l) && l.holders.is_empty() && !l.passkey_keepalive {
      screen_leases.remove(key)
    }
  }
}

///|
/// Register or update a real UI visibility lease holder for `key`. Settled at end of navigation batch
/// (`@ui.after_drawn_frame`), so side-panel <-> fullscreen <-> `Place("remote")` handoffs keep the stream alive and
/// only pause when the last visible holder leaves.
fn screen_lease_set(src : Source, key : String, holder_id : Int, visible : Bool) -> Unit {
  let lease = match screen_leases.get(key) {
    Some(l) => {
      l.src = src
      l
    }
    None => {
      let l : ScreenLease = { holders: Map([]), ever_had_holder: false, passkey_keepalive: false, src, dirty: false }
      screen_leases[key] = l
      l
    }
  }
  lease.ever_had_holder = true
  if lease.holders.get(holder_id) == Some(visible) {
    return
  }
  lease.holders[holder_id] = visible
  lease.dirty = true
  if visible {
    match screen_uis.get(key) {
      Some(u) => u.covered.set(false)
      None => ()
    }
  }
  screen_leases_schedule_settle()
}

///|
/// Set or clear the request-level passkey keepalive flag on `key` (separate from real UI holders).
fn screen_lease_set_passkey(src : Source, key : String, on : Bool) -> Unit {
  let lease = match screen_leases.get(key) {
    Some(l) => {
      l.src = src
      l
    }
    None =>
      if !on {
        return
      } else {
        let l : ScreenLease = { holders: Map([]), ever_had_holder: false, passkey_keepalive: false, src, dirty: false }
        screen_leases[key] = l
        l
      }
  }
  if lease.passkey_keepalive == on {
    return
  }
  lease.passkey_keepalive = on
  lease.dirty = true
  screen_leases_schedule_settle()
}

///|
/// Remove a real UI holder from the visibility lease table when its `screen_node` is permanently disposed.
/// Passkey keepalive cancellation (if no real UI holders and no standalone window remain) is settled at
/// `@ui.after_drawn_frame` so same-batch handoffs (side-panel <-> fullscreen) keep the passkey alive while permanent
/// teardown never leaks.
fn screen_lease_release(src : Source, key : String, holder_id : Int) -> Unit {
  match screen_leases.get(key) {
    Some(lease) => {
      lease.src = src
      if lease.holders.contains(holder_id) {
        lease.holders.remove(holder_id)
        lease.dirty = true
        screen_leases_schedule_settle()
      }
    }
    None => ()
  }
}

///|
fn screen_revoke_keys(drop_keys : Array[String]) -> Unit {
  if drop_keys.is_empty() {
    return
  }
  for key in drop_keys {
    screen_leases.remove(key)
    match screens_open.get(key) {
      Some(s) => {
        s.revoked = true
        s.heard = false
        s.copied.clear()
        s.close(s.src)
        s.state = None
        s.shown_any = false
        s.size = None
        s.frames = 0
        s.bytes = 0
        s.stream = None
        s.part = None
      }
      None => ()
    }
    match screen_uis.get(key) {
      Some(u) => {
        u.covered.set(true)
        match u.catcher {
          Some(k) => @ui.key_catcher_focus_set(k, false)
          None => ()
        }
        u.held.take() |> ignore
        u.down_with.clear()
        screen_panels_close(u)
        if u.fulled && @ui.full_screen() {
          @hostapi.set_full_screen(false)
        }
        if u.sideways_told {
          u.sideways_told = false
          @hostapi.set_sideways(false)
        }
        if u.awake {
          u.awake = false
          @sfbase.keep_awake_by("screen:" + key, false)
        }
        if u.turnable {
          u.turnable = false
          @hostapi.set_turnable(false)
        }
      }
      None => ()
    }
    screens_open.remove(key)
    screen_uis.remove(key)
  }
  screen_revokes.set(screen_revokes.untracked() + 1)
}

///|
/// Synchronously revoke all screen sessions, holders, frames, clipboard queues, and input belonging to a removed
/// account `old_account`. Other still-signed-in accounts remain untouched.
fn screen_revoke_account(old_account : String) -> Unit {
  let prefix = old_account + "\u{2}"
  let drop_keys : Array[String] = []
  for key, s in screens_open {
    if s.account == old_account {
      drop_keys.push(key)
    }
  }
  for key in screen_uis.keys().collect() {
    if !drop_keys.contains(key) && key.has_prefix(prefix) {
      drop_keys.push(key)
    }
  }
  for key in screen_leases.keys().collect() {
    if !drop_keys.contains(key) && key.has_prefix(prefix) {
      drop_keys.push(key)
    }
  }
  screen_revoke_keys(drop_keys)
}

///|
/// Synchronously revoke screen sessions for workspace `ws` owned by `old_owner` when that workspace's owning account
/// changes. Sessions belonging to other workspaces or accounts remain untouched.
fn screen_revoke_workspace_owner(ws : String, old_owner : String, _new_owner : String) -> Unit {
  let prefix = old_owner + "\u{2}"
  let ws_seg = "\u{2}" + ws + "\u{2}"
  let drop_keys : Array[String] = []
  for key, s in screens_open {
    if s.workspace == ws && s.account == old_owner {
      drop_keys.push(key)
    }
  }
  for key in screen_uis.keys().collect() {
    if !drop_keys.contains(key) && key.has_prefix(prefix) && key.contains(ws_seg) {
      drop_keys.push(key)
    }
  }
  for key in screen_leases.keys().collect() {
    if !drop_keys.contains(key) && key.has_prefix(prefix) && key.contains(ws_seg) {
      drop_keys.push(key)
    }
  }
  screen_revoke_keys(drop_keys)
  if old_owner == "\u{3}revoked" && drop_keys.is_empty() {
    screen_revokes.set(screen_revokes.untracked() + 1)
  }
}

///|
/// Hook for PR-B2s: advance screen `auth_gen` and synchronously revoke all prior-generation screen sessions.
pub fn screen_auth_gen_bump() -> Unit {
  screen_auth_gen.val += 1
  let drop_keys : Array[String] = []
  for key in screens_open.keys().collect() {
    drop_keys.push(key)
  }
  for key in screen_uis.keys().collect() {
    if !drop_keys.contains(key) {
      drop_keys.push(key)
    }
  }
  for key in screen_leases.keys().collect() {
    if !drop_keys.contains(key) {
      drop_keys.push(key)
    }
  }
  screen_revoke_keys(drop_keys)
}

///|
fn screen_leases_reset() -> Unit {
  screen_leases.clear()
  screen_holder_next.val = 0
  screen_lease_settle_queued.val = false
  screen_auth_gen.val = 0
  screen_revokes.set(0)
}

///|
/// Cancel in-flight passkeys belonging to the workspace we just switched away from.
fn screen_workspace_switched(prev_ws : String, _next_ws : String) -> Unit {
  for _, s in screens_open {
    if s.workspace == prev_ws && (s.passkey_run is Some(_) || s.passkey_keepalive_key != "") {
      s.passkey_stop()
    }
  }
}

///|
/// Unconditionally close and tear down screen `key` (marks `revoked` and clears pending clipboard queue so late RPC
/// callbacks such as `screen.screenshot` can never write to the device clipboard after permanent close).
fn screen_left_force(src : Source, key : String) -> Unit {
  match screens_open.get(key) {
    Some(s) => {
      s.revoked = true
      s.copied.clear()
      s.close(src)
    }
    None => ()
  }
  match screen_uis.get(key) {
    Some(u) => {
      screen_panels_close(u)
      if u.fulled && @ui.full_screen() {
        @hostapi.set_full_screen(false)
      }
      if u.sideways_told {
        @hostapi.set_sideways(false)
      }
      if u.awake {
        @sfbase.keep_awake_by("screen:" + key, false)
        @hostapi.perf_line("app: screen closed " + key)
      }
      if u.turnable {
        @hostapi.set_turnable(false)
      }
    }
    None => ()
  }
  screen_leases.remove(key)
  screens_open.remove(key)
  screen_uis.remove(key)
}

///|
/// The view's page gone for a captured `key`: the view, its decoder and its files let go of; upright (held upright only
/// again) and asleep again. Kept alive if another real visible UI holder or standalone window of the same owner still
/// displays the same screen.
pub fn screen_left_key(
  src : Source,
  key : String,
  station : String,
  screen : String,
  excluding_holder? : Int = 0,
  leaving_holder_released? : Bool = false,
) -> Unit {
  let owner = match screens_open.get(key) {
    Some(s) => s.account
    None => screen_owner_of(station)
  }
  let other_visible = if excluding_holder > 0 {
    screen_lease_visible_count_except(key, excluding_holder) > 0
  } else if leaving_holder_released {
    screen_lease_visible_count(key) > 0
  } else {
    screen_lease_visible_count(key) > 1
  }
  if other_visible || @sfbase.window_has_screen_for_owner(owner, station, screen) {
    match screen_uis.get(key) {
      Some(u) => {
        screen_panels_close(u)
        if u.fulled && @ui.full_screen() {
          @hostapi.set_full_screen(false)
        }
      }
      None => ()
    }
    return
  }
  screen_left_force(src, key)
}

///|
/// The view's page gone: the view, its decoder and its files let go of; upright (held upright only again) and asleep
/// again. Kept alive if another visible holder or standalone window still displays the same screen.
pub fn screen_left(src : Source, station : String, screen : String) -> Unit {
  screen_left_key(src, screen_key(station, screen), station, screen)
}

///|
/// A window of this run beside the first closed on page `p` (sfbase's window_page_left): look up by the window's
/// creation `owner` so a subject switch cannot alias or close a new owner's session. If no real UI holder or other
/// standalone window of `owner` remains, cancel any in-flight passkey and close the screen cleanly.
fn screen_window_left(p : @sfbase.Page, owner : String) -> Unit {
  if p is Terminal(tat) {
    terminal_left(tat.station, tat.terminal)
    return
  }
  guard p is Screen(at) else { return }
  let key = screen_key_for_owner(owner, at.station, at.screen)
  if screen_lease_visible_count(key) > 0 || @sfbase.window_has_screen_for_owner(owner, at.station, at.screen) {
    return
  }
  match screens_open.get(key) {
    Some(s) => {
      s.passkey_stop()
      screen_left_force(s.src, key)
    }
    None => ()
  }
}

///|
/// Page `p` given to window `wid` of this run as it opens (sfbase's window_page_given): a screen's pictures that
/// window's from then on, so the page it leaves here, going, neither takes them back nor hides them there.
fn screen_window_given(p : @sfbase.Page, wid : Int, owner : String) -> Unit {
  guard p is Screen(at) else { return }
  match screens_open.get(screen_key_for_owner(owner, at.station, at.screen)) {
    Some(s) =>
      for st in [s.stream, s.part] {
        match st {
          Some(st) => st.given_to_window(wid)
          None => ()
        }
      }
    None => ()
  }
}

///|
fn init {
  @sfbase.window_page_left.val = screen_window_left
  @sfbase.window_page_given.val = screen_window_given
}

// ── what goes between the device and the screen ─────────────────────────

///|
/// What is done with the answer of a call to the screen: its failure said as 无法<what>：<why>.
fn screen_act(what : String) -> (Result[Json, Json]) -> Unit {
  fn(r) {
    match r {
      Ok(_) => ()
      Err(e) => toast_later(@sf.t("android-misc.act.failed", args=[("what", what), ("error", error_words(e))]))
    }
  }
}

///|
/// The copies made on the screen: onto the device's clipboard, text as it is, a picture as a PNG (the latest copy wins).
/// Where the system says so itself (Android 13 and later, with a preview), nothing more; else it is said here.
fn screen_copies(s : ScreenSess) -> Unit {
  if !s.is_active_principal() {
    s.copied.clear()
    return
  }
  if s.copied.is_empty() {
    return
  }
  let got = s.copied.copy()
  s.copied.clear()
  let label = match opt_text(s.state, "title") {
    Some(t) if t != "" => t
    _ => @sf.product()
  }
  let types = s.clip_types()
  for g in got {
    match g {
      // marked by a password manager there (its words concealed, or not to be kept): the device's copy marked a secret
      // too, out of its clipboard's history and managers; a concealed one taken off as a secret copied here is
      // (@sf.secret_copied_life), a transient one left (only its history skips it). Its other marks (`auto`: words an app
      // made up) as any words.
      CopiedText(t, Some("concealed")) => {
        @ui.clipboard_secret(t, clear_ms=@sf.secret_copied_life)
        if !@ui.copy_shown() {
          toast_later(@sf.t("android-misc.screen.copied"))
        }
      }
      CopiedText(t, Some("transient")) => {
        @ui.clipboard_secret(t, clear_ms=0.0)
        if !@ui.copy_shown() {
          toast_later(@sf.t("android-misc.screen.copied"))
        }
      }
      CopiedText(t, _) => {
        @ui.clipboard_set(t, label~)
        if !@ui.copy_shown() {
          toast_later(@sf.t("android-misc.screen.copied"))
        }
      }
      // only from a screen that says it carries pictures (a station from before them sends none)
      CopiedPng(b) =>
        if types.contains("png") {
          @ui.clipboard_set_png(b, label~)
          if !@ui.copy_shown() {
            toast_later(@sf.t("android-misc.screen.copiedImage"))
          }
        }
    }
  }
}

///|
/// The device's clipboard (`got`), pasted into the screen where its focus is: its picture as PNG where the screen
/// carries pictures, else its text. Asked of the system as the button is tapped (paste_asked), taken here once it
/// answers. Asked by ⌘V (Ctrl+V) where the screen carries no clipboard (a tab of the station's browser, a device's): its
/// text typed there, or with none the key itself sent, the screen pasting its own. A paste asked meanwhile, asked next.
fn screen_pasted(s : ScreenSess, u : ScreenUi, got : @ui.Clipboard) -> Unit {
  guard s.is_active_principal() else {
    u.paste_from_key = None
    u.paste_owed = None
    s.pasting.set(false)
    return
  }
  let from_key = u.paste_from_key
  u.paste_from_key = None
  let finish = fn() {
    s.pasting.set(false)
    match u.paste_owed {
      Some(next) => {
        u.paste_owed = None
        paste_asked(s, u, from_key=next)
      }
      None => ()
    }
  }
  match from_key {
    Some((key, mods)) => {
      if got.text != "" {
        type_into(s, u, got.text)
      } else {
        paste_key_sent(s, key, mods)
      }
      finish()
      return
    }
    None => ()
  }
  let types = s.clip_types()
  let image = !(got.picture is NoPicture)
  let words = got.text
  let what = @sf.t("android-misc.screen.pasteWhat")
  let done = fn(r : Result[Json, Json]) {
    finish()
    (screen_act(what))(r)
  }
  let kind = if image && types.contains("png") {
    "image"
  } else if words != "" && types.contains("text") {
    "text"
  } else if image && words == "" {
    "no-images"
  } else if words != "" {
    "no-text"
  } else {
    "empty"
  }
  let said = fn(key : String) {
    finish()
    toast_later(@sf.t(key))
  }
  match kind {
    "image" =>
      match got.picture {
        Png(png) if png.length() <= clip_png_max => s.paste_png(s.src, png, done)
        Png(_) | TooLarge => said("android-misc.screen.imageTooLarge")
        _ => said("android-misc.screen.imageUnread")
      }
    "text" => s.paste(s.src, words, done)
    "no-images" => said("android-misc.screen.noImages")
    "no-text" => said("android-misc.screen.noText")
    _ => said("android-misc.screen.clipboardEmpty")
  }
}

///|
/// ⌘V (Ctrl+V) itself, down and up with `mods`: the screen pastes what it has of its own.
fn paste_key_sent(s : ScreenSess, key : String, mods : Int) -> Unit {
  s.input(s.src, key_input("down", key, "KeyV", mods))
  s.input(s.src, key_input("up", key, "KeyV", mods))
}

///|
/// `words` typed on the screen as the keyboard types them (screen_keys_in's Text), with the modifiers held on the keys
/// row.
fn type_into(s : ScreenSess, u : ScreenUi, words : String) -> Unit {
  let sent : Array[Json] = []
  type_words(fn(j) { sent.push(j) }, u.held, words)
  for j in sent {
    s.input(s.src, j)
  }
  // (no paste on Xcode 27's yet, the keys; said when it is what was just typed)
  if s.simulator() && text(s.state, "title").contains("iOS 27") && words.iter().any(fn(ch) { ch.to_int() > 0x7e }) {
    toast_later(@sf.t("web-pages.screen.debug.keysNote"))
  }
}

///|
/// 粘贴手机剪贴板 tapped (or ⌘V): the device's clipboard read (the system answers; screen_pasted takes it). `from_key`:
/// ⌘V's key and modifiers where the screen carries no clipboard (screen_pasted). Asked while one is under way, asked
/// again as that one is done, not lost.
fn paste_asked(s : ScreenSess, u : ScreenUi, from_key? : (String, Int)? = None) -> Unit {
  if s.pasting.untracked() {
    u.paste_owed = Some(from_key)
    return
  }
  match @ui.clipboard_read() {
    Some(r) => {
      u.paste_from_key = from_key
      s.pasting.set(true)
      u.reading.set(Some(r))
    }
    None =>
      match from_key {
        Some((key, mods)) => paste_key_sent(s, key, mods)
        None => toast_later(@sf.t("android-misc.screen.clipboardEmpty"))
      }
  }
}

///|
/// 发送文件 tapped: the system's picker, the files it gives going where the state says now.
fn send_asked(s : ScreenSess) -> Unit {
  guard s.drops_to() is Some(to) else { return }
  if @ui.pick(Files, on_got=fn(files) { if !files.is_empty() { s.send_files(files, to) } }) is None {
    toast_later(@sf.t("android-chat.composer.noFiles"))
  }
}

///|
/// 安装 App tapped: the system's picker, what it gives going up to be installed on the device.
fn install_asked(s : ScreenSess) -> Unit {
  let folder = text(s.state, "install")
  guard folder != "" else { return }
  let to : DropTo = { folder, reveal: false, install: true }
  if @ui.pick(Files, on_got=fn(files) { if !files.is_empty() { s.send_files(files, to) } }) is None {
    toast_later(@sf.t("android-chat.composer.noFiles"))
  }
}

///|
/// Trackpad or direct, said as it is chosen: how a finger drives it now. A trackpad starts where the screen's pointer is.
fn pad_chosen(s : ScreenSess, u : ScreenUi, on : Bool) -> Unit {
  if on {
    u.pad.start_at(s.cursor())
  }
  toast_later(@sf.t(if on { "android-misc.screen.padOn" } else { "android-misc.screen.padOff" }))
  s.choose_pad(s.src, on, screen_act(@sf.t("android-misc.screen.touchWhat")))
}

///|
/// 只看 or 控制, chosen.
fn control_chosen(s : ScreenSess, u : ScreenUi, on : Bool) -> Unit {
  screen_panels_close(u)
  s.wants_control = Some(on)
  s.control(s.src, on)
}

///|
/// What the keyboard sends (the key catcher's: committed words, named keys and shortcuts as taps), as the screen takes
/// it, with the modifiers held on the keys row: words typed with one held go as keys with it, a key goes down with them
/// and up with what it went down with. At the input's moment.
fn screen_keys_in(pg : ScreenPage, k : @ui.KeyIn) -> Unit {
  let s = pg.s
  let u = pg.u
  let send = fn(j : Json) { s.input(s.src, j) }
  match k {
    Text(words) => type_into(s, u, words)
    // the pointer held for an app there let go of by the person's own keys (⌃Esc, ⌃⌥⇧Q), whatever the app does
    Key(down~, code~, mods~, ..) if screen_lock_keys(u.mouse, code, mods, down) => ()
    // a browser's own keys on a tab of the station's browser (⌘L, ⌘T, ⌘W, ⌘R, ⌘[, ⌘]): the viewer's, as a browser's
    Key(down~, code~, mods~, ..) if browser_key(s, u, code, mods, down) => ()
    Key(down~, key~, code~, mods~) => {
      let (mapped_key, mapped_code, mapped_mods) = remap_screen_key(s, key, code, mods)
      // ⌘V (Apple) or Ctrl+V (Windows/Linux/Android): this device's clipboard onto the screen's and pasted there,
      // where it carries one, as a paste is on the web's page (its keys are not sent); where it carries none, its text
      // typed there (what a voice input put on the clipboard and pasted). Its V let go of after ⌘/Ctrl, taken here too.
      if (down && is_paste_key(s, mapped_code, mods, mapped_mods)) || (!down && u.pasted_v && code == "KeyV") {
        if down {
          u.pasted_v = true
          let held_mods = mapped_mods | u.held.take()
          paste_asked(s, u, from_key=if s.pastes() { None } else { Some((mapped_key, held_mods)) })
        } else {
          u.pasted_v = false
        }
        return
      }
      if down {
        let extra = u.held.take()
        u.down_with[code] = (mapped_key, mapped_code, mapped_mods, extra)
        send(key_input("down", mapped_key, mapped_code, mapped_mods | extra))
      } else {
        let (up_key, up_code, up_mods) = match u.down_with.get(code) {
          Some((dk, dc, dm, extra)) => {
            u.down_with.remove(code)
            (dk, dc, (if dc != mapped_code { dm } else { mapped_mods }) | extra)
          }
          None => (mapped_key, mapped_code, mapped_mods)
        }
        send(key_input("up", up_key, up_code, up_mods))
      }
    }
  }
}

///|
/// The keyboard taken or let go (ScreenViewer.kt keyboard()): by whether the keys go to the screen (`catching`), not
/// whether the soft keyboard is up (none with a keyboard plugged in, or put away by the system with the keys still
/// here).
fn keyboard_toggled(pg : ScreenPage) -> Unit {
  let u = pg.u
  screen_panels_close(u)
  let catching = @signals.untracked(fn() { pg.catching() })
  match u.catcher {
    Some(k) => @ui.key_catcher_focus_set(k, !catching)
    None => ()
  }
  // (upright, the foot is the keyboard's row from now till it is put away again: a key of it pressed takes nothing
  // from it)
  u.typing.set(!catching)
}

///|
/// The screens open as the device's performance record says them (@ui.perf_also "screens"): each its codec and size,
/// the 帧率 and 画质 asked, the frames and bytes that came since last asked (as 控制中心's 连接 counts them: ScreenSess::came),
/// over `span` ms; "" where none is open.
pub fn screens_perf(span : Double) -> String {
  let line = StringBuilder()
  for key, s in screens_open {
    let (frames, bytes) = s.came()
    let (f0, b0) = screens_perf_was.get(key).unwrap_or((frames, bytes))
    screens_perf_was[key] = (frames, bytes)
    let secs = (if span > 1.0 { span } else { 1.0 }) / 1000.0
    let size = match s.size {
      Some((w, h)) => "\{w}x\{h}"
      None => "-"
    }
    line.write_string(
      (if line.is_empty() { "" } else { " | " }) +
      "\{s.codec.unwrap_or("-")} \{size} asked=\{s.asked}/\{s.asked_fps}fps fps=\{((frames - f0).to_double() / secs).round()} kbps=\{((bytes - b0).to_double() * 8.0 / 1000.0 / secs).round()} phase=\{s.phase()}",
    )
  }
  for key in screens_perf_was.keys().collect() {
    if !screens_open.contains(key) {
      screens_perf_was.remove(key)
    }
  }
  line.to_string()
}

///|
/// Each open screen's frames and bytes as screens_perf last said them, by its key.
// kept across runs: the record's counts, put back as a screen closes (screens_perf)
let screens_perf_was : Map[String, (Int, Int)] = Map([])
