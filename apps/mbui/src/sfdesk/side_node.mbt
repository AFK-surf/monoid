// The sidebar made once over the block (pane_view's and tape_view's `sides`): where the block lays its sidebar out
// (SideAt), the sidebar the block holds now (side_place), each made as nodes of the window's tree: the chats' lists for
// the chats' places (with 已归档 among them, the band over them and the foot under them), the settings' list for the
// settings', the stations' and the profiles' lists for the rail's places of theirs (places_side_node.mbt), the files'
// for theirs (files_side_node.mbt).

///|
/// The vertical order of a top-level place in the current workspace's left rail (side_node's switch direction).
/// Maps chat-list places (`"chats"`, `"mine"`, `"watching"`, `"hidden"`, `"archive"`) to the first matching rail item,
/// places `"settings"` after all rail items, and returns `None` when the place is absent from the rail.
fn side_place_rail_index(src : Source, ws : String, place : String) -> Int? {
  if ws == "" {
    return None
  }
  let items = rail_items(src, ws)
  if place == "settings" {
    return Some(items.length())
  }
  if place == "chats" {
    for i, it in items {
      if it is ("chats" | "mine" | "watching" | "hidden" | "archive") {
        return Some(i)
      }
    }
    return None
  }
  items.search(place)
}

///|
/// The sidebar the block holds now in node `n` (as large as what holds the block, over it), where `at` says the block
/// has it: cut to the block's room, its corners the block's (its line over it, dock_edge_node's); shown while what is in
/// it is drawn.
fn side_node(n : @view.View, src : Source, tips : @sf.TipLayer, at : () -> SideAt, ground? : () -> Int64) -> Unit {
  n.box(fn(cut) {
    cut
    // (not shown, as the device waits in the lock: laid out nowhere, the same nodes, what had the focus in it given
    // it back as it is shown again, as an old view's focus waits for its node)
    .laid_nowhere(By(fn() { !at().shown }))
    .clips(Is(true))
    .bounds_input(Is(true))
    .width(By(fn() { Some(at().block.2) }))
    .height(By(fn() { Some(at().block.3) }))
    .offset(By(fn() { (at().block.0, at().block.1) }))
    |> ignore
    dock_round_node(cut, at)
    cut.box(fn(side) {
      // (given way with the drawer's glass as a drawer shown a while comes back to the rail, so nothing it holds shows
      // on no ground: a signal of its own, so the window's size, which moves `at`, wakes it not)
      let seen = @signals.computed(fn(_) { at().seen }, same=fn(a, b) { a == b })
      side.owns(fn() { seen.dispose() }) |> ignore
      side.alpha(By(fn() { if @signals.active_sub() is None { at().seen } else { seen.get() } })) |> ignore
      // (where the rail's lit place pressed again finds its list: back_to_top.mbt)
      side_made.val = Some(side)
      side.owns(fn() {
        match side_made.val {
          Some(v) if physical_equal(v, side) => side_made.val = None
          _ => ()
        }
      })
      |> ignore
      let cur_place = fn() { if side_place() == "archive" { "chats" } else { side_place() } }
      let kept_places : @signals.Signal[Array[String]] = @signals.signal([])
      let last_ws : Ref[String] = Ref("")
      side.reacts(
        fn() { (@sfbase.workspace_in_view(src).0.map_or("", fn(w) { w.id }), cur_place()) },
        fn(now) {
          let (ws, place) = now
          let mut kept = if ws != last_ws.val {
            last_ws.val = ws
            []
          } else {
            kept_places.untracked()
          }
          if !kept.contains(place) {
            kept = kept.copy()
            kept.push(place)
          }
          kept_places.set(kept)
        },
      )
      // (settings_side_node's own reacts sleeps while parked; keep resetting search when leaving settings)
      let in_settings = fn() { app.nav.pages().iter().any(fn(p) { p is (Settings | Setting(_)) }) }
      side.reacts(in_settings, fn(on) { if !on { @sfpages.settings_search_reset() } })
      let prev_place : Ref[(String, String)?] = Ref(None)
      let slide_dir : Ref[Double] = Ref(1.0)
      let slide_way = @motion.NodeWay::new(1.0)
      side.reacts(
        fn() { (@sfbase.workspace_in_view(src).0.map_or("", fn(w) { w.id }), cur_place()) },
        fn(now) {
          let (ws, place) = now
          match prev_place.val {
            Some((old_ws, old_place)) if old_ws == ws && old_place != place => {
              let (old_idx, cur_idx) = @signals.untracked(fn() {
                (side_place_rail_index(src, ws, old_place), side_place_rail_index(src, ws, place))
              })
              match (old_idx, cur_idx) {
                (Some(oi), Some(ci)) if !fold_showing_toggling(side.cause_at()) => {
                  slide_dir.val = if ci >= oi { 1.0 } else { -1.0 }
                  slide_way.go_from(side, 0.0, 1.0, @motion.tween(160.0, ease=Out))
                }
                _ => slide_way.put(1.0)
              }
            }
            Some((old_ws, old_place)) if old_ws != ws || old_place != place => slide_way.put(1.0)
            _ => ()
          }
          prev_place.val = Some((ws, place))
        },
      )
      side
      .width(By(fn() { Some(at().laid_w) }))
      .height(By(fn() { Some(at().box.3) }))
      .offset(By(fn() {
        let dy = slide_dir.val * 10.0 * (1.0 - slide_way.shown(side))
        (at().box.0 - at().block.0, at().box.1 - at().block.1 + dy)
      }))
      .carries_until(fn() { slide_way.ends_at() })
      |> ignore
      side.each(
        fn() { [cur_place()] },
        fn(k) { k },
        keeps=fn() { kept_places.get() },
        at_once=true,
        fn(s, place_sig) {
          let place = @signals.untracked(fn() { place_sig.get() })
          match place {
            // (the settings' list beside their pages: settings_frame.mbt)
            "settings" => settings_side_node(s, src, tips, at)
            // (the files' places: files_side_node.mbt; the rail's Station and Profile places' lists: places_side_node.mbt)
            "files" => files_side_node(s, src, tips, at)
            "stations" => stations_side_node(s, src, tips, at)
            "profiles" => profiles_side_node(s, src, tips, at)
            // (远程's: its band over the remote list, made as the chats' sidebar is)
            "remote" => remote_side_node(s, src, tips, at, ground?)
            // (the chats' lists: a place of the rail's of theirs, or what the frame shows by default)
            _ => lists_side_node(s, src, tips, at, ground?)
          }
        },
      )
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
fn lists_side_node(s : @view.View, src : Source, tips : @sf.TipLayer, at : () -> SideAt, ground? : () -> Int64) -> Unit {
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
      Some(w) => band_h(src, w, at=band_at(true), in_archive=@sfbase.has_active_list_filters(w.id) && side_place() == "archive")
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
    // (on the tape the block's, a step darker behind the panel in use: tape_side_ground)
    ground: fn() {
      if wide.tape.get() {
        match ground {
          Some(g) => g()
          None => at().ground
        }
      } else if side_folded() {
        apart_ground()
      } else {
        @sf.theme().p.sidebar
      }
    },
    before: fn(filter, view) {
      let parts : Array[@sfpages.NodePart] = @sfpages.restart_interrupted_parts(src, view, fn() {
        match workspace() {
          Some(w) => @sfbase.chats_of(src, w.id, filter).0
          None => None
        }
      })
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
              Some(w) => band_h(src, w, at=band_at(false), in_archive=true)
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
    section_rows: fn() { if at().box.3 >= 720.0 { (2, 2) } else { (2, 1) } },
    section_chrome_bottom: fn() { 0.0 },
    section_chrome_suppress: fn() { false },
  }
  // (while the app's first page waits for what it shows: drawn at none, the splash in its place, as the old views are)
  s
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  .alpha(By(fn() { if @sfbase.first_page_waits.get() { 0.0 } else { 1.0 } }))
  .takes_unseen(Is(true))
  |> ignore
  // under a finger's search (sfpages' search.mbt): the band and the foot away with the lists, the search over them
  let away = @sfpages.search_away_node(s)
  s.box(fn(lists) {
    // (their room for the band held on the block's way: drawn where the band has them as it goes, lists_side's)
    lists
    .over(Is(true))
    .drawn_off(By(fn() {
      match workspace() {
        Some(w) => {
          let in_archive = @sfbase.has_active_list_filters(w.id) && side_place() == "archive"
          (0.0, band_h(src, w, at=band_at(false), in_archive~) - band_h(src, w, at=band_at(true), in_archive~))
        }
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
    lists_band_node(o, src, tips, workspace, at, ground?)
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
  ground? : () -> Int64,
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
    // Pure progressive variable-blur scroll-edge over the lists (solid fallback keeps the sidebar's mixed ground).
    let band_bg = fn() {
      let a = at()
      let bg = if a.tape {
        match ground {
          Some(g) => g()
          None => a.ground
        }
      } else {
        apart_ground()
      }
      @sf.mix(bg, a.band, @sf.theme().p.sidebar)
    }
    band.adaptive_ink(Is(true)).fades(Is((0.0, 0.0, 0.0, 14.0))) |> ignore
    // (its top row the window's title bar where the window's buttons are in the app's top row, under what is in it: as
    // tall as their row however short the band's own top is (no buttons at its left: a Windows window), not folded;
    // reuse this over-box for the pure progressive-blur scroll-edge fill so zero extra nodes are added)
    band.box(fn(o) {
      o.over(Is(true)).width_share(Is(1.0)).height_share(Is(1.0)) |> ignore
      @sf.scroll_edge_fill_decorate(o, band_bg) |> ignore
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
      line.drawn_clear_of(band) |> ignore
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
        @sfbase.sync_key_node(k, tips, update_key_side, update_key_mark, fn() {
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
        let projects_on = fn() {
          workspace().map(fn(w) { @sfbase.workspace_projects_on(src, w.id) }).unwrap_or(false)
        }
        let narrowed = fn() {
          match workspace() {
            Some(w) => @sfpages.filter_narrowed(src, w.id, shown())
            None => false
          }
        }
        sidebar_glass_node(
          k,
          "sidebar/filter",
          fn() {
            match workspace() {
              Some(w) => {
                let summary = @sfpages.filter_summary(src, w.id, shown())
                if summary != "" {
                  @sf.t("web-main.filter.chats.named", args=[("named", summary)])
                } else {
                  @sf.t("web-main.filter.chats.named", args=[("named", filter_named(shown()))])
                }
              }
              None => @sf.t("web-main.filter.chats.named", args=[("named", filter_named(shown()))])
            }
          },
          "filter",
          fn() { if projects_on() { [] } else { filter_glass_rows(shown()) } },
          dot=narrowed,
        )
      })
      // the filter: its menu (sfpages' filter_menu), a filter its list, 已归档 the archive's list; coming and going
      // along the row (a workspace switched to one with no stations: 新建对话 widening over its room, not at once)
      line.show(along_row=true, fn() { !@sf.native_on() && view().map(fn(v) { v.stations > 0 }).unwrap_or(false) }, fn(k) {
        let shown_sig = @signals.computed(fn(_) {
          match workspace() {
            Some(w) => list_place(list_mode(src, w))
            None => "chats"
          }
        })
        let shown = fn() { shown_sig.get() }
        let narrowed_sig = @signals.computed(fn(_) {
          match workspace() {
            Some(w) => @sfpages.filter_narrowed(src, w.id, shown())
            None => false
          }
        })
        let narrowed = fn() { narrowed_sig.get() }
        let tip_text = fn() {
          match workspace() {
            Some(w) => {
              let summary = @sfpages.filter_summary(src, w.id, shown())
              if summary != "" {
                @sf.t("web-main.filter.chats.named", args=[("named", summary)])
              } else {
                @sf.t("web-main.filter.chats")
              }
            }
            None => @sf.t("web-main.filter.chats")
          }
        }
        // (its menu, while drawn: what it says of itself)
        let opener = @sf.Opener::new()
        @sf.action_box_node(k, fn() {
          match workspace() {
            Some(w) => {
              let summary = @sfpages.filter_summary(src, w.id, shown())
              if summary != "" {
                @sf.t("web-main.filter.chats.named", args=[("named", summary)])
              } else {
                @sf.t("web-main.filter.chats.named", args=[("named", filter_named(shown()))])
              }
            }
            None => @sf.t("web-main.filter.chats.named", args=[("named", filter_named(shown()))])
          }
        }, fn(f) {
          if @signals.untracked(@sfpages.filter_menu_accepting) {
            @sfpages.close_filter_menu()
            return
          }
          guard @signals.untracked(workspace) is Some(w) else { return }
          let now = @signals.untracked(shown)
          @sfpages.filter_menu(Node(f), if now == "chats" { "all" } else { now }, fn(pick) {
            rail_go_told(src, w, if pick == "all" { "chats" } else { pick }, fn(_, g) { g() })
          }, src=Some(src), ws=w.id)
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
            if narrowed() {
              t.p.accent
            } else {
              @sf.mix(t.p.text, hot(), t.p.muted)
            }
          }))
          |> ignore
          @sfpages.filter_dot_bind(f, narrowed, 22.0, 4.0)
          @sf.tip_node(tips, f, tip_text) |> ignore
        })
        |> ignore
      })
    })
    |> ignore
    // 待处理 under 新建对话 where the rail has no bell, plus fixed active filter bar when projects filters are active
    // (combined under one `band.show` so zero extra nodes exist when both are inactive).
    let todo_on = fn() { workspace().map(fn(w) { todo_shown(src, w) }).unwrap_or(false) }
    let filter_bar_on = fn() {
      workspace().map(fn(w) { @sfbase.has_active_list_filters(w.id) && @sfbase.workspace_projects_on(src, w.id) }).unwrap_or(false) &&
      side_place() != "archive"
    }
    band.show(at_once=true, fn() { todo_on() || filter_bar_on() }, fn(extra) {
      extra.drawn_clear_of(band) |> ignore
      extra.show(at_once=true, todo_on, fn(t) {
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
            slot.show(at_once=true, fn() { n() > 0 }, fn(count) {
              @sf.style_node(count, fn() { todo_count })
              @sf.words_node(count, fn() { n().to_string() }, fn() { todo_count_words }) |> ignore
            })
          })
          |> ignore
        })
      })
      extra.show(at_once=true, filter_bar_on, fn(bar) {
        @sfpages.active_filter_bar_node(bar, src, fn() { workspace().map_or("", fn(w) { w.id }) }, px=8.0, along=Start)
      })
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
  @sf.host_button_anchor_node(r, fn() { workspace().map(fn(w) { w.name }).unwrap_or("") }, fn(b) {
    b
    .grow(Is(1.0))
    .height(By(fn() { Some(@sf.band_row_h()) }))
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
  dot? : () -> Bool = fn() { false },
) -> Unit {
  @sf.host_button_anchor_node(k, title, fn(b) {
    b
    .width(By(fn() { Some(@sf.band_row_h()) }))
    .height(By(fn() { Some(@sf.band_row_h()) }))
    |> ignore
    let id = @ui.tree_read_out_id(b)
    native_workspace_hooked()
    b.reacts(fn() { (title(), menu(), dot()) }, fn(now) {
      native_sidebar_items[id] = { id: key, title: now.0, icon: @sf.icon_path(icon), dot: now.2, prominent: false, menu: now.1 }
      if key == "sidebar/filter" {
        native_filter_anchor.val = Node(b)
      }
      native_floating_schedule()
    })
    b.owns(fn() {
      native_sidebar_items.remove(id)
      if key == "sidebar/filter" {
        match native_filter_anchor.val {
          Node(n) if n.id() == b.id() => native_filter_anchor.val = Unanchored
          _ => ()
        }
      }
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
fn remote_side_node(s : @view.View, src : Source, tips : @sf.TipLayer, at : () -> SideAt, ground? : () -> Int64) -> Unit {
  let list_at = side_list_at(@signals.untracked(at))
  let ws = fn() { @sfbase.workspace_in_view(src).0.map_or("", fn(w) { w.id }) }
  s
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  .alpha(By(fn() { if @sfbase.first_page_waits.get() { 0.0 } else { 1.0 } }))
  .takes_unseen(Is(true))
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
    remote_band_node(o, at, ground?)
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
fn remote_band_node(o : @view.View, at : () -> SideAt, ground? : () -> Int64) -> Unit {
  o.box(fn(band) {
    let band_bg = fn() {
      let a = at()
      let bg = if a.tape {
        match ground {
          Some(g) => g()
          None => a.ground
        }
      } else {
        apart_ground()
      }
      @sf.mix(bg, a.band, @sf.theme().p.sidebar)
    }
    band.fades(Is((0.0, 0.0, 0.0, 14.0))) |> ignore
    band.box(fn(scrim) {
      scrim
      .over(Is(true))
      .width_share(Is(1.0))
      .height_share(Is(1.0))
      |> ignore
      @signals.untracked(fn() { scrim.pointed() }) |> ignore
      @sf.scroll_edge_fill_decorate(scrim, band_bg) |> ignore
    })
    |> ignore
    side_top_node(band, fn() { at().brand })
  })
  |> ignore
}
