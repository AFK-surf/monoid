// An agent's mark (still.fail web/src/ui.tsx AgentMark, ui.css.ts agentMark): its model's maker on a tile of the neutral
// ground, its corner .3 of its side; where it stands a mark at the corner, the chat list's own (chat_mark.mbt): yellow
// spokes stepping round at work, blue when it waits on a person, red when it failed, ringed in the ground it is on.

///|
/// How large the maker's mark is on its tile (ui.tsx: .62 of it, rounded).
let agent_logo_of : Double = 0.62

///|
/// A tile of the neutral ground, what is on it in its middle (its side and corner the mark's).
// kept across runs: a value (no field of it changes)
let agent_tile : @ui.Style = @ui.css("bg=Neutral align=ACenter justify=JCenter")

///|
/// `maker`'s mark (of `runtime`) on its tile `side` across, as agent_mark has it, as a node in `parent`: as the two say
/// now; its `badge` at its corner ("" none), ringed in `ground` (what it stands on: agent_badge's).
pub fn agent_mark_node(
  parent : @view.View,
  maker : () -> String,
  runtime : () -> String,
  side : Double,
  badge? : String = "",
  ground? : () -> Int64 = fn() { @sf.theme().p.bg },
) -> Unit {
  parent.box(fn(t) {
    @sf.style_node(t, fn() { agent_tile.then(@ui.style(w=Fixed(side), h=Fixed(side), radius=@sf.agent_mark_corner(side))) }, in_row=true)
    t.shrink(Is(0.0)) |> ignore
    t.pick(fn() { (maker(), runtime()) }, fn(m, k) {
      @sf.maker_mark_node(m, k.0, k.1, (side * agent_logo_of).round()) |> ignore
    })
    agent_badge_node(t, badge, side, ground~)
  })
  |> ignore
}
