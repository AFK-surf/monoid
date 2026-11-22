// The badge at the corner of an agent's mark as nodes (agent_mark.mbt's agent_badge), where a chat's bar draws it.

///|
/// Agents of a chat grouped by the station they run on, preserving order of appearance.
#derive(Eq)
pub(all) struct StationAgentGroup {
  station : String
  agents : Array[@sfbase.Agent]
}

///|
/// Groups `agents` by their station (`default_station` while `Agent` has no per-agent station field).
/// Returns an empty array when `agents` is empty so callers render the standalone station capsule.
pub fn group_agents_by_station(agents : Array[@sfbase.Agent], default_station : String) -> Array[StationAgentGroup] {
  if agents.length() == 0 {
    return []
  }
  [{ station: default_station, agents }]
}

///|
/// The badge at the corner of an agent's mark `side` across (sfpages' agent_badge, as nodes): a dot ringed in the
/// page's ground (or `ground`: what the mark stands on, as agent_badge's), blue waiting on a person, red failed; yellow
/// spokes at work. A chat's bar's on every screen (小屏's chat_bar_node, 中屏's and 大屏's chat_bar_wide_node), a chat's
/// info's (its panel's ground).
pub fn agent_badge_node(
  v : @view.View,
  badge : String,
  side : Double,
  ground? : () -> Int64 = fn() { @sf.theme().p.bg },
) -> Unit {
  guard badge == "block" || badge == "failed" || badge == "run" else { return }
  v.box(fn(r) { agent_badge_in(r, badge, side, ground~) }) |> ignore
}

///|
/// Node `r`, over the corner of an agent's mark `side` across, drawn as its badge `badge` (agent_badge_node's: the
/// node itself, none made round it; nothing for none): what changes it in place makes it so again (a chat's bar's
/// pick by the badge).
pub fn agent_badge_in(
  r : @view.View,
  badge : String,
  side : Double,
  ground? : () -> Int64 = fn() { @sf.theme().p.bg },
) -> Unit {
  let k = if side / 20.0 < 1.0 { side / 20.0 } else { 1.0 }
  match badge {
    "block" | "failed" => {
      let d = 12.0 * k
      let at = side - d + 3.0 * k
      r
      .over(Is(true))
      .width(Is(Some(d)))
      .height(Is(Some(d)))
      .offset(Is((at, at)))
      .radius(Is(d / 2.0))
      .padding(Is((2.0 * k, 2.0 * k, 2.0 * k, 2.0 * k)))
      .ground(By(ground))
      |> ignore
      r.box(fn(dot) {
        let ink = if badge == "block" { @sf.mark_blue } else { @sf.mark_red }
        dot.grow(Is(1.0)).radius(Is(d / 2.0)).ground(By(fn() { @ui.tree_theme().color(ink) }))
        |> ignore
      })
      |> ignore
    }
    "run" => {
      let d = 10.0 * k
      let at = side - d + 2.0 * k
      r.over(Is(true)).width(Is(Some(d))).height(Is(Some(d))).offset(Is((at, at))) |> ignore
      @sf.spokes_node(r, d, @sf.mark_yellow) |> ignore
    }
    // (none: over it, of no size, nothing drawn)
    _ => r.over(Is(true)).width(Is(Some(0.0))).height(Is(Some(0.0))) |> ignore
  }
}

///|
/// The badge at the corner of mark `m` (`side` across) as `badge` says it now: two nodes, its ground's and what is drawn
/// in it (a dot, or the spokes), each told again in place as it comes to another, laid out nowhere while it has none
/// (agent_badge_in's looks, by one binding); none made while it has none, as most marks have, till it first comes to
/// one. Its spokes turned only once it has first been at work. Its dot ringed in the capsule's ground
/// (capsule_badge_ground): it is drawn only on a mark in a capsule above a chat's composer.
pub fn agent_badge_slot(m : @view.View, badge : () -> String, side : Double) -> Unit {
  let k = if side / 20.0 < 1.0 { side / 20.0 } else { 1.0 }
  let made = Ref(false)
  let make = fn() {
    made.val = true
    m.box(fn(r) {
      r.over(Is(true)) |> ignore
      r.box(fn(c) {
        let turning = Ref(false)
        let turn = fn() {
          turning.val = true
          c.turn(By(fn() { if badge() == "run" { @sf.spokes_turn(c) } else { 0.0 } }), drawn=true) |> ignore
        }
        c.sets_together(
          fn() {
            let now = badge()
            let theme = @ui.tree_theme()
            let ink = match now {
              "block" => theme.color(@sf.mark_blue)
              "failed" => theme.color(@sf.mark_red)
              _ => @sf.mark_yellow()
            }
            (now, capsule_badge_ground(), ink)
          },
          fn(said) {
            let (now, ground, ink) = said
            match now {
              "block" | "failed" => {
                let d = 12.0 * k
                let at = side - d + 3.0 * k
                r
                .laid_nowhere(Is(false))
                .width(Is(Some(d)))
                .height(Is(Some(d)))
                .offset(Is((at, at)))
                .radius(Is(d / 2.0))
                .padding(Is((2.0 * k, 2.0 * k, 2.0 * k, 2.0 * k)))
                .ground(Is(ground))
                |> ignore
                c.width(Is(None)).height(Is(None)).grow(Is(1.0)).radius(Is(d / 2.0)).ground(Is(ink)).lines(Is([]))
                |> ignore
              }
              "run" => {
                let d = 10.0 * k
                let at = side - d + 2.0 * k
                r
                .laid_nowhere(Is(false))
                .width(Is(Some(d)))
                .height(Is(Some(d)))
                .offset(Is((at, at)))
                .radius(Is(0.0))
                .padding(Is((0.0, 0.0, 0.0, 0.0)))
                .ground(Is(0L))
                |> ignore
                c.width(Is(Some(d))).height(Is(Some(d))).grow(Is(0.0)).radius(Is(0.0)).ground(Is(0L)).lines(Is(@sf.spokes_lines(d, d, ink)))
                |> ignore
                if !turning.val {
                  turn()
                }
              }
              _ => {
                r.laid_nowhere(Is(true)) |> ignore
                c.lines(Is([])) |> ignore
              }
            }
          },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }
  if @signals.untracked(badge) != "" {
    make()
  } else {
    m.reacts(fn() { badge() != "" }, at_start=false, fn(on) { if on && !made.val && m.alive() { make() } })
  }
}

///|
/// What a badge on a mark in a liquid glass capsule above the composer is ringed in, near the capsule's glass (raised
/// in dark, paper in light) so the ring reads as a cut in the capsule, not a darker or lighter edge round the dot.
fn capsule_badge_ground() -> Int64 {
  let t = @sf.theme()
  if t.dark {
    t.p.raised
  } else {
    t.p.paper
  }
}

///|
/// How a station is reached (`via`: direct, relay, offline; none: "") as a dot's ink: online's, warning's, red's.
fn station_via_ink(via : String) -> Int64 {
  let p = @sf.theme().p
  match via {
    "direct" => p.online
    "relay" => @ui.tree_theme().color(Warn)
    "offline" => p.red
    _ => p.muted
  }
}

///|
/// A station's mark (15pt in a 16 square, the agent's mark's size beside it) with how it is reached (`via`) as a dot
/// on its corner, where an agent's badge sits on its mark (agent_badge_slot's place and ring), in a capsule above a
/// chat's composer (小屏's chat_bar_node, 中屏's and 大屏's chat_bar_wide_node); a station with no mark (no emoji, no
/// icon) has the dot before its name instead. Which of the two is as the station is when it is made, the capsule made
/// again as its station changes. No dot while `via` is "".
pub fn station_via_mark_node(
  parent : @view.View,
  emoji : () -> String,
  icon : () -> String,
  via : () -> String,
  tint : () -> Int64,
  stint : () -> Int,
) -> Unit {
  if !@sf.has_station_mark(@signals.untracked(emoji), @signals.untracked(icon)) {
    station_inline_via_dot(parent, via)
    return
  }
  @sf.station_mark_node(parent, emoji, icon, 15.0, tint, stint, over=fn(m) {
    // (at least the agent's mark's 16 square, a wider emoji or larger words growing it)
    m
    .min_width(Is(Some(16.0)))
    .min_height(Is(Some(16.0)))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .shrink(Is(0.0))
    |> ignore
    // (a 6.4 dot ringed 1.6 in the capsule's ground, 2.4 out past the mark's corner: agent_badge_slot's 12 at 16)
    m.box(fn(d) {
      d
      .over(Is(true), edges=(None, None, Some(-0.8), Some(-0.8)))
      .width(Is(Some(6.4)))
      .height(Is(Some(6.4)))
      .radius(Is(3.2))
      .shrink(Is(0.0))
      .sets_together(
        fn() {
          let v = via()
          (v == "", station_via_ink(v), capsule_badge_ground())
        },
        fn(s) {
          let (hidden, ink, bg) = s
          d
          .laid_nowhere(Is(hidden))
          .ground(Is(if hidden { 0L } else { ink }))
          .ring(Is(if hidden { (0.0, 0.0, 0L) } else { (1.6, 0.0, bg) }))
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
}

///|
/// How a station with no mark is reached (`via`) as a 6 dot before its name (station_via_mark_node's): none while "".
fn station_inline_via_dot(parent : @view.View, via : () -> String) -> Unit {
  parent.box(fn(d) {
    d
    .width(Is(Some(6.0)))
    .height(Is(Some(6.0)))
    .radius(Is(3.0))
    .shrink(Is(0.0))
    .sets_together(fn() { let v = via(); (v == "", station_via_ink(v)) }, fn(s) {
      let (hidden, ink) = s
      d.laid_nowhere(Is(hidden)).ground(Is(if hidden { 0L } else { ink })) |> ignore
    })
    |> ignore
  })
  |> ignore
}
