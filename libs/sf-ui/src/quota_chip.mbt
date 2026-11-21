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
