// The sidebar made once over the block (pane_view's and tape_view's `sides`): where the block lays its sidebar out
// (SideAt), the sidebar the block holds now (side_place), each made as nodes of the window's tree: the chats' lists for
// the chats' places (with 已归档 among them, the band over them and the foot under them), the settings' list for the
// settings', the stations' and the profiles' lists for the rail's places of theirs (places_side_node.mbt), the files'
// for theirs (files_side_node.mbt).

///|
/// The sidebar the block holds now in node `n` (as large as what holds the block, over it), where `at` says the block
/// has it: cut to the block's room, its corners the block's (its line over it, dock_edge_node's); shown while what is in
/// it is drawn.
fn side_node(n : @view.View, src : Source, tips : @sf.TipLayer, at : () -> SideAt) -> Unit {
  n.box(fn(cut) {
    cut
    // (not shown, as the device waits in the lock: laid out nowhere, the same nodes, what had the focus in it given
    // it back as it is shown again, as an old view's focus waits for its node)
    .laid_nowhere(By(fn() { !at().shown }))
    .clips(Is(true))
    .width(By(fn() { Some(at().block.2) }))
    .height(By(fn() { Some(at().block.3) }))
    .offset(By(fn() { (at().block.0, at().block.1) }))
    |> ignore
    dock_round_node(cut, at)
    cut.box(fn(side) {
      // (where the rail's lit place pressed again finds its list: back_to_top.mbt)
      side_made.val = Some(side)
      side.owns(fn() {
        match side_made.val {
          Some(v) if physical_equal(v, side) => side_made.val = None
          _ => ()
        }
      })
      |> ignore
      side
      .width(By(fn() { Some(at().laid_w) }))
      .height(By(fn() { Some(at().box.3) }))
      .offset(By(fn() { (at().box.0 - at().block.0, at().box.1 - at().block.1) }))
      |> ignore
      side.pick(at_once=true, fn() { if side_place() == "archive" { "chats" } else { side_place() } }, fn(s, place) {
        match place {
          // (the settings' list beside their pages: settings_frame.mbt)
          "settings" => settings_side_node(s, src, tips, at)
          // (the files' places: files_side_node.mbt; the rail's Station and Profile places' lists: places_side_node.mbt)
          "files" => files_side_node(s, src, tips, at)
          "stations" => stations_side_node(s, src, tips, at)
          "profiles" => profiles_side_node(s, src, tips, at)
          // (远程's: its band over the remote list, made as the chats' sidebar is)
          "remote" => remote_side_node(s, src, tips, at)
          // (the chats' lists: a place of the rail's of theirs, or what the frame shows by default)
          _ => lists_side_node(s, src, tips, at)
        }
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// What the chats' sidebar (lists_side_node) shows of workspace `ws` as it opens, asked of `ask` (sfbase's
/// opens_answered): its list as it is filtered (sfbase's list_opens); the band's and the foot's of all its chats
/// (what is catching up, whether it has stations to filter, their trouble: chats_all_opens); 待处理's count, of the
/// core's marks; what is left up long, the foot's 运行中 (where the foot shows it).
fn side_opens(src : Source, ws : String, ask : (String, Map[String, Json]) -> @sfbase.TopicState) -> Bool {
  let list = @sfbase.list_opens(src, ws, ask)
  let all = @sfbase.chats_all_opens(src, ws, ask)
  let marks = @sfbase.opens_answered(ask("workspaceMarks", @sfbase.marks_asked()))
  // (the foot's 运行中 reads it where the bell is not in the rail: in its panel then, read as that opens, lists_foot)
  let long = rail_items(src, ws).contains("attention") ||
    @sfbase.opens_answered(ask("longJobs", @sfbase.long_jobs_asked(ws)))
  list && all && marks && long
}

///|
/// The band as a sidebar's block laid out `a` has it (BandAt), `held`: as the lists under it are laid out, on a fold the
/// open end's all the way (list_brand, list_band), so their rows are not laid out again at each frame; else where the
/// block's move has got, as the band itself is drawn.
fn side_band_at(a : SideAt, held : Bool) -> BandAt {
  {
    brand: if held { a.list_brand } else { a.brand },
    band: if held { a.list_band } else { a.band },
    tape: a.tape,
    in_bar: a.bar,
    roots: @ui.tree_corner_roots_now(),
  }
}

///|
/// The chats' sidebar (lists_side's) in node `s` as wide as the sidebar: the lists (sfpages' chats_lists_node: 全部,
/// 我参与的, 监控中, then 已归档 on its track: archive_pane_node) under the band (新建对话 and the filter: lists_band_node)
/// and over the foot (lists_foot_node).
fn lists_side_node(s : @view.View, src : Source, tips : @sf.TipLayer, at : () -> SideAt) -> Unit {
  let workspace = fn() { @sfbase.workspace_in_view(src).0 }
  // (the tape's side column or one beside the page: the block's, each its own sidebar made once)
  let list_at = side_list_at(@signals.untracked(at))
  let mode = fn() {
    match workspace() {
      Some(w) => list_mode(src, w)
      None => 0
    }
  }
  let band_at = fn(held : Bool) { side_band_at(at(), held) }
  // (under the band and its top row: on a fold the open end's room all the way, while the band moves over them, so
  // their rows are not laid out again at each frame)
  let lists_top = fn() {
    match workspace() {
      Some(w) => band_h(src, w, at=band_at(true))
      None => 0.0
    }
  }
  let frame : @sfpages.ListsNodeFrame = {
    top: lists_top,
    under: fn() {
      band_at(true).brand
    },
    // (over the foot's band where it shows: their last row clear of it, their bar too, lists_foot_h)
    foot: fn() { lists_foot_h(src, workspace) },
    // (on the tape the block's, a step darker behind the panel in use: tape_side_at)
    ground: fn() {
      if wide.tape.get() {
        at().ground
      } else if side_folded() {
        apart_ground()
      } else {
        @sf.theme().p.sidebar
      }
    },
    before: fn(_, _) {
      let parts : Array[@sfpages.NodePart] = []
      if @sfpages.stale_build_card_shown() {
        parts.push({ key: "stale-build-card", make: fn(p) { @sfpages.stale_build_card_node(p, src) } })
      }
      parts
    },
    after: fn(_, _) { [] },
    others: [
      fn(p) {
        // (已归档, all of its lane, as a list is: under all of the band (band_h: its top row's room too, as the old lane
        // had it, its search field where it stood beside a folded sidebar's way), over the foot's band, of the workspace
        // in view as it changes)
        archive_pane_node(
          p,
          src,
          fn() { workspace().map(fn(w) { w.id }).unwrap_or("") },
          fn() {
            match workspace() {
              Some(w) => band_h(src, w, at=band_at(false))
              None => 0.0
            }
          },
          fn() { lists_foot_h(src, workspace) },
          list_at,
          tips,
          fn() { 0 },
        )
      },
    ],
    shown: mode,
    at: list_at,
    watched: fn() { true },
  }
  // (while the app's first page waits for what it shows: drawn at none, the splash in its place, as the old views are)
  s.grow(Is(1.0)).min_height(Is(Some(0.0))).alpha(By(fn() { if @sfbase.first_page_waits.get() { 0.0 } else { 1.0 } }))
  |> ignore
  // under a finger's search (sfpages' search.mbt): the band and the foot away with the lists, the search over them
  let away = @sfpages.search_away_node(s)
  s.box(fn(lists) {
    // (their room for the band held on the block's way: drawn where the band has them as it goes, lists_side's)
    lists
    .over(Is(true))
    .drawn_off(By(fn() {
      match workspace() {
        Some(w) => (0.0, band_h(src, w, at=band_at(false)) - band_h(src, w, at=band_at(true)))
        None => (0.0, 0.0)
      }
    }))
    |> ignore
    @sfpages.chats_lists_node(lists, src, workspace, frame, tips, fn() { 0 })
  })
  |> ignore
  // the band over the lists, the foot under them: each only as tall as it is, the lists under them the rest (what the
  // pointer is over and a press takes there)
  s.box(fn(o) {
    o.over(Is(true)).alpha(By(fn() { 1.0 - away() })) |> ignore
    lists_band_node(o, src, tips, workspace, at)
    o.box(fn(between) { between.grow(Is(1.0)) |> ignore }) |> ignore
    lists_foot_node(o, src, workspace, at)
  })
  |> ignore
  s.show(@sfpages.search_on_lists, fn(k) {
    @sfpages.search_page_node(k, src, workspace, fn() { at().brand }, list_at)
  })
}

///|
/// The band over the chats' lists (lists_band's) in `o`, where `at` says the block has it: on the sidebar's own ground
/// (the closed bar's as it closes), its top row, then 新建对话, what is catching up (its old view), the update where one
/// is offered and the filter (with stations to narrow) on one line; 待处理 under them where the rail has no bell.
fn lists_band_node(
  o : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  workspace : () -> Workspace?,
  at : () -> SideAt,
) -> Unit {
  let list_at = side_list_at(@signals.untracked(at))
  let band_at = fn() {
    let a = at()
    ({ brand: a.brand, band: a.band, tape: a.tape, in_bar: a.bar, roots: @ui.tree_corner_roots_now() } : BandAt)
  }
  let view = fn() {
    match workspace() {
      Some(w) => chats_of(src, w.id, "all").0
      None => None
    }
  }
  o.box(fn(band) {
    // (on the tape the block's ground, a step darker behind the panel in use as the lists under it are: tape_side_at)
    band.ground(By(fn() {
      let a = at()
      @sf.mix(if a.tape { a.ground } else { apart_ground() }, a.band, @sf.theme().p.sidebar)
    }))
    |> ignore
    // (its top row the window's title bar where the window's buttons are in the app's top row, under what is in it: as
    // tall as their row however short the band's own top is (no buttons at its left: a Windows window), not folded)
    band.box(fn(o) {
      o.over(Is(true)) |> ignore
      o.box(fn(row) {
        row
        .width(By(fn() { Some(at().laid_w) }))
        .height(Is(Some(closed_bar_top)))
        .laid_nowhere(By(fn() { !@ui.window_inset_now() || side_folded() }))
        .moves_window(By(fn() { @ui.window_inset_now() && !side_folded() }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    side_top_node(band, fn() { band_at().brand })
    band.box(fn(line) {
      @sf.style_node(line, fn() {
        let a = band_at()
        if a.tape {
          band_new_tape(at=a)
        } else {
          band_new_pane(at=a)
        }
      })
      line.box(fn(full) {
        full.row(Is(true)).grow(Is(1.0)) |> ignore
        // (beside the system's bars, the workspace's button in their glass in its place, as high as its row: 新建对话 the
        // system's tab bar's own action there, rail_native.mbt)
        full.pick(@sf.native_on, fn(r, native) {
          r.row(Is(true)).grow(Is(1.0)) |> ignore
          if native {
            workspace_glass_node(r, src, workspace)
          } else {
            @sf.band_row_node(r, fn() { app.nav.top() is NewChat }, fn() { @sf.t("web-main.sidebar.newChat") }, new_chat, list_at, fn(
              b,
            ) {
              @sf.icon_node(b, "compose", @sf.theme().chat_list.band_icon, By(fn() { @sf.theme().p.muted })) |> ignore
              @sf.nav_words_node(b, fn() { @sf.t("web-main.sidebar.newChat") })
            })
          }
        })
      })
      |> ignore
      // catching up on what changed while away
      line.show(at_once=true, fn() { view().map(fn(v) { v.syncing is Some(_) }).unwrap_or(false) }, fn(k) {
        native_floating_schedule()
        k.owns(native_floating_schedule) |> ignore
        @sf.sync_key_node(k, tips, update_key_side, update_key_mark, fn() {
          match view() {
            Some({ syncing: Some(y), .. }) => Some(y)
            _ => None
          }
        })
      })
      // 更新 before the filter where one is offered (brand.mbt update_key_of); omitted in the chats band while the
      // over-7-day upgrade card is already shown right below (still shown in the collapsed bar and other sidebars).
      let band_update = fn() { update_shown() && !@sfpages.stale_build_card_shown() }
      line.show(at_once=true, band_update, fn(k) {
        native_floating_schedule()
        k.owns(native_floating_schedule) |> ignore
        update_key_of(k, src, tips)
      })
      // the stations' newer releases waiting for this person beside it, as the app's own is offered; pressed, their
      // dialog (sfpages station_updates.mbt)
      let stations_said = fn() {
        match workspace() {
          Some(w) if (src.asks_station_updates)() => @sfpages.station_updates_said(settings_core(src, w), w.id)
          _ => ""
        }
      }
      // (the app's own offered too: one key, the app's, opening the dialog of both: update_pressed)
      line.show(at_once=true, fn() { stations_said() != "" && !band_update() }, fn(k) {
        native_floating_schedule()
        k.owns(native_floating_schedule) |> ignore
        @sf.update_key_node(k, tips, update_key_side, update_key_mark, stations_said, stations_said, fn() { false }, fn() { None }, fn() {
          match @signals.untracked(workspace) {
            Some(w) => @sfpages.station_updates_dialog(src, settings_core(src, w), w.id)
            None => ()
          }
        }, offered=fn() { true })
      })
      // beside the system's bars, the search and the filter in their glass (rail_native.mbt: what each does there)
      line.show(at_once=true, @sf.native_on, fn(k) {
        sidebar_glass_node(k, "sidebar/search", fn() { @sf.t("android-chat.search.field") }, "search", fn() { [] })
      })
      line.show(at_once=true, fn() { @sf.native_on() && view().map(fn(v) { v.stations > 0 }).unwrap_or(false) }, fn(k) {
        let shown = fn() {
          match workspace() {
            Some(w) => list_place(list_mode(src, w))
            None => "chats"
          }
        }
        sidebar_glass_node(
          k,
          "sidebar/filter",
          fn() { @sf.t("web-main.filter.chats.named", args=[("named", filter_named(shown()))]) },
          "filter",
          fn() { filter_glass_rows(shown()) },
        )
      })
      // the filter: its menu (sfpages' filter_menu), a filter its list, 已归档 the archive's list
      line.show(at_once=true, fn() { !@sf.native_on() && view().map(fn(v) { v.stations > 0 }).unwrap_or(false) }, fn(k) {
        let shown = fn() {
          match workspace() {
            Some(w) => list_place(list_mode(src, w))
            None => "chats"
          }
        }
        // (its menu, while drawn: what it says of itself)
        let opener = @sf.Opener::new()
        @sf.action_box_node(k, fn() { @sf.t("web-main.filter.chats.named", args=[("named", filter_named(shown()))]) }, fn(f) {
          guard @signals.untracked(workspace) is Some(w) else { return }
          let (x, y, wd, h) = f.placed_window_now()
          let now = @signals.untracked(shown)
          @sfpages.filter_menu(At(x, y, wd, h), if now == "chats" { "all" } else { now }, fn(pick) {
            rail_go_told(src, w, if pick == "all" { "chats" } else { pick }, fn(_, g) { g() })
          })
          opener.mark()
        }, expanded=fn() { opener.open() }, fn(f) {
          let hot = @motion.hover_fade(f, fn() { @sf.lit_node(f) || @sfpages.filter_menu_open() }, duration_ms=@sf.dur_ms)
          @sf.style_node(f, fn() { filter_box })
          // (round as its ground is while it shows one, as an old view's is drawn: at rest nothing of it stands in the
          // panel's corner; in the closed bar's, its corner linked, below)
          f.radius(By(fn() { if band_at().in_bar || hot() > 0.0 { 1.0e6 } else { 0.0 } })) |> ignore
          // (in the closed bar's corner, its ground's corner linked to that corner, concentric with it: filter_box_bar)
          @ui.tree_corners_linked(f, fn() {
            if band_at().in_bar {
              Some(FixedArray::make(4, filter_bar_link()))
            } else {
              None
            }
          })
          f.ground(By(fn() { @sf.alpha(@sf.theme().p.hover, hot()) })) |> ignore
          @sf.icon_node(f, "filter", side_icon, By(fn() {
            let t = @sf.theme()
            @sf.mix(t.p.text, hot(), t.p.muted)
          }))
          |> ignore
          @sf.tip_node(tips, f, fn() { @sf.t("web-main.filter.chats") }) |> ignore
        })
        |> ignore
      })
    })
    |> ignore
    // 待处理 under 新建对话 where the rail has no bell
    band.show(at_once=true, fn() { workspace().map(fn(w) { todo_shown(src, w) }).unwrap_or(false) }, fn(k) {
      k.box(fn(t) {
        @sf.style_node(t, fn() { todo_box })
        // (what 待处理's panel opens under: attention_node.mbt)
        side_attention.val = Some(t)
        t.owns(fn() {
          match side_attention.val {
            Some(v) if physical_equal(v, t) => side_attention.val = None
            _ => ()
          }
        })
        |> ignore
        let n = fn() { workspace().map(fn(w) { todo_all(src, w) }).unwrap_or(0) }
        @sf.band_row_node(t, fn() { wide.attention_open.get() }, fn() { @sf.t("web-main.attention.entry") }, fn() {
          attention_set(!wide.attention_open.untracked())
        }, list_at, fn(r) {
          @sf.icon_node(r, "bell", @sf.theme().chat_list.band_icon, By(fn() { @sf.theme().p.muted })) |> ignore
          @sf.nav_words_node(r, fn() { @sf.t("web-main.attention.entry") })
          r.box(fn(slot) {
            @sf.style_node(slot, fn() { todo_slot })
            slot.show(at_once=true, fn() { n() > 0 }, fn(c) {
              c.box(fn(count) {
                @sf.style_node(count, fn() { todo_count })
                @sf.words_node(count, fn() { n().to_string() }, fn() { todo_count_words }) |> ignore
              })
              |> ignore
            })
          })
          |> ignore
        })
      })
      |> ignore
    })
  })
  |> ignore
}


///|
/// The button of the workspace in view (`workspace`, as it changes: its icon and name in the system's glass,
/// rail_native.mbt) in the band's row `r`, where
/// 新建对话 stands elsewhere: as wide as the row, as high as a band's row; its place handed to the system's glass as it is
/// read out (native_sidebar_items, by its node's id), what the workspaces' sheet opens beside, let go with it.
fn workspace_glass_node(r : @view.View, src : Source, workspace : () -> Workspace?) -> Unit {
  r.box(fn(b) {
    b
    .grow(Is(1.0))
    .height(By(fn() { Some(@sf.band_row_h()) }))
    .says(By(fn() { Some(@view.said(Button, label=workspace().map(fn(w) { w.name }).unwrap_or(""))) }))
    |> ignore
    let id = @ui.tree_read_out_id(b)
    native_workspace_hooked()
    // (the workspace in view's, as it changes: its name, its mark)
    b.reacts(fn() { workspace().map(fn(w) { native_workspace_item(src, w) }) }, fn(item) {
      match item {
        Some(item) => native_sidebar_items[id] = item
        None => native_sidebar_items.remove(id)
      }
      native_workspace_anchor.val = Node(b)
      native_floating_schedule()
    })
    b.owns(fn() {
      native_sidebar_items.remove(id)
      match native_workspace_anchor.val {
        Node(n) if n.id() == b.id() => native_workspace_anchor.val = Unanchored
        _ => ()
      }
      native_floating_schedule()
    })
    |> ignore
  })
  |> ignore
}

///|
/// An icon-only control in the system's glass beside the workspace's button (sidebar_glass's) in `k`: a band's row
/// square, read out a button named `title()`; its place, its icon and its menu's rows (`menu()`: each its id, its words,
/// whether it is the one now, its icon) handed to the host as it is read out, by `key` (what rail_native.mbt does as it
/// is chosen there), let go with it.
fn sidebar_glass_node(
  k : @view.View,
  key : String,
  title : () -> String,
  icon : String,
  menu : () -> Array[(String, String, Bool, String)],
) -> Unit {
  k.box(fn(b) {
    b
    .width(By(fn() { Some(@sf.band_row_h()) }))
    .height(By(fn() { Some(@sf.band_row_h()) }))
    .says(By(fn() { Some(@view.said(Button, label=title())) }))
    |> ignore
    let id = @ui.tree_read_out_id(b)
    native_workspace_hooked()
    b.reacts(fn() { (title(), menu()) }, fn(now) {
      native_sidebar_items[id] = { id: key, title: now.0, icon: @sf.icon_path(icon), dot: false, prominent: false, menu: now.1 }
      native_floating_schedule()
    })
    b.owns(fn() {
      native_sidebar_items.remove(id)
      native_floating_schedule()
    })
    |> ignore
  })
  |> ignore
}

///|
/// The filter's menu in the system's glass (filter_button's there): each list it shows, the one `shown` now ticked.
fn filter_glass_rows(shown : String) -> Array[(String, String, Bool, String)] {
  let now = if shown == "chats" { "all" } else { shown }
  [
    ("all", "web-main.filter.chats.all"),
    ("mine", "web-main.filter.chats.mine"),
    ("watching", "web-main.filter.watching"),
    ("hidden", "web-main.filter.hidden"),
    ("archive", "web-main.filter.archived"),
  ].map(fn(p) { ("sidebar/filter/" + p.0, @sf.t(p.1), p.0 == now, "") })
}

///|
/// 远程's sidebar (lists_side_node's makings) in node `s` as wide as the sidebar, where `at` says the block has it: the
/// remote list (sfpages' remote_list_node: each station under its heading, its ＋ there making a new view on it, its rows
/// opening tabs of the workbench beside it) under the sidebar's top row (remote_band_node). No row of its own over the
/// list: a new terminal or browser tab is its station's heading's ＋ (左子健, 2026-11-16).
fn remote_side_node(s : @view.View, src : Source, tips : @sf.TipLayer, at : () -> SideAt) -> Unit {
  let list_at = side_list_at(@signals.untracked(at))
  let ws = fn() { @sfbase.workspace_in_view(src).0.map_or("", fn(w) { w.id }) }
  s
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  .alpha(By(fn() { if @sfbase.first_page_waits.get() { 0.0 } else { 1.0 } }))
  |> ignore
  s.box(fn(list) {
    list.over(Is(true)) |> ignore
    @sfpages.remote_list_node(
      list,
      src,
      ws,
      list_at,
      tips,
      // (under the top row: its height as the block stands, the open end's all the way on a fold, remote_band_h; in a
      // block round at its corners off the tape (the sidebar shown a while over the page from the folded bar) at least
      // as far under its top as it is round, so the first station's heading and its ＋ stand clear of its top corners)
      top=fn() {
        let a = at()
        let h = remote_band_h(side_band_at(a, true))
        // (its top right corner: its one radius, else the corner it follows, linked)
        let corner = match a.links {
          Some(k) => dmax(a.round, k[1].radius(@ui.tree_corner_roots_now()))
          None => a.round
        }
        if a.tape { h } else { dmax(h, corner) }
      },
      foot=fn() { 0.0 },
      on_pick=show_page,
    )
  })
  |> ignore
  s.box(fn(o) {
    o.over(Is(true)) |> ignore
    remote_band_node(o, at)
  })
  |> ignore
}

///|
/// The room the remote list leaves over it (lists_side_node's lists_top, with no row of a band): the sidebar's top row,
/// and in a panel of the tape the room 新建对话's row has over it there (band_new_tape), so the first station's heading
/// and its ＋ stand clear of the panel's top corners as the chats' first row does; laid out `at` (side_band_at's, held:
/// the open band's all the way on the block's way).
fn remote_band_h(at : BandAt) -> Double {
  at.brand + (if at.tape { band_new_top + band_new_tape_over(at~) } else { 0.0 })
}

///|
/// What covers the remote list's top (lists_band_node's ground) in `o`, where `at` says the block has it: on the
/// sidebar's own ground, its top row (the window's buttons' row, dragging it).
fn remote_band_node(o : @view.View, at : () -> SideAt) -> Unit {
  o.box(fn(band) {
    band.ground(By(fn() {
      let a = at()
      @sf.mix(if a.tape { a.ground } else { apart_ground() }, a.band, @sf.theme().p.sidebar)
    }))
    |> ignore
    side_top_node(band, fn() { at().brand })
  })
  |> ignore
}
