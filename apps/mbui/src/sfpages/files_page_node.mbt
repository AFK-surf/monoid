// 文件 and a station's drive (still.fail web/src/pages/Drive.tsx DriveHome, DrivePage, Roots, RootRow; Files.css.ts), one
// page on every screen as nodes of the window's tree, laid out by the width of the box it is drawn in: a folder (where
// there is one to show: the one asked, else the station's home where it has one, else a configured root), else the
// station's configured folders (Roots). The folder is its page (folder_node.mbt); what holds it by its width: wide, the
// files' page as Finder's window (a row of tabs, each a folder of a station of the workspace, the one shown below; a tab
// split in two shows two folders side by side, of one station or two, to drag from one to the other; the side in front,
// its top lined in the accent, is what the page's address says and what the keys work on; a press in the other one
// puts it in front), whose bar holds what can be done to the folder in front; narrow, its own bar (back, its name, what
// can be done to it) in the frame it is given, a folder gone into another page over it. 文件 opens the folder in front of
// the tabs as they were left (else the folder last open on this page), else this machine's home, another station's
// home, an older configured root or a favorite; none, says so.

///|
/// What shows a folder opened from the files' page: the shell's (sfdesk's files_go on 中屏 and 大屏: the side in front,
/// over the page in use on the tape; a page of the stack on 小屏), said as it starts; by default a page opened.
// kept across runs: a wire, set once as the app starts (sfdesk's init)
pub let files_go_said : Ref[(DriveAt) -> Unit] = Ref(fn(at) { open_page(Drive(at)) })

///|
/// A folder shown from the files' page (files_go_said's).
pub fn files_go(at : DriveAt) -> Unit {
  (files_go_said.val)(at)
}

///|
/// Where a station's drive opens for `at` (DrivePage): the root asked, else the home where the viewer may browse
/// everywhere, else its one configured root that can be read; None: its configured folders (Roots).
fn drive_root(st : DvStation?, at : DriveAt) -> String? {
  match (at.root, st) {
    (Some(r), _) => Some(r)
    (None, Some(s)) if s.drive && s.anywhere && s.home != "" => Some(s.home)
    (None, Some(s)) if s.drive =>
      match s.roots {
        [r] if r.state == "ok" => Some(r.path)
        _ => if s.anywhere && s.home != "" { Some(s.home) } else { None }
      }
    _ => None
  }
}

///|
/// A station's files at `at()` (DrivePage) in node `v`, of workspace `ws`, in whichever frame (`frame`: back, the room
/// over and under it; `width`: how wide the box it is drawn in is, its arrangement by it): a folder where there is one to
/// show, else its configured folders. `on_back`: back, where the frame gives it; `go`: a folder shown in place of this
/// one (narrow: a page over it; wide, the side in front). `shown`: whether the page shows (a stack's page not covered by
/// another): what only its rows show is read only then.
pub fn drive_page_node(
  v : @view.View,
  src : Source,
  ws : String,
  at : () -> DriveAt,
  frame~ : () -> @sf.PageFrame,
  width~ : () -> Double,
  on_back~ : () -> Unit,
  go? : (DriveAt) -> Unit = files_go,
  tips? : @sf.TipLayer,
  bar? : ((@sf.PageSaid) -> Unit, ((@view.View) -> Unit, (@sf.Look) -> Double) -> Unit),
  ends? : () -> (Double, Double, Double),
  shown? : () -> Bool = fn() { true },
  arrives? : () -> Bool,
) -> Unit {
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  shown_at_rest(v, shown, fn(b) { drive_page_body(b, src, ws, at, frame, width, on_back, go, tips?, bar?, ends?, arrives?) })
}

///|
/// What is made in `v` by `made`, at rest while `shown` says it does not show (a page covered by another on its stack):
/// what it reads let go of, read anew as it shows again, the same nodes, scrolled as they were, as the old view's island
/// read only while it was built.
pub fn shown_at_rest(v : @view.View, shown : () -> Bool, made : (@view.View) -> Unit, grows? : Bool = true) -> Unit {
  v.each(fn() { if shown() { [0] } else { [] } }, fn(k) { k }, keeps=fn() { [0] }, at_once=true, fn(b, _) {
    if grows {
      b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    }
    made(b)
  })
}

///|
fn drive_page_body(
  v : @view.View,
  src : Source,
  ws : String,
  at : () -> DriveAt,
  frame : () -> @sf.PageFrame,
  width : () -> Double,
  on_back : () -> Unit,
  go : (DriveAt) -> Unit,
  tips? : @sf.TipLayer,
  bar? : ((@sf.PageSaid) -> Unit, ((@view.View) -> Unit, (@sf.Look) -> Double) -> Unit),
  ends? : () -> (Double, Double, Double),
  arrives? : () -> Bool,
) -> Unit {
  let st = fn() {
    let a = at()
    dv_stations(src, ws).0.unwrap_or([]).iter().find_first(fn(s) { s.station == a.station })
  }
  // a folder where there is one to show (by its station, its root and its path: another folder another one), else
  // the station's folders
  let folder = fn() -> DriveAt? {
    let a = at()
    match (st(), drive_root(st(), a)) {
      (Some(s), Some(r)) if s.drive => Some({ station: a.station, root: Some(r), path: a.path })
      _ => None
    }
  }
  v.pick(fn() { folder() is Some(_) }, at_once=true, fn(p, has) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    if !has {
      roots_page_node(p, src, ws, st, frame, width, on_back, go)
      return
    }
    @sf.by_look_node(
      p,
      width,
      // wide, the files' page as Finder's window: its tabs, its halves, its address the folder in front
      fn(w) {
        let last = Ref(@signals.untracked(folder).unwrap())
        let here = fn() {
          match folder() {
            Some(f) => last.val = f
            None => ()
          }
          last.val
        }
        files_shell_node(w, src, ws, here, width, tips?, ends?, arrives?)
      },
      // narrow, a folder in its own frame (a stack's page), another folder another page over it
      fn(n) {
        n.pick(fn() { folder() }, at_once=true, fn(q, f) {
          q.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          match f {
            Some(here) => narrow_folder_node(q, src, ws, here, width, frame, on_back, go, tips?, bar?)
            None => ()
          }
        })
      },
    )
  })
}

///|
/// A folder in its own frame (narrow: a stack's page, a pane's), in `parent`: its bar (back where its frame has one, its
/// name, what can be done to it at its end, as far as half the bar less the title's half: the rest in its ⋯), its head
/// and its rows; a folder gone into another page over it (`go`).
fn narrow_folder_node(
  parent : @view.View,
  src : Source,
  ws : String,
  here : DriveAt,
  room : () -> Double,
  frame : () -> @sf.PageFrame,
  on_back : () -> Unit,
  go : (DriveAt) -> Unit,
  tips? : @sf.TipLayer,
  bar? : ((@sf.PageSaid) -> Unit, ((@view.View) -> Unit, (@sf.Look) -> Double) -> Unit),
) -> Unit {
  let st = fn() {
    dv_stations(src, ws).0.unwrap_or([]).iter().find_first(fn(s) { s.station == here.station }).unwrap_or(@sfbase.dv_station({ "station": Json::string(here.station) }))
  }
  let f : FolderOf = {
    // (a place of its own for each folder's page: on a stack the one under it is drawn as this one slides in)
    key: "narrow/" + here.station + "\n" + here.root.unwrap_or("") + "\n" + here.path,
    ws,
    st,
    at: here,
    front: fn() { true },
    room,
    go: fn(to, _) { go(to) },
    open_in: None,
    go_to: None,
  }
  parent.box(fn(page) {
    page.grow(Is(1.0)).min_height(Is(Some(0.0))).ground(By(fn() { @sf.theme().p.bg })) |> ignore
    // (in a panel of its own on the tape: the panel's bar names it and holds what can be done to it, as a settings
    // page's there; else its own bar)
    match bar {
      Some((told, acts)) => {
        page.reacts(fn() { folder_name(st(), here) }, fn(name) { told({ title: name, about: "", back: "" }) })
        acts(fn(a) { folder_actions_node(a, src, f, room, tips?) }, fn(_) { @sf.icon_button_side })
      }
      None =>
    @sf.nav_bar_node(
      page,
      fn() { frame().back.unwrap_or("") },
      fn() { folder_name(st(), here) },
      on_back,
      top=fn() { frame().top },
      // (back's word no wider than the bar has beside the title, 80 at least: whole or not at all)
      back_most=fn() { dmax(room() / 2.0 - narrow_back_room, narrow_back_least) },
      trailing_pad=4.0,
      trailing=fn(t) {
        t.box(fn(held) {
          held.max_width(By(fn() { Some(room() / 2.0 - bar_title_half) })) |> ignore
          folder_actions_node(held, src, f, room, tips?)
        })
        |> ignore
      },
    )
    }
    folder_view_node(page, src, f, fn(h, b) { folder_head_node(h, src, f, b, fn() {  }, false) }, foot=fn() { frame().foot })
    files_from_outside_node(page)
    drag_ghost_node(page)
  })
  |> ignore
}

///|
/// Half the room its own bar keeps for its title (its name in the middle).
let bar_title_half : Double = 40.0

// ── the files' page, wide ──

///|
/// ⌘⇧G of the files' page made last, as its folder's ⋯ opens it (a page shown at that moment: a test's).
// kept across runs: said as each files' page is made
let go_to_last : Ref[(() -> Unit)?] = Ref(None)

///|
/// ⌘⇧G's dialog opened on the files' page made last, as its folder's ⋯'s 前往文件夹 opens it.
pub fn go_to_open() -> Unit {
  match go_to_last.val {
    Some(f) => f()
    None => ()
  }
}

///|
/// The files' page of workspace `ws` at `here()` (the page's address: the side in front of the tab shown), in `parent`
/// (filling it): the bar (the tabs, when more than one; what can be done to the folder in front; split, a new tab),
/// then the tab shown. Its keys: ⌘T a new tab where the front is, ⌃Tab / ⌘⇧] and ⌘⇧[ go along them, ⌘⌥D splits, ⌘⇧G a
/// folder by its path (as Finder's 前往文件夹).
pub fn files_shell_node(
  parent : @view.View,
  src : Source,
  ws : String,
  here : () -> DriveAt,
  width : () -> Double,
  tips? : @sf.TipLayer,
  ends? : () -> (Double, Double, Double),
  arrives? : () -> Bool = fn() { true },
  arrives_later? : Bool = false,
) -> Unit {
  // the address moved (a link, the sidebar, history): the side in front follows it
  // (told once for where it arrives, whichever shell shows it: the page under one pushed shows it too as that slides
  // in, as the old view's shell told it once, files_arrived)
  // (until the core has them, the one tab where the address is)
  let tabs = fn() -> FilesTabs {
    match files_tabs(src, ws) {
      Some(Some(t)) if t.tabs.length() > 0 => t
      _ => { tabs: [{ id: "", panes: [here()], front: 0 }], current: "", front: here() }
    }
  }
  let tab = fn() {
    let t = tabs()
    for i = 0; i < t.tabs.length(); i = i + 1 {
      if t.tabs[i].id == t.current {
        return t.tabs[i]
      }
    }
    t.tabs[0]
  }
  // (told by the page on top, not by one under it as another slides in over it, `arrives`; once its sides are made,
  // as the first is and as the address moves)
  let arrive_from = fn(v : @view.View) {
    v.reacts(fn() { (here(), arrives()) }, fn(now) {
      let (h, on) = now
      let arrive = ws + "\n" + h.station + "\n" + h.root.unwrap_or("") + "\n" + h.path
      if on && files_arrived.val != arrive {
        files_arrived.val = arrive
        files_tabs_act(src, ws, "arrive", pane=h, fn(_) {  })
      }
    })
  }
  // another tab or side brought in front: the address says it
  let show = fn(act : String, pane : DriveAt?, id : String?, side : Int?) {
    files_tabs_act(src, ws, act, pane?, id?, side?, fn(next) {
      match next {
        Some(n) => if !same_pane(n.front, @signals.untracked(here)) { files_go(n.front) }
        None => ()
      }
    })
  }
  // the side in front is where the address is: drawn from it, not from what is kept (which follows it)
  let pane_at = fn(x : FilesTab, i : Int) -> DriveAt {
    let t = tab()
    if x.id == t.id && i == t.front {
      here()
    } else {
      x.panes.get(i).unwrap_or(here())
    }
  }
  let split_on = fn() { tab().panes.length() == 2 }
  let along = fn(step : Int) {
    let t = @signals.untracked(tabs)
    let at = t.tabs.search_by(fn(x) { x.id == t.current }).unwrap_or(0)
    let n = t.tabs.length()
    show("show", None, Some(t.tabs[(at + step + n) % n].id), None)
  }
  let go_to = fn() { go_to_ask(src, ws, @signals.untracked(here), files_go) }
  go_to_last.val = Some(go_to)
  let stations = fn() { drive_stations(src, ws).0.unwrap_or([]) }
  let station_of = fn(p : DriveAt) {
    fn() {
      let sts = stations()
      for i = 0; i < sts.length(); i = i + 1 {
        if sts[i].station == p.station {
          return sts[i]
        }
      }
      @sfbase.dv_station({ "station": Json::string(p.station) })
    }
  }
  let folder_of = fn(i : Int, p : DriveAt) -> FolderOf {
    {
      key: "page/\{i}",
      ws,
      st: station_of(p),
      at: p,
      front: fn() { i == tab().front },
      // (a side's room: the page's, less its own room either side; split, its half)
      room: fn() { if split_on() { width() / 2.0 - body_in_half } else { width() - body_in } },
      // (its operation state handed to the folder it opens, read on as that one loads: open_handing)
      go: fn(to, _) { @sfbase.open_handing(src, "doing", {}, fn() { files_go(to) }) },
      open_in: Some(fn(to, beside) { show(if beside { "besides" } else { "open" }, Some(to), None, None) }),
      go_to: Some(go_to),
    }
  }
  parent.box(fn(page) {
    page.grow(Is(1.0)).min_height(Is(Some(0.0))).ground(By(fn() { @sf.theme().p.bg })) |> ignore
    page.key_context("Files") |> ignore
    let on = fn(action : String, f : () -> Unit) {
      page.on_action("files." + action, fn(_) {
        f()
        true
      })
      |> ignore
    }
    on("tab_new", fn() { show("open", Some(@signals.untracked(here)), None, None) })
    on("tab_next", fn() { along(1) })
    on("tab_back", fn() { along(-1) })
    on("split", fn() { show("split", None, None, None) })
    on("go_to", go_to)
    // the bar: the tabs as Safari's compact ones (one tab alone has none, as Finder's window: only the bar's buttons),
    // what can be done to the folder in front, then the tabs' own, a little apart
    page.box(fn(bar) {
      // (in a panel of its own on the tape, as a page's bar there: on the tape's one line, its ends clear of the panel's
      // top corners, its last button concentric with the top right one where it can be: `ends`, the tape's)
      @sf.style_node(bar, fn() {
        match ends {
          Some(e) => {
            let (start, end, over) = e()
            bar_box.then(
              @ui.style(h=Fixed(files_bar_h + over), pt=@sf.room_of(over), pl=@sf.room_of(start), pr=@sf.room_of(end), gap=@sf.keys_gap()),
            )
          }
          None => bar_box_wide()
        }
      })
      bar.moves_window(By(fn() { @ui.window_inset() })) |> ignore
      bar.pick(fn() { tabs().tabs.length() > 1 }, at_once=true, fn(t, several) {
        @sf.style_node(t, fn() { tabs_none }, in_row=true)
        if several {
          tab_row_node(t, stations, tabs, pane_at, fn(act, id) { show(act, None, Some(id), None) })
        }
      })
      bar.box(fn(held) {
        held.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
        held.pick(fn() {
          let t = tab()
          (t.id, t.front, pane_at(t, t.front))
        }, at_once=true, fn(a, which) {
          let (_, front, at) = which
          let f = folder_of(front, at)
          let others = fn() {
            let t = tab()
            let out : Array[FolderOf] = []
            for i in 0..<t.panes.length() {
              if i != t.front {
                out.push(folder_of(i, pane_at(t, i)))
              }
            }
            out
          }
          // (the list's room: the window's share the side has)
          folder_actions_node(a, src, f, f.room, others~, tips?)
        })
      })
      |> ignore
      bar.box(fn(apart) { @sf.style_node(apart, fn() { bar_apart }, in_row=true) }) |> ignore
      // (as a bar's buttons are: round on the tape, the last in the panel's corner concentric with it)
      @sf.icon_button_node(
        bar,
        "view-columns",
        fn() { @sf.t(if split_on() { "web-pages.files.unsplit" } else { "web-pages.files.split" }) },
        fn() { show("split", None, None, None) },
        tips?,
        linked=fn() { @sf.bar_keys_link() },
        ink=fn() { if split_on() { @sf.theme().p.accent } else { @sf.theme().p.muted } },
      )
      |> ignore
      @sf.icon_button_node(bar, "plus", fn() { @sf.t("web-pages.files.newTab") }, fn() {
        show("open", Some(@signals.untracked(here)), None, None)
      }, tips?, linked=fn() { @sf.bar_keys_link() })
      |> ignore
    })
    |> ignore
    // the tab shown: a side each, split the one in front lined at its top
    page.box(fn(row) {
      @sf.style_node(row, fn() { panes_row })
      // (its sides once the core has said its tabs, which say what they show: none read before, as page_reads waits)
      let sides = fn() { tab().panes.length() }
      row.each(fn() { Array::makei(sides(), fn(i) { i }) }, fn(i) { i }, at_once=true, fn(side, i) {
        let i = i.untracked()
        // (each side its share of the row, the row's whole where it is alone)
        side.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        side_node(side, src, i, tab, pane_at, folder_of, split_on, fn() {
          let t = @signals.untracked(tab)
          if i != t.front {
            show("front", None, None, Some(i))
          }
        })
        if i == 0 {
          if arrives_later {
            // (the start page's from its first layout on, as the old view's from the frame that built it: one put on
            // and covered in one change, a folder opened over it, tells nothing)
            side.box(fn(o) {
              o.over(Is(true)) |> ignore
              o.by_room(fn(held, _) { arrive_from(held) }) |> ignore
            })
            |> ignore
          } else {
            arrive_from(side)
          }
        }
      })
    })
    |> ignore
    // files from the computer let go on a folder drawn in it go up into it; what is carried, under the pointer
    files_from_outside_node(page)
    drag_ghost_node(page)
  })
  |> ignore
}

///|
/// One side (PaneFrame) in `parent`: the folder `i` of the tab shown is under its station, what is pressed in it putting
/// it in front first (`front_it`, as the web's side takes the pointer going down first); a station not among the
/// workspace's, said so.
fn side_node(
  parent : @view.View,
  src : Source,
  i : Int,
  tab : () -> FilesTab,
  pane_at : (FilesTab, Int) -> DriveAt,
  folder_of : (Int, DriveAt) -> FolderOf,
  split_on : () -> Bool,
  front_it : () -> Unit,
) -> Unit {
  let front = fn() { tab().front == i }
  parent.box(fn(s) {
    @sf.style_node(s, fn() { if split_on() { side_half } else { side_one } }, in_row=true)
    s.box(fn(line) {
      @sf.style_node(line, fn() { if front() { front_line } else { back_line } })
      line.laid_nowhere(By(fn() { !split_on() })) |> ignore
    })
    |> ignore
    s.box(fn(body) {
      @sf.style_node(body, fn() { if split_on() { body_half } else { body_one } })
      // (a press going down in it, before what it presses takes it: it is put in front)
      body.reacts(fn() { body.window_downs() }, fn(_) {
        let (x, y) = body.window_down_point()
        let (bx, by, bw, bh) = body.placed_window_now()
        if x >= bx && x < bx + bw && y >= by && y < by + bh {
          front_it()
        }
      }, at_start=false)
      body.pick(fn() { pane_at(tab(), i) }, at_once=true, fn(fv, at) {
        // (all of the side's room across)
        fv.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        let present = @signals.untracked(fn() { dv_stations(src, @sfbase.workspace_of(at.station)).0.unwrap_or([]).iter().any(fn(s) { s.station == at.station }) })
        if !present && @signals.untracked(fn() { dv_stations(src, @sfbase.workspace_of(at.station)).0 }) is Some(_) {
          fv.box(fn(m) {
            @sf.style_node(m, fn() { missing_box })
            @sf.words_node(m, fn() { @sf.t("web-pages.workspace.noSuchStation") }, fn() { missing_words }) |> ignore
          })
          |> ignore
          return
        }
        let f = folder_of(i, at)
        folder_view_node(fv, src, f, fn(h, b) { folder_head_node(h, src, f, b, front_it, true) })
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// The tabs in `parent` (@sf.tab_bar_node's groove: one tab list, Tab stopping at the one shown, ← → showing each):
/// each tab as wide as what it shows, the one shown raised; its folder first, its station after it, small, a dot of its
/// station's colour before; its × at its end, concentric with it, while pointed at (always to a finger), Delete on it
/// closing it too. `show`: a tab shown or closed.
fn tab_row_node(
  parent : @view.View,
  stations : () -> Array[DvStation],
  tabs : () -> FilesTabs,
  pane_at : (FilesTab, Int) -> DriveAt,
  show : (String, String) -> Unit,
) -> Unit {
  // (each tab read by its id, each station's colour by its place among them)
  let by_id = parent.keyed_by(fn() { tabs().tabs }, fn(t) { t.id })
  let tones = parent.keyed_by(fn() { stations().mapi(fn(i, s) { (s.station, i) }) }, fn(x) { x.0 })
  let panes = fn(id : String) {
    match by_id.get(id) {
      Some(t) => Array::makei(t.panes.length(), fn(i) { pane_at(t, i) })
      None => []
    }
  }
  @sf.tab_bar_node(
    parent,
    fn() { @sf.t("web-pages.files.tabs") },
    fn() { by_id.keys() },
    fn() { tabs().current },
    fn(id) { show("show", id) },
    fn(id) {
      panes(id).map(fn(p) {
        let (folder, station) = pane_parts(p, stations())
        station + " › " + folder
      }).join(" | ")
    },
    fn(t, id, shown) {
      t.box(fn(parts) {
        @sf.style_node(parts, fn() { tab_parts }, in_row=true)
        parts.each(fn() { Array::makei(panes(id).length(), fn(i) { i }) }, fn(i) { i }, at_once=true, fn(pp, k) {
          let k = k.untracked()
          let p = fn() {
            match panes(id).get(k) {
              Some(p) => p
              None => pane_at({ id, panes: [], front: 0 }, 0)
            }
          }
          pp.row(Is(true)).gap(Is(@ui.Space::px(S1_5))).lines_up(Is(Some(Middle))).min_width(Is(Some(0.0))).shrink(Is(1.0)) |> ignore
          pp.box(fn(dot) {
            @sf.style_node(dot, fn() {
              let tone = tones.get(p().station).map(fn(x) { x.1 }).unwrap_or(0) % station_dots.length()
              station_dots[tone]
            })
          })
          |> ignore
          @sf.words_node(pp, fn() { pane_parts(p(), stations()).0 }, fn() { if shown.front() { tab_folder_on } else { tab_folder } }) |> ignore
          @sf.words_node(pp, fn() { pane_parts(p(), stations()).1 }, fn() { tab_station }) |> ignore
        })
      })
      |> ignore
    },
    look=Groove,
    close=fn(id) { show("close", id) },
    close_label=fn(_) { @sf.t("web-pages.files.closeTab") },
    close_shows=Lit,
  )
  |> ignore
}

// ── 文件 on a wide screen, and a station's configured folders ──

///|
/// 文件 on a wide screen (DriveHome), in `v`: the folder it opens at (the files' page's tabs), else the page saying
/// there is none. `width`: how wide the box it is drawn in is.
pub fn files_home_node(
  v : @view.View,
  src : Source,
  ws : String,
  frame~ : () -> @sf.PageFrame,
  width~ : () -> Double,
  on_back~ : () -> Unit,
  tips? : @sf.TipLayer,
  ends? : () -> (Double, Double, Double),
  shown? : () -> Bool = fn() { true },
  arrives? : () -> Bool,
) -> Unit {
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  shown_at_rest(v, shown, fn(b) { files_home_body(b, src, ws, frame, width, on_back, tips?, ends?, arrives?) })
}

///|
fn files_home_body(
  v : @view.View,
  src : Source,
  ws : String,
  frame : () -> @sf.PageFrame,
  width : () -> Double,
  on_back : () -> Unit,
  tips? : @sf.TipLayer,
  ends? : () -> (Double, Double, Double),
  arrives? : () -> Bool,
) -> Unit {
  // (the tabs not known yet: as none kept, the core has them from this device at once)
  let first = fn() -> DriveAt? {
    let tabs = files_tabs(src, ws).unwrap_or(None)
    let (known, _) = drive_stations(src, ws)
    let stations = known.unwrap_or([])
    let here = this_machine()
    match tabs {
      Some(t) if t.tabs.length() > 0 => Some(t.front)
      _ =>
        match last_files_page(ws) {
          Some(at) => Some(at)
          None => {
            let mut mine : DvStation? = None
            let mut pinned : DvStation? = None
            let mut home : DvStation? = None
            for i = 0; i < stations.length(); i = i + 1 {
              let s = stations[i]
              if mine is None && s.station == here && s.anywhere && s.home != "" {
                mine = Some(s)
              }
              if pinned is None && s.roots.length() > 0 {
                pinned = Some(s)
              }
              if home is None && s.anywhere && s.home != "" {
                home = Some(s)
              }
            }
            let favs = favorites_in(src, ws, stations)
            let mut saved : Favorite? = None
            for fi = 0; fi < favs.length(); fi = fi + 1 {
              let f = favs[fi]
              let mut has_drive = false
              for si = 0; si < stations.length(); si = si + 1 {
                if stations[si].station == f.station && stations[si].drive {
                  has_drive = true
                  break
                }
              }
              if has_drive {
                saved = Some(f)
                break
              }
            }
            match (mine, pinned, home, saved) {
              (Some(s), _, _, _) => Some({ station: s.station, root: Some(s.home), path: "" })
              (_, _, Some(s), _) => Some({ station: s.station, root: Some(s.home), path: "" })
              (_, Some(s), _, _) => Some({ station: s.station, root: Some(s.roots[0].path), path: "" })
              (_, _, _, Some(f)) => Some({ station: f.station, root: Some(f.root), path: f.path })
              _ => None
            }
          }
        }
    }
  }
  v.pick(fn() { first() is Some(_) }, at_once=true, fn(p, has) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    if has {
      let last = Ref(@signals.untracked(first).unwrap())
      let here = fn() {
        match first() {
          Some(a) => last.val = a
          None => ()
        }
        last.val
      }
      // (文件 opens the files' page's tabs, Finder's window, wide alone: the phone's 文件 is its places)
      @sf.by_look_node(p, fn() { @sf.page_narrow_most }, fn(w) {
        files_shell_node(w, src, ws, here, width, tips?, ends?, arrives?, arrives_later=true)
      }, fn(_) {  })
    } else {
      @sf.page_node(p, fn() { @sf.t("web-pages.drive.title") }, fn() { ["none"] }, on_back~, frame~, width~, tips?, fn(b, _) {
        b.pick(fn() { drive_stations(src, ws).0 is None }, at_once=true, fn(x, reading) {
          if reading {
            @sf.waiting_node(
              x,
              fn(w) { roots_sample_node(w) },
              error=fn() { drive_stations(src, ws).1.unwrap_or("") },
              note=fn() { { reading: true, text: @sf.t("common.readingStations"), failing: [] } },
            )
          } else {
            @sf.empty_words_node(x, fn() { @sf.t("web-main.rail.filesNone") }, more=fn(e) {
              e.show(fn() { favorite_stations(src, ws).length() > 0 }, at_once=true, fn(k) {
                @sf.button_node(k, fn() { @sf.t("web-pages.files.addFavorite") }, fn() {
                  add_favorite_folder(src, ws, favorite_stations(src, ws), picked=fn(f) {
                    files_go({ station: f.station, root: Some(f.root), path: f.path })
                  })
                }, tone=Primary)
                |> ignore
              })
            })
          }
        })
      })
    }
  })
}

///|
/// A station's drive with no folder to show (Roots; the phone's RootsPage), in `parent`: one page on every screen, made
/// of the library's page parts (its frame laid out by its width: back over a large title, or its head). What it is for:
/// which of the station's configured folders can be gone into, and what is wrong with one. A station that offers its home
/// opens there instead.
fn roots_page_node(
  parent : @view.View,
  src : Source,
  ws : String,
  st : () -> DvStation?,
  frame : () -> @sf.PageFrame,
  width : () -> Double,
  on_back : () -> Unit,
  go : (DriveAt) -> Unit,
) -> Unit {
  let shows = fn() -> Int {
    let (known, _) = dv_stations(src, ws)
    match st() {
      _ if known is None => 0
      None => 1
      Some(s) if !s.overview => 0
      Some(s) if !s.drive => 2
      Some(s) if s.roots.length() == 0 => 3
      Some(_) => 4
    }
  }
  @sf.page_node(
    parent,
    fn() { @sf.t("web-pages.drive.title") },
    fn() { ["roots"] },
    on_back~,
    frame~,
    width~,
    small=fn() { st().map(fn(s) { s.name }).unwrap_or("") },
    fn(b, _) {
      b.pick(shows, at_once=true, fn(x, k) {
        let empty = fn(words : String, pick : Bool) {
          @sf.empty_words_node(x, fn() { words }, more=fn(e) {
            if pick {
              @sf.button_node(e, fn() { @sf.t("web-pages.files.addFavorite") }, fn() {
                match @signals.untracked(st) {
                  Some(s) => add_favorite_folder(src, ws, [s], picked=fn(f) { go({ station: f.station, root: Some(f.root), path: f.path }) })
                  None => ()
                }
              }, tone=Primary)
              |> ignore
            }
          })
        }
        match k {
          0 => @sf.waiting_node(x, fn(w) { roots_sample_node(w) }, error=fn() { dv_stations(src, ws).1.unwrap_or("") })
          1 => empty(@sf.t("web-pages.workspace.noSuchStation"), false)
          2 => empty(@sf.t("web-pages.drive.oldStation"), false)
          3 => {
            let s = @signals.untracked(st).unwrap()
            empty(@sf.t("web-pages.drive.noneMember"), favorite_stations(src, ws).iter().any(fn(x) { x.station == s.station }))
          }
          _ => roots_section_node(x, fn() { st().unwrap_or(@sfbase.dv_station({})) }, go)
        }
      })
    },
  )
}

///|
/// The folders station `s` pins, in `parent`: how many, the title over their card, a row each.
fn roots_section_node(parent : @view.View, s : () -> DvStation, go : (DriveAt) -> Unit) -> Unit {
  @sf.section_node(parent, fn() { @sf.t("web-pages.drive.rootsCount", args=[("n", s().roots.length().to_string())]) }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.each(fn() { s().roots.map(fn(r) { (r.path, r.name, r.state) }) }, fn(r) { r.0 }, fn(row, r) {
        @sf.link_row_node(
          row,
          fn() { r.get().1 },
          fn() {
            let st = @signals.untracked(s)
            go({ station: st.station, root: Some(r.untracked().0), path: "" })
          },
          note=fn() { r.get().0 },
          trouble=fn() {
            match dv_trouble(r.get().2) {
              Some((what, hint)) => what + " · " + hint
              None => ""
            }
          },
          lead=LeadLine(fn(l) { @sf.icon_node(l, "folder", @signals.untracked(fn() { @sf.theme().items.mark }), By(fn() { @sf.theme().p.muted })) |> ignore }),
        )
      })
    })
  })
}

///|
/// The folders to come while the station is read (the library's Waiting, in its bones), in `parent`: roots_section of
/// made-up ones.
fn roots_sample_node(parent : @view.View) -> Unit {
  let roots : Array[DvRoot] = [(5, 18), (3, 24), (6, 15), (4, 21)].map(fn(r) {
    { path: @sf.sample_words(r.1), name: @sf.sample_words(r.0), state: "ok" }
  })
  let s = @sfbase.dv_station({ "station": "sample", "name": Json::string(@sf.sample_words(4)) })
  roots_section_node(parent, fn() { { ..s, roots, } }, fn(_) {  })
}

///|
/// The bar in a window's whole: its last button at the window's top right corner following it where the bar's buttons
/// do (@sf.window_end_in).
fn bar_box_wide() -> @ui.Style {
  let over = @sf.window_keys_bar_over_now()
  bar_box.then(
    @ui.style(
      h=Fixed(files_bar_h + over),
      pt=@sf.room_of(over),
      pr=@sf.room_of(@sf.window_end_in(files_bar_in, roots=@ui.tree_corner_roots_now())),
      gap=@sf.keys_gap(),
    ),
  )
}

///|
/// A side's folder's room in from its sides (one: 32 before it, 40 after; split, 24 each and its rows' 16).
let body_in : Double = 72.0

///|
let body_in_half : Double = 80.0

///|
/// The bar's height (bar_box: S11), and how far in it is at its ends (12).
let files_bar_h : Double = 44.0

///|
let files_bar_in : Double = 12.0

///|
// kept across runs: a value (no field of it changes)
let bar_box : @ui.Style = @ui.css("row w=Full h=S11 px=S3 gap=S1 align=ACenter justify=JEnd")

///|
/// No tabs (one alone): what is left of the bar.
// kept across runs: a value (no field of it changes)
let tabs_none : @ui.Style = @ui.style(row=true, w=@sf.grow, min_w=S0)

///|
// kept across runs: a value (no field of it changes)
let bar_apart : @ui.Style = @ui.css("w=S2")

///|
// kept across runs: a value (no field of it changes)
let tab_parts : @ui.Style = @ui.style(row=true, w=@sf.grow, min_w=S0, gap=S1_5, align=ACenter, justify=JCenter, clip=true)

///|
// kept across runs: a value (no field of it changes)
let tab_folder : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let tab_folder_on : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let tab_station : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let station_dots : Array[@ui.Style] = ([Accent, Link, Positive, Warn, Danger, Muted] : Array[@ui.Color]).map(fn(k) {
  @ui.style(w=S1_5, h=S1_5, radius=Full, bg=k)
})

///|
// kept across runs: a value (no field of it changes)
let panes_row : @ui.Style = @ui.css("row w=Full h=Full")

///|
// kept across runs: a value (no field of it changes)
let side_one : @ui.Style = @ui.css("w=Full h=Full")

///|
// kept across runs: a value (no field of it changes)
let side_half : @ui.Style = @ui.style(w=@sf.grow, h=Full, clip=true)

///|
// kept across runs: a value (no field of it changes)
let front_line : @ui.Style = @ui.css("w=Full h=S0_5 bg=Accent")

///|
// kept across runs: a value (no field of it changes)
let back_line : @ui.Style = @ui.css("w=Full h=S0_5")

///|
/// A side's folder in from its sides (one: 32 before it, 40 after; split, 16 each).
// kept across runs: a value (no field of it changes)
let body_one : @ui.Style = @ui.css("row w=Full h=Full pl=S8 pr=S10 clip")

///|
// kept across runs: a value (no field of it changes)
let body_half : @ui.Style = @ui.css("row w=Full h=Full px=S4 clip")

///|
// kept across runs: a value (no field of it changes)
let missing_box : @ui.Style = @ui.css("w=Full px=S10 pt=S3 pb=S3")

///|
// kept across runs: a value (no field of it changes)
let missing_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// Back's words at least 80 wide, at most what the bar has beside the title (half less 120).
let narrow_back_least : Double = 80.0

///|
let narrow_back_room : Double = 120.0

///|
/// Where the files' page last told the core it arrived (its workspace and folder): told again only where it moves.
// kept across runs: put back by a run anew (files_reset)
let files_arrived : Ref[String] = Ref("")
