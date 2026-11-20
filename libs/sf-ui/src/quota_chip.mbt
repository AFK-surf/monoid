// What the core says of an allowance and of a machine, as fill chips (MeterChip): one part
// each, for every page that shows one (a profile's row and page, a station's row and peek, a chat's agents, the model
// control), drawn by fill_chip.

///|
/// Whether an allowance shows as chips (quota_chips draws any): the core can say it (`state` ok) and it has a window.
pub fn has_quota(q : Json?) -> Bool {
  chip_str(q, "state") == "ok" &&
  (match chip_field(q, "windows") {
    Some(Array(a)) => a.length() > 0
    _ => false
  })
}

///|
/// An allowance's chips (quota_chips', marked) in words, as a screen reader is told them where they are part of what is
/// pressed (a chat's agent's row of its account): each window's mark and what is left in it, `5H 62% W 18%`; "" where
/// it shows none (has_quota).
pub fn quota_chips_said(q : Json?) -> String {
  guard has_quota(q) && chip_field(q, "windows") is Some(Array(windows)) else { return "" }
  windows.map(fn(w) { quota_mark(Some(w)) + " " + quota_figure(Some(w)) }).join(" ")
}

///|
/// Each window shows its percentage in a fluid fill capsule, or a dedicated refresh capsule
/// with its short countdown (`42m`, `2d`) when spent.
/// A worded row uses window names where they fit (5h, 每周, 每月) and short marks (5h, W, M)
/// in tighter spaces. When a single line cannot hold them, model pools get their own rows.
/// `lines` (not worded): on a line of its own, as wide as what holds it (under a row's words: a station's account),
/// where the line has not the room for its chips they go on so too, by their marks.
/// Each says over it while it is pointed at what is left of it and when it fills again; `key` names them where the same
/// allowance shows more than once in a place (a list's rows: each its profile's).
pub fn quota_chips(
  c : @ui.Ctx,
  q : Json?,
  small? : Bool = false,
  marked? : Bool = true,
  worded? : Bool = false,
  lines? : Bool = false,
  gap? : Double = 8.0,
  key? : String = "quota",
) -> Unit {
  guard has_quota(q) else { return }
  let windows = match chip_field(q, "windows") {
    Some(Array(a)) => a
    _ => []
  }
  let grouped = quota_parts(windows).iter().any(fn(p) { p.0 != "" })
  if !worded {
    if lines && grouped {
      quota_chips_lines(c, windows, small, gap, key, 2)
      return
    }
    let row = fn() {
      c.box(style=quota_chips_row.then(@ui.style(gap=room(gap))), fn() {
        for w in windows {
          quota_chip(c, Some(w), small~, marked~, key~)
        }
      })
      |> ignore
    }
    if lines {
      c.box(style=quota_chips_line, one_of=true, fn() {
        row()
        quota_chips_lines(c, windows, small, gap, key, 2)
      })
      |> ignore
    } else {
      row()
    }
    return
  }
  // (its ways, each shorter than the one before, the first that fits the line's room shown: Ctx::box one_of)
  c.box(style=quota_chips_line, one_of=true, fn() {
    for form in 1..<3 {
      c.box(style=quota_chips_row.then(@ui.style(gap=room(gap))), fn() {
        for w in windows {
          let (mark, words) = quota_worded(Some(w), form)
          fill_chip(
            c,
            chip_left(Some(w)),
            chip_str(Some(w), "level"),
            mark,
            words,
            small~,
            key=key + "/" + chip_str(Some(w), "mark") + "/" + form.to_string(),
            label_muted=true,
            refill=quota_is_refill(Some(w)),
            said=quota_said(Some(w)),
          )
        }
      })
      |> ignore
    }
    quota_chips_lines(c, windows, small, gap, key, 1)
  })
  |> ignore
}

///|
/// The group display name of a window when its label has a `" · "` suffix (such as `"5 小时 · Gemini"` or
/// `"每周 · Claude / GPT"`), or its `scope` otherwise.
fn quota_group_name(w : Json) -> String {
  let label = chip_str(Some(w), "label")
  match label.find(" · ") {
    Some(i) => label.clamped_view(start=i + 3).to_owned()
    None => chip_str(Some(w), "scope")
  }
}

///|
/// A window's mark within a group `group`: when `group` is already shown as the line's group heading, strip the
/// repeated `group + " "` prefix from the window's mark (`"Claude / GPT 5H"` -> `"5H"`).
fn quota_part_mark(group : String, w : Json?) -> String {
  let mark = quota_mark(w)
  let prefix = group + " "
  if group != "" && mark.has_prefix(prefix) {
    mark.clamped_view(start=prefix.length()).to_owned()
  } else {
    mark
  }
}

///|
/// The lines an allowance's windows divide into when one line cannot hold them all: two windows stay together (and
/// wrap only if the line is narrower than a pair); more than two put the account's own windows on the first line (four
/// unscoped windows balanced two and two), each multi-window model pool (`scope` shared by more than one window, such as
/// Gemini 5H / Gemini W and Claude / GPT 5H / Claude / GPT W) on its own line with its group heading, and single-window
/// model caps (`Fable`, `Opus`, `Sonnet`) together on theirs.
fn quota_parts(windows : Array[Json]) -> Array[(String, Array[Json])] {
  if windows.length() <= 1 {
    return if windows.length() == 0 { [] } else { [("", windows)] }
  }
  let base : Array[Json] = []
  let counts : Map[String, Int] = Map([])
  let order : Array[String] = []
  for w in windows {
    let s = chip_str(Some(w), "scope")
    if s == "" {
      base.push(w)
    } else {
      let c = counts.get(s).unwrap_or(0)
      if c == 0 {
        order.push(s)
      }
      counts[s] = c + 1
    }
  }
  let parts : Array[(String, Array[Json])] = []
  if base.length() >= 2 && order.length() == 0 {
    let half = (base.length() + 1) / 2
    parts.push(("", base[:half].to_owned()))
    parts.push(("", base[half:].to_owned()))
  } else if base.length() > 0 {
    parts.push(("", base))
  }
  let has_pool = base.length() == 0 && order.iter().any(fn(s) { counts.get(s).unwrap_or(0) > 1 })
  let single : Array[Json] = []
  for s in order {
    let group_wins = windows.filter(fn(w) { chip_str(Some(w), "scope") == s })
    let gname = if group_wins.length() > 0 { quota_group_name(group_wins[0]) } else { "" }
    if counts.get(s).unwrap_or(0) > 1 || (has_pool && gname != "" && chip_str(Some(group_wins[0]), "mark").has_prefix(gname + " ")) {
      parts.push((gname, group_wins))
    } else {
      for w in group_wins {
        single.push(w)
      }
    }
  }
  if single.length() > 0 {
    parts.push(("", single))
  }
  parts
}

///|
/// An allowance's chips where no one line holds them (quota_chips' last way): the account's windows a line, each said
/// `account`'s way (quota_worded's: 1 its name and its figure, 每周 │ 62%; 2 by its mark, where the line before was),
/// each multi-window model pool a line of its own with its group column on the left and short `[5h │ %] [W │ %]` capsules
/// on the right, and what single models have to themselves (`scope`) a line under it, each by its model (Fable 46%: a
/// model's name says whose it is, where W says little without a tip); a line going on in lines where even it has not
/// the room, every chip whole.
fn quota_chips_lines(c : @ui.Ctx, windows : Array[Json], small : Bool, gap : Double, key : String, account : Int) -> Unit {
  let parts = quota_parts(windows)
  let label_w = parts.fold(init=0.0, fn(m, p) {
    if p.0 == "" { m } else { dmax(m, c.words_across(p.0, nav_quota_group).ceil()) }
  })
  c.box(style=quota_chips_parts, fn() {
    for part in parts {
      c.box(style=quota_chips_part.then(@ui.style(gap=room(gap))), flow=part.0 == "", line_gap=quota_chips_part_lines, fn() {
        if part.0 != "" {
          c.box(style=@ui.style(w=Fixed(label_w)), fn() {
            c.text(part.0, style=nav_quota_group) |> ignore
          })
          |> ignore
        }
        let draw_chips = fn() {
          for w in part.1 {
            let form = if chip_str(Some(w), "scope") != "" { 2 } else { account }
            let (mark0, words) = quota_worded(Some(w), form)
            let mark = if part.0 != "" { quota_part_mark(part.0, Some(w)) } else { mark0 }
            fill_chip(
              c,
              chip_left(Some(w)),
              chip_str(Some(w), "level"),
              mark,
              words,
              small~,
              key=key + "/" + chip_str(Some(w), "mark") + "/lines",
              label_muted=true,
              refill=quota_is_refill(Some(w)),
              said=quota_said(Some(w)),
            )
          }
        }
        if part.0 != "" {
          c.box(style=quota_chips_part.then(@ui.style(gap=room(gap))), flow=true, line_gap=quota_chips_part_lines, draw_chips)
          |> ignore
        } else {
          draw_chips()
        }
      })
      |> ignore
    }
  })
  |> ignore
}

///|
/// The lines of an allowance no one line holds: as wide as what holds them, a line under another as far as the lines
/// a line goes on in.
// kept across runs: a value (no field of it changes)
let quota_chips_parts : @ui.Style = @ui.css("w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let quota_chips_part : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let quota_chips_part_lines : Double = 6.0

///|
// kept across runs: a value (no field of it changes)
let nav_quota_group : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, leading=L4, wrap=false)

///|
/// Use the same hour and day units on both sides of a quota chip. In a scoped
/// mark only its final duration changes (for example, "Gemini 5H").
pub fn quota_mark(w : Json?) -> String {
  let mark = chip_str(w, "mark")
  if !mark.has_suffix("H") && !mark.has_suffix("D") {
    return mark
  }
  let start = mark.rev_find(" ").unwrap_or(-1) + 1
  let end = mark.length() - 1
  if start < end && mark.clamped_view(start~, end~).iter().all(fn(c) { c.is_ascii_digit() }) {
    mark.clamped_view(end~).to_owned() + (if mark.has_suffix("H") { "h" } else { "d" })
  } else {
    mark
  }
}

///|
/// A quota chip shows when an empty window refills, if known.
pub fn quota_figure(w : Json?) -> String {
  let left = chip_left(w)
  if left == 0 {
    let refill = chip_str(w, "refillShort")
    if refill != "" {
      return refill
    }
  }
  left.to_string() + "%"
}

///|
/// Whether `w` is rendered in its dedicated refill-countdown capsule state.
pub fn quota_is_refill(w : Json?) -> Bool {
  chip_left(w) == 0 && chip_str(w, "refillShort") != ""
}

///|
/// Numeric durations always use the compact mark. Other windows use their name while it fits.
fn quota_worded(w : Json?, form : Int) -> (String, String) {
  let mark = quota_mark(w)
  let label = chip_str(w, "label")
  let typed = mark != chip_str(w, "mark")
  let name = if form < 2 && !typed && label != "" {
    label.replace(old=" · ", new=" ")
  } else {
    mark
  }
  (name, quota_figure(w))
}

///|
/// One window of an allowance, or the one an agent is short of: what is left in it, filled
/// as far as that, its mark before it where `marked`; `compact` gives a small, unmarked figure less padding when the
/// mark is above it; over it while pointed at, `said` (what is left and when it fills again: quota_said), the chip
/// `key`'s.
pub fn quota_chip(
  c : @ui.Ctx,
  w : Json?,
  small? : Bool = false,
  compact? : Bool = false,
  marked? : Bool = true,
  key? : String = "quota",
  said? : String,
) -> Unit {
  fill_chip(
    c,
    chip_left(w),
    chip_str(w, "level"),
    if marked { quota_mark(w) } else { "" },
    quota_figure(w),
    small~,
    compact~,
    key=key + "/" + chip_str(w, "mark"),
    label_muted=true,
    refill=quota_is_refill(w),
    said=said.unwrap_or(quota_said(w)),
  )
}

///|
/// What is left of an allowance's window, in words, and
/// when it fills again on a line of its own (QuotaBars' tip).
pub fn quota_said(w : Json?) -> String {
  let said = quota_left(w)
  match chip_str(w, "refills") {
    "" => said
    refills => said + "\n" + refills
  }
}

///|
/// What is left of an allowance's window, in words: 每周剩余 78% (剩余 78% where it has no name).
fn quota_left(w : Json?) -> String {
  let label = chip_str(w, "label")
  let left = chip_left(w).to_string()
  if label != "" {
    t("web-main.quota.left", args=[("label", label), ("left", left)])
  } else {
    t("web-main.quota.leftAlone", args=[("left", left)])
  }
}

///|
/// A machine's chips' line one way (in words, or by their figures), 8 apart.
// kept across runs: a value (no field of it changes)
let meter_line_way : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let meter_chips_line : @ui.Style = @ui.css("row w=Full gap=S1 align=ACenter")

///|
fn chip_field(v : Json?, key : String) -> Json? {
  match v {
    Some(Object(o)) => o.get(key)
    _ => None
  }
}

///|
fn chip_str(v : Json?, key : String) -> String {
  match chip_field(v, key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// What is left (0–100) of a window or a meter (`left`).
fn chip_left(v : Json?) -> Int {
  let n = match chip_field(v, "left") {
    Some(Number(x, ..)) => x.to_int()
    _ => 0
  }
  if n < 0 {
    0
  } else if n > 100 {
    100
  } else {
    n
  }
}

///|
/// The chips in a line, in its middle.
// kept across runs: a value (no field of it changes)
let quota_chips_row : @ui.Style = @ui.css("row align=ACenter")

///|
/// A worded line of them: as wide as what holds it, the room its ways are fitted to (Ctx::box one_of).
// kept across runs: a value (no field of it changes)
let quota_chips_line : @ui.Style = @ui.css("row w=Full align=ACenter")
