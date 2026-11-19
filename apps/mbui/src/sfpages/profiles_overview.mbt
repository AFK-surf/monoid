// Workspace profiles overview (Profile 汇总页):
// Minimal, graphic-first summary for staggered account reset schedules:
// - Wide (`宽排法`): default view of `Place("profiles")`, listed first in the profiles sidebar (`概览`).
// - Narrow (`窄排法`): `账号 | 概览` switch at the top of `Profiles` (defaults to the original `账号` list).
// Two charts per model pool, both the core's (`profilesOverview`), hour by hour:
// 1. `额度与恢复`: what the pool had left the last 48 hours as its accounts were read, and the week on as foreseen
//    (refills stepping up, red where it goes without);
// 2. `消耗速度`: each of the last 24 hours and the next 24 against the most it could spend an hour and last the week
//    (0, the middle line), in %/h: above it green (spent less than that), under it red (more, or going without);
// and under them `输出速度`: how fast its models wrote (tokens a second, a sliding window: the core's `speed`) over the
// last 6 hours, 24 hours or week, as chosen.

///|
/// A model's pool as the core makes it (`profilesOverview`: client/core-ts views/profiles-overview.ts).
#derive(Eq)
priv struct ModelPool {
  title : String
  ready : Int
  total : Int
  now_pct : Int
  exhaust_hours : Int?
  /// what it spends an hour now against what it could keep up (%/h): negative over it, or going without
  net_now : Double
  over_pace : Bool
  /// percent left an hour apart: 48 hours back (0), now (48), 168 on (216)
  traj : Array[Double]
  /// each of the 168 hours on, whether it goes without (of the core's `starveSpans`)
  will_starve : Array[Bool]
  /// each hour against what it could keep up (%/h): the last 24 (0..23), the next 24 as foreseen (24..47)
  hourly_net : Array[Double]
  /// how many more accounts of its usual plan it would take to keep up with its pace (0: it keeps up)
  needed_accounts : Int
  /// its models' tokens a second (-1: none timed then), over each span `ov_speed_span` chooses (the core's `speed`:
  /// quarters, hours, days); empty where none of its calls was timed
  speed : Array[Array[Double]]
}

///|
fn ov_num(v : Json?, key : String) -> Double {
  match field(v, key) {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
fn ov_pool_of(j : Json) -> ModelPool {
  let v = Some(j)
  let nums = fn(key : String) -> Array[Double] {
    items(v, key).map(fn(x) {
      match x {
        Number(n, ..) => n
        _ => 0.0
      }
    })
  }
  {
    title: text(v, "title"),
    ready: count(v, "ready"),
    total: count(v, "total"),
    now_pct: count(v, "nowPct"),
    exhaust_hours: match field(v, "exhaustHours") {
      Some(Number(n, ..)) => Some(n.to_int())
      _ => None
    },
    net_now: ov_num(v, "netPerHour"),
    over_pace: flag(v, "overPace"),
    traj: nums("traj"),
    will_starve: {
      let starve = Array::make(168, false)
      let spans = nums("starveSpans")
      for i = 0; i + 1 < spans.length(); i = i + 2 {
        for h = spans[i].to_int(); h < spans[i + 1].to_int() && h < 168; h = h + 1 {
          starve[h] = true
        }
      }
      starve
    },
    hourly_net: nums("hourlyNet"),
    needed_accounts: count(v, "neededAccounts"),
    speed: match field(v, "speed") {
      Some(Object(_)) as sp =>
        ["quarters", "hours", "days"].map(k => {
          items(sp, k).map(fn(x) {
            match x {
              Number(n, ..) => n
              _ => -1.0
            }
          })
        })
      _ => []
    },
  }
}

///|
/// Which span `输出速度` shows: 0 the last 6 hours, 1 the last 24, 2 the last week (the page's, every pool's).
let ov_speed_span : @signals.Signal[Int] = @signals.signal(1, same=fn(a, b) { a == b })

///|
fn ov_speed_spans() -> Array[String] {
  if ov_en() {
    ["6 hours", "24 hours", "7 days"]
  } else {
    ["6小时", "24小时", "7天"]
  }
}

///|
/// The span's points as the core said them, none where nothing of the pool's was timed.
fn ov_speed_points(pool : ModelPool) -> Array[Double] {
  pool.speed.get(ov_speed_span.get()).unwrap_or([])
}

///|
/// Whether any of the span's windows was timed.
fn ov_speed_known(points : Array[Double]) -> Bool {
  points.iter().any(fn(v) { v >= 0.0 })
}

///|
/// A speed in words: whole tokens a second, under 10 to a tenth.
fn ov_tps(v : Double) -> String {
  let whole = if v < 10.0 {
    let tenths = (v * 10.0).round().to_int()
    if tenths % 10 == 0 { (tenths / 10).to_string() } else { (tenths / 10).to_string() + "." + (tenths % 10).to_string() }
  } else {
    v.round().to_int().to_string()
  }
  whole + " tok/s"
}

///|
/// The speed chart's top: the next round speed over what it shows.
fn ov_speed_top(points : Array[Double]) -> Double {
  let mut most = 0.0
  for v in points {
    if v > most {
      most = v
    }
  }
  for step in [10.0, 20.0, 40.0, 60.0, 80.0, 100.0, 120.0, 160.0, 200.0, 300.0, 400.0, 600.0, 800.0, 1000.0] {
    // (a tenth over what it shows at least: its line never on the top's)
    if most * 1.1 <= step {
      return step
    }
  }
  (most * 1.1 / 500.0).ceil() * 500.0
}

///|
/// Each point the speed of the window that ends there, the last now's at the right edge, the first as far in as its
/// span says (the points end a step apart over the whole span); a run of windows timed one line, one alone a dot, those
/// not timed a gap.
fn ov_speed_shapes(points : Array[Double], top : Double, w : Double, h : Double) -> Array[@ui.Shape] {
  let n = points.length()
  if w <= 10.0 || n < 2 || top <= 0.0 {
    return []
  }
  let t = @sf.theme()
  let pad_top = 6.0
  let pad_bot = 6.0
  let ph = h - pad_top - pad_bot
  let x_of = fn(i : Int) -> Double { (i + 1).to_double() / n.to_double() * w }
  let y_of = fn(v : Double) -> Double { pad_top + (1.0 - @cmp.minimum(1.0, v / top)) * ph }
  let shapes : Array[@ui.Shape] = []
  for yg in [y_of(top), y_of(top / 2.0), y_of(0.0)] {
    shapes.push(@ui.shape_of([([0.0, yg, w, yg], false)], stroke=t.p.line, width=1.0))
  }
  let ink = t.p.accent
  let mut i = 0
  while i < n {
    if points[i] < 0.0 {
      i += 1
      continue
    }
    let line : Array[Double] = []
    let start = i
    while i < n && points[i] >= 0.0 {
      line.push(x_of(i))
      line.push(y_of(points[i]))
      i += 1
    }
    if i - start == 1 {
      shapes.push(@ui.shape_of([(ov_circle_poly(line[0], line[1], 2.6), true)], fill=ink))
    } else {
      let area = line.copy()
      area.push(x_of(i - 1))
      area.push(y_of(0.0))
      area.push(x_of(start))
      area.push(y_of(0.0))
      shapes.push(@ui.shape_of([(area, true)], fill=@sf.alpha(ink, if t.dark { 0.10 } else { 0.08 })))
      shapes.push(@ui.shape_of([(line, false)], stroke=ink, width=2.0))
    }
  }
  if points[n - 1] >= 0.0 {
    let x = x_of(n - 1)
    let y = y_of(points[n - 1])
    shapes.push(@ui.shape_of([(ov_circle_poly(x, y, 4.6), true)], fill=t.p.card))
    shapes.push(@ui.shape_of([(ov_circle_poly(x, y, 3.1), true)], fill=ink))
  }
  shapes
}

///|
/// The speed chart's times under it, its span's from its start to now.
fn ov_speed_hours() -> Array[String] {
  let now = if ov_en() { "Now" } else { "现在" }
  match ov_speed_span.get() {
    0 => ["-6h", "-4.5h", "-3h", "-1.5h", now]
    2 => if ov_en() { ["-7d", "", "-3.5d", "", now] } else { ["-7天", "", "-3.5天", "", now] }
    _ => ["-24h", "-18h", "-12h", "-6h", now]
  }
}

///|
/// What a pool short of accounts says under its charts: how many more of its usual plan would keep it going.
fn ov_needed_words(n : Int) -> String {
  if ov_en() {
    "Needs ~" + n.to_string() + (if n == 1 { " more account" } else { " more accounts" }) + " of this plan at current pace"
  } else {
    "按当前消耗速度，还需约 " + n.to_string() + " 个同档账号才能不断档"
  }
}

///|
let ov_picked_pool : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })

///|
fn profiles_overview_reset() -> Unit {
  ov_picked_pool.set("")
  ov_speed_span.set(1)
}

///|
let ov_chart_h : Double = 118.0

///|
fn ov_en() -> Bool {
  @sf.language() == "en"
}

///|
// kept across runs: a constant unit-circle lookup table (never mutated)
let ov_unit_circle : Array[(Double, Double)] = [
  (1.0, 0.0),
  (0.92388, 0.38268),
  (0.70711, 0.70711),
  (0.38268, 0.92388),
  (0.0, 1.0),
  (-0.38268, 0.92388),
  (-0.70711, 0.70711),
  (-0.92388, 0.38268),
  (-1.0, 0.0),
  (-0.92388, -0.38268),
  (-0.70711, -0.70711),
  (-0.38268, -0.92388),
  (0.0, -1.0),
  (0.38268, -0.92388),
  (0.70711, -0.70711),
  (0.92388, -0.38268),
]

///|
fn ov_circle_poly(cx : Double, cy : Double, r : Double) -> Array[Double] {
  let pts : Array[Double] = []
  for p in ov_unit_circle {
    pts.push(cx + r * p.0)
    pts.push(cy + r * p.1)
  }
  pts
}

///|
fn ov_bar_poly(x : Double, y : Double, w : Double, h : Double, rt : Double, rb : Double) -> Array[Double] {
  if w <= 0.0 || h <= 0.0 {
    return []
  }
  let r_top = @cmp.minimum(rt, @cmp.minimum(w / 2.0, h / 2.0))
  let r_bot = @cmp.minimum(rb, @cmp.minimum(w / 2.0, h / 2.0))
  let pts : Array[Double] = []
  if r_top > 0.5 {
    pts.push(x)
    pts.push(y + r_top)
    pts.push(x + r_top * 0.2929)
    pts.push(y + r_top * 0.2929)
    pts.push(x + r_top)
    pts.push(y)
  } else {
    pts.push(x)
    pts.push(y)
  }
  if r_top > 0.5 {
    pts.push(x + w - r_top)
    pts.push(y)
    pts.push(x + w - r_top * 0.2929)
    pts.push(y + r_top * 0.2929)
    pts.push(x + w)
    pts.push(y + r_top)
  } else {
    pts.push(x + w)
    pts.push(y)
  }
  if r_bot > 0.5 {
    pts.push(x + w)
    pts.push(y + h - r_bot)
    pts.push(x + w - r_bot * 0.2929)
    pts.push(y + h - r_bot * 0.2929)
    pts.push(x + w - r_bot)
    pts.push(y + h)
  } else {
    pts.push(x + w)
    pts.push(y + h)
  }
  if r_bot > 0.5 {
    pts.push(x + r_bot)
    pts.push(y + h)
    pts.push(x + r_bot * 0.2929)
    pts.push(y + h - r_bot * 0.2929)
    pts.push(x)
    pts.push(y + h - r_bot)
  } else {
    pts.push(x)
    pts.push(y + h)
  }
  pts
}

///|
fn ov_push_v_dash(
  out : Array[@ui.Shape],
  x : Double,
  y0 : Double,
  y1 : Double,
  dash : Double,
  gap : Double,
  ink : Int64,
  width : Double,
) -> Unit {
  let mut y = y0
  while y < y1 {
    let ye = @cmp.minimum(y1, y + dash)
    out.push(@ui.shape_of([([x, y, x, ye], false)], stroke=ink, width~))
    y += dash + gap
  }
}

///|
fn ov_needs_fix(e : Json?) -> Bool {
  let p = field(e, "profile")
  flag(e, "look") || text(field(e, "state"), "tone") == "red" || text(p, "checkTone") == "red"
}

///|
fn ov_is_main_week(mk : String, sc : String, lbl : String) -> Bool {
  if sc != "" {
    return false
  }
  if mk == "W" || mk == "M" {
    return true
  }
  !lbl.contains("·") &&
  (lbl.contains("每周") || lbl.contains("每月") || lbl.contains("Weekly") || lbl.contains("Monthly"))
}

///|
fn ov_refill_minutes(s : String) -> Int {
  if s == "" {
    return 999999
  }
  let chars = s.to_array()
  let len = chars.length()
  let mut i = 0
  let mut total = 0
  let mut matched = false
  while i < len {
    let ch = chars[i]
    if ch >= '0' && ch <= '9' {
      let mut n = 0
      while i < len && chars[i] >= '0' && chars[i] <= '9' {
        n = n * 10 + (chars[i].to_int() - '0'.to_int())
        i += 1
      }
      while i < len && chars[i] == ' ' {
        i += 1
      }
      if i < len {
        let u = chars[i]
        if u == '天' || u == 'd' || u == 'D' {
          total += n * 1440
          matched = true
        } else if u == '小' || u == 'h' || u == 'H' {
          total += n * 60
          matched = true
        } else if u == '分' || u == 'm' || u == 'M' {
          total += n
          matched = true
        }
      }
    } else {
      i += 1
    }
  }
  if matched {
    @cmp.maximum(1, total)
  } else if s.contains("即将") || s.contains("now") || s.contains("soon") {
    1
  } else {
    999999
  }
}

///|
fn ov_hours_short(h : Int) -> String {
  let en = ov_en()
  if h <= 1 {
    "1h"
  } else if h < 36 {
    h.to_string() + "h"
  } else {
    let d = (h + 12) / 24
    if en { d.to_string() + "d" } else { d.to_string() + "天" }
  }
}

///|
fn ov_account_name(e : Json?) -> String {
  let p = field(e, "profile")
  let n = text(p, "name")
  if n != "" { n } else { text(e, "title") }
}

///|
fn ov_issue_short(e : Json?) -> String {
  let p = field(e, "profile")
  let st = text(field(e, "state"), "text")
  if st != "" {
    st
  } else {
    let ck = text(p, "checkText")
    if ck != "" && ck != "可用" {
      ck
    } else if ov_en() {
      "Needs attention"
    } else {
      "需处理"
    }
  }
}

///|
fn ov_issue_action_label(e : Json?) -> String {
  let en = ov_en()
  let p = field(e, "profile")
  let st = text(field(e, "state"), "text")
  if !flag(e, "usable") && (st.contains("离线") || st.to_lower().contains("offline")) {
    if en { "Open" } else { "查看" }
  } else if text(e, "group") == "key" || text(field(p, "access"), "kind") != "subscription" {
    if en { "Update key" } else { "更换 key" }
  } else if text(p, "kindText") != "终端里的登录" &&
    (text(p, "checkTone") != "green" || st.contains("登录") || st.to_lower().contains("sign")) {
    @sf.t("web-pages.signIn.again")
  } else if en {
    "Open"
  } else {
    "查看"
  }
}

///|
fn ov_expiring_waste(e : Json?) -> (Int, String)? {
  if ov_needs_fix(e) || text(e, "group") == "key" {
    return None
  }
  let q = field(field(e, "profile"), "quota")
  if text(q, "state") != "ok" {
    return None
  }
  for w in items(q, "windows") {
    let wv = Some(w)
    let mk = text(wv, "mark")
    let sc = text(wv, "scope")
    let lbl = text(wv, "label")
    if ov_is_main_week(mk, sc, lbl) {
      let left = count(wv, "left")
      let rf = text(wv, "refills")
      let mins = ov_refill_minutes(rf)
      if mins <= 2160 && left >= 50 {
        return Some((left, ov_hours_short((mins + 30) / 60)))
      }
      break
    }
  }
  None
}

///|
/// Deduplicated API keys that report a credit/balance figure (skips stateless keys and collapses multi-station copies).
fn ov_balance_keys(list : Array[Json]) -> Array[(Json, String)] {
  let out : Array[(Json, String)] = []
  for e in list {
    let ev = Some(e)
    if text(ev, "group") == "key" && !ov_needs_fix(ev) && flag(ev, "usable") {
      let kq = field(field(ev, "profile"), "quota")
      if text(kq, "state") == "ok" {
        let cr = text(kq, "creditsText")
        let dt = text(kq, "detail")
        let bal = if cr != "" { cr } else { dt }
        if bal != "" {
          let nm = ov_account_name(ev)
          if !out.iter().any(fn(x) { ov_account_name(Some(x.0)) == nm && x.1 == bal }) {
            out.push((e, bal))
          }
        }
      }
    }
  }
  out
}

///|
pub fn profiles_side_summary(list : Array[Json]) -> (String, String) {
  let mut broken = 0
  let mut waste = 0
  for e in list {
    let ev = Some(e)
    if ov_needs_fix(ev) {
      broken += 1
    } else if ov_expiring_waste(ev) is Some(_) {
      waste += 1
    }
  }
  let total = broken + waste
  if total > 0 {
    let words = if ov_en() {
      total.to_string() + " need attention"
    } else {
      total.to_string() + " 项需处理"
    }
    (words, if broken > 0 { "red" } else { "amber" })
  } else {
    ("", "")
  }
}

///|
fn ov_account_mark_node(parent : @view.View, e : Json?, side? : Double = 18.0) -> Unit {
  let p = field(e, "profile")
  @sf.provider_logo_node(parent, text(p, "runtime"), text(field(p, "access"), "kind"), side, text(p, "providerMark"))
  |> ignore
}

///|
fn ov_open_account(
  core : Core,
  open_profile : ((String, String) -> Unit)?,
  e : Json?,
) -> Unit {
  let address = text(e, "station")
  let id = text(field(e, "profile"), "id")
  match open_profile {
    Some(go) => go(address, id)
    None => (core.push)(@settings.Route::Profile(address, id))
  }
}

///|
fn ov_trajectory_shapes(pool : ModelPool, w : Double, h : Double) -> Array[@ui.Shape] {
  if w <= 10.0 || pool.traj.length() < 217 {
    return []
  }
  let t = @sf.theme()
  let pad_top = 6.0
  let pad_bot = 6.0
  let ph = h - pad_top - pad_bot
  let x_of = fn(idx : Int) -> Double { idx.to_double() / 216.0 * w }
  let y_of = fn(pct : Double) -> Double {
    let c = @cmp.maximum(0.0, @cmp.minimum(100.0, pct))
    pad_top + (1.0 - c / 100.0) * ph
  }
  let y_bot = y_of(0.0)
  let y_mid = y_of(50.0)
  let y_top = y_of(100.0)
  let shapes : Array[@ui.Shape] = []

  for yg in [y_top, y_mid, y_bot] {
    shapes.push(@ui.shape_of([([0.0, yg, w, yg], false)], stroke=t.p.line, width=1.0))
  }

  let mut idx = 48
  while idx < 216 {
    if pool.traj[idx] <= 0.4 && pool.traj[idx + 1] <= 0.4 {
      let start_i = idx
      while idx < 216 && pool.traj[idx + 1] <= 0.4 {
        idx += 1
      }
      let x0 = x_of(start_i)
      let x1 = x_of(idx)
      if x1 > x0 + 0.5 {
        shapes.push(
          @ui.shape_of([([x0, y_top, x1, y_top, x1, y_bot, x0, y_bot], true)], fill=@sf.alpha(t.p.red, 0.09)),
        )
        shapes.push(@ui.shape_of([([x0, y_bot, x1, y_bot], false)], stroke=t.p.red, width=2.4))
      }
    } else {
      idx += 1
    }
  }

  let past_line : Array[Double] = []
  for i in 0..=48 {
    past_line.push(x_of(i))
    past_line.push(y_of(pool.traj[i]))
  }
  let past_area = past_line.copy()
  past_area.push(x_of(48))
  past_area.push(y_bot)
  past_area.push(0.0)
  past_area.push(y_bot)
  shapes.push(@ui.shape_of([(past_area, true)], fill=@sf.alpha(t.p.text, if t.dark { 0.12 } else { 0.07 })))
  shapes.push(@ui.shape_of([(past_line, false)], stroke=t.p.text, width=2.0))

  let refill_dots : Array[(Double, Double)] = []
  for step in 0..<168 {
    let i0 = 48 + step
    let i1 = i0 + 1
    let v0 = pool.traj[i0]
    let v1 = pool.traj[i1]
    let x0 = x_of(i0)
    let x1 = x_of(i1)
    let y0 = y_of(v0)
    let y1 = y_of(v1)
    let is_jump = v1 > v0 + 1.8
    let starve = pool.will_starve[step]
    let seg_ink = if is_jump || !starve { t.p.green } else { t.p.red }

    if v0 > 0.2 || v1 > 0.2 {
      shapes.push(
        @ui.shape_of(
          [([x0, y0, x1, y1, x1, y_bot, x0, y_bot], true)],
          fill=@sf.alpha(seg_ink, if starve { 0.12 } else { 0.10 }),
        ),
      )
    }

    if is_jump {
      shapes.push(@ui.shape_of([([x0, y0, x1, y1], false)], stroke=t.p.green, width=2.0))
      if v1 - v0 >= 6.0 {
        refill_dots.push((x1, y1))
      }
    } else if !(v0 <= 0.4 && v1 <= 0.4) && step % 3 != 2 {
      shapes.push(@ui.shape_of([([x0, y0, x1, y1], false)], stroke=seg_ink, width=2.0))
    }
  }

  let x_now = x_of(48)
  let y_now = y_of(pool.traj[48])
  ov_push_v_dash(shapes, x_now, y_top, y_bot, 3.5, 3.0, @sf.alpha(t.p.text, 0.28), 1.0)

  for pt in refill_dots {
    shapes.push(@ui.shape_of([(ov_circle_poly(pt.0, pt.1, 3.6), true)], fill=t.p.card))
    shapes.push(@ui.shape_of([(ov_circle_poly(pt.0, pt.1, 2.3), true)], fill=t.p.green))
  }

  shapes.push(@ui.shape_of([(ov_circle_poly(x_now, y_now, 4.6), true)], fill=t.p.card))
  shapes.push(@ui.shape_of([(ov_circle_poly(x_now, y_now, 3.1), true)], fill=t.p.text))

  shapes
}

///|
/// A rate of the pool an hour in words: under 10 to a tenth (1.8%/h, 2%/h), else whole (12%/h); `signed`, above 0
/// with its plus (+0.9%/h).
fn ov_rate(v : Double, signed? : Bool = false) -> String {
  let a = v.abs()
  let words = if a < 0.05 {
    "0"
  } else if a < 10.0 {
    let tenths = (a * 10.0).round().to_int()
    let whole = tenths / 10
    let part = tenths % 10
    if part == 0 { whole.to_string() } else { whole.to_string() + "." + part.to_string() }
  } else {
    a.round().to_int().to_string()
  }
  let sign = if words == "0" { "" } else if v < 0.0 { "-" } else if signed { "+" } else { "" }
  sign + words + "%/h"
}

///|
/// The pace chart's reach each way from 0: the next round rate over what it shows.
fn ov_net_top(p : ModelPool) -> Double {
  let mut most = 0.0
  for n in p.hourly_net {
    if n.abs() > most {
      most = n.abs()
    }
  }
  for step in [0.5, 1.0, 2.0, 4.0, 6.0, 8.0, 10.0, 16.0, 20.0, 30.0, 40.0, 60.0, 80.0, 100.0] {
    if most <= step {
      return step
    }
  }
  100.0
}

///|
/// Each hour against the pace the pool could keep up all week (0, the line through the middle): the last 24 left of
/// now, the next 24 as foreseen right of it (lighter); above it green where it spent less than that, under it red where
/// it spent more or goes without, each bar from 0 rounded at its far end.
fn ov_net_shapes(pool : ModelPool, scale_top : Double, w : Double, h : Double) -> Array[@ui.Shape] {
  if w <= 10.0 || pool.hourly_net.length() < 48 || scale_top <= 0.0 {
    return []
  }
  let t = @sf.theme()
  let pad_top = 6.0
  let pad_bot = 6.0
  let half = (h - pad_top - pad_bot) / 2.0
  let y_top = pad_top
  let y_zero = pad_top + half
  let y_bot = pad_top + half * 2.0
  let shapes : Array[@ui.Shape] = []
  for yg in [y_top, y_bot] {
    shapes.push(@ui.shape_of([([0.0, yg, w, yg], false)], stroke=t.p.line, width=1.0))
  }
  ov_push_v_dash(shapes, 0.5 * w, y_top, y_bot, 3.5, 3.0, @sf.alpha(t.p.text, 0.28), 1.0)
  let slot_w = w / 48.0
  let bar_w = @cmp.minimum(9.0, @cmp.maximum(1.5, slot_w * 0.64))
  for i in 0..<48 {
    let v = pool.hourly_net[i]
    if v.abs() < 0.05 {
      continue
    }
    let bh = @cmp.maximum(2.0, @cmp.minimum(1.0, v.abs() / scale_top) * (half - 1.0))
    let x = (i.to_double() + 0.5) * slot_w - bar_w / 2.0
    let ink = if v >= 0.0 { t.p.green } else { t.p.red }
    let ink = if i >= 24 { @sf.alpha(ink, 0.42) } else { ink }
    let poly = if v >= 0.0 {
      ov_bar_poly(x, y_zero - bh, bar_w, bh, bar_w / 2.0, 0.0)
    } else {
      ov_bar_poly(x, y_zero, bar_w, bh, 0.0, bar_w / 2.0)
    }
    if poly.length() > 0 {
      shapes.push(@ui.shape_of([(poly, true)], fill=ink))
    }
  }
  shapes.push(@ui.shape_of([([0.0, y_zero, w, y_zero], false)], stroke=@sf.alpha(t.p.text, 0.34), width=1.25))
  shapes
}

///|
/// A chart's hours under it, from its first to its last, `now`'s (its index) the stronger: as far in as the y axis's
/// labels' column (`lead`) and the gap after it.
fn ov_time_axis_node(parent : @view.View, lead : Double, labels : () -> Array[String], now : Int) -> Unit {
  parent.box(fn(axis) {
    axis.row(Is(true)).padding(Is((lead + 6.0, 4.0, 0.0, 0.0))).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
    for i in 0..<5 {
      @sf.words_node(axis, fn() { labels().get(i).unwrap_or("") }, fn() { if i == now { ug_peak } else { ug_grid_label } })
      .shrink(Is(0.0))
      |> ignore
    }
  })
  |> ignore
}

///|
fn ov_quota_hours() -> Array[String] {
  if ov_en() {
    ["-2d", "Now", "+2d", "+4d", "+7d"]
  } else {
    ["-2天", "现在", "+2天", "+4天", "+7天"]
  }
}

///|
fn ov_burn_hours() -> Array[String] {
  ["-24h", "-12h", if ov_en() { "Now" } else { "现在" }, "+12h", "+24h"]
}

///|
/// The y axis's labels' column: as wide as its widest at the system's size of words.
let ov_axis_w : Double = 36.0

///|
let ov_burn_axis_w : Double = 46.0

///|
/// Single-line reactive pool tab (`Claude      ● 4/7`) at `8px` concentric inset (`ug_row_corner`). Its title, its count
/// and whether it runs short (`low`) each worked out by the caller on its own (a computed each), so what a pool's change
/// leaves as it was runs none of what shows it.
fn ov_pool_pill_node(
  parent : @view.View,
  title : () -> String,
  count_txt : () -> String,
  low : () -> Bool,
  selected : () -> Bool,
  on_select : () -> Unit,
) -> Unit {
  // (one of the pools to choose (@sf.count_chip_node's Fill): read out selected while it is the one shown, the pointer's
  // ground over its own; its state's dot red where it runs short, else the online green)
  @sf.count_chip_node(
    parent,
    title,
    fn(_) { on_select() },
    count=count_txt,
    chosen=selected,
    dot=fn() { if low() { "error" } else { "online" } },
    corner=ug_row_corner,
  )
  .grow(Is(1.0))
  |> ignore
}

///|
fn ov_pools_card_node(
  parent : @view.View,
  core : Core,
  open_profile : ((String, String) -> Unit)?,
  pools : () -> Array[ModelPool],
  api_keys : () -> Array[(Json, String)],
  share : () -> Unit,
  tips : @sf.TipLayer?,
) -> Unit {
  // (the pool shown: the one picked, else the one running down fastest; worked out once for all that shows it, told
  // only as it comes out otherwise, never as another pool changes)
  let active_now = @signals.computed(fn(_) -> ModelPool? {
    let ps = pools()
    if ps.length() == 0 {
      None
    } else {
      let picked = ov_picked_pool.get()
      match ps.iter().find_first(fn(p) { p.title == picked }) {
        Some(p) => Some(p)
        // (none picked: the one going without soonest, else the first spending past its pace, else the first)
        None => {
          let mut worst = 0
          for i in 1..<ps.length() {
            let a = ps[i]
            let b = ps[worst]
            let soon = fn(p : ModelPool) { p.exhaust_hours.unwrap_or(100000) }
            if soon(a) < soon(b) || (soon(a) == soon(b) && a.over_pace && !b.over_pace) {
              worst = i
            }
          }
          Some(ps[worst])
        }
      }
    }
  })
  let active_pool = fn() { active_now.get() }

  parent.box(fn(card) {
    card
    .padding(Is((@sf.corner_inset, @sf.corner_inset, @sf.corner_inset, @sf.corner_inset)))
    .gap(Is(4.0))
    .radius(By(fn() { @ui.tree_theme().corner(Xl3) }))
    .ground(By(fn() { @ui.tree_theme().color(Card) }))
    |> ignore

    card.show(fn() { active_pool() is Some(_) }, fn(has_pools) {
      has_pools.gap(Is(4.0)) |> ignore
      // (the one shown, by its title: a pill is told only as it comes to be shown or stops being so: View::selected)
      let shown_is = has_pools.selected(fn() { active_pool().map(fn(p) { p.title }) })

      // 1. Reactive Pool Selector Grid (2 columns on phone widths, up to 4 across wider panes)
      has_pools.grid(fn() { pools().length() }, min_col_w=136.0, gap=6.0, row_gap=6.0, max_cols=4, fn(slot, idx) {
        slot.row(Is(true)) |> ignore
        // (its pool's title, count and whether it runs short, each worked out once of the pools, told only as that comes
        // out otherwise: another pool's change runs none of this pill)
        let pool_at = fn() -> ModelPool? { pools().get(idx) }
        let title = @signals.computed(fn(_) { pool_at().map(fn(p) { p.title }).unwrap_or("") })
        let count = @signals.computed(fn(_) {
          match pool_at() {
            Some(p) => p.ready.to_string() + "/" + p.total.to_string()
            None => "0/0"
          }
        })
        let low = @signals.computed(fn(_) { pool_at().map(fn(p) { p.over_pace }).unwrap_or(false) })
        ov_pool_pill_node(
          slot,
          fn() { title.get() },
          fn() { count.get() },
          fn() { low.get() },
          fn() { shown_is(title.get()) },
          fn() { ov_picked_pool.set(@signals.untracked(fn() { title.get() })) },
        )
      })
      |> ignore

      // 2. Reactive Two Synchronized Charts (stacked on narrow panes, 2 columns side-by-side when >= 564px)
      ov_charts_node(has_pools, active_pool, Some(share), tips)
    })

    // 3. Deduplicated Pay-as-you-go API Balance Rows
    card.show(fn() { api_keys().length() > 0 }, fn(keys_sec) {
      keys_sec.gap(Is(2.0)) |> ignore
      // (a line between the pools and the keys: a panel's rule, the library's)
      keys_sec.show(fn() { active_pool() is Some(_) }, fn(sep) { @sf.panel_rule_node(sep) })
      keys_sec.each(api_keys, fn(item) { text(Some(item.0), "key") }, fn(r, item_sig) {
        let kev = fn() { Some(item_sig.get().0) }
        let bal = fn() { item_sig.get().1 }
        r
        .padding(Is((12.0, 8.0, 12.0, 8.0)))
        .radius(By(ug_row_corner))
        .height(By(fn() { Some(@cmp.maximum(@sf.theme().items.least, @sf.node_sp(r, 20.0) + 16.0)) }))
        .lies_along(Is(Middle))
        .says(By(fn() { Some(@view.said(Link, label=ov_account_name(kev()) + " " + bal())) }))
        |> ignore
        @sf.hover_ground_node(r)
        @sf.presses_node(r, fn() { ov_open_account(core, open_profile, @signals.untracked(kev)) })
        ug_line_node(r, fn(l) {
          @sf.words_node(l, fn() { ov_account_name(kev()) }, fn() { if @sf.lit_node(r) { ug_row_title_lit } else { ug_row_title } })
          .grow(Is(1.0))
          .basis(Is(Some(0.0)))
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          .allow_ellipsis(Is(true))
          |> ignore
          l.box(fn(end) {
            end.row(Is(true)).gap(Is(4.0)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
            @sf.words_node(end, bal, fn() { ug_line_end }) |> ignore
            @sf.icon_node(end, "chevron-right", 16.0, By(fn() { @sf.theme().p.subtle })) |> ignore
          })
          |> ignore
        })
      })
    })
  })
  |> ignore
}

///|
/// A pool's two charts (额度与恢复, 消耗速度: stacked on narrow panes, side by side from 564 wide), `active_pool` the pool
/// they draw as it is now, what it would take more under them; `share` at the first's head (the page's, the pool
/// shown; none in the picture shared of them all, share_quota.mbt).
fn ov_charts_node(
  parent : @view.View,
  active_pool : () -> ModelPool?,
  share : (() -> Unit)?,
  tips : @sf.TipLayer?,
) -> Unit {
  parent.box(fn(body) {
    body.padding(Is((12.0, 10.0, 12.0, 10.0))) |> ignore
    let c1_badge = fn() {
      match active_pool() {
        Some(active) =>
          match active.exhaust_hours {
            Some(eh) if eh <= 0 => active.now_pct.to_string() + (if ov_en() { "% · out now" } else { "% · 已断档" })
            Some(eh) =>
              if ov_en() {
                active.now_pct.to_string() + "% · out in " + ov_hours_short(eh)
              } else {
                active.now_pct.to_string() + "% · " + ov_hours_short(eh) + "后断档"
              }
            None => active.now_pct.to_string() + "%"
          }
        None => ""
      }
    }

    body.grid(fn() { 2 }, min_col_w=270.0, gap=24.0, row_gap=16.0, max_cols=2, fn(col, idx) {
      if idx == 0 {
        // Chart 1: 额度与恢复
        col.gap(Is(6.0)) |> ignore
        ug_line_node(col, fn(h1) {
          @sf.words_node(h1, fn() { if ov_en() { "Quota" } else { "额度与恢复" } }, fn() { ug_named_title })
          .grow(Is(1.0))
          .basis(Is(Some(0.0)))
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          .allow_ellipsis(Is(true))
          |> ignore
          @sf.words_node(h1, c1_badge, fn() {
            let t = @sf.theme()
            let is_bad = match active_pool() {
              Some(ap) => ap.exhaust_hours is Some(_)
              None => false
            }
            ug_peak.then(@ui.text_style(color=Data(if is_bad { t.p.red } else { t.p.green_ink })))
          })
          .shrink(Is(0.0))
          |> ignore
          // (its charts as a picture to share, where it is shown on the page: share_quota.mbt; the line as tall as its
          // button, the pace chart's beside it too, so the two charts stand level)
          match share {
            Some(go) => {
              h1.min_height(Is(Some(@sf.icon_button_side))) |> ignore
              @sf.icon_button_node(h1, "share", fn() { @sf.t("web-main.share.pool") }, go, tips?).shrink(Is(0.0)) |> ignore
            }
            None => ()
          }
        })

        col.box(fn(plot1) {
          plot1.row(Is(true)).gap(Is(6.0)) |> ignore
          plot1.box(fn(ys) {
            ys.min_width(Is(Some(ov_axis_w))).min_height(Is(Some(ov_chart_h))).lies_along(Is(Between)).shrink(Is(0.0)) |> ignore
            @sf.words_node(ys, fn() { "100%" }, fn() { ug_scale_label }) |> ignore
            @sf.words_node(ys, fn() { "50%" }, fn() { ug_scale_label }) |> ignore
            @sf.words_node(ys, fn() { "0%" }, fn() { ug_scale_label }) |> ignore
          })
          |> ignore
          plot1.box(fn(cv1) {
            cv1.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
            cv1.by_room(fn(canvas, room) {
              canvas
              .height(Is(Some(ov_chart_h)))
              .shapes(By(fn() {
                match active_pool() {
                  Some(ap) => ov_trajectory_shapes(ap, room.width(), ov_chart_h)
                  None => []
                }
              }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        ov_time_axis_node(col, ov_axis_w, ov_quota_hours, 1)
      } else {
        // Chart 2: 消耗速度
        col.gap(Is(6.0)) |> ignore
        ug_line_node(col, fn(h2) {
          if share is Some(_) {
            h2.min_height(Is(Some(@sf.icon_button_side))) |> ignore
          }
          @sf.words_node(h2, fn() { if ov_en() { "Net Pace" } else { "消耗速度" } }, fn() { ug_named_title })
          .grow(Is(1.0))
          .basis(Is(Some(0.0)))
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          .allow_ellipsis(Is(true))
          |> ignore
          @sf.words_node(
            h2,
            fn() {
              match active_pool() {
                Some(ap) => ov_rate(ap.net_now, signed=true)
                None => ""
              }
            },
            fn() {
              let t = @sf.theme()
              let is_bad = match active_pool() {
                Some(ap) => ap.net_now < 0.0
                None => false
              }
              ug_peak.then(@ui.text_style(color=Data(if is_bad { t.p.red } else { t.p.green_ink })))
            },
          )
          .shrink(Is(0.0))
          |> ignore
        })

        col.box(fn(plot2) {
          plot2.row(Is(true)).gap(Is(6.0)) |> ignore
          let top = fn() {
            match active_pool() {
              Some(ap) => ov_net_top(ap)
              None => 1.0
            }
          }
          plot2.box(fn(ys) {
            ys.min_width(Is(Some(ov_burn_axis_w))).min_height(Is(Some(ov_chart_h))).lies_along(Is(Between)).shrink(Is(0.0)) |> ignore
            @sf.words_node(ys, fn() { ov_rate(top(), signed=true) }, fn() { ug_scale_label }) |> ignore
            @sf.words_node(ys, fn() { "0" }, fn() { ug_scale_label }) |> ignore
            @sf.words_node(ys, fn() { ov_rate(-top()) }, fn() { ug_scale_label }) |> ignore
          })
          |> ignore
          plot2.box(fn(cv2) {
            cv2.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
            cv2.by_room(fn(canvas, room) {
              canvas
              .height(Is(Some(ov_chart_h)))
              .shapes(By(fn() {
                match active_pool() {
                  Some(ap) => ov_net_shapes(ap, ov_net_top(ap), room.width(), ov_chart_h)
                  None => []
                }
              }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        ov_time_axis_node(col, ov_burn_axis_w, ov_burn_hours, 2)
      }
    })
    |> ignore
    // (how many more accounts would keep it going, under both charts: only where it does not keep up as it is; at once
    // as another pool is picked, as the charts over it are)
    body.show(fn() { active_pool().map(fn(p) { p.needed_accounts > 0 }).unwrap_or(false) }, at_once=true, fn(hint) {
      hint.padding(Is((0.0, 8.0, 0.0, 0.0))) |> ignore
      @sf.words_node(hint, fn() { ov_needed_words(active_pool().map(fn(p) { p.needed_accounts }).unwrap_or(0)) }, fn() {
        @ui.text_style(size=Meta, leading=L5, wrap=true, w=Full, color=Data(@sf.theme().p.red))
      })
      |> ignore
    })
    ov_speed_node(body, active_pool)
  })
  |> ignore
}

///|
/// `输出速度`, under the pool's two charts: its title and the speed now, the span to show, and each window's speed over
/// it; where none of the pool's calls was timed in the span, says so in the chart's place. A pool none of whose calls
/// was timed in any span shows none of it, title and spans too: nothing to choose between.
fn ov_speed_node(parent : @view.View, active_pool : () -> ModelPool?) -> Unit {
  let points_now = @signals.computed(fn(_) { active_pool().map(ov_speed_points).unwrap_or([]) }, same=fn(a, b) { a == b })
  let points = fn() { points_now.get() }
  let any_timed = @signals.computed(
    fn(_) { active_pool().map(fn(p) { p.speed.iter().any(ov_speed_known) }).unwrap_or(false) },
    same=fn(a, b) { a == b },
  )
  parent.show(fn() { any_timed.get() }, at_once=true, fn(sec) { ov_speed_section_node(sec, points) })
}

///|
fn ov_speed_section_node(parent : @view.View, points : () -> Array[Double]) -> Unit {
  parent.box(fn(col) {
    col.gap(Is(6.0)).padding(Is((0.0, 16.0, 0.0, 0.0))) |> ignore
    ug_line_node(col, fn(h) {
      @sf.words_node(h, fn() { if ov_en() { "Output speed" } else { "输出速度" } }, fn() { ug_named_title })
      .grow(Is(1.0))
      .basis(Is(Some(0.0)))
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      .allow_ellipsis(Is(true))
      |> ignore
      @sf.words_node(
        h,
        fn() {
          match points().last() {
            Some(v) if v >= 0.0 => ov_tps(v)
            _ => "—"
          }
        },
        fn() {
          match points().last() {
            Some(v) if v >= 0.0 => ug_peak.then(@ui.text_style(color=AccentText))
            _ => ug_peak.then(@ui.text_style(color=Data(@sf.theme().p.subtle)))
          }
        },
      )
      .shrink(Is(0.0))
      |> ignore
    })
    col.box(fn(slot) { @sf.segmented_node(slot, ov_speed_spans, fn() { ov_speed_span.get() }, fn(i) { ov_speed_span.set(i) }) })
    |> ignore
    col.show(fn() { ov_speed_known(points()) }, at_once=true, fn(known) {
      known.gap(Is(6.0)) |> ignore
      known.box(fn(plot) {
        plot.row(Is(true)).gap(Is(6.0)) |> ignore
        let top = fn() { ov_speed_top(points()) }
        plot.box(fn(ys) {
          ys.min_width(Is(Some(ov_axis_w))).min_height(Is(Some(ov_chart_h))).lies_along(Is(Between)).shrink(Is(0.0)) |> ignore
          @sf.words_node(ys, fn() { ov_rate_number(top()) }, fn() { ug_scale_label }) |> ignore
          @sf.words_node(ys, fn() { ov_rate_number(top() / 2.0) }, fn() { ug_scale_label }) |> ignore
          @sf.words_node(ys, fn() { "0" }, fn() { ug_scale_label }) |> ignore
        })
        |> ignore
        plot.box(fn(cv) {
          cv.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
          cv.by_room(fn(canvas, room) {
            canvas.height(Is(Some(ov_chart_h))).shapes(By(fn() { ov_speed_shapes(points(), top(), room.width(), ov_chart_h) }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      ov_time_axis_node(known, ov_axis_w, ov_speed_hours, 4)
    })
    col.show(fn() { !ov_speed_known(points()) }, at_once=true, fn(none) {
      @sf.words_node(
        none,
        fn() {
          if ov_en() {
            "No timed calls of these models in this span"
          } else {
            "这段时间里没有这类模型的计时调用"
          }
        },
        fn() { @ui.text_style(size=Meta, leading=L5, wrap=true, w=Full, color=Data(@sf.theme().p.subtle)) },
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// A speed's scale label: whole tokens a second.
fn ov_rate_number(v : Double) -> String {
  v.round().to_int().to_string()
}

///|
pub fn profiles_overview_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  open_profile? : (String, String) -> Unit,
  on_show_accounts? : () -> Unit,
  tabs_thumb? : @sf.SegThumb,
  bar_actions? : ((@view.View) -> Unit, (@sf.Look) -> Double) -> Unit,
  bar_add? : Bool = true,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let topic = fn() { (core.topic)("profiles", { "scope": Json::string(here().workspace) }).get() }
  let list_now = @signals.computed(fn(_) { items(topic().value, "items") }, same=jsons_same)
  let list = fn() { list_now.get() }
  let overview = fn() { (core.topic)("profilesOverview", { "scope": Json::string(here().workspace) }).get() }
  let pools_now = @signals.computed(fn(_) { items(overview().value, "pools").map(ov_pool_of) }, same=fn(a, b) { a == b })
  let pools = fn() { pools_now.get() }
  let has_accounts_tab = on_show_accounts is Some(_)
  // (what it lists, each worked out once of the accounts for all that reads it, told only as it comes out otherwise: an
  // account's change that leaves a list as it was runs none of what shows it)
  let balance_now = @signals.computed(fn(_) { ov_balance_keys(list()) })
  let balance_keys = fn() { balance_now.get() }
  let broken_now = @signals.computed(fn(_) { list().filter(fn(e) { ov_needs_fix(Some(e)) }) })
  let broken_items = fn() { broken_now.get() }
  let waste_now = @signals.computed(fn(_) {
    let out : Array[(Json, Int, String)] = []
    for e in list() {
      match ov_expiring_waste(Some(e)) {
        Some((left, dur)) => out.push((e, left, dur))
        None => ()
      }
    }
    out
  })
  let waste_items = fn() { waste_now.get() }
  // (its blocks, worked out once: what reads them is told only as one comes or goes)
  let blocks_now = @signals.computed(fn(_) {
    let out : Array[String] = []
    if has_accounts_tab {
      out.push("choice")
    }
    if pools().length() > 0 || balance_keys().length() > 0 {
      out.push("pools")
    }
    if broken_items().length() > 0 || waste_items().length() > 0 {
      out.push("alerts")
    }
    out
  })
  let page_title = fn() {
    if has_accounts_tab {
      @sf.t("android-misc.bar.place.profiles")
    } else if ov_en() {
      "Overview"
    } else {
      "概览"
    }
  }
  // (adding one as the accounts' list does, profiles_list_node: at its title's end where the frame does not name the
  // page, else in the frame's bar)
  let add = fn() { has_accounts_tab && @settings.place_action(core, here(), "profiles") is Some(_) }
  let adding = fn(at : @view.View) {
    match @settings.place_action(core, @signals.untracked(here), "profiles") {
      Some(run) => run(Node(at))
      None => ()
    }
  }
  let label = fn() { @sf.t("android-misc.bar.action.profiles") }
  let has_pools = @signals.computed(fn(_) { !pools().is_empty() })
  let add_actions = fn(l : @view.View) {
    profile_share_node(l, core, here, fn() { !frame().named }, tips, has_pools=fn() { has_pools.get() })
    l.show(fn() { add() && !frame().named }, fn(a) { @sf.page_add_node(a, label, adding) })
  }
  match bar_actions {
    Some(f) =>
      f(
        fn(l) {
          profile_share_node(l, core, here, fn() { true }, tips, bar=true, has_pools=fn() { has_pools.get() })
          if bar_add {
            l.show(add, fn(a) { @sf.page_add_node(a, label, adding) })
          }
        },
        fn(_) { @sf.button_height() },
      )
    None => ()
  }
  @sf.page_node(
    v,
    page_title,
    actions=add_actions,
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    fn() { blocks_now.get() },
    fn(b, key) {
      if key == "choice" {
        @sf.page_choice_node(
          b,
          fn() { if ov_en() { ["Accounts", "Overview"] } else { ["账号", "概览"] } },
          fn() { 1 },
          fn(i) {
            if i == 0 {
              match on_show_accounts {
                Some(go) => go()
                None => ()
              }
            }
          },
          thumb?=tabs_thumb,
        )
      } else if key == "pools" {
        b.box(fn(sec) {
          sec.padding(Is((0.0, 0.0, 0.0, if has_accounts_tab { 10.0 } else { 24.0 }))) |> ignore
          ov_pools_card_node(sec, core, open_profile, pools, balance_keys, fn() { pool_share_open(core, fn() { here().workspace }) }, tips)
        })
        |> ignore
      } else if key == "alerts" {
        @sf.section_node(b, fn() { if ov_en() { "Needs attention" } else { "需处理" } }, fn(sec) {
          @sf.group_node(sec, fn(g) {
            g.each(broken_items, fn(e) { text(Some(e), "key") }, fn(slot, e_sig) {
              let ev = fn() { Some(e_sig.get()) }
              @sf.link_row_node(
                slot,
                fn() { ov_account_name(ev()) },
                fn() { ov_open_account(core, open_profile, @signals.untracked(ev)) },
                title_cut=true,
                value=fn() { ov_issue_action_label(ev()) },
                trouble=fn() { ov_issue_short(ev()) },
                lead=LeadLine(fn(l) { ov_account_mark_node(l, ev()) }),
              )
            })
            g.each(waste_items, fn(it) { text(Some(it.0), "key") }, fn(slot, it_sig) {
              let ev = fn() { Some(it_sig.get().0) }
              @sf.link_row_node(
                slot,
                fn() { ov_account_name(ev()) },
                fn() { ov_open_account(core, open_profile, @signals.untracked(ev)) },
                title_cut=true,
                note=fn() {
                  let (_, left, dur) = it_sig.get()
                  if ov_en() {
                    left.to_string() + "% weekly unused · resets to zero in " + dur
                  } else {
                    "周额度剩 " + left.to_string() + "% 未用 · " + dur + "后重置清零"
                  }
                },
                lacks=true,
                lead=LeadLine(fn(l) { ov_account_mark_node(l, ev()) }),
              )
            })
          })
        })
      }
    },
  )
}
