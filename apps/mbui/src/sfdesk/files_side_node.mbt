// The files' sidebar (still.fail web/src/pages/FilesNav.tsx) made once over the block (side_node's): its band (Pin
// 文件夹, the app's update at its end where one is offered), then the files' places (sfpages' files_places_node.mbt): the
// person's own folders kept at hand, then every station of the workspace with a drive, opened to its places. A row
// opens its folder in the side in front; something dragged onto one goes into it, and a folder dragged onto 个人收藏 is
// kept there.

///|
/// The files' sidebar in node `s` as wide as the sidebar, where `at` says the block has it: of the workspace in view as
/// it changes.
fn files_side_node(s : @view.View, src : Source, tips : @sf.TipLayer, at : () -> SideAt) -> Unit {
  let workspace = fn() { @sfbase.workspace_in_view(src).0 }
  let list_at = side_list_at(@signals.untracked(at))
  let band_at = fn() {
    let a = at()
    ({ brand: a.brand, band: a.band, tape: a.tape, in_bar: a.bar, roots: @ui.tree_corner_roots_now() } : BandAt)
  }
  // (while the app's first page waits for what it shows: drawn at none, the splash in its place, as the old views are)
  s
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  .alpha(By(fn() { if @sfbase.first_page_waits.get() { 0.0 } else { 1.0 } }))
  .takes_unseen(Is(true))
  |> ignore
  s.pick(fn() { workspace().map(fn(w) { w.id }) }, fn(q, id) {
    q.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    guard id is Some(ws) else { return }
    side_top_node(q, fn() { at().brand })
    // its band: Pin 文件夹, on one station there is or one chosen first; the app's update at its end
    // (who may pin a folder and where, followed as the band shows: its press offers those, nothing where there is none)
    q.reacts(fn() { @sfpages.favorite_stations(src, ws).length() }, fn(_) {  }) |> ignore
    q.box(fn(band) {
      // (in the tape's corner as 新建对话's band is, whether an update is offered at its end or not)
      @sf.style_node(band, fn() {
        let a = band_at()
        if a.tape {
          band_new_tape(at=a)
        } else {
          band_new_pane(at=a)
        }
      })
      band.box(fn(full) {
        @sf.style_node(full, fn() { side_full }, in_row=true)
        @sf.band_row_node(
          full,
          fn() { false },
          fn() { @sf.t("web-pages.files.addFavorite") },
          fn() {
            let can = @sfpages.favorite_stations(src, ws)
            if can.length() > 0 {
              @sfpages.add_favorite_folder(src, ws, can)
            }
          },
          list_at,
          fn(r) {
            @sf.icon_node(r, "plus", @signals.untracked(fn() { @sf.theme().chat_list.band_icon }), By(fn() { @sf.theme().p.text })) |> ignore
            @sf.words_node(r, fn() { @sf.t("web-pages.files.addFavorite") }, fn() { @sf.theme().chat_list.band_words }) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
      band.show(update_shown, at_once=true, fn(u) {
        @sf.update_key_node(
          u,
          tips,
          update_key_side,
          update_key_mark,
          fn() { update_said().0 },
          fn() { update_said().1 },
          fn() { update_said().2 },
          fn() {
            match update_now() {
              Coming(_, part) => Some(part)
              _ => None
            }
          },
          fn() { update_pressed(src) },
          offered=fn() { update_now() is Offered(_, ..) },
        )
      })
      // (no update offered: its room kept, as 新建对话's band keeps its filter's, so its row ends where it does, clear of
      // the panel's corner the key at its end is concentric with)
      band.show(fn() { !update_shown() }, at_once=true, fn(k) {
        k.width(Is(Some(update_key_side))).height(Is(Some(update_key_side))).shrink(Is(0.0)) |> ignore
      })
    })
    |> ignore
    // the places: a folder chosen there opened in the page (on the tape brought over to show it); what the page left
    // read handed to the one opened (open_handing_held)
    // (in from its sides by its lines' own room, list_line's, as the archive's side is: not the box's as well)
    // (the rest of the sidebar under the band, not as tall as its rows: shrunk from none, so the list scrolls all of
    // them, as place_side_node's list does)
    q.box(fn(l) {
      l.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
      @sfpages.files_places_node(l, src, ws, list_at, top=fn() { files_side_top }, foot=fn() { 0.0 }, go=fn(to) {
        @sfbase.open_handing_held(fn() { files_go(to) })
        @sfbase.show_chosen()
      }, tips~)
    })
    |> ignore
  })
}

///|
/// The places 4 under the band (Sidebar.css.ts navList).
let files_side_top : Double = 4.0

///|
/// A folder opened from the files' page or its sidebar: on the tape over the page in use (a folder in it, its path),
/// back coming to the folder it was opened from (page_goes_on); else in the side in front, in place of what was open
/// (the stack's page above the files' place); in a chat's 文件 tab while it is built, there.
pub fn files_go(at : DriveAt) -> Unit {
  if tab_building() {
    tab_go(at)
    return
  }
  @sfbase.history_push()
  if page_goes_on() {
    if !(app.nav.top() is Drive(here) && here == at) {
      app.nav.push_over(Drive(at))
    }
    return
  }
  app.nav.replace_above(1, [Drive(at)])
}
