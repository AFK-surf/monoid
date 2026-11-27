// The chats' lists (still.fail web/src/Sidebar.tsx ChatList, ChatPane; SidebarList.tsx NavSection; web/src/mobile/Home.tsx
// Home, ChatPane, Empty, FilterButton; Sidebar.css.ts navSlider, navTrack, navScroll, navEmpty; mobile/Home.css.ts
// mHomePanes, mHomePane), one in every tier: 全部, 我参与的 and 监控中 side by side on one track, slid from one to
// another as the filter changes (240 ms) with nothing to wait for, as the core's `chats` view lists each: its days
// under their headings, a row each (chat_row.mbt); while it is read the rows to come, what is wrong over them, an
// empty list's words. While a finger is on a list, the pointer over it or it moves, its rows keep their places
// ; they move as it changes (useListMotion). The frame it is drawn in says what is over
// it and at its foot (the bar it is under, the bottom bar), what it adds at each list's top (a search's field, what is
// left up long), and the lists that follow the three on the track (已归档, where the frame has it so).

///|
/// Something a frame puts in a list: its key among the list's lines, what draws it, and whether the list is first
/// shown scrolled past it (a phone's search over the first row).
pub(all) struct ListPart {
  key : String
  draw : () -> Unit
  tucked : Bool
}

///|
/// The lists the track holds first, in this order (mine, watching).
// kept across runs: a table, never written
pub let list_filters : Array[String] = ["all", "mine", "watching", "hidden"]

///|
/// Which of the lists the filter shows (0 all, 1 mine, 2 watching).
pub fn filter_at(src : Source, w : Workspace) -> Int {
  list_filters.search(@sfbase.filter_of(src, w.id)).unwrap_or(0)
}

///|
fn sidebar_reset() -> Unit {
  list_scrolls.clear()
  list_scroll_order.clear()
  rows_rest_at.val = -1.0
  filter_menu_serial.val = -1
  archived_here.set(None)
  archived_n.val = 0
}

///|
/// The chat in the page pane, if one is.
fn open_chat() -> ChatRef? {
  let pages = app.nav.pages()
  for k = pages.length() - 1; k >= 0; k = k - 1 {
    match pages[k] {
      Chat(r) => return Some(r)
      NewChat => return None
      _ => ()
    }
  }
  None
}

///|
let illustration_w : Double = 240.0

///|
// kept across runs: a value (no field of it changes)
let said_box : @ui.Style = @ui.css("w=Full px=S2_5 py=S4")

///|
// kept across runs: a value (no field of it changes)
let said_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L6)

///|
// kept across runs: a value (no field of it changes)
let empty_first : @ui.Style = @ui.style(w=Full, p=@sf.empty_in, gap=S2_5, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let empty_box : @ui.Style = @ui.style(w=Full, px=@sf.empty_in, py=S5, gap=S2, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let empty_title : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg, center=true, w=Full)

///|
// kept across runs: a value (no field of it changes)
let empty_note : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, center=true, leading=L6, w=Full)

///|
// kept across runs: a value (no field of it changes)
let empty_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let empty_link : @ui.TextStyle = @ui.text_style(size=Ui, color=Link)

///|
/// The filter's menu last opened (its presenter).
// kept across runs: put back by sidebar_reset (reset)
let filter_menu_serial : Ref[Int] = Ref(-1)

///|
/// Whether the filter's menu is open (drawn, including exit animation — for visual highlight/expanded state).
pub fn filter_menu_open() -> Bool {
  @sf.presented_drawn_of(filter_menu_serial.val)
}

///|
/// Whether the filter's menu (or a stepped project/tag subpanel) is currently open and accepting input.
/// Becomes false immediately when closing without replacement, so reopening during exit animation works cleanly.
pub fn filter_menu_accepting() -> Bool {
  filter_menu_serial.val != -1 && @sf.presented_open_chain_of(filter_menu_serial.val)
}

///|
/// Close the currently open filter menu/panel (including any stepped project/tag subpanel).
pub fn close_filter_menu() -> Unit {
  if filter_menu_open() {
    @sf.close_all_presented()
  }
}

///|
/// Whether the active list/board view is narrowed by scope or project/tag filters.
/// Normalizes `"chats"` to `"all"`; `"archive"` and project grouping alone do not count as narrowed.
/// Checks in-memory list filters before `workspace_projects_on` so unfiltered views never subscribe to `chats_topic`.
pub fn filter_narrowed(src : Source, ws : String, shown : String) -> Bool {
  let norm = if shown == "chats" { "all" } else { shown }
  if norm == "archive" {
    return false
  }
  if norm != "all" {
    return true
  }
  if !@sfbase.has_active_list_filters(ws) {
    return false
  }
  @sfbase.workspace_projects_on(src, ws)
}

///|
/// Draw a 6×6 accent indicator dot on `v` at `(x, y)` using `View::rects` (zero extra layout nodes when inactive).
pub fn filter_dot_bind(v : @view.View, on : () -> Bool, x : Double, y : Double) -> Unit {
  v.rects(By(fn() {
    if on() {
      [{ x, y, w: 6.0, h: 6.0, color: @sf.theme().p.accent, corners: (3.0, 3.0, 3.0, 3.0) }]
    } else {
      []
    }
  }))
  |> ignore
}

///|
/// Concise human-readable summary of active scope and project/tag filters (empty when unfiltered).
pub fn filter_summary(src : Source, ws : String, shown : String) -> String {
  let norm = if shown == "chats" { "all" } else { shown }
  let parts : Array[String] = []
  match norm {
    "mine" => parts.push(@sf.t("web-main.filter.chats.mine"))
    "watching" => parts.push(@sf.t("web-main.filter.watching"))
    "hidden" => parts.push(@sf.t("web-main.filter.hidden"))
    "archive" => parts.push(@sf.t("web-main.filter.archived"))
    _ => ()
  }
  if norm != "archive" && @sfbase.has_active_list_filters(ws) && @sfbase.workspace_projects_on(src, ws) {
    match @sfbase.project_filter_of(ws) {
      Named(name) => parts.push(name)
      Unclassified => parts.push(@sf.t("web-main.projects.unclassified"))
      All => ()
    }
    match @sfbase.tag_filter_of(ws) {
      Some(tg) => parts.push("#" + tg)
      None => ()
    }
  }
  parts.join(", ")
}

///|
/// The filter's menu, opened by `from`: 全部会话,
/// 我参与的, 监控中, then 已归档, a menu of choices, the list `shown` (all, mine, watching, archive) checked. Chosen, `go` is
/// given which: where it goes is the frame's (a filter its list, 已归档 its page or list). `in_board`: the board's, which
/// narrows to 全部会话 or 我参与的 alone (its 监控中 is a column of its own), 已隐藏 and 已归档 lists off it
/// (board_filter_go).
pub fn filter_menu(
  from : @sf.Beside,
  shown : String,
  go : (String) -> Unit,
  in_board? : Bool = false,
  along? : @ui.Along = End,
  src? : Source? = None,
  ws? : String = "",
) -> Unit {
  let pressed : @signals.Signal[String?] = @signals.signal(None)
  let choose = match src {
    Some(s) if in_board && ws != "" && !s.read_only && (s.switches_ahead)() =>
      board_scope_choice(s, ws, pressed, go)
    _ => go
  }
  let projects_on = match src {
    Some(s) if ws != "" => @signals.untracked(fn() { @sfbase.workspace_projects_on(s, ws) })
    _ => false
  }
  if projects_on {
    match src {
      Some(s) => {
        let anchor : @sf.Anchor = match from {
          Node(v) => Node(v)
          At(x, y, w, h) => At(x, y, w, h)
        }
        chats_view_panel(s, ws, anchor, shown, pressed, choose, in_board~, along~)
        return
      }
      None => ()
    }
  }
  let item = fn(key : String, words : String) -> @sf.MenuItem? {
    Some(@sf.menu_item_of(@sf.t(words), chosen=shown == key, fn() { choose(key) }))
  }
  let items : Array[@sf.MenuItem?] = []
  if in_board {
    items.push(item("all", "web-main.filter.chats.all"))
    items.push(item("mine", "web-main.filter.chats.mine"))
    items.push(None)
    items.push(item("hidden", "web-main.filter.hidden"))
    items.push(item("archive", "web-main.filter.archived"))
  } else {
    items.push(item("all", "web-main.filter.chats.all"))
    items.push(item("mine", "web-main.filter.chats.mine"))
    items.push(item("watching", "web-main.filter.watching"))
    items.push(item("hidden", "web-main.filter.hidden"))
    items.push(None)
    items.push(item("archive", "web-main.filter.archived"))
  }
  @sf.menu(
    items,
    from~,
    along~,
  )
  filter_menu_serial.val = @sf.last_presented()
  filter_menu_opened.set(filter_menu_opened.untracked() + 1)
}

///|
/// Switch the board to the chosen list when its first local answer is available. The open project
/// panel can pick another scope before that answer comes.
fn board_scope_choice(
  src : Source,
  ws : String,
  pressed : @signals.Signal[String?],
  go : (String) -> Unit,
) -> (String) -> Unit {
  let pending : Ref[@sfbase.PressWait?] = Ref(None)
  fn(scope) {
    if pending.val is Some(wait) {
      pending.val = None
      wait.give_up()
    }
    if scope != "all" && scope != "mine" {
      go(scope)
      return
    }
    pressed.set(Some(scope))
    let wait = @sfbase.press_wait(fn() {
      let query = { ..@sfbase.board_list_query(src, ws), filter: scope }
      let list = src.topic("chats", @sfbase.chats_params_query(ws, query)).get()
      @sfbase.opens_answered(list) || ((src.gates_opens)() && list.waiting)
    }, fn() {
      go(scope)
      pressed.set(None)
    }, let_go=fn() { pressed.set(None) })
    if wait.waiting() {
      pending.val = Some(wait)
    }
  }
}

///|
let cvp_panel_w : Double = 312.0

///|
/// Extra inner padding inside `chats_view_panel` when shown as a small popover:
/// `col` adds `cvp_cap_pad = 6pt` horizontally (so `panel_pad 6 + 6 = 12pt`, concentric with `r_menu = 24pt` for
/// 24pt full-capsule link pills), while body sections add `cvp_body_in = 2pt` (total `14pt` inset, concentric with
/// `r_menu = 24pt` on the theme ladder `[42, 26, 24, 18, 10]` at corner `10pt`).
let cvp_cap_pad : Double = 6.0

///|
let cvp_body_in : Double = 2.0

///|
let cvp_pad_x : Double = 8.0

///|
let cvp_in : Double = 2.0

///|
let cvp_chip_max_w : Double = 124.0

///|
let active_filter_bar_row_h : Double = 52.0

///|
// kept across runs: a value (no field of it changes)
let cvp_head_look : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let cvp_sub_head_look : @ui.TextStyle = @ui.text_style(size=Caption, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let cvp_hint_look : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=true)

///|
// kept across runs: a value (no field of it changes)
let cvp_scope_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let cvp_scope_words_on : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=AccentText, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let cvp_nav_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
/// Hairline rule inside `chats_view_panel`.
fn cvp_rule_node(parent : @view.View) -> Unit {
  parent.box(fn(l) {
    l.width_share(Is(1.0)).height(Is(Some(@sf.rule_w))).margin(Is((cvp_in, 0.0, cvp_in, 0.0))).ground(By(@sf.rule_color)) |> ignore
  })
  |> ignore
}

///|
/// 2×2 scope radio group (`all`, `mine`, `watching`, `hidden`) styled as Fill count chips with single Tab stop and arrow keys.
fn cvp_scope_grid_node(
  parent : @view.View,
  scope_now : () -> String,
  on_pick : (String) -> Unit,
) -> Unit {
  let pairs : Array[Array[(String, String)]] = [
    [("all", "web-main.filter.chats.all"), ("mine", "web-main.filter.chats.mine")],
    [("watching", "web-main.filter.watching"), ("hidden", "web-main.filter.hidden")],
  ]
  @sf.radio_chip_group(
    parent,
    fn() { @sf.t("web-main.projects.scope") },
    scope_now,
    on_pick,
    fn(grid, rg) {
      grid.row(Is(false)).gap(Is(6.0)).width_share(Is(1.0)) |> ignore
      for pair in pairs {
        grid.box(fn(row) {
          row.row(Is(true)).gap(Is(6.0)).width_share(Is(1.0)) |> ignore
          for entry in pair {
            let key = entry.0
            let word_key = entry.1
            rg.item(row, fn() { key }, fn() { @sf.t(word_key) }, fn(chip, item) {
              chip
              .row(Is(true))
              .grow(Is(1.0))
              .basis(Is(Some(0.0)))
              .min_width(Is(Some(0.0)))
              .min_height(By(fn() { Some(@sf.theme().items.least) }))
              .padding(Is((10.0, 6.0, 10.0, 6.0)))
              .lines_up(Is(Some(Middle)))
              .radius(By(fn() { @ui.tree_theme().corner(Lg) }))
              .ground(By(fn() {
                let t = @sf.theme()
                if item.chosen() {
                  @sf.alpha(t.p.accent, if t.dark { 0.18 } else { 0.11 })
                } else {
                  @ui.tree_theme().color(Tint)
                }
              }))
              .focus_ring_theme()
              |> ignore
              @sf.hover_ground_node(chip, on=fn() { !item.chosen() }, lit=Some(fn() { item.hovered() || item.pressed() || item.focus_shown() }))
              @sf.words_node(chip, fn() { @sf.t(word_key) }, fn() {
                if item.chosen() { cvp_scope_words_on } else { cvp_scope_words }
              })
              .grow(Is(1.0))
              .shrink(Is(1.0))
              .basis(Is(Some(0.0)))
              .min_width(Is(Some(0.0)))
              .cuts(Is(true))
              .allow_ellipsis(Is(true))
              |> ignore
            })
            |> ignore
          }
        })
        |> ignore
      }
    },
  )
  |> ignore
}

///|
/// Bottom navigation row inside `chats_view_panel` (已隐藏 / 已归档).
fn cvp_nav_row_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  checked : Bool,
  on_press : () -> Unit,
) -> Unit {
  @sf.action_box_node(parent, label, fn(_) { on_press() }, fn(row) {
    row
    .row(Is(true))
    .width_share(Is(1.0))
    .min_height(By(fn() { Some(@sf.theme().items.least) }))
    .padding(Is((8.0, 6.0, 8.0, 6.0)))
    .gap(Is(8.0))
    .lines_up(Is(Some(Middle)))
    |> ignore
    @sf.concentric_radius_node(row, fn() { @sf.row_corner })
    @sf.hover_ground_node(row)
    @sf.icon_node(row, icon, 15.0, By(fn() { @sf.theme().p.muted })) |> ignore
    @sf.words_node(row, label, fn() { cvp_nav_words })
    .grow(Is(1.0))
    .shrink(Is(1.0))
    .basis(Is(Some(0.0)))
    .min_width(Is(Some(0.0)))
    .cuts(Is(true))
    .allow_ellipsis(Is(true))
    |> ignore
    if checked {
      @sf.icon_node(row, "check", 14.0, By(fn() { @sf.theme().p.accent })) |> ignore
    } else {
      @sf.icon_node(row, "chevron-right", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
    }
  })
  |> ignore
}

///|
/// Unified live view/filter/grouping panel when `projects` is enabled (`projects_on == true`).
fn chats_view_panel(
  src : Source,
  ws : String,
  from : @sf.Anchor,
  shown : String,
  pressed : @signals.Signal[String?],
  go : (String) -> Unit,
  in_board? : Bool = false,
  along? : @ui.Along = End,
) -> Unit {
  let in_archive = shown == "archive"
  @sf.panel_nodes(
    @sf.t("web-main.filter.chats"),
    fn(pv, close) {
      let scope_now = fn() -> String {
        if in_archive {
          "archive"
        } else if in_board {
          pressed.get().unwrap_or(@sfbase.board_filter_of(src, ws))
        } else {
          @sfbase.filter_of(src, ws)
        }
      }
      pv.box(fn(col) {
        let in_pop = @sf.in_small_panel_node(pv)
        let body_px = if in_pop { cvp_body_in } else { 0.0 }
        col.row(Is(false)).gap(Is(10.0)).width_share(Is(1.0)) |> ignore
        if in_pop {
          let top_pad = if in_archive || in_board { cvp_pad_x } else { 0.0 }
          col.padding(Is((cvp_cap_pad, top_pad, cvp_cap_pad, cvp_pad_x))) |> ignore
          @sf.corner_card_node(col, fn() { @sf.r_menu }, inset=fn() { @sf.panel_pad + cvp_pad_x })
        }
        if in_archive {
          // Archive mode: scope switch back to chats list + current Archived status only.
          col.box(fn(sec) {
            sec.row(Is(false)).gap(Is(6.0)).padding(Is((body_px, 0.0, body_px, 0.0))).width_share(Is(1.0)) |> ignore
            sec.box(fn(t) {
              t.padding(Is((cvp_in, 2.0, cvp_in, 2.0))) |> ignore
              @sf.words_node(t, fn() { @sf.t("web-main.projects.scope") }, fn() { cvp_head_look }) |> ignore
            })
            |> ignore
            cvp_scope_grid_node(sec, scope_now, fn(k) {
              go(k)
              close()
            })
          })
          |> ignore
          cvp_rule_node(col)
          col.box(fn(nav) {
            nav.row(Is(false)).padding(Is((body_px, 0.0, body_px, 0.0))).width_share(Is(1.0)) |> ignore
            cvp_nav_row_node(nav, "archive", fn() { @sf.t("web-main.filter.archived") }, true, close)
          })
          |> ignore
          return
        }
        // Normal mode: panel root holds one page-1 ProjectListChain and one page-1 TagListChain.
        let proj_chain = @sfbase.ProjectListChain::new(ws)
        proj_chain.bind(pv, src)
        let tag_chain = @sfbase.TagListChain::new(ws)
        tag_chain.bind(pv, src)
        // Section 1: Grouping (list mode only)
        if !in_board {
          let effective_project = fn() {
            @sfbase.project_filter_of(ws) == All && @sfbase.list_group_by(src, ws) == "project"
          }
          col.box(fn(sec) {
            sec.row(Is(false)).gap(Is(2.0)).width_share(Is(1.0)) |> ignore
            sec.box(fn(head) {
              head
              .row(Is(true))
              .lines_up(Is(Some(if in_pop { Start } else { Middle })))
              .min_height(By(fn() { Some(@sf.theme().items.least) }))
              .padding(Is((body_px + cvp_in, 0.0, 0.0, 0.0)))
              .width_share(Is(1.0))
              |> ignore
              head.box(fn(lbl) {
                lbl
                .row(Is(true))
                .lines_up(Is(Some(Middle)))
                .grow(Is(1.0))
                .shrink(Is(1.0))
                .basis(Is(Some(0.0)))
                .min_width(Is(Some(0.0)))
                |> ignore
                if in_pop {
                  lbl.min_height(Is(Some(30.0))).padding(Is((0.0, 6.0, 0.0, 0.0))) |> ignore
                }
                @sf.words_node(lbl, fn() { @sf.t("web-main.board.group_by") }, fn() { cvp_head_look }) |> ignore
              })
              |> ignore
              head.show(at_once=true, fn() { effective_project() && @sfbase.has_grouped_collapse_hook(ws) }, fn(btn_slot) {
                let is_all_collapsed = fn() { @sfbase.grouped_collapse_all_collapsed(src, ws) }
                let btn_label = fn() {
                  if is_all_collapsed() {
                    @sf.t("web-main.projects.expand_all")
                  } else {
                    @sf.t("web-main.projects.collapse_all")
                  }
                }
                @sf.panel_link_button_node(btn_slot, btn_label, fn() {
                  @sfbase.trigger_all_groups_collapse(src, ws, !@signals.untracked(is_all_collapsed))
                }, tone=Accent, to_corner=in_pop)
                |> ignore
              })
            })
            |> ignore
            sec.box(fn(seg_wrap) {
              seg_wrap.row(Is(false)).padding(Is((body_px, 0.0, body_px, 0.0))).width_share(Is(1.0)) |> ignore
              @sf.seg_fill_node(
                seg_wrap,
                fn() { [@sf.t("web-main.projects.group_by_time"), @sf.t("web-main.projects.group_by_project")] },
                fn() { if effective_project() { 1 } else { 0 } },
                fn(i) {
                  if i == 1 {
                    @signals.start_batch()
                    if @sfbase.project_filter_of(ws) != All {
                      @sfbase.set_project_filter(ws, All)
                    }
                    @sfbase.set_list_group_by(src, ws, "project")
                    @signals.end_batch()
                  } else {
                    @sfbase.set_list_group_by(src, ws, "")
                  }
                },
                said=@sf.t("web-main.board.group_by"),
              )
              |> ignore
            })
            |> ignore
            sec.show(at_once=true, fn() { @sfbase.project_filter_of(ws) != All }, fn(h) {
              h.padding(Is((body_px + cvp_in, 6.0, body_px + cvp_in, 0.0))).width_share(Is(1.0)) |> ignore
              @sf.words_node(h, fn() { @sf.t("web-main.projects.group_by_project_clears_filter") }, fn() { cvp_hint_look }) |> ignore
            })
          })
          |> ignore
          cvp_rule_node(col)
        }
        // Section 2: Scope
        col.box(fn(sec) {
          sec.row(Is(false)).gap(Is(6.0)).padding(Is((body_px, 0.0, body_px, 0.0))).width_share(Is(1.0)) |> ignore
          sec.box(fn(t) {
            t.padding(Is((cvp_in, 2.0, cvp_in, 2.0))) |> ignore
            @sf.words_node(t, fn() { @sf.t("web-main.projects.scope") }, fn() { cvp_head_look }) |> ignore
          })
          |> ignore
          if in_board {
            @sf.seg_fill_node(
              sec,
              fn() { [@sf.t("web-main.filter.chats.all"), @sf.t("web-main.filter.chats.mine")] },
              fn() { if scope_now() == "mine" { 1 } else { 0 } },
              fn(i) { go(if i == 1 { "mine" } else { "all" }) },
              said=@sf.t("web-main.projects.scope"),
            )
            |> ignore
          } else {
            cvp_scope_grid_node(sec, scope_now, fn(k) { go(k) })
          }
        })
        |> ignore
        cvp_rule_node(col)
        // Section 3: Filters (Projects + Tags)
        col.box(fn(sec) {
          sec.row(Is(false)).gap(Is(0.0)).padding(Is((body_px, 0.0, body_px, 0.0))).width_share(Is(1.0)) |> ignore
          // Filter section header + Clear filters
          sec.box(fn(head) {
            head
            .row(Is(true))
            .lines_up(Is(Some(Middle)))
            .min_height(By(fn() { Some(@sf.theme().items.least) }))
            .padding(Is((cvp_in, 0.0, 0.0, 0.0)))
            .width_share(Is(1.0))
            |> ignore
            @sf.words_node(head, fn() { @sf.t("web-main.projects.filter_section") }, fn() { cvp_head_look })
            .grow(Is(1.0))
            .shrink(Is(1.0))
            .basis(Is(Some(0.0)))
            .min_width(Is(Some(0.0)))
            |> ignore
            head.show(at_once=true, fn() { @sfbase.has_active_list_filters(ws) }, fn(cl) {
              @sf.panel_link_button_node(cl, fn() { @sf.t("web-main.projects.filter_clear") }, fn() {
                @sfbase.clear_list_filters(ws)
              }, tone=Accent)
              |> ignore
            })
          })
          |> ignore
          // Projects quick-pick (top 6 + Unclassified, pinning currently selected project)
          sec.box(fn(psec) {
            psec.row(Is(false)).gap(Is(0.0)).width_share(Is(1.0)) |> ignore
            psec.box(fn(sh) {
              sh.row(Is(true)).lines_up(Is(Some(Middle))).padding(Is((cvp_in, 0.0, 0.0, 0.0))).width_share(Is(1.0)) |> ignore
              @sf.words_node(sh, fn() { @sf.t("web-main.projects.filter_project") }, fn() { cvp_sub_head_look })
              .grow(Is(1.0))
              .shrink(Is(1.0))
              .basis(Is(Some(0.0)))
              .min_width(Is(Some(0.0)))
              |> ignore
              @sf.panel_link_button_node(sh, fn() { @sf.t("web-main.projects.more_projects") }, fn() {
                close()
                open_project_filter_panel(src, ws, from, along~, from_menu=true)
              }, tone=Quiet, icon="chevron-right")
              |> ignore
            })
            |> ignore
            let quick_projects = fn() -> Array[String] {
              let out : Array[String] = []
              let seen : Map[String, Bool] = Map([])
              let add = fn(name : String) {
                if name != "" && !seen.contains(name) && out.length() < 6 {
                  seen[name] = true
                  out.push("p:" + name)
                }
              }
              match @sfbase.project_filter_of(ws) {
                Named(cur) => add(cur)
                _ => ()
              }
              for row in proj_chain.read(src).items {
                add(row.name)
              }
              out.push("u")
              out
            }
            psec.box(fn(wrap) {
              wrap.row(Is(true)).wraps(Is(Some(0.0))).gap(Is(6.0)).width_share(Is(1.0)) |> ignore
              wrap.each(quick_projects, fn(k) { k }, at_once=true, fn(slot, ksig) {
                let k = @signals.untracked(fn() { ksig.get() })
                if k == "u" {
                  @sf.filter_toggle_chip_node(
                    slot,
                    fn() { @sf.t("web-main.projects.unclassified") },
                    fn() { @sfbase.project_filter_of(ws) == Unclassified },
                    fn() {
                      let next : @sfbase.ProjectFilter = if @sfbase.project_filter_of(ws) == Unclassified { All } else { Unclassified }
                      @sfbase.set_project_filter(ws, next)
                    },
                    max_w=cvp_chip_max_w,
                  )
                  |> ignore
                } else {
                  let pname = k.exact_view(start=2).to_owned()
                  @sf.filter_toggle_chip_node(
                    slot,
                    fn() { pname },
                    fn() { @sfbase.project_filter_of(ws) == Named(pname) },
                    fn() {
                      let next : @sfbase.ProjectFilter = if @sfbase.project_filter_of(ws) == Named(pname) { All } else { Named(pname) }
                      @sfbase.set_project_filter(ws, next)
                    },
                    max_w=cvp_chip_max_w,
                  )
                  |> ignore
                }
              })
            })
            |> ignore
          })
          |> ignore
          // Tags quick-pick (shown when tags exist or a tag filter is active)
          let has_tags_sec = fn() {
            !tag_chain.read(src).items.is_empty() || @sfbase.tag_filter_of(ws) is Some(_)
          }
          sec.show(at_once=true, has_tags_sec, fn(tsec) {
            tsec.row(Is(false)).gap(Is(0.0)).width_share(Is(1.0)) |> ignore
            tsec.box(fn(sh) {
              sh.row(Is(true)).lines_up(Is(Some(Middle))).padding(Is((cvp_in, 0.0, 0.0, 0.0))).width_share(Is(1.0)) |> ignore
              @sf.words_node(sh, fn() { @sf.t("web-main.projects.filter_tag") }, fn() { cvp_sub_head_look })
              .grow(Is(1.0))
              .shrink(Is(1.0))
              .basis(Is(Some(0.0)))
              .min_width(Is(Some(0.0)))
              |> ignore
              @sf.panel_link_button_node(sh, fn() { @sf.t("web-main.projects.more_tags") }, fn() {
                close()
                open_tag_filter_panel(src, ws, from, along~, from_menu=true)
              }, tone=Quiet, icon="chevron-right")
              |> ignore
            })
            |> ignore
            let quick_tags = fn() -> Array[String] {
              let out : Array[String] = []
              let seen : Map[String, Bool] = Map([])
              let add = fn(tg : String) {
                if tg != "" && !seen.contains(tg) && out.length() < 6 {
                  seen[tg] = true
                  out.push(tg)
                }
              }
              match @sfbase.tag_filter_of(ws) {
                Some(cur) => add(cur)
                None => ()
              }
              for row in tag_chain.read(src).items {
                add(row.tag)
              }
              out
            }
            tsec.box(fn(wrap) {
              wrap.row(Is(true)).wraps(Is(Some(0.0))).gap(Is(6.0)).width_share(Is(1.0)) |> ignore
              wrap.each(quick_tags, fn(k) { k }, at_once=true, fn(slot, ksig) {
                let tg = @signals.untracked(fn() { ksig.get() })
                @sf.filter_toggle_chip_node(
                  slot,
                  fn() { "#" + tg },
                  fn() { @sfbase.tag_filter_of(ws) == Some(tg) },
                  fn() {
                    let next = if @sfbase.tag_filter_of(ws) == Some(tg) { None } else { Some(tg) }
                    @sfbase.set_tag_filter(ws, next)
                  },
                  max_w=cvp_chip_max_w,
                )
                |> ignore
              })
            })
            |> ignore
          })
        })
        |> ignore
        cvp_rule_node(col)
        // Bottom nav
        col.box(fn(nav) {
          nav.row(Is(false)).gap(Is(2.0)).padding(Is((body_px, 0.0, body_px, 0.0))).width_share(Is(1.0)) |> ignore
          if in_board {
            cvp_nav_row_node(nav, "eye-off", fn() { @sf.t("web-main.filter.hidden") }, false, fn() {
              go("hidden")
              close()
            })
          }
          cvp_nav_row_node(nav, "archive", fn() { @sf.t("web-main.filter.archived") }, false, fn() {
            go("archive")
            close()
          })
        })
        |> ignore
      })
      |> ignore
    },
    from~,
    w=cvp_panel_w,
    heads_itself=true,
    hugs=true,
    along~,
  )
  filter_menu_serial.val = @sf.last_presented()
  filter_menu_opened.set(filter_menu_opened.untracked() + 1)
}

///|
/// Open park-safe searchable project filter picker panel (`ProjectListChain`).
/// Shared by `chats_view_panel`'s "更多项目 >" (returns via `panel_back()`) and `active_filter_bar_node` pills (closes).
fn open_project_filter_panel(
  src : Source,
  ws : String,
  from : @sf.Anchor,
  along? : @ui.Along = End,
  from_menu? : Bool = false,
) -> Unit {
  let query : @signals.Signal[String] = @signals.signal("")
  let field = @ui.Field::new()
  let prev_serial = filter_menu_serial.val
  let sub_serial : Ref[Int] = Ref(-1)
  @sf.panel_nodes(
    @sf.t("web-main.projects.filter_project"),
    fn(pv, close) {
      if from_menu {
        pv.owns(fn() {
          if filter_menu_serial.val == sub_serial.val {
            filter_menu_serial.val = prev_serial
          }
        })
        |> ignore
      }
      let finish = fn() {
        if @sf.panel_depth() > 1 {
          @sf.panel_back() |> ignore
        } else {
          close()
        }
      }
      pv.box(fn(col) {
        col.row(Is(false)).grow(Is(1.0)).min_height(Is(Some(0.0))).width_share(Is(1.0)).gap(Is(8.0)) |> ignore
        col.box(fn(head) {
          head.padding(Is((proj_pad_x, proj_s1, proj_pad_x, 0.0))).width_share(Is(1.0)) |> ignore
          @sf.input_node(
            head,
            field,
            placeholder_by=fn() { @sf.t("web-pages.projects.search_placeholder") },
            small=true,
            edited=fn(s) { query.set(s) },
          )
          |> ignore
        })
        |> ignore
        col.pick(at_once=true, fn() { query.get().trim().to_owned() }, fn(list_host, q) {
          list_host.grow(Is(1.0)).min_height(Is(Some(0.0))).width_share(Is(1.0)) |> ignore
          let chain = @sfbase.ProjectListChain::new(ws, q~)
          chain.bind(list_host, src)
          let snap = fn() { chain.read(src) }
          let keys = fn() {
            let s = snap()
            let out : Array[String] = []
            let body : Array[String] = []
            if s.error is Some(_) {
              body.push("error")
            } else if s.loading && s.items.is_empty() {
              body.push("loading")
            } else if s.items.is_empty() {
              body.push("empty")
            } else {
              for r in s.items {
                body.push("p/" + r.name)
              }
              if s.has_more {
                body.push("more")
              }
            }
            if q == "" {
              out.push("all")
              out.push("unclassified")
              if !body.is_empty() {
                out.push("sep")
              }
            }
            for b in body {
              out.push(b)
            }
            out
          }
          @sf.panel_list_node(list_host, keys, est=44.0, fills=true, fn(r, k) {
            let cur = fn() { @sfbase.project_filter_of(ws) }
            if k == "all" {
              @sf.action_box_node(r, fn() { @sf.t("web-main.projects.filter_all") }, fn(_) {
                @sfbase.set_project_filter(ws, All)
                finish()
              }, fn(row) {
                row.row(Is(true)).lines_up(Is(Some(Middle))).min_height(By(fn() { Some(@sf.theme().items.least) })).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { @sf.t("web-main.projects.filter_all") }, fn() { proj_row_name }).grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
                row.show(fn() { cur() == All }, fn(ck) { @sf.icon_node(ck, "check", 14.0, By(fn() { @sf.theme().p.text })) |> ignore })
              })
              |> ignore
            } else if k == "unclassified" {
              @sf.action_box_node(r, fn() { @sf.t("web-main.projects.unclassified") }, fn(_) {
                @sfbase.set_project_filter(ws, Unclassified)
                finish()
              }, fn(row) {
                row.row(Is(true)).lines_up(Is(Some(Middle))).min_height(By(fn() { Some(@sf.theme().items.least) })).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { @sf.t("web-main.projects.unclassified") }, fn() { proj_row_name }).grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
                row.show(fn() { cur() == Unclassified }, fn(ck) { @sf.icon_node(ck, "check", 14.0, By(fn() { @sf.theme().p.text })) |> ignore })
              })
              |> ignore
            } else if k == "sep" {
              r.box(fn(sep) {
                @sf.style_node(sep, fn() { @sf.rule_line })
                sep.margin(Is((proj_pad_x, proj_s1, proj_pad_x, proj_s1))) |> ignore
              })
              |> ignore
            } else if k == "loading" {
              r.box(fn(row) {
                row.padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { @sf.t("web-main.projects.loading") }, fn() { proj_summary_words }) |> ignore
              })
              |> ignore
            } else if k == "empty" {
              r.box(fn(row) {
                row.padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() {
                  if q != "" { @sf.t("web-main.projects.filter_search_empty") } else { @sf.t("web-pages.projects.empty_projects") }
                }, fn() { proj_summary_words })
                |> ignore
              })
              |> ignore
            } else if k == "error" {
              r.box(fn(row) {
                row.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(proj_s2)).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { snap().error.unwrap_or("") }, fn() { proj_picker_err })
                .grow(Is(1.0))
                .basis(Is(Some(0.0)))
                .min_width(Is(Some(0.0)))
                |> ignore
                @sf.panel_link_button_node(row, fn() { @sf.t("common.retry") }, fn() { chain.retry(src) })
                |> ignore
              })
              |> ignore
            } else if k == "more" {
              @sf.action_box_node(r, fn() { @sf.t("web-pages.projects.load_more") }, fn(_) { chain.load_more(src) }, fn(row) {
                row.row(Is(true)).lines_up(Is(Some(Middle))).min_height(By(fn() { Some(@sf.theme().items.least) })).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { @sf.t("web-pages.projects.load_more") }, fn() { proj_summary_words }) |> ignore
              })
              |> ignore
            } else if k.has_prefix("p/") {
              let pname = k.exact_view(start=2).to_owned()
              @sf.action_box_node(r, fn() { pname }, fn(_) {
                @sfbase.set_project_filter(ws, Named(pname))
                finish()
              }, fn(row) {
                row.row(Is(true)).lines_up(Is(Some(Middle))).min_height(By(fn() { Some(@sf.theme().items.least) })).gap(Is(proj_s2)).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { pname }, fn() { proj_row_name }).grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).cuts(Is(true)).allow_ellipsis(Is(true)) |> ignore
                @sf.words_node(
                  row,
                  fn() { snap().items.iter().find_first(fn(x) { x.name == pname }).map_or("", fn(x) { x.chat_count.to_string() }) },
                  fn() { proj_row_count },
                )
                |> ignore
                row.show(fn() { cur() == Named(pname) }, fn(ck) { @sf.icon_node(ck, "check", 14.0, By(fn() { @sf.theme().p.text })) |> ignore })
              })
              |> ignore
            }
          })
          |> ignore
        })
      })
      |> ignore
    },
    from~,
    w=cvp_panel_w,
    along~,
  )
  if from_menu {
    sub_serial.val = @sf.last_presented()
    filter_menu_serial.val = sub_serial.val
  }
}

///|
/// Open park-safe searchable tag filter picker panel (`TagListChain`).
/// Shared by `chats_view_panel`'s "更多标签 >" (returns via `panel_back()`) and `active_filter_bar_node` pills (closes).
fn open_tag_filter_panel(
  src : Source,
  ws : String,
  from : @sf.Anchor,
  along? : @ui.Along = End,
  from_menu? : Bool = false,
) -> Unit {
  let query : @signals.Signal[String] = @signals.signal("")
  let retry_tick : @signals.Signal[Int] = @signals.signal(0)
  let field = @ui.Field::new()
  let prev_serial = filter_menu_serial.val
  let sub_serial : Ref[Int] = Ref(-1)
  @sf.panel_nodes(
    @sf.t("web-main.projects.filter_tag"),
    fn(pv, close) {
      if from_menu {
        pv.owns(fn() {
          if filter_menu_serial.val == sub_serial.val {
            filter_menu_serial.val = prev_serial
          }
        })
        |> ignore
      }
      let finish = fn() {
        if @sf.panel_depth() > 1 {
          @sf.panel_back() |> ignore
        } else {
          close()
        }
      }
      pv.box(fn(col) {
        col.row(Is(false)).grow(Is(1.0)).min_height(Is(Some(0.0))).width_share(Is(1.0)).gap(Is(8.0)) |> ignore
        col.box(fn(head) {
          head.padding(Is((proj_pad_x, proj_s1, proj_pad_x, 0.0))).width_share(Is(1.0)) |> ignore
          @sf.input_node(
            head,
            field,
            placeholder_by=fn() { @sf.t("web-pages.projects.search_tags_placeholder") },
            small=true,
            edited=fn(s) { query.set(s) },
          )
          |> ignore
        })
        |> ignore
        col.pick(at_once=true, fn() { (query.get().trim().to_owned(), retry_tick.get()) }, fn(list_host, key) {
          let q = key.0
          list_host.grow(Is(1.0)).min_height(Is(Some(0.0))).width_share(Is(1.0)) |> ignore
          let chain = @sfbase.TagListChain::new(ws, q~)
          chain.bind(list_host, src)
          let snap = fn() { chain.read(src) }
          let keys = fn() {
            let s = snap()
            let out : Array[String] = []
            let body : Array[String] = []
            if s.error is Some(_) {
              body.push("error")
            } else if s.loading && s.items.is_empty() {
              body.push("loading")
            } else if s.items.is_empty() {
              body.push("empty")
            } else {
              for r in s.items {
                body.push("t/" + r.tag)
              }
              if s.has_more {
                body.push("more")
              }
            }
            if q == "" {
              out.push("all")
              if !body.is_empty() {
                out.push("sep")
              }
            }
            for b in body {
              out.push(b)
            }
            out
          }
          @sf.panel_list_node(list_host, keys, est=44.0, fills=true, fn(r, k) {
            let cur = fn() { @sfbase.tag_filter_of(ws) }
            if k == "all" {
              @sf.action_box_node(r, fn() { @sf.t("web-main.projects.filter_all") }, fn(_) {
                @sfbase.set_tag_filter(ws, None)
                finish()
              }, fn(row) {
                row.row(Is(true)).lines_up(Is(Some(Middle))).min_height(By(fn() { Some(@sf.theme().items.least) })).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { @sf.t("web-main.projects.filter_all") }, fn() { proj_row_name }).grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
                row.show(fn() { cur() is None }, fn(ck) { @sf.icon_node(ck, "check", 14.0, By(fn() { @sf.theme().p.text })) |> ignore })
              })
              |> ignore
            } else if k == "sep" {
              r.box(fn(sep) {
                @sf.style_node(sep, fn() { @sf.rule_line })
                sep.margin(Is((proj_pad_x, proj_s1, proj_pad_x, proj_s1))) |> ignore
              })
              |> ignore
            } else if k == "loading" {
              r.box(fn(row) {
                row.padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { @sf.t("web-main.projects.loading") }, fn() { proj_summary_words }) |> ignore
              })
              |> ignore
            } else if k == "empty" {
              r.box(fn(row) {
                row.padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() {
                  if q != "" { @sf.t("web-main.projects.filter_search_empty") } else { @sf.t("web-pages.projects.empty_tags") }
                }, fn() { proj_summary_words })
                |> ignore
              })
              |> ignore
            } else if k == "error" {
              r.box(fn(row) {
                row.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(proj_s2)).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { snap().error.unwrap_or("") }, fn() { proj_picker_err })
                .grow(Is(1.0))
                .basis(Is(Some(0.0)))
                .min_width(Is(Some(0.0)))
                |> ignore
                @sf.panel_link_button_node(row, fn() { @sf.t("common.retry") }, fn() {
                  let p : Map[String, Json] = { "scope": Json::string(ws) }
                  if q != "" {
                    p["q"] = Json::string(q)
                  }
                  (src.refresh)("tags", p)
                  retry_tick.set(retry_tick.untracked() + 1)
                })
                |> ignore
              })
              |> ignore
            } else if k == "more" {
              @sf.action_box_node(r, fn() { @sf.t("web-pages.projects.load_more") }, fn(_) { chain.load_more(src) }, fn(row) {
                row.row(Is(true)).lines_up(Is(Some(Middle))).min_height(By(fn() { Some(@sf.theme().items.least) })).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { @sf.t("web-pages.projects.load_more") }, fn() { proj_summary_words }) |> ignore
              })
              |> ignore
            } else if k.has_prefix("t/") {
              let tname = k.exact_view(start=2).to_owned()
              @sf.action_box_node(r, fn() { "#" + tname }, fn(_) {
                @sfbase.set_tag_filter(ws, Some(tname))
                finish()
              }, fn(row) {
                row.row(Is(true)).lines_up(Is(Some(Middle))).min_height(By(fn() { Some(@sf.theme().items.least) })).gap(Is(proj_s2)).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
                @sf.words_node(row, fn() { "#" + tname }, fn() { proj_row_name }).grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).cuts(Is(true)).allow_ellipsis(Is(true)) |> ignore
                @sf.words_node(
                  row,
                  fn() { snap().items.iter().find_first(fn(x) { x.tag == tname }).map_or("", fn(x) { x.chat_count.to_string() }) },
                  fn() { proj_row_count },
                )
                |> ignore
                row.show(fn() { cur() == Some(tname) }, fn(ck) { @sf.icon_node(ck, "check", 14.0, By(fn() { @sf.theme().p.text })) |> ignore })
              })
              |> ignore
            }
          })
          |> ignore
        })
      })
      |> ignore
    },
    from~,
    w=cvp_panel_w,
    along~,
  )
  if from_menu {
    sub_serial.val = @sf.last_presented()
    filter_menu_serial.val = sub_serial.val
  }
}

///|
/// Single height source for the fixed active filter bar (0 when hidden, in archive mode, or `projects` off).
pub fn active_filter_bar_h(src : Source, ws : String, in_archive? : Bool = false) -> Double {
  if !in_archive && @sfbase.has_active_list_filters(ws) && @sfbase.workspace_projects_on(src, ws) {
    active_filter_bar_row_h
  } else {
    0.0
  }
}

///|
/// Fixed active filter bar reusing standard 44pt `@sf.filter_pill_node` capsules with 32pt concentric `×` targets.
/// Clicking a pill opens its standalone picker anchored to the pill; clicking `×` clears that filter alone.
pub fn active_filter_bar_node(
  parent : @view.View,
  src : Source,
  ws : () -> String,
  px? : Double = 8.0,
  along? : @ui.Along = Start,
) -> Unit {
  parent.by_room(fn(host, given) {
    host.width_share(Is(1.0)).min_height(Is(Some(active_filter_bar_row_h))) |> ignore
    host.scrolls(@view.Scroll::across(), slop=@ui.touch_slop(), fn(bar) {
      bar
      .row(Is(true))
      .min_width(By(fn() { Some(given.width()) }))
      .min_height(Is(Some(active_filter_bar_row_h)))
      .lines_up(Is(Some(Middle)))
      .gap(Is(6.0))
      .padding(Is((px, 2.0, px, 6.0)))
      |> ignore
      let pill_max_w = fn() -> Double? {
        let avail = dmax(140.0, given.width() - 2.0 * px)
        let both = @sfbase.project_filter_of(ws()) != All && @sfbase.tag_filter_of(ws()) is Some(_)
        Some(if both { dmin(avail, dmax(150.0, avail * 0.62)) } else { avail })
      }
      bar.show(at_once=true, fn() { @sfbase.project_filter_of(ws()) != All }, fn(slot) {
        slot.shrink(Is(0.0)).max_width(By(pill_max_w)) |> ignore
        let label = fn() {
          match @sfbase.project_filter_of(ws()) {
            All => ""
            Unclassified => @sf.t("web-main.projects.unclassified")
            Named(p) => p
          }
        }
        @sf.filter_pill_node(
          slot,
          label,
          fn(btn) { open_project_filter_panel(src, @signals.untracked(ws), Node(btn), along~) },
          picked=fn() { true },
          chevron=false,
          lead=fn(b) {
            @sf.icon_node(b, "folder", 14.0, By(fn() { @sf.theme().p.muted }))
            .margin(Is((2.0, 0.0, 0.0, 0.0)))
            |> ignore
          },
          clear=fn() { @sfbase.set_project_filter(@signals.untracked(ws), All) },
          clear_label=fn() { @sf.t("web-main.projects.clear_project_filter") },
        )
        |> ignore
      })
      bar.show(at_once=true, fn() { @sfbase.tag_filter_of(ws()) is Some(_) }, fn(slot) {
        slot.shrink(Is(0.0)).max_width(By(pill_max_w)) |> ignore
        let label = fn() {
          match @sfbase.tag_filter_of(ws()) {
            Some(t) => "#" + t
            None => ""
          }
        }
        @sf.filter_pill_node(
          slot,
          label,
          fn(btn) { open_tag_filter_panel(src, @signals.untracked(ws), Node(btn), along~) },
          picked=fn() { true },
          chevron=false,
          clear=fn() { @sfbase.set_tag_filter(@signals.untracked(ws), None) },
          clear_label=fn() { @sf.t("web-main.projects.clear_tag_filter") },
        )
        |> ignore
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// How many times the filter's menu has opened: what makes the lists it would show at once told as it does
/// (chats_lists_node).
// kept across runs: counted on as it opens (nothing reads its value, only its change)
let filter_menu_opened : @signals.Signal[Int] = @signals.signal(0)

///|
/// The list's filter in workspace `w` chosen (`all`, `mine`, `watching`): sfbase's set_filter_of.
pub fn set_filter(src : Source, w : Workspace, f : String) -> Unit {
  @sfbase.set_filter_of(src, w.id, f)
}

///|
/// The board's filter's menu chosen (filter_menu's `in_board`) in workspace `w`: 全部会话 and 我参与的 narrow the board
/// (sfbase's board_filter_of), 已隐藏 its list in the board's place, 已归档 `archive` (the frame's: its page or list).
pub fn board_filter_go(src : Source, w : Workspace, f : String, archive : () -> Unit) -> Unit {
  match f {
    "all" | "mine" => set_filter(src, w, f)
    "hidden" => {
      set_filter(src, w, f)
      @sfbase.board_set(src, false)
    }
    "archive" => archive()
    _ => ()
  }
}
