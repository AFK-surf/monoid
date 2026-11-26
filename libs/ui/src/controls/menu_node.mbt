// A menu of the presenters' (the library's dropdown, kit's dropdown_menu and menu_panel, in the web's look) as nodes of
// the window's tree: a modal layer over the window, nothing under it dimmed, its small panel beside what opened it
// (where it was drawn as it opened: under it, `offset` off, lined up `along` it, over it where there is not the room
// under: View::beside), grown out of that side as it comes (pop_in), drawn back into it as it closes (pop_out, as kit's
// menu goes), nothing of it pressed, modal or read out from the moment it closes; its rows as menu_row draws them (as
// high as the screen's pick row at least, its icon or a choice's check in a column before its words where one has one,
// a danger's in red, one not to be chosen faint), headings and lines between parts; what it holds scrolling where it is
// taller than the window leaves it. Its rows are one roving group, the one with the focus lit: Up and Down move the
// focus along them (round past either end, as a Mac's), Home and End to the ends, letters typed (alone or with
// Shift) to the first whose words start with them (a second's worth together), shown, what holds them bringing it
// into sight; the pointer moving onto one gives it the focus, unseen. Enter, Space, a tap or a click choose one (it
// closes, then what it does goes on); a press on what of its panel cannot be chosen does nothing. Escape, back and a
// press outside close it; a secondary press outside goes on to what is under it. Opened by the keyboard, the focus on
// its first row, shown; else on its panel, nothing lit, till a key or the pointer moves it.

///|
/// A menu in `parent` while `open()` (let go of once drawn back, pop_out_ms after: closing, nothing of it pressed):
/// what `content` holds as it is now (None a line between parts: its rows, what can be chosen of them, the keys' way
/// along them and what a choice does, all from the same of it, read again as it is told changed, the menu open as it
/// was, its focus where it was), headed by `title` ("" none; none drawn over a heading of its own first, still its
/// name to a screen reader), beside what `anchor` makes in its layer (what opened it,
/// where that is drawn), `offset` off it, lined up `along` it; `by_key`: opened by the keyboard (the focus on its first
/// row); `keep_field`: opened by a finger with a field focused (kit's dropdown_menu: its input method left in place):
/// the focus left in that field, what is typed still its (View::leaves_typing), every key, the wheel and every press
/// the menu's as ever. `choose` with the item chosen, once, as it closes; `cancel` as it is closed unchosen. `shown`,
/// `gone`: as dialog_layer_node's. `side`: the side of what opened it it goes on (a submenu's beside its row:
/// submenu_row_node). Not `modal` (a submenu's, as kit's dropdown_menu's `submenu`): what is under it its own as ever,
/// a press outside its panel closing it as it goes down and going on to what it lands on; the arrow key back toward
/// what opened it (away from `side`) closing it too.
pub fn menu_node(
  parent : @view.View,
  open : () -> Bool,
  anchor : (@view.View) -> @view.View,
  content : () -> Array[MenuItem?],
  title : String,
  along : @ui.Along,
  offset : Double,
  by_key : Bool,
  keep_field : Bool,
  choose : (MenuItem) -> Unit,
  cancel : () -> Unit,
  shown? : () -> Unit = fn() {  },
  gone? : () -> Unit = fn() {  },
  extras? : (Int) -> MenuExtra = fn(_) { menu_no_extra },
  min_w? : Double = menu_w,
  max_w? : Double = 0.0,
  side? : @ui.Side = Bottom,
  modal? : Bool = true,
) -> Unit {
  menu_node_by(
    parent,
    open,
    anchor,
    content,
    title,
    along,
    offset,
    by_key,
    keep_field,
    choose,
    cancel,
    shown~,
    gone~,
    extras~,
    min_w~,
    max_w~,
    side~,
    modal~,
    false,
  )
}

///|
/// `menu_node` whose `chosen` items are checkboxes that may be ticked several at once (read out as `MenuItemCheckbox`,
/// the menu left open after `choose` unless the caller closes `open`). `check_end`: each ticked one's check at its row's
/// end, no column before its words for it, its own mark (where it has one) first.
pub fn menu_ticks_node(
  parent : @view.View,
  open : () -> Bool,
  anchor : (@view.View) -> @view.View,
  content : () -> Array[MenuItem?],
  title : String,
  along : @ui.Along,
  offset : Double,
  by_key : Bool,
  keep_field : Bool,
  choose : (MenuItem) -> Unit,
  cancel : () -> Unit,
  shown? : () -> Unit = fn() {  },
  gone? : () -> Unit = fn() {  },
  extras? : (Int) -> MenuExtra = fn(_) { menu_no_extra },
  min_w? : Double = menu_w,
  side? : @ui.Side = Bottom,
  modal? : Bool = true,
  check_end? : Bool = false,
) -> Unit {
  menu_node_by(
    parent,
    open,
    anchor,
    content,
    title,
    along,
    offset,
    by_key,
    keep_field,
    choose,
    cancel,
    shown~,
    gone~,
    extras~,
    min_w~,
    side~,
    modal~,
    true,
    check_end~,
  )
}

///|
fn menu_node_by(
  parent : @view.View,
  open : () -> Bool,
  anchor : (@view.View) -> @view.View,
  content : () -> Array[MenuItem?],
  title : String,
  along : @ui.Along,
  offset : Double,
  by_key : Bool,
  keep_field : Bool,
  choose : (MenuItem) -> Unit,
  cancel : () -> Unit,
  shown? : () -> Unit = fn() {  },
  gone? : () -> Unit = fn() {  },
  extras? : (Int) -> MenuExtra = fn(_) { menu_no_extra },
  min_w? : Double = menu_w,
  max_w? : Double = 0.0,
  side? : @ui.Side = Bottom,
  modal? : Bool = true,
  ticks : Bool,
  check_end? : Bool = false,
  sub_levels? : () -> Array[(Int, String, Array[MenuItem?])] = fn() { [] },
  level_back? : () -> Bool = fn() { false },
  sub_extras? : () -> (Int) -> MenuExtra = fn() { fn(_) { menu_no_extra } },
  panel_ref? : Ref[@view.View?],
  host? : @view.NodeId,
) -> Unit {
  // (no line at either end, none twice: menu_clean_items)
  let content = fn() { menu_clean_items(content()) }
  let cur_level = fn() -> (Int, String, Array[MenuItem?], Int) {
    let subs = sub_levels()
    if subs.is_empty() {
      (0, title, content(), 0)
    } else {
      let last = subs[subs.length() - 1]
      (last.0, last.1, last.2, subs.length())
    }
  }
  let cur_items = fn() { cur_level().2 }
  // (what each row of the level that shows has besides its item: the first level's `extras`, the topmost pushed
  // one's its own)
  let cur_extras = fn() -> (Int) -> MenuExtra { if sub_levels().is_empty() { extras } else { sub_extras() } }
  let cur_title = fn() { cur_level().1 }
  let cur_depth = fn() { cur_level().3 }
  parent.show(
    open,
    fn(layer) {
      shown()
      layer.owns(gone) |> ignore
      let th = theme()
      // (how far in it is, from the moment it opened; out from the moment it closed, back into the side it grew from,
      // as panel_node's)
      let (enter, exit) = @signals.untracked(fn() { (pop_in_for(layer), pop_out_for(layer)) })
      let (look, live) = @motion.overlay_presence(layer, enter~, exit~)
      let rest_end = Ref(0.0)
      if modal {
        if layout(layer.window_w()) is Small {
          layer.reacts(fn() { layer.leaving() }, fn(going) {
            rest_end.val = dmax(rest_end.val, layer.cause_at() + (if going { @motion.pop_out_ms } else { @motion.pop_ms }))
          })
        }
        presented_sheet_rest(layer, fn(_) { rest_end.val })
      }
      // (its words and icons as far in as its look says: its ground first, then they, as pop_in has it)
      let words_in = fn() { look().words }
      // (said once per level: the first choice, or a close; reset when a submenu level pushes/pops)
      let said = Ref(false)
      let go = fn(i : Int) {
        // (what it holds now: what the row pressed shows)
        match @signals.untracked(cur_items).get(i) {
          Some(Some(item)) if !item.disabled && !item.heading && !said.val => {
            // (one taken closes it; one of several ticked leaves it open to tick the next: said again)
            if !ticks {
              said.val = true
            }
            choose(item)
          }
          _ => ()
        }
      }
      // (its panel, once made)
      let panel : Ref[@view.View?] = Ref(None)
      let body_ref : Ref[@view.View?] = Ref(None)
      // (what the level's rows make, scrolled in `active`: as tall as they are, where `active` is no taller than `body`
      // lets it be on its way, so a level taller than the one before would never be gone to)
      let rows_ref : Ref[@view.View?] = Ref(None)
      let reach = menu_row_reach(th.rows.pick)
      let pad_v_of = fn(depth : Int, items : Array[MenuItem?], lv_title : String) -> Double {
        let is_first_row = depth == 0 && items.length() > 0 && (items[0] is Some(i) && !i.heading) && lv_title == ""
        let is_last_row = items.length() > 0 && (items[items.length() - 1] is Some(i) && !i.heading)
        let top_pad = if depth > 0 {
          r_menu - 12.0
        } else if is_first_row {
          panel_pad - reach
        } else {
          panel_pad
        }
        let bot_pad = if is_last_row { panel_pad - reach } else { panel_pad }
        top_pad + bot_pad
      }
      let cur_pad_v = fn() -> Double {
        let (_, lv_t, lv_items, lv_d) = cur_level()
        pad_v_of(lv_d, lv_items, lv_t)
      }
      // (in-container submenu horizontal slide state: closed-form NodeWay, zero overhead when depth == 0)
      let slide_way = @motion.NodeWay::new(1.0)
      let slide_dir : Ref[Double] = Ref(1.0)
      let slide_w : Ref[Double] = Ref(min_w)
      let slide_h_from : Ref[Double] = Ref(0.0)
      let slide_gen : Ref[Int] = Ref(0)
      // (the level going in, laid out unseen as wide as its rows make it while the levels slide (`lv_box`'s twin): how
      // wide the panel goes to, from as wide as it stood, rather than snapping to it as the level changes)
      let ghost_ref : Ref[@view.View?] = Ref(None)
      let leaving_snap : @signals.Signal[(Int, String, Array[MenuItem?], Int)?] = @signals.signal_ref(None)
      let prev_level : Ref[(Int, String, Array[MenuItem?], Int)] = Ref(@signals.untracked(cur_level))
      // (what each level's rows have besides their items, kept from as it came in: one gone back from is no longer
      // the menu's, its picture sliding out still drawn so)
      let level_extras : Map[Int, (Int) -> MenuExtra] = Map([])
      level_extras[prev_level.val.0] = @signals.untracked(cur_extras)
      layer.reacts(fn() { cur_level().0 }, at_start=false, fn(new_id) {
        said.val = false
        let next_lv = @signals.untracked(cur_level)
        let prev_lv = prev_level.val
        level_extras[next_lv.0] = @signals.untracked(cur_extras)
        if prev_lv.0 != new_id {
          slide_dir.val = if next_lv.3 >= prev_lv.3 { 1.0 } else { -1.0 }
          let w_now = match panel.val {
            Some(pv) => pv.placed_window_now().2
            None => min_w
          }
          slide_w.val = dmax(w_now, min_w)
          let old_bh = match body_ref.val {
            Some(bv) => bv.placed_window_now().3
            None => 0.0
          }
          let old_pad_v = pad_v_of(prev_lv.3, prev_lv.2, prev_lv.1)
          let new_pad_v = pad_v_of(next_lv.3, next_lv.2, next_lv.1)
          slide_h_from.val = dmax(0.0, old_bh + old_pad_v - new_pad_v)
          let dur = @ui.move_ms(slide_w.val)
          leaving_snap.set(Some(prev_lv))
          slide_way.go_from(layer, 0.0, 1.0, @motion.moved(points=slide_w.val))
          rest_end.val = dmax(rest_end.val, layer.cause_at() + dur)
          slide_gen.val += 1
          let gen = slide_gen.val
          layer.at_moment(layer.cause_at() + dur, fn() {
            if slide_gen.val == gen {
              leaving_snap.set(None)
              // (none leaving now: only the level that shows is drawn again)
              level_extras.clear()
              level_extras[prev_level.val.0] = @signals.untracked(cur_extras)
            }
          })
          |> ignore
          prev_level.val = next_lv
        }
      })
      layer.over(Is(true)) |> ignore
      // (not modal: the key back toward what opened it)
      let back = match side {
        Right => @ui.key_code_left
        Left => @ui.key_code_right
        _ => -1
      }
      if modal {
        // (a secondary press outside closes the menu and asks what is under it for its own menu at that same press)
        layer.on_menu(fn(m) {
          let inside = match panel.val {
            Some(p) =>
              match p.tree.target_at(m.wx, m.wy) {
                Pressed(id) | Dragged(id) => p.tree.holds(p.id(), id)
                _ => false
              }
            None => false
          }
          if @signals.untracked(live) && !inside {
            cancel()
            layer.menu_behind(m)
          }
        })
        |> ignore
      }
      // (what opened it, where it is drawn: what its panel goes beside)
      let at = anchor(layer)
      // (a column before every item's words where one has an icon or is one of a choice: the web's dropdown)
      let iconed = fn() { cur_items().iter().any(fn(x) { x is Some(i) && i.chosen is None && i.icon != "" }) }
      // (none for a check said to go at its row's end)
      let lead = fn() { iconed() || (!check_end && cur_items().iter().any(fn(x) { x is Some(i) && i.chosen is Some(_) })) }
      let gap = fn() { if lead() && !iconed() { chooser_gap } else { menu_gap } }
      // (how far in a heading's words are: past the check's or icon's column, and a mark's where a row has one, as the
      // dropdown's heading_look has them)
      let marked = fn() {
        let items = cur_items()
        let extras = cur_extras()
        let n = items.length()
        let mut any = false
        for i in 0..<n {
          let leads = match items[i] {
            Some(it) => menu_mark_leads(it, extras(i), check_end~)
            None => false
          }
          if extras(i).mark is Some(_) && !(leads && lead()) {
            any = true
          }
        }
        any
      }
      let past = fn() {
        (if lead() { menu_check_w + gap() } else { 0.0 }) + (if marked() { menu_check_w + gap() } else { 0.0 })
      }
      let first_row = fn() {
        let items = cur_items()
        cur_depth() == 0 && items.length() > 0 && (items[0] is Some(i) && !i.heading) && cur_title() == ""
      }
      let last_row = fn() {
        let items = cur_items()
        items.length() > 0 && (items[items.length() - 1] is Some(i) && !i.heading)
      }
      anchored_popover_bridge(layer, at, look, side~, along~, offset~)
      layer.box(fn(p) {
        panel.val = Some(p)
        match panel_ref {
          Some(r) => {
            r.val = Some(p)
            p.owns(fn() { r.val = None }) |> ignore
          }
          None => ()
        }
        let menu_ref : Ref[@headless.Menu?] = Ref(None)
        // (what it is to the keys and a screen reader: @headless.menu on `p` itself so `Menu` role, rect, and Tab stops
        // (panel + roving item) match the panel; Escape goes through `@headless.overlay` on the unified overlay stack)
        @headless.menu(
          p,
          label=fn() { title_plain(cur_title()) },
          on_close?=if !modal && back >= 0 {
            Some(fn() {
              if @signals.untracked(live) {
                cancel()
              }
            })
          } else {
            None
          },
          close_key?=if !modal && back >= 0 { Some(back) } else { None },
          wraps=true,
          disabled=fn() { !live() },
          takes_focus=true,
          roving=true,
          typeahead=true,
          typeahead_ms=@headless.typeahead_ms,
          keep_field~,
          captures_unfocused=true,
          in_node=true,
          fn(p, menu) {
            menu_ref.val = Some(menu)
            anchored_popover_shell_by(p, at.id(), look, side~, along~, offset~, holds_side=false, host?)
            .min_width(Is(Some(min_w)))
            .width(
              By(fn() {
                let sp = slide_way.shown(p)
                if sp >= 0.999 || leaving_snap.get() is None {
                  None
                } else {
                  let to = match ghost_ref.val {
                    Some(g) => g.placed_window_now().2
                    _ => 0.0
                  }
                  if to <= 0.0 {
                    Some(slide_w.val)
                  } else {
                    let room = dmax(0.0, over_room(layer).0 - 16.0)
                    let to = dmin(dmax(min_w, to), if max_w > 0.0 { dmin(max_w, room) } else { room })
                    Some(slide_w.val + (to - slide_w.val) * sp)
                  }
                }
              }),
            )
            .max_width(
              By(fn() {
                let room = dmax(0.0, over_room(layer).0 - 16.0)
                Some(if max_w > 0.0 { dmin(max_w, room) } else { room })
              }),
            )
            .max_height(By(fn() { Some(dmax(0.0, over_room(layer).1 - 16.0)) }))
            // (small_panel: its padding, its rows reaching past it to stand concentric with its corners;
            // submenu levels use `r_menu - 12` inset so the 24x24 circular `<` back button (radius 12) sits concentric with `r_menu`)
            .padding(
              By(fn() {
                let top_pad = if cur_depth() > 0 {
                  r_menu - 12.0
                } else if first_row() {
                  panel_pad - reach
                } else {
                  panel_pad
                }
                (panel_pad - reach, top_pad, panel_pad - reach, if last_row() { panel_pad - reach } else { panel_pad })
              }),
            )
            |> ignore
            p.box(fn(body) {
              body_ref.val = Some(body)
              // (all it holds as far in as its look says, past the panel's own ground, edge and shadow: its rows, their
              // grounds, checks, marks and words, its headings and lines, the same, Look's `words` as a surface's are)
              let side = panel_pad - reach
              body
              .margin(Is((-side, 0.0, -side, 0.0)))
              .clips(Is(true))
              .height(
                By(fn() {
                  let sp = slide_way.shown(body)
                  if sp >= 0.999 || slide_h_from.val <= 0.0 {
                    None
                  } else {
                    let h_to = match rows_ref.val {
                      Some(av) => av.placed_window_now().3
                      None => 0.0
                    }
                    if h_to <= 0.0 {
                      None
                    } else {
                      let cap = dmax(0.0, over_room(layer).1 - 16.0 - cur_pad_v())
                      Some(dmin(cap, slide_h_from.val + (dmin(h_to, cap) - slide_h_from.val) * sp))
                    }
                  }
                }),
              )
              |> ignore
              popover_content_motion(p, body, words_in)
              body.box(fn(active) {
                active
                .shrink(Is(0.0))
                .offset(
                  By(fn() {
                    let sp = slide_way.shown(active)
                    if sp >= 0.999 {
                      (0.0, 0.0)
                    } else {
                      (slide_dir.val * (1.0 - sp) * slide_w.val, 0.0)
                    }
                  }),
                )
                |> ignore
                active.scrolls(@view.Scroll::new(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(b) {
                  rows_ref.val = Some(b)
                  b.padding(Is((side, 0.0, side, 0.0))) |> ignore
                  // (submenu level header: concentric 24x24 `<` back button + submenu title; at_once=true because level switch is driven by horizontal slide_way)
                  b.show(fn() { cur_depth() > 0 }, at_once=true, fn(hdr) {
                    let back_pad_l = dmax(0.0, r_menu - 12.0 - side)
                    hdr
                    .row(Is(true))
                    .lines_up(Is(Some(Middle)))
                    .gap(Is(4.0))
                    .padding(Is((back_pad_l, 0.0, text_in, 4.0)))
                    |> ignore
                    icon_button_node(
                      hdr,
                      "chevron-left",
                      fn() { t("common.back") },
                      fn() { level_back() |> ignore },
                      size=24.0,
                    )
                    |> ignore
                    hdr.box(fn(tw) {
                      tw
                      .words(By(cur_title), look=toast_words_look(Ui, L5, 600, false))
                      .ink(By(fn() { @ui.tree_theme().color(Fg) }))
                      |> ignore
                    })
                    |> ignore
                  })
                  // (its title over its rows on level 0, in a heading's look: none over a heading of its own first)
                  if title != "" {
                    b.show(fn() { cur_depth() == 0 && !(cur_items().get(0) is Some(Some(i)) && i.heading) }, at_once=true, fn(h) {
                      menu_heading_node(h, fn() { title }, past, reach)
                    })
                  }
                  // (each of what it holds by its level, place and kind: at_once=true so old level rows unmount immediately instead of collapsing above the new level while lv_box slides out)
                  b.each(
                    fn() {
                      let (lv_id, _, items, _) = cur_level()
                      items.mapi(fn(i, x) { (lv_id, i, menu_row_kind(x, ticks)) })
                    },
                    fn(k) { k },
                    at_once=true,
                    fn(cell, k) {
                      let (_, i, kind) = k.untracked()
                      let item = fn() {
                        match cur_items().get(i) {
                          Some(Some(item)) => item
                          _ => menu_none
                        }
                      }
                      // (made as its level shows: that level's)
                      let row_extra = @signals.untracked(cur_extras)(i)
                      match kind {
                        0 => menu_rule_node(cell, reach)
                        1 => menu_heading_node(cell, fn() { item().label }, past, reach)
                        _ =>
                          menu_row_node(
                            cell,
                            menu,
                            item,
                            kind,
                            lead,
                            gap,
                            reach,
                            fn() { go(i) },
                            row_extra,
                            check_end~,
                            clip_label=max_w > 0.0,
                          )
                          |> ignore
                      }
                    },
                  )
                })
                |> ignore
              })
              |> ignore
              // (the level going in, unseen, as wide as it makes itself: what the panel's width goes to as they slide)
              body.show(fn() { leaving_snap.get() is Some(_) }, at_once=true, fn(gv) {
                // (given all the room the panel may have, in a row it is not shrunk in: as wide as its rows make it, past
                // the panel as it stands where it is wider)
                gv
                .over(Is(true), edges=(Some(0.0), Some(0.0), None, None))
                .width(By(fn() { Some(dmax(0.0, over_room(layer).0 - 16.0)) }))
                .row(Is(true))
                .lines_up(Is(Some(Start)))
                .points(Is(false))
                .alpha(Is(0.0))
                .hides(Is(true))
                |> ignore
                gv.each(fn() { [cur_level().0] }, fn(k) { k }, at_once=true, fn(g, _) {
                  ghost_ref.val = Some(g)
                  g.owns(fn() { if ghost_ref.val is Some(now) && now.id() == g.id() { ghost_ref.val = None } }) |> ignore
                  g.shrink(Is(0.0)).padding(Is((side, 0.0, side, 0.0))) |> ignore
                  let (_, g_title, g_items, g_depth) = @signals.untracked(cur_level)
                  menu_leaving_level_node(g, g_title, g_items, g_depth, side, reach, th.rows.pick, @signals.untracked(cur_extras), check_end)
                })
              })
              // (leaving level snapshot sliding out horizontally while the new level slides in; unmounted on settle; made
              // again for each level that leaves, one going in or back mid-slide its own, as wide as the panel stood then)
              body.show(fn() { leaving_snap.get() is Some(_) }, at_once=true, fn(lv_over) {
                lv_over.over(Is(true)).points(Is(false)) |> ignore
                lv_over.each(
                  fn() {
                    match leaving_snap.get() {
                      Some(snap) => [snap.0]
                      None => []
                    }
                  },
                  fn(k) { k },
                  at_once=true,
                  fn(lv_box, _) {
                    let w = slide_w.val
                    lv_box
                    .width(Is(Some(w)))
                    .padding(Is((side, 0.0, side, 0.0)))
                    .offset(
                      By(fn() {
                        let sp = slide_way.shown(lv_box)
                        (-slide_dir.val * sp * w, 0.0)
                      }),
                    )
                    .alpha(By(fn() { 1.0 - slide_way.shown(lv_box) * 0.35 }))
                    |> ignore
                    match @signals.untracked(fn() { leaving_snap.get() }) {
                      Some((snap_id, snap_title, snap_items, snap_depth)) =>
                        menu_leaving_level_node(
                          lv_box,
                          snap_title,
                          snap_items,
                          snap_depth,
                          side,
                          reach,
                          th.rows.pick,
                          level_extras.get(snap_id).unwrap_or(fn(_) { menu_no_extra }),
                          check_end,
                        )
                      None => ()
                    }
                  },
                )
              })
            })
            |> ignore
          },
        )
        |> ignore
        // (the focus given as it opens: opened by the keyboard, to its first item; else its panel; or, by a finger
        // beside a field, left in that field (`keep_field`), returning focus as it goes)
        let first_takes = if !keep_field && by_key {
          Some(fn(s : @view.Said) {
            s.role == MenuItem || s.role == MenuItemCheckbox || s.role == MenuItemRadio
          })
        } else {
          None
        }
        let init_focus = if !keep_field && !by_key { Some(p) } else { None }
        let before_dismiss = fn(how : @headless.OverlayDismiss) {
          how == Back && level_back()
        }
        let ov_ref : Ref[@headless.Overlay?] = Ref(None)
        if modal {
          @headless.overlay(
            layer,
            fn(_) { cancel() },
            modal=true,
            held_back_goes_on=true,
            dismiss_on_escape=true,
            dismiss_on_outside=false,
            inert=fn() { layer.leaving() },
            leaves_typing=keep_field,
            auto_focus=!keep_field,
            first_takes?,
            initial_focus?=init_focus,
            before_dismiss~,
            in_node=true,
            fn(_, ov) { ov_ref.val = Some(ov) },
          )
          |> ignore
          layer.on_drag(fn(d) {
            if d.kind == Down && ov_ref.val is Some(ov) && @signals.untracked(fn() { ov.is_top() }) {
              ov.dismiss(Outside)
            }
          })
          |> ignore
        } else {
          @headless.overlay(
            p,
            fn(_) { cancel() },
            modal=false,
            dismiss_on_escape=true,
            dismiss_on_outside=true,
            inert=fn() { layer.leaving() },
            anchor=at,
            return_focus=false,
            leaves_typing=keep_field,
            auto_focus=!keep_field,
            first_takes?,
            initial_focus?=init_focus,
            before_dismiss~,
            in_node=true,
            fn(_, ov) { ov_ref.val = Some(ov) },
          )
          |> ignore
          // Keep panel as a Tab stop alongside its roving items (`@headless.overlay` sets `tab=false`).
          p.focusable(By(live), keys=0) |> ignore
        }
        // Handle Escape (with or without modifiers, matching legacy menu) via the overlay stack, and delegate all
        // other menu navigation/typeahead keys to `@headless.Menu::handle_key`.
        p.on_key(fn(k) {
          if k.code == @ui.key_escape {
            if ov_ref.val is Some(ov) && @signals.untracked(fn() { ov.is_top() }) {
              ov.dismiss(Escape)
              return true
            }
            return false
          }
          match menu_ref.val {
            Some(m) => m.handle_key(k)
            None => false
          }
        })
        |> ignore
      })
      |> ignore
    },
    leave=@motion.pop_out_ms,
  )
}

///|
/// Whether a row's own mark goes in the menu's column before its words (where the menu has one): it has a mark and
/// neither a check nor an icon of its own for that column (a check said to go at its row's end takes none of it).
fn menu_mark_leads(item : MenuItem, extra : MenuExtra, check_end? : Bool = false) -> Bool {
  extra.mark is Some(_) && (item.chosen is None || check_end) && item.icon == ""
}

///|
/// What a menu holds at a place is, by its kind: a line (0), a heading (1), a row (2).
fn menu_kind(x : MenuItem?) -> Int {
  match x {
    None => 0
    Some(item) if item.heading => 1
    Some(_) => 2
  }
}

///|
/// What a menu (not a sheet's) holds at a place is, by its kind: a line (0), a heading (1), a row: an action (2), a
/// check (3: a choice's checkbox, or any choice of a menu ticking several), a radio (4); a row turned another kind made
/// anew, said as what it is now.
fn menu_row_kind(x : MenuItem?, ticks : Bool) -> Int {
  match x {
    Some(item) if !item.heading =>
      match item.chosen {
        Some(_) if item.checkbox || ticks => 3
        Some(_) => 4
        None => 2
      }
    _ => menu_kind(x)
  }
}

///|
/// What a row of a menu reads where its place holds nothing more (its menu holding less now, the row about to go).
let menu_none : MenuItem = {
  label: "",
  icon: "",
  danger: false,
  disabled: true,
  chosen: None,
  checkbox: false,
  heading: false,
  further: false,
  select: fn() {  },
}

///|
/// Enabled destructive ink inside a floating menu: lifted 25% toward `Fg` in the dark (`#F9B0A4`) so it keeps
/// >= 4.5:1 over mid-bright translucent glass (`#4F5053` -> 4.56:1, dark app `#3C3D40` -> 6.15:1) while staying
/// unmistakably coral-red with no resting opaque pill box.
fn menu_danger_ink() -> Int64 {
  if library_theme().dark {
    @ui.tree_theme().color(Over(Danger, A(Fg, O25)))
  } else {
    @ui.tree_theme().color(Danger)
  }
}

///|
/// Group heading ink inside a floating menu: keeps a clear secondary hierarchy under `Fg` items in dark mode
/// (`Over(Muted, A(Fg, O55))`, ~6.7:1 on dark menu glass) instead of matching primary item brightness.
fn menu_heading_ink() -> Int64 {
  if library_theme().dark {
    @ui.tree_theme().color(Over(Muted, A(Fg, O55)))
  } else {
    overlay_muted_ink()
  }
}

///|
/// A row of a menu (menu_row's look) in `b`, an item of `menu` (@headless.menu's: an action, a check or a radio as
/// `kind` says, menu_row_kind): what `item()` is now; lit while it has the focus (its ground the pointer's or the
/// keyboard's where that is shown or the pointer is on it); the pointer moving onto it gives it the focus, unseen;
/// pressed, `go`. Its words, icon, check and whether it can be chosen as the item has them now. The row.
#callsite(autofill(loc))
fn menu_row_node(
  b : @view.View,
  menu : @headless.Menu,
  item : () -> MenuItem,
  kind : Int,
  lead : () -> Bool,
  gap : () -> Double,
  reach : Double,
  go : () -> Unit,
  extra : MenuExtra,
  check_end? : Bool = false,
  clip_label? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let t = theme()
  let off = fn() { item().disabled }
  let label = fn() { item().label }
  let checked = fn() { item().chosen == Some(true) }
  let act = fn(_ : @view.View) { go() }
  let look = fn(r : @view.View, _ : @headless.MenuItem) {
    r
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .min_height(Is(Some(t.rows.pick)))
    .padding(Is((text_in + reach, menu_row_over, text_in + reach, menu_row_over)))
    .gap(By(gap))
    .radius(Is(small_panel_inner(r_menu)))
    // det-ok(raw-hover-ground): roving menu active bar moves at once across items without trailing fade
    .ground(By(fn() {
      if r.focused() && (r.focus_shown() || r.pointed()) {
        if library_theme().dark {
          @ui.tree_theme().color(A(Fg, O5))
        } else {
          library_theme().p.hover
        }
      } else {
        0L
      }
    }))
    |> ignore
    // (the pointer moved onto it or over it: the focus its, unseen, as kit's menu has it (hovered and the pointer moved);
    // come under a pointer that stays still (what holds it scrolled to bring another into sight), nothing)
    r.on_pointer_moved(fn() {
      if !@signals.untracked(off) {
        r.ask_focus() |> ignore
      }
    })
    |> ignore
    // (its own mark in that column where it has no check nor icon of its own to go there: a Slack account among kinds
    // of secret by their icons; one beside a check or an icon goes after it)
    let mark_leads = fn() { menu_mark_leads(item(), extra, check_end~) && lead() }
    // (that mark, as wide as the check's column, where it goes)
    let mark_in = fn(at : @view.View, m : ChoiceMark) { choice_mark_node(at, m, menu_check_w) }
    // (its first line: its column before its words, where the menu has one (a choice's check, or its icon, else its
    // own mark), its own mark after it otherwise, its words, and its value pushed to its end)
    let first_line = fn(into : @view.View) {
      into.show(lead, fn(col) {
        col.width(Is(Some(menu_check_w))).lines_up(Is(Some(Middle))) |> ignore
        match extra.mark {
          Some(m) if menu_mark_leads(@signals.untracked(item), extra, check_end~) => mark_in(col, m)
          _ => ()
        }
        let mark = fn() {
          let it = item()
          match it.chosen {
            // (at its row's end where the menu says so: none here)
            Some(true) => if check_end { "" } else { "\u{1}check" }
            Some(false) => ""
            None => it.icon
          }
        }
        col.each(fn() { if mark() == "" { [] } else { [mark()] } }, fn(m) { m }, fn(slot, m) {
          let name = m.untracked()
          if name == "\u{1}check" {
            icon_node(slot, "check", 14.0, By(fn() { library_theme().p.text })) |> ignore
          } else {
            icon_node(slot, name, 14.0, By(fn() {
              let p = library_theme().p
              if item().danger {
                if off() { p.subtle } else { menu_danger_ink() }
              } else {
                p.muted
              }
            }))
            |> ignore
          }
        })
      })
      // (its own mark (a station's, a maker's) after that column)
      match extra.mark {
        Some(m) => into.show(fn() { !mark_leads() }, fn(at) { mark_in(at, m) })
        None => ()
      }
      into.box(fn(w) {
        if clip_label {
          w.shrink(Is(1.0)).min_width(Is(Some(0.0))).cuts(Is(true)).allow_ellipsis(Is(true)) |> ignore
        }
        w
        .words(By(fn() { item().label }), look=toast_words_look(Ui, L5, 400, false))
        .ink(By(fn() { if off() { @ui.tree_theme().color(Subtle) } else if item().danger { menu_danger_ink() } else { @ui.tree_theme().color(Fg) } }))
        |> ignore
      })
      |> ignore
      if extra.value != "" {
        into.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
        into.box(fn(w) {
          w
          .words(Is(extra.value), look=toast_words_look(Meta, L5, 400, false))
          .ink(By(overlay_muted_ink))
          |> ignore
        })
        |> ignore
      }
      // (what stands at its end beside its item (a place's ＋), pushed there)
      match extra.end {
        Some(e) => {
          into.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
          menu_end_node(into, r, e)
        }
        None => ()
      }
      // (ticked, its check at its end where the menu says so (a chat's 抄送: 左子健's), what it is shown in stretching
      // to the row's end)
      if check_end {
        into.show(fn() { item().chosen == Some(true) }, fn(at) {
          at.grow(Is(1.0)).row(Is(true)).lies_along(Is(End)).lines_up(Is(Some(Middle))) |> ignore
          icon_node(at, "check", 14.0, By(fn() { library_theme().p.text })) |> ignore
        })
      }
      // (one that asks more first: its chevron at its end, after its value where it has one)
      // (what it is shown in stretches to the row's end, as the menu is wide)
      into.show(fn() { item().further }, fn(at) {
        at.grow(Is(1.0)).row(Is(true)).lies_along(Is(End)).lines_up(Is(Some(Middle))) |> ignore
        icon_node(at, "chevron-right", 14.0, By(fn() { library_theme().p.subtle })) |> ignore
      })
    }
    if extra.note == "" {
      first_line(r)
    } else {
      // (what it is under its words, as far in as they are; what leads it by its first line: lead_by_first_line)
      r.box(fn(lines) {
        lines.grow(Is(1.0)) |> ignore
        lines.box(fn(l) {
          l.row(Is(true)).lines_up(Is(Some(Middle))).gap(By(gap)) |> ignore
          first_line(l)
        })
        |> ignore
        lines.box(fn(u) {
          u
          .padding(
            By(fn() {
              let w = (if lead() { menu_check_w + gap() } else { 0.0 }) +
                (if extra.mark is Some(_) && !mark_leads() { menu_check_w + gap() } else { 0.0 })
              (w, 0.0, 0.0, 0.0)
            }),
          )
          |> ignore
          // (its words a node of their own in it: what holds words is laid out as they are, not padded)
          u.box(fn(w) {
            w
            .words(Is(extra.note), look=toast_words_look(Meta, L5, 400, true))
            .ink(By(overlay_muted_ink))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  }
  match kind {
    3 => menu.check_item(b, label, checked, act, look, disabled=off, made_for=loc)
    4 => menu.radio_item(b, label, checked, act, look, disabled=off, made_for=loc)
    _ => menu.item(b, label, act, look, disabled=off, made_for=loc)
  }
}

///|
/// What a row of a menu has besides its item (a pick's choice's): what it is under its words (`note`), what it is at
/// now at its end (`value`), its own mark (`mark`, as wide as the column), a button of its own at its end (`end`).
pub(all) struct MenuExtra {
  note : String
  value : String
  mark : ChoiceMark?
  end : MenuEnd?
}

///|
/// A row with nothing besides its item.
let menu_no_extra : MenuExtra = { note: "", value: "", mark: None, end: None }

///|
/// A button at the end of a menu's row, beside what choosing the row does (a place's ＋ in the rail's menu, putting it
/// in the rail where the row goes to it): its icon (`icon`) and what it is read out as (`label`); `press`, what pressing
/// it does, the row not chosen.
pub(all) struct MenuEnd {
  label : String
  icon : String
  press : () -> Unit
}

///|
/// End `e` of menu row `row` in `into` (its first line): a round button 24 across in the row's capsule end
/// (menu_row_end), its icon 14, muted, in the words' ink with the hover's ground under the hand; shown while the row
/// is pointed at or its focus shown, the pointer on it, or always to a finger (which hovers over nothing), faded in and
/// out from the moment that changes (nav_fade), taking presses only while it shows (@headless.hover_reveal).
#callsite(autofill(loc))
fn menu_end_node(into : @view.View, row : @view.View, e : MenuEnd, loc~ : SourceLoc) -> Unit {
  @headless.button(made_for=loc, into, fn() { e.label }, fn(_) { (e.press)() }, fn(k, _) {
    style_node(k, fn() { menu_end_box }, in_row=true)
    let reveal = @headless.hover_reveal(row, k, always=fn() { !pointer_rests() || (row.focused() && row.focus_shown()) })
    let way = @motion.NodeWay::new(if @signals.untracked(fn() { reveal.shown() }) { 1.0 } else { 0.0 })
    k.reacts(fn() { reveal.shown() }, at_start=false, fn(on) { way.go(k, if on { 1.0 } else { 0.0 }, nav_fade) })
    hover_ground_node(k)
    k.box(fn(i) {
      i.alpha(By(fn() { way.shown(i) })) |> ignore
      icon_node(i, e.icon, menu_end_icon, By(fn() {
        let p = library_theme().p
        if lit_node(k) {
          p.text
        } else {
          p.muted
        }
      }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A menu row's end button (menu_end_node): 24 round, its icon in its middle, in the row's capsule end, concentric
/// with it (menu_row_end).
// kept across runs: a value (no field of it changes)
let menu_end_box : @ui.Style = @ui.css("w=S6 h=S6 radius=Full align=ACenter justify=JCenter").then(menu_row_end)

///|
let menu_end_icon : Double = 14.0

///|
/// A heading among a menu's items: its words (`label()`) as far in as its rows' words
/// (`past()`: past the columns before them where there are: a check's or an icon's, a mark's), small and muted, 6 over and
/// 4 under it.
#callsite(autofill(loc))
fn menu_heading_node(
  b : @view.View,
  label : () -> String,
  past : () -> Double,
  reach : Double,
  loc~ : SourceLoc,
) -> Unit {
  b.box(made_for=loc, fn(h) {
    h.padding(By(fn() { (text_in + past() + reach, 6.0, 10.0 + reach, 4.0) })) |> ignore
    h.box(fn(w) {
      // (a part of it in the accent: title_accent.mbt)
      if title_marked(@signals.untracked(label)) {
        w
        .words_runs(By(fn() { title_runs(label(), theme().p.accent_text) }))
        .words_look(Is(toast_words_look(Meta, L4_75, 400, false)))
        .ink(By(menu_heading_ink))
        |> ignore
      } else {
        w
        .words(By(label), look=toast_words_look(Meta, L4_75, 400, false))
        .ink(By(menu_heading_ink))
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// A line between parts of a menu (menu_rule): rule_line, 6 over and under it, as wide as its rows'
/// grounds.
#callsite(autofill(loc))
fn menu_rule_node(b : @view.View, reach : Double, loc~ : SourceLoc) -> Unit {
  b.box(made_for=loc, fn(r) {
    r.padding(Is((reach, 6.0, reach, 6.0))) |> ignore
    r.box(fn(l) { style_node(l, fn() { rule_line }) }) |> ignore
  })
  |> ignore
}

///|
/// The tree's Along for the library's.
fn view_along(a : @ui.Along) -> @view.Along {
  match a {
    Start => Start
    Middle => Middle
    End => End
  }
}

///|
/// Non-interactive picture of a menu's level (`snap_title`, `snap_items`, `snap_depth` deep, each row's `extra`), as
/// its rows draw it: what slides out of `menu_node_by` as it leaves, and its unseen twin as it comes in (how wide it
/// is).
#callsite(autofill(loc))
fn menu_leaving_level_node(
  parent : @view.View,
  snap_title : String,
  snap_items : Array[MenuItem?],
  snap_depth : Int,
  side : Double,
  reach : Double,
  row_h : Double,
  extra : (Int) -> MenuExtra,
  check_end : Bool,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(parent) {
  let iconed = snap_items.iter().any(fn(x) { x is Some(i) && i.chosen is None && i.icon != "" })
  let lead = iconed || (!check_end && snap_items.iter().any(fn(x) { x is Some(i) && i.chosen is Some(_) }))
  let gap = if lead && !iconed { chooser_gap } else { menu_gap }
  // (a heading's words past the column and a row's own mark where one has it after the column, as the live past's)
  let mut marked = false
  for n, x in snap_items {
    if x is Some(it) && extra(n).mark is Some(_) && !(menu_mark_leads(it, extra(n), check_end~) && lead) {
      marked = true
    }
  }
  let past = (if lead { menu_check_w + gap } else { 0.0 }) + (if marked { menu_check_w + gap } else { 0.0 })
  if snap_depth > 0 {
    let back_pad_l = dmax(0.0, r_menu - 12.0 - side)
    parent.box(fn(hdr) {
      hdr
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .gap(Is(4.0))
      .padding(Is((back_pad_l, 0.0, text_in, 4.0)))
      |> ignore
      hdr.box(fn(b) {
        b.width(Is(Some(24.0))).height(Is(Some(24.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
        icon_node(b, "chevron-left", 14.0, By(fn() { library_theme().p.text })) |> ignore
      })
      |> ignore
      hdr.box(fn(tw) {
        tw
        .words(Is(snap_title), look=toast_words_look(Ui, L5, 600, false))
        .ink(By(fn() { @ui.tree_theme().color(Fg) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  } else if snap_title != "" && !(snap_items.get(0) is Some(Some(i)) && i.heading) {
    menu_heading_node(parent, fn() { snap_title }, fn() { past }, reach)
  }
  for n, x in snap_items {
    match x {
      None => menu_rule_node(parent, reach)
      Some(item) if item.heading => menu_heading_node(parent, fn() { item.label }, fn() { past }, reach)
      Some(item) => {
        let ex = extra(n)
        let mark_leads = menu_mark_leads(item, ex, check_end~) && lead
        // (its first line as menu_row_node's: its column, its own mark, its words, its value, its end, its check
        // at its end, its chevron)
        let first_line = fn(into : @view.View) {
          if lead {
            into.box(fn(col) {
              col.width(Is(Some(menu_check_w))).lines_up(Is(Some(Middle))) |> ignore
              match ex.mark {
                Some(m) if mark_leads => choice_mark_node(col, m, menu_check_w)
                _ =>
                  if item.chosen == Some(true) && !check_end {
                    icon_node(col, "check", 14.0, By(fn() { library_theme().p.text })) |> ignore
                  } else if item.chosen is None && item.icon != "" {
                    icon_node(col, item.icon, 14.0, By(fn() {
                      let p = library_theme().p
                      if item.danger {
                        if item.disabled { p.subtle } else { menu_danger_ink() }
                      } else {
                        p.muted
                      }
                    }))
                    |> ignore
                  }
              }
            })
            |> ignore
          }
          match ex.mark {
            Some(m) if !mark_leads => choice_mark_node(into, m, menu_check_w)
            _ => ()
          }
          into.box(fn(w) {
            w
            .words(Is(item.label), look=toast_words_look(Ui, L5, 400, false))
            .ink(By(fn() { if item.disabled { @ui.tree_theme().color(Subtle) } else if item.danger { menu_danger_ink() } else { @ui.tree_theme().color(Fg) } }))
            |> ignore
          })
          |> ignore
          if ex.value != "" {
            into.box(fn(sp) { sp.grow(Is(1.0)) |> ignore }) |> ignore
            into.box(fn(w) {
              w.words(Is(ex.value), look=toast_words_look(Meta, L5, 400, false)).ink(By(overlay_muted_ink)) |> ignore
            })
            |> ignore
          }
          if ex.end is Some(_) {
            into.box(fn(sp) { sp.grow(Is(1.0)) |> ignore }) |> ignore
            into.box(fn(k) { style_node(k, fn() { menu_end_box }, in_row=true) }) |> ignore
          }
          if check_end && item.chosen == Some(true) {
            into.box(fn(at) {
              at.grow(Is(1.0)).row(Is(true)).lies_along(Is(End)).lines_up(Is(Some(Middle))) |> ignore
              icon_node(at, "check", 14.0, By(fn() { library_theme().p.text })) |> ignore
            })
            |> ignore
          }
          if item.further {
            into.box(fn(at) {
              at.grow(Is(1.0)).row(Is(true)).lies_along(Is(End)).lines_up(Is(Some(Middle))) |> ignore
              icon_node(at, "chevron-right", 14.0, By(fn() { library_theme().p.subtle })) |> ignore
            })
            |> ignore
          }
        }
        parent.box(fn(r) {
          r
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .min_height(Is(Some(row_h)))
          .padding(Is((text_in + reach, menu_row_over, text_in + reach, menu_row_over)))
          .gap(Is(gap))
          |> ignore
          if ex.note == "" {
            first_line(r)
          } else {
            r.box(fn(lines) {
              lines.grow(Is(1.0)) |> ignore
              lines.box(fn(l) {
                l.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(gap)) |> ignore
                first_line(l)
              })
              |> ignore
              lines.box(fn(u) {
                let w = (if lead { menu_check_w + gap } else { 0.0 }) +
                  (if ex.mark is Some(_) && !mark_leads { menu_check_w + gap } else { 0.0 })
                u.padding(Is((w, 0.0, 0.0, 0.0))) |> ignore
                u.box(fn(w) {
                  w.words(Is(ex.note), look=toast_words_look(Meta, L5, 400, true)).ink(By(overlay_muted_ink)) |> ignore
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
          }
        })
        |> ignore
      }
    }
  }
  })
  |> ignore
}

///|
/// What a menu goes beside at a place in the window (x, y, w, h: a point where w and h are 0), made in `layer`.
#callsite(autofill(loc))
pub fn fixed_anchor(layer : @view.View, at : (Double, Double, Double, Double), loc~ : SourceLoc) -> @view.View {
  layer.box(made_for=loc, fn(a) {
    let (x, y, w, h) = at
    a.width(Is(Some(w))).height(Is(Some(h))).offset(Is((x, y))) |> ignore
  })
}
