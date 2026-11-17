// The workspace's stations: what is left here of their old views (a machine's chips, how this device reaches one), and
// what a station's page keeps while it is in the stack (its list and its page are made once as nodes: sfpages'
// stations_list.mbt, station_node.mbt).

///|
/// How this device reaches station `s` now, its figures (Stations.kt rememberStationNet: the `stationNet` view, sampled
/// while shown; none before a connection of its own is open).
fn station_net(core : Core, s : Json?) -> Json? {
  // (the view's null: no connection of this device's own open yet, as none)
  match (core.topic)("stationNet", { "station": str(text(s, "station")) }).get().value {
    Some(Object(_)) as v => v
    _ => None
  }
}

///|
/// A machine's CPU, memory and disk, each a chip (MeterChip) with what it is in its tip;
/// `alerts`: only those running low. 8 apart.
pub fn meter_chips(c : @ui.Ctx, key : String, meters : Array[Json], alerts? : Bool = false) -> Unit {
  c.box(style=peek_meters, fn() {
    // (what it is in the chip's own tip)
    let shown = if alerts { meters.filter(fn(m) { text(Some(m), "level") != "ok" }) } else { meters }
    @sf.meter_line(c, shown, key=key + "/meter")
  })
  |> ignore
}

///|
/// This device's connection to a station: how it goes (and packets lost) over its round trip on
/// the left; on the right ↑ over ↓, the speed each way and what went that way.
fn net_line(c : @ui.Ctx, net : Json?) -> Unit {
  let t = @sf.theme()
  let tone = fn(f : Json?) {
    match text(f, "level") {
      "red" => t.p.red
      "amber" => t.p.warn_ink
      _ => t.p.text
    }
  }
  // (none: a made-up one, to be drawn in its bones while it is read, its words in Chinese)
  let n = match net {
    Some(_) => net
    None =>
      Some(
        obj([
          ("path", str("直连")),
          ("rtt", obj([("text", str("0 ms")), ("level", str("ok"))])),
          ("down", str("0.0 KB/s")),
          ("up", str("0.0 KB/s")),
        ]),
      )
  }
  c.box(dir=Row, w=Fill(1.0), gap=10.0, align=ACenter, justify=JBetween, flow=true, line_gap=2.0, fn() {
    c.box(dir=Row, w=Cut, gap=6.0, align=ACenter, fn() {
      // (short of room, what its latency is called is cut short; how it is reached and the figures are not)
      c.box(dir=Row, gap=6.0, align=ACenter, fn() {
        c.text(text(n, "path"), size=t.t.meta, color=t.p.muted, wrap=false, line=18.0) |> ignore
        match field(n, "loss") {
          Some(Object(_)) as l =>
            c.text(text(l, "text"), size=@sf.theme().t.meta, weight=500, color=tone(l), wrap=false, line=18.0) |> ignore
          _ => ()
        }
      })
      |> ignore
      match field(n, "rtt") {
        Some(Object(_)) as r =>
          c.box(dir=Row, w=Cut, gap=4.0, align=ACenter, fn() {
            c.text("·", size=t.t.meta, color=t.p.muted, wrap=false, line=18.0) |> ignore
            c.text(tr("android-settings.stations.rtt"), size=t.t.meta, color=t.p.muted, wrap=false, line=18.0, w=Cut) |> ignore
            c.text(text(r, "text"), size=@sf.theme().t.meta, weight=500, color=tone(r), wrap=false, line=18.0) |> ignore
          })
          |> ignore
        _ => ()
      }
    })
    |> ignore
    c.box(dir=Row, gap=10.0, align=ACenter, fn() {
      for way in [("↑", "up"), ("↓", "down")] {
        c.box(dir=Row, gap=4.0, align=ACenter, fn() {
          c.text(way.0, size=t.t.meta, color=t.p.muted, wrap=false, line=18.0) |> ignore
          c.text(text(n, way.1), size=t.t.meta, weight=500, color=t.p.text, wrap=false, line=18.0) |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// The page's part shown, by station, by its name (StationPage.tsx Part: overview 概览, processes 进程, settings 设置,
/// machine 软件与设备); none, the overview. Kept while the page is in the stack; a login's link opens the settings
/// (mark_login).
pub let station_parts : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
/// Whose page has its 高级网络设置 opened, by station (opened by the person, or the fixture's
/// settings-station-network); kept while the page is in the stack.
pub let station_network_open : Map[String, Bool] = Map([])

///|
/// Whether station `s` is this machine's (the host's station, one id in every workspace it is in): Station's list puts
/// it first, tagged 本机 (the user, 2026-11-16).
pub fn is_this_machine(s : Json?) -> Bool {
  let id = text(s, "id")
  id != "" && local_station_id() == id
}
