// A chat's 文件 tab (drive_tab.mbt says what it is for) made once as nodes of the window's tree, in the chat's side
// panel beside its page and on the tape (panel_node.mbt, tape_view.mbt tape_side_node), for its `files` tab and a
// station's `drive:` tab alike: the places (个人收藏, then each station a section of its places), or a folder: its trail
// and what is done to it over its list, the folder as a whole picked from the top of it, its rows (sfpages'
// drive_row_node, compact) picked by a press or gone into, its ⋯ and a right click their menu; dragged with a mouse onto
// the chat for its composer to take (tab_drag_node: the tab's own carry, what the composer and the chat's page read,
// dragged and tab_take_drop); the preview under the list; 添加 n at its foot. Where it is is drive_tab.mbt's (by
// scope, a signal of its own, ftab_place_of), what the folder is ordered by the files' page's (its Browse, told where
// it is as that changes); what is picked is this one's (ntab_picked). The new chat's panel, an old view still, keeps
// the tab's old view (files_tab) till its page is made as nodes.

///|
/// What is picked in the tab made as nodes to go into a chat's message, in the order picked, with the chat whose it is
/// (its key: what 添加 puts it into): another chat's picks are none.
// kept across runs: put back by tab_node_reset
let ntab_picked : @signals.Signal[(String, Array[Dragged])] = @signals.signal(("", []))

///|
fn tab_node_reset() -> Unit {
  ntab_picked.set(("", []))
}

///|
/// What is picked for chat `chat`'s message, read as it changes.
fn ntab_picks(chat : String) -> Array[Dragged] {
  let (whose, picked) = ntab_picked.get()
  if whose == chat {
    picked
  } else {
    []
  }
}

///|
/// Whether `d` is picked for chat `chat`'s message.
fn ntab_is_picked(chat : String, d : Dragged) -> Bool {
  ntab_picks(chat).iter().any(fn(x) { x.station == d.station && x.abs == d.abs })
}

///|
/// `d` picked for chat `chat`'s message, or no longer (a press's).
fn ntab_pick(chat : String, d : Dragged) -> Unit {
  let now = @signals.untracked(fn() { ntab_picks(chat) })
  if now.iter().any(fn(x) { x.station == d.station && x.abs == d.abs }) {
    ntab_picked.set((chat, now.filter(fn(x) { !(x.station == d.station && x.abs == d.abs) })))
  } else {
    ntab_picked.set((chat, [..now, d]))
  }
}

///|
/// Row node `v` carrying what `item` says as a mouse holds it and moves it past the slop (a finger moving on a row moves
/// the list): carried, what the chat's composer and its page read as carried (dragged); let go, let go off the tab where
/// it is, for the first that asks to take it (tab_take_drop, chat_talk's chat_drop_node). Not while `live` says not
/// (the row busy).
fn tab_drag_node(v : @view.View, item : () -> Dragged, live : () -> Bool) -> Unit {
  v
  .claims(fn(dx, dy) { @sf.pointer_rests() && @signals.untracked(live) && (dx.abs() > tdrag_slop || dy.abs() > tdrag_slop) })
  .on_drag(fn(d) {
    match d.kind {
      Down => {
        // (another carried: what was let go before and not taken is not for it)
        ftab.let_go = None
        tdrag.at.set((d.wx, d.wy))
        tdrag.item.set(Some(@signals.untracked(item)))
      }
      Moved => tdrag.at.set((d.wx, d.wy))
      Up =>
        match tdrag.item.untracked() {
          Some(i) => {
            ftab.let_go = Some((i, d.wx, d.wy))
            tdrag.item.set(None)
          }
          None => ()
        }
      Off => tdrag.item.set(None)
    }
  })
  |> ignore
}

///|
/// The tab for chat `chat` (its key: what 添加 puts things into), whose station is `station`, in node `v` (as large as
/// the panel under its bar), of workspace `ws`: the stations lending their files (`only_station`: that one alone, a
/// station's 文件 tab), where it is kept by `scope`; it starts at the chat's station's home for one who browses every
/// folder, else at its one folder pinned, else at the places. 添加 at its foot as `foot` lays it (in the panel's foot
/// corner, concentric with it). What is said of what the pointer rests on, in `tips`.
fn files_tab_node(
  v : @view.View,
  src : Source,
  ws : String,
  chat : String,
  station : String,
  foot : () -> @ui.Style,
  tips : @sf.TipLayer,
  only_station? : Bool = false,
  scope? : String = ws,
) -> Unit {
  let stations = fn() {
    dv_stations(src, ws).0.unwrap_or([]).filter(fn(s) { s.drive && (!only_station || s.station == station) })
  }
  let start = fn() -> DriveAt? {
    match stations().iter().find_first(fn(s) { s.station == station }) {
      Some(s) if s.anywhere && s.home != "" => Some({ station, root: Some(s.home), path: "" })
      Some(s) if s.roots.length() == 1 => Some({ station, root: Some(s.roots[0].path), path: "" })
      _ => None
    }
  }
  // (where it is: a folder of a station still lending it, else the places)
  let place = fn() -> DriveAt? {
    let at = match ftab_place_of(scope) {
      Some(p) => p
      None => start()
    }
    match at {
      Some(a) if a.root is Some(_) && stations().iter().any(fn(s) { s.station == a.station }) => Some(a)
      _ => None
    }
  }
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  v.box(fn(body) {
    body.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    body.pick(place, fn(b, at) {
      b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      match at {
        None => ftab_places_node(b, src, ws, scope, stations)
        Some(at) => {
          let st = fn() {
            stations().iter().find_first(fn(s) { s.station == at.station }).unwrap_or(@sfbase.dv_station({ "station": Json::string(at.station) }))
          }
          ftab_folder_node(b, src, ws, chat, scope, at, st, tips)
        }
      }
    })
  })
  |> ignore
  // 添加 (添加 n once something is picked) at its foot: pressed, what is picked goes into the chat's message (files_into:
  // the composer takes it, by its path or as a file as the chat says), the picks let go
  v.box(fn(f) {
    @sf.style_node(f, fn() { ftab_foot.then(foot()) })
    let n = fn() { ntab_picks(chat).length() }
    @sf.button_node(
      f,
      fn() {
        if n() == 0 {
          @sf.t("web-mobile.files.add")
        } else {
          @sf.t("web-mobile.files.addCount", args=[("n", n().to_string())])
        }
      },
      fn() {
        for d in @signals.untracked(fn() { ntab_picks(chat) }) {
          files_into(chat, d)
        }
        ntab_picked.set((chat, []))
      },
      tone=Primary,
      disabled=fn() { n() == 0 },
    )
    |> ignore
  })
  |> ignore
}

///|
/// A line of the places (ftab_places_node): a section's heading (its title, what is said under it), a place to go to
/// (its title, where it is, what is wrong with it, its mark, the station, root and path it goes to, the piece of its
/// section's card it is), or none to show; by its key.
#derive(Eq)
priv struct TabPlace {
  key : String
  head : Bool
  title : String
  note : String
  trouble : String
  icon : String
  station : String
  root : String
  path : String
  piece : @sf.CardPiece
}

///|
/// The places, as the files' sidebar has them (files_places): the person's own folders kept at hand (个人收藏, of the
/// stations shown, while there are any), then each station a section (its name, 离线 under it while away), the places
/// its drive offers one who browses every folder (its home, the home's own folders, its disks; its home alone while
/// they are read), then its folders pinned not among those (what is wrong with one in red).
fn ftab_place_lines(src : Source, ws : String, stations : Array[DvStation]) -> Array[TabPlace] {
  let out : Array[TabPlace] = []
  let section = fn(key : String, title : String, note : String, rows : Array[TabPlace]) {
    out.push({ key: "h|" + key, head: true, title, note, trouble: "", icon: "", station: "", root: "", path: "", piece: CardWhole })
    for i, r in rows {
      out.push({ ..r, piece: @sf.card_piece_of(i, rows.length()) })
    }
  }
  let favs = @sfpages.favorites(src, ws).filter(fn(f) { stations.iter().any(fn(s) { s.station == f.station }) })
  if favs.length() > 0 {
    let rows = favs.map(fn(f) -> TabPlace {
      let name = stations.iter().find_first(fn(s) { s.station == f.station }).map(fn(s) { s.name }).unwrap_or("")
      {
        key: "f|" + f.station + "|" + f.root + "|" + f.path,
        head: false,
        title: f.name,
        note: name,
        trouble: "",
        icon: "folder",
        station: f.station,
        root: f.root,
        path: f.path,
        piece: CardWhole,
      }
    })
    section("favorites", @sf.t("web-pages.files.favorites"), "", rows)
  }
  for s in stations {
    let rows : Array[TabPlace] = []
    let row = fn(icon : String, name : String, where_ : String, trouble : String, root : String) {
      rows.push({
        key: "p|" + s.station + "|" + root,
        head: false,
        title: name,
        note: where_,
        trouble,
        icon,
        station: s.station,
        root,
        path: "",
        piece: CardWhole,
      })
    }
    let shown : Array[String] = []
    if s.anywhere {
      match @sfpages.station_places_read(src, s) {
        Some(places) if places.length() > 0 =>
          for i, p in places {
            let (name, path, disk) = p
            let icon = if disk { "disk" } else if i == 0 && path == s.home { "server" } else { "folder" }
            shown.push(path)
            row(icon, name, path, "", path)
          }
        _ => if s.home != "" { row("server", @sf.t("web-pages.drive.home"), s.home, "", s.home) }
      }
    }
    // (a folder pinned that is among them already: once)
    for r in s.roots.filter(fn(r) { !shown.contains(r.path) }) {
      let trouble = match r.state {
        "ok" => ""
        "missing" => @sf.t("web-pages.drive.root.missing")
        "not_a_directory" => @sf.t("web-pages.drive.root.notFolder")
        _ => @sf.t("web-pages.drive.root.unreadable")
      }
      row("folder", r.name, r.path, trouble, r.path)
    }
    section("s|" + s.station, s.name, if s.online { "" } else { @sf.t("web-pages.stations.offline") }, rows)
  }
  out
}

///|
/// The places (Places) in node `v`, its lines in a list of their own (ftab_place_lines), each a block made only while
/// it shows, keyed: a row pressed goes there (the tab of `scope` put in that folder). Once the stations are read and
/// none lends its files, saying so.
fn ftab_places_node(v : @view.View, src : Source, ws : String, scope : String, stations : () -> Array[DvStation]) -> Unit {
  v.pick(fn() { dv_stations(src, ws).0 is Some(_) && stations().is_empty() }, fn(p, none) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    @sf.style_node(p, fn() { ftab_list })
    p.min_height(Is(Some(0.0))) |> ignore
    if none {
      @sf.page_note_node(p, fn() { @sf.t("web-main.rail.filesNone") })
      return
    }
    let keyed = p.keyed_by(fn() { ftab_place_lines(src, ws, stations()) }, fn(l) { l.key })
    // (a line's block taken by the next of its make (a station's heading, a place's row) to show as it no more does,
    // its key that one's)
    p.scrolls_reused(
      @view.Scroll::list(),
      fn() { keyed.keys() },
      shape=fn(k) { if keyed.peek(k).map_or(false, fn(l) { l.head }) { 0 } else { 1 } },
      est=ftab_place_est,
      slop=@ui.touch_slop(),
      bar=@ui.tree_scroll_bar(),
      foot=fn(f) { f.height(Is(Some(ftab_places_foot))) |> ignore },
      fn(b, k) {
        // (its make, which never changes for a block: `shape`'s)
        guard @signals.untracked(fn() { keyed.get(k()) }) is Some(first) else { return }
        // (its key's line as it is now, the last it was where its key is gone from the list: what it shows as it goes)
        let last = Ref(first)
        let now = fn() {
          match keyed.get(k()) {
            Some(l) => {
              last.val = l
              l
            }
            None => last.val
          }
        }
        if first.head {
          @sf.section_heading_node(b, fn() { now().title }, note=fn() { now().note })
          return
        }
        @sf.card_piece_node(b, fn() { now().piece }, fn(r) {
          @sf.link_row_node(
            r,
            fn() { now().title },
            fn() {
              let l = @signals.untracked(now)
              ftab_put(scope, Some({ station: l.station, root: Some(l.root), path: l.path }))
            },
            note=fn() { now().note },
            trouble=fn() { now().trouble },
            lead=@sf.LeadLine(fn(l) {
              @sf.icon_node(l, "", tab_icon, By(fn() { @sf.theme().p.muted }), name_now=fn() { now().icon }) |> ignore
            }),
          )
        })
      },
    )
    |> ignore
  })
}

///|
/// The tab's browsing of the folder `at` (the files' page's: its order, the core told where it is), as a list: the
/// place `scope`'s (where it is kept), the same for every chat's tab of it.
fn ntab_browse_of(scope : String, at : DriveAt) -> @sfpages.Browse {
  {
    key: "tab/" + scope,
    owner: "tab",
    view: fn() { "list" },
    at: fn() { at },
    write: fn() { false },
    does: { open: fn(_, _) {  }, preview: fn(_, _) {  }, go: fn(_, _) {  }, remove: fn(_) {  } },
  }
}

///|
/// What a folder's list shows: read the first time, failing to be read, or what is in it.
#derive(Eq)
priv enum TabFolderShows {
  TabReading
  TabFailed
  TabRead
}

///|
/// Folder `at` (FolderList) of station `st` in node `v`, for chat `chat`'s message: the trail over it (its station's
/// name the way back to the places, then the way to it from the home, the disk's top or the folder pinned) and what is
/// done to it at the trail's end (收藏, the preview, 复制路径, 在此处打开终端 where this device opens the station's terminals, 刷新); its list as the tab shows it, the folder as a whole
/// over its rows; the preview under it while it is shown. Nothing here changes the files.
fn ftab_folder_node(
  v : @view.View,
  src : Source,
  ws : String,
  chat : String,
  scope : String,
  at : DriveAt,
  st : () -> DvStation,
  tips : @sf.TipLayer,
) -> Unit {
  let root = at.root.unwrap_or("")
  let here = dv_absolute(root, at.path)
  let b = ntab_browse_of(scope, at)
  b.follow(v, src)
  let go = fn(to : DriveAt?) {
    // (a folder pressed and read meanwhile, browse_switch's: waited for no more, the tab put elsewhere)
    @sfpages.browse_switch_off(b.key)
    ftab_put(scope, to)
  }
  let go_in = fn(station : String, root : String, path : String) { go(Some({ station, root: Some(root), path })) }
  // the way here: from the home (or the disk's top) for one who browses everywhere, else from the folder pinned
  let way = fn() -> Array[(String, String)] {
    let st = st()
    if st.anywhere {
      ftab_trail(here, st.home)
    } else {
      let first = match st.roots.iter().find_first(fn(r) { r.path == root }) {
        Some(r) => r.name
        None => dv_name(root)
      }
      let out = [(first, root)]
      let mut so_far = ""
      for part in at.path.split("/") {
        if part != "" {
          so_far = dv_join(so_far, part.to_owned())
          out.push((part.to_owned(), dv_absolute(root, so_far)))
        }
      }
      out
    }
  }
  let go_to = fn(abs : String) {
    let prefix = if root.has_suffix("/") { root } else { root + "/" }
    if abs == root {
      go_in(at.station, root, "")
    } else if abs.has_prefix(prefix) {
      go_in(at.station, root, abs.exact_view(start=prefix.length()).to_owned())
    } else {
      go_in(at.station, abs, "")
    }
  }
  let kept = fn() { @sfpages.favorite_has(@sfpages.favorites_in(src, ws, [st()]), at.station, root, at.path) }
  let previewing = fn() { @sfpages.preview_shown(src, "tab") }
  let lit = fn(on : Bool) { if on { @sf.theme().p.accent } else { @sf.theme().p.muted } }
  // its trail and what is done to it
  v.box(fn(h) {
    @sf.style_node(h, fn() { ftab_head })
    h.box(fn(t) {
      // (what is left of the head by what is done to the folder, as narrow as it must be)
      @sf.style_node(t, fn() { ftab_trail_box }, in_row=true)
      t.min_width(Is(Some(0.0))) |> ignore
      @sf.way_line_node(t, fn() { [st().name] + way().map(fn(w) { w.0 }) }, ftab_way, fn(i) {
        if i == 0 {
          go(None)
        } else {
          let w = @signals.untracked(way)
          if i - 1 < w.length() {
            go_to(w[i - 1].1)
          }
        }
      })
      |> ignore
    })
    |> ignore
    h.box(fn(a) {
      @sf.style_node(a, fn() { ftab_actions }, in_row=true)
      @sf.icon_button_node(
        a,
        "star",
        fn() {
          @sf.t(if kept() { "web-pages.files.unfavorite" } else { "web-pages.files.favorite" }, args=[("name", @sfpages.folder_name(st(), at))])
        },
        fn() {
          if @signals.untracked(kept) {
            @sfpages.favorite_remove(src, ws, at.station, root, at.path)
          } else {
            @sfpages.favorite_add(src, ws, { station: at.station, root, path: at.path, name: @sfpages.folder_name(@signals.untracked(st), at) })
          }
        },
        tips~,
        ink=fn() { lit(kept()) },
        on=kept,
      )
      |> ignore
      @sf.icon_button_node(
        a,
        "panel-open",
        fn() { @sf.t(if previewing() { "web-pages.files.hidePreview" } else { "web-pages.files.showPreview" }) },
        fn() { @sfpages.set_preview_shown(src, "tab", !@signals.untracked(previewing)) },
        tips~,
        icon_now=fn() { if previewing() { "panel-close" } else { "panel-open" } },
        ink=fn() { lit(previewing()) },
        on=previewing,
      )
      |> ignore
      @sf.icon_button_node(a, "copy", fn() { @sf.t("web-pages.drive.copyPath") }, fn() { @sfpages.copy_path(here) }, tips~) |> ignore
      // (a terminal opened in this folder, where this device opens a station's terminals and the station has them)
      a.show(at_once=true, fn() { @sfpages.terminals_here() && (src.asks_terminals)() && here != "" }, fn(t) {
        t.shrink(Is(0.0)) |> ignore
        @sf.icon_button_node(
          t,
          "terminal",
          fn() { @sf.t("web-pages.remote.openHereTerminal") },
          fn() { @sfbase.open_terminal(at.station, "new", here, "") },
          tips~,
        )
        |> ignore
      })
      @sf.icon_button_node(a, "refresh", fn() { @sf.t("web-pages.drive.refresh") }, fn() { @sfpages.refresh_folder(src, at) }, tips~) |> ignore
    })
    |> ignore
  })
  |> ignore
  let dragged_of = fn(in_ : DriveAt, e : DvEntry) -> Dragged {
    let path = dv_join(in_.path, e.name)
    { station: in_.station, station_name: st().name, root, path, abs: dv_absolute(root, path), name: e.name, size: e.size, dir: e.dir }
  }
  let open = fn(in_ : DriveAt, e : DvEntry) {
    // (a folder's entries as shown, for a preview to step through the pictures beside it: the one shown's)
    let near = if in_.path == at.path { b.arranged(src, in_.path).unwrap_or([]) } else { [] }
    @sfpages.open_entry(src, "tab", in_, e, near, fn(to) { go_in(to.station, to.root.unwrap_or(""), to.path) })
  }
  // a press: a folder gone into (once what it shows is read, the one shown as it is meanwhile: browse_switch), a file
  // picked (or no longer)
  let pressed = fn(in_ : DriveAt, e : DvEntry) {
    if e.dir {
      let path = dv_join(in_.path, e.name)
      @sfpages.browse_switch(src, [(b, { view: "list", at: { ..at, path, } })], b.key, fn(_, _) { [path] }, fn() { go_in(at.station, root, path) })
    } else {
      ntab_pick(chat, dragged_of(in_, e))
    }
  }
  let items = fn(in_ : DriveAt, e : DvEntry) -> Array[@sf.MenuItem?] {
    let abs = dv_absolute(root, dv_join(in_.path, e.name))
    let out : Array[@sf.MenuItem?] = []
    // (a file is opened from here: a press picks it)
    if !e.dir {
      out.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.open"), icon="external", fn() { open(in_, e) })))
    }
    match @sfpages.entry_beside(in_, e) {
      Some(f) => out.push(Some(@sf.menu_item_of(@sf.t("web-main.preview.openBeside"), icon="panel-open", f)))
      None => ()
    }
    out.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.sendToChat"), icon="send", fn() { files_into(chat, dragged_of(in_, e)) })))
    out.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.copyPath"), icon="copy", fn() { @sfpages.copy_path(abs) })))
    if !e.dir {
      out.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.download"), icon="download", fn() { @sfpages.save_entry(src, in_, e) })))
    }
    if e.dir {
      if @sfpages.terminals_here() && (src.asks_terminals)() && abs != "" {
        out.push(Some(@sf.menu_item_of(@sf.t("web-pages.remote.openHereTerminal"), icon="terminal", fn() {
          @sfbase.open_terminal(in_.station, "new", abs, "")
        })))
      }
      let path = dv_join(in_.path, e.name)
      let saved = @sfpages.favorite_has(@sfpages.favorites_in(src, ws, [st()]), at.station, root, path)
      out.push(Some(@sf.menu_item_of(@sf.t(if saved { "web-pages.files.unfavorite" } else { "web-pages.files.favorite" }, args=[("name", e.name)]), icon="star", fn() {
        if saved {
          @sfpages.favorite_remove(src, ws, at.station, root, path)
        } else {
          @sfpages.favorite_add(src, ws, { station: at.station, root, path, name: e.name })
        }
      })))
    }
    out
  }
  let s : @sfpages.Shown = {
    src,
    b,
    row_of: fn(in_, e) {
      {
        items: fn() { items(in_, @signals.untracked(e)) },
        open: fn() { pressed(in_, @signals.untracked(e)) },
        press: fn() { pressed(in_, @signals.untracked(e)) },
        menu: fn() {  },
        chosen: fn() {
          let e = e()
          !e.dir && ntab_is_picked(chat, dragged_of(in_, e))
        },
        renaming: fn() { false },
        rename: fn(_) {  },
        drop: None,
      }
    },
    drop_on: fn(_) { None },
    clear: fn() { b.clear(src) },
    write: fn() { false },
    transfers: fn() { false },
    stacked: fn() { false },
    carries: tab_drag_node,
  }
  // the folder shown, picked as a whole
  let whole = fn() -> Dragged {
    let w = way()
    {
      station: at.station,
      station_name: st().name,
      root,
      path: at.path,
      abs: here,
      name: if at.path == "" { w[w.length() - 1].0 } else { dv_name(at.path) },
      size: 0.0,
      dir: true,
    }
  }
  v.box(fn(list) {
    @sf.style_node(list, fn() { ftab_list })
    list.min_height(Is(Some(0.0))) |> ignore
    // (a ground round its rows: a press there chooses none)
    list.presses(Is(true)).on_press(s.clear) |> ignore
    list.pick(fn() {
      let (value, error) = b.folder(src, at)
      match (value, error) {
        (None, Some(_)) => TabFailed
        (None, None) => TabReading
        (Some(_), _) => if b.arranged(src, at.path) is None { TabReading } else { TabRead }
      }
    }, fn(l, shows) {
      l.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      match shows {
        TabFailed =>
          l.box(fn(p) {
            @sf.style_node(p, fn() { ftab_problem })
            @sf.words_node(p, fn() { b.folder(src, at).1.unwrap_or("") }, fn() { tab_trouble }) |> ignore
            @sf.button_node(p, fn() { @sf.t("web-pages.drive.retry") }, fn() { @sfpages.refresh_folder(src, at) }, tone=Ghost, icon="retry") |> ignore
          })
          |> ignore
        TabReading => @sfpages.rows_sample_node(l, s, at, 5, compact=true, card=false)
        TabRead =>
          @sfpages.rows_view_node(
            l,
            s,
            at,
            false,
            compact=true,
            card=false,
            head=fn(hv) {
              // (the folder as a whole, where it is under it: the library's row of choices, as the places' rows)
              @sf.choice_row_node(
                hv,
                fn() { @sf.t("web-mobile.files.wholeFolder") },
                fn() { ntab_is_picked(chat, whole()) },
                press=fn() { ntab_pick(chat, @signals.untracked(whole)) },
                note=fn() { here },
                compact=true,
                // (its mark as large as the rows' under it, as far in: its words start where theirs do)
                lead=fn(m) {
                  @sf.icon_node(m, "folder", @signals.untracked(fn() { @sf.theme().items.mark - ftab_mark_less }), By(fn() {
                    @sf.theme().p.muted
                  }))
                  |> ignore
                },
                // (its ground round as the rows' under it, standing in from the panel's sides: never square in its corners;
                // as far in as theirs, sfpages' row_compact)
                grounded=fn(g) {
                  g.radius(Is(@sf.row_corner)).padding(Is((ftab_row_in, ftab_row_in, ftab_row_in, ftab_row_in))) |> ignore
                },
              )
            },
            empty=fn(e) { @sf.words_node(e, fn() { @sf.t("web-pages.drive.emptyFolder") }, fn() { ftab_note }) |> ignore },
          )
      }
    })
  })
  |> ignore
  // the preview under the list: what was picked last in the folder shown, what a pick is, seen before it goes into the
  // message
  v.show(previewing, fn(slot) {
    let shown = fn() -> @sfpages.Previewed {
      let picked = ntab_picks(chat).filter(fn(d) { d.station == at.station && !d.dir && dv_parent(d.path) == at.path })
      match picked.last() {
        Some(d) =>
          match @sfbase.dv_entries(src, at.station, root, at.path).unwrap_or([]).iter().find_first(fn(e) { e.name == d.name }) {
            Some(e) => One(at, e)
            None => Nothing
          }
        None => Nothing
      }
    }
    @sfpages.drive_pane_node(
      slot,
      src,
      shown,
      fn() { st().name },
      fn() {
        match @signals.untracked(shown) {
          One(pat, e) => open(pat, e)
          _ => ()
        }
      },
      fn() {
        match @signals.untracked(shown) {
          One(pat, e) => @sfpages.save_entry(src, pat, e)
          _ => ()
        }
      },
      below=true,
    )
  })
}

///|
/// The trail's look: its steps the option's corner, 3 by 4 in, in the meta's muted, the folder shown bold in the words'
/// ink; its chevrons (12) muted.
fn ftab_way() -> @sf.WayLook {
  {
    line: ftab_way_line,
    step: ftab_step,
    words: ftab_step_words,
    here: ftab_step_last,
    chevron: ftab_chevron,
    chevron_ink: @sf.theme().p.muted,
  }
}

///|
// kept across runs: a value (no field of it changes)
let ftab_way_line : @ui.Style = @ui.css("row gap=SPx align=ACenter")

///|
/// A place's line, as tall as it mostly is till it is laid out; under the last (30).
let ftab_place_est : Double = 52.0

///|
let ftab_places_foot : Double = 30.0

///|
/// The folder as a whole's row as far in as a compact row of a folder's (sfpages' row_compact: 10 in), its mark 2 less
/// than the screen's, as theirs.
let ftab_row_in : Double = 10.0

///|
let ftab_mark_less : Double = 2.0
