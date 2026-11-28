// The phone's bottom bar drawn as nodes of the window's tree (bar.mbt's model and its ways, bar_menu.mbt's menu), in
// its glass's node (bar_glass_node: where it is laid out, what takes a finger on it): laid out where it is told
// (bar_tell: BarLaid), each of its numbers read where it is as each frame is drawn (View::drawn_while) while the ways it
// is drawn by go, where they went once they are there (the clock no longer followed); told again as the bar is told
// anew (bar_said). What moves is drawn so, nothing laid out for it (src/motion's rule): the bar going down and coming
// back, the glass growing up into its menu and drawn in along the bar, the capsule giving the action room and its
// places moving with it, the action's circle growing and its icon swapping, the selection and the lens it lifts into,
// each place lighting up, the menu's rows rising and its indicator.

///|
/// Said each time the bar is told what it goes by (bar_tell, bar_retell, bar_reset): its ways set out anew, what waits
/// on them told again (bar_node's said_moving).
// kept across runs: a count whose changes alone are read (what reads it read again), never its value
let bar_said : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })

///|
/// The parts of the bar each drawn by ways of their own, told apart: what reads one part's ways is read again only as
/// its ways are told anew, not as another's are (the bar going down under a page wakes its holder alone).
priv enum BarPart {
  /// the bar shown (vis): its holder
  Vis
  /// the notch (k, its liquid bridge, scroll-collapse): the glass's length, the action's disc, the places' places
  Notch
  /// the menu (the glass's height and pinch, whether it is open, its rows rising, what its indicator points at, the
  /// bar's press let go): the glass's top, the tab row fading, the rows, the indicator
  Menu
  /// the ball (where across, held, how faint and large): the selection, its lens, what the lens zooms and grows
  Ball
  /// each place lit (tints)
  Tints
  /// the notch's icon and its swap
  Icon
  /// scroll-to-collapse progress alone (collapse): tab fades/scales and capsule clip
  Collapse
}

///|
/// Each part said as it is told anew (bar_said_again), in BarPart's order.
// kept across runs: counts whose changes alone are read (what reads them read again), never their values
let bar_parts_said : Array[@signals.Signal[Int]] = [
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
]

///|
/// What each part's ways were last told, as text (bar_part_told), in BarPart's order.
// kept across runs: said again each time the bar is told (bar_said_again), emptied by bar_reset's
let bar_parts_told : Array[String] = ["", "", "", "", "", "", ""]

///|
fn BarPart::ord(self : BarPart) -> Int {
  match self {
    Vis => 0
    Notch => 1
    Ball => 2
    Tints => 3
    Icon => 4
    Menu => 5
    Collapse => 6
  }
}

///|
/// Part `p` read as it is told anew (bar_parts_said).
fn bar_part_said(p : BarPart) -> Unit {
  bar_parts_said[p.ord()].get() |> ignore
}

///|
fn spr_told(s : Spr) -> String {
  "\{s.to} \{s.end()} \{s.set_at};"
}

///|
fn glide_told(g : Glide) -> String {
  "\{g.target} \{g.start} \{g.dur};"
}

///|
fn way_told(w : @motion.Way) -> String {
  "\{w.target()} \{w.starts_at()} \{w.ends_at()};"
}

///|
/// What part `p`'s ways are told now, as text: changed only as they are told anew.
fn bar_part_told(p : BarPart) -> String {
  let m = bar
  match p {
    Vis => glide_told(m.vis)
    Notch =>
      spr_told(m.k) +
      "\{m.bond_merge.target()} \{m.bond_merge.ends_at()} \{m.bond_recoil.ends_at()} " +
      "\{m.collapse.target()} \{m.collapse.ends_at()} "
    Ball =>
      spr_told(m.ball_x) +
      way_told(m.ball_held_up) +
      way_told(m.ball_held_dn) +
      way_told(m.ball_pill_dn) +
      way_told(m.tap_lens_up) +
      way_told(m.tap_lens_dn) +
      way_told(m.tap_pill_dn) +
      way_told(m.flex_launch) +
      way_told(m.flex_brake) +
      way_told(m.flex_decay) +
      way_told(m.flex_drag) +
      way_told(m.flex_wall) +
      glide_told(m.ball_alpha) +
      glide_told(m.ball_scale)
    Tints => {
      let out = StringBuilder()
      for id, g in m.tints {
        out.write_string(id)
        out.write_string(glide_told(g))
      }
      out.to_string()
    }
    Icon => m_face.val + " " + m.icon_was + " " + glide_told(m.icon_swap)
    Menu => {
      let menu = bar_menu
      "\{menu.open.untracked()} \{menu.rows} \{menu.rise_at} \{menu.rows_closing} \{menu.told_at} \{menu.carry};" +
      way_told(menu.h) +
      way_told(menu.pinch) +
      way_told(menu.press_down)
    }
    Collapse => "\{m.collapse.target()} \{m.collapse.ends_at()}"
  }
}

///|
/// The bar told anew: each part whose ways changed said, and the bar as a whole.
fn bar_said_again() -> Unit {
  for p in [Vis, Notch, Ball, Tints, Icon, Menu, Collapse] {
    let told = bar_part_told(p)
    if told != bar_parts_told[p.ord()] {
      bar_parts_told[p.ord()] = told
      let s = bar_parts_said[p.ord()]
      s.set(s.untracked() + 1)
    }
  }
  bar_said.set(bar_said.untracked() + 1)
}

///|
/// The moment node `n` reads part `p`'s ways at, those it is drawn by ending at `until`: the moment it is drawn at while
/// they go, past every end (+inf: each where it went) once they are there, as the first frame after says; read again as
/// that part is told anew.
fn bar_moment(n : @view.View, p : BarPart, until : Double) -> Double {
  bar_part_said(p)
  n.drawn_while(fn(t) { t < until })
}

///|
/// Node `n` moved off where it is laid out by what `f` gives at the moment it is drawn at (View::moved_by: placed, pressed
/// and read out there, nothing laid out again), part `p`'s ways it goes by ending at `until`; asked again as that part
/// is told anew.
fn bar_moved(n : @view.View, p : BarPart, until : () -> Double, f : (Double) -> (Double, Double)) -> Unit {
  n
  .moved_by(
    fn(_, _, t) {
      bar_part_said(p)
      f(t)
    },
    fn(_, _) {
      bar_part_said(p)
      until()
    },
  )
  |> ignore
}

///|
/// Where the notch as drawn ends (BarModel::k_at: its spring's, its liquid bridge's, and scroll-to-collapse).
fn bar_k_until() -> Double {
  dmax(dmax(bar.k.end(), bar.collapse.ends_at()), dmax(bar.bond_merge.ends_at(), bar.bond_recoil.ends_at()))
}

///|
/// Where the menu as drawn ends (its glass, its rows, its indicator's easing, the bar's press let go).
fn bar_menu_until() -> Double {
  bar_menu.rest()
}

///|
/// Where the ball as drawn ends (bar_ball_at: where it is, held, how big, how faint; the selection under it).
fn bar_ball_until() -> Double {
  let m = bar
  dmax(
    dmax(m.ball_x.end(), dmax(m.ball_pill_dn.ends_at(), m.tap_pill_dn.ends_at())),
    dmax(
      dmax(dmax(m.ball_held_ends_at(), m.tap_lens_ends_at()), m.flex_ends_at()),
      dmax(m.ball_scale.end(), m.ball_alpha.end()),
    ),
  )
}

///|
/// Where all the bar's glass, its selection and its tab row are drawn by ends: the notch's, the ball's and the menu's.
fn bar_all_until() -> Double {
  dmax(bar_k_until(), dmax(bar_ball_until(), bar_menu_until()))
}

///|
/// The moment node `n` reads the notch's, the ball's and the menu's ways at (bar_moment's, of the three), read again as
/// any of them is told anew: what is drawn by how long the capsule is, how far the lens grows the bar and how far the
/// glass has turned into the menu.
fn bar_all_moment(n : @view.View) -> Double {
  bar_part_said(Notch)
  bar_part_said(Ball)
  bar_moment(n, Menu, bar_all_until())
}

///|
/// Node `n` moved off where it is laid out by what `f` gives at the moment it is drawn at (bar_moved's), by the
/// notch's, the ball's and the menu's ways.
fn bar_all_moved(n : @view.View, f : (Double) -> (Double, Double)) -> Unit {
  n
  .moved_by(
    fn(_, _, t) {
      bar_part_said(Notch)
      bar_part_said(Ball)
      bar_part_said(Menu)
      f(t)
    },
    fn(_, _) {
      bar_part_said(Notch)
      bar_part_said(Ball)
      bar_part_said(Menu)
      bar_all_until()
    },
  )
  |> ignore
}

///|
/// Where the place of tint `id` ends lighting up or going dim.
fn bar_tint_until(id : String) -> Double {
  match bar.tints.get(id) {
    Some(g) => g.end()
    None => -1.0
  }
}

///|
/// How lit the place of tint `id` is at moment `t` (its glide's, bar_tell's; none told yet: not).
fn bar_tint_at(id : String, t : Double) -> Double {
  match bar.tints.get(id) {
    Some(g) => g.at(t).0
    None => 0.0
  }
}

///|
/// A box `w` by `h` at (`x`, `y`) in `parent` (over all of it: View::over), made by `f`; it.
fn bar_at(
  parent : @view.View,
  x : () -> Double,
  y : () -> Double,
  w : () -> Double,
  h : () -> Double,
  f : (@view.View) -> Unit,
) -> @view.View {
  let made : Ref[@view.View?] = Ref(None)
  parent.box(fn(o) {
    o.over(Is(true)) |> ignore
    made.val = Some(
      o.box(fn(b) {
        b.width(By(fn() { Some(w()) })).height(By(fn() { Some(h()) })).offset(By(fn() { (x(), y()) })) |> ignore
        f(b)
      }),
    )
  })
  |> ignore
  made.val.unwrap()
}

///|
/// What the bar is laid out by as it was last told (BarLaid), or as none before it is.
fn bar_laid_now() -> BarLaid {
  bar_laid_told.get()
}

///|
/// The bar laid out as nothing told yet.
fn bar_laid_none() -> BarLaid {
  bar_laid({ ws: "", shown: false, action: "", active: None, flat: [], more: "", width: 0.0 })
}

///|
/// How the bar is laid out as it was last told (bar_tell's: BarLaid), told again only as that changes, not as whether it
/// shows or what its notch offers does: what is laid out by it read again then alone.
// kept across runs: said again as the bar is told, put back by bar_reset
let bar_laid_told : @signals.Signal[BarLaid] = @signals.signal(bar_laid_none(), same=fn(a, b) { a == b })

///|
/// The slot of the place shown as the bar was last told (BarLaid::slot_of; -1: none of the bar's), told again only as
/// that changes: a slot's look that turns on being the one lit is read again then alone, not as the bar goes down under
/// a page or its notch offers another action.
// kept across runs: said again as the bar is told, put back by bar_reset
let bar_active_slot_told : @signals.Signal[Int] = @signals.signal(-1, same=fn(a, b) { a == b })

///|
/// Whether the stack is currently in an interactive back gesture (or cancelling one) over a bottom-bar root place.
fn bar_nav_gesturing() -> Bool {
  app.nav.in_gesture() && app.nav.root_shows() && place_of(app.nav.pages()[0]) is Some(_)
}

///|
/// Watches the active root page's primary scrollable list and feeds its scroll offset into `bar_scroll_note`.
fn bar_scroll_watch_node(b : @view.View, ws : () -> Workspace?) -> Unit {
  let prev_in_hand : Ref[Bool] = Ref(false)
  b.reacts(
    fn() {
      ignore(@sfbase.first_page_waits.get())
      ignore(app.nav.top())
      guard bar_told_now.get() is Some(t) && t.shown else { return None }
      guard t.active is Some(active) else { return None }
      guard ws() is Some(w) else { return None }
      guard @ui.view_tree() is Some(tree) else { return None }
      let mut best : @view.Scroll? = None
      let mut best_most = 0.0
      for _, s in tree.lists_scrolled {
        match s.shown_by() {
          Some(v) if v.alive() && tree.takes_keys(v.id()) => {
            let most = s.reach()
            if most > best_most {
              best_most = most
              best = Some(s)
            }
          }
          _ => ()
        }
      }
      match best {
        Some(s) => {
          let key = w.id + ":" + active
          let held = s.in_hand()
          if held {
            Some((key, s.at(tree), best_most, true))
          } else {
            let gliding = s.glides_till() is Some(_)
            if prev_in_hand.val || gliding {
              Some((key, if gliding { s.drawn(tree) } else { s.at(tree) }, best_most, false))
            } else {
              None
            }
          }
        }
        None => None
      }
    },
    fn(obs) {
      match obs {
        Some((page_key, y, _, true)) => {
          prev_in_hand.val = true
          bar.scroll_page_key = page_key
          bar.scroll_last_y = y
          bar.scroll_acc = 0.0
        }
        Some((page_key, y, most, false)) => {
          prev_in_hand.val = false
          bar_scroll_note(page_key, y, most, b.cause_at())
        }
        None => prev_in_hand.val = false
      }
    },
  )
}

///|
/// The bottom bar drawn in `g`, its glass's node (bar_glass_node: so what a press there goes to holds what it draws),
/// shown on a place's top page with nothing over it; going down out of the way as it is hidden,
/// taking nothing as it goes (View::show's `leave`). `ws`: the workspace in view.
fn bar_node(g : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  g.box(fn(b) {
    b.transitions_only().over(Is(true)) |> ignore
    bar_place_marks_node(b, src, ws)
    bar_scroll_watch_node(b, ws)
    // (what waits on what moves told as the bar is told anew: when all of it is at rest, BarModel::rest)
    b.reacts(fn() { bar_said.get() }, fn(_) { b.said_moving("bar", "the bar's springs", fn(_) { bar.rest() }) })
    // (none before its width is known: it is first laid out where it goes, at once, bar_tell; its leave scoped to `b`)
    let bar_open = fn() {
      match bar_told_now.get() {
        Some(t) => t.width > 0.0 && (t.shown || bar_nav_gesturing())
        None => false
      }
    }
    let bar_shown = @signals.signal(@signals.untracked(bar_open), same=fn(a, b) { a == b })
    b.reacts(bar_open, fn(on) { @view.transition(within=b, fn() { bar_shown.set(on) }) }, at_start=false)
    b.show(at_once=true,
      fn() { bar_shown.get() },
      fn(holder) { bar_holder_node(holder, src, ws) },
      leave=bar_hide_ms,
    )
  })
  |> ignore
}

///|
/// The bar in `holder` (its glass, what the glass holds), where it is told: going down out of the way and back up,
/// drawn so, laid out where it rests.
fn bar_holder_node(holder : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  let w = fn() { bar_laid_now().w }
  let panel = fn() { bar_laid_now().panel }
  let row_top = fn() { bar_laid_now().row_top }
  holder
  .width(By(fn() { Some(w()) }))
  .height(By(fn() { Some(panel()) }))
  .alpha(
    By(fn() {
      let vis = if bar_nav_gesturing() {
        app.nav.root_progress(fn() { app.nav.slide_moment(holder) })
      } else {
        bar.vis.at(bar_moment(holder, Vis, bar.vis.end())).0
      }
      vis * @sf.sheet_foot_alpha(holder)
    }),
  )
  |> ignore
  holder
  .moved_by(
    fn(_, _, t) {
      bar_part_said(Vis)
      let v = if bar_nav_gesturing() {
        app.nav.root_progress(fn() { t })
      } else {
        bar.vis.at(t).0
      }
      (0.0, (1.0 - v) * bar_drop)
    },
    fn(_, _) {
      bar_part_said(Vis)
      let nav_end = if bar_nav_gesturing() { app.nav.rest() } else { -1.0 }
      dmax(nav_end, bar.vis.end())
    },
  )
  |> ignore
  bar_shadows_node(holder, w, row_top)
  bar_glass_capsule(holder, w, row_top)
  // the action's circle of glass beside the capsule, at the bar's right, growing out of nothing as the place has an
  // action and the capsule gives it room (laid out as it is there, drawn so); closing, it keeps the last action's icon
  // as it shrinks. It is the notch's key: pressed while the place has an action, taken only where it is drawn whole at
  // its moment, no finger on the bar and its menu shut (bar_disc_takes); what it opens opened beside it
  let disc_x = fn() { w() - act_size }
  let disc_y = fn() { row_top() }
  let disc = bar_at(holder, disc_x, disc_y, fn() { act_size }, fn() { act_size }, fn(d) {
    @sf.tab_bar_menu_surface_decorate(
      d.radius(Is(act_size / 2.0)),
      fn() {
        bar_part_said(Menu)
        let t = bar_moment(d, Notch, dmax(bar_k_until(), bar_menu.morph_ends()))
        let spot = if d.pressed() { Some((act_size / 2.0, act_size / 2.0)) } else { None }
        let merge = bar_merge_at(t)
        // (one glass with the capsule while they flow into one: as much the menu's as it is)
        (spot, merge, if merge > 0.0 { 1.0 - bar_menu.tabs_shown_at(t) } else { 0.0 })
      },
      share_when_unmerged=true,
    )
    .presses(By(fn() {
      match bar_told_now.get() {
        Some(t) => t.shown && t.action != ""
        None => false
      }
    }))
    .takes(fn(w, h, at) { if bar_disc_takes(at) { [(0.0, 0.0, w, h)] } else { [] } })
    .on_press(fn() {
      match ws() {
        Some(w) => bar_action_run(src, w, d.cause_at())
        None => ()
      }
    })
    |> ignore
    bar_action_icons(d)
  })
  bar_disc_look(disc)
  // (what its action opens opened beside it: bar_action_run)
  bar_action_anchor.val = Some(disc)
  bar_ball_node(holder)
  bar_indicator_node(holder)
  bar_rows_node(holder)
  bar_places_node(holder, w, row_top)
  bar_lens_node(holder)
  bar_dots_node(holder)
}

///|
/// The icons the notch draws for its actions (bar_action_icon's: 令's and ＋'s alike a ＋).
// kept across runs: a table, never written
let bar_faces : Array[String] = ["plus"]

///|
/// The action's icons in `d` (bar_action_icon's, each 30, in the bar's lit ink, in its middle), one of each action's, made once
/// and drawn (and found on screen by what it draws) only while the action is it (m_face) or another swaps in for it
/// (icon_was; bar_tell: a short scale and fade, 300 ms on the bar's clock, linear; the one going out by 120 ms, the one
/// coming in from 60 ms): none made or let go as the action is another.
fn bar_action_icons(d : @view.View) -> Unit {
  let css : @ui.Ease = Out
  // (how it is drawn, as faint and as large, at node `n`'s moment: coming in, going out, or not there: None)
  let look = fn(n : @view.View, face : String) -> (Double, Double)? {
    bar_part_said(Icon) |> ignore
    let v = bar.icon_swap.at(bar_moment(n, Icon, bar.icon_swap.end())).0
    if face == m_face.val {
      let ms = v * 300.0
      if ms < 300.0 {
        Some((css.at(dclamp((ms - 60.0) / 180.0, 0.0, 1.0)), 0.5 + 0.5 * css.at(dclamp((ms - 60.0) / 240.0, 0.0, 1.0))))
      } else {
        Some((1.0, 1.0))
      }
    } else if face == bar.icon_was && v < 1.0 {
      let p = css.at(dclamp(v * 300.0 / 120.0, 0.0, 1.0))
      Some((1.0 - p, 1.0 - 0.5 * p))
    } else {
      None
    }
  }
  for face in bar_faces {
    d.box(fn(c) {
      c
      .over(Is(true))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .alpha(By(fn() { dclamp((bar.k_at(bar_moment(c, Notch, bar_k_until())) - 0.55) / 0.35, 0.0, 1.0) }))
      |> ignore
      let shown = fn() { look(c, face) }
      let i = @sf.icon_node(c, face, 26.0, By(bar_action_ink), name_now=fn() {
        if shown() is Some(_) {
          face
        } else {
          ""
        }
      })
      i
      .alpha(By(fn() { shown().map(fn(s) { s.0 }).unwrap_or(0.0) }))
      .scale(By(fn() { shown().map(fn(s) { s.1 }).unwrap_or(1.0) }))
      |> ignore
    })
    |> ignore
  }
}

///|
/// The action's circle: budding smoothly out from inside the capsule's right semicircle with subtle elastic recoil on
/// split/fuse; there still while a finger has the capsule (taking nothing then), as Comma's circle is.
/// Starts strictly inside the capsule (`scale = 0.55`, centered on the capsule's right end) when `k` crosses
/// `bar_disc_k_start` and reaches full size at its resting position by `bar_disc_k_full`, eliminating any single-frame
/// corner pop while preserving full capillary adhesion across separation.
fn bar_disc_look_at(t : Double) -> (Double, Double) {
  let k = bar.k_at(t)
  if k <= bar_disc_k_start {
    (0.0, 0.55)
  } else {
    let u = bar_smoothstep(bar_disc_k_start, bar_disc_k_full, k)
    let alpha = dclamp((k - bar_disc_k_start) / 0.15, 0.0, 1.0)
    let base_scale = 0.55 + 0.45 * u
    let recoil = dclamp(bar.bond_recoil.value_at(t) * 0.25, -0.06, 0.06) * u
    (alpha, dclamp(base_scale + recoil, 0.55, 1.08))
  }
}

///|
/// Horizontal draw offset of the `＋` circle at moment `t` (ms): tucked concentric with the capsule's right semicircle
/// as it begins to bud out and gliding smoothly to `0.0` (its resting layout slot) by `bar_disc_k_full`.
fn bar_disc_dx_at(t : Double) -> Double {
  let k = bar.k_at(t)
  if k >= bar_disc_k_full || k <= 0.0 {
    0.0
  } else {
    let u = bar_smoothstep(bar_disc_k_start, bar_disc_k_full, k)
    -(act_size + act_gap) * k * (1.0 - u)
  }
}

///|
fn bar_disc_look(d : @view.View) -> Unit {
  let look = fn() { bar_disc_look_at(bar_moment(d, Notch, bar_k_until())) }
  d.alpha(By(fn() { look().0 })).scale(By(fn() { look().1 })) |> ignore
  bar_moved(d, Notch, bar_k_until, fn(t) { (bar_disc_dx_at(t), 0.0) })
}

///|
/// The bar's glass as it is drawn at `t` on the bar laid out as `l` (the bar's node's terms): where its left and its top
/// are, how long and how high, how round. As long as the capsule is with the notch as it is then (scroll-collapse's
/// too), drawn in along the bar by the menu's pinch; its foot the bar's, its top as high as the menu's spring has it;
/// all of it larger about the track's middle as far as a lifted lens grows the bar.
fn bar_glass_at(l : BarLaid, t : Double) -> (Double, Double, Double, Double, Double) {
  let menu = bar_menu
  let cw = bar_cur_capsule_w(l.w, bar.k_at(t), bar.collapse_at(t))
  let inset = cw * (1.0 - menu.major_at(t)) / 2.0
  let gh = menu.height_at(t)
  let g = bar.grown_at(t)
  let mid_x = cw / 2.0
  let mid_y = l.row_top + bar_track / 2.0
  let x = mid_x + (inset - mid_x) * g
  let y = mid_y + (l.panel - gh - mid_y) * g
  let h = gh * g
  (x, y, (cw - 2.0 * inset) * g, h, dmin(rad * g, h / 2.0))
}

///|
/// How a node laid out on the bar's track (the bar `w` wide, its track's top `row_top`) draws its ground as the bar's
/// glass is at `t` (bar_glass_at).
fn bar_glass_shape(l : BarLaid, t : Double) -> @view.GroundShape {
  let (x, y, gw, gh, r) = bar_glass_at(l, t)
  { dx: x, dy: y - l.row_top, dw: gw - l.w, dh: gh - bar_track, corners: Some((r, r, r, r)) }
}

///|
/// Preceding outside-only shadows for the capsule and `＋` action circle, kept in a sibling layer before both glass
/// nodes so `sd_group` adjacency is never broken and the `＋` shadow fades in smoothly with separation (never bleeding
/// dark shadow into the capsule while merged).
fn bar_shadows_node(holder : @view.View, w : () -> Double, row_top : () -> Double) -> Unit {
  holder.box(fn(shadows) {
    shadows.over(Is(true)) |> ignore
    bar_at(shadows, fn() { 0.0 }, row_top, w, fn() { bar_track }, fn(cs) {
      cs
      .radius(Is(rad))
      .shadow(By(bar_shadow))
      .shadow_outside(Is(true))
      .ground_drawn(By(fn() { bar_glass_shape(bar_laid_now(), bar_all_moment(cs)) }))
      |> ignore
    })
    |> ignore
    bar_at(shadows, fn() { w() - act_size }, row_top, fn() { act_size }, fn() { act_size }, fn(ds) {
      let at = fn() { bar_moment(ds, Notch, bar_k_until()) }
      ds
      .radius(Is(act_size / 2.0))
      .shadow(By(bar_shadow))
      .shadow_outside(Is(true))
      .alpha(By(fn() {
        let t = at()
        let k = bar.k_at(t)
        if k <= 0.001 {
          0.0
        } else {
          let gap = (act_size + act_gap) * k - act_size
          let u = dclamp(gap / bar_bond_break_gap, 0.0, 1.0)
          u * u * (3.0 - 2.0 * u)
        }
      }))
      .scale(By(fn() { bar_disc_look_at(at()).1 }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The shadow round the bar's glass on the page (@sf.glass_control_shadow: light/dark separated), outside its outline
/// only: the glass bends nothing of it.
fn bar_shadow() -> (Double, Double, Int64) {
  @sf.glass_control_shadow()
}

///|
/// The ink of the action's icon: the bar's places' lit ink (@sf.bar_place_node's).
fn bar_action_ink() -> Int64 {
  if @sf.theme().dark {
    0xFFFFFFFFL
  } else {
    0x111827FFL
  }
}

///|
/// The bar's glass (glass_tab_bar's), laid out on the bar's track and drawn as the glass is at each frame's moment
/// (bar_glass_at): as long as the capsule, grown up into the menu and drawn in along the bar as far as its springs
/// have it, round at its ends. The same glass all the way: only what hides the page so the menu's rows read comes in
/// as the tab row leaves (@sf.tab_bar_menu_surface_decorate: its blur and its tint's weight), the edge's light and its
/// bending the bar's throughout.
fn bar_glass_capsule(holder : @view.View, w : () -> Double, row_top : () -> Double) -> Unit {
  bar_at(holder, fn() { 0.0 }, row_top, w, fn() { bar_track }, fn(g) {
    @sf.tab_bar_menu_surface_decorate(g.radius(Is(rad)), fn() {
      let t = bar_all_moment(g)
      (None, bar_merge_at(t), 1.0 - bar_menu.tabs_shown_at(t))
    })
    .ground_drawn(By(fn() { bar_glass_shape(bar_laid_now(), bar_all_moment(g)) }))
    |> ignore
  })
  |> ignore
}

///|
/// The ball as drawn at moment `t`: its middle across, how much its speed stretches it along its way and lowers it, how
/// faint, how large it is coming or going, how far it is held, how far the notch is open then (how wide a place is).
priv struct BallAt {
  cx : Double
  sx : Double
  sy : Double
  alpha : Double
  scale : Double
  held : Double
  drag_held : Double
  k : Double
  collapse : Double
}

///|
/// The box the ball and its lens are drawn in about their middle.
let ball_box_w : Double = 160.0

///|
let ball_box_h : Double = 96.0

///|
/// The ball at moment `t` with iOS 27.0 `_UIFlexInteraction` volume-preserving jelly scale (`sx`, `sy`).
fn bar_ball_at(t : Double) -> BallAt {
  let m = bar
  let (x, _) = m.ball_x.at(t)
  let flex = m.flex_at(t)
  let (sx, sy) = if flex >= 0.0 {
    (1.0 + flex, dmax(0.76, 1.0 - 1.38 * flex))
  } else {
    (dmax(0.81, 1.0 + flex), dmin(1.19, 1.0 - 1.12 * flex))
  }
  {
    cx: x,
    sx,
    sy,
    alpha: m.ball_alpha.at(t).0,
    scale: m.ball_scale.at(t).0,
    held: m.lift_at(t),
    drag_held: if bar_lens_on.val { m.ball_held_at(t) } else { 0.0 },
    k: m.k_at(t),
    collapse: m.collapse_at(t),
  }
}

///|
/// How wide and high the ball `a` is drawn on the bar laid out as `l`: at rest the selection, as wide as its place and
/// past it to the pill's inset at the bar's ends (ShellTabBar.kt pillWidthFor), lifted into its lens as far as it is
/// held, taller than the bar and wider than a place (TabBarLens.kt lensSize, lensLiftedWidth); scaled by
/// `_UIFlexInteraction` (lifted, stretched and squashed whole; flat, only ever narrower and taller, as the selection
/// was). The selection and the lens are one thing, so one size.
fn bar_ball_size(a : BallAt, l : BarLaid) -> (Double, Double) {
  let iw = bar_item_w(l.w, a.k, l.items.length())
  let pw = iw + 2.0 * (tab_edge - pill_inset)
  let lh = bar_track * lens_lift_h
  let lw = dmin(lh * lens_lift_aspect, iw * lens_lift_aspect)
  let up = dclamp(a.held, 0.0, 1.0)
  let w = pw + (lw - pw) * up
  let h = pill_h + (lh - pill_h) * up
  let sx = if a.sx > 1.0 { 1.0 + (a.sx - 1.0) * up } else { a.sx }
  let sy = if a.sy < 1.0 { 1.0 + (a.sy - 1.0) * up } else { a.sy }
  (w * sx, dmax(8.0, h * sy))
}

///|
/// The frame `(cx, cy, sw, sh)` of the selection and the lens it lifts into, in the bar as it lies at rest (before the
/// bar's own growth), with elastic inner-wall clamping inside the glass capsule so the flat selection never overflows
/// `[0, cap_w]` (the lifted lens overhangs by as much as it is larger).
fn bar_ball_frame(a : BallAt, l : BarLaid) -> (Double, Double, Double, Double) {
  let (sw_raw, sh_raw) = bar_ball_size(a, l)
  let cy = l.row_top + bar_track / 2.0
  if l.w > 0.0 && l.items.length() > 0 && a.collapse < 0.5 {
    let cap_w = bar_cur_capsule_w(l.w, a.k, a.collapse)
    let iw = bar_item_w(l.w, a.k, l.items.length())
    let pw = iw + 2.0 * (tab_edge - pill_inset)
    let lh = bar_track * lens_lift_h
    let lw = dmin(lh * lens_lift_aspect, iw * lens_lift_aspect)
    let lens_over = dmax(0.0, (lw - pw) / 2.0) * dclamp(a.held, 0.0, 1.0) +
      12.0 * dclamp(a.drag_held, 0.0, 1.0) +
      dmax(0.0, (sw_raw - lw) / 2.0) * dclamp(a.held, 0.0, 1.0)
    let min_x = 2.0 - lens_over
    let max_x = dmax(10.0, cap_w - 2.0 + lens_over)
    let left = dclamp(a.cx - sw_raw / 2.0, min_x, max_x - 8.0)
    let right = dclamp(a.cx + sw_raw / 2.0, left + 8.0, max_x)
    ((left + right) / 2.0, cy, right - left, sh_raw)
  } else {
    (a.cx, cy, sw_raw, sh_raw)
  }
}

///|
/// The selection's (and its lens's) frame on screen at `t`: bar_ball_frame's, grown about the track's middle with the
/// pressed bar, and drawn in along the bar with the glass on its way to the menu (as the tab row is).
fn bar_ball_shown_at(l : BarLaid, t : Double) -> (Double, Double, Double, Double) {
  let a = bar_ball_at(t)
  let (cx, cy, sw, sh) = bar_ball_frame(a, l)
  let g = bar.grown_at(t)
  let gx = g * bar_menu.major_at(t)
  let mid = bar_cur_capsule_w(l.w, a.k, a.collapse) / 2.0
  (mid + (cx - mid) * gx, cy, sw * gx * a.scale, sh * g * a.scale)
}

///|
/// A capsule in `parent` drawn where `frame` has it at the moment each frame is drawn (its middle, how wide, how high:
/// the bar's node's terms), as round as the shorter, as faint as `alpha` has it then; made by `f`. Laid out round where
/// the ball rests, drawn where it is.
fn bar_ball_capsule(
  parent : @view.View,
  frame : (Double) -> (Double, Double, Double, Double),
  alpha : (Double) -> Double,
  f : (@view.View) -> Unit,
) -> Unit {
  let rest_y = fn() { bar_laid_now().row_top + bar_track / 2.0 }
  parent.box(fn(o) {
    o.over(Is(true)) |> ignore
    o.box(fn(b) {
      b
      .width(Is(Some(ball_box_w)))
      .height(Is(Some(ball_box_h)))
      // (laid out where it goes, drawn where it is)
      .offset(By(fn() {
        bar_part_said(Ball) |> ignore
        (bar.ball_x.to - ball_box_w / 2.0, rest_y() - ball_box_h / 2.0)
      }))
      .alpha(By(fn() { alpha(bar_all_moment(b)) }))
      |> ignore
      bar_all_moved(b, fn(t) {
        let (cx, cy, _, _) = frame(t)
        (cx - bar.ball_x.to, cy - rest_y())
      })
      b.box(fn(s) {
        s.over(Is(true)) |> ignore
        // (as wide and as high as it is drawn about its middle, as round as the shorter)
        s
        .ground_drawn(
          By(fn() {
            let (_, _, sw, sh) = frame(bar_all_moment(s))
            let r = dmin(sw, sh) / 2.0
            {
              dx: (ball_box_w - sw) / 2.0,
              dy: (ball_box_h - sh) / 2.0,
              dw: sw - ball_box_w,
              dh: sh - ball_box_h,
              corners: Some((r, r, r, r)),
            }
          }),
        )
        .radius(Is(pill_h / 2.0))
        |> ignore
        f(s)
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The selection under the place shown (ShellTabBar.kt's Selection: a grey of the glass by day, a well sunk into it by
/// night, @sf.tab_selection), where its lens is and as large (one thing with it: bar_ball_shown_at), stretched by its
/// speed toward where it goes. It goes as the lens lifts over it and shows again as the lens lands
/// (BarModel::pill_alpha_at); while the bar is its menu it shows as the tab row does.
fn bar_ball_node(holder : @view.View) -> Unit {
  bar_ball_capsule(
    holder,
    fn(t) { bar_ball_shown_at(bar_laid_now(), t) },
    fn(t) {
      let a = bar_ball_at(t)
      a.alpha * bar.pill_alpha_at(t) * dclamp(1.0 - a.collapse / 0.25, 0.0, 1.0)
    },
    fn(g) { g.ground(By(@sf.tab_selection)) |> ignore },
  )
}

///|
/// The menu's indicator in the bar's node's terms at `t`: where its left and top are, how wide and high (BarMenu::ind_at,
/// in the glass as it is then, drawn in along the bar with it), how much of its grey shows, and how much of the clear
/// lens it began as.
fn bar_ind_shown_at(l : BarLaid, t : Double) -> (Double, Double, Double, Double, Double, Double) {
  let menu = bar_menu
  let k = bar.k_at(t)
  let cw = bar_cur_capsule_w(l.w, k, 0.0)
  let i = menu.ind_at(t, cw, bar_rest_selection(l, l.more_slot(), k))
  let scale = menu.major_at(t)
  let left = cw * (1.0 - scale) / 2.0 + i.l * scale
  let top = l.panel - menu.height_at(t) + i.t
  (left, top, (i.r - i.l) * scale, i.b - i.t, i.alpha * i.grey, i.alpha * i.clear)
}

///|
/// The ball in the finger: a lens of clear liquid glass the selection lifts into (TabBarLens.kt's), taller than the bar
/// and wider than a place, what is under its rim bent; it magnifies nothing itself (the bar zooms each glyph in place as
/// it comes over it: bar_places_node). One thing with the selection: from the moment it lifts it lies over the
/// selection whole, the same frame, and what makes it glass (its bending, its edge, its shadow) comes in with its lift;
/// flat it draws nothing, and the selection under it is all there is. Handed to the menu, the indicator carries it,
/// clearing as the grey comes in. Where glass is not liquid (Frosted or Solid) there is nothing to bend: the selection
/// alone.
fn bar_lens_node(holder : @view.View) -> Unit {
  holder.box(fn(b) {
    b.over(Is(true)) |> ignore
    b.show(
      at_once=true,
      fn() {
        let on = !b.glass_solid() && @ui.glass_material() == Liquid
        bar_lens_on.val = on
        on
      },
      fn(on) {
        on.over(Is(true)) |> ignore
        // (how far it is a glass at `t`: its own lift, or what it had as the indicator took it)
        let press_at = fn(t : Double) { if bar_menu.carry >= 0.0 { bar_menu.carry } else { bar.lift_at(t) } }
        bar_ball_capsule(
          on,
          fn(t) {
            let l = bar_laid_now()
            if bar_menu.carry >= 0.0 {
              let (x, y, w, h, _, _) = bar_ind_shown_at(l, t)
              (x + w / 2.0, y + h / 2.0, w, h)
            } else {
              bar_ball_shown_at(l, t)
            }
          },
          fn(t) {
            if bar_menu.carry >= 0.0 {
              let (_, _, _, _, _, clear) = bar_ind_shown_at(bar_laid_now(), t)
              if clear <= 0.01 { 0.0 } else { clear }
            } else {
              let a = bar_ball_at(t)
              if a.held > 0.0 { a.alpha * dclamp(1.0 - a.collapse / 0.4, 0.0, 1.0) } else { 0.0 }
            }
          },
          fn(g) {
            @sf.tab_lens_still_surface_decorate(g, fn() { press_at(bar_all_moment(g)) }) |> ignore
            g
            .shadow(By(fn() {
              let h = dclamp(press_at(bar_all_moment(g)), 0.0, 1.0)
              if @sf.theme().dark || h <= 0.001 {
                (0.0, 0.0, 0L)
              } else {
                // (as far and as soft as it is lifted, and as dark as it is a glass: there by half its lift)
                let r = @sf.tab_lens_raised_for(false)
                let a = ((r.color & 0xFFL).to_double() * dclamp(h / 0.5, 0.0, 1.0)).round().to_int64()
                (r.sigma * h, r.dy * h, (r.color & 0xFFFFFF00L) | a)
              }
            }))
            .shadow_outside(Is(true))
            |> ignore
          },
        )
      },
    )
  })
  |> ignore
}

///|
/// The menu's indicator: the grey a row lies on (the selection's ground), where BarMenu::ind_at has it as each frame is
/// drawn: it starts as the lifted lens or as the bar's selection on the last slot, travels to the row pointed at as the
/// glass grows, follows a finger from row to row, and as the menu folds back fades on its row or lands on the last
/// slot as the bar's selection.
fn bar_indicator_node(holder : @view.View) -> Unit {
  holder.box(fn(b) {
    b.over(Is(true)) |> ignore
    b.show(at_once=true, fn() { !bar_laid_now().menu.is_empty() }, fn(on) {
      on.over(Is(true)) |> ignore
      on.box(fn(i) {
        let at = fn() { bar_ind_shown_at(bar_laid_now(), bar_all_moment(i)) }
        i
        .over(Is(true))
        .ground(By(@sf.tab_selection))
        .alpha(By(fn() { at().4 }))
        .ground_drawn(
          By(fn() {
            let l = bar_laid_now()
            let (x, y, w, h, _, _) = at()
            let r = dmin(w, h) / 2.0
            { dx: x, dy: y, dw: w - l.w, dh: h - l.panel, corners: Some((r, r, r, r)) }
          }),
        )
        |> ignore
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// The menu's rows (@sf.bar_menu_node: each a place of the menu, its icon and its name; a key's and a screen reader's
/// to press, the hand's the bar's own), cut to the glass as it is drawn: they ride the glass's top edge, each rising
/// into its place in turn from the row nearest the bar as the menu opens (BarMenu::row_at), blurred until it is whole;
/// as the menu folds back they leave together by how far the glass has folded (BarMenu::rows_shown_at). Made as the
/// menu opens and let go once it has folded back: none of them while the bar is the bar.
fn bar_rows_node(holder : @view.View) -> Unit {
  let menu = bar_menu
  holder.box(fn(b) {
    b.over(Is(true)) |> ignore
    b.show(
      at_once=true,
      fn() {
        !bar_laid_now().menu.is_empty() &&
        (menu.open.get() || bar_moment(b, Menu, menu.morph_ends()) != @double.infinity)
      },
      fn(cut) {
      let row_top = fn() { bar_laid_now().row_top }
      cut
      .over(Is(true))
      .padding(By(fn() { (0.0, row_top(), 0.0, 0.0) }))
      |> ignore
      // (laid out on the bar's track, drawn and cut as the glass is)
      cut.box(fn(win) {
        win
        .height(Is(Some(bar_track)))
        .radius(Is(rad))
        .clips(Is(true))
        .ground_drawn(By(fn() { bar_glass_shape(bar_laid_now(), bar_all_moment(win)) }))
        |> ignore
        win.box(fn(rows) {
          let shown = fn(n : @view.View) { menu.rows_shown_at(bar_moment(n, Menu, bar_menu_until())) }
          rows
          .over(Is(true))
          .width(By(fn() {
            bar_part_said(Notch)
            Some(bar_capsule_w(bar_laid_now().w, bar.k_end()))
          }))
          .height(By(fn() { Some(bar_laid_now().panel) }))
          .offset(By(fn() { (0.0, -row_top()) }))
          .alpha(By(fn() { shown(rows) }))
          .content_lens(
            By(fn() {
              @sf.bar_morph_lens(shown(rows), morph_blur)
            }),
          )
          |> ignore
          // (the rows ride the glass's top edge)
          bar_moved(rows, Menu, bar_menu_until, fn(t) { (0.0, bar_laid_now().panel - menu.height_at(t)) })
          @sf.bar_menu_node(
            rows,
            fn() { bar_laid_now().menu },
            place_icon,
            fn(key) {
              if key == "stations" {
                Some(fn() { bar_place_marks.get().glance })
              } else {
                None
              }
            },
            place_label,
            fn() { tr("android-misc.bar.menu") },
            fn() { menu.open.get() },
            fn(key, n) {
              let at = n.cause_at()
              match key {
                Some(k) => bar.pick_row(bar_laid_now().menu.search(k).unwrap_or(-1), at)
                None => bar.close_menu(at)
              }
              bar_retell(at)
            },
            fn(row, key) {
              let i = fn() { bar_laid_now().menu.search(key).unwrap_or(0) }
              let own = fn(n : @view.View) { menu.row_at(i(), bar_moment(n, Menu, bar_menu_until())) }
              row
              .alpha(By(fn() { own(row).1 }))
              .content_lens(
                By(fn() {
                  @sf.bar_morph_lens(own(row).1, morph_blur)
                }),
              )
              |> ignore
              bar_moved(row, Menu, bar_menu_until, fn(t) { (0.0, menu.row_at(i(), t).0) })
            },
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
      },
    )
  })
  |> ignore
}

///|
/// What the bar's places say of the workspace in view (read while the bar is: bar_place_marks_node): a station
/// in trouble, a remote agent lit, the stations at a glance and in words.
#derive(Eq)
priv struct BarPlaceMarks {
  trouble : Bool
  remote : Bool
  glance : @sf.GlyphCounts
  said : String
}

///|
/// None said yet.
// kept across runs: a value (no field of it changes)
let bar_place_marks_none : BarPlaceMarks = {
  trouble: false,
  remote: false,
  glance: { online: 0, dim: 0, failing: 0, working: 0, asleep: false, connecting: 0 },
  said: "",
}

///|
/// The bar's marks as the workspace in view last said them (bar_place_marks_node), what each place reads.
// kept across runs: said again as the bar is made (bar_place_marks_node)
let bar_place_marks : @signals.Signal[BarPlaceMarks] = @signals.signal(bar_place_marks_none, same=fn(a, b) { a == b })

///|
/// The bar's marks told in node `b` as the workspace in view `ws` says them (the chats' trouble, a remote agent, the
/// stations at a glance): read all along while the bar is there, shown or not.
fn bar_place_marks_node(b : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  b.reacts(
    fn() {
      match ws() {
        Some(w) => {
          let (glance, said) = stations_at_glance(src, w.id)
          {
            trouble: field(chats_topic(src, w.id).value, "trouble") is Some(Object(_)),
            remote: @sfpages.remote_agent_lit(src, w.id),
            glance,
            said,
          }
        }
        None => bar_place_marks_none
      }
    },
    fn(m) { bar_place_marks.set(m) },
  )
}

///|
/// What a screen reader says of place `key` (Station's, the stations in words).
fn bar_said_of(key : String) -> String {
  let said = if key == "stations" { bar_place_marks.get().said } else { "" }
  if said != "" {
    said
  } else {
    place_label(key)
  }
}

///|
/// Place `key`'s dot: a station in trouble (red) on Station's, a remote agent lit (the accent) on 远程's; none else.
fn bar_dot_of(key : String) -> Int64 {
  match key {
    "stations" => if bar_place_marks.get().trouble { @sf.theme().p.red } else { 0L }
    "remote" => if bar_place_marks.get().remote { @sf.theme().p.primary } else { 0L }
    _ => 0L
  }
}

///|
/// A place of the bar or the panel (place_at's) in `at`, its slot 44 high round its middle, as the library draws one
/// (@sf.bar_place_node): lit as far as `lit_at` has it as each frame is drawn, its dot, read out by its name.
fn bar_face_node(
  at : @view.View,
  key : String,
  part : BarPart,
  lit_at : (Double) -> Double,
  lit_until : () -> Double,
) -> Unit {
  @sf.bar_place_node(
    at,
    place_icon(key),
    if key == "stations" {
      Some(fn() { bar_place_marks.get().glance })
    } else {
      None
    },
    fn(n) { lit_at(bar_moment(n, part, lit_until())) },
    // (its dot is drawn over the lens and the menu, not here: bar_dots_node)
    fn() { 0L },
    fn() { bar_said_of(key) },
  )
}

///|
/// Slot `i`'s middle across as it is drawn at `t` on the bar laid out as `l`: where the notch has it then, gathered into
/// the left orb as far as the bar is scroll-collapsed, off the track's middle as far as a lifted lens grows the bar, and
/// drawn in along the bar with the glass on its way to the menu.
fn bar_slot_cx_at(l : BarLaid, i : Int, t : Double) -> Double {
  let k = bar.k_at(t)
  let c = bar.collapse_at(t)
  let exp_cx = bar_centres(l.w, k, l.items.length())[i]
  let cx = exp_cx + (bar_track / 2.0 - exp_cx) * c
  let mid = bar_cur_capsule_w(l.w, k, c) / 2.0
  mid + (cx - mid) * bar.grown_at(t) * bar_menu.major_at(t)
}

///|
/// How large slot `i`'s glyph is drawn at `t` (1: as laid out), `shown` whether it is the place shown: a little
/// smaller as the bar scroll-collapses round the place shown, larger with the pressed bar, and larger again, in place,
/// under the lifted lens (BarModel::zoom_at); one the lens is not over is neither moved nor scaled by it.
fn bar_slot_scale_at(l : BarLaid, i : Int, shown : Bool, t : Double) -> Double {
  let c = bar.collapse_at(t)
  let folded = if c <= 0.0001 || shown { 1.0 } else { 1.0 - 0.12 * c }
  folded * bar.grown_at(t) * bar.zoom_at(l, i, t)
}

///|
/// The bar's places over the selection: each its slot round its middle, lit as far as it is as each frame is drawn,
/// placed where the notch has it as each frame is drawn (drawn and read out there; nothing laid out for it), the last
/// slot the menu's where there is one (@sf.bar_more_node: the menu's place it stands for and a chevron). The tab row is
/// cut to the glass as it is drawn, and leaves as the glass grows into the menu: fading and blurring out over the
/// first of its growth (BarMenu::tabs_shown_at).
fn bar_places_node(
  holder : @view.View,
  w : () -> Double,
  row_top : () -> Double,
) -> Unit {
  let menu = bar_menu
  let items = fn() { bar_laid_now().items }
  // (the slots that are a place's own: all of them but the menu's)
  let fixed = fn() {
    let l = bar_laid_now()
    if l.menu.is_empty() {
      l.items
    } else {
      l.items[0:l.items.length() - 1].to_owned()
    }
  }
  let slot = fn(n : Int) -> Double { bar_slot(w(), n) }
  let is_active = fn(i : Int) { bar_active_slot_told.get() == i }
  // (slot `i` in node `at`, laid out where the notch is going, drawn where it is)
  let x_laid = fn(i : Int) {
    bar_part_said(Notch) |> ignore
    bar_centres(w(), bar.k_end(), items().length())[i] - slot(items().length()) / 2.0
  }
  let slot_look = fn(at : @view.View, i : () -> Int) {
    at
    .alpha(By(fn() {
      let c = bar.collapse_at(bar_moment(at, Collapse, bar.collapse.ends_at()))
      if c <= 0.0001 || is_active(i()) {
        1.0
      } else {
        dclamp(1.0 - c / 0.30, 0.0, 1.0)
      }
    }))
    .scale(By(fn() { bar_slot_scale_at(bar_laid_now(), i(), is_active(i()), bar_all_moment(at)) }))
    |> ignore
    bar_all_moved(at, fn(t) {
      (bar_slot_cx_at(bar_laid_now(), i(), t) - slot(items().length()) / 2.0 - x_laid(i()), 0.0)
    })
  }
  holder.box(fn(row) {
    let shown = fn() { menu.tabs_shown_at(bar_moment(row, Menu, menu.morph_ends())) }
    row
    .over(Is(true))
    .width(By(fn() { Some(w()) }))
    .height(Is(Some(bar_track)))
    .offset(By(fn() { (0.0, row_top()) }))
    .radius(Is(rad))
    .clips(Is(true))
    .ground_drawn(By(fn() { bar_glass_shape(bar_laid_now(), bar_all_moment(row)) }))
    .alpha(By(shown))
    .content_lens(By(fn() { @sf.bar_morph_lens(shown(), morph_blur) }))
    |> ignore
    row.each(at_once=true, fixed, fn(k) { k }, fn(p, key) {
      let key = key.untracked()
      let i = fn() { items().search(key).unwrap_or(0) }
      bar_at(p, fn() { x_laid(i()) }, fn() { (bar_track - 44.0) / 2.0 }, fn() { slot(items().length()) }, fn() { 44.0 }, fn(at) {
        slot_look(at, i)
        bar_face_node(at, key, Tints, fn(t) { bar_tint_at("bar:" + key, t) }, fn() { bar_tint_until("bar:" + key) })
      })
      |> ignore
    })
    row.show(at_once=true, fn() { !bar_laid_now().menu.is_empty() }, fn(p) {
      p.over(Is(true)) |> ignore
      let i = fn() { bar_laid_now().more_slot() }
      let more = fn() {
        let l = bar_laid_now()
        if l.menu.is_empty() { "" } else { l.items[l.items.length() - 1] }
      }
      bar_at(p, fn() { x_laid(i()) }, fn() { (bar_track - 44.0) / 2.0 }, fn() { slot(items().length()) }, fn() { 44.0 }, fn(at) {
        slot_look(at, i)
        @sf.bar_more_node(
          at,
          fn() { place_icon(more()) },
          fn() { if more() == "stations" { Some(bar_place_marks.get().glance) } else { None } },
          fn(n) {
            bar_part_said(Tints)
            let id = "bar:" + more()
            bar_tint_at(id, n.drawn_while(fn(t) { t < bar_tint_until(id) }))
          },
          fn() { tr("android-misc.bar.more", args=[("name", bar_said_of(more()))]) },
          fn() { menu.open.get() },
          // (pressed by a key or a screen reader: the menu opened with its rows the keys', or folded back)
          fn(n) {
            let t = n.cause_at()
            if menu.open.untracked() {
              bar.close_menu(t)
            } else {
              bar.press_slot = -1
              bar.open_menu(false, 0.0, t)
            }
            bar_retell(t)
          },
        )
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// Slot `i`'s dot (0: none): its place's (bar_dot_of); the last slot's, with a menu, the first of the menu's places'
/// that has one, whichever of them it shows.
fn bar_slot_dot(l : BarLaid, i : Int) -> Int64 {
  if i >= l.items.length() {
    0L
  } else if i == l.more_slot() {
    for key in l.menu {
      let d = bar_dot_of(key)
      if d != 0L {
        return d
      }
    }
    0L
  } else {
    bar_dot_of(l.items[i])
  }
}

///|
/// The slots' dots, over the lens and the menu: a dot is the owner's mark on a tab, and no glass bends or covers it.
/// Each on its glyph's top trailing corner, where the tab row puts that glyph now (grown with the pressed bar and drawn
/// in with the glass), showing as much as the tab row does (ShellTabBar.kt placeDots).
fn bar_dots_node(holder : @view.View) -> Unit {
  let menu = bar_menu
  // (a dot's middle from its glyph's: up and to its trailing side)
  let reach_x = 13.5
  let reach_y = 12.5
  holder.box(fn(b) {
    b.over(Is(true)) |> ignore
    for i in 0..<bar_slots_most {
      b.show(at_once=true, fn() { bar_slot_dot(bar_laid_now(), i) != 0L }, fn(on) {
        on.over(Is(true)) |> ignore
        let laid_x = fn() {
          bar_part_said(Notch) |> ignore
          let l = bar_laid_now()
          bar_centres(l.w, bar.k_end(), l.items.length())[i] + reach_x - 3.5
        }
        let laid_y = fn() { bar_laid_now().row_top + bar_track / 2.0 - reach_y - 3.5 }
        let dot = bar_at(on, laid_x, laid_y, fn() { 7.0 }, fn() { 7.0 }, fn(d) {
          d
          .radius(Is(1.0e6))
          .ground(By(fn() { bar_slot_dot(bar_laid_now(), i) }))
          .alpha(By(fn() {
            let t = bar_all_moment(d)
            let c = bar.collapse_at(t)
            let active = bar_active_slot_told.get() == i
            let folded = if c <= 0.0001 || active { 1.0 } else { dclamp(1.0 - c / 0.30, 0.0, 1.0) }
            menu.tabs_shown_at(t) * folded
          }))
          |> ignore
        })
        bar_all_moved(dot, fn(t) {
          let l = bar_laid_now()
          if i >= l.items.length() {
            return (0.0, 0.0)
          }
          let g = bar.grown_at(t)
          let cx = bar_slot_cx_at(l, i, t) + reach_x * g * menu.major_at(t)
          let cy = l.row_top + bar_track / 2.0 - reach_y * g
          (cx - 3.5 - laid_x(), cy - 3.5 - laid_y())
        })
      })
    }
  })
  |> ignore
}
