// Reusable Station information card component for dialogs, sheets, and panels.
// Displays a station's icon/emoji mark, name, and context-appropriate details (live online/offline state,
// hardware/OS spec, CPU/memory/disk availability, network latency, version, or custom note) inside an iOS 27
// concentric quiet card (`bg=A(Fg,O5)`, `quiet_card_corner = 22pt` in dialogs/sheets, `row_corner` in popovers).

///|
/// Which detail facets `station_info_card_node` renders for a station in a given scenario.
pub(all) struct StationInfoShow {
  /// Online/offline status dot and state/running/network badge on the right of the header line.
  state : Bool
  /// Hardware / OS identity (`host.identity` or `host.os`).
  host : Bool
  /// Brief CPU, memory, and disk availability summary when online.
  meters : Bool
  /// Network reachability path and RTT (`stationNet` topic or `row.net`) when online.
  net : Bool
  /// Station build version (`version`) when present.
  version : Bool
}

///|
/// Minimal station identity + live online/offline indicator.
pub fn StationInfoShow::brief() -> StationInfoShow {
  { state: true, host: false, meters: false, net: false, version: false }
}

///|
/// Standard verification display (source station, removal, retirement): mark, name, live status, machine identity, and
/// live CPU/memory/disk availability.
pub fn StationInfoShow::compact() -> StationInfoShow {
  { state: true, host: true, meters: true, net: false, version: false }
}

///|
/// Target selection / handoff / migration display: mark, name, live status + network path/RTT, machine identity, and
/// resource availability so people can verify capacity before moving work onto the station.
pub fn StationInfoShow::target() -> StationInfoShow {
  { state: true, host: true, meters: true, net: true, version: false }
}

///|
/// Full diagnostic summary including station version.
pub fn StationInfoShow::detail() -> StationInfoShow {
  { state: true, host: true, meters: true, net: true, version: true }
}

///|
/// One station entry rendered inside `station_info_card_node`.
pub(all) struct StationInfoItem {
  /// Optional role caption shown above the station row (e.g. "来源 Station", "目标 Station").
  role : String
  /// Full station address (`<workspace>/<id>`) for mark fallback and lookup.
  address : String
  /// Fallback display name when the station row is not yet loaded.
  name : String
  /// Reactive station row JSON (from `stations` or `station` topic).
  row : () -> Json?
  /// Optional reactive `stationNet` JSON (`path`, `rtt.text`), queried only when `show.net` is true.
  net : (() -> Json?)?
  /// Optional reactive CPU busy display preference for `meters_said`.
  cpu_busy : (() -> Bool)?
  /// Which detail facets to display in this context.
  show : StationInfoShow
  /// Optional contextual note line displayed beneath the station details.
  note : String
}

///|
fn find_station_row(list : Json?, address : String) -> Json? {
  match list {
    Some(Array(rows)) =>
      rows.iter().find_first(fn(x) { text(Some(x), "station") == address })
    _ => None
  }
}

///|
/// Builds a `StationInfoItem` backed by `@sfbase.Source` (`stations` topic, plus `stationNet` when `show.net`).
pub fn station_info_from_source(
  src : Source,
  address : String,
  name : String,
  role? : String = "",
  show? : StationInfoShow = StationInfoShow::compact(),
  note? : String = "",
) -> StationInfoItem {
  let ws = @sfbase.workspace_of(address)
  let row = fn() {
    if ws == "" || address == "" {
      None
    } else {
      find_station_row(@sfbase.station_rows(src, ws).value, address)
    }
  }
  let net : (() -> Json?)? = if show.net && address != "" {
    let t = src.topic("stationNet", { "station": Json::string(address) })
    Some(fn() { t.get().value })
  } else {
    None
  }
  let busy = @signals.computed(fn(_) { cpu_busy(src) })
  { role, address, name, row, net, cpu_busy: Some(fn() { busy.get() }), show, note }
}

///|
/// Builds a `StationInfoItem` backed by `@settings.Core` (or an explicit `row` signal/getter when already in hand).
pub fn station_info_from_core(
  core : Core,
  address : String,
  name : String,
  row? : () -> Json?,
  role? : String = "",
  show? : StationInfoShow = StationInfoShow::compact(),
  note? : String = "",
) -> StationInfoItem {
  let ws = @sfbase.workspace_of(address)
  let resolved_row = fn() {
    let live = if ws == "" || address == "" {
      None
    } else {
      let (_, params) = @sfbase.station_rows_ask(ws)
      find_station_row((core.topic)("stations", params).get().value, address)
    }
    match live {
      Some(Object(_)) => live
      _ =>
        match row {
          Some(r) => r()
          None => None
        }
    }
  }
  let net : (() -> Json?)? = if show.net && address != "" {
    let t = (core.topic)("stationNet", { "station": Json::string(address) })
    Some(fn() { t.get().value })
  } else {
    None
  }
  let busy = @signals.computed(fn(_) { @settings.cpu_busy(core) })
  { role, address, name, row: resolved_row, net, cpu_busy: Some(fn() { busy.get() }), show, note }
}

///|
fn station_info_net_text(row : Json?, net_topic : (() -> Json?)?) -> String {
  let n = match net_topic {
    Some(get) =>
      match get() {
        Some(Object(_)) as v => v
        _ => field(row, "net")
      }
    None => field(row, "net")
  }
  match n {
    Some(Object(_)) => {
      let path = text(n, "path")
      let rtt = text(field(n, "rtt"), "text")
      if path != "" && rtt != "" {
        path + " · " + rtt
      } else if path != "" {
        path
      } else {
        rtt
      }
    }
    _ => ""
  }
}

///|
fn station_info_meters_text(row : Json?, busy : Bool) -> String {
  let raw = items(field(row, "host"), "meters")
  if raw.is_empty() {
    return ""
  }
  let said = @settings.meters_said(raw, busy)
  let parts : Array[String] = []
  for m in said {
    let mv = Some(m)
    let short = text(mv, "short")
    let rem = text(mv, "remaining")
    if rem != "" {
      if short != "" && !rem.has_prefix(short) {
        parts.push(short + " " + rem)
      } else {
        parts.push(rem)
      }
    }
  }
  parts.join(" · ")
}

///|
fn station_info_spec_text(row : Json?, show : StationInfoShow, online : Bool, head_state : String) -> String {
  let parts : Array[String] = []
  if show.host {
    let host = field(row, "host")
    let id = text(host, "identity")
    let os = text(host, "os")
    if id != "" {
      parts.push(id)
    } else if os != "" {
      parts.push(os)
    }
  }
  if show.version {
    let ver = text(row, "version")
    if ver != "" {
      parts.push(@sf.t("web-pages.stations.versionLabel", args=[("version", ver)]))
    }
  }
  if online && show.state {
    let ov = field(row, "overview")
    let running = number(field(ov, "counts"), "running").to_int()
    let workload = if running > 0 {
      @sf.t("web-pages.stations.page.runningShort", args=[("n", running.to_string())])
    } else {
      let proc = text(ov, "processesText")
      if proc != "" {
        proc
      } else {
        text(row, "stateText")
      }
    }
    if workload != "" && workload != head_state {
      parts.push(workload)
    }
  }
  parts.join(" · ")
}

///|
/// Renders one station block inside `station_info_card_node`.
#callsite(autofill(loc))
fn station_info_item_node(parent : @view.View, item : StationInfoItem, loc~ : SourceLoc) -> Unit {
  let row_sig = @signals.computed(fn(_) { (item.row)() })
  let row = fn() { row_sig.get() }
  let has_row = fn() { row() is Some(Object(_)) }
  let online_sig = @signals.computed(fn(_) { flag(row(), "online") })
  let online = fn() { online_sig.get() }
  let display_name = fn() {
    match text(row(), "name") {
      "" => item.name
      n => n
    }
  }
  let net_sig = @signals.computed(fn(_) {
    if item.show.net && online() {
      station_info_net_text(row(), item.net)
    } else {
      ""
    }
  })
  let net_text = fn() { net_sig.get() }
  let state_sig = @signals.computed(fn(_) {
    if !has_row() {
      ""
    } else if !online() {
      match text(row(), "stateText") {
        "" => @sf.t("web-pages.stations.offline")
        s => s
      }
    } else {
      let net = net_text()
      if net != "" {
        net
      } else {
        let running = number(field(field(row(), "overview"), "counts"), "running").to_int()
        if running > 0 {
          @sf.t("web-pages.stations.page.runningShort", args=[("n", running.to_string())])
        } else {
          match text(row(), "stateText") {
            "" => @sf.t("web-pages.stations.online")
            s => s
          }
        }
      }
    }
  })
  let state_text = fn() { state_sig.get() }
  let spec_text = fn() {
    station_info_spec_text(row(), item.show, online(), state_text())
  }
  let meters_text = fn() {
    if !item.show.meters || !online() {
      ""
    } else {
      let busy = match item.cpu_busy {
        Some(f) => f()
        None => false
      }
      station_info_meters_text(row(), busy)
    }
  }
  let problem_text = fn() {
    if !item.show.state {
      return ""
    }
    let blocked = text(row(), "blocked")
    if blocked != "" {
      return blocked
    }
    for p in items(row(), "problems") {
      let key = text(Some(p), "key")
      let msg = text(Some(p), "text")
      if msg != "" && (online() || key != "away") {
        return msg
      }
    }
    ""
  }
  parent.box(made_for=loc, fn(block) {
    @sf.style_node(block, fn() { si_item_box })
    if item.role != "" {
      @sf.words_node(loc~, block, fn() { item.role }, fn() { si_role_words }) |> ignore
    }
    block.box(made_for=loc, fn(head) {
      @sf.style_node(head, fn() { si_head_row })
      head.wraps(Is(Some(@ui.Space::px(S1)))) |> ignore
      head.box(made_for=loc, fn(left) {
        @sf.style_node(left, fn() { si_identity_row })
        left.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sfbase.station_mark_at_node(
          loc~,
          left,
          fn() { item.address },
          fn() { text(row(), "emoji") },
          fn() { text(row(), "icon") },
          Row,
          words=fn() {
            if has_row() && !online() {
              @ui.tree_theme().color(Over(Muted, A(Fg, O75)))
            } else {
              @sf.theme().p.text
            }
          },
        )
        @sf.words_node(loc~, left, display_name, fn() { si_name_words })
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        |> ignore
      })
      |> ignore
      if item.show.state {
        head.show(has_row, at_once=true, fn(right) {
          @sf.style_node(right, fn() { si_state_row })
          right.shrink(Is(0.0)) |> ignore
          @sf.words_node(loc~, right, state_text, fn() { si_state_words }) |> ignore
          @sf.state_dot_node(right, fn() { if online() { "up" } else { "offline" } }, size=station_dot_side)
        })
      }
    })
    |> ignore
    if item.show.host || item.show.version || item.show.net {
      block.show(fn() { spec_text() != "" }, at_once=true, fn(s) {
        @sf.words_node(loc~, s, spec_text, fn() { si_meta_words }) |> ignore
      })
    }
    if item.show.meters {
      block.show(fn() { meters_text() != "" }, at_once=true, fn(m) {
        @sf.words_node(loc~, m, meters_text, fn() { si_meta_words }) |> ignore
      })
    }
    if item.show.state {
      block.show(fn() { problem_text() != "" }, at_once=true, fn(p) {
        @sf.words_node(loc~, p, problem_text, fn() { si_meta_words }) |> ignore
      })
    }
    if item.note != "" {
      @sf.words_node(loc~, block, fn() { item.note }, fn() { si_meta_words }) |> ignore
    }
  })
  |> ignore
}

///|
/// A quiet concentric Station info card (`bg=A(Fg,O5)`, `quiet_card_corner = 22pt` in dialogs/sheets or `row_corner`
/// in anchored popovers) rendering one or more stations separated by hairline dividers, showing only the detail facets
/// configured by each `StationInfoItem.show`.
#callsite(autofill(loc))
pub fn station_info_card_node(
  parent : @view.View,
  stations : Array[StationInfoItem],
  inset_out? : Bool = true,
  loc~ : SourceLoc,
) -> Unit {
  if stations.is_empty() {
    return
  }
  parent.box(made_for=loc, fn(card) {
    let small = @sf.in_small_panel_node(card)
    @sf.style_node(card, fn() {
      if small {
        si_popover_card
      } else if inset_out {
        si_card.then(@sf.panel_card_out_node(card))
      } else {
        si_card
      }
    })
    card.radius(Is(if small { @sf.row_corner } else { @sf.quiet_card_corner })) |> ignore
    if !small {
      card.min_height(Is(Some(@sf.quiet_card_corner * 2.0))) |> ignore
    }
    for i, item in stations {
      if i > 0 {
        card.box(made_for=loc, fn(sep) { @sf.style_node(sep, fn() { @sf.rule_line }) }) |> ignore
      }
      station_info_item_node(loc~, card, item)
    }
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let si_card : @ui.Style = @ui.css("w=Full px=S4 py=S3 gap=S2_5 bg=A(Fg,O5) clip justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let si_popover_card : @ui.Style = @ui.css("w=Full py=S2_5 gap=S2 bg=A(Fg,O5) clip").then(
  @ui.style(px=@sf.room_of(@sf.text_in - @sf.panel_pad)),
)

///|
// kept across runs: a value (no field of it changes)
let si_item_box : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let si_head_row : @ui.Style = @ui.css("row w=Full align=ACenter justify=JBetween gap=S2")

///|
// kept across runs: a value (no field of it changes)
let si_identity_row : @ui.Style = @ui.css("row align=ACenter gap=S2")

///|
// kept across runs: a value (no field of it changes)
let si_state_row : @ui.Style = @ui.css("row align=ACenter gap=S1_25")

///|
// kept across runs: a value (no field of it changes)
let si_role_words : @ui.TextStyle = @ui.text_style(
  size=Caption,
  color=Muted,
  dark=@ui.text_patch(color=Over(Muted, A(Fg, O95))),
  w=Full,
)

///|
// kept across runs: a value (no field of it changes)
let si_name_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let si_state_words : @ui.TextStyle = @ui.text_style(
  size=Meta,
  color=Muted,
  dark=@ui.text_patch(color=Over(Muted, A(Fg, O95))),
  wrap=false,
)

///|
// kept across runs: a value (no field of it changes)
let si_meta_words : @ui.TextStyle = @ui.text_style(
  size=Meta,
  color=Muted,
  dark=@ui.text_patch(color=Over(Muted, A(Fg, O95))),
  w=Full,
)
