// What a station's row says of it wherever the workspace's stations are listed: the
// stations' sidebar (sfdesk places_side_node.mbt stations_side_node) and where a new chat runs (new_chat.mbt
// station_rows_node), the same in both. The row itself (its mark, its name, its ground) is the list's or the panel's.

///|
/// What it says (end): a chat's second line's words (the theme's chats' list's), as long as
/// they are.
fn station_words() -> @ui.TextStyle {
  @sf.theme().chat_list.last.then(station_words_hug)
}

///|
// kept across runs: a value (no field of it changes)
let station_words_hug : @ui.TextStyle = @ui.text_style(w=Hug)

///|
/// Its agents at work: the accent's words.
// kept across runs: a value (no field of it changes)
let station_busy : @ui.TextStyle = @ui.text_style(color=AccentText)

///|
/// The dot and what follows it, 5 apart.
// kept across runs: a value (no field of it changes)
let station_state_box : @ui.Style = @ui.css("row gap=S1_25 align=ACenter")

///|
/// Up or away: the rail's dot (railCss.dot: 6), the positive ground; down, a ring in the quiet words' grey
/// (parts.css.ts statusDot: inset 1.5 of --muted), seen on any ground (@sf.state_dot_node's `up` and its ring).
let station_dot_side : Double = 6.0

///|
/// Under the name of a station that only runs tasks (rig `r()`: the core's `rigs`, as it is now), in its figures'
/// place, as nodes in `parent` (the column under its name): that it only runs tasks, then whose it is and how it is.
pub fn rig_figures_node(parent : @view.View, r : () -> Json?) -> Unit {
  @sf.list_row_line_node(parent, fn(l) { @sf.words_node(l, fn() { @sf.t("web-pages.rigs.mode.tasks") }, station_words) |> ignore })
  @sf.list_row_line_node(parent, fn(l) {
    @sf.words_node(l, fn() { @settings.rig_whose(r()) + " · " + @settings.rig_state(r()) }, station_words) |> ignore
  })
}

///|
/// station_state's, as nodes, in `parent` (a row: the end of a station's name's line), of station `s` as it is now: up
/// or away (the rail's dot), then its agents at work (in the accent) or, away, when it was last seen.
pub fn station_state_node(parent : @view.View, s : () -> Json?) -> Unit {
  let online = fn() { flag(s(), "online") }
  let running = fn() { number(field(field(s(), "overview"), "counts"), "running") }
  parent.box(fn(b) {
    @sf.style_node(b, fn() { station_state_box })
    @sf.state_dot_node(b, fn() { if online() { "up" } else { "offline" } }, size=station_dot_side)
    b.show(fn() { !online() }, fn(w) { @sf.words_node(w, fn() { text(s(), "summary") }, station_words) |> ignore })
    b.show(fn() { online() && running() > 0.0 }, fn(w) {
      @sf.words_node(
        w,
        fn() { @sf.t("web-pages.stations.page.runningShort", args=[("n", running().to_int().to_string())]) },
        fn() { station_words().then(station_busy) },
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// station_figures', as nodes, in `parent` (the column under a station's name), of station `s` as it is now: while it
/// is up, a line of what is left of its CPU, memory and disk in brief (@sf.meter_chips_brief_node) and a line of how
/// this device reaches it (the core's `stationNet`, as it says it: 未连接 while there is none). `apart`: the two lines as
/// far apart as a list's row's lines are (the theme's chats' list's `text`: a sidebar's station row).
pub fn station_figures_node(parent : @view.View, src : Source, s : () -> Json?, apart? : Bool = false) -> Unit {
  let net = src.topic("stationNet", { "station": Json::string(text(@signals.untracked(s), "station")) })
  // (its chips as this device says a CPU: idle or busy, @settings.meters_said; told again only as what they say changes)
  let busy = @signals.computed(fn(_) { cpu_busy(src) })
  let meters = @signals.computed(fn(_) { @settings.meters_said(items(field(s(), "host"), "meters"), busy.get()) })
  parent.show(fn() { flag(s(), "online") }, fn(f) {
    if apart {
      @sf.style_node(f, fn() { @sf.theme().chat_list.text })
    }
    @sf.list_row_line_node(f, fn(l) { @sf.meter_chips_brief_node(l, fn() { meters.get() }) })
    @sf.list_row_line_node(f, fn(l) {
      @sf.words_node(l, fn() {
          let n = net.get().value
          match n {
            Some(Object(_)) =>
              match text(field(n, "rtt"), "text") {
                "" => text(n, "path")
                rtt => text(n, "path") + " · " + rtt
              }
            _ => @sf.t("web-pages.stations.netNone")
          }
        }, station_words)
      |> ignore
    })
  })
}
