// Workspace profiles overview (Profile 汇总页):
// Minimal, graphic-first summary for staggered account reset schedules:
// - Wide (`宽排法`): default view of `Place("profiles")`, listed first in the profiles sidebar (`概览`).
// - Narrow (`窄排法`): `账号 | 概览` switch at the top of `Profiles` (defaults to the original `账号` list).
// Two synchronized time-series charts per model pool:
// 1. `额度与恢复` (Past 48h -> `现在` -> 7-day stepped reset forecast, red outage bands on `0%`);
// 2. `消耗速度` (Zero-baseline diverging bars: positive green = slower than recovery, negative red = exhausts early).

///|
priv struct PoolSlot {
  weight : Double
  raw_week_left : Double
  cool_hours : Double
  locked_hours : Double
  reset_hours : Double
  cycle_hours : Double
  broken : Bool
}

///|
#derive(Eq)
priv struct ModelPool {
  title : String
  ready : Int
  total : Int
  now_pct : Int
  net_today : Int
  exhaust_hours : Int?
  traj : Array[Double]
  will_starve : Array[Bool]
  net_bars : Array[Double]
}

///|
let ov_picked_pool : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })

///|
fn profiles_overview_reset() -> Unit {
  ov_picked_pool.set("")
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
fn ov_is_main_short(mk : String, sc : String, lbl : String) -> Bool {
  if sc != "" {
    return false
  }
  if mk == "5H" || mk == "3D" || mk == "2H" {
    return true
  }
  !lbl.contains("·") && (lbl.contains("小时") || lbl.contains("hour") || lbl.contains("5h"))
}

///|
fn ov_entry_status(e : Json?) -> (Bool, Bool, Bool, Bool, String) {
  let broken = ov_needs_fix(e)
  if broken {
    return (false, false, false, true, "")
  }
  let p = field(e, "profile")
  let q = field(p, "quota")
  if text(q, "state") == "blocked" {
    return (false, false, true, false, text(q, "detail"))
  }
  let wins = if text(q, "state") == "ok" { items(q, "windows") } else { [] }
  let mut week_dead = false
  let mut short_dead = false
  let mut week_refill = ""
  let mut short_refill = ""
  for w in wins {
    let wv = Some(w)
    let sc = text(wv, "scope")
    let mk = text(wv, "mark")
    let lbl = text(wv, "label")
    let left = count(wv, "left")
    if ov_is_main_week(mk, sc, lbl) && left <= 0 {
      week_dead = true
      if week_refill == "" {
        week_refill = text(wv, "refills")
      }
    } else if ov_is_main_short(mk, sc, lbl) && left <= 0 {
      short_dead = true
      if short_refill == "" {
        short_refill = text(wv, "refills")
      }
    }
  }
  if week_dead {
    (false, false, true, false, week_refill)
  } else if short_dead {
    (false, true, false, false, short_refill)
  } else {
    (flag(e, "usable"), false, false, false, "")
  }
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
fn ov_signed_pct(v : Int) -> String {
  let unit = if ov_en() { "%/d" } else { "%/天" }
  if v > 0 {
    "+" + v.to_string() + unit
  } else {
    v.to_string() + unit
  }
}

///|
fn ov_account_name(e : Json?) -> String {
  let p = field(e, "profile")
  let n = text(p, "name")
  if n != "" { n } else { text(e, "title") }
}

///|
fn ov_plan_weight(e : Json?) -> Double {
  let g = text(e, "group")
  let pl = text(field(e, "profile"), "planText")
  if g == "claude" {
    if pl.contains("20x") {
      20.0
    } else if pl.contains("5x") {
      5.0
    } else {
      1.0
    }
  } else if g == "chatgpt" {
    if pl.contains("200") || pl.contains("Pro") {
      10.0
    } else if pl.contains("Team") {
      2.0
    } else {
      1.0
    }
  } else if g == "agy" || g == "google" {
    if pl.contains("Ultra") {
      5.0
    } else {
      1.0
    }
  } else {
    1.0
  }
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
fn ov_find_window_ext(e : Json?, pred : (String, String, String) -> Bool) -> (Int, String, Double)? {
  let q = field(field(e, "profile"), "quota")
  if text(q, "state") != "ok" {
    return None
  }
  for w in items(q, "windows") {
    let wv = Some(w)
    let mk = text(wv, "mark")
    let sc = text(wv, "scope")
    let lbl = text(wv, "label")
    if pred(mk, sc, lbl) {
      let cyc = if mk == "M" || lbl.contains("每月") || lbl.contains("Monthly") { 720.0 } else { 168.0 }
      return Some((count(wv, "left"), text(wv, "refills"), cyc))
    }
  }
  None
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
fn ov_reset_hours_of(rf : String, cycle_h : Double) -> Double {
  let m = ov_refill_minutes(rf)
  if m >= 900000 {
    cycle_h / 2.0
  } else {
    let h = m.to_double() / 60.0
    if h < 1.0 { 1.0 } else if h > cycle_h { cycle_h } else { h }
  }
}

///|
fn ov_starves_in_window(
  shares : Array[Double],
  init_tanks_at_start : Array[Double],
  cool_until : Array[Double],
  lock_until : Array[Double],
  reset_h : Array[Int],
  cycle_h : Array[Int],
  start_h : Int,
  end_h : Int,
  test_burn_per_day : Double,
) -> Bool {
  let n = shares.length()
  let tanks = init_tanks_at_start.copy()
  let burn_step = test_burn_per_day / 24.0
  let mut h = start_h + 1
  while h <= end_h {
    let hd = h.to_double()
    for i in 0..<n {
      let cyc = cycle_h[i]
      if h >= reset_h[i] && (h - reset_h[i]) % cyc == 0 {
        tanks[i] = shares[i]
      }
    }
    let mut rem = burn_step
    let mut pass = 0
    while rem > 0.0001 && pass < n {
      let mut best = -1
      let mut best_next = 999999
      for i in 0..<n {
        if hd >= cool_until[i] && hd >= lock_until[i] && tanks[i] > 0.0001 {
          let cyc = cycle_h[i]
          let rem_to_rst = (reset_h[i] - (h % cyc) + cyc) % cyc
          if rem_to_rst < best_next {
            best_next = rem_to_rst
            best = i
          }
        }
      }
      if best < 0 {
        break
      }
      let take = @cmp.minimum(rem, tanks[best])
      tanks[best] = tanks[best] - take
      rem -= take
      pass += 1
    }
    if rem > 0.02 {
      return true
    }
    let mut avail = 0.0
    for i in 0..<n {
      if hd >= cool_until[i] && hd >= lock_until[i] {
        avail += tanks[i]
      }
    }
    if avail <= 0.05 && test_burn_per_day > 0.1 {
      return true
    }
    h += 1
  }
  false
}

///|
fn ov_finalize_pool(
  title : String,
  recs : Array[(PoolSlot, Bool)],
) -> ModelPool? {
  let total = recs.length()
  if total == 0 {
    return None
  }
  let mut ready = 0
  let active_slots : Array[PoolSlot] = []
  let mut active_w = 0.0

  for r in recs {
    let (slot, is_ready) = r
    if is_ready {
      ready += 1
    }
    if !slot.broken {
      active_slots.push(slot)
      active_w += slot.weight
    }
  }

  if active_slots.length() == 0 || active_w <= 0.0 {
    return Some({
      title,
      ready: 0,
      total,
      now_pct: 0,
      net_today: -15,
      exhaust_hours: Some(0),
      traj: Array::make(217, 0.0),
      will_starve: Array::make(168, true),
      net_bars: Array::make(9, -15.0),
    })
  }

  let n = active_slots.length()
  let shares : Array[Double] = []
  let cool_until : Array[Double] = []
  let lock_until : Array[Double] = []
  let reset_h : Array[Int] = []
  let cycle_h : Array[Int] = []
  let rate_pct_h : Array[Double] = []
  let mut burn_h = 0.0
  let mut weighted_cycle_days = 0.0

  for s in active_slots {
    let sh = s.weight / active_w * 100.0
    shares.push(sh)
    cool_until.push(s.cool_hours)
    lock_until.push(s.locked_hours)
    let cyc_i = @cmp.maximum(24, s.cycle_hours.round().to_int())
    cycle_h.push(cyc_i)
    let rh = s.reset_hours.round().to_int()
    let rh_clamped = if rh < 1 { 1 } else if rh > cyc_i { cyc_i } else { rh }
    reset_h.push(rh_clamped)
    let elapsed = @cmp.maximum(16.0, @cmp.minimum(s.cycle_hours - 12.0, s.cycle_hours - s.reset_hours))
    let used_pct = @cmp.maximum(0.0, 100.0 - s.raw_week_left)
    let r_h = used_pct / elapsed
    rate_pct_h.push(r_h)
    burn_h += sh * r_h / 100.0
    weighted_cycle_days += sh * (s.cycle_hours / 24.0) / 100.0
  }

  let burn_per_day_f = burn_h * 24.0
  let traj = Array::make(217, 0.0)

  for k in 1..=48 {
    let kd = k.to_double()
    let mut sum_past = 0.0
    for i in 0..<n {
      let age_now = active_slots[i].cycle_hours - active_slots[i].reset_hours
      let pct_then = if kd <= age_now {
        @cmp.minimum(100.0, active_slots[i].raw_week_left + rate_pct_h[i] * kd)
      } else {
        let before_rst = kd - age_now
        @cmp.maximum(4.0, @cmp.minimum(95.0, 18.0 + rate_pct_h[i] * (before_rst - 1.0)))
      }
      sum_past += shares[i] * pct_then / 100.0
    }
    traj[48 - k] = @cmp.minimum(100.0, @cmp.maximum(0.0, sum_past))
  }

  let tanks : Array[Double] = []
  for i in 0..<n {
    tanks.push(shares[i] * active_slots[i].raw_week_left / 100.0)
  }
  let day_snapshots : Array[Array[Double]] = [tanks.copy()]

  let mut now_avail = 0.0
  for i in 0..<n {
    if cool_until[i] <= 0.0 && lock_until[i] <= 0.0 {
      now_avail += tanks[i]
    }
  }
  traj[48] = now_avail

  let mut exhaust_hours : Int? = if now_avail <= 0.5 && burn_per_day_f > 1.0 { Some(0) } else { None }

  for h in 1..=168 {
    let hd = h.to_double()
    for i in 0..<n {
      let cyc = cycle_h[i]
      if h >= reset_h[i] && (h - reset_h[i]) % cyc == 0 {
        tanks[i] = shares[i]
      }
    }
    let mut rem = burn_h
    let mut pass = 0
    while rem > 0.0001 && pass < n {
      let mut best = -1
      let mut best_next = 999999
      for i in 0..<n {
        if hd >= cool_until[i] && hd >= lock_until[i] && tanks[i] > 0.0001 {
          let cyc = cycle_h[i]
          let rem_to_rst = (reset_h[i] - (h % cyc) + cyc) % cyc
          if rem_to_rst < best_next {
            best_next = rem_to_rst
            best = i
          }
        }
      }
      if best < 0 {
        break
      }
      let take = @cmp.minimum(rem, tanks[best])
      tanks[best] = tanks[best] - take
      rem -= take
      pass += 1
    }

    let mut avail = 0.0
    for i in 0..<n {
      if hd >= cool_until[i] && hd >= lock_until[i] {
        avail += tanks[i]
      }
    }
    traj[48 + h] = @cmp.minimum(100.0, @cmp.maximum(0.0, avail))
    if exhaust_hours is None && avail <= 0.3 && burn_per_day_f > 1.0 {
      exhaust_hours = Some(h)
    }
    if h % 24 == 0 && day_snapshots.length() < 8 {
      day_snapshots.push(tanks.copy())
    }
  }

  let will_starve = Array::make(168, false)
  for h in 0..<168 {
    let v0 = traj[48 + h]
    let v1 = traj[48 + h + 1]
    if v1 > v0 + 1.0 {
      will_starve[h] = false
    } else if v0 <= 0.5 || v1 <= 0.5 {
      will_starve[h] = true
    } else {
      let mut hits_zero = false
      let mut k = h + 1
      while k < 168 {
        if traj[48 + k + 1] > traj[48 + k] + 1.5 {
          break
        }
        if traj[48 + k] <= 0.4 {
          hits_zero = true
          break
        }
        k += 1
      }
      will_starve[h] = hits_zero
    }
  }

  let net_bars : Array[Double] = []
  let steady_rec = 100.0 / @cmp.maximum(1.0, weighted_cycle_days)
  net_bars.push(steady_rec - burn_per_day_f * 0.92)
  net_bars.push(steady_rec - burn_per_day_f)

  for d in 0..<7 {
    let start_h = d * 24
    let end_h = @cmp.minimum(168, start_h + 96)
    let snap = day_snapshots[d].copy()
    let mut lo = 0.0
    let mut hi = 60.0
    for _ in 0..<12 {
      let mid = (lo + hi) / 2.0
      if ov_starves_in_window(shares, snap, cool_until, lock_until, reset_h, cycle_h, start_h, end_h, mid) {
        hi = mid
      } else {
        lo = mid
      }
    }
    let net_v = lo - burn_per_day_f
    let actual_starves = ov_starves_in_window(
      shares,
      snap,
      cool_until,
      lock_until,
      reset_h,
      cycle_h,
      start_h,
      end_h,
      burn_per_day_f,
    )
    let adjusted = if actual_starves && net_v >= -0.8 {
      -1.5
    } else if !actual_starves && net_v < 0.5 {
      1.2
    } else {
      net_v
    }
    net_bars.push(adjusted)
  }

  Some({
    title,
    ready,
    total,
    now_pct: traj[48].round().to_int(),
    net_today: net_bars[2].round().to_int(),
    exhaust_hours,
    traj,
    will_starve,
    net_bars,
  })
}

///|
fn ov_is_claude_gpt_win(mk : String, sc : String, lbl : String) -> Bool {
  sc == "Claude / GPT" || mk == "Claude / GPT" || lbl.contains("Claude / GPT")
}

///|
fn ov_is_fable_win(mk : String, sc : String, lbl : String) -> Bool {
  sc == "Fable" || sc == "fable" || mk == "Fable" || lbl.contains("Fable")
}

///|
fn ov_is_gemini_week(mk : String, sc : String, lbl : String) -> Bool {
  let is_gem = sc == "Gemini" || sc == "gemini" || mk == "Gemini" || lbl.contains("Gemini")
  is_gem &&
  (mk == "W" || lbl.contains("每周") || lbl.contains("Weekly") || (sc == "" && mk == "Gemini" && !lbl.contains("小时") && !lbl.contains("h ")))
}

///|
fn ov_is_gemini_short(mk : String, sc : String, lbl : String) -> Bool {
  let is_gem = sc == "Gemini" || sc == "gemini" || mk == "Gemini" || lbl.contains("Gemini")
  is_gem && (mk == "5H" || lbl.contains("小时") || lbl.contains("hour") || lbl.contains("5h"))
}

///|
fn ov_build_pools(list : Array[Json]) -> Array[ModelPool] {
  let pools : Array[ModelPool] = []

  // 1. Claude Pool
  let cl_recs : Array[(PoolSlot, Bool)] = []
  for e in list {
    let ev = Some(e)
    let g = text(ev, "group")
    if g == "claude" {
      let wt = ov_plan_weight(ev)
      let (is_ready, is_short, is_week_dead, is_broken, hint_rf) = ov_entry_status(ev)
      let w_win = ov_find_window_ext(ev, ov_is_main_week)
      if is_broken {
        cl_recs.push(({ weight: wt, raw_week_left: 0.0, cool_hours: 0.0, locked_hours: 0.0, reset_hours: 84.0, cycle_hours: 168.0, broken: true }, false))
      } else if is_week_dead {
        let cyc = match w_win { Some((_, _, c)) => c; None => 168.0 }
        cl_recs.push(({ weight: wt, raw_week_left: 0.0, cool_hours: 0.0, locked_hours: 0.0, reset_hours: ov_reset_hours_of(hint_rf, cyc), cycle_hours: cyc, broken: false }, false))
      } else {
        let (w_left, w_rf, cyc) = match w_win { Some(t3) => t3; None => (if is_ready { 100 } else { 0 }, "", 168.0) }
        let cool_h = if is_short { @cmp.maximum(0.25, ov_refill_minutes(hint_rf).to_double() / 60.0) } else { 0.0 }
        cl_recs.push(({ weight: wt, raw_week_left: w_left.to_double(), cool_hours: cool_h, locked_hours: 0.0, reset_hours: ov_reset_hours_of(w_rf, cyc), cycle_hours: cyc, broken: false }, !is_short && is_ready))
      }
    } else if g == "agy" || g == "google" {
      match ov_find_window_ext(ev, ov_is_claude_gpt_win) {
        Some((w_left, w_rf, cyc)) => {
          let wt = ov_plan_weight(ev)
          let broken = ov_needs_fix(ev)
          let slot = {
            weight: wt,
            raw_week_left: if broken { 0.0 } else { w_left.to_double() },
            cool_hours: 0.0,
            locked_hours: 0.0,
            reset_hours: ov_reset_hours_of(w_rf, cyc),
            cycle_hours: cyc,
            broken,
          }
          cl_recs.push((slot, !broken && w_left > 0))
        }
        None => ()
      }
    }
  }
  match ov_finalize_pool("Claude", cl_recs) {
    Some(p) => pools.push(p)
    None => ()
  }

  // 2. Fable Pool
  let any_fable = list.iter().any(fn(e) { ov_find_window_ext(Some(e), ov_is_fable_win) is Some(_) })
  if any_fable {
    let fb_recs : Array[(PoolSlot, Bool)] = []
    for e in list {
      let ev = Some(e)
      let fb_win = ov_find_window_ext(ev, ov_is_fable_win)
      if fb_win is Some(_) || (text(ev, "group") == "claude" && ov_needs_fix(ev)) {
        let wt = ov_plan_weight(ev)
        let (is_ready, is_short, is_week_dead, is_broken, hint_rf) = ov_entry_status(ev)
        let (fb_left, fb_rf, cyc) = match fb_win { Some(t3) => t3; None => (0, "", 168.0) }
        if is_broken {
          fb_recs.push(({ weight: wt, raw_week_left: 0.0, cool_hours: 0.0, locked_hours: 0.0, reset_hours: 84.0, cycle_hours: cyc, broken: true }, false))
        } else if is_week_dead && fb_left > 0 {
          let lock_h = ov_reset_hours_of(hint_rf, cyc)
          fb_recs.push(({ weight: wt, raw_week_left: fb_left.to_double(), cool_hours: 0.0, locked_hours: lock_h, reset_hours: ov_reset_hours_of(if fb_rf != "" { fb_rf } else { hint_rf }, cyc), cycle_hours: cyc, broken: false }, false))
        } else if fb_left <= 0 || is_week_dead {
          let rf = if fb_rf != "" { fb_rf } else { hint_rf }
          fb_recs.push(({ weight: wt, raw_week_left: 0.0, cool_hours: 0.0, locked_hours: 0.0, reset_hours: ov_reset_hours_of(rf, cyc), cycle_hours: cyc, broken: false }, false))
        } else {
          let cool_h = if is_short { @cmp.maximum(0.25, ov_refill_minutes(hint_rf).to_double() / 60.0) } else { 0.0 }
          fb_recs.push(({ weight: wt, raw_week_left: fb_left.to_double(), cool_hours: cool_h, locked_hours: 0.0, reset_hours: ov_reset_hours_of(fb_rf, cyc), cycle_hours: cyc, broken: false }, !is_short && is_ready))
        }
      }
    }
    match ov_finalize_pool("Fable", fb_recs) {
      Some(p) => pools.push(p)
      None => ()
    }
  }

  // 3. Codex Pool
  let cx_recs : Array[(PoolSlot, Bool)] = []
  for e in list {
    let ev = Some(e)
    let g = text(ev, "group")
    if g == "chatgpt" {
      let wt = ov_plan_weight(ev)
      let (is_ready, is_short, is_week_dead, is_broken, hint_rf) = ov_entry_status(ev)
      let w_win = ov_find_window_ext(ev, ov_is_main_week)
      if is_broken {
        cx_recs.push(({ weight: wt, raw_week_left: 0.0, cool_hours: 0.0, locked_hours: 0.0, reset_hours: 84.0, cycle_hours: 168.0, broken: true }, false))
      } else if is_week_dead {
        let cyc = match w_win { Some((_, _, c)) => c; None => 168.0 }
        cx_recs.push(({ weight: wt, raw_week_left: 0.0, cool_hours: 0.0, locked_hours: 0.0, reset_hours: ov_reset_hours_of(hint_rf, cyc), cycle_hours: cyc, broken: false }, false))
      } else {
        let (w_left, w_rf, cyc) = match w_win { Some(t3) => t3; None => (if is_ready { 100 } else { 0 }, "", 168.0) }
        let cool_h = if is_short { @cmp.maximum(0.25, ov_refill_minutes(hint_rf).to_double() / 60.0) } else { 0.0 }
        cx_recs.push(({ weight: wt, raw_week_left: w_left.to_double(), cool_hours: cool_h, locked_hours: 0.0, reset_hours: ov_reset_hours_of(w_rf, cyc), cycle_hours: cyc, broken: false }, !is_short && is_ready))
      }
    } else if g == "agy" || g == "google" {
      match ov_find_window_ext(ev, ov_is_claude_gpt_win) {
        Some((w_left, w_rf, cyc)) => {
          let wt = ov_plan_weight(ev)
          let broken = ov_needs_fix(ev)
          let slot = {
            weight: wt,
            raw_week_left: if broken { 0.0 } else { w_left.to_double() },
            cool_hours: 0.0,
            locked_hours: 0.0,
            reset_hours: ov_reset_hours_of(w_rf, cyc),
            cycle_hours: cyc,
            broken,
          }
          cx_recs.push((slot, !broken && w_left > 0))
        }
        None => ()
      }
    }
  }
  match ov_finalize_pool("Codex", cx_recs) {
    Some(p) => pools.push(p)
    None => ()
  }

  // 4. Gemini Pool
  let gm_recs : Array[(PoolSlot, Bool)] = []
  for e in list {
    let ev = Some(e)
    if text(ev, "group") == "agy" || text(ev, "group") == "google" {
      let wt = ov_plan_weight(ev)
      let broken = ov_needs_fix(ev)
      let w_win = ov_find_window_ext(ev, ov_is_gemini_week)
      let s_win = ov_find_window_ext(ev, ov_is_gemini_short)
      if broken {
        gm_recs.push(({ weight: wt, raw_week_left: 0.0, cool_hours: 0.0, locked_hours: 0.0, reset_hours: 84.0, cycle_hours: 168.0, broken: true }, false))
      } else {
        let (w_left, w_rf, cyc) = match w_win { Some(t3) => t3; None => (100, "", 168.0) }
        let (s_left, s_rf, _) = match s_win { Some(t3) => t3; None => (w_left, "", 168.0) }
        if w_left <= 0 {
          gm_recs.push(({ weight: wt, raw_week_left: 0.0, cool_hours: 0.0, locked_hours: 0.0, reset_hours: ov_reset_hours_of(w_rf, cyc), cycle_hours: cyc, broken: false }, false))
        } else if s_left <= 0 {
          let cool_h = @cmp.maximum(0.25, ov_refill_minutes(s_rf).to_double() / 60.0)
          gm_recs.push(({ weight: wt, raw_week_left: w_left.to_double(), cool_hours: cool_h, locked_hours: 0.0, reset_hours: ov_reset_hours_of(w_rf, cyc), cycle_hours: cyc, broken: false }, false))
        } else {
          gm_recs.push(({ weight: wt, raw_week_left: w_left.to_double(), cool_hours: 0.0, locked_hours: 0.0, reset_hours: ov_reset_hours_of(w_rf, cyc), cycle_hours: cyc, broken: false }, flag(ev, "usable")))
        }
      }
    }
  }
  match ov_finalize_pool("Gemini", gm_recs) {
    Some(p) => pools.push(p)
    None => ()
  }

  // 5. Any other active subscription groups
  for extra in [
    ("grok", "SuperGrok"),
    ("kimi", "Kimi Code"),
    ("opencode", "OpenCode Go"),
    ("cursor", "Cursor"),
    ("devin", "Devin"),
  ] {
    let (grp_key, p_title) = extra
    let ex_recs : Array[(PoolSlot, Bool)] = []
    for e in list {
      let ev = Some(e)
      if text(ev, "group") == grp_key {
        let (is_ready, is_short, is_week_dead, is_broken, hint_rf) = ov_entry_status(ev)
        let w_win = ov_find_window_ext(ev, ov_is_main_week)
        if is_broken {
          ex_recs.push(({ weight: 1.0, raw_week_left: 0.0, cool_hours: 0.0, locked_hours: 0.0, reset_hours: 84.0, cycle_hours: 168.0, broken: true }, false))
        } else if is_week_dead {
          let cyc = match w_win { Some((_, _, c)) => c; None => 168.0 }
          ex_recs.push(({ weight: 1.0, raw_week_left: 0.0, cool_hours: 0.0, locked_hours: 0.0, reset_hours: ov_reset_hours_of(hint_rf, cyc), cycle_hours: cyc, broken: false }, false))
        } else {
          let (w_left, w_rf, cyc) = match w_win { Some(t3) => t3; None => (if is_ready { 100 } else { 0 }, "", 168.0) }
          let cool_h = if is_short { @cmp.maximum(0.25, ov_refill_minutes(hint_rf).to_double() / 60.0) } else { 0.0 }
          ex_recs.push(({ weight: 1.0, raw_week_left: w_left.to_double(), cool_hours: cool_h, locked_hours: 0.0, reset_hours: ov_reset_hours_of(w_rf, cyc), cycle_hours: cyc, broken: false }, !is_short && is_ready))
        }
      }
    }
    match ov_finalize_pool(p_title, ex_recs) {
      Some(p) => pools.push(p)
      None => ()
    }
  }

  pools
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
fn ov_velocity_shapes(pool : ModelPool, scale_top : Double, w : Double, h : Double) -> Array[@ui.Shape] {
  if w <= 10.0 || pool.net_bars.length() < 9 {
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

  shapes.push(@ui.shape_of([([0.0, y_top, w, y_top], false)], stroke=@sf.alpha(t.p.line, 0.7), width=1.0))
  shapes.push(@ui.shape_of([([0.0, y_bot, w, y_bot], false)], stroke=@sf.alpha(t.p.line, 0.7), width=1.0))

  let x_now = 2.0 / 9.0 * w
  ov_push_v_dash(shapes, x_now, y_top, y_bot, 3.5, 3.0, @sf.alpha(t.p.text, 0.25), 1.0)

  let slot_w = w / 9.0
  let bar_w = @cmp.minimum(22.0, @cmp.maximum(8.0, slot_w * 0.58))

  for i in 0..<9 {
    let val = pool.net_bars[i]
    let ratio = @cmp.minimum(1.0, val.abs() / scale_top)
    let bh = @cmp.maximum(3.0, ratio * (half - 2.0))
    let bx = (i.to_double() + 0.5) * slot_w - bar_w / 2.0
    let past = i < 2
    if val >= 0.0 {
      let ink = if past { @sf.alpha(t.p.green, 0.50) } else { t.p.green }
      let poly = ov_bar_poly(bx, y_zero - bh, bar_w, bh, 3.5, 0.0)
      if poly.length() > 0 {
        shapes.push(@ui.shape_of([(poly, true)], fill=ink))
      }
    } else {
      let ink = if past { @sf.alpha(t.p.red, 0.50) } else { t.p.red }
      let poly = ov_bar_poly(bx, y_zero, bar_w, bh, 0.0, 3.5)
      if poly.length() > 0 {
        shapes.push(@ui.shape_of([(poly, true)], fill=ink))
      }
    }
  }

  shapes.push(@ui.shape_of([([0.0, y_zero, w, y_zero], false)], stroke=@sf.alpha(t.p.text, 0.34), width=1.25))

  shapes
}

///|
fn ov_time_axis_node(parent : @view.View, end_days : Int) -> Unit {
  parent.box(fn(axis) {
    axis.row(Is(true)).padding(Is((42.0, 4.0, 0.0, 0.0))).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
    @sf.words_node(axis, fn() { if ov_en() { "-2d" } else { "-2天" } }, fn() { ug_grid_label }).shrink(Is(0.0)) |> ignore
    @sf.words_node(axis, fn() { if ov_en() { "Now" } else { "现在" } }, fn() { ug_peak }).shrink(Is(0.0)) |> ignore
    @sf.words_node(axis, fn() { if ov_en() { "+2d" } else { "+2天" } }, fn() { ug_grid_label }).shrink(Is(0.0)) |> ignore
    @sf.words_node(axis, fn() { if ov_en() { "+4d" } else { "+4天" } }, fn() { ug_grid_label }).shrink(Is(0.0)) |> ignore
    @sf.words_node(axis, fn() { "+" + end_days.to_string() + (if ov_en() { "d" } else { "天" }) }, fn() { ug_grid_label })
    .shrink(Is(0.0))
    |> ignore
  })
  |> ignore
}

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
  parent.box(fn(pill) {
    pill
    .row(Is(true))
    .gap(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .grow(Is(1.0))
    .basis(Is(Some(0.0)))
    .min_width(Is(Some(0.0)))
    .min_height(By(fn() { Some(@sf.theme().items.least) }))
    .padding(Is((12.0, 7.0, 12.0, 7.0)))
    .radius(By(ug_row_corner))
    .ground(By(fn() {
      let t = @sf.theme()
      if selected() {
        @sf.alpha(t.p.accent, if t.dark { 0.18 } else { 0.11 })
      } else if @sf.lit_node(pill) {
        @ui.tree_theme().color(Hover)
      } else {
        @ui.tree_theme().color(Tint)
      }
    }))
    .says(By(fn() { Some(@view.said(Button, label=title() + " " + count_txt())) }))
    |> ignore
    @sf.presses_node(pill, on_select)

    @sf.words_node(pill, title, fn() {
      if selected() {
        ug_named_title.then(@ui.text_style(color=AccentText, w=@sf.grow))
      } else {
        ug_row_title
      }
    })
    .grow(Is(1.0))
    .basis(Is(Some(0.0)))
    .shrink(Is(1.0))
    .min_width(Is(Some(0.0)))
    .allow_ellipsis(Is(true))
    |> ignore

    pill.box(fn(dot) {
      dot
      .width(Is(Some(6.0)))
      .height(Is(Some(6.0)))
      .radius(Is(3.0))
      .shrink(Is(0.0))
      .ground(By(fn() {
        let t = @sf.theme()
        if low() { t.p.red } else { t.p.green }
      }))
      |> ignore
    })
    |> ignore

    @sf.words_node(pill, count_txt, fn() { ug_line_end }).shrink(Is(0.0)) |> ignore
  })
  |> ignore
}

///|
fn ov_pools_card_node(
  parent : @view.View,
  core : Core,
  open_profile : ((String, String) -> Unit)?,
  pools : () -> Array[ModelPool],
  api_keys : () -> Array[(Json, String)],
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
        None => {
          let mut worst = 0
          for i in 1..<ps.length() {
            if ps[i].net_today < ps[worst].net_today {
              worst = i
            }
          }
          Some(ps[worst])
        }
      }
    }
  })
  let active_pool = fn() { active_now.get() }

  let scale_top_of = fn(p : ModelPool) -> Double {
    let mut max_abs_v = 20.0
    for b in p.net_bars {
      if b.abs() > max_abs_v {
        max_abs_v = b.abs()
      }
    }
    ((max_abs_v.ceil().to_int() + 9) / 10 * 10).to_double()
  }

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
        let low = @signals.computed(fn(_) { pool_at().map(fn(p) { p.net_today < 0 }).unwrap_or(false) })
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
      has_pools.box(fn(body) {
        body.padding(Is((12.0, 10.0, 12.0, 10.0))) |> ignore
        let c1_badge = fn() {
          match active_pool() {
            Some(active) =>
              match active.exhaust_hours {
                Some(eh) if active.net_today < 0 =>
                  if ov_en() {
                    active.now_pct.to_string() + "% · " + ov_hours_short(eh) + " left"
                  } else {
                    active.now_pct.to_string() + "% · " + ov_hours_short(eh) + "后断档"
                  }
                _ => active.now_pct.to_string() + "%"
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
                  Some(ap) => ap.net_today < 0 && ap.exhaust_hours is Some(_)
                  None => false
                }
                ug_peak.then(@ui.text_style(color=Data(if is_bad { t.p.red } else { t.p.green_ink })))
              })
              .shrink(Is(0.0))
              |> ignore
            })

            col.box(fn(plot1) {
              plot1.row(Is(true)).gap(Is(6.0)) |> ignore
              plot1.box(fn(ys) {
                ys.min_width(Is(Some(36.0))).min_height(Is(Some(ov_chart_h))).lies_along(Is(Between)).shrink(Is(0.0)) |> ignore
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
            ov_time_axis_node(col, 7)
          } else {
            // Chart 2: 消耗速度
            col.gap(Is(6.0)) |> ignore
            ug_line_node(col, fn(h2) {
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
                    Some(ap) => ov_signed_pct(ap.net_today)
                    None => ""
                  }
                },
                fn() {
                  let t = @sf.theme()
                  let is_bad = match active_pool() {
                    Some(ap) => ap.net_today < 0
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
              plot2.box(fn(ys) {
                ys.min_width(Is(Some(36.0))).min_height(Is(Some(ov_chart_h))).lies_along(Is(Between)).shrink(Is(0.0)) |> ignore
                @sf.words_node(
                  ys,
                  fn() {
                    let st = match active_pool() {
                      Some(ap) => scale_top_of(ap).to_int()
                      None => 30
                    }
                    "+" + st.to_string() + "%"
                  },
                  fn() { ug_scale_label },
                )
                |> ignore
                @sf.words_node(ys, fn() { "0" }, fn() { ug_scale_label }) |> ignore
                @sf.words_node(
                  ys,
                  fn() {
                    let st = match active_pool() {
                      Some(ap) => scale_top_of(ap).to_int()
                      None => 30
                    }
                    "-" + st.to_string() + "%"
                  },
                  fn() { ug_scale_label },
                )
                |> ignore
              })
              |> ignore
              plot2.box(fn(cv2) {
                cv2.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
                cv2.by_room(fn(canvas, room) {
                  canvas
                  .height(Is(Some(ov_chart_h)))
                  .shapes(By(fn() {
                    match active_pool() {
                      Some(ap) => ov_velocity_shapes(ap, scale_top_of(ap), room.width(), ov_chart_h)
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
            ov_time_axis_node(col, 6)
          }
        })
        |> ignore
      })
      |> ignore
    })

    // 3. Deduplicated Pay-as-you-go API Balance Rows
    card.show(fn() { api_keys().length() > 0 }, fn(keys_sec) {
      keys_sec.gap(Is(2.0)) |> ignore
      keys_sec.show(fn() { active_pool() is Some(_) }, fn(sep_wrap) {
        sep_wrap.padding(Is((12.0, 0.0, 12.0, 2.0))) |> ignore
        sep_wrap.box(fn(line) {
          line.height(Is(Some(1.0))).ground(By(fn() { @sf.theme().p.line })) |> ignore
        })
        |> ignore
      })
      keys_sec.each(api_keys, fn(item) { text(Some(item.0), "key") }, fn(r, item_sig) {
        let kev = fn() { Some(item_sig.get().0) }
        let bal = fn() { item_sig.get().1 }
        r
        .padding(Is((12.0, 8.0, 12.0, 8.0)))
        .radius(By(ug_row_corner))
        .height(By(fn() { Some(@cmp.maximum(@sf.theme().items.least, @sf.node_sp(r, 20.0) + 16.0)) }))
        .lies_along(Is(Middle))
        .ground(By(fn() { if @sf.lit_node(r) { @ui.tree_theme().color(Hover) } else { 0L } }))
        .says(By(fn() { Some(@view.said(Link, label=ov_account_name(kev()) + " " + bal())) }))
        |> ignore
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
pub fn profiles_overview_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  open_profile? : (String, String) -> Unit,
  on_show_accounts? : () -> Unit,
  bar_actions? : ((@view.View) -> Unit, (@sf.Look) -> Double) -> Unit,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let topic = fn() { (core.topic)("profiles", { "scope": Json::string(here().workspace) }).get() }
  let list_now = @signals.computed(fn(_) { items(topic().value, "items") }, same=jsons_same)
  let list = fn() { list_now.get() }
  let pools_now = @signals.computed(fn(_) { ov_build_pools(list()) }, same=fn(a, b) { a == b })
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
  let add_actions = fn(l : @view.View) {
    l.show(fn() { add() && !frame().named }, fn(a) { @sf.page_add_node(a, label, adding) })
  }
  match bar_actions {
    Some(f) => f(fn(l) { l.show(add, fn(a) { @sf.page_add_node(a, label, adding) }) }, fn(_) { @sf.button_height() })
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
        )
      } else if key == "pools" {
        b.box(fn(sec) {
          sec.padding(Is((0.0, 0.0, 0.0, if has_accounts_tab { 10.0 } else { 24.0 }))) |> ignore
          ov_pools_card_node(sec, core, open_profile, pools, balance_keys)
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
                    left.to_string() + "% left · resets in " + dur
                  } else {
                    "剩 " + left.to_string() + "% · " + dur + "后重置"
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
