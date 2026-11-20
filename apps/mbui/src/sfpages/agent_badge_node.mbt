// The badge at the corner of an agent's mark as nodes (agent_mark.mbt's agent_badge), where a chat's bar draws it.

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
/// one. Its spokes turned only once it has first been at work.
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
            (now, @sf.theme().p.bg, ink)
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
