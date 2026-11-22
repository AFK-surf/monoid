// 文件 and a station's drive on the phone's stack (sfpages' files_page_node.mbt, files_places_node.mbt): 文件 (the files'
// places, the wide frame's sidebar's list), at the root a place of the bottom bar (its top bar the place's, its ＋ the
// bar's notch: files_lend), pushed a page with back and its ＋ in its bar; a page of a station's drive (a folder, laid
// out by its width), a folder gone into a page pushed over it (or back to it where it is in the stack already).

///|
/// Whether 文件 offers ＋ (another folder pinned: one who may pin, on a station with a drive), for the bottom bar's
/// notch.
pub fn files_can_lend(src : Source, w : Workspace) -> Bool {
  @sfpages.favorite_stations(src, w.id).length() > 0
}

///|
/// ＋ of 文件 (the bottom bar's notch): Pin 文件夹, on the one station there is or one chosen first.
pub fn files_lend(src : Source, w : Workspace) -> Unit {
  @sfpages.add_favorite_folder(src, w.id, @sfpages.favorite_stations(src, w.id))
}

///|
/// 文件 on the phone's stack in `v` of workspace `ws`: its places under the stack's bar (`place`: the top of a place of
/// the bottom bar, its top bar the place's, over it; else a page with back and its ＋ in its bar), in the frame it is
/// given (`frame`: back, the room over and under it).
fn files_narrow_node(
  v : @view.View,
  src : Source,
  ws : String,
  place : Bool,
  frame : () -> PageFrame,
  shown? : () -> Bool = fn() { true },
) -> Unit {
  v.grow(Is(1.0)).min_height(Is(Some(0.0))).ground(By(fn() { @sf.theme().p.bg })) |> ignore
  // (at rest while a page covers it on the stack, as the drive's pages are: sfpages' shown_at_rest)
  @sfpages.shown_at_rest(v, shown, fn(b) { files_narrow_body(b, src, ws, place, frame) })
}

///|
fn files_narrow_body(v : @view.View, src : Source, ws : String, place : Bool, frame : () -> PageFrame) -> Unit {
  if !place {
    @sf.nav_bar_node(
      v,
      fn() { frame().back.unwrap_or(tr("android-settings.title")) },
      fn() { tr("android-misc.bar.place.files") },
      fn() { @sfbase.go_back() |> ignore },
      top=fn() { frame().top },
      trailing_shown=fn() { @sfpages.favorite_stations(src, ws).length() > 0 },
      trailing_pad=4.0,
      trailing=fn(t) {
        t.show(fn() { @sfpages.favorite_stations(src, ws).length() > 0 }, at_once=true, fn(k) {
          @sf.icon_button_node(k, "plus", fn() { @sf.t("web-pages.files.addFavorite") }, fn() {
            @sfpages.add_favorite_folder(src, ws, @sfpages.favorite_stations(src, ws))
          }, icon_size=20.0)
          |> ignore
        })
      },
    )
  }
  // (under the top bar (and the status bar); at the foot 30 over the navigation bar and the bottom bar's room)
  // (a sidebar's list as the wide frame's sidebar has it: its lines in from its sides by list_line's room)
  @sfpages.files_places_node(
    v,
    src,
    ws,
    Side,
    top=fn() { if place { frame().top } else { files_narrow_top } },
    foot=fn() { frame().foot + files_narrow_foot },
    go=fn(at) { open_page(Drive(at)) },
  )
}

///|
/// The places' room under a page's bar (4), and over the navigation bar (30).
let files_narrow_top : Double = 4.0

///|
let files_narrow_foot : Double = 30.0

///|
/// What back over a page of the drive says: the folder under it by its name (its station's, at the drive's own page),
/// 文件, else as back says it elsewhere.
fn drive_back_label(src : Source, w : Workspace, under : Page) -> String {
  match under {
    Drive(d) => {
      let st = dv_stations(src, w.id).0.unwrap_or([]).iter().find_first(fn(s) { s.station == d.station })
      match (st, d.root) {
        (Some(s), Some(_)) => @sfpages.folder_name(s, d)
        (Some(s), None) => s.name
        _ => @sf.t("common.back")
      }
    }
    Files => tr("android-misc.bar.place.files")
    p => @sfbase.back_label(p)
  }
}

///|
/// Back to a folder where it is in the stack (the root as the drive's own page with one root has it is the same page);
/// else it opened there.
fn drive_go_back_to(at : DriveAt) -> Unit {
  let station = at.station
  let root = at.root.unwrap_or("")
  let path = at.path
  let pages = app.nav.pages()
  let mut found = -1
  for i, p in pages {
    match p {
      Drive(d) if d.station == station && d.path == path && (d.root == Some(root) || (d.root is None && path == "")) =>
        found = i
      _ => ()
    }
  }
  if found >= 0 {
    @sfbase.history_push()
    for _ in 0..<(pages.length() - 1 - found) {
      app.nav.pop() |> ignore
    }
  } else {
    open_page(Drive({ station, root: Some(root), path }))
  }
}
