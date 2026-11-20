// Ergonomic desktop tab strip node (Chrome / Safari / VS Code style): uniform slot widths with deferred tab resize on
// repeated × clicks, smart × visibility (unmounted rather than alpha=0 click-through), horizontal scroll with vertical
// wheel forwarding and dynamic edge fades, overflow switcher trigger, right-click context menu hook, and drag-to-reorder.

///|
let tab_strip_max_w : Double = 168.0

///|
let tab_strip_min_w : Double = 84.0

///|
let tab_strip_narrow_x_w : Double = 100.0

///|
let tab_strip_gap : Double = 2.0

///|
let tab_strip_overflow_w : Double = 28.0

///|
let tab_strip_close_side : Double = 20.0

///|
let tab_strip_close_icon : Double = 12.0

///|
let tab_strip_mark_side : Double = 14.0

///|
let tab_strip_drag_slop : Double = 6.0

///|
let tab_strip_close_in : Double = @ui.capsule_in(side_tab_side / 2.0, tab_strip_close_side, room=side_tab_side / 2.0)

///|
let tab_strip_mark_in : Double = @ui.capsule_in(side_tab_side / 2.0, tab_strip_mark_side, room=side_tab_side / 2.0) -
  tab_strip_close_in

///|
// kept across runs: a value (no field of it changes)
let tab_strip_capsule : @ui.Style = @ui.style(
  row=true,
  h=side_tab_h,
  min_w=S0,
  px=room_of(tab_strip_close_in),
  gap=S1_5,
  align=ACenter,
  radius=Full,
)

///|
// kept across runs: a value (no field of it changes)
let tab_strip_capsule_lit : @ui.Style = tab_strip_capsule.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let tab_strip_body_style : @ui.Style = @ui.style(
  row=true,
  h=Full,
  min_w=S0,
  pl=room_of(tab_strip_mark_in),
  gap=S1_5,
  align=ACenter,
)

///|
// kept across runs: a value (no field of it changes)
let tab_strip_body_no_x : @ui.Style = tab_strip_body_style.then(@ui.style(pr=room_of(tab_strip_mark_in)))

///|
/// Natural uniform slot width for `n` tabs inside `strip_w`.
fn tab_strip_natural_w(strip_w : Double, n : Int) -> Double {
  if n <= 0 || strip_w <= 0.0 {
    return tab_strip_max_w
  }
  let w = (strip_w - (n - 1).to_double() * tab_strip_gap) / n.to_double()
  dmax(tab_strip_min_w, dmin(tab_strip_max_w, w))
}

///|
/// Configuration and domain callbacks for `tab_strip_node`.
pub(all) struct TabStripSpec {
  group_label : () -> String
  more_label : () -> String
  tabs : () -> Array[String]
  front : () -> String
  names : (String) -> (String, String)
  mark : (@view.View, String, () -> Bool) -> Unit
  on_select : (String) -> Unit
  on_close : (String) -> Unit
  on_move : (String, Int) -> Unit
  on_menu : (String, Double, Double) -> Unit
  on_overflow : ((Double, Double, Double, Double)) -> Unit
  tips : TipLayer
  strip_h : Double
  panel_w : () -> Double?
  words_front : @ui.TextStyle
  words_lit : @ui.TextStyle
  words_rest : @ui.TextStyle
}

///|
/// Ergonomic horizontal tab strip in `parent` with uniform slot widths (`84–168pt`), deferred tab resize when closing
/// non-last tabs with a mouse, smart `×` mounting (never `alpha=0`), horizontal scrolling with vertical wheel support
/// and edge fades, overflow switcher trigger, right-click context menu hook, and drag-to-reorder.
#callsite(autofill(loc))
pub fn tab_strip_node(parent : @view.View, spec : TabStripSpec, loc~ : SourceLoc) -> Unit {
  let front_key = @signals.signal(@signals.untracked(spec.front))
  let tabs_sig = @signals.signal(@signals.untracked(spec.tabs), same=fn(a, b) { a == b })
  let bar_w = @signals.signal(0.0, same=fn(a, b) { (a - b).abs() <= 0.5 })
  let locked_w : @signals.Signal[Double?] = @signals.signal(None, same=fn(a, b) { a == b })
  let width_way = @motion.NodeWay::new(tab_strip_max_w)

  // Drag-to-reorder state
  let drag_tab : @signals.Signal[String?] = @signals.signal(None, same=fn(a, b) { a == b })
  let drag_dx = @signals.signal(0.0, same=fn(a, b) { a == b })
  let drag_from = @signals.signal(-1)
  let drag_to = @signals.signal(-1)

  let scroll = @view.Scroll::across()
  let prev_n = Ref(tabs_sig.untracked().length())

  let outer = parent.box(made_for=loc, fn(box) {
    let prev_panel_w = Ref(@signals.untracked(fn() { (box.window().0, (spec.panel_w)()) }))
    box
    .grow(Is(1.0))
    .shrink(Is(1.0))
    .min_width(Is(Some(0.0)))
    .height(Is(Some(spec.strip_h)))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    |> ignore
    let front_now = fn() { front_key.get() }

    let total_w = fn() { bar_w.get() }
    let needs_overflow = fn() {
      let n = tabs_sig.get().length()
      if n <= 1 {
        return false
      }
      let w = total_w()
      w > 0.0 && n.to_double() * tab_strip_min_w + (n - 1).to_double() * tab_strip_gap > w + 0.5
    }
    let strip_w = fn() {
      let w = total_w()
      if needs_overflow() {
        dmax(0.0, w - tab_strip_overflow_w - tab_strip_gap)
      } else {
        w
      }
    }
    let slot_w_rest = fn() -> Double {
      match locked_w.get() {
        Some(lw) => lw
        None => {
          let n = tabs_sig.get().length()
          if n <= 1 {
            tab_strip_max_w
          } else {
            tab_strip_natural_w(strip_w(), n)
          }
        }
      }
    }
    let slot_w_at = fn(v : @view.View) -> Double {
      match locked_w.get() {
        Some(lw) => lw
        None => {
          let n = tabs_sig.get().length()
          let nat = if n <= 1 { tab_strip_max_w } else { tab_strip_natural_w(strip_w(), n) }
          if width_way.goes(v) { width_way.shown(v) } else { nat }
        }
      }
    }
    let unlock_now = fn() {
      if locked_w.untracked() is Some(_) {
        locked_w.set(None)
      }
      let nat = @signals.untracked(fn() {
        let n = tabs_sig.untracked().length()
        if n <= 1 { tab_strip_max_w } else { tab_strip_natural_w(strip_w(), n) }
      })
      width_way.put(nat)
    }
    let close_tab = fn(key : String) {
      let cur = tabs_sig.untracked()
      let idx = cur.search(key).unwrap_or(-1)
      let n = cur.length()
      if !more_held() && idx >= 0 && idx < n - 1 && n > 1 {
        if locked_w.untracked() is None {
          let cur_w = @signals.untracked(fn() { tab_strip_natural_w(strip_w(), n) })
          locked_w.set(Some(cur_w))
        }
      }
      (spec.on_close)(key)
    }

    box.padding(By(fn() {
      if needs_overflow() {
        (0.0, 0.0, tab_strip_overflow_w + tab_strip_gap, 0.0)
      } else {
        (0.0, 0.0, 0.0, 0.0)
      }
    }))
    |> ignore

    // Unlock immediately on actual window/panel resize (not `total_w`, which fluctuates when tab-specific toolbar
    // buttons appear/disappear between active tabs) or tab count increase/empty.
    box.reacts(
      fn() { (box.window().0, (spec.panel_w)()) },
      at_start=false,
      fn(cur_sz) {
        let (ww, pw) = cur_sz
        let (prev_ww, prev_pw) = prev_panel_w.val
        if (ww - prev_ww).abs() > 0.5 || pw != prev_pw {
          prev_panel_w.val = cur_sz
          if locked_w.untracked() is Some(_) || width_way.goes_at(box.cause_at()) {
            unlock_now()
          }
        }
      },
    )
    box.reacts(
      fn() { ((spec.tabs)(), (spec.front)()) },
      at_start=false,
      fn(st) {
        let (ts, f) = st
        let n = ts.length()
        tabs_sig.set(ts)
        front_key.set(f)
        if n > prev_n.val || n == 0 {
          unlock_now()
        }
        prev_n.val = n
      },
    )

    let sc = box.box(fn(sb) {
      sb
      .grow(Is(1.0))
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      .height(Is(Some(spec.strip_h)))
      .scrolls(scroll, slop=@ui.touch_slop(), fn(inner) {
        inner.row(Is(true)).lines_up(Is(Some(Middle))).shrink(Is(0.0)).height(Is(Some(spec.strip_h))) |> ignore
        // Vertical mouse wheel scrolls tab strip horizontally when overflowing
        inner.on_wheel_moves(fn(w) {
          if w.dx == 0.0 && w.dy != 0.0 && scroll.goes() {
            let cur = scroll.at(inner.tree)
            let reach = scroll.reach()
            let next = dmax(0.0, dmin(reach, cur + w.dy))
            if (next - cur).abs() > 0.5 {
              scroll.put(next)
              return true
            }
          }
          false
        })
        |> ignore

        @headless.radio_group(
          inner,
          spec.group_label,
          front_now,
          spec.on_select,
          kind=Tab,
          fn(g, rg) {
            // `g` wraps only the tab row and takes pointer hits so leaving slots / tab gaps keep `box.pointed_in()`
            // true during repeated × clicks without blocking `moves_window` on empty top-bar space.
            g.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(tab_strip_gap)).shrink(Is(0.0)).presses(Is(true)) |> ignore
            let front_of = g.selected(fn() { Some(front_now()) })
            let hands = @motion.Handoff::new()

            g.each(along_row=true, fn() { tabs_sig.get() }, fn(k) { k }, fn(slot, k) {
              let key = k.untracked()
              let shut : Ref[@view.View?] = Ref(None)
              let item_ref : Ref[@view.View?] = Ref(None)
              let item_said : Ref[@headless.RadioItem?] = Ref(None)

              let is_front = fn() { front_of(key) }
              let on_shut = fn() {
                match shut.val {
                  Some(x) => x.pointed() || x.pressed()
                  None => false
                }
              }
              let on_item = fn() {
                match item_ref.val {
                  Some(x) => lit_node(x)
                  None => false
                }
              }
              let lit = fn() { !is_front() && (on_item() || on_shut()) }
              let show_x = fn() {
                if is_front() {
                  true
                } else if more_held() {
                  false
                } else {
                  slot_w_rest() >= tab_strip_narrow_x_w &&
                  (slot.pointed_in() || item_ref.val.map(fn(x) { x.focused() }).unwrap_or(false))
                }
              }

              // Leaving slot releases hits on frame 1 so rapid × clicks never get swallowed
              slot
              .presses(By(fn() { !slot.leaving() }))
              .shrink(Is(0.0))
              .width(By(fn() { Some(slot_w_at(slot)) }))
              .offset(By(fn() {
                match drag_tab.get() {
                  Some(dt) if dt == key => (drag_dx.get(), 0.0)
                  Some(_) => {
                    let from = drag_from.get()
                    let to = drag_to.get()
                    if from < 0 || to < 0 || from == to {
                      (0.0, 0.0)
                    } else {
                      let my = tabs_sig.untracked().search(key).unwrap_or(-1)
                      let step = slot_w_rest() + tab_strip_gap
                      if from < to && my > from && my <= to {
                        (-step, 0.0)
                      } else if from > to && my >= to && my < from {
                        (step, 0.0)
                      } else {
                        (0.0, 0.0)
                      }
                    }
                  }
                  None => (0.0, 0.0)
                }
              }))
              .on_menu(fn(m) { (spec.on_menu)(key, m.wx, m.wy) })
              .on_middle(fn(b) {
                if b.went is ButtonUp && !slot.leaving() {
                  let (sx, sy, sw, sh) = slot.placed_window_now()
                  if b.wx >= sx && b.wx <= sx + sw && b.wy >= sy && b.wy <= sy + sh {
                    close_tab(key)
                  }
                }
              })
              |> ignore

              // Active pill handoff
              let part = hands.part(fn(_) { if @signals.untracked(is_front) { 1.0 } else { 0.0 } })
              slot.box(fn(pill) {
                pill
                .over(Is(true), edges=(Some(0.0), Some(0.0), Some(0.0), Some(0.0)))
                .radius(Is(1.0e6))
                .ground(By(fn() { if is_front() { @ui.tree_theme().color(Selected) } else { 0L } }))
                |> ignore
                part.draws(pill)
              })
              |> ignore
              if @signals.untracked(is_front) {
                part.came(0.0, @motion.snappy_damped, takes=false) |> ignore
              }
              slot.reacts(is_front, at_start=false, fn(on) {
                let at = slot.cause_at()
                if on {
                  part.came(at, @motion.snappy_damped) |> ignore
                } else {
                  part.left(at)
                  part.still()
                }
              })
              slot.owns(fn() { part.gone() }) |> ignore

              let item = rg.item(
                slot,
                fn() { key },
                fn() { (spec.names)(key).0 },
                on_close=fn() { close_tab(key) },
                fn(v, s) {
                  item_ref.val = Some(v)
                  item_said.val = Some(s)
                  style_node(v, fn() { if show_x() { tab_strip_body_style } else { tab_strip_body_no_x } }, in_row=true)
                  v.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                  (spec.mark)(v, key, fn() { is_front() || lit() })
                  words_node(v, fn() { (spec.names)(key).0 }, fn() {
                    if is_front() {
                      spec.words_front
                    } else if lit() {
                      spec.words_lit
                    } else {
                      spec.words_rest
                    }
                  })
                  .shrink(Is(1.0))
                  .min_width(Is(Some(0.0)))
                  |> ignore
                },
              )

              // Drag-to-reorder + tap-to-focus via View::gesture (never bare on_drag)
              let drag_start_wx = Ref(0.0)
              let drag_start_scroll = Ref(0.0)
              item.gesture(
                tab_strip_drag_slop,
                tap=fn(_) {
                  if item_said.val is Some(s) {
                    s.press()
                  }
                },
                drag=fn(d) {
                  let cur = tabs_sig.untracked()
                  if more_held() || cur.length() <= 1 {
                    return
                  }
                  let reset = fn() {
                    drag_tab.set(None)
                    drag_dx.set(0.0)
                    drag_from.set(-1)
                    drag_to.set(-1)
                    scroll.edge_toward(0.0)
                  }
                  match d.kind {
                    Down => {
                      let idx = cur.search(key).unwrap_or(-1)
                      if idx >= 0 {
                        if !@signals.untracked(is_front) {
                          (spec.on_select)(key)
                        }
                        drag_start_wx.val = d.wx
                        drag_start_scroll.val = scroll.at(inner.tree)
                        drag_tab.set(Some(key))
                        drag_dx.set(0.0)
                        drag_from.set(idx)
                        drag_to.set(idx)
                      }
                    }
                    Moved => {
                      let from = drag_from.untracked()
                      if from >= 0 {
                        let step = @signals.untracked(slot_w_rest) + tab_strip_gap
                        let raw_dx = d.wx - drag_start_wx.val + (scroll.at(inner.tree) - drag_start_scroll.val)
                        let min_dx = -from.to_double() * step
                        let max_dx = (cur.length() - 1 - from).to_double() * step
                        let dx = dmax(min_dx, dmin(max_dx, raw_dx))
                        drag_dx.set(dx)
                        let delta = if step > 0.5 { (dx / step).round().to_int() } else { 0 }
                        let raw_to = from + delta
                        let clamped = if raw_to < 0 { 0 } else if raw_to >= cur.length() { cur.length() - 1 } else { raw_to }
                        drag_to.set(clamped)
                        if scroll.goes() {
                          let (sx, _, sw, _) = box.placed_window_now()
                          if d.wx < sx + 24.0 {
                            scroll.edge_toward(-0.25)
                          } else if d.wx > sx + sw - 24.0 {
                            scroll.edge_toward(0.25)
                          } else {
                            scroll.edge_toward(0.0)
                          }
                        }
                      }
                    }
                    Up => {
                      let from = drag_from.untracked()
                      let to = drag_to.untracked()
                      reset()
                      if from >= 0 && to >= 0 && from != to {
                        (spec.on_move)(key, to)
                      }
                    }
                    Off => reset()
                  }
                },
              )
              |> ignore

              style_node_ring(
                slot,
                fn() {
                  if !is_front() && lit() {
                    tab_strip_capsule_lit
                  } else {
                    tab_strip_capsule
                  }
                },
                fn() { if item.focus_shown() { (-1.0, 0.0, 0L) } else { (0.0, 0.0, 0L) } },
                in_row=true,
              )

              // Full tooltip on every tab
              tip_node(spec.tips, item, fn() { (spec.names)(key).0 }, repeats=true) |> ignore

              // × mounted only when show_x() is true (no alpha=0 click-through)
              slot.show(at_once=true, show_x, fn(c) {
                c.shrink(Is(0.0)) |> ignore
                let x = icon_button_node(
                  c,
                  "close",
                  fn() { (spec.names)(key).1 },
                  fn() {
                    if item_said.val is Some(s) {
                      s.close()
                    }
                  },
                  size=tab_strip_close_side,
                  icon_size=tab_strip_close_icon,
                )
                x.focusable(Is(false)).shrink(Is(0.0)) |> ignore
                shut.val = Some(x)
                x.owns(fn() { shut.val = None }) |> ignore
              })
            })
          },
        )
        |> ignore
      })
      |> ignore
    })

    // Smoothly expand tabs to natural width when mouse pointer leaves the tab strip.
    box.reacts(
      fn() { (pointer_rests(), box.pointed() || box.pointed_in()) },
      at_start=false,
      fn(st) {
        let (mouse, in_now) = st
        if mouse && !in_now {
          if locked_w.untracked() is Some(was) {
            let nat = @signals.untracked(fn() {
              let n = tabs_sig.untracked().length()
              if n <= 1 { tab_strip_max_w } else { tab_strip_natural_w(strip_w(), n) }
            })
            locked_w.set(None)
            if (nat - was).abs() > 0.5 && !@ui.reduced_motion() {
              width_way.put(was)
              width_way.go(box, nat, @motion.moved(over=(nat - was).abs()))
            } else {
              width_way.put(nat)
            }
          }
        }
      },
    )

    // Auto-scroll active tab into view when front or tabs change
    sc.reacts(
      fn() {
        let n = tabs_sig.get().length()
        if n <= 1 {
          ("", 0, 0.0)
        } else {
          (front_now(), n, strip_w())
        }
      },
      fn(st) {
        let (f, n, sw) = st
        if n <= 1 || sw <= 0.0 {
          return
        }
        let cur = tabs_sig.untracked()
        let idx = cur.search(f).unwrap_or(-1)
        if idx < 0 {
          return
        }
        let w = @signals.untracked(slot_w_rest)
        let step = w + tab_strip_gap
        let tab_l = idx.to_double() * step
        let tab_r = tab_l + w
        let sx = scroll.at(sc.tree)
        if tab_l < sx {
          scroll.put(tab_l)
        } else if tab_r > sx + sw {
          scroll.put(dmax(0.0, tab_r - sw))
        }
      },
    )

    // Width probe and overflow dropdown trigger: mounted only when 2+ tabs are open so single-tab cold open pays
    // zero extra probe/overflow nodes and zero secondary layout pass.
    box.show(at_once=true, fn() { tabs_sig.get().length() > 1 }, fn(multi) {
      multi.over(Is(true), edges=(Some(0.0), Some(0.0), Some(0.0), Some(0.0))) |> ignore
      multi
      .by_room(fn(probe, room) {
        probe.over(Is(true)) |> ignore
        probe.reacts(fn() { room.width() }, fn(w) { bar_w.set(w) })
      })
      .over(Is(true), edges=(Some(0.0), Some(0.0), Some(0.0), Some(0.0)))
      |> ignore
      multi.show(at_once=true, needs_overflow, fn(ob) {
        ob.over(Is(true), edges=(None, Some(0.0), Some(0.0), Some(0.0))).row(Is(true)).lines_up(Is(Some(Middle)))
        |> ignore
        let btn_ref : Ref[@view.View?] = Ref(None)
        let btn = icon_button_node(
          ob,
          "chevron-down",
          spec.more_label,
          fn() {
            let anchor = match btn_ref.val {
              Some(b) => b.placed_window_now()
              None => ob.placed_window_now()
            }
            (spec.on_overflow)(anchor)
          },
          size=tab_strip_overflow_w,
          icon_size=14.0,
          tips=spec.tips,
        )
        btn_ref.val = Some(btn)
      })
    })
  })
  ignore(outer)
}
