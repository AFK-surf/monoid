// The app's sheets, one at a time: each the library's panel of nodes (@sf.panel_nodes, src/sf presenters.mbt), with
// a finger the phone's sheet, its share of the screen, a draggable one between half (55%) and nearly all (94%); with a
// mouse beside what opened it, or in the middle of the window. What it shows is its kind's (SheetKind), made once as
// nodes of the window's tree as it opens (sheet_body_node), each part bound to what it shows.

///|
/// Which sheet: what it shows and how it sits.
#derive(Eq)
priv enum SheetKind {
  NoSheet
  /// what another app shares in, to a chat (the web's mobile/ShareIn.tsx; ShareIn.tsx's panel, 520 wide, with a wide
  /// window): as tall as what it holds
  ShareSheet
  /// what an invitation's link leads to, before it is accepted: half the screen
  InviteLink
  /// a station's login opened from its link (/w/<ws>/s/<station>/login/<id>): as tall as its card
  LoginLink
}

///|
/// How a sheet sits: its share of the screen at first, whether its top drags it between half and full.
fn sheet_spec(kind : SheetKind) -> (Double, Bool) {
  match kind {
    ShareSheet => (0.0, false)
    InviteLink => (0.5, false)
    LoginLink => (0.0, false)
    NoSheet => (0.5, false)
  }
}

///|
/// The sheet up (NoSheet: none), and the presenter it is (@sf.last_presented).
priv struct SheetHost {
  mut kind : SheetKind
  mut serial : Int
}

///|
let sheet_host : SheetHost = { kind: NoSheet, serial: 0 }

///|
/// The source the sheets show what they show of (the app's tree's: told as that is made, app_tree), read as a sheet's
/// nodes are made.
// kept across runs: told anew as each app's tree is made, before a sheet is
let sheet_src : Ref[Source?] = Ref(None)

///|
/// Opens `kind` (in place of one open), by what opened it: the library's panel of nodes (@sf.panel_nodes), as tall as
/// its share of the window (a sheet with a finger, beside `from` or in the middle of the window with a mouse), what it
/// shows made as it opens (sheet_body_node). What was typed lets go of the keyboard first. `title`: its title (the
/// login's; the invitation's says its own as it changes, what is shared heads itself).
fn raise_sheet(
  kind : SheetKind,
  from? : @sf.Anchor = Unanchored,
  title? : String = "",
) -> Unit {
  lower_sheet()
  let s = sheet_host
  s.kind = kind
  let (share, draggable) = sheet_spec(kind)
  // (its title as it is now: the invitation's as what it leads to is read; the others' as said, what is shared none)
  let live = match kind {
    InviteLink => fn() { (sheet_src.val.map_or("", invite_title), "", "") }
    _ => fn() { (title, "", "") }
  }
  @sf.panel_nodes(
    title,
    fn(v, close) { sheet_body_node(v, kind, close) },
    from~,
    tall=share,
    grows=draggable,
    // (the invitation in the middle of the window as tall as what it says, no taller; a sheet on 小屏 half the window)
    hugs_centred=kind == InviteLink,
    live~,
    w=if kind == ShareSheet { share_panel_w } else { @sf.panel_w },
    // (what is shared in the app, on 中屏 and 大屏: 14% down the window, over its night, no close button, as ⌘K's panel
    // (sfdesk switcher.mbt); a sheet on 小屏; over another app a dialog in its middle)
    top_share=if kind == ShareSheet && !share_over.get() { share_panel_top_share } else { 0.0 },
    gone=fn() {
      if s.kind == kind {
        s.kind = NoSheet
      }
    },
  )
  s.serial = @sf.last_presented()
}

///|
/// What sheet `kind` shows in node `v` (its panel's body), of the app's source (sheet_src): what is shared, an
/// invitation, a login of the workspace in view (made again as that changes).
fn sheet_body_node(v : @view.View, kind : SheetKind, close : () -> Unit) -> Unit {
  ignore(close)
  guard sheet_src.val is Some(src) else { return }
  match kind {
    ShareSheet => share_sheet_node(v, src)
    InviteLink => invite_node(v, src)
    LoginLink =>
      v.pick(fn() { workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(p, id) {
        guard id is Some(_) && @signals.untracked(fn() { workspace_in_view(src).0 }) is Some(w) else { return }
        login_node(p, src, w)
      })
    NoSheet => ()
  }
}

///|
/// Closes the sheet open: it sinks away.
fn lower_sheet() -> Unit {
  if sheet_host.kind != NoSheet {
    sheet_host.kind = NoSheet
    @sf.close_presented_of(sheet_host.serial)
  }
}

///|
/// Whether a sheet is open.
fn sheet_open() -> Bool {
  // (its kind changes with the presenter it is, opened or let go in the same change: followed by what follows that)
  @sf.presenting() |> ignore
  sheet_host.kind != NoSheet
}

///|
/// What another app shares, its panel's width with a wide window.
let share_panel_w : Double = 520.0

///|
/// How far down the window what is shared stands in the app (⌘K's panel's).
let share_panel_top_share : Double = 0.14

///|
/// How what is shared is laid out where node `v` is made: as a sheet on 小屏 (a narrow look), as the wide panel in a
/// dialog in the middle of the window on 中屏 and 大屏 (a wide one), as the presenters show the sheet there.
fn share_look_of(v : @view.View) -> ShareLook {
  if @sf.layout(v.window_w()) is Small {
    share_narrow
  } else {
    share_wide_look
  }
}
