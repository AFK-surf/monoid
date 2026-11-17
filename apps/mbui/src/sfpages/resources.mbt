// What still.fail uses of a station's machine, as Activity Monitor says it (still.fail web/src/Resources.tsx ResourcesBody,
// Resources.css.ts; the core's `resources` view, client/core-ts/src/views/resources.ts): a station's page's 进程, and
// the line its overview says it in. Its totals with the last minutes' line under each, whose
// uses what (a chat, the agents, the desktop app, the station) grouped or every process flat, sorted by a column, a
// chat's process ended from its row (asked first). Laid out by its own width: the totals four in a row or two over
// two; the table's columns each as wide as its widest figure, so its rows line up, and where its names would have too
// little room beside them (a phone's), each row's names on a line over its figures.

///|
/// What the core is asked for station `address`'s figures (its 进程's and its overview's line's): its
/// `resources` view of the workspace in view.
fn resources_ask(here : Here, address : String) -> (String, Map[String, Json]) {
  ("resources", { "scope": str(here.workspace), "station": str(address) })
}

///|
/// The columns (ALL), each by its key: what it sorts by, the figure it says.
// kept across runs: a table, never written
let rs_columns : Array[(String, String)] = [
  ("cpu", "cpuText"),
  ("memory", "memoryText"),
  ("net", "netText"),
  ("disk", "diskText"),
]

///|
/// The columns shown: the network's and the disk's only where some station reads them (columnsOf).
fn rs_columns_of(v : Json?) -> Array[(String, String)] {
  rs_columns.filter(fn(k) { (k.0 != "net" || flag(v, "net")) && (k.0 != "disk" || flag(v, "disk")) })
}

///|
/// What the page shows, by station: the kind of whose (all, or a ResourceKind's key), every process flat or grouped,
/// the column sorted by, the groups open (`opened`: once one is opened or shut; till then the first alone).
priv struct RsShown {
  kind : String
  flat : Bool
  by : String
  open : Array[String]
  opened : Bool
}

///|
// kept across runs: said as a station's 进程 is chosen in; station_page_reset empties it
let rs_shown : @sf.LiveMap[String, RsShown] = @sf.LiveMap::new()

///|
/// What station `address`'s 进程 shows now (as at first where nothing was chosen in it).
fn rs_shown_of(address : String) -> RsShown {
  rs_shown.get(address).unwrap_or({ kind: "all", flat: false, by: "cpu", open: [], opened: false })
}

///|
/// Whether group `key` of `groups` (those shown, in the core's order) is open: the first alone till one is opened or
/// shut.
fn rs_open(shown : RsShown, groups : Array[Json], key : String) -> Bool {
  if shown.opened {
    shown.open.contains(key)
  } else {
    match groups {
      [g, ..] => text(Some(g), "key") == key
      [] => false
    }
  }
}

///|
/// Group `key` opened or shut on station `address`'s 进程 (as it is pressed).
fn rs_open_or_shut(address : String, groups : Array[Json], key : String) -> Unit {
  let shown = rs_shown_of(address)
  let open = if rs_open(shown, groups, key) {
    groups.filter_map(fn(g) {
      let k = text(Some(g), "key")
      if k != key && rs_open(shown, groups, k) { Some(k) } else { None }
    })
  } else {
    groups.filter_map(fn(g) {
      let k = text(Some(g), "key")
      if k == key || rs_open(shown, groups, k) { Some(k) } else { None }
    })
  }
  rs_shown[address] = { ..shown, open, opened: true }
}

///|
/// A use's figure by column key.
fn rs_use(u : Json?, key : String) -> Double {
  number(u, key)
}

///|
/// The made-up machine rs_sample draws (and its node, resources_node's bones).
fn rs_sample_view() -> Json {
  let w = fn(n : Int) { Json::string(@sf.sample_words(n)) }
  let usage = fn(k : Double) -> Json { { "cpu": Json::number(k), "memory": Json::number(k * 2.0) } }
  let group = fn(i : Int, n : Int, k : Double, processes : Array[Int]) -> Json {
    {
      "key": Json::string("sample" + i.to_string()),
      "title": w(n),
      "kindText": w(2),
      "use": usage(k),
      "processes": Json::array(
        processes.mapi(fn(j, m) {
          Json::object({
            "key": Json::string("sample" + i.to_string() + "/" + j.to_string()),
            "name": w(m),
            "pid": Json::number((j + 1).to_double()),
            "use": usage(k / 2.0),
          })
        }),
      ),
    }
  }
  let v : Json = {
    "tiles": Json::array(["cpu", "memory", "net", "disk"].map(fn(k) { Json::object({ "key": Json::string(k), "label": w(2), "sub": w(4), "value": w(4) }) })),
    "kinds": [{ "key": "a", "label": w(2) }, { "key": "b", "label": w(2) }],
    "groups": [group(0, 8, 30.0, [6, 9, 5]), group(1, 6, 20.0, [7]), group(2, 10, 10.0, [8])],
  }
  v
}

///|
/// A total's line's ink, by what it counts.
fn rs_spark_ink(key : String) -> Int64 {
  let t = @sf.theme()
  match key {
    "cpu" => t.p.accent
    "memory" => t.p.blue
    "net" => t.p.green
    "disk" => t.p.warn_ink
    _ => t.p.muted
  }
}

///|
/// The figures of `key` of `v`, as numbers.
fn number_list(v : Json?, key : String) -> Array[Double] {
  items(v, key).filter_map(fn(x) {
    match x {
      Number(n, ..) => Some(n)
      _ => None
    }
  })
}

///|
/// The last minutes' line `w` wide (Spark: the most at 2 under its top, the line 1.25 wide, the ground under it the ink
/// at 14%); none for fewer than two points.
fn rs_spark_shapes(points : Array[Double], w : Double, ink : Int64) -> Array[@ui.Shape] {
  if points.length() < 2 {
    return []
  }
  let most = points.fold(init=0.0, fn(m, p) { if p > m { p } else { m } })
  let most = if most > 0.0 { most } else { 1.0 }
  let line : Array[Double] = []
  for i, p in points {
    line.push(i.to_double() / (points.length() - 1).to_double() * w)
    line.push(rs_spark_h - p / most * (rs_spark_h - rs_spark_top))
  }
  let ground = line.copy()
  ground.push(w)
  ground.push(rs_spark_h)
  ground.push(0.0)
  ground.push(rs_spark_h)
  [
    @ui.shape_of([(ground, true)], fill=@sf.alpha(ink, rs_spark_ground)),
    @ui.shape_of([(line, false)], stroke=ink, width=rs_spark_line),
  ]
}

///|
/// How the table is laid out in its width: each figure's column as wide as the widest it says (its head, every row's
/// figure, a group's processes' too, open or not), so its rows line up as a table's and none moves as a group opens;
/// `stacked`, each row's names on a line of their own over its figures, where beside the figures they would have less
/// than rs_name_least each; `share`, the sorted column's share before its figures, left out where the figures' line
/// has not the room for it.
#derive(Eq)
priv struct RsLayout {
  widths : Array[Double]
  stacked : Bool
  share : Bool
}

///|
/// The layout of a table `room` wide (rs_layout's), its heads' words drawn `head` large and its figures' `figure` (a
/// figure's digits tabular).
fn rs_layout_of(
  room : Double,
  head : Double,
  figure : Double,
  rows : Array[(Json?, Bool)],
  columns : Array[(String, String)],
  by : String,
  names : Int,
) -> RsLayout {
  let sp = fn(s : @ui.Space) { s.px() }
  let widths = columns.map(fn(col) {
    let sorted = col.0 == by
    let name = @sf.t("web-main.resources.column." + col.0)
    let mut widest = @ui.text_advance(if sorted { name + " ↓" } else { name }, size=head, weight=500)
    for r in rows {
      let weight = if sorted && r.1 { 600 } else { 400 }
      widest = dmax(widest, @ui.text_advance(text(r.0, col.1), size=figure, weight~, style=@hostapi.style_tabular))
    }
    widest + 2.0 * sp(S2)
  })
  let share_w = sp(S9) + sp(S2)
  let sorted = columns.search_by(fn(col) { col.0 == by })
  let figures = widths.fold(init=0.0, fn(s, w) { s + w }) + (if sorted is Some(_) { share_w } else { 0.0 })
  let left = room - figures - sp(S8)
  let beside = left >= sp(rs_name_least) * names.to_double()
  let share = left >= 0.0
  match sorted {
    Some(k) if share => widths[k] = widths[k] + share_w
    _ => ()
  }
  { widths, stacked: !beside, share }
}

///|
/// Column `k`'s cell: as wide as its column; under its row's names (stacked), the line over it apart enough; `shared`,
/// the share at its start, the figure at its end (the shares one under another, as bars of a chart).
fn rs_column(lay : RsLayout, k : Int, under? : Bool = false, shared? : Bool = false) -> @ui.Style {
  let s = rs_number_cell.then(@ui.style(min_w=Fixed(lay.widths[k])))
  let s = if under { s.then(rs_number_under) } else { s }
  if shared {
    s.then(rs_number_shared)
  } else {
    s
  }
}

///|
/// Process `pid` (called `name`) of group `gv`'s chat ended (`process.end`), as its end is confirmed; said how it went.
fn rs_end_now(core : Core, gv : Json?, pid : Double, name : String) -> Unit {
  let session = text(gv, "session")
  if session == "" {
    return
  }
  (core.call)(
    "process.end",
    obj([("station", str(text(gv, "station"))), ("pid", Json::number(pid)), ("session", str(session))]),
    fn(r) {
      match r {
        Ok(_) => (core.say)(@sf.t("web-main.resources.ended", args=[("name", name)]))
        Err(e) => (core.say)(@sf.t("web-main.resources.endFailed", args=[("name", name), ("error", error_text(e))]))
      }
    },
  )
}

// ── styles ────────────────

///|
/// Its 进程 (processes): the line on what is counted over the page, 16 apart.
// kept across runs: a value (no field of it changes)
let rs_processes : @ui.Style = @ui.css("w=Full gap=S4")

///|
/// The body (page): 14 apart.
// kept across runs: a value (no field of it changes)
let rs_page : @ui.Style = @ui.css("w=Full gap=S3_5")

///|
/// Nothing to see (empty): in the middle, 28 over and under.
// kept across runs: a value (no field of it changes)
let rs_empty : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, center=true, w=Full)

///|
/// The totals (tiles): in pairs on a line, 8 apart along it and between the lines.
// kept across runs: a value (no field of it changes)
let rs_tiles : @ui.Style = @ui.css("row w=Full gap=S2")

///|
/// Two of the totals side by side, sharing what their line has.
// kept across runs: a value (no field of it changes)
let rs_tile_pair : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=S2)

///|
/// A total (tile): 10 down, 12 in, 8 up; 2 apart; the card's corner on the card's ground. 144 at least: its figure
/// whole at its longest (↓ 1023 KB/s), its label beside the start of what is under it.
// kept across runs: a value (no field of it changes)
let rs_tile_box : @ui.Style = @ui.style(w=@sf.grow, min_w=S36, px=S3, pt=S2_5, pb=S2, gap=S0_5, radius=Xl3, bg=Card)

///|
/// Its label and what is under it, at its ends (tileHead).
// kept across runs: a value (no field of it changes)
let rs_tile_head : @ui.Style = @ui.css("row w=Full gap=S2 justify=JBetween")

///|
// kept across runs: a value (no field of it changes)
let rs_tile_label : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// (tileSub: subtle, cut at its end)
// kept across runs: a value (no field of it changes)
let rs_tile_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false, w=Cut)

///|
/// Its figure (tileValue: the title's 16, 600).
// kept across runs: a value (no field of it changes)
let rs_tile_value : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg, wrap=false)

///|
/// The line's room (spark: as wide as the tile, 26 high, 2 under the figure).
// kept across runs: a value (no field of it changes)
let rs_spark : @ui.Style = @ui.css("w=Full pt=S0_5")

///|
let rs_spark_h : Double = 26.0

///|
/// How far under the line's room its most stands (the viewBox's 26 - 24).
let rs_spark_top : Double = 2.0

///|
let rs_spark_line : Double = 1.25

///|
/// The ground under the line: the ink at 14%.
let rs_spark_ground : Double = 0.14

///|
/// Between the lines of the totals and of the choice where they go on in lines (their gap, S2).
let rs_flow_lines : Double = 8.0

///|
/// The choice of whose and of how, apart at its ends, 8 apart, 4 under the totals (bar).
// kept across runs: a value (no field of it changes)
let rs_bar : @ui.Style = @ui.css("row w=Full pt=S1 gap=S2 justify=JBetween align=ACenter")

///|
/// The table: its rows, each a line under it.
// kept across runs: a value (no field of it changes)
let rs_table : @ui.Style = @ui.css("w=Full")

///|
/// A row (cell's 6 by 8, a line under it).
// kept across runs: a value (no field of it changes)
let rs_row : @ui.Style = @ui.css("row w=Full align=ACenter")


///|
/// The heads' row; stacked, only the figures' heads and the end's room, at the row's end over them.
// kept across runs: a value (no field of it changes)
let rs_head_row : @ui.Style = rs_row

///|
// kept across runs: a value (no field of it changes)
let rs_head_row_stacked : @ui.Style = rs_row.then(@ui.css("justify=JEnd"))

///|
/// A stacked row's names and figures: what its row leaves beside its end, its two lines under each other.
// kept across runs: a value (no field of it changes)
let rs_stack : @ui.Style = @ui.style(w=@sf.grow, min_w=S0)

///|
/// A stacked row's figures, at its end under their heads.
// kept across runs: a value (no field of it changes)
let rs_figures_line : @ui.Style = @ui.css("row w=Full justify=JEnd")

///|
/// Beside the figures, the least each column of names keeps (a chat's title its first words, what it is and how many
/// processes after it); with less the row is stacked.
// kept across runs: a value (no field of it changes)
let rs_name_least : @ui.Space = S40

///|
/// The first column: what is left of the row's width, 6 by 8 in.
// kept across runs: a value (no field of it changes)
let rs_name_cell : @ui.Style = @ui.style(w=@sf.grow, min_w=S0, px=S2, py=S1_5)

///|
/// A process under its group: its name under its group's (processName: past the chevron and its gap).
// kept across runs: a value (no field of it changes)
let rs_process_cell : @ui.Style = @ui.style(row=true, w=@sf.grow, min_w=S0, pl=S7, pr=S2, py=S1_5, gap=S1_5, align=ACenter)

///|
/// Whose a process is (whose: about 200 at most).
// kept across runs: a value (no field of it changes)
let rs_whose_cell : @ui.Style = @ui.css("w=Cut max_w=S48 px=S2 py=S1_5")

///|
/// A figure's column: at its end.
// kept across runs: a value (no field of it changes)
let rs_number_cell : @ui.Style = @ui.css("row px=S2 py=S1_5 gap=S2 align=ACenter justify=JEnd")

///|
/// Under a stacked row's names: nothing over it but their line's own 6 under them.
// kept across runs: a value (no field of it changes)
let rs_number_under : @ui.Style = @ui.css("pt=S0")

///|
/// The sorted column's cell with its share: the share at its start, the figure at its end.
// kept across runs: a value (no field of it changes)
let rs_number_shared : @ui.Style = @ui.css("justify=JBetween")

///|
/// The row's end (endCell: 32, 2 by 4 in).
// kept across runs: a value (no field of it changes)
let rs_end_cell : @ui.Style = @ui.css("row w=S8 px=S1 py=S0_5 justify=JEnd")

///|
let rs_end_size : Double = 24.0

///|
/// A name with what it is after it, 6 apart (name).
// kept across runs: a value (no field of it changes)
let rs_name : @ui.Style = @ui.css("row w=Full gap=S1_5 align=ACenter")

///|
let rs_toggle : Double = 14.0

///|
/// A head (head: the meta's 12, 500, muted).
// kept across runs: a value (no field of it changes)
let rs_head : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)

///|
/// The column sorted by, and one under the pointer (sorted).
// kept across runs: a value (no field of it changes)
let rs_head_on : @ui.TextStyle = rs_head.then(@ui.text_style(color=Fg))

///|
/// A group's name (nameText: 500, cut at its end).
// kept across runs: a value (no field of it changes)
let rs_name_text : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let rs_cell_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
/// A process under its group (process: muted).
// kept across runs: a value (no field of it changes)
let rs_process_name : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
/// Whose (whose: muted, cut at its end).
// kept across runs: a value (no field of it changes)
let rs_whose : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
/// What it is, its pid (meta: subtle, the meta's 12).
// kept across runs: a value (no field of it changes)
let rs_meta : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
/// A figure (number: tabular, on one line).
// kept across runs: a value (no field of it changes)
let rs_figure : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false, tabular=true)

///|
// kept across runs: a value (no field of it changes)
let rs_figure_strong : @ui.TextStyle = rs_figure.then(@ui.text_style(weight=Semibold))

///|
/// How much of the most (share: 36 by 4, round, the line's grey; its fill the accent).
// kept across runs: a value (no field of it changes)
let rs_share : @ui.Style = @ui.css("row w=S9 h=S1 radius=Full bg=Line clip")

///|
// kept across runs: a value (no field of it changes)
let rs_share_fill : @ui.Style = @ui.css("h=Full bg=Accent")

///|
/// How it is read (foot): 4 apart, the meta's 12, subtle.
// kept across runs: a value (no field of it changes)
let rs_foot_box : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let rs_foot_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, w=Full)

///|
/// The line (uses: 14 apart, muted, the text's under the pointer).
// kept across runs: a value (no field of it changes)
let rs_uses : @ui.Style = @ui.css("row w=Full gap=S3_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let rs_uses_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, tabular=true)

///|
// kept across runs: a value (no field of it changes)
let rs_uses_lit : @ui.TextStyle = rs_uses_words.then(@ui.text_style(color=Fg))

///|
/// Its figures: what is left of the line, 14 apart, wrapping (usesFigures).
// kept across runs: a value (no field of it changes)
let rs_uses_figures : @ui.Style = @ui.style(row=true, w=@sf.grow, min_w=S0, gap=S3_5)

///|
let rs_uses_chevron : Double = 14.0

///|
/// Between its figures' lines where they go on in lines (their gap, S3_5).
let rs_uses_gap : Double = 14.0

///|
/// The ways of saying them, what the line has beside the chevron.
// kept across runs: a value (no field of it changes)
let rs_uses_ways : @ui.Style = @ui.style(row=true, w=@sf.grow, min_w=S0)

///|
/// Its name and its figures on a line, as far apart as the figures are.
// kept across runs: a value (no field of it changes)
let rs_uses_beside : @ui.Style = @ui.css("row gap=S3_5 align=ACenter")

///|
/// Its figures in one line, whole.
// kept across runs: a value (no field of it changes)
let rs_uses_one_line : @ui.Style = @ui.css("row gap=S3_5")

///|
/// Its name over its figures.
// kept across runs: a value (no field of it changes)
let rs_uses_over : @ui.Style = @ui.style(w=@sf.grow, min_w=S0, gap=S1)
