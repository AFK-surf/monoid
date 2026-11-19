// What a station's page shows of the machine and its software (still.fail web/src/components.tsx MeterDials, Dial;
// cloud/StationCards.tsx HostDetails; Versions.tsx SoftwareList, SoftwareRow; MachineLogins.tsx LoginsSection,
// PastRow; their css.ts), all of it as the core says it.

///|
/// A meter as its dial: what is left large, filled as far as is used, its name and its total under (each its short
/// words too). The CPU's (`short` CPU) turns: `busy`, how much of it is used large instead, as its cells are filled.
fn meter_dial(m : Json, busy : Bool) -> @sf.Dial {
  let mv = Some(m)
  let cpu = text(mv, "short") == "CPU"
  if cpu && busy {
    let used = count(mv, "percent")
    {
      number: used.to_string(),
      unit: "%",
      fill: used,
      level: text(mv, "level"),
      label: @sf.t("web-pages.stations.page.cpuBusy"),
      note: text(mv, "total"),
      label_short: @sf.t("web-pages.stations.page.cpuBusyShort"),
      note_short: text(mv, "totalShort"),
      turns: true,
    }
  } else {
    {
      number: text(mv, "big"),
      unit: text(mv, "unit"),
      fill: 100 - count(mv, "left"),
      level: text(mv, "level"),
      label: text(mv, "title"),
      note: text(mv, "total"),
      label_short: text(mv, "titleShort"),
      note_short: text(mv, "totalShort"),
      turns: cpu,
    }
  }
}

///|
/// Whether this device shows its machines' CPU as how much of it is used (the prefs' `cpuDial` busy), not how much is
/// idle: pressing the CPU's dial turns it, kept on this device alone.
fn cpu_busy(src : Source) -> Bool {
  text(src.topic("prefs", {}).get().value, "cpuDial") == "busy"
}

///|
/// The CPU's dial pressed: the other way kept on this device.
fn cpu_dial_turn(src : Source) -> Unit {
  let to = if cpu_busy(src) { Json::null() } else { Json::string("busy") }
  (src.call)("prefs.set", { "cpuDial": to }, @sfbase.answer_unread)
}

///|
/// The machine's meters and its GPUs as one row of dials, and what is said under each (a GPU's model; "" none).
fn station_dials_of(meters : Array[Json], gpus : Array[Json]) -> (Array[Json], Array[String]) {
  let all = meters.copy()
  all.append(gpus)
  let models = meters.map(fn(_) { "" })
  models.append(gpus.map(fn(g) { text(Some(g), "model") }))
  (all, models)
}

///|
/// The machine's dials, as `host` says them now, the CPU's turned by a press (cpu_dial_turn).
fn station_dials_node(p : @view.View, src : Source, host : () -> Json?) -> Unit {
  let busy = @signals.computed(fn(_) { cpu_busy(src) })
  let press = fn(_i : Int) { cpu_dial_turn(src) }
  p.pick(fn() { items(host(), "gpus").length() > 0 }, fn(d, gpus) {
    if gpus {
      let both = fn() { station_dials_of(items(host(), "meters"), items(host(), "gpus")) }
      @sf.dials_node(d, fn() { both().0.map(fn(m) { meter_dial(m, busy.get()) }) }, details=fn() { both().1 }, columns=3, press~)
    } else {
      @sf.dials_node(d, fn() { items(host(), "meters").map(fn(m) { meter_dial(m, busy.get()) }) }, press~)
    }
  })
}

///|
/// An allowance's windows on its profile's page as dials (QuotaBars, not compact; dials_node's): what is left of each,
/// large over its cells, as far as is left, its name and when it refills.
fn quota_dials_of(windows : Array[Json]) -> Array[@sf.Dial] {
  windows.map(fn(w) {
    let wv = Some(w)
    let left = count(wv, "left")
    { number: left.to_string(), unit: "%", fill: left, level: text(wv, "level"), label: text(wv, "label"), note: text(wv, "refills"), label_short: "", note_short: "", turns: false }
  })
}

///|
/// A figure (Figure): bold in the words' ink, in its level's colour when off.
pub fn figure(c : @ui.Ctx, f : Json?) -> Unit {
  c.text(text(f, "text"), style=@sf.level_figure_style(text(f, "level"), nt_figure)) |> ignore
}

///|
/// What is asked of a station's software (useSoftware): updating one, checking, its channel, updating by itself; what
/// went wrong with it, by station ("" nothing).
// kept across runs: said as an update fails or is asked again; station_cards_reset empties it
let software_failed : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
fn station_cards_reset() -> Unit {
  software_failed.clear()
}

///|
/// A software call (`software.update`, `.check`, `.channel`, `.auto`), what went wrong said under the list.
fn software_call(core : Core, station : String, name : String, params : Array[(String, Json)]) -> Unit {
  software_failed.remove(station)
  let p = [("station", str(station))]
  p.append(params)
  (core.call)(name, obj(p), fn(r) {
    match r {
      Ok(_) => ()
      Err(e) =>
        software_failed[station] = if name == "software.check" {
          @sf.t("web-main.versions.checkFailedWhy", args=[("error", error_text(e))])
        } else {
          error_text(e)
        }
    }
  })
}

///|
/// Which program's tries are open on a station's page, by station ("" none: closed again).
// kept across runs: said as a program's row is pressed; login_cards_reset empties it
let st_logins_open : @sf.LiveMap[String, String] = @sf.LiveMap::new()

// ── styles ──────────────────────────────────────────────────────────────

///|
// kept across runs: a value (no field of it changes)
let nt_figure : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Medium, color=Fg, wrap=false)

///|
/// The rest of a machine (hostDetails: its labels beside each, 14 apart, rows 8 apart, the meta's 12 muted).
// kept across runs: a value (no field of it changes)
let hd_grid : @ui.Style = @ui.css("row w=Full gap=S3_5")

///|
// kept across runs: a value (no field of it changes)
let hd_labels : @ui.Style = @ui.css("gap=S2")

///|
// kept across runs: a value (no field of it changes)
let hd_values : @ui.Style = @ui.style(w=@sf.grow, gap=S2)

///|
// kept across runs: a value (no field of it changes)
let hd_label : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Subtle, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let hd_value : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Full)

///|
let sw_glyph : Double = 18.0

///|
let sw_progress_w : Double = 60.0

///|
// kept across runs: a value (no field of it changes)
let sw_mark : @ui.Style = @ui.css("w=S9 h=S9 radius=Full bg=Neutral align=ACenter justify=JCenter")

///|
/// How wide and tall a software row's mark is (sw_mark's S9): its first line is at least this tall.
let sw_mark_d : Double = @ui.Space::S9.px()

///|
// kept across runs: a value (no field of it changes)
let sw_name_line : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
/// Its name taking what its first line leaves what is newer and updating it.
// kept across runs: a value (no field of it changes)
let sw_name_grow : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let sw_version_box : @ui.Style = @ui.css("row")

///|
// kept across runs: a value (no field of it changes)
let sw_version : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sw_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
/// The test channel's tag beside a version (betaTag).
// kept across runs: a value (no field of it changes)
let sw_beta : @ui.Style = @ui.css("px=S1_5 radius=Full bg=AccentBg")

///|
// kept across runs: a value (no field of it changes)
let sw_beta_words : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4, weight=Medium, color=AccentText, wrap=false)

///|
/// A switch's word beside it (channel: the ui's 13, on one line).
// kept across runs: a value (no field of it changes)
let sw_switch_word : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sw_switches : @ui.Style = @ui.css("row pt=S1_5 gap=S4 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sw_switch_line : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sw_rest : @ui.Style = @ui.css("row gap=S2_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sw_newer : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sw_failed : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Danger, wrap=false)

///|
/// Why checking failed, in the foot: a line of its own, in lines where it is long.
// kept across runs: a value (no field of it changes)
let sw_failed_line : @ui.TextStyle = sw_failed.then(@ui.text_style(wrap=true, w=Full))

///|
/// When it was last checked, checking again beside it (cardFoot).
// kept across runs: a value (no field of it changes)
let sw_foot : @ui.Style = @ui.css("row w=Full px=S3 pt=S2 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sw_foot_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sw_check : @ui.Style = @ui.css("px=S1")

///|
// kept across runs: a value (no field of it changes)
let sw_check_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=AccentText, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sw_check_lit : @ui.TextStyle = sw_check_words.then(@ui.text_style(color=Fg))

///|
/// Logins under way, their cards 12 apart.
// kept across runs: a value (no field of it changes)
let lg_cards : @ui.Style = @ui.css("w=Full gap=S3 pb=S3")

///|
/// Where a try's mark would be, under its program's: its words where the program's name is.
// kept across runs: a value (no field of it changes)
let lg_no_mark : @ui.Style = @ui.css("w=S6")

///|
/// A program's mark before its name, bare (用户 2026-10-31: 不要那个背景色): its middle in a square as wide as a try's
/// lg_no_mark.
// kept across runs: a value (no field of it changes)
let lg_mark : @ui.Style = @ui.css("w=S6 h=S6 align=ACenter justify=JCenter")

///|
/// How many tries a program's row stands for, at its end (the meta's 13, muted, one line).
// kept across runs: a value (no field of it changes)
let lg_count : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sw_name : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=Fg, wrap=false)
