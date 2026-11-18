// The page's pane's stack held by the window's tree (@ui.nav_flat_view: the pane beside the block on Large, the tape's
// page panel on Medium): each page of the stack a node of its own, built the old way in it (its island), as the frame
// drew the stack's page before, or one of the library's made once in it (pane_made: 关于): what waits to be confirmed
// in the workspace's safe mode in its place, else the page moved aside as the folded sidebar is shown a while, its
// words picked by the pointer (a finger picks them as on a phone).

///|
/// Page `page` of the stack in workspace `w`, its island's: `main_w` wide and `ph` high, moved `aside`, as the frame drew
/// the stack's top before.
fn page_one(
  c : @ui.Ctx,
  src : Source,
  w : Workspace,
  page : Page,
  main_w : Double,
  ph : Double,
  aside : Double,
) -> Unit {
  let top = page == app.nav.top()
  // (a chat's bar the page node's, dragging the window itself where nothing of it takes the press:
  // chat_bar_wide_node; the old view's row there would take what is over it)
  if @ui.window_inset() && !(page is Chat(_) && pane_makes.val) {
    title_row(c, "page-title-row", @sf.wide_bar_h + (if wide.tape.get() { @sf.tape_bar_over() } else { 0.0 }))
  }
  c.sized(main_w, ph, fn() {
    let body = fn() {
      let moved = c.box(style=page_aside, tx=aside, fn() {
        // (the page drawn: one on its way out hands no actions to the system's bars)
        drawn_page.val = Some(page)
        if top {
          top_drawn.val = true
        }
        let (now, _, _, _) = @sfbase.workspace_in_view(src)
        main_page(c, src, now.unwrap_or(w), page)
        drawn_page.val = None
      })
      @motion.scope(c, moved, bottom=true)
    }
    c.selectable(color=@sf.alpha(@sf.theme().p.blue, 0.28), body)
  })
}

///|
/// Page `page` of the pane off the tape (Large), its island's (the room the tree leaves the stack beside the block's
/// column): the page's bars' room where the block's move has got (page_bar_room), the page moved aside as the block is
/// shown a while; the top's what the page shows across as it is laid out (fold_peek_shift reads it). `held`: its node
/// holds it at the width the block's move ends at and moves it across and aside (pane_fold_held, chat_page_made's
/// `held`), so it is built as the block is where it goes, never again at each frame of the move.
fn pane_page_one(c : @ui.Ctx, src : Source, page : Page, held? : Bool = false) -> Unit {
  let (now, _, _, _) = @sfbase.workspace_in_view(src)
  guard now is Some(w) else { return }
  let (_, target) = fold_target(src, w, c.window_size().0)
  let f = if held { target } else { fold_built(c, target) }
  fold_bars(c, f)
  // (held, laid out where the move ends from as it sets off: at rest to what it holds, no way of the page's width for
  // its lists to hold their rows on, nothing of it set going for the move)
  if held {
    @sfbase.page_way_said("", 0.0, ends=0.0)
  }
  // (the page shown in the pane, whether the one on top or the one kept while that waits: the one page built here)
  let page_id = c.id("main-page")
  // (said by this build: image_item, video_item)
  @sfbase.held_pictures_waiting.val = []
  fold_goes.page_id = page_id
  // (what the page shows across as it is laid out, its bars left out: where the page moves aside to as the folded
  // sidebar is shown a while, taken as that starts: fold_peek_shift)
  c.shown_across(page_id, but="page-bar") |> ignore
  // a right click in it: what is picked copied (context_menu.mbt)
  context_page(c, page_id)
  let pane = c.box(style=frame_main.then(@ui.style(w=Fixed(c.width))), id=page_id, fn() {
    page_one(c, src, w, page, c.width, c.height, if held { 0.0 } else { f.aside })
  })
  // (what moves in the page of its own takes its place from the page's foot: a keyboard, the block moving the page
  // aside, move none of it)
  @motion.scope(c, pane, bottom=true)
}

///|
/// The stack in the pane off the tape (Large) as a node of `v`'s: each page its island (pane_page_one); a page put in
/// place shown as pane_page_wait says, at its causes; nothing pushed over slides here (shown in place as any other).
/// While the workspace waits to be confirmed in its safe mode, what waits in its place instead, the stack none of it
/// (nothing of it pressed, nothing of it back), as the frame had it before.
fn pane_pages(v : @view.View, src : Source, tips : @sf.TipLayer) -> Unit {
  let gated = fn() {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) => fold_target(src, w, v.window().0).0.gated
      None => false
    }
  }
  // (the page on top switched, as the stack is told it, before any page of it is built; none while what waits in the
  // safe mode is in the pages' place. An old page works out its bars from the block's move as it is built (pane_page_one).
  page_switch_said(v, fn() { @sfbase.workspace_in_view(src).0 is Some(_) && !gated() })
  // (what waits in its place giving back the focus as it goes, to what had it as it came: the page under it kept, laid
  // out nowhere meanwhile (none of it built, pressed or read out), the focus in it let go of then, after it is kept)
  v.show(gated, at_once=true, fn(g) {
    g.grow(Is(1.0)).focus_returns() |> ignore
    pane_gate_node(g, src)
  })
  v.box(fn(s) {
    s.grow(Is(1.0)).laid_nowhere(By(gated)) |> ignore
    pane_stack(s, src, tips)
  })
  |> ignore
}

///|
/// What waits to be confirmed in the workspace's safe mode in the pane off the tape, in node `g` (all of the pane), made
/// once for the workspace in view: on the page's ground, sfpages' page (lock_wait_node); over its top the window's
/// title bar where its buttons are in the app's top row (pane_made_host's), and the workspace's button where the
/// system's tabs are the rail (gate_heading_node).
fn pane_gate_node(g : @view.View, src : Source) -> Unit {
  g.ground(By(fn() { @sf.theme().p.bg })) |> ignore
  g.switch_by(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(p, _id) {
    // (all of the pane, as the page it is in the place of; what waits clear of the column of the system's bars down
    // the window's trailing edge, an iPhone Duo's on its side (@sf.native_clear), the page's ground on under it)
    p.over(Is(true)).padding(By(fn() { (0.0, 0.0, @sf.native_clear(), 0.0) })) |> ignore
    guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
    let core = settings_core(src, w)
    @sfpages.lock_wait_node(p, core, @settings.here_of(core, w.id, w.name)).grow(Is(1.0)) |> ignore
    p.show(fn() { @ui.window_inset() }, fn(t) {
      t
      .over(Is(true))
      .height(Is(Some(@sf.wide_bar_h)))
      .presses(Is(true))
      .moves_window(Is(true))
      |> ignore
    })
    p.show(@sf.native_on, fn(h) {
      h.over(Is(true)) |> ignore
      gate_heading_node(h, src, w)
    })
  })
}

///|
/// The workspace's button (its icon and name in the system's glass: chats.mbt workspace_heading, the bars'
/// workspace-switch) over the top of the page that waits, in node `h` (over all of the pane), where the sidebar's head
/// would have it: the sidebar is not shown while the device waits, and where the rail's places are the system's tabs
/// those hold no workspaces, so with nothing to switch with a person was held in the workspace until a trusted device
/// approved this one (the user, 2026-11-03; the web's SecurityWaiting keeps its WorkspaceSwitcher over the page,
/// cloud/workspace.tsx Bare). The rail has the workspaces where it is the app's own, the narrow frame's Home bar its
/// switch (sfapp lock_gate). Its place handed to the system's glass as it is read out (native_sidebar_items, by its
/// node's id), let go with it.
fn gate_heading_node(h : @view.View, src : Source, w : Workspace) -> Unit {
  let inset = fn() {
    let list = @sf.theme().chat_list
    list.band_in + list.heading_in
  }
  h.box(fn(b) {
    b
    .width(By(fn() {
      Some(dmin(dmax(side_min, wide.side_w.get()), pane_w_at(src, b) - @sf.native_clear() - 2.0 * inset()))
    }))
    .height(By(fn() { Some(@sf.band_row_h()) }))
    .offset(By(fn() { (inset(), side_top_web + band_new_top) }))
    .says(Is(Some(@view.said(Button, label=w.name))))
    |> ignore
    let id = @ui.tree_read_out_id(b)
    native_workspace_hooked()
    b.reacts(fn() { native_workspace_item(src, w) }, fn(item) {
      native_sidebar_items[id] = item
      native_workspace_anchor.val = Node(b)
    })
    b.owns(fn() {
      native_sidebar_items.remove(id)
      match native_workspace_anchor.val {
        Node(n) if n.id() == b.id() => native_workspace_anchor.val = Unanchored
        _ => ()
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// Whether the pane's page of entry `k` shows (Nav::shows), for what it holds put to rest while another covers it in
/// the pane; as it last was while what is on top is over the whole window (a drive's text read, a film played, a
/// station's screen: the pane under it as it was, back to it as it was left), and once its entry has left the stack,
/// let go as it is, never put to rest on the way.
fn pane_shows(k : Int) -> () -> Bool {
  let last = Ref(true)
  fn() {
    if app.nav.page_of(k) is Some(_) && !(app.nav.top() is (Screen(_) | Terminal(_) | DriveRead(_) | DrivePlay(_))) {
      last.val = app.nav.shows(k)
    }
    last.val
  }
}

///|
fn pane_stack(v : @view.View, src : Source, tips : @sf.TipLayer) -> Unit {
  @ui.nav_flat_view(
    v,
    app.nav,
    fn(c, p) { pane_page_one(c, src, p) },
    fn(p) { (fold_goes.ready)(p) },
    fold_goes.most,
    bg=fn() { @sf.theme().p.bg },
    stacks=fn() { false },
    page_for=fn(entry, serial) {
      let retained = @sfbase.page_entry_source(src, entry, serial)
      let page_read = @sfbase.page_chat_reader(retained, entry, serial)
      fn(visible) {
        let shown = src.owned_by(visible)
        fn(c, page) {
          @sfbase.page_entry_read(serial, retained, page)
          page_read(page)
          pane_page_one(c, if page is Chat(_) { retained } else { shown }, page)
        }
      }
    },
    page_key=fn(_) { tape_island_key() },
    // (a page of the library's made once in its place: 关于)
    made=fn(p) { pane_made(src, p, tips) },
    // (which show, as the stack stands whole: the page made once that shows, by its entry)
    shown=fn(ks) { fold_goes.shown = ks },
  )
  |> ignore
}

///|
/// The pages of the library's made once as nodes in the pane off the tape (Large), in the place of their old view
/// (nav_flat_view's `made`): 关于, 记忆, 更新日志, 一台 station 的记忆; 归档, a station's own archiving, 自动决策; 用量,
/// 价目表; a chat (and the new chat that becomes it), its old view in it as yet (chat_page_made). Laid out by the width the frame gives the pane (the window's less the block's column where its move goes:
/// fold_target's, never what the page last laid out), narrow or wide (page_node), each made again only as that
/// arrangement changes. What the old view's island did for the page done by its node (pane_made_host).
fn pane_made(
  src : Source,
  page : Page,
  tips : @sf.TipLayer,
) -> (String, (@view.View, () -> Page, Page?, () -> Int, Int) -> Unit)? {
  // (the stations' and the profiles' places, and a web service not found, have no old view: made so whatever pane_makes
  // says)
  guard pane_makes.val || page is (Place("stations" | "profiles") | Service(_, _)) else { return None }
  // (made in the workspace in view, its settings' core, under what it was opened from, as wide as the frame gives it)
  let made_k = fn(
    kind : String,
    f : (@view.View, @settings.Core, () -> @settings.Here, () -> Int, () -> @sf.PageFrame, () -> Double, Int) -> Unit,
  ) {
    Some(
      (
        kind,
        fn(v : @view.View, page : () -> Page, under : Page?, stint : () -> Int, k : Int) {
          v.switch_by(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(p, _id) {
            guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
            let core = settings_core(src, w)
            let here = fn() { @settings.here_of(core, w.id, w.name) }
            @settings.frame(core, @signals.untracked(here))
            // (a dialog a fixture's mode puts up over its page, before the page is made: setting_page's)
            settings_fixture(src, core)
            pane_made_host(p, src, k)
            // (back over it only under another settings page or a place of the rail's: setting_page's; a place of the
            // rail's itself, none, whatever is under it: place_page's; its words read as they are said, in the
            // language now)
            let frame = fn() -> @sf.PageFrame {
              {
                back: match (page(), under) {
                  (Place(_), _) => None
                  (_, Some(u)) if u is (Setting(_) | Place(_)) => Some(@sfbase.back_label(u))
                  _ => None
                },
                top: 0.0,
                foot: 0.0,
                named: false,
              }
            }
            let width = fn() {
              let ww = p.window().0
              match @sfbase.workspace_in_view(src).0 {
                Some(w) => ww - fold_target(src, w, ww).1.col
                None => ww
              }
            }
            p.box(fn(a) {
              a.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
              f(a, core, here, stint, frame, width, k)
            })
            |> ignore
          })
        },
      ),
    )
  }
  let made = fn(
    kind : String,
    f : (@view.View, @settings.Core, () -> @settings.Here, () -> Int, () -> @sf.PageFrame, () -> Double) -> Unit,
  ) {
    made_k(kind, fn(a, core, here, stint, frame, width, _k) { f(a, core, here, stint, frame, width) })
  }
  match page {
    // (Home: the board while it is chosen, else its ground: board.mbt)
    Home => Some(board_home_made(src, tips))
    // (the settings come to beside their list: its first row's page, made once as that page is)
    Settings | Setting(Home) => pane_made(src, Setting(settings_landing), tips).map(fn(m) { ("settings/" + m.0, m.1) })
    Setting(About) =>
      made("about", fn(a, core, _here, _stint, frame, width) {
        @sfpages.about_node(a, core, on_back=core.pop, frame~, width~)
      })
    Setting(Memories) =>
      made("memories", fn(a, core, here, _stint, frame, width) {
        @sfpages.memories_node(a, core, here, on_back=core.pop, frame~, width~)
      })
    Setting(Changelog) =>
      made("changelog", fn(a, core, _here, _stint, frame, width) {
        @sfpages.changelog_node(a, core, on_back=core.pop, frame~, width~)
      })
    // (the profiles' place: the profile picked in its list, made once as its page is; none to pick yet, the first to add)
    Place("profiles") =>
      made("place/profiles", fn(a, core, here, stint, frame, width) {
        profiles_place_node(a, src, core, here, stint, frame, width, tips~)
      })
    // (the stations' place: the station picked in its list made once as its page is, none the first to add)
    Place("stations") =>
      made("place/stations", fn(a, core, here, stint, frame, width) {
        stations_place_node(a, src, core, here, stint, frame, width, tips~)
      })
    Place("remote") =>
      Some(
        (
          "place/remote",
          fn(v, _page, _under, _stint, k) {
            v.switch_by(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(p, ws_id) {
              guard ws_id is Some(wid) else { return }
              pane_made_host(p, src, k)
              let ends = pane_chat_bar_ends(src, p)
              let width = fn() { pane_w_at(src, p) }
              @sfpages.remote_workbench_node(
                p,
                src,
                fn() { @sfbase.workspace_in_view(src).0.map_or(wid, fn(w) { w.id }) },
                tips,
                start_pad=fn() { dmax(12.0, (ends.start)()) },
                end_pad=fn() { (ends.end)(false, false) },
                width~,
                shown=pane_shows(k),
                keep_screen=fn(st, sc) {
                  side_screen_shown(src, st, sc) ||
                  (app.nav.top() is Screen(top) && top.station == st && top.screen == sc)
                },
              )
            })
          },
        ),
      )
    // (a place of the rail's whose page is one of those: that page, at the stack's root (no back over it, place_page's),
    // made under its own kind)
    Place(name) =>
      match @settings.route_of(name) {
        // (those whose old view is gone: every frame makes them once, as a page or a place)
        Some(r) if @settings.made_once(r) =>
          pane_made(src, Setting(r), tips).map(fn(m) { ("place/" + m.0, m.1) })
        _ => None
      }
    // (by its station: another station's another page, not this one become it)
    Setting(Memory(address)) =>
      made("memory/" + address, fn(a, core, here, _stint, frame, width) {
        @sfpages.memory_node(a, core, here, address, on_back=core.pop, frame~, width~, tips~)
      })
    // 文件 and a station's drive (sfpages' files_page_node.mbt): one kind for all of them, the files' page's tabs kept
    // as the folder in front changes (its address, the page as it is now)
    Files =>
      made_k("files-home", fn(a, _core, _here, _stint, frame, width, k) {
        guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
        // (at rest while a page covers it in the pane: shown=)
        @sfpages.files_home_node(a, src, w.id, frame~, width~, on_back=fn() { @sfbase.go_back() |> ignore }, tips~, shown=pane_shows(k), arrives=fn() { app.nav.top() is Files })
      })
    Drive(_) =>
      made_k("files", fn(a, _core, _here, _stint, frame, width, k) {
        guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
        // (its own entry's folder, as it is now (what it became in place): kept shown while the page in its place
        // waits, it shows what it showed, never that one's)
        let own = fn() {
          match app.nav.page_of(k) {
            Some((Drive(d), _)) => Some(d)
            _ => None
          }
        }
        let last = Ref(@signals.untracked(own).unwrap_or({ station: "", root: None, path: "" }))
        let at = fn() {
          match own() {
            Some(d) => last.val = d
            None => ()
          }
          last.val
        }
        @sfpages.drive_page_node(a, src, w.id, at, frame~, width~, on_back=fn() { @sfbase.go_back() |> ignore }, go=files_go, tips~, shown=pane_shows(k), arrives=fn() { app.nav.top() is Drive(_) })
      })
    // (a web service whose chat the station has not said, or that it does not find: service_beside_node)
    Service(station, job) =>
      made("service/" + station + "/" + job, fn(a, _core, _here, _stint, _frame, _width) {
        service_beside_node(a, src, station, job)
      })
    // (已归档, none of its chats beside the sidebar's list of them: what it is)
    Archived => made("archived", fn(a, _core, _here, _stint, _frame, _width) { archive_main_node(a) })
    Setting(Archive) =>
      made("archive", fn(a, core, here, _stint, frame, width) {
        @sfpages.archive_node(a, core, here, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(Archiving) =>
      // (its pictures asked for again each time it is come back to, not each frame it stays: nav_flat_view's stint)
      made("archiving", fn(a, core, here, stint, frame, width) {
        @sfpages.archiving_node(a, core, here, on_back=core.pop, frame~, stint~, width~)
      })
    Setting(AutoDecisions) =>
      made("auto-decisions", fn(a, core, here, _stint, frame, width) {
        @sfpages.decisions_node(a, core, here, on_back=core.pop, frame~, width~, tips~)
      })
    // (by its station: another station's another page, not this one become it)
    Setting(StationArchiving(st)) =>
      made("station-archiving/" + st, fn(a, core, here, _stint, frame, width) {
        @sfpages.station_archiving_node(a, core, here, st, on_back=core.pop, frame~, width~)
      })
    Setting(StationMove(st)) =>
      made("station-move/" + st, fn(a, core, here, _stint, frame, width) {
        @sfpages.station_move_node(a, core, here, st, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(Shortcuts) =>
      // (recording while it is the one on top of the stack: its stay there, stint's)
      made("shortcuts", fn(a, core, _here, stint, frame, width) {
        @sfpages.shortcuts_node(a, core, on_back=core.pop, frame~, active=fn() { app.nav.top_stay().1 == stint() }, width~)
      })
    Setting(Notifications) =>
      // (a workspace's picture asked for again each time it is come back to: nav_flat_view's stint)
      made("notifications", fn(a, core, here, stint, frame, width) {
        @sfpages.notify_node(a, core, here, on_back=core.pop, frame~, stint~, width~)
      })
    // (by its station, skill and the part first shown: another's another page)
    Setting(MemoryDoc(address, skill, at)) =>
      made("memory-doc/" + address + "/" + skill + "/" + at.to_string(), fn(a, core, here, _stint, frame, width) {
        @sfpages.memory_doc_node(a, core, here, address, skill, at, on_back=core.pop, frame~, width~)
      })
    Setting(AutoPolicy(st)) =>
      made("auto-policy/" + st, fn(a, core, here, _stint, frame, width) {
        @sfpages.policy_node(a, core, here, st, on_back=core.pop, frame~, width~)
      })
    Setting(Appearance) =>
      made("appearance", fn(a, core, _here, _stint, frame, width) { @sfpages.appearance_node(a, core, on_back=core.pop, frame~, width~) })
    Setting(Experimental) =>
      made("experimental", fn(a, core, _here, _stint, frame, width) { @sfpages.experimental_node(a, core, on_back=core.pop, frame~, width~) })
    // the stations' list, the profiles' (by station: another station's another page) and an account's on several
    // stations (sfpages' stations_list.mbt, profiles_list.mbt)
    Setting(Stations) =>
      made("stations", fn(a, core, here, _stint, frame, width) {
        @sfpages.stations_list_node(a, core, here, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(Profiles("")) =>
      made("profiles/", fn(a, core, here, _stint, frame, width) {
        @sfpages.profiles_page_node(a, src, core, here, @settings.profiles_narrow_overview, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(Profiles(only)) =>
      made("profiles/" + only, fn(a, core, here, _stint, frame, width) {
        @sfpages.profiles_list_node(a, core, here, only, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(ProfileAccount(key)) =>
      made("profile-account/" + key, fn(a, core, here, _stint, frame, width) {
        @sfpages.profile_account_node(a, core, here, key, on_back=core.pop, frame~, width~, tips~)
      })
    // (by its station and id: another's another page)
    Setting(Profile(address, id)) =>
      made("profile/" + address + "/" + id, fn(a, core, here, stint, frame, width) {
        @sfpages.profile_node(a, core, here, address, id, on_back=core.pop, frame~, width~, tips~, stint~)
      })
    Setting(NewProfile(address)) =>
      made("new-profile/" + address, fn(a, core, here, _stint, frame, width) {
        @sfpages.new_profile_node(a, core, src, here, address, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(LocalStation) =>
      made("local-station", fn(a, core, _here, _stint, frame, width) {
        @sfpages.local_station_node(a, core, on_back=core.pop, frame~, width~)
      })
    // (by its station: another station's another page, not this one become it)
    Setting(Station(address)) =>
      made("station/" + address, fn(a, core, here, stint, frame, width) {
        @sfpages.station_node(a, core, src, here, address, on_back=core.pop, frame~, width~, stint~)
      })
    Setting(Permissions) =>
      made("permissions", fn(a, core, _here, _stint, frame, width) {
        @sfpages.permissions_node(a, core, on_back=core.pop, frame~, width~)
      })
    Setting(Me) =>
      made("me", fn(a, core, here, stint, frame, width) {
        @sfpages.me_node(a, core, here, on_back=core.pop, frame~, stint~, width~)
      })
    Setting(Fonts) =>
      made("fonts", fn(a, core, _here, _stint, frame, width) { @sfpages.fonts_node(a, core, on_back=core.pop, frame~, width~) })
    Setting(BarSettings) =>
      made("bars", fn(a, core, _here, _stint, frame, width) { @sfpages.bars_node(a, core, on_back=core.pop, frame~, width~) })
    Setting(Security) =>
      made("security", fn(a, core, here, stint, frame, width) {
        @sfpages.security_node(a, core, here, on_back=core.pop, frame~, stint~, width~)
      })
    Setting(SecurityOpen) =>
      made("security-open", fn(a, core, here, _stint, frame, width) {
        @sfpages.security_open_node(a, core, here, on_back=core.pop, frame~, width~)
      })
    Setting(Workspace) =>
      made("workspace", fn(a, core, here, stint, frame, width) {
        @sfpages.workspace_node(a, core, here, on_back=core.pop, frame~, stint~, width~, tips~)
      })
    Setting(VaultItems) =>
      made("vault-items", fn(a, core, here, _stint, frame, width) {
        @sfpages.vault_items_node(a, core, here, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(KeptFiles) =>
      made("kept", fn(a, core, _here, _stint, frame, width) { @settings.kept_node(a, core, on_back=core.pop, frame~, width~, tips~) })
    // (by its station and thread: another chat's another page)
    Setting(KeptChat(station, thread)) =>
      made("kept/" + station + "/" + thread.to_string(), fn(a, core, _here, _stint, frame, width) {
        @settings.kept_chat_node(a, core, station, thread, on_back=core.pop, frame~, width~, tips~)
      })
    // (by the station whose step is said first: another station's another page)
    Setting(AdbShare(focus)) =>
      made("adb/" + focus, fn(a, core, here, _stint, frame, width) {
        @settings.adb_node(a, core, focus, on_back=core.pop, frame~, width~, tips~, sub=fn() { here().sub })
      })
    Setting(Vault) =>
      made("vault", fn(a, core, here, _stint, frame, width) { @sfpages.vault_node(a, core, here, on_back=core.pop, frame~, width~, tips~) })
    // (by its vault and item: another's another page)
    Setting(VaultItem(vault, item)) =>
      made("vault-item/" + vault + "/" + item, fn(a, core, here, _stint, frame, width) {
        @sfpages.vault_item_node(a, core, here, vault, item, on_back=core.pop, frame~, width~, tips~)
      })
    // (by its station and id: another's another page)
    Setting(Connects(only)) =>
      made("connects/" + only, fn(a, core, here, stint, frame, width) {
        @sfpages.connects_node(a, src, core, here, only, on_back=core.pop, frame~, stint~, width~, tips~)
      })
    Setting(Connect(station, id)) =>
      made("connect/" + station + "/" + id, fn(a, core, here, stint, frame, width) {
        @sfpages.connect_node(a, src, core, here, station, id, on_back=core.pop, frame~, stint~, width~, tips~)
      })
    Setting(AutoCompletion) =>
      made("auto-completion", fn(a, core, here, _stint, frame, width) {
        @sfpages.completion_node(a, core, here, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(Usage) =>
      made("usage", fn(a, core, here, _stint, frame, width) {
        @sfpages.usage_node(a, core, src, here, on_back=core.pop, frame~, width~, tips~)
      })
    // (by its days: another's of other days another page)
    Setting(UsagePrices(days)) =>
      made("usage-prices/" + days.to_string(), fn(a, core, here, _stint, frame, width) {
        @sfpages.usage_prices_node(a, core, here, days, on_back=core.pop, frame~, width~)
      })
    // (a chat, and the new chat that becomes one in place: the same page, a node of the tree's, its old view in it as
    // yet, built as the stack's island built it: pane_page_one)
    page if @sfbase.chat_page_is(page) =>
      Some(
        (
          @sfbase.chat_page_kind(),
          fn(v, _page, _under, stint, k) {
            // (beside it its side panel, the tree's, reading by the page's source, let go with it: side_panel_node)
            v.row(Is(true)).grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
            let page_src : Ref[Source] = Ref(src)
            v.box(fn(p) {
              p.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))) |> ignore
              // (its bar the tree's, over the page's old view: chat_bar_wide_node, keeping clear of the window's corner)
              page_src.val = @sfbase.chat_page_made(
                p,
                src,
                k,
                fn(c, s, page) { pane_page_one(c, s, page, held=page is Chat(_)) },
                key=tape_island_key,
                drawn=fn(serial) { pane_page_wait.draws(serial) },
                over=fn(o, src, page, stint) {
                  chat_bar_wide_node(o, src, page, pane_chat_bar_ends(src, o, page~), tips, stint)
                },
                // (with chat_page_nodes on: its messages nodes, its composer in their list's foot its old view)
                body=fn(col, s, r, composer, shows) {
                  pane_made_chat(col, k)
                  chat_body_nodes(col, s, r, tips, stint, composer, shows)
                },
                // (the composer's old view on the page's way to another width as the side panel slides beside it, as the
                // old page's was inside its with_side: its foot's room across the way, not stepped where it crosses its
                // width, composer_foot_in)
                foot=fn(c, s, r) {
                  match @sfbase.workspace_in_view(s).0 {
                    Some(w) => with_side(c, s, w, r, fn() { chat_composer_nodes(c, s, r, wide.tape.get()) })
                    None => chat_composer_nodes(c, s, r, wide.tape.get())
                  }
                },
                // (its composer made as nodes in the list's foot: sfpages' chat_composer_node)
                foot_node=fn(n, s, r, shows, laid) {
                  @sfpages.chat_composer_node(n, s, r, shows~, laid~, tips~, apart=fn() { wide.tape.get() })
                },
                leaving=fn(c, s, r) {
                  match @sfbase.workspace_in_view(s).0 {
                    Some(w) => new_chat_after(c, s, w, r)
                    None => ()
                  }
                },
                // (its column on the page's way as the side panel slides beside it: laid out as at its narrower end)
                narrower=fn(n) { side_narrower(src, n, k) },
                // (moved aside with the folded block over it, in the same offset as the way across: chat_page_made's;
                // a new chat's old view, not held, moved aside inside itself as before, pane_page_one's)
                aside=fn(n) { if app.nav.page_of(k) is Some((Chat(_), _)) { pane_aside_at(src, n) } else { 0.0 } },
                // (a chat's old view held at the width the block's move ends at all the way, moved across by its node)
                held=fn(n) { pane_fold_held(src, n, k) },
                // (bound once the block's move has first set off with a chat on the page: nothing of it at rest before,
                // nor while a new chat, whose old view is laid out anew at each width of the move as before)
                held_from=fn() { pane_fold_set_off() && app.nav.page_of(k) is Some((Chat(_), _)) },
              )
            })
            |> ignore
            side_panel_node(v, page_src.val, k, tips)
          },
        ),
      )
    _ => None
  }
}

///|
/// Where a chat's bar in the pane off the tape keeps clear at its ends (chat_bar_wide_node's, node `n` its page's): as a
/// page's bar there (page_bar_room), where the block's move has it as the bar is drawn (fold_along's, as
/// pane_aside_at's): its start past the rail and the window's buttons as the block is closed, its margins while it is
/// shown a while; its end at the window's corner while no panel is open beside it (window_end_in: its buttons'
/// corner the window's, followed), clear of a corner too square for ⌘F's field (a capsule: window_corner_past), the
/// bar's own padding beside a panel.
fn pane_chat_bar_ends(
  src : Source,
  n : @view.View,
  page? : () -> Page? = fn() { None },
) -> ChatBarEnds {
  let look = fn() {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) => {
        let (_, now) = fold_target(src, w, n.window().0)
        Some(fold_along(fold_drawn_at(n), now))
      }
      None => None
    }
  }
  {
    over: fn() { 0.0 },
    // (as the old view's were, drawn in the page moved aside: page_one's `aside`, which the bar over it is not)
    margins: fn() {
      match look() {
        Some(f) => (f.bar_ml + f.aside, f.bar_mr - f.aside)
        None => (0.0, 0.0)
      }
    },
    start: fn() {
      match look() {
        Some(f) => f.bar_pl
        None => 0.0
      }
    },
    end: fn(beside, finding) {
      let col_w = match page() {
        Some(Chat(r)) if pane_w_at(src, n) >= side_both_least => {
          let key = chat_key(r)
          let _ = side_way(key)
          if panel_own.asked.get() == key {
            0.0
          } else {
            side_col(src, n, key, beside)
          }
        }
        _ => 0.0
      }
      if col_w > 0.5 {
        if @ui.window_keys_own() {
          bar_in
        } else {
          dmax(bar_in, @sf.window_corner_past(4.0, roots=@ui.tree_corner_roots_now()) - col_w)
        }
      } else if beside {
        // (beside what the pane shows next to it, not a chat's side column: a history's, as before)
        bar_in
      } else if finding {
        if @ui.window_keys_own() {
          @sf.window_keys_room(roots=@ui.tree_corner_roots_now()) + bar_in
        } else {
          @sf.window_corner_past(bar_in, roots=@ui.tree_corner_roots_now())
        }
      } else {
        @sf.window_end_in(bar_in, roots=@ui.tree_corner_roots_now())
      }
    },
    linked: fn() { if @ui.window_keys_own() { None } else { Some(@sf.window_corner_key()) } },
    ground: fn(_) { @sf.theme().p.bg },
  }
}

///|
/// Whether the frame makes the library's pages once where they are made at either width (pane_made; tape_made's 关于):
/// on in the app; off for a test that draws them as their old view does, to be compared.
// kept across runs: said by a test alone, round what it draws
pub let pane_makes : Ref[Bool] = Ref(true)

///|
/// What page_one and pane_page_one did for the page in its island, done for entry `k`'s page made once in node `p`: moved
/// aside as the folded sidebar is shown a while, where the block's move has got (page_aside's); over it the window's
/// title bar where its buttons are in the app's top row (title_row's); a right click in it copying what is picked
/// (context_node); what it shows across read of it as the sidebar comes to be shown a while, and nothing handed the
/// system's bars, while its entry shows (fold_goes' `made` by its entry, `shown`). Nothing in it moves of its own for
/// what moves the page (a keyboard, the block): no motion of the old view's is in it to be scoped to its foot
/// (@motion.scope's), its own (the update's bar's room) bound to its cause.
fn pane_made_host(p : @view.View, src : Source, k : Int) -> Unit {
  p
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  .offset(By(fn() { (pane_aside_at(src, p), 0.0) }))
  |> ignore
  context_node(p)
  fold_goes.made[k] = p
  p.owns(fn() {
    match fold_goes.made.get(k) {
      Some(v) if v.id() == p.id() => fold_goes.made.remove(k)
      _ => ()
    }
  })
  |> ignore
  p.show(fn() { @ui.window_inset() }, fn(t) {
    t
    .over(Is(true))
    .height(Is(Some(@sf.wide_bar_h)))
    .presses(Is(true))
    .moves_window(Is(true))
    |> ignore
  })
}

///|
/// What page_one did for a chat's page in its island, done for entry `k`'s chat made as nodes, its messages' column
/// `col` (chat_body_nodes', the composer in it): what it shows across read of it as the folded sidebar is shown a while,
/// while its entry shows (fold_goes' `made`), the one kept while the one on top waits too. Moved aside as that block
/// moves (pane_aside_at) by chat_page_made's `aside`, in the one offset its column has with its way across as the side
/// panel slides: an offset bound here too let go of that one (a node's one binding of a property), and the chat's rows
/// stood still while the panel slid, then stepped to their place at its end.
fn pane_made_chat(col : @view.View, k : Int) -> Unit {
  fold_goes.made[k] = col
  col.owns(fn() {
    match fold_goes.made.get(k) {
      Some(v) if v.id() == col.id() => fold_goes.made.remove(k)
      _ => ()
    }
  })
  |> ignore
}

///|
/// How far the page in the pane off the tape is moved aside as node `n` is drawn (the folded block shown a while over
/// it), where the block's move has it then.
fn pane_aside_at(src : Source, n : @view.View) -> Double {
  match @sfbase.workspace_in_view(src).0 {
    Some(w) => {
      let (_, now) = fold_target(src, w, n.window().0)
      fold_along(fold_drawn_at(n), now).aside
    }
    None => 0.0
  }
}

///|
/// How chat page `serial`'s old view in the pane off the tape is laid out as node `n` is drawn (chat_page_made's `held`):
/// while the block's move goes, at the width the page has where the move ends all the way, moved across as far as its
/// rows' words stood further in at the width it set off from, less as much as the move has come (laid_toward, as the
/// side panel's way has it), so the old view is built as the move sets off and not again at each frame of it, its words
/// going with the page; at rest, and while a new chat (laid out anew as the move goes, its words not a chat's rows), as
/// wide as it is.
fn pane_fold_held(src : Source, n : @view.View, serial : Int) -> @sfbase.ColumnLaid {
  let ww = n.window().0
  guard @sfbase.workspace_in_view(src).0 is Some(w) else { return { by: 0.0, across: 0.0, laid: ww, toward: ww, toward_by: 0.0 } }
  let (_, now) = fold_target(src, w, ww)
  let t = fold_drawn_at(n)
  let pane = ww - fold_along(t, now).col
  guard app.nav.page_of(serial) is Some((Chat(_), _)) else { return { by: 0.0, across: 0.0, laid: pane, toward: pane, toward_by: 0.0 } }
  // (what of the pane the chat's page does not have: its side panel's column beside it, as it is at that moment)
  let beside = pane - pane_page_w(src, n, serial, pane)
  match (fold_goes.from, fold_goes.to) {
    (Some(a), Some(b)) if fold_going(t) =>
      laid_toward(pane - beside, ww - a.col - beside, ww - b.col - beside)
    _ => { by: 0.0, across: 0.0, laid: pane - beside, toward: pane - beside, toward_by: 0.0 }
  }
}

///|
/// How wide chat page `serial` is in a pane `pane` wide, node `n` its page's (its side panel's column beside it, none where
/// the panel is over the page: side_panel_node's).
fn pane_page_w(src : Source, n : @view.View, serial : Int, pane : Double) -> Double {
  match app.nav.page_of(serial) {
    Some((Chat(r), _)) if pane >= side_both_least =>
      pane - side_col(src, n, chat_key(r), side_now(src, r).0.length() > 0)
    _ => pane
  }
}

///|
/// How wide the pane off the tape is as node `n` is drawn: the window's less the block's column, where the block's move
/// has it then.
fn pane_w_at(src : Source, n : @view.View) -> Double {
  let ww = n.window().0
  match @sfbase.workspace_in_view(src).0 {
    Some(w) => {
      let (_, now) = fold_target(src, w, ww)
      ww - fold_along(fold_drawn_at(n), now).col
    }
    None => ww
  }
}
