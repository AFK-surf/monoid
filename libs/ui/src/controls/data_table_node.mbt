// A general scrollable, sortable data table built on `GridTable` / `@headless.table`.
// - `Card` surface: borderless list card (`bg=Card`, card corner, `clips(true)` matching `wide_group_node`), single
//   header divider, no row-between dividers — hugs content when rows are few and shrinks to scroll internally when rows
//   exceed the available height.
// - `Plain` surface: frameless, for panels and dialogs (`capped_node` non-virtualized body via `rows`).
// - Sortable column headers reserve a permanent 12pt icon slot (`alpha=0.0` when inactive, `alpha=1.0` when active) so
//   toggling sort never shifts label text horizontally or trips `sizes_steady`.

///|
/// Outer surface of a `data_table_node`.
#derive(Eq, Debug)
pub(all) enum DataTableSurface {
  Card
  Plain
}

///|
/// Sort direction for `TableSort`.
#derive(Eq, Debug)
pub(all) enum SortDir {
  Asc
  Desc
}

///|
/// Active sort column key and direction.
#derive(Eq, Debug)
pub(all) struct TableSort {
  col : String
  dir : SortDir
}

///|
/// Column horizontal alignment shared between header and data cells.
#derive(Eq, Debug)
pub(all) enum ColAlign {
  Start
  End
}

///|
/// Toggles sort state on `sig` for `col`:
/// - `allow_clear=true`: 3-state cycle `None -> default_dir -> opposite -> None`
/// - `allow_clear=false`: 2-state toggle `default_dir <-> opposite`
pub fn toggle_table_sort(
  sig : @signals.Signal[TableSort?],
  col : String,
  default_dir? : SortDir = Asc,
  allow_clear? : Bool = false,
) -> Unit {
  let opposite = fn(d : SortDir) -> SortDir {
    match d {
      Asc => Desc
      Desc => Asc
    }
  }
  match sig.untracked() {
    Some(cur) if cur.col == col =>
      if cur.dir == default_dir {
        sig.set(Some({ col, dir: opposite(default_dir) }))
      } else if allow_clear {
        sig.set(None)
      } else {
        sig.set(Some({ col, dir: default_dir }))
      }
    _ => sig.set(Some({ col, dir: default_dir }))
  }
}

///|
priv enum DataTableBody {
  NoBody
  PlainRows(() -> Array[String], (DataTableRow, String) -> Unit, SourceLoc)
  VirtualRows(
    () -> Array[String],
    (DataTableRow, String) -> Unit,
    Double,
    ((String) -> Int?)?,
    ((DataTableRow, Int, () -> String) -> Unit)?,
    (() -> Double)?,
    SourceLoc,
  )
}

///|
/// Builder scope for `data_table_node`: declare `head`, `rows` or `virtual_rows`, optional `group_header`, and optional `empty`.
pub struct DataTableScope {
  priv mut head_fn : ((DataTableHead) -> Unit)?
  priv mut body : DataTableBody
  priv mut empty_fn : ((@view.View) -> Unit)?
  priv mut group_fn : (((String) -> Bool), (@view.View, () -> String) -> Unit)?
}

///|
/// Header row scope passed to `DataTableScope::head`.
pub struct DataTableHead {
  priv row_view : @view.View
  priv grid_row : GridRow
  priv surface : DataTableSurface
}

///|
/// Body row scope passed to `DataTableScope::rows` and `DataTableScope::virtual_rows`.
pub struct DataTableRow {
  priv row_view : @view.View
  priv grid_row : GridRow
}

///|
/// Underlying view node of a data table row (for row-level padding, press/hover customization, or action wrappers).
pub fn DataTableRow::view(self : DataTableRow) -> @view.View {
  self.row_view
}

///|
/// Registers the fixed header row (with a 1px `rule_line` divider below it).
pub fn DataTableScope::head(self : DataTableScope, make : (DataTableHead) -> Unit) -> Unit {
  self.head_fn = Some(make)
}

///|
/// Registers an empty-state view rendered inside the table body when `keys()` is empty.
pub fn DataTableScope::empty(self : DataTableScope, make : (@view.View) -> Unit) -> Unit {
  self.empty_fn = Some(make)
}

///|
/// Registers a group subheader renderer inside a virtualized table body. Keys matching `is_group` render as
/// non-hoverable section headers aligned with table columns (no extra dividers, tighter top padding for the first
/// group). Slot reuse kinds for group headers are isolated automatically from caller data-row kinds.
pub fn DataTableScope::group_header(
  self : DataTableScope,
  is_group : (String) -> Bool,
  make : (@view.View, () -> String) -> Unit,
) -> Unit {
  self.group_fn = Some((is_group, make))
}

///|
/// Registers a non-virtualized scrollable body (`capped_node` + `each`, no block reuse), suited for `Plain` panels.
#callsite(autofill(loc))
pub fn DataTableScope::rows(
  self : DataTableScope,
  keys : () -> Array[String],
  row : (DataTableRow, String) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  self.body = PlainRows(keys, row, loc)
}

///|
/// Registers a virtualized scrollable body (`scrolls_window`), with explicit opt-in `reused` / `make_reused`.
#callsite(autofill(loc))
pub fn DataTableScope::virtual_rows(
  self : DataTableScope,
  keys : () -> Array[String],
  row : (DataTableRow, String) -> Unit,
  est? : Double = 48.0,
  reused? : (String) -> Int?,
  make_reused? : (DataTableRow, Int, () -> String) -> Unit,
  end_room? : () -> Double,
  loc~ : SourceLoc,
) -> Unit {
  self.body = VirtualRows(keys, row, est, reused, make_reused, end_room, loc)
}

///|
/// Optional leading slot in the header row (e.g. select-all checkbox), non-shrinking.
pub fn DataTableHead::lead(self : DataTableHead, make : (@view.View) -> Unit) -> Unit {
  self.row_view.box(fn(l) {
    l.shrink(Is(0.0)).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
    make(l)
  })
  |> ignore
}

///|
/// Applies shared column sizing (`None` = flex fill, `Some(f)` = fixed reactive width) to a header or data cell.
fn dt_apply_col_width(v : @view.View, width : (() -> Double?)?) -> Unit {
  match width {
    Some(f) => v.width(By(f)).shrink(Is(0.0)) |> ignore
    None => v.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
  }
}

///|
/// Looks up a built-in data-table i18n key via `t(...)`, falling back to `default_words` if a custom host translator
/// does not define the key.
fn dt_words(key : String, args? : Array[(String, String)] = []) -> String {
  let s = t(key, args~)
  if s == key { default_words(key, args) } else { s }
}

///|
/// Localized accessibility suffix for a table column's sort direction.
fn dt_sort_dir_label(dir : @headless.TableSortDir) -> String {
  match dir {
    Asc => dt_words("common.sort.asc")
    Desc => dt_words("common.sort.desc")
  }
}

///|
/// Clickable pill-rounded sort column button with a permanent 12pt arrow slot so toggling sort never shifts text
/// horizontally. Keeps `Button` semantics (`"按 {column} 排序"` / `"Sort by {column}"`) intact for screen readers.
#callsite(autofill(loc))
pub fn sort_head_button_node(
  parent : @view.View,
  label : () -> String,
  sort_key : String,
  sort : () -> TableSort?,
  on_sort : (String) -> Unit,
  align? : ColAlign = Start,
  plain? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let is_active = fn() {
    match sort() {
      Some(ts) => ts.col == sort_key
      None => false
    }
  }
  let is_desc = fn() {
    match sort() {
      Some(ts) => ts.col == sort_key && ts.dir is Desc
      None => false
    }
  }
  let btn_label = fn() { dt_words("web-main.resources.by", args=[("column", label())]) }
  action_box_node(
    loc~,
    parent,
    btn_label,
    fn(_) { on_sort(sort_key) },
    fn(btn) {
      style_node(
        btn,
        fn() {
          if plain {
            if align is End { dt_sort_btn_plain_end } else { dt_sort_btn_plain_start }
          } else if align is End {
            dt_sort_btn_card_end
          } else {
            dt_sort_btn_card_start
          }
        },
        in_row=true,
      )
      btn.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      if !plain && align is Start {
        btn.margin(Is((-6.0, 0.0, 0.0, 0.0))) |> ignore
      }
      hover_ground_node(btn, lit=Some(fn() { hovered_in_node(btn) || btn.focus_shown() }))
      // Permanent 12pt icon slot keeps column text horizontally steady across sort toggles:
      // placed before the label for End-aligned columns so header text aligns flush-right with values below,
      // and after the label for Start-aligned columns.
      let add_sort_icon = fn() {
        btn.box(fn(ic) {
          ic
          .width(Is(Some(dt_sort_icon_w)))
          .height(Is(Some(dt_sort_icon_w)))
          .shrink(Is(0.0))
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          .alpha(By(fn() { if is_active() { 1.0 } else { 0.0 } }))
          |> ignore
          ic.pick(is_desc, fn(slot, desc) {
            icon_node(
              slot,
              if desc { "arrow-down" } else { "arrow-up" },
              dt_sort_icon_w,
              By(fn() { theme().p.accent_text }),
            )
            |> ignore
          })
        })
        |> ignore
      }
      let add_sort_words = fn() {
        words_node(btn, label, fn() {
          if plain {
            if is_active() { dt_head_plain_on } else { dt_head_plain }
          } else if is_active() {
            dt_head_card_on
          } else {
            dt_head_card
          }
        })
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        |> ignore
      }
      match align {
        End => {
          add_sort_icon()
          add_sort_words()
        }
        Start => {
          add_sort_words()
          add_sort_icon()
        }
      }
    },
  )
}

///|
/// Adds a column header cell. When `sort_key` and `on_sort` are given, marks the outer header cell as `ColumnHeader`
/// (announcing sort direction) and renders a `sort_head_button_node` inside so `Button` semantics and actions stay intact.
#callsite(autofill(loc))
pub fn DataTableHead::col(
  self : DataTableHead,
  label : () -> String,
  width? : () -> Double?,
  align? : ColAlign = Start,
  sort_key? : String,
  sort? : () -> TableSort?,
  on_sort? : (String) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let justify : @view.Lies = match align {
    Start => Start
    End => End
  }
  match (sort_key, on_sort) {
    (Some(sk), Some(cb)) => {
      let read_sort = match sort {
        Some(s) => s
        None => fn() { None }
      }
      let cur_dir = fn() -> @headless.TableSortDir? {
        match read_sort() {
          Some(ts) if ts.col == sk =>
            Some(match ts.dir {
              Asc => @headless.TableSortDir::Asc
              Desc => @headless.TableSortDir::Desc
            })
          _ => None
        }
      }
      let plain = self.surface is Plain
      self.grid_row.sort_head(
        loc~,
        self.row_view,
        label,
        cur_dir,
        sort_label=dt_sort_dir_label,
        fn(th) {
          th.row(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(justify)) |> ignore
          dt_apply_col_width(th, width)
          sort_head_button_node(loc~, th, label, sk, read_sort, cb, align~, plain~) |> ignore
        },
      )
      |> ignore
    }
    _ =>
      self.grid_row.head(loc~, self.row_view, fn(th) {
        th.row(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(justify)) |> ignore
        dt_apply_col_width(th, width)
        let plain = self.surface is Plain
        words_node(th, label, fn() { if plain { dt_head_plain } else { dt_head_card } })
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        |> ignore
      })
      |> ignore
  }
}

///|
/// Optional leading slot in a data row (e.g. row checkbox), non-shrinking.
pub fn DataTableRow::lead(self : DataTableRow, make : (@view.View) -> Unit) -> Unit {
  self.row_view.box(fn(l) {
    l.shrink(Is(0.0)).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
    make(l)
  })
  |> ignore
}

///|
/// Marks an existing cell view inside a custom-wrapped row (such as a whole-row `action_box_node`) with `Cell` semantics.
#callsite(autofill(loc))
pub fn DataTableRow::mark_cell(self : DataTableRow, cell : @view.View, loc~ : SourceLoc) -> Unit {
  self.grid_row.cell(loc~, cell, in_node=true, fn(_) {  }) |> ignore
}

///|
/// Adds a data cell aligned with its header column (`width` and `align`).
#callsite(autofill(loc))
pub fn DataTableRow::cell(
  self : DataTableRow,
  make : (@view.View) -> Unit,
  width? : () -> Double?,
  align? : ColAlign = Start,
  loc~ : SourceLoc,
) -> Unit {
  let justify : @view.Lies = match align {
    Start => Start
    End => End
  }
  self.grid_row.cell(loc~, self.row_view, fn(c) {
    c.row(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(justify)) |> ignore
    dt_apply_col_width(c, width)
    make(c)
  })
  |> ignore
}

///|
/// A general scrollable, sortable data table in `parent`.
/// - `Card`: borderless list card (`bg=Card`, card corner, `clips(true)` matching `wide_group_node`), hugs content when
///   rows are few and shrinks inside a flex column to scroll internally when rows overflow.
/// - `Plain`: frameless, for panels/dialogs.
#callsite(autofill(loc))
pub fn data_table_node(
  parent : @view.View,
  build : (DataTableScope) -> Unit,
  surface? : DataTableSurface = Card,
  max_height? : () -> Double,
  loc~ : SourceLoc,
) -> @view.View {
  let scope : DataTableScope = { head_fn: None, body: NoBody, empty_fn: None, group_fn: None }
  build(scope)
  let is_card = surface is Card
  parent.box(made_for=loc, fn(outer) {
    // Every layer shrinks (`shrink(1.0).min_height(Some(0.0))`) and never `grow(1.0)` so few rows hug content
    // while many rows shrink to fit and scroll inside the table body.
    outer.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    let (card_pad_x, card_ends) = if is_card {
      let (pad, corner) = list_card_in(outer)
      let ends = pad
      outer.radius(Is(corner)).ground(By(fn() { @ui.tree_theme().color(Card) })).clips(Is(true)) |> ignore
      corner_card_node(outer, fn() { corner }, inset=fn() { pad })
      (pad, ends)
    } else {
      (0.0, 0.0)
    }
    match max_height {
      Some(mh) if is_card => outer.max_height(By(fn() { Some(mh()) })) |> ignore
      _ => ()
    }
    grid_table_node(loc~, outer, fn(tbl, tb) {
      tbl.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      // Fixed table header + single 1px hairline divider below it (matching station picker; no row-between dividers).
      match scope.head_fn {
        Some(make_head) => {
          tb.row(loc~, tbl, fn(hdr, hr) {
            hdr.shrink(Is(0.0)) |> ignore
            style_node(hdr, fn() {
              if is_card {
                dt_head_row_card.then(@ui.style(min_h=Fixed(dt_head_card_min_h + card_ends)))
              } else {
                dt_head_row_plain
              }
            })
            if is_card {
              hdr.padding(Is((18.0 + card_pad_x, card_ends + 2.0, 18.0 + card_pad_x, 2.0))) |> ignore
            }
            make_head({ row_view: hdr, grid_row: hr, surface })
          })
          |> ignore
          tbl.box(fn(div) {
            div.shrink(Is(0.0)) |> ignore
            if is_card {
              div.padding(Is((card_pad_x, 0.0, card_pad_x, 4.0))) |> ignore
            } else {
              style_node(div, fn() { dt_head_rule_plain })
            }
            div.box(fn(ln) { style_node(ln, fn() { rule_line }) }) |> ignore
          })
          |> ignore
        }
        None => ()
      }
      // Body
      match scope.body {
        NoBody => ()
        PlainRows(keys, make_row, body_loc) => {
          let mh = match max_height {
            Some(f) => f
            None => fn() { dt_default_capped_h }
          }
          let render_plain = fn(list : @view.View) {
            if !is_card {
              list.gap(Is(lit_apart)) |> ignore
            }
            match scope.empty_fn {
              Some(make_empty) =>
                list.show(at_once=true, fn() { keys().is_empty() }, fn(em) { make_empty(em) })
              None => ()
            }
            list.each(keys, fn(k) { k }, fn(row_host, k_sig) {
              let k = k_sig.untracked()
              tb.row(loc=body_loc, row_host, in_node=true, fn(rv, gr) {
                make_row({ row_view: rv, grid_row: gr }, k)
              })
              |> ignore
            })
          }
          capped_node(loc=body_loc, tbl, mh, render_plain, bleed=!is_card) |> ignore
        }
        VirtualRows(keys, make_row, est, reused, make_reused, end_room, body_loc) => {
          match scope.empty_fn {
            Some(make_empty) =>
              tbl.show(at_once=true, fn() { keys().is_empty() }, fn(em) {
                em.shrink(Is(0.0)) |> ignore
                make_empty(em)
              })
            None => ()
          }
          tbl.box(made_for=body_loc, fn(host) {
            host.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
            let scroll = @view.Scroll::list()
            let was : Ref[Set[String]] = Ref(Set([]))
            let other = Ref(false)
            let read_keys = fn() { pg_blocks_read(was, other, keys()) }
            let row_end_room = fn() {
              if keys().is_empty() {
                0.0
              } else {
                let extra = match end_room {
                  Some(er) => er()
                  None => 0.0
                }
                card_ends + extra
              }
            }
            let wrap_group = fn(slot : @view.View, k_fn : () -> String, make_grp : (@view.View, () -> String) -> Unit) {
              slot.grow(Is(1.0)) |> ignore
              if is_card {
                slot.padding(Is((18.0 + card_pad_x, 12.0, 18.0 + card_pad_x, 4.0))) |> ignore
              } else {
                slot.padding(Is((8.0, 10.0, 8.0, 4.0))) |> ignore
              }
              slot.box(fn(g) {
                g.width_share(Is(1.0)).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
                make_grp(g, k_fn)
              })
              |> ignore
            }
            let wrap_row = fn(slot : @view.View, fill : (DataTableRow) -> Unit) {
              slot.grow(Is(1.0)) |> ignore
              if is_card {
                slot.padding(Is((card_pad_x, 0.0, card_pad_x, 0.0))) |> ignore
              }
              tb.row(loc=body_loc, slot, fn(rv, gr) {
                style_node(rv, fn() {
                  if is_card {
                    dt_body_row_card.then(@ui.style(min_h=Fixed(theme().items.least)))
                  } else {
                    dt_body_row_plain
                  }
                })
                if is_card {
                  rv.padding(Is((18.0, 0.0, 18.0, 0.0))).radius(By(fn() { list_row_corner(rv) })) |> ignore
                }
                hover_ground_node(rv, lit=Some(fn() { hovered_in_node(rv) || rv.focus_shown() }))
                fill({ row_view: rv, grid_row: gr })
              })
              |> ignore
            }
            // When `group_header` is registered alongside `reused`, isolate group slots automatically on kind `0` and
            // shift non-negative caller kinds by `+1` so callers cannot accidentally recycle a group slot as a data row.
            let has_group = scope.group_fn is Some(_)
            let eff_reused : ((String) -> Int?)? = match (scope.group_fn, reused) {
              (Some((is_grp, _)), Some(rf)) =>
                Some(fn(k) {
                  if is_grp(k) {
                    Some(0)
                  } else {
                    match rf(k) {
                      Some(n) => Some(if n >= 0 { n + 1 } else { n })
                      None => None
                    }
                  }
                })
              _ => reused
            }
            host.scrolls_window(
              scroll,
              read_keys,
              fn(slot, k) {
                match scope.group_fn {
                  Some((is_grp, make_grp)) if is_grp(k) => wrap_group(slot, fn() { k }, make_grp)
                  _ => wrap_row(slot, fn(r) { make_row(r, k) })
                }
              },
              est~,
              slop=@ui.touch_slop(),
              bar=@ui.tree_scroll_bar(),
              comes=fn(_) { !other.val },
              goes=fn(_) { !other.val },
              end_room=row_end_room,
              reused?=eff_reused,
              make_reused?=make_reused.map(fn(mr) {
                fn(slot, k_fn) {
                  let init_k = @signals.untracked(k_fn)
                  match scope.group_fn {
                    Some((is_grp, make_grp)) if is_grp(init_k) => wrap_group(slot, k_fn, make_grp)
                    _ => {
                      let raw_kind = slot.reused_kind().unwrap_or(0)
                      let kind = if has_group && raw_kind > 0 { raw_kind - 1 } else { raw_kind }
                      wrap_row(slot, fn(r) { mr(r, kind, k_fn) })
                    }
                  }
                }
              }),
            )
            |> ignore
            host.fades(By(fn() {
              let at = scroll.drawn(host.tree)
              let top = scroll.tuck_height()
              let reach = scroll.reach()
              (0.0, dclamp(at - top, 0.0, panel_list_fade), 0.0, dclamp(reach - at, 0.0, panel_list_fade))
            }))
            |> ignore
          })
          |> ignore
        }
      }
    })
    |> ignore
  })
}

///|
let dt_sort_icon_w : Double = 12.0

///|
let dt_head_card_min_h : Double = 40.0

///|
let dt_default_capped_h : Double = 420.0

///|
// kept across runs: a value (no field of it changes)
// Padding is applied explicitly via `hdr.padding` with `card_pad_x` / `card_ends` so `style_node` never overwrites it on theme changes.
let dt_head_row_card : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let dt_head_row_plain : @ui.Style = @ui.css("row w=Full pl=S0_5 pr=S2 py=S1 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let dt_head_rule_plain : @ui.Style = @ui.css("w=Full pb=S1_5")

///|
// kept across runs: a value (no field of it changes)
// Padding is applied explicitly via `rv.padding` with `card_pad_x` so `style_node` never overwrites it on theme changes.
let dt_body_row_card : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let dt_body_row_plain : @ui.Style = @ui.css("row w=Full px=S2 py=S1_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
// Height matches the 18pt header checkbox (`check_node_of`) so same-row controls share one height (`height_faults`).
let dt_sort_btn_card_start : @ui.Style = @ui.css("row px=S1_5 gap=S0_5 align=ACenter justify=JStart radius=Full")

///|
// kept across runs: a value (no field of it changes)
let dt_sort_btn_card_end : @ui.Style = @ui.css("row px=S1_5 gap=S0_5 align=ACenter justify=JEnd radius=Full")

///|
// kept across runs: a value (no field of it changes)
let dt_sort_btn_plain_start : @ui.Style = @ui.css("row px=S1 py=S0_5 gap=S0_5 align=ACenter justify=JStart radius=Full")

///|
// kept across runs: a value (no field of it changes)
let dt_sort_btn_plain_end : @ui.Style = @ui.css("row px=S1 py=S0_5 gap=S0_5 align=ACenter justify=JEnd radius=Full")

///|
// kept across runs: a value (no field of it changes)
let dt_head_card : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false, max_lines=1, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let dt_head_card_on : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false, max_lines=1, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let dt_head_plain : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4, color=Muted, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let dt_head_plain_on : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4, weight=Medium, color=AccentText, wrap=false, w=Hug)
