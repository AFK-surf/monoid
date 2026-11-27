// Tabs (标签页) as nodes of the window's tree, made once: a tab list over the panel of the tab chosen. Two looks
// (`TabsLook`): `Underline`, words along a hairline, the chosen one's in the ink with a bar under it; `Pill`, words in a
// quiet capsule track, the chosen one's on a lifted capsule. The bar or the capsule slides from where it is to the tab
// chosen as that changes, at that moment, as a thing moved does (@motion's move_spring), its width moving with its
// place (@ui.cover_rect). What it is to the hand, the keyboard and a screen reader is mbui's tabs (@headless.Tabs: a
// tab list of tabs, Tab stopping at the chosen one, ← → Home End choosing along it, or moving the focus alone where
// `manual`, Space or Enter choosing; each panel read out while its tab is chosen); here their look.

///|
/// How a tabs_node's tab list looks: words along a hairline, a bar under the chosen one's (`Underline`), or words in a
/// quiet capsule track, the chosen one's on a lifted capsule (`Pill`).
#derive(Eq, Debug)
pub(all) enum TabsLook {
  Underline
  Pill
}

///|
/// Tabs in `parent` as wide as where they are: a tab list called `label` of `tabs` (each its key and its words), the one
/// chosen `chosen()`, `choose` told the key a press or a key chooses (the caller says it chosen then); under it the
/// panel of the chosen tab, made by `content` (given the panel and its key) while its tab is chosen, or once and kept
/// while another is (`keep_mounted`: what it holds keeps its state, hidden, taking no input and no room). `look` its
/// tab list's look; `manual`: the arrow keys move the focus alone, Space or Enter choosing. The node.
#callsite(autofill(loc))
pub fn[K : Eq] tabs_node(
  parent : @view.View,
  label : () -> String,
  tabs : Array[(K, () -> String)],
  chosen : () -> K,
  choose : (K) -> Unit,
  content : (@view.View, K) -> Unit,
  look? : TabsLook = Underline,
  manual? : Bool = false,
  keep_mounted? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let t = @headless.Tabs::new(chosen, choose, manual~)
  let place_of = fn(k : K) -> Int {
    for i = 0; i < tabs.length(); i = i + 1 {
      if tabs[i].0 == k {
        return i
      }
    }
    0
  }
  let tab_h = match look {
    Underline => tabs_line_h
    Pill => tabs_pill_h
  }
  parent.box(made_for=loc, fn(col) {
    style_node(col, fn() { tabs_column })
    let panel_way = @motion.NodeWay::new(1.0)
    let panel_dir : Ref[Double] = Ref(1.0)
    // its tab list (a row as wide as where it is, its track as wide as its tabs)
    col.box(fn(line) {
      style_node(line, fn() { tabs_line })
      @headless.Tabs::list(t, line, label, made_for=loc, fn(list, rg) {
        style_node(list, fn() {
          match look {
            Underline => tabs_list_line
            Pill => tabs_list_pill
          }
        })
        // (underlined, across its line, its hairline under the room after its tabs too; a pill's track as wide as its
        // tabs)
        if look is Underline {
          list.grow(Is(1.0)) |> ignore
        }
        list.box(fn(strip) {
          style_node(strip, fn() { tabs_strip })
          // (each tab as wide as its words, 500, at the system's size of words, with its sides: measured again as all
          // words are, the size of words changed)
          let w_of = fn(i : Int) {
            strip.words_redone() |> ignore
            match tabs.get(i) {
              Some((_, words)) => node_words_w(words(), node_sp(strip, theme().t.ui), weight=500) + 2.0 * tabs_in
              None => 0.0
            }
          }
          let x_of = fn(i : Int) {
            let mut x = 0.0
            for j in 0..<i {
              x = x + w_of(j) + tabs_gap
            }
            x
          }
          // (where the bar or the capsule is along the strip and how wide: off from where it set out to the chosen
          // tab's place and width together as that changes, on snappy_damped; the words' size changed, there at once)
          let tab_h_now = fn() {
            strip.words_redone() |> ignore
            let tl = @ui.tree_theme().text_line
            let line = theme().t.ui * (if tl > 0.0 { tl } else { 1.4 })
            dmax(tab_h, node_sp(strip, line).ceil() + 2.0 * 2.0)
          }
          let n = tabs.length()
          let last_f = if n > 1 { (n - 1).to_double() } else { 0.0 }
          let init_idx = place_of(@signals.untracked(chosen))
          let dd = @glass.DampedDrag::new(init_idx.to_double(), lo=0.0, hi=last_f, held_scale=@glass.ctrl_seg_held_scale)
          dd.attach(strip)
          let current = Ref(init_idx)
          let strip_origin_x = Ref(0.0)
          let felt : Ref[Int?] = Ref(None)
          let finger_previewing = Ref(false)
          let press_was_finger = Ref(false)
          let drag_active = Ref(false)
          let axis_locked : Ref[Bool?] = Ref(None)
          let press_key : Ref[K?] = Ref(None)
          let press_keys : Ref[Array[K]] = Ref([])
          let pill_rect = fn(v : @view.View) -> (Double, Double, Double, Double)? {
            guard n > 0 else { return None }
            let h = tab_h_now()
            guard n > 1 else { return Some((x_of(0), 0.0, w_of(0), h)) }
            let p = dd.value(v)
            let i = p.floor().to_int()
            let a = if i < 0 { 0 } else if i > n - 2 { n - 2 } else { i }
            let f = p - a.to_double()
            let x0 = x_of(a)
            let x1 = x_of(a + 1)
            let w0 = w_of(a)
            let w1 = w_of(a + 1)
            Some((x0 + (x1 - x0) * f, 0.0, dmax(0.0, w0 + (w1 - w0) * f), h))
          }
          let pill_index_at = fn(lx : Double) -> Double {
            if n <= 1 {
              return 0.0
            }
            let mut from = x_of(0) + w_of(0) / 2.0
            if lx <= from {
              return 0.0
            }
            for k in 1..<n {
              let to = x_of(k) + w_of(k) / 2.0
              if lx < to && to > from {
                return (k - 1).to_double() + dclamp((lx - from) / (to - from), 0.0, 1.0)
              }
              from = to
            }
            last_f
          }
          let prev_idx = Ref(init_idx)
          strip.reacts(chosen, at_start=false, fn(k) {
            let to_k = place_of(k)
            let from_k = prev_idx.val
            prev_idx.val = to_k
            if to_k != current.val {
              current.val = to_k
              if look is Pill {
                dd.slide_to(to_k.to_double(), spec=@motion.snappy_damped)
              }
            }
            if to_k != from_k {
              panel_dir.val = if to_k > from_k { 1.0 } else { -1.0 }
              panel_way.go_from(strip, 0.0, 1.0, @motion.tween(180.0, ease=Out))
            }
          })
          let no_lens = fn() { !(look is Pill) || strip.glass_solid() || @ui.glass_material() != Liquid }
          let press_on_selected = Ref(false)
          let clear_press_state = fn() {
            felt.val = None
            finger_previewing.val = false
            drag_active.val = false
            axis_locked.val = None
            press_key.val = None
            press_keys.val = []
            press_on_selected.val = false
          }
          strip.owns(fn() {
            let was_active = finger_previewing.val || drag_active.val || dd.pressing() || dd.has_pending_release()
            clear_press_state()
            if was_active && look is Pill {
              dd.drop_lens()
            }
          })
          |> ignore
          let tap_commit = fn(sel : Int) {
            let dd_host_before = dd.host_node()
            match tabs.get(sel) {
              Some((k, _)) => if k != @signals.untracked(chosen) { choose(k) }
              None => ()
            }
            if !strip.alive() || !dd.same_host(dd_host_before) {
              return
            }
            let settled = place_of(@signals.untracked(chosen))
            current.val = settled
            if no_lens() && (dd.pressing() || dd.has_pending_release()) {
              dd.drop_lens()
            }
            dd.slide_to(settled.to_double(), spec=@motion.snappy_damped)
          }
          let drag_commit = fn(sel : Int, spec : @motion.Spec?) {
            let dd_host_before = dd.host_node()
            match tabs.get(sel) {
              Some((k, _)) => if k != @signals.untracked(chosen) { choose(k) }
              None => ()
            }
            if !strip.alive() || !dd.same_host(dd_host_before) {
              return
            }
            let settled = place_of(@signals.untracked(chosen))
            current.val = settled
            if no_lens() {
              dd.drop_lens()
              dd.slide_to(settled.to_double(), spec?)
            } else {
              dd.settle_to(settled.to_double(), spec?, within_frac=0.18, relative_trip=true)
            }
          }
          let cancel_drag_opts = fn(keep_vertical_lock : Bool) {
            let was_active = finger_previewing.val || drag_active.val || dd.pressing() || dd.has_pending_release()
            felt.val = None
            finger_previewing.val = false
            drag_active.val = false
            if !keep_vertical_lock {
              axis_locked.val = None
              press_key.val = None
              press_keys.val = []
              press_on_selected.val = false
            }
            if was_active {
              let orig = place_of(@signals.untracked(chosen))
              current.val = orig
              if no_lens() {
                dd.drop_lens()
                dd.slide_to(orig.to_double(), spec=@motion.snappy_damped)
              } else {
                dd.settle_to(orig.to_double(), spec=@motion.snappy_damped, within_frac=0.18, relative_trip=true)
              }
            }
          }
          let cancel_drag = fn() { cancel_drag_opts(false) }
          let finger_preview = fn(k : Int, event : @view.Drag?) -> Int? {
            match event {
              Some(d) => {
                let p = pill_index_at(x_of(k) + d.x)
                let nearest = dclamp((p + 0.5).floor(), 0.0, last_f).to_int()
                let prev_felt = felt.val.unwrap_or(place_of(@signals.untracked(chosen)))
                let steps = (nearest - prev_felt).abs()
                for _ in 0..<steps {
                  @ui.haptic(TextHandleMove)
                }
                felt.val = Some(nearest)
                let target = nearest.to_double()
                let leaned = target + (p - target) * 0.25
                if !finger_previewing.val {
                  finger_previewing.val = true
                  if !no_lens() {
                    dd.press()
                  }
                }
                if no_lens() {
                  dd.slide_to(leaned, spec=@motion.tactile_bounce)
                } else {
                  dd.update_value(leaned, spec=@motion.tactile_bounce)
                }
                Some(nearest)
              }
              None => {
                cancel_drag_opts(true)
                None
              }
            }
          }
          let finger_commit = fn(sel : Int) {
            let prev = place_of(@signals.untracked(chosen))
            if felt.val != Some(sel) && sel != prev {
              @ui.haptic(TextHandleMove)
            }
            let was_previewing = finger_previewing.val
            clear_press_state()
            let commit_spec = if was_previewing { @motion.tactile_bounce } else { @motion.snappy_damped }
            drag_commit(sel, Some(commit_spec))
          }
          let mount_pill_lens = match look {
            Underline => {
              let rect = @motion.cover_indicator(
                strip,
                fn() { place_of(chosen()) },
                fn(k) {
                  if k >= 0 && k < n {
                    Some((x_of(k), 0.0, w_of(k), tab_h_now()))
                  } else {
                    None
                  }
                },
                spec=@motion.snappy_damped,
              )
              strip.box(fn(mark) {
                mark
                .over(Is(true))
                .points(Is(false))
                .width(Is(Some(0.0)))
                .height(Is(Some(tabs_bar_h)))
                .radius(Is(tabs_bar_h / 2.0))
                .ground(By(fn() { theme().p.text }))
                .ground_drawn(By(fn() {
                  match rect() {
                    Some((x, _, w, _)) => {
                      dx: x,
                      dy: tab_h_now() - tabs_bar_h,
                      dw: w,
                      dh: 0.0,
                      corners: None,
                    }
                    None => @view.ground_as_laid
                  }
                }))
                |> ignore
              })
              |> ignore
              None
            }
            Pill =>
              Some(
                @glass.liquid_segmented_thumb_look(
                  strip,
                  pill_rect,
                  fn(v) { dd.pressed(v) },
                  look=@glass.SegThumbLook::default(
                    glass_track=false,
                    jelly=fn(v) { dd.jelly(v, 10.0) },
                    active=fn() { dd.pressing() },
                    solid=fn() { theme().p.raised },
                    overhang_x=12.0,
                    overhang_y=8.0,
                  ),
                  loc~,
                ),
              )
          }
          for i, tab in tabs {
            let (key, words) = tab
            let i_f = i.to_double()
            rg.item(strip, fn() { key }, words, made_for=loc, fn(o, item) {
              o
              .focus_ring_theme()
              .width(By(fn() { Some(w_of(i)) }))
              .height(By(fn() { Some(tab_h_now()) }))
              .radius(By(fn() { if look is Pill { tab_h_now() / 2.0 } else { tabs_corner } }))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              |> ignore
              o.box(fn(w) {
                w
                .words(By(words))
                .words_look(By(fn() {
                  // (its line so many times its size as drawn, at the system's size of words: seg_node's)
                  {
                    size: theme().t.ui,
                    weight: 500,
                    line: -@ui.tree_theme().text_line,
                    wrap: false,
                    tracking: @view.letters_own,
                    balance: false,
                    max_lines: 0,
                  }
                }))
                .ink(By(fn() {
                  if look is Pill {
                    let lit = dclamp(1.0 - (dd.value(w) - i_f).abs(), 0.0, 1.0)
                    if !item.disabled() && item.hovered() && lit < 0.5 {
                      theme().p.text
                    } else {
                      @ui.blend(theme().p.muted, theme().p.text, lit)
                    }
                  } else if item.chosen() || (!item.disabled() && (item.hovered() || item.pressed())) {
                    theme().p.text
                  } else {
                    theme().p.muted
                  }
                }))
                |> ignore
              })
              |> ignore
              if look is Pill {
                let across = fn(d : @view.Drag) { (d.x - d.ox).abs() > (d.y - d.oy).abs() }
                let on_it = fn(d : @view.Drag) { o.finger_target(d.wx, d.wy) }
                let keys_unchanged = fn() -> Bool {
                  let snap = press_keys.val
                  if tabs.length() != snap.length() {
                    return false
                  }
                  for j in 0..<tabs.length() {
                    if tabs[j].0 != snap[j] {
                      return false
                    }
                  }
                  tabs.get(i).map(fn(e) { e.0 }) == Some(key)
                }
                o.gesture(
                  @ui.touch_slop(),
                  press=fn(d) {
                    press_was_finger.val = @ui.pointing() is Finger
                    drag_active.val = false
                    axis_locked.val = None
                    press_key.val = Some(key)
                    press_keys.val = tabs.map(fn(e) { e.0 })
                    press_on_selected.val = key == @signals.untracked(chosen)
                    strip_origin_x.val = d.wx - (x_of(i) + d.x)
                  },
                  tap=fn(d) {
                    if press_was_finger.val {
                      if !keys_unchanged() {
                        cancel_drag()
                      } else if on_it(d) {
                        if !finger_previewing.val && key != @signals.untracked(chosen) {
                          clear_press_state()
                          tap_commit(i)
                        } else {
                          finger_commit(i)
                        }
                      } else {
                        cancel_drag()
                      }
                    } else {
                      let was_drag = drag_active.val
                      if !keys_unchanged() || !on_it(d) {
                        cancel_drag()
                      } else {
                        clear_press_state()
                        if was_drag {
                          drag_commit(i, None)
                        } else {
                          tap_commit(i)
                        }
                      }
                    }
                  },
                  hold=(@glass.ctrl_seg_hold_ms, fn(d) {
                    if !keys_unchanged() {
                      cancel_drag()
                      return
                    }
                    if press_was_finger.val {
                      finger_preview(i, Some(d)) |> ignore
                    } else if press_on_selected.val {
                      drag_active.val = true
                      if !no_lens() && !dd.pressing() {
                        dd.press()
                      }
                    }
                  }),
                  hold_yields=true,
                  drag=fn(d) {
                    if press_was_finger.val {
                      match d.kind {
                        Down | Moved => {
                          if !keys_unchanged() {
                            cancel_drag()
                            return
                          }
                          if d.kind == Down {
                            axis_locked.val = Some(across(d))
                          }
                          if axis_locked.val == Some(true) {
                            finger_preview(i, Some(d)) |> ignore
                          } else {
                            finger_preview(i, None) |> ignore
                          }
                        }
                        Up => {
                          let hold_still = finger_previewing.val &&
                            axis_locked.val is None &&
                            (d.x - d.ox).abs() <= @ui.touch_slop() &&
                            (d.y - d.oy).abs() <= @ui.touch_slop()
                          if !keys_unchanged() ||
                            axis_locked.val == Some(false) ||
                            (!hold_still && !axis_locked.val.unwrap_or(across(d))) {
                            cancel_drag()
                          } else {
                            match finger_preview(i, Some(d)) {
                              Some(sel) => finger_commit(sel)
                              None => cancel_drag()
                            }
                          }
                        }
                        Off => cancel_drag()
                      }
                    } else {
                      let started_on_selected = press_on_selected.val
                      if !started_on_selected {
                        match d.kind {
                          Down | Moved => ()
                          Up =>
                            if !drag_active.val && on_it(d) && keys_unchanged() {
                              clear_press_state()
                              tap_commit(i)
                            } else {
                              cancel_drag()
                            }
                          Off => cancel_drag()
                        }
                      } else {
                        match d.kind {
                          Down => {
                            if !keys_unchanged() {
                              cancel_drag()
                              return
                            }
                            let is_h = across(d)
                            axis_locked.val = Some(is_h)
                            if is_h {
                              drag_active.val = true
                              if !no_lens() && !dd.pressing() {
                                dd.press()
                              }
                              let p = pill_index_at(d.wx - strip_origin_x.val)
                              if no_lens() {
                                dd.slide_to(p)
                              } else {
                                dd.update_value(p)
                              }
                            } else {
                              cancel_drag_opts(true)
                            }
                          }
                          Moved => {
                            if !keys_unchanged() {
                              cancel_drag()
                              return
                            }
                            if axis_locked.val == Some(true) {
                              let p = pill_index_at(d.wx - strip_origin_x.val)
                              if no_lens() {
                                dd.slide_to(p)
                              } else {
                                dd.update_value(p)
                              }
                            }
                          }
                          Up => {
                            if !keys_unchanged() || axis_locked.val == Some(false) {
                              cancel_drag()
                            } else if axis_locked.val.unwrap_or(across(d)) {
                              let p = pill_index_at(d.wx - strip_origin_x.val)
                              let sel = dclamp(p.round(), 0.0, last_f).to_int()
                              clear_press_state()
                              drag_commit(sel, None)
                            } else {
                              cancel_drag()
                            }
                          }
                          Off => cancel_drag()
                        }
                      }
                    }
                  },
                )
                |> ignore
              }
            })
            |> ignore
          }
          match mount_pill_lens {
            Some(mount) => mount()
            None => ()
          }
        })
        |> ignore
        if look is Underline {
          list.box(fn(rule) { style_node(rule, fn() { tabs_rule }) }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
    // the panels: the chosen one's laid out, the others (kept) taking no room
    col.box(fn(panels) {
      style_node(panels, fn() { tabs_panels })
      for tab in tabs {
        let (key, words) = tab
        t.panel(
          panels,
          key,
          words,
          made_for=loc,
          keep_mounted~,
          fn(p, shown) {
            style_node(p, fn() { tabs_panel })
            p
            .laid_nowhere(By(fn() { !shown.selected() }))
            .offset(By(fn() {
              let q = panel_way.shown(p)
              (panel_dir.val * 12.0 * (1.0 - q), 0.0)
            }))
            .alpha(By(fn() { panel_way.shown(p) }))
            .carries_until(fn() { panel_way.ends_at() })
            |> ignore
          },
          fn(p) { content(p, key) },
        )
        |> ignore
      }
    })
    |> ignore
  })
}

///|
/// An underlined tab's height, a pill's, and the bar under the chosen underlined one.
let tabs_line_h : Double = 36.0

///|
let tabs_pill_h : Double = 28.0

///|
let tabs_bar_h : Double = 2.0

///|
/// Words in from a tab's sides, and the room between tabs.
let tabs_in : Double = 12.0

///|
let tabs_gap : Double = 2.0

///|
/// An underlined tab's corner (its focus ring's, its ground none).
let tabs_corner : Double = 6.0

///|
// kept across runs: a value (no field of it changes)
let tabs_column : @ui.Style = @ui.css("w=Full gap=S3")

///|
/// Its tab list's line, as wide as where it is.
// kept across runs: a value (no field of it changes)
let tabs_line : @ui.Style = @ui.css("row w=Full")

///|
/// The underlined list: across its line, its tabs over a hairline.
// kept across runs: a value (no field of it changes)
let tabs_list_line : @ui.Style = @ui.css("w=Full")

///|
/// The hairline under underlined tabs, across their list.
// kept across runs: a value (no field of it changes)
let tabs_rule : @ui.Style = rule_line

///|
/// The pill's track: a quiet capsule round its tabs, 4 in (so the capsule in it stands concentric with it).
// kept across runs: a value (no field of it changes)
let tabs_list_pill : @ui.Style = @ui.css("row p=S1 radius=Full bg=A(Fg,O5)")

///|
// kept across runs: a value (no field of it changes)
let tabs_strip : @ui.Style = @ui.css("row gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let tabs_panels : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let tabs_panel : @ui.Style = @ui.css("w=Full gap=S2")
