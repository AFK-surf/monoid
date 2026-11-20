// Where an agent stands, said one way wherever it is shown (a chat's sheet's agent title, its history's details): the
// library's dot of its tone, its words and, muted, for how long, counting on each second from when it began
// (agent_card_node.mbt's agent_wait_of, agent_card_seconds: the agent card's clock, the same).

///|
/// A session's tone (the core's accent | green | blue | red | neutral, format.ts statusText) as the library's dot says
/// how something stands (@sf.state_dot_node): at work (running, queued) busy; done online; waiting on a person (blocked,
/// a decision) waiting; failed error; else (idle, aborted) a ring.
pub fn agent_tone_state(tone : String) -> String {
  match tone {
    "accent" => "busy"
    "green" => "online"
    "blue" => "waiting"
    "red" => "error"
    "amber" | "warn" => "busy"
    _ => "offline"
  }
}

///|
/// For how long agent `a` has stood where it does at `now` (agent_since's words): waiting as long as it has (of at
/// most), at work since its turn began (agent_waited_words), else when it was last at it.
pub fn agent_since_words(now : Double, a : Json?) -> String {
  match agent_wait_of(a) {
    Some(_) => agent_waited_words(now, a)
    None => text(field(field(field(a, "session"), "time"), "lastActiveAt"), "ago")
  }
}

///|
/// For how long agent `a` (as it is now) has stood where it does (agent_since_words'), read again in `v` each whole
/// second while it runs on (agent_card_seconds').
pub fn agent_since_node(v : @view.View, src : Source, a : () -> Json?) -> () -> String {
  let tick = agent_card_seconds(v, src, fn() { agent_wait_of(a()) })
  fn() {
    tick() |> ignore
    agent_since_words((src.now)(), a())
  }
}

///|
/// Where agent `a` stands in `v`, as it says it now: the library's dot of its tone (agent_tone_state) on its first
/// line, in a box as tall as that line at the system's size of words, never on the middle of two; its words and,
/// muted, for how long (agent_since_node').
pub fn agent_status_node(v : @view.View, src : Source, a : () -> Json?) -> Unit {
  let s = fn() { field(a(), "session") }
  v.box(fn(row) {
    row.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Start))) |> ignore
    row.box(fn(d) {
      d
      .height(By(fn() { Some(@sf.node_sp(d, @ui.tree_theme().text_size(Meta).1)) }))
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .shrink(Is(0.0))
      |> ignore
      @sf.state_dot_node(d, fn() { agent_tone_state(text(s(), "tone")) })
    })
    |> ignore
    row.box(fn(w) {
      w.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      let since = agent_since_node(w, src, a)
      w
      .words_runs(By(fn() {
        let said = since()
        let runs = [@ui.span(text(s(), "statusText"))]
        if said != "" {
          runs.push(@ui.span(" · " + said, color=@sf.theme().p.muted))
        }
        runs
      }))
      .words_look(By(fn() { @ui.style_words(agent_status_words) }))
      .ink(By(fn() { @ui.style_ink(agent_status_words) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Where its words stand: the meta's, in the ink.
// kept across runs: a value (no field of it changes)
let agent_status_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg)
