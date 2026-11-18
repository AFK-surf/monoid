// The settings as the desktop has them (SettingsNav): the sidebar of
// their pages by where they act, and the page picked beside it: the desktop's own ported from the web's (account.mbt,
// notifications.mbt, …, in settings_page.mbt's frame), the others the settings' package's (src/sfapp/settings) in the
// wide frame's scale until they are ported. What both read and call (the core's calls, the models) is that
// package's, once.

///|
/// The settings page `route` in the pane.
fn setting_page(c : @ui.Ctx, src : Source, w : Workspace, route : Route) -> Unit {
  let core = settings_core(src, w)
  let here = @settings.here_of(core, w.id, w.name)
  // a page under another of them shows back (the sidebar is the way to the others)
  let under = app.nav.under()
  let deep = under is Some(Setting(_))
  settings_deep.val = deep
  // (the settings' pages not ported yet read it too)
  @settings.wide_deep.val = deep
  @settings.frame(core, here)
  settings_fixture(src, core)
  @settings.page(c, core, here, route)
}

///|
/// Whether the settings page drawn is under another of them (its head's back shown).
// kept across runs: said again by every settings page as it is drawn (setting_page)
let settings_deep : Ref[Bool] = Ref(false)

///|
/// A dialog a fixture's mode puts up over its page (MBUI_FIXTURE=settings-policy-text, settings-security-join, …:
/// @settings.fixture_desk), once the page is drawn with what it needs; before it is made where a frame makes it once
/// (pane_made, tape_made, the narrow frame's).
pub fn settings_fixture(src : Source, core : Core) -> Unit {
  match @settings.fixture_desk() {
    "policy-text" => @sfpages.fx_policy_up.val = "text"
    "policy-option" => @sfpages.fx_policy_up.val = "option"
    "lock-join" => join_dialog(core, "ws1", "st2", "Maple")
    "lock-off" => turn_off_dialog(core, "ws1", "星火工作室")
    "local-fonts" => @sfpages.fx_local_up.val = true
    "connect-mode" =>
      // (the first connect listed, as its page has it: the ways it could change are its page's)
      match items((core.topic)("connects", { "scope": str("ws1"), "mine": Json::boolean(false) }).get().value, "items") {
        [row, ..] => {
          let station = text(Some(row), "station")
          let here = @settings.here_of(core, "ws1", "星火工作室")
          match @settings.connect_of(core, here, station, text(field(Some(row), "connect"), "id")) {
            Some(_) as item => @sfpages.cd_mode_dialog(core, station, item)
            None => ()
          }
        }
        _ => ()
      }
    "new-connect" => @sfpages.new_connect_dialog(src, core, @settings.here_of(core, "ws1", "星火工作室"), "ws1/st1")
    "vault-add" => @sfpages.fx_vault_add_up.val = true
    "vault-editor" => @sfpages.vault_editor_dialog(core, "ws1", "v1", None, kind="token")
    "vault-recover" => @sfpages.vault_recover_dialog(core, "ws1")
    "copies-confirm" =>
      match items(@settings.fixture_copies(), "offers") {
        [copy, ..] => @sfpages.copies_restore_confirm(core, "ws1/st1", Some(copy))
        _ => ()
      }
    // (Willow's retirement asked: its ⋯'s 迁走聊天并移出工作区's panel, what it would take along as Willow says it)
    "retire-panel" =>
      @sfpages.station_retire_panel(
        core,
        @settings.here_of(core, "ws1", "星火工作室"),
        Some({ "station": Json::string("ws1/st1"), "name": Json::string("Willow") }),
        @settings.fixture_retire_preview(),
      )
    // (Willow's 全部迁移 asked: its ⋯'s, over its page of 迁移, Maple chosen)
    "move-all" =>
      @sfpages.station_move_all_confirm(core, "ws1/st1", @settings.move_of(core, "ws1/st1", "st2", "").value, false)
    _ => ()
  }
}

///|
/// What the settings pages here keep put back as the app begins anew.
fn settings_reset() -> Unit {
  settings_deep.val = false
}

///|
/// The settings' sidebar made once as nodes in `s` (as wide as the sidebar), where `at` says the block has it: its top
/// row, back to the chats in the band over the list (none beside the system's tabs: 对话 is one of them, rail_native.mbt)
/// and the update beside it where one is offered, the search, then the settings' list (sfpages' settings_list.mbt: the
/// same rows in the same groups as a small screen's settings page) scrolling under them, the row of the page beside
/// it lit; a row pressed, its page beside it, in place of the one there. For the workspace in view, made again for
/// another.
fn settings_side_node(s : @view.View, src : Source, tips : @sf.TipLayer, at : () -> SideAt) -> Unit {
  let workspace = fn() { @sfbase.workspace_in_view(src).0 }
  let list_at = side_list_at(@signals.untracked(at))
  let band_at = fn() {
    let a = at()
    ({ brand: a.brand, band: a.band, tape: a.tape, in_bar: a.bar, roots: @ui.tree_corner_roots_now() } : BandAt)
  }
  let lit = fn() {
    match app.nav.top() {
      Setting(r) => Some(r)
      // (the settings come to: their first row's page, settings_landing)
      Settings => Some(settings_landing)
      _ => None
    }
  }
  // (while the app's first page waits for what it shows: drawn at none, the splash in its place, as the old views are)
  s.grow(Is(1.0)).min_height(Is(Some(0.0))).alpha(By(fn() { if @sfbase.first_page_waits.get() { 0.0 } else { 1.0 } }))
  |> ignore
  s.switch_by(fn() { workspace().map(fn(w) { w.id }) }, fn(q, _id) {
    q.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    guard @signals.untracked(workspace) is Some(w) else { return }
    let core = settings_core(src, w)
    let here = fn() { @settings.here_of(core, w.id, w.name) }
    side_top_node(q, fn() { at().brand })
    // The way back belongs to the sidebar's band, not to the list that scrolls beneath it.
    q.pick(fn() { (update_shown(), @sf.native_on()) }, fn(b, shown) {
      let (updating, native) = shown
      if updating {
        // The update and the back action share the same band as the other sidebars' actions: the band's spacing gives
        // each key its press room, and keeps the update concentric with the sidebar's corner.
        b.box(fn(band) {
          @sf.style_node(band, fn() { if native { update_band(at=band_at()) } else { update_back_band(at=band_at()) } })
          band.box(fn(full) {
            @sf.style_node(full, fn() { side_full }, in_row=true)
            if !native {
              settings_back_node(full, true, list_at)
            }
          })
          |> ignore
          @sf.update_key_node(
            band,
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
        |> ignore
      } else if !native {
        // (on the tape, the band's action as with the update beside it: in the panel's top corner, concentric with it,
        // as the chats' 新建对话 is there; beside the page the list's own row)
        let tape = list_at is Tape
        b.box(fn(band) {
          @sf.style_node(band, fn() {
            if tape {
              band_new_tape(at=band_at()).then(settings_back_band)
            } else {
              @sf.side_list().then(settings_back_band)
            }
          })
          if tape {
            // (the update's room at its end, where it stands as one is offered: the row kept off the panel's top
            // corner, which the update's round key is concentric with)
            band.box(fn(full) {
              @sf.style_node(full, fn() { side_full }, in_row=true)
              full.box(fn(kept) {
                kept.margin(Is((0.0, 0.0, update_key_side, 0.0))) |> ignore
                settings_back_node(kept, true, list_at)
              })
              |> ignore
            })
            |> ignore
          } else {
            settings_back_node(band, false, list_at)
          }
        })
        |> ignore
      }
    })
    // Without the back row, keep the field below the sidebar's upper corners.
    q.box(fn(k) {
      @sf.style_node(k, fn() { @sf.side_list().then(if @sf.native_on() { settings_search_native_band } else { settings_search_band }) })
      @sfpages.settings_search_node(k, at=list_at, page=false)
    })
    |> ignore
    // the list under the band (side_scroll's): the rows keep their inset; the scroll track belongs to the whole sidebar.
    // What scrolls, and takes the hand, starts at the rail's edge: the sidebar's first 8 reach over the rail's empty
    // side, which its places' keys take; its rows where they were, in from the sidebar's edge
    q.box(fn(from) {
      from.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).margin(Is((side_into_rail, 0.0, 0.0, 0.0))) |> ignore
      from.box(fn(l) {
        @sf.style_node(l, fn() { @sf.side_list().then(@ui.style(px=S0)) })
        l.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        l.scrolls(@view.Scroll::list(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(col) {
          col.box(fn(back) {
            back.margin(Is((-side_into_rail, 0.0, 0.0, 0.0))) |> ignore
            back.box(fn(rows) {
              @sf.style_node(rows, fn() { @sf.theme().chat_list.side_list.then(@ui.style(h=Hug)) })
              // (a row's page in place of the one open; on the tape brought over to show it)
              @sfpages.settings_side_rows_node(rows, core, here, lit, fn(r) {
                @sfbase.history_push()
                app.nav.replace_above(1, [Setting(r)])
                @sfbase.show_chosen()
              }, list_at)
              // (the room under its last)
              rows.box(fn(foot) { foot.height(Is(Some(@sf.list_foot_in(Side)))) |> ignore }) |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// The way back to the chats in `parent` (where the list stands: `at`), a band's action when the update is beside it
/// (`band`); otherwise the settings list's own row.
fn settings_back_node(parent : @view.View, band : Bool, at : @sf.ListAt) -> Unit {
  let label = fn() { @sf.t("web-pages.settings.nav.backToChats") }
  let back = fn() {
    @sfpages.settings_search_reset()
    @sfbase.history_push()
    @sfbase.nav_over_home([])
    wide.landed.set("")
  }
  let body = fn(r : @view.View) {
    @sf.icon_node(r, "arrow-left", settings_nav_icon, By(fn() { @sf.theme().p.muted })) |> ignore
    @sf.nav_words_node(r, label)
  }
  if band {
    @sf.band_row_node(parent, fn() { false }, label, back, at, body)
  } else {
    @sf.action_box_node(parent, label, fn(_) { back() }, fn(r) {
      @sf.style_node(r, fn() { @sf.side_row_at(at).then(settings_back_row).then(@sf.row_least_h()) })
      @sf.nav_ground_node(r, fn() { false })
      body(r)
    })
    |> ignore
  }
}

///|
/// The back row as a sidebar's row of one line (nav_row's): across its middle, as tall as a press takes at least.
// kept across runs: a value (no field of it changes)
let settings_back_row : @ui.Style = @ui.css("align=ACenter")

///|
/// The page the settings come to beside their list on a medium or large screen (the stack's root, the gear pressed):
/// the list's first row's, the account's, as a list's page is the one first in it.
// kept across runs: a value (no field of it changes)
pub let settings_landing : Route = Route::Me

///|
let settings_nav_icon : Double = 16.0


///|
/// The list supplies four points of its own top room; with the band's ten the groups remain fourteen apart.
// kept across runs: a value (no field of it changes)
let settings_back_band : @ui.Style = @ui.css("h=Hug pb=S2_5")

///|
// kept across runs: a value (no field of it changes)
let settings_search_band : @ui.Style = @ui.css("w=Full h=Hug pt=S0 pb=S2")

///|
// kept across runs: a value (no field of it changes)
let settings_search_native_band : @ui.Style = @ui.css("w=Full h=Hug pt=S5 pb=S2")
