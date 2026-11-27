// The chats' sidebar as the web's lists (still.fail web/src/Sidebar.tsx ChatList, Sidebar.css.ts navSlider, navTrack;
// pages/Archive.tsx ArchiveRows, ArchivePage; Archive.css.ts): under the band (新建对话 and the filter), one track of
// the lists side by side, 全部, 我参与的, 监控中 and 已归档, slid from one to another as the list shown changes
// (240 ms, ease out); only those in view are drawn. 已归档 is a list of the sidebar's like the others: a field to look
// for one, its days, each archived chat a row (put back or deleted while pointed at), pressed its chat beside the
// list; opened, the newest of them is open beside it, or with none what the archive is.

///|
/// What is wrong with the stations of the workspace in view, as the foot's band says it (lists_foot_node's): None
/// where nothing is, or with the bell in the rail (its panel says it).
fn foot_trouble_of(src : Source, workspace : () -> Workspace?) -> Json? {
  match workspace() {
    Some(w) if !rail_items(src, w.id).contains("attention") =>
      match field(@sfbase.chats_topic(src, w.id).value, "trouble") {
        Some(Object(_)) as t => t
        _ => None
      }
    _ => None
  }
}

///|
/// How many the workspace in view has left up long, as the foot's band's 运行中 N says it (lists_foot_node's): the
/// viewer's own and the others' (nothing kept from where there is no bell), those stopped here aside; none with the
/// bell in the rail (its panel lists them).
fn foot_jobs_of(src : Source, workspace : () -> Workspace?) -> Int {
  match workspace() {
    Some(w) if !rail_items(src, w.id).contains("attention") =>
      open_jobs_count(open_jobs_groups(src, w, "groups")) + open_jobs_count(open_jobs_groups(src, w, "otherGroups"))
    _ => 0
  }
}

///|
/// How tall the lists' foot band is where it shows (lists_foot_node's: foot_band's room round its line, the trouble's
/// row or the chip, the taller), none where it does not: what the lists under it leave clear at their foot, their last
/// row and their bar.
fn lists_foot_h(src : Source, workspace : () -> Workspace?) -> Double {
  let trouble = foot_trouble_of(src, workspace) is Some(_)
  let jobs = foot_jobs_of(src, workspace) > 0
  if !trouble && !jobs {
    return 0.0
  }
  let line = if trouble { @ui.Space::S8.px() } else { @ui.Space::S6.px() }
  2.0 * @ui.Space::S2.px() + line
}

///|
/// The lists' foot band (Sidebar.css.ts navFoot, navFootStatus) of the workspace in view (`workspace`) in `o`, under
/// the lists: what is wrong with the stations (StationTrouble: their glyph and its words, red while one fails, leading
/// to them), and 运行中 N (OpenJobsChip: the services left up long, their panel over it, wide.jobs_open). Nothing when
/// neither is, nor with the bell in the rail (they are in its panel). On the sidebar's own ground, whole, as the band
/// over the lists (the closed bar's as it closes, where `at` says the block has it).
fn lists_foot_node(o : @view.View, src : Source, workspace : () -> Workspace?, at : () -> SideAt) -> Unit {
  let trouble = fn() { foot_trouble_of(src, workspace) }
  let jobs = fn() { foot_jobs_of(src, workspace) }
  o.show(at_once=true, fn() { trouble() is Some(_) || jobs() > 0 }, fn(band) {
    @sf.style_node(band, fn() { foot_band })
    band.fades(Is((0.0, 14.0, 0.0, 0.0))) |> ignore
    band.box(fn(scrim) {
      scrim
      .over(Is(true))
      .width_share(Is(1.0))
      .height_share(Is(1.0))
      |> ignore
      @signals.untracked(fn() { scrim.pointed() }) |> ignore
      @sf.scroll_edge_fill_decorate(scrim, fn() { at().ground }) |> ignore
    })
    |> ignore
    band.show(at_once=true, fn() { trouble() is Some(_) }, fn(k) {
      k.drawn_clear_of(band) |> ignore
      // (what the band's row leaves to the chip at its end is the trouble's: its row w=Full in it, as the old foot's)
      k.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      let words = fn() { text(trouble(), "text") }
      // (@sf.count_chip_node's Row: the stations' glyph and the words, red while one fails, the pointer's ground under
      // the hand)
      @sf.count_chip_node(
        k,
        words,
        fn(_) { @sfbase.go_place("stations", kept=true) |> ignore },
        lead=fn(r) {
          @sf.station_glyph_node(
            r,
            fn() {
              match workspace() {
                Some(w) => @sfbase.stations_at_glance(src, w.id).0
                None => { online: 0, dim: 0, failing: 0, working: 0, asleep: false, connecting: 0 }
              }
            },
            foot_glyph,
            fn() { @sf.theme().p.text },
            fn() { @sf.theme().p.red },
          )
          |> ignore
        },
        alarm=fn() { text(trouble(), "state") == "error" },
        look=Row,
      )
      |> ignore
    })
    band.show(at_once=true, fn() { jobs() > 0 }, fn(k) {
      k.drawn_clear_of(band) |> ignore
      // (@sf.count_chip_node's Small, a plain button: its press opens or closes the 运行中 list beside it, presented
      // over it; its dot the online green)
      let chip = @sf.count_chip_node(
        k,
        fn() { @sf.t("web-main.jobs.chip", args=[("n", jobs().to_string())]) },
        fn(_) { wide.jobs_open.set(!wide.jobs_open.untracked()) },
        dot=fn() { "online" },
        look=Small,
        // (read out as what it opens, as it was: the long-running services and jobs)
        named=fn() { @sf.t("web-main.jobs.long") },
      )
      open_jobs_pop_node(chip, src, workspace)
    })
  })
}

///|
/// The foot's 运行中 list (open_jobs_node) presented over its chip `chip` as wide.jobs_open comes to say so: a panel 280
/// wide, its end at the chip's, scrolling in itself past 420 or 60% of the window; said closed as it closes for anything
/// else (Escape, a press outside it and its chip), closed with the chip let go.
fn open_jobs_pop_node(chip : @view.View, src : Source, workspace : () -> Workspace?) -> Unit {
  let mine = Ref(0)
  chip.reacts(fn() { wide.jobs_open.get() }, fn(on) {
    if !on {
      if mine.val != 0 {
        @sf.close_presented_of(mine.val)
        mine.val = 0
      }
      return
    }
    guard @signals.untracked(workspace) is Some(w) else { return }
    @sf.panel_nodes(
      "",
      fn(v, close) {
        // (in a box of its own: its rows as far in as their own room says, the dot's column where the headings start; a
        // row pressed closes it as it leads where it is)
        v.box(fn(b) { open_jobs_node(b, src, w, close, alone=true) }) |> ignore
      },
      // (420 high at most, or 60% of the window: past that its groups scroll in it, as the old popover's did,
      // within_room)
      most=fn() { dmin(open_jobs_pop_most, chip.window_h() * 0.6) },
      from=Node(chip),
      w=open_jobs_pop_w,
      side=Top,
      along=End,
      offset=6.0,
      gone=fn() { wide.jobs_open.set(false) },
    )
    mine.val = @sf.last_presented()
  })
  chip.reacts(
    fn() { @sf.presented_open_now(mine.val) },
    fn(shown) {
      if !shown && mine.val != 0 {
        mine.val = 0
        wide.jobs_open.set(false)
      }
    },
    at_start=false,
  )
  chip.owns(fn() {
    if mine.val != 0 && @sf.presented_open_of(mine.val) {
      @sf.close_presented_of(mine.val)
    }
  })
  |> ignore
}

///|
/// The stations' glyph in the foot's line (Sidebar.css.ts stationTroubleMark: 18).
let foot_glyph : Double = 18.0

///|
/// 8 in, its line and the chip 6 apart (Sidebar.css.ts navFoot, navFootStatus).
// kept across runs: a value (no field of it changes)
let foot_band : @ui.Style = @ui.css("row w=Full p=S2 gap=S1_5 align=ACenter")

///|
/// An archived chat's page beside the list: over the archive, in place of another's.
fn archive_open(it : Json) -> Unit {
  let v = Some(it)
  let r : ChatRef = {
    station: text(v, "station"),
    session: text(v, "session"),
    title: text(v, "title"),
    station_name: text(v, "place"),
  }
  @sfbase.history_push()
  match app.nav.top() {
    Chat(open) if open.station == r.station && open.session == r.session => ()
    Chat(_) => app.nav.replace(Chat(r))
    _ => app.nav.push(Chat(r))
  }
}

///|
/// Deleted for good, once said so (its 删除, under the pointer or in its menu).
fn archive_delete(src : Source, it : Json) -> Unit {
  let v = Some(it)
  @sf.confirm(
    @sf.t("web-pages.archive.deleteConfirm"),
    @sf.t("web-pages.archive.deleteText"),
    @sf.t("common.delete"),
    danger=true,
    facts=[(@sf.t("common.confirmFact.chat"), text(v, "title"))],
    fn() {
      act(
        src,
        @sf.t("common.delete"),
        "",
        "session.delete",
        { "station": Json::string(text(v, "station")), "key": Json::string(text(v, "session")) },
        done=@sf.t("web-pages.archive.deleted"),
      )
    },
  )
}

///|
/// Put back in the list (`chat.archive` with archived false), said once done.
fn archive_restore(src : Source, it : Json) -> Unit {
  let v = Some(it)
  let p : Map[String, Json] = {
    "station": Json::string(text(v, "station")),
    "session": Json::string(text(v, "session")),
    "archived": Json::boolean(false),
  }
  match field(v, "thread") {
    Some(Number(_, ..) as n) => p["thread"] = n
    _ => ()
  }
  act(src, @sf.t("web-pages.archive.restore"), "", "chat.archive", Json::object(p), done=@sf.t("web-pages.archive.restored"))
}

///|
/// Whether an archived chat's putting back or deleting is under way (the core's `doing`).
fn archive_doing(src : Source, station : String, session : String) -> Bool {
  for d in items(src.topic("doing", {}).get().value, "doing") {
    let call = text(Some(d), "call")
    let p = field(Some(d), "params")
    if text(Some(d), "stage") == "failed" || text(p, "station") != station {
      continue
    }
    if (call == "chat.archive" && text(p, "session") == session) || (call == "session.delete" && text(p, "key") == session) {
      return true
    }
  }
  false
}

///|
// kept across runs: a value (no field of it changes)
let arch_field_box : @ui.Style = @ui.css("w=Full pb=S1")

///|
// kept across runs: a value (no field of it changes)
let arch_field_alone : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let arch_clock : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, leading=L5, wrap=false)

///|
/// Their marks (14; turning, 12).
let arch_icon : Double = 14.0

///|
let arch_spin : Double = 12.0

///|
// kept across runs: a value (no field of it changes)
let arch_empty : @ui.Style = @ui.css("w=Full h=Full px=S10 gap=S2 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let arch_empty_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let arch_empty_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, center=true, leading=L6)

///|
/// 待处理's row in the band: 2 above it, 8 in, 8 under (Sidebar.css.ts navTodo).
// kept across runs: a value (no field of it changes)
let todo_box : @ui.Style = @ui.css("w=Full pt=S0_5 px=S2 pb=S2")

///|
/// Its count's place, as wide as the lists' menu button above it, centred under it.
// kept across runs: a value (no field of it changes)
let todo_slot : @ui.Style = @ui.css("w=S8 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let todo_count : @ui.Style = @ui.css("min_w=S4 h=S4 px=S1 align=ACenter justify=JCenter bg=Danger radius=Full")

///|
// kept across runs: a value (no field of it changes)
let todo_count_words : @ui.TextStyle = @ui.text_style(size=Caption, weight=Semibold, color=OnPrimary, wrap=false)

///|
/// How many are in 待处理 in every workspace (the core's marks' items), less those let go in its panel.
fn todo_all(src : Source, w : Workspace) -> Int {
  attention_groups(src, w, true).fold(init=0, fn(n, g) { n + g.2.length() })
}

///|
/// Whether 待处理 is under 新建对话: no bell in the rail, and something there (or its panel open).
fn todo_shown(src : Source, w : Workspace) -> Bool {
  // (待处理 a tab of the system's: rail_native.mbt)
  !@sf.native_on() &&
  !rail_items(src, w.id).contains("attention") && (todo_all(src, w) > 0 || wide.attention_open.get())
}

///|
/// The band's height over the lists: its top row, 新建对话's (6 + a row + 2; in the closed bar 6 + a row + 6), 待处理's
/// when there (2 + a row + 8), plus the fixed active filter bar when projects are enabled and filters are active
/// (excluded in archive mode); a row as high as the theme's band (32; touch's the search field's 38).
fn band_h(src : Source, w : Workspace, at? : BandAt = band_at_old(), in_archive? : Bool = false) -> Double {
  at.brand +
  band_row_h() +
  (if at.tape {
    band_new_top + side_new_under + band_new_tape_over(at~)
  } else {
    band_pane_top(at~) + band_pane_under(at~)
  }) +
  (if todo_shown(src, w) { side_todo_around + band_row_h() } else { 0.0 }) +
  @sfpages.active_filter_bar_h(src, w.id, in_archive~)
}

///|
/// 新建对话's row's room under it (2), and in the closed bar from its side and under it (6: Sidebar.css.ts navNew, closed).
let side_new_under : Double = 2.0

///|
let bar_band_in : Double = 6.0

///|
/// 待处理's room over and under its row (2 + 8).
let side_todo_around : Double = 10.0
