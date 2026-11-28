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
/// Outer shell width cap for an inline confirmation level inside a popover menu.
let menu_confirm_w : Double = 296.0

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
  sub_levels? : () -> Array[MenuLevel] = fn() { [] },
  level_back? : () -> Bool = fn() { false },
  panel_ref? : Ref[@view.View?],
  host? : @view.NodeId,
) -> Unit {
  // (no line at either end, none twice: menu_clean_items)
  let content = fn() { menu_clean_items(content()) }
  let cur_level = fn() -> (Int, String, MenuLevelKind, Int) {
    let subs = sub_levels()
    if subs.is_empty() {
      (0, title, MenuItems(content(), extras), 0)
    } else {
      let last = subs[subs.length() - 1]
      (last.n, last.title, last.kind, subs.length())
    }
  }
  let cur_items = fn() -> Array[MenuItem?] {
    match cur_level().2 {
      MenuItems(items, _) => items
      MenuConfirmLevel(_) => []
    }
  }
  // (what each row of the level that shows has besides its item: the first level's `extras`, the topmost pushed
  // one's its own)
  let cur_extras = fn() -> (Int) -> MenuExtra {
    match cur_level().2 {
      MenuItems(_, ex) => ex
      MenuConfirmLevel(_) => fn(_) { menu_no_extra }
    }
  }
  let cur_title = fn() { cur_level().1 }
  let cur_depth = fn() { cur_level().3 }
  let is_confirm = fn() { cur_level().2 is MenuConfirmLevel(_) }
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
      let menu_ref : Ref[@headless.Menu?] = Ref(None)
      let body_ref : Ref[@view.View?] = Ref(None)
      // (what the level's rows make, scrolled in `active`: as tall as they are, where `active` is no taller than `body`
      // lets it be on its way, so a level taller than the one before would never be gone to)
      let rows_ref : Ref[@view.View?] = Ref(None)
      let reach = menu_row_reach(th.rows.pick)
      let side_pad = panel_pad - reach
      // (a level's head a row where its rows have a column before their words (menu_back_row_node): first as a row is)
      let pad_of = fn(depth : Int, kind : MenuLevelKind, lv_title : String) -> (Double, Double, Double, Double) {
        let top_pad = match kind {
          MenuConfirmLevel(_) => @ui.capsule_in(r_menu, menu_confirm_back_h)
          MenuItems(items, ex) => {
            let head_row = depth > 0 && menu_level_past(items, ex, check_end) > 0.0
            if depth > 0 && !head_row {
              r_menu - 12.0
            } else if head_row || (depth == 0 && items.length() > 0 && (items[0] is Some(i) && !i.heading) && lv_title == "") {
              panel_pad - reach
            } else {
              panel_pad
            }
          }
        }
        let bot_pad = match kind {
          MenuConfirmLevel(_) => 0.0
          MenuItems(items, _) =>
            if items.length() > 0 && (items[items.length() - 1] is Some(i) && !i.heading) {
              panel_pad - reach
            } else {
              panel_pad
            }
        }
        (side_pad, top_pad, side_pad, bot_pad)
      }
      let pad_v_of = fn(depth : Int, kind : MenuLevelKind, lv_title : String) -> Double {
        let (_, tp, _, bp) = pad_of(depth, kind, lv_title)
        tp + bp
      }
      let cur_pad_v = fn() -> Double {
        let (_, lv_t, lv_kind, lv_d) = cur_level()
        pad_v_of(lv_d, lv_kind, lv_t)
      }
      let confirm_outer_w = fn() -> Double {
        let room_w = dmax(0.0, over_room(layer).0 - 16.0)
        let max_room_w = dmax(min_w, if max_w > 0.0 { dmin(max_w, room_w) } else { room_w })
        let scaled_w = dmin(submenu_max_w, menu_confirm_w * dmax(1.0, layer.words_scale()))
        dmin(scaled_w, max_room_w)
      }
      // (in-container submenu horizontal slide state: closed-form NodeWay, zero overhead when depth == 0)
      let slide_way = @motion.NodeWay::new(1.0)
      let slide_dir : Ref[Double] = Ref(1.0)
      let slide_w : Ref[Double] = Ref(min_w)
      let slide_h_from : Ref[Double] = Ref(0.0)
      let slide_p_h_from : Ref[Double] = Ref(0.0)
      let slide_x_from : Ref[Double] = Ref(0.0)
      let slide_y_from : Ref[Double] = Ref(0.0)
      let slide_gen : Ref[Int] = Ref(0)
      let confirm_scroll_ref : Ref[@view.Scroll?] = Ref(None)
      let confirm_view_ref : Ref[@view.View?] = Ref(None)
      let slide_confirm_scroll_y : Ref[Double] = Ref(0.0)
      let slide_confirm_view_h : Ref[Double] = Ref(0.0)
      // (the level going in, laid out unseen as wide as its rows make it while the levels slide (`lv_box`'s twin): how
      // wide the panel goes to, from as wide as it stood, rather than snapping to it as the level changes)
      let ghost_ref : Ref[@view.View?] = Ref(None)
      let leaving_snap : @signals.Signal[(Int, String, MenuLevelKind, Int)?] = @signals.signal_ref(None)
      let prev_level : Ref[(Int, String, MenuLevelKind, Int)] = Ref(@signals.untracked(cur_level))
      layer.reacts(fn() { cur_level().0 }, at_start=false, fn(new_id) {
        said.val = false
        let next_lv = @signals.untracked(cur_level)
        let prev_lv = prev_level.val
        if prev_lv.0 != new_id {
          slide_dir.val = if next_lv.3 >= prev_lv.3 { 1.0 } else { -1.0 }
          let (x_now, y_now, w_now, h_now) = match panel.val {
            Some(pv) => pv.placed_window_now()
            None => (0.0, 0.0, min_w, 0.0)
          }
          slide_w.val = dmax(w_now, min_w)
          slide_p_h_from.val = h_now
          slide_x_from.val = x_now
          slide_y_from.val = y_now
          let old_bh = match body_ref.val {
            Some(bv) => bv.placed_window_now().3
            None => 0.0
          }
          let old_pad_v = pad_v_of(prev_lv.3, prev_lv.2, prev_lv.1)
          let new_pad_v = pad_v_of(next_lv.3, next_lv.2, next_lv.1)
          slide_h_from.val = dmax(0.0, old_bh + old_pad_v - new_pad_v)
          let dur = @ui.move_ms(slide_w.val)
          slide_confirm_scroll_y.val = match confirm_scroll_ref.val {
            Some(sc) => sc.drawn(layer.tree)
            None => 0.0
          }
          slide_confirm_view_h.val = match confirm_view_ref.val {
            Some(mv) => mv.placed_window_now().3
            None => 0.0
          }
          leaving_snap.set(Some(prev_lv))
          slide_way.go_from(layer, 0.0, 1.0, @motion.moved(points=slide_w.val))
          rest_end.val = dmax(rest_end.val, layer.cause_at() + dur)
          slide_gen.val += 1
          let gen = slide_gen.val
          layer.at_moment(layer.cause_at() + dur, fn() {
            if slide_gen.val == gen {
              leaving_snap.set(None)
            }
          })
          |> ignore
          // (focus & typeahead handoff when entering/leaving an inline confirm level; preserve field focus when keep_field)
          match (prev_lv.2, next_lv.2) {
            (_, MenuConfirmLevel(_)) =>
              if !keep_field {
                match panel.val {
                  Some(pv) => pv.ask_focus() |> ignore
                  None => ()
                }
              }
            (MenuConfirmLevel(_), MenuItems(_, _)) => {
              match menu_ref.val {
                Some(m) => m.reset_typeahead()
                None => ()
              }
              if !keep_field {
                match panel.val {
                  Some(pv) => pv.ask_focus() |> ignore
                  None => ()
                }
              }
            }
            _ => ()
          }
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
      let iconed = fn() {
        let items = cur_items()
        for i = 0; i < items.length(); i = i + 1 {
          if items[i] is Some(it) && it.chosen is None && it.icon != "" {
            return true
          }
        }
        false
      }
      // (none for a check said to go at its row's end)
      let lead = fn() {
        if iconed() {
          return true
        }
        if check_end {
          return false
        }
        let items = cur_items()
        for i = 0; i < items.length(); i = i + 1 {
          if items[i] is Some(it) && it.chosen is Some(_) {
            return true
          }
        }
        false
      }
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
      let (m_host, m_offset) = match host {
        Some(_) => (host, offset)
        None => floating_anchor_beside(at, side, offset)
      }
      anchored_popover_bridge(layer, at, look, side~, along~, offset=m_offset)
      layer.box(fn(p) {
        panel.val = Some(p)
        match panel_ref {
          Some(r) => {
            r.val = Some(p)
            p.owns(fn() { r.val = None }) |> ignore
          }
          None => ()
        }
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
            anchored_popover_shell_by(
              p,
              at.id(),
              look,
              side~,
              along~,
              offset=m_offset,
              holds_side=false,
              lock_side=fn() { cur_depth() > 0 || leaving_snap.get() is Some(_) },
              host?=m_host,
            )
            .min_width(Is(Some(min_w)))
            .width(
              By(fn() {
                let sp = slide_way.shown(p)
                if sp >= 0.999 || leaving_snap.get() is None {
                  None
                } else {
                  let to = match cur_level().2 {
                    MenuConfirmLevel(_) => confirm_outer_w()
                    MenuItems(_, _) =>
                      match ghost_ref.val {
                        Some(g) => g.placed_window_now().2
                        _ => 0.0
                      }
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
            // Smooth out viewport edge-clamp kinks during level slide inside `Tree::besides_placed`, reusing the
            // exact same `rect`, `clear`, `away`, `offset`, and `along_offset` (zero frame-0 jump on pill_morph/clear/away).
            .beside_slide(fn() {
              if leaving_snap.untracked() is None || slide_p_h_from.val <= 0.0 {
                return None
              }
              let sp = slide_way.shown(p)
              if sp >= 0.999 {
                return None
              }
              let (vw, vh) = over_room(layer)
              let room_w = dmax(0.0, vw - 16.0)
              let w_raw = match cur_level().2 {
                MenuConfirmLevel(_) => confirm_outer_w()
                MenuItems(_, _) =>
                  match ghost_ref.val {
                    Some(g) => g.placed_window_now().2
                    None => 0.0
                  }
              }
              let h_raw = match ghost_ref.val {
                Some(g) => g.placed_window_now().3
                None => 0.0
              }
              if w_raw <= 0.0 || h_raw <= 0.0 {
                return Some((slide_x_from.val, slide_y_from.val, 0.0, 0.0, sp))
              }
              let w_to = dmin(dmax(min_w, w_raw), if max_w > 0.0 { dmin(max_w, room_w) } else { room_w })
              let pad_v = cur_pad_v()
              let cap_b = dmax(0.0, vh - 16.0 - pad_v)
              let p_h_to = dmin(h_raw, cap_b) + pad_v
              Some((slide_x_from.val, slide_y_from.val, w_to, p_h_to, sp))
            })
            // (small_panel: its padding, its rows reaching past it to stand concentric with its corners;
            // submenu and confirm levels share `pad_of` with `pad_v_of` so height interpolation has zero snap)
            .padding(
              By(fn() {
                let (_, lv_t, lv_kind, lv_d) = cur_level()
                pad_of(lv_d, lv_kind, lv_t)
              }),
            )
            |> ignore
            p.box(fn(body) {
              body_ref.val = Some(body)
              // (all it holds as far in as its look says, past the panel's own ground, edge and shadow: its rows, their
              // grounds, checks, marks and words, its headings and lines, the same, Look's `words` as a surface's are)
              let side = side_pad
              body
              .margin(Is((-side, 0.0, -side, 0.0)))
              .shrink(Is(1.0))
              .min_height(Is(Some(0.0)))
              .clips(Is(true))
              .height(
                By(fn() {
                  let sp = slide_way.shown(body)
                  if sp >= 0.999 || slide_h_from.val <= 0.0 {
                    None
                  } else {
                    let h_to = match cur_level().2 {
                      MenuConfirmLevel(_) =>
                        match ghost_ref.val {
                          Some(g) => g.placed_window_now().3
                          None => 0.0
                        }
                      MenuItems(_, _) =>
                        match rows_ref.val {
                          Some(av) => av.placed_window_now().3
                          None => 0.0
                        }
                    }
                    let cap = dmax(0.0, over_room(layer).1 - 16.0 - cur_pad_v())
                    if h_to <= 0.0 {
                      Some(dmin(cap, slide_h_from.val))
                    } else {
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
                .max_height(By(fn() { Some(dmax(0.0, over_room(layer).1 - 16.0 - cur_pad_v())) }))
                .drawn_off(
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
                active.pick(fn() { if is_confirm() { 1 } else { 0 } }, at_once=true, fn(slot, kind_idx) {
                  slot.shrink(Is(0.0)) |> ignore
                  if kind_idx == 1 {
                    slot.each(
                      fn() {
                        match cur_level() {
                          (id, _, MenuConfirmLevel(_), _) => [id]
                          _ => []
                        }
                      },
                      fn(k) { k },
                      at_once=true,
                      fn(cv, _) {
                        cv.shrink(Is(0.0)) |> ignore
                        match @signals.untracked(cur_level) {
                          (_, lv_title, MenuConfirmLevel(c), _) =>
                            menu_confirm_level_node(
                              cv,
                              lv_title,
                              c,
                              true,
                              confirm_outer_w,
                              fn() { dmax(0.0, over_room(layer).1 - 16.0 - cur_pad_v()) },
                              level_back,
                              cancel,
                              scroll_ref=confirm_scroll_ref,
                              view_ref=confirm_view_ref,
                            )
                          _ => ()
                        }
                      },
                    )
                  } else {
                    slot.scrolls(@view.Scroll::new(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(b) {
                      rows_ref.val = Some(b)
                      b.padding(Is((side, 0.0, side, 0.0))) |> ignore
                      // (submenu level header: concentric 24x24 `<` back button + submenu title; at_once=true because level switch is driven by horizontal slide_way)
                      // (where the level's rows have a column before their words, its head a row as they are: its `<` in
                      // that column, its title where their words begin (menu_back_row_node))
                      b.show(fn() { cur_depth() > 0 && !is_confirm() && past() > 0.0 }, at_once=true, fn(hdr) {
                        menu_back_row_node(hdr, cur_title, Some(fn() { level_back() |> ignore }), reach, past)
                      })
                      b.show(fn() { cur_depth() > 0 && !is_confirm() && past() <= 0.0 }, at_once=true, fn(hdr) {
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
                          match cur_level() {
                            (lv_id, _, MenuItems(items, _), _) =>
                              items.mapi(fn(i, x) { MenuRowKey::{ lv_id, idx: i, kind: menu_row_kind(x, ticks) } })
                            _ => []
                          }
                        },
                        fn(k) { k },
                        at_once=true,
                        fn(cell, k) {
                          let { idx: i, kind, .. } = k.untracked()
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
                  }
                })
              })
              |> ignore
              // (the level going in, unseen, as wide as it makes itself: what the panel's width and confirm height go to as they slide)
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
                  g.shrink(Is(0.0)) |> ignore
                  let (_, g_title, g_kind, g_depth) = @signals.untracked(cur_level)
                  match g_kind {
                    MenuItems(g_items, g_extras) => {
                      g.padding(Is((side, 0.0, side, 0.0))) |> ignore
                      menu_leaving_level_node(g, g_title, g_items, g_depth, side, reach, th.rows.pick, g_extras, check_end)
                    }
                    MenuConfirmLevel(g_c) =>
                      menu_confirm_level_node(
                        g,
                        g_title,
                        g_c,
                        false,
                        confirm_outer_w,
                        fn() { 0.0 },
                        fn() { false },
                        fn() {  },
                      )
                  }
                })
              })
              // (leaving level snapshot sliding out horizontally while the new level slides in; unmounted on settle; made
              // again for each level that leaves, one going in or back mid-slide its own, as wide as the panel stood then)
              body.show(fn() { leaving_snap.get() is Some(_) }, at_once=true, fn(lv_over) {
                lv_over.over(Is(true)).points(Is(false)).hides(Is(true)) |> ignore
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
                    .drawn_off(
                      By(fn() {
                        let sp = slide_way.shown(lv_box)
                        (-slide_dir.val * sp * w, 0.0)
                      }),
                    )
                    .alpha(By(fn() { 1.0 - slide_way.shown(lv_box) * 0.35 }))
                    |> ignore
                    match @signals.untracked(fn() { leaving_snap.get() }) {
                      Some((_, snap_title, MenuItems(snap_items, snap_extras), snap_depth)) => {
                        lv_box.padding(Is((side, 0.0, side, 0.0))) |> ignore
                        menu_leaving_level_node(
                          lv_box,
                          snap_title,
                          snap_items,
                          snap_depth,
                          side,
                          reach,
                          th.rows.pick,
                          snap_extras,
                          check_end,
                        )
                      }
                      Some((_, snap_title, MenuConfirmLevel(snap_c), _)) =>
                        menu_confirm_level_node(
                          lv_box,
                          snap_title,
                          snap_c,
                          false,
                          confirm_outer_w,
                          fn() { 0.0 },
                          fn() { false },
                          fn() {  },
                          snap_scroll_y=slide_confirm_scroll_y.val,
                          snap_view_h=slide_confirm_view_h.val,
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
        // (switch container a11y semantics between `Menu` and `Dialog` when an inline confirmation level is active)
        p.says(
          By(fn() {
            let (_, lv_title, lv_kind, _) = cur_level()
            match lv_kind {
              MenuConfirmLevel(c) => {
                let desc = confirm_description(c.facts, c.words, c.warning)
                Some(@view.said(Dialog, label=title_plain(lv_title), description=desc))
              }
              MenuItems(_, _) => Some(@view.said(@view.Role::Menu, label=title_plain(lv_title)))
            }
          }),
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
        // Exclude the outer panel container from Tab stops while on an inline confirmation level so Tab/Shift+Tab
        // cycles strictly among `[< Back, Cancel, Action]`, while still allowing programmatic `pv.ask_focus()`.
        p.tab_stop(By(fn() { !is_confirm() })) |> ignore
        // Handle Escape (with or without modifiers, matching legacy menu) via the overlay stack, and delegate all
        // other menu navigation/typeahead keys to `@headless.Menu::handle_key` only when on a menu items level.
        p.on_key(fn(k) {
          if k.code == @ui.key_escape {
            if ov_ref.val is Some(ov) && @signals.untracked(fn() { ov.is_top() }) {
              ov.dismiss(Escape)
              return true
            }
            return false
          }
          if @signals.untracked(is_confirm) {
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
/// Warning ink inside an inline menu confirmation level: darkened slightly in light mode and lifted in dark mode so
/// contrast stays >= 4.5:1 over light glass, dark glass, and solid surfaces (`MBUI_GLASS=solid`).
fn menu_confirm_warning_ink() -> Int64 {
  if library_theme().dark {
    @ui.tree_theme().color(Over(Danger, A(Fg, O25)))
  } else {
    @ui.tree_theme().color(Over(Danger, A(Fg, O20)))
  }
}

///|
/// Capsule height of the inline confirmation level's `< Back` button: 28pt accommodates `Meta` text up to 1.5x
/// font scale while staying a true concentric capsule (`capsule_in(r_menu, 28.0) = 10.0`, `radius = 14.0`).
let menu_confirm_back_h : Double = 28.0

///|
/// Shared layout for an inline confirmation level inside `menu_node_by`, used identically by the live level
/// (`interactive=true`), the unseen width/height measurement ghost (`interactive=false`), and the sliding-out
/// snapshot (`interactive=false`).
#callsite(autofill(loc))
fn menu_confirm_level_node(
  parent : @view.View,
  lv_title : String,
  c : MenuConfirm,
  interactive : Bool,
  width : () -> Double,
  max_h : () -> Double,
  level_back : () -> Bool,
  cancel : () -> Unit,
  scroll_ref? : Ref[@view.Scroll?],
  view_ref? : Ref[@view.View?],
  snap_scroll_y? : Double = 0.0,
  snap_view_h? : Double = 0.0,
  loc~ : SourceLoc,
) -> Unit {
  let back_pad_l = @ui.capsule_in(r_menu, menu_confirm_back_h)
  parent.box(made_for=loc, fn(root) {
    root.width(By(fn() { Some(width()) })).shrink(Is(0.0)) |> ignore
    if interactive {
      root.max_height(By(fn() {
        let mh = max_h()
        if mh > 0.0 { Some(mh) } else { None }
      }))
      |> ignore
    }
    // Scrollable nav + title + body: keeps the footer `[Cancel, action]` permanently visible even in very short
    // viewports with long wrapped titles and 1.3x text scaling, while title/body/warning sit symmetrically at `text_in`.
    let scroll_content = fn(sc : @view.View) {
      // Top independent `< Back` navigation row, concentric with top-left `r_menu`
      sc.box(fn(nav) {
        nav
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .padding(Is((back_pad_l, 0.0, text_in, 6.0)))
        .shrink(Is(0.0))
        |> ignore
        let nav_inner = fn(btn : @view.View) {
          btn
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .gap(Is(4.0))
          .min_height(Is(Some(menu_confirm_back_h)))
          .radius(Is(menu_confirm_back_h / 2.0))
          .padding(Is((4.0, 2.0, 10.0, 2.0)))
          |> ignore
          if interactive {
            hover_ground_node(btn)
          }
          icon_node(btn, "chevron-left", 14.0, By(overlay_muted_ink)) |> ignore
          btn.box(fn(w) {
            w
            .words(By(fn() { t("common.back") }), look=toast_words_look(Meta, L5, 500, false))
            .ink(By(overlay_muted_ink))
            |> ignore
          })
          |> ignore
        }
        if interactive {
          action_box_node(nav, fn() { t("common.back") }, fn(_) { level_back() |> ignore }, nav_inner) |> ignore
        } else {
          nav.box(nav_inner) |> ignore
        }
      })
      |> ignore
      let confirm_words_look = fn(size : @ui.TextSize, line : @ui.Leading, weight : Int) -> @view.WordsLook {
        { ..toast_words_look(size, line, weight, true), balance: true }
      }
      // Title: symmetric `text_in` (16pt) full-width balanced wrappable heading
      sc.box(fn(th_box) {
        th_box.padding(Is((text_in, 0.0, text_in, 0.0))).shrink(Is(0.0)) |> ignore
        th_box.box(fn(tw) {
          tw
          .words(Is(lv_title), look=confirm_words_look(Ui, L5, 600))
          .ink(By(fn() { @ui.tree_theme().color(Fg) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Verification facts card (concentric `row_corner` at `panel_pad` from menu edges, text aligned with `text_in`)
      if c.facts.iter().any(fn(kv) { kv.1 != "" }) {
        sc.box(fn(facts_wrap) {
          facts_wrap.padding(Is((panel_pad, @ui.Space::px(S2), panel_pad, 0.0))) |> ignore
          confirm_facts_card_node(facts_wrap, c.facts, 0.0, row_corner, fn() { 1.0 }, compact=true)
        })
        |> ignore
      }
      // Body + optional warning: symmetric `text_in` (16pt) full-width, 8pt below title/facts, 6pt between body and warning
      if c.words != "" || c.warning != "" {
        sc.box(fn(body_box) {
          body_box.padding(Is((text_in, @ui.Space::px(S2), text_in, 0.0))).gap(Is(6.0)) |> ignore
          if c.words != "" {
            body_box.box(fn(w) {
              w
              .words(Is(c.words), look=confirm_words_look(Meta, L6, 400))
              .ink(By(overlay_muted_ink))
              |> ignore
            })
            |> ignore
          }
          if c.warning != "" {
            body_box.box(fn(w) {
              w
              .words(Is(c.warning), look=confirm_words_look(Meta, L6, 400))
              .ink(By(menu_confirm_warning_ink))
              |> ignore
            })
            |> ignore
          }
        })
        |> ignore
      }
    }
    root.box(fn(mid) {
      if interactive {
        mid.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        let sc = @view.Scroll::new()
        match scroll_ref {
          Some(r) => {
            r.val = Some(sc)
            mid.owns(fn() { r.val = None }) |> ignore
          }
          None => ()
        }
        match view_ref {
          Some(r) => {
            r.val = Some(mid)
            mid.owns(fn() { r.val = None }) |> ignore
          }
          None => ()
        }
        mid.scrolls(sc, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), scroll_content) |> ignore
      } else if snap_view_h > 0.0 {
        mid.shrink(Is(1.0)).min_height(Is(Some(0.0))).max_height(Is(Some(snap_view_h))).clips(Is(true)) |> ignore
        mid.box(fn(inner) {
          if snap_scroll_y != 0.0 {
            inner.offset(Is((0.0, -snap_scroll_y))) |> ignore
          }
          scroll_content(inner)
        })
        |> ignore
      } else {
        mid.shrink(Is(0.0)) |> ignore
        mid.box(scroll_content) |> ignore
      }
    })
    |> ignore
    // Footer: [Cancel (Ghost), action (DangerSolid / Primary)], 14pt breathing room above, concentric bottom/right
    root.box(fn(f) {
      let at = @ui.capsule_in(r_menu, button_height())
      f
      .row(Is(true))
      .lies_along(Is(End))
      .lines_up(Is(Some(Middle)))
      .gap(Is(@ui.Space::px(S2)))
      .wraps(By(fn() { Some(ask_foot_lines()) }))
      .padding(Is((at, 14.0, at, at)))
      .shrink(Is(0.0))
      |> ignore
      if interactive {
        button_node(f, fn() { t("common.cancel") }, cancel, tone=Ghost) |> ignore
        button_node(
          f,
          fn() { c.action },
          c.run,
          tone=if c.danger { DangerSolid } else { Primary },
          default_on?=if c.danger { None } else { Some(fn() { true }) },
        )
        |> ignore
      } else {
        let h = button_height()
        let static_btn = fn(label : String, solid : Bool, danger : Bool) {
          f.box(fn(b) {
            b
            .row(Is(true))
            .min_height(Is(Some(h)))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .radius(Is(h / 2.0))
            .padding(Is((button_padx, 2.0, button_padx, 2.0)))
            .ground(By(fn() {
              if !solid {
                0L
              } else if danger {
                theme().p.red
              } else {
                theme().p.primary
              }
            }))
            |> ignore
            b.box(fn(w) {
              let th = @signals.untracked(theme)
              w
              .words(
                Is(label),
                look={
                  size: th.t.ui,
                  weight: if th.touch { 600 } else { 500 },
                  line: th.t.ui_line,
                  wrap: false,
                  tracking: @view.letters_own,
                  balance: false,
                  max_lines: 0,
                },
              )
              .ink(By(fn() {
                let th = theme()
                if !solid {
                  th.p.text
                } else if danger {
                  if th.dark { th.p.bg } else { 0xFFFFFFFFL }
                } else {
                  th.p.bg
                }
              }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        }
        static_btn(t("common.cancel"), false, false)
        static_btn(c.action, true, c.danger)
      }
    })
    |> ignore
  })
  |> ignore
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
    @view.Along::Start => @view.Along::Start
    @view.Along::Middle => @view.Along::Middle
    @view.Along::End => @view.Along::End
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
  let mut iconed = false
  for i = 0; i < snap_items.length(); i = i + 1 {
    if snap_items[i] is Some(it) && it.chosen is None && it.icon != "" {
      iconed = true
      break
    }
  }
  let mut lead = iconed
  if !lead && !check_end {
    for i = 0; i < snap_items.length(); i = i + 1 {
      if snap_items[i] is Some(it) && it.chosen is Some(_) {
        lead = true
        break
      }
    }
  }
  let gap = if lead && !iconed { chooser_gap } else { menu_gap }
  let past = menu_level_past(snap_items, extra, check_end)
  if snap_depth > 0 && past > 0.0 {
    parent.box(fn(hdr) { menu_back_row_node(hdr, fn() { snap_title }, None, reach, fn() { past }) }) |> ignore
  } else if snap_depth > 0 {
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

///|
/// A level's head in `parent` where its rows have a column before their words (`past` wide: a check's, an icon's, a
/// mark's): a row as theirs are, as tall, as far in and as round (concentric with the menu's corner as they are), its
/// `<` in that column and `title` where their words begin; pressed, `back` (none: a picture of it, a level sliding
/// out). The round `<` concentric with the corner stands where they have none.
#callsite(autofill(loc))
fn menu_back_row_node(
  parent : @view.View,
  title : () -> String,
  back : (() -> Unit)?,
  reach : Double,
  past : () -> Double,
  loc~ : SourceLoc,
) -> Unit {
  let look = fn(r : @view.View) {
    r
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .min_height(Is(Some(theme().rows.pick)))
    .padding(Is((text_in + reach, menu_row_over, text_in + reach, menu_row_over)))
    .gap(By(fn() { dmax(0.0, past() - menu_check_w) }))
    .radius(Is(small_panel_inner(r_menu)))
    |> ignore
    r.box(fn(col) {
      col.width(Is(Some(menu_check_w))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)).shrink(Is(0.0)) |> ignore
      icon_node(col, "chevron-left", menu_check_w, By(fn() { library_theme().p.text })) |> ignore
    })
    |> ignore
    r.box(fn(tw) {
      tw
      .words(By(title), look=toast_words_look(Ui, L5, 600, false))
      .ink(By(fn() { @ui.tree_theme().color(Fg) }))
      |> ignore
    })
    |> ignore
  }
  match back {
    Some(go) =>
      action_box_node(parent, fn() { t("common.back") }, fn(_) { go() }, fn(r) {
        look(r)
        hover_ground_node(r)
      }, loc~)
      |> ignore
    None => parent.box(made_for=loc, look) |> ignore
  }
}

///|
/// How far a level's rows' words are past their start (`items`, what each has besides: `extra`): a check's or an
/// icon's column and a row's own mark where one has it after the column, each with the room after it (as the live
/// menu's `past`, its headings' words as far in).
fn menu_level_past(items : Array[MenuItem?], extra : (Int) -> MenuExtra, check_end : Bool) -> Double {
  let mut iconed = false
  for i = 0; i < items.length(); i = i + 1 {
    if items[i] is Some(it) && it.chosen is None && it.icon != "" {
      iconed = true
      break
    }
  }
  let mut lead = iconed
  if !lead && !check_end {
    for i = 0; i < items.length(); i = i + 1 {
      if items[i] is Some(it) && it.chosen is Some(_) {
        lead = true
        break
      }
    }
  }
  let gap = if lead && !iconed { chooser_gap } else { menu_gap }
  let mut marked = false
  for n, x in items {
    if x is Some(it) && extra(n).mark is Some(_) && !(menu_mark_leads(it, extra(n), check_end~) && lead) {
      marked = true
    }
  }
  (if lead { menu_check_w + gap } else { 0.0 }) + (if marked { menu_check_w + gap } else { 0.0 })
}

///|
/// What a menu row is kept by: its level, its place in it and its kind (menu_row_kind).
#derive(Eq, Hash)
priv struct MenuRowKey {
  lv_id : Int
  idx : Int
  kind : Int
}
