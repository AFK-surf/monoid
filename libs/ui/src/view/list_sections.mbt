// Virtualized list bidirectional section stacking and sticky headers (`ListPlace::set_sections`, `View::sticky_section`,
// `ListPlace::bring_section`, `ListPlace::section_state`): closed-form continuous stacking in monotonic ordered `Places`
// coordinates, unified with `View::sticky` in `Tree::sticky_offset_for` and rendered in a dedicated foreground pass
// above body rows and below the scrollbar and pinned `foot`.

///|
/// Stacking state of a section heading at the current scroll offset (read in handlers via `ListPlace::section_state`).
/// Note: `Active` strictly requires `dy > 0` (displaced by top stacking); when a section heading lands exactly at its
/// stacked top slot `p_j == L + S_j` (`dy == 0`, e.g. after `bring_section`), its `SectionState` is `Flow` while
/// `SectionChrome::active` still reports it as the active section.
#derive(Eq, Debug)
pub(all) enum SectionState {
  /// Resting at its natural in-flow position (`drawn_j == p_j`).
  Flow
  /// Currently pinned as the active top section (including while being pushed out by the next section).
  Active
  /// Docked at the top stack above the currently active section.
  Above
  /// Docked at the bottom stack below the viewport body.
  Below
}

///|
/// Summary of stacked section chrome for an optional list-owned overlay presenter (`ListPlace::set_sections`'s `chrome`).
#derive(Eq, Debug)
pub(all) struct SectionChrome[K] {
  active : K?
  above_count : Int
  below_count : Int
  above_overflow : Int
  below_overflow : Int
  top_edge : Double
  bottom_edge : Double
  top_stack_h : Double
  bot_stack_h : Double
  top_edge_key : K?
  bot_edge_key : K?
  top_push : (K, Double)?
  bot_push : (K, Double)?
  active_bottom : Double
  next_top : Double
}

///|
/// Non-generic section configuration stored on private `PlaceAt`, keeping `View::scrolls_window`, `View::scrolls_reused`,
/// `flex::Style`, and `ListPlace[K]` ABI unchanged.
priv struct SectionConfig {
  head : (Int) -> Bool
  tail : (Int) -> Bool
  top_edge : () -> Double
  bottom_edge : () -> Double
  rows : () -> (Int, Int)
  air : (Int) -> Double
  chrome : ((View, () -> SectionChrome[Int]) -> Unit)?
}

///|
/// Per-list callbacks registered on `Tree::section_lists` by `held.at` so the unified sticky offset resolver,
/// foreground pass, and clip bounds query the list's cached section solve in O(1).
priv struct SectionListHooks {
  dy_of : (Int, Double) -> Double
  clip_of : () -> (Double, Double, Double, Double)?
}

///|
/// Monotonic ordered-list geometry of one section heading in `Places` coordinates (`p_{j+1} >= p_j + r_j`).
priv struct SectionGeom {
  key : Int
  p : Double
  r : Double
}

///|
/// Solved positions, offsets, states, and stack heights for all sections of a list at one scroll offset.
priv struct SectionSolved {
  keys : Array[Int]
  ps : Array[Double]
  rs : Array[Double]
  raw_drawn : Array[Double]
  pushed : Array[Bool]
  drawn : Array[Double]
  dys : Array[Double]
  top_floors : Array[Double]
  bot_ceils : Array[Double]
  states : Array[SectionState]
  top_sums : Array[Double]
  mounted_keys : Array[Int]
  by_key : Map[Int, Int]
  eff_top_cap : Int
  eff_bot_cap : Int
  active_idx : Int
  above_count : Int
  below_count : Int
  above_overflow : Int
  below_overflow : Int
  top_edge : Double
  bottom_edge : Double
  top_stack_h : Double
  bot_stack_h : Double
  top_edge_idx : Int
  bot_edge_idx : Int
  top_push_idx : Int
  top_push_by : Double
  bot_push_idx : Int
  bot_push_by : Double
  active_bottom : Double
  next_top : Double
}

///|
fn SectionSolved::empty(top_edge : Double, bottom_edge : Double) -> SectionSolved {
  {
    keys: [],
    ps: [],
    rs: [],
    raw_drawn: [],
    pushed: [],
    drawn: [],
    dys: [],
    top_floors: [],
    bot_ceils: [],
    states: [],
    top_sums: [],
    mounted_keys: [],
    by_key: Map([]),
    eff_top_cap: 0,
    eff_bot_cap: 0,
    active_idx: -1,
    above_count: 0,
    below_count: 0,
    above_overflow: 0,
    below_overflow: 0,
    top_edge,
    bottom_edge,
    top_stack_h: 0.0,
    bot_stack_h: 0.0,
    top_edge_idx: -1,
    bot_edge_idx: -1,
    top_push_idx: -1,
    top_push_by: 0.0,
    bot_push_idx: -1,
    bot_push_by: 0.0,
    active_bottom: 0.0,
    next_top: @double.infinity,
  }
}

///|
/// Maximum sum of any contiguous window of up to `cap` section heights in `geoms` (0 when `cap <= 0` or empty).
fn max_window_sum(geoms : Array[SectionGeom], cap : Int) -> Double {
  let g = geoms.length()
  if cap <= 0 || g == 0 {
    return 0.0
  }
  let w = if cap < g { cap } else { g }
  let mut sum = 0.0
  for i in 0..<w {
    sum = sum + geoms[i].r
  }
  let mut best = sum
  for i in w..<g {
    sum = sum + geoms[i].r - geoms[i - w].r
    if sum > best {
      best = sum
    }
  }
  best
}

///|
/// Closed-form continuous bidirectional section stacking solver in monotonic ordered list coordinates.
///
/// Guarantees:
/// - Empty `geoms` returns empty immediately.
/// - `raw_top_cap == 0` skips the top pass (`u_j = p_j`); `raw_bot_cap == 0` skips the bottom pass (`w_j = p_j`).
/// - Viewport budget downgrades `bot_cap` then `top_cap` down to 0 using actual heights `r_j` so
///   `top_sum_max + bot_sum_max <= B - L`.
/// - Only the trailing sentinel `u[G]` uses `tail_end`; interior headings push each other via `u[j+1] - r[j]`.
/// - Because `p_{j+1} >= p_j + r_j` and `top_sum_max + bot_sum_max <= B - L`, `u_j > p_j` and `w_j < p_j` are
///   mutually exclusive and `drawn_j` is Lipschitz-1 continuous in `x`.
fn solve_sections(
  geoms : Array[SectionGeom],
  tail_end : Double,
  x : Double,
  vh : Double,
  top_edge : Double,
  bottom_edge : Double,
  raw_top_cap : Int,
  raw_bot_cap : Int,
  grid : Double,
) -> SectionSolved {
  let g = geoms.length()
  let te = dmax(0.0, top_edge)
  let be = dmax(0.0, bottom_edge)
  if g == 0 {
    return SectionSolved::empty(te, be)
  }
  let l_edge = x + te
  let b_edge = x + vh - be
  let band = dmax(0.0, b_edge - l_edge)
  let mut top_cap = raw_top_cap.max(0).min(g)
  let mut bot_cap = raw_bot_cap.max(0).min(g)
  let max_cap_within = fn(hi_cap : Int, budget : Double) -> Int {
    if hi_cap <= 0 {
      return 0
    }
    if max_window_sum(geoms, hi_cap) <= budget + 1.0e-6 {
      return hi_cap
    }
    let mut lo = 0
    let mut hi = hi_cap - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if max_window_sum(geoms, mid) <= budget + 1.0e-6 {
        lo = mid
      } else {
        hi = mid - 1
      }
    }
    lo
  }
  if band <= 0.0 {
    top_cap = 0
    bot_cap = 0
  } else {
    let top_sum = max_window_sum(geoms, top_cap)
    if top_sum > band + 1.0e-6 {
      bot_cap = 0
      top_cap = max_cap_within(top_cap, band)
    } else if bot_cap > 0 && top_sum + max_window_sum(geoms, bot_cap) > band + 1.0e-6 {
      bot_cap = max_cap_within(bot_cap, band - top_sum)
    }
  }
  let keys : Array[Int] = Array::make(g, 0)
  let ps : Array[Double] = Array::make(g, 0.0)
  let rs : Array[Double] = Array::make(g, 0.0)
  let by_key : Map[Int, Int] = Map([])
  for j in 0..<g {
    let s = geoms[j]
    keys[j] = s.key
    ps[j] = s.p
    rs[j] = s.r
    by_key[s.key] = j
  }
  // Top pass: S_j = sum of up to (top_cap - 1) preceding section heights; u_G = tail_end;
  // u_j = min(max(p_j, L + S_j), u_{j+1} - r_j).
  let top_sums : Array[Double] = Array::make(g, 0.0)
  let top_floors : Array[Double] = Array::make(g, @double.neg_infinity)
  let u : Array[Double] = Array::make(g, 0.0)
  if top_cap >= 1 {
    let kt = top_cap - 1
    if kt > 0 {
      let mut acc = 0.0
      for j in 0..<g {
        top_sums[j] = acc
        acc = acc + rs[j]
        if j >= kt {
          acc = acc - rs[j - kt]
        }
      }
    }
    let mut u_next = tail_end
    let mut j = g - 1
    while j >= 0 {
      top_floors[j] = dmin(l_edge + top_sums[j], u_next - rs[j])
      let want = dmax(ps[j], l_edge + top_sums[j])
      let uj = dmin(want, u_next - rs[j])
      u[j] = uj
      u_next = uj
      j = j - 1
    }
  } else {
    for j in 0..<g {
      u[j] = ps[j]
    }
  }
  // Bottom pass: T_j = sum of up to (bot_cap - 1) following section heights;
  // w_{-1} = -inf; w_j = max(min(p_j, B - T_j - r_j), w_{j-1} + r_{j-1}).
  let bot_ceils : Array[Double] = Array::make(g, @double.infinity)
  let w : Array[Double] = Array::make(g, 0.0)
  if bot_cap >= 1 {
    let kb = bot_cap - 1
    let bot_sums : Array[Double] = Array::make(g, 0.0)
    if kb > 0 {
      let mut acc = 0.0
      let mut j = g - 1
      while j >= 0 {
        bot_sums[j] = acc
        acc = acc + rs[j]
        if j + kb < g {
          acc = acc - rs[j + kb]
        }
        j = j - 1
      }
    }
    let mut w_prev = @double.neg_infinity
    for j in 0..<g {
      bot_ceils[j] = dmax(b_edge - bot_sums[j] - rs[j], w_prev)
      let want = dmin(ps[j], b_edge - bot_sums[j] - rs[j])
      let wj = dmax(want, w_prev)
      w[j] = wj
      w_prev = wj + rs[j]
    }
  } else {
    for j in 0..<g {
      w[j] = ps[j]
    }
  }
  // Composition, contact-run shared-edge screen-grid quantization (preserving fixed Flow anchors & clip bounds),
  // and unified visible slot / overflow / state classification
  let raw_drawn : Array[Double] = Array::make(g, 0.0)
  let pushed : Array[Bool] = Array::make(g, false)
  let drawn : Array[Double] = Array::make(g, 0.0)
  let dys : Array[Double] = Array::make(g, 0.0)
  let states : Array[SectionState] = Array::make(g, SectionState::Flow)
  let is_top_arr : Array[Bool] = Array::make(g, false)
  let is_bot_arr : Array[Bool] = Array::make(g, false)
  let is_above_ovf : Array[Bool] = Array::make(g, false)
  let is_below_ovf : Array[Bool] = Array::make(g, false)
  for j in 0..<g {
    let is_top = u[j] > ps[j] + 1.0e-9
    let is_bot = !is_top && w[j] < ps[j] - 1.0e-9
    is_top_arr[j] = is_top
    is_bot_arr[j] = is_bot
    let raw = if is_top { u[j] } else if is_bot { w[j] } else { ps[j] }
    raw_drawn[j] = raw
    pushed[j] = is_top && u[j] < l_edge + top_sums[j] - 1.0e-6
    drawn[j] = raw
    is_above_ovf[j] = raw + rs[j] <= l_edge + 1.0e-6
    is_below_ovf[j] = !is_above_ovf[j] && raw >= b_edge - 1.0e-6
  }
  if grid > 0.0 {
    // Quantize each visible contiguous top contact run: anchor backward from a touching Flow neighbor,
    // otherwise quantize at run start and propagate forward (never modifying Flow rows or peeking overflow in).
    let mut j = 0
    while j < g {
      if is_top_arr[j] && !is_above_ovf[j] {
        let mut end = j
        while end + 1 < g &&
          is_top_arr[end + 1] &&
          !is_above_ovf[end + 1] &&
          u[end] + rs[end] >= u[end + 1] - 1.0e-6 {
          end = end + 1
        }
        let next_is_flow = end + 1 < g && !is_top_arr[end + 1] && !is_bot_arr[end + 1]
        if next_is_flow && u[end] + rs[end] >= ps[end + 1] - 1.0e-6 {
          drawn[end] = dmax(ps[end], ps[end + 1] - rs[end])
          let mut k = end
          while k > j {
            drawn[k - 1] = dmax(ps[k - 1], drawn[k] - rs[k - 1])
            k = k - 1
          }
        } else {
          drawn[j] = dmax(ps[j], x + ((u[j] - x) * grid).round() / grid)
          for k in j..<end {
            drawn[k + 1] = dmax(ps[k + 1], drawn[k] + rs[k])
          }
          if next_is_flow && drawn[end] + rs[end] > ps[end + 1] {
            drawn[end] = dmax(ps[end], ps[end + 1] - rs[end])
            let mut k = end
            while k > j {
              drawn[k - 1] = dmax(ps[k - 1], drawn[k] - rs[k - 1])
              k = k - 1
            }
          }
        }
        j = end + 1
      } else {
        j = j + 1
      }
    }
    // Quantize each visible contiguous bottom contact run: anchor forward from a touching Flow/Top neighbor,
    // otherwise quantize at run end and propagate backward (never modifying Flow rows or peeking overflow in).
    let mut bj = g - 1
    while bj >= 0 {
      if is_bot_arr[bj] && !is_below_ovf[bj] {
        let mut start = bj
        while start - 1 >= 0 &&
          is_bot_arr[start - 1] &&
          !is_below_ovf[start - 1] &&
          w[start - 1] + rs[start - 1] >= w[start] - 1.0e-6 {
          start = start - 1
        }
        let touches_left = start - 1 >= 0 &&
          !is_bot_arr[start - 1] &&
          raw_drawn[start - 1] + rs[start - 1] >= w[start] - 1.0e-6
        if touches_left {
          drawn[start] = dmin(ps[start], drawn[start - 1] + rs[start - 1])
          for k in start..<bj {
            drawn[k + 1] = dmin(ps[k + 1], drawn[k] + rs[k])
          }
        } else {
          drawn[bj] = dmin(ps[bj], x + ((w[bj] - x) * grid).round() / grid)
          let mut k = bj
          while k > start {
            drawn[k - 1] = dmin(ps[k - 1], drawn[k] - rs[k - 1])
            k = k - 1
          }
          if start - 1 >= 0 && drawn[start] < drawn[start - 1] + rs[start - 1] {
            drawn[start] = dmin(ps[start], drawn[start - 1] + rs[start - 1])
            for k2 in start..<bj {
              drawn[k2 + 1] = dmin(ps[k2 + 1], drawn[k2] + rs[k2])
            }
          }
        }
        bj = start - 1
      } else {
        bj = bj - 1
      }
    }
    // Preserve monotonic non-overlap across non-contact adjacent pairs without ever moving Flow rows or flipping side
    if g > 1 {
      let mut k = g - 2
      while k >= 0 {
        if is_top_arr[k] && drawn[k] > drawn[k + 1] - rs[k] {
          drawn[k] = dmax(ps[k], drawn[k + 1] - rs[k])
        }
        k = k - 1
      }
      for k2 in 1..<g {
        if is_bot_arr[k2] && drawn[k2] < drawn[k2 - 1] + rs[k2 - 1] {
          drawn[k2] = dmin(ps[k2], drawn[k2 - 1] + rs[k2 - 1])
        }
      }
    }
  }
  for j in 0..<g {
    let dy = drawn[j] - ps[j]
    if dy.abs() <= 1.0e-9 {
      dys[j] = 0.0
      drawn[j] = ps[j]
    } else {
      dys[j] = dy
    }
    // Align continuous FLIP clamp bounds with post-quantization drawn positions so oy -> 0 is exact
    if is_top_arr[j] {
      top_floors[j] = drawn[j]
    } else if top_cap >= 1 {
      let tf = if grid > 0.0 { x + ((top_floors[j] - x) * grid).round() / grid } else { top_floors[j] }
      top_floors[j] = dmin(ps[j], tf)
    }
    if is_bot_arr[j] {
      bot_ceils[j] = drawn[j]
    } else if bot_cap >= 1 {
      let bc = if grid > 0.0 { x + ((bot_ceils[j] - x) * grid).round() / grid } else { bot_ceils[j] }
      bot_ceils[j] = dmax(ps[j], bc)
    }
    if top_floors[j] > bot_ceils[j] {
      top_floors[j] = bot_ceils[j]
    }
  }
  let mut active_idx = -1
  if top_cap >= 1 {
    for j in 0..<g {
      if ps[j] <= l_edge + top_sums[j] + 1.0e-6 && !is_above_ovf[j] {
        active_idx = j
      }
    }
  } else if tail_end > l_edge + 1.0e-6 {
    for j in 0..<g {
      if ps[j] <= l_edge + 1.0e-6 {
        active_idx = j
      }
    }
  }
  let mounted_keys : Array[Int] = []
  let mut above_count = 0
  let mut below_count = 0
  let mut above_overflow = 0
  let mut below_overflow = 0
  let mut top_stack_end = l_edge
  let mut bot_stack_start = b_edge
  let mut top_edge_idx = -1
  let mut bot_edge_idx = -1
  let mut top_push_idx = -1
  let mut top_push_by = 0.0
  let mut bot_push_idx = -1
  let mut bot_push_by = 0.0
  // Quantized top clip edge using the exact same `((l_edge - x) * grid).round()` expression as contact-run snapping
  // (so IEEE-754 half-ties like `((x + 51.0) - x) * 1.5` match resting slot-0 `drawn[j]` bit-for-bit across all `x`).
  let l_edge_q = if grid > 0.0 { x + ((l_edge - x) * grid).round() / grid } else { l_edge }
  for j in 0..<g {
    let dy = dys[j]
    if is_above_ovf[j] {
      states[j] = Above
      above_overflow = above_overflow + 1
    } else if is_top_arr[j] && j < active_idx && dy > 1.0e-6 {
      states[j] = Above
      above_count = above_count + 1
      mounted_keys.push(keys[j])
      if drawn[j] + rs[j] >= top_stack_end {
        top_stack_end = drawn[j] + rs[j]
        top_edge_idx = j
      }
    } else if is_top_arr[j] && j == active_idx && dy > 1.0e-6 {
      states[j] = Active
      mounted_keys.push(keys[j])
      if drawn[j] + rs[j] >= top_stack_end {
        top_stack_end = drawn[j] + rs[j]
        top_edge_idx = j
      }
    } else if is_below_ovf[j] {
      states[j] = if is_bot_arr[j] && dy < -1.0e-6 { Below } else { Flow }
      below_overflow = below_overflow + 1
    } else if is_bot_arr[j] && dy < -1.0e-6 {
      states[j] = Below
      below_count = below_count + 1
      mounted_keys.push(keys[j])
      if drawn[j] <= bot_stack_start {
        bot_stack_start = drawn[j]
        bot_edge_idx = j
      }
    } else {
      states[j] = Flow
    }
    if top_cap >= 1 && !is_above_ovf[j] && drawn[j] < l_edge_q - 1.0e-6 && drawn[j] + rs[j] > l_edge_q + 1.0e-6 {
      top_push_idx = j
      top_push_by = l_edge_q - drawn[j]
    }
    if bot_cap >= 1 && !is_below_ovf[j] {
      // Exact quantized resting bottom slot for heading `j`, matching bottom contact-run snapping bit-for-bit
      let bot_rest_q = if grid > 0.0 { x + ((b_edge - rs[j] - x) * grid).round() / grid } else { b_edge - rs[j] }
      if drawn[j] > bot_rest_q + 1.0e-6 && drawn[j] < b_edge - 1.0e-6 {
        bot_push_idx = j
        bot_push_by = drawn[j] - bot_rest_q
      }
    }
  }
  let top_stack_h = dmax(0.0, top_stack_end - l_edge)
  let bot_stack_h = dmax(0.0, b_edge - bot_stack_start)
  let active_bottom = if active_idx >= 0 { ps[active_idx] + rs[active_idx] - x } else { 0.0 }
  let next_top = if active_idx >= 0 && active_idx + 1 < g {
    ps[active_idx + 1] - x
  } else {
    @double.infinity
  }
  {
    keys,
    ps,
    rs,
    raw_drawn,
    pushed,
    drawn,
    dys,
    top_floors,
    bot_ceils,
    states,
    top_sums,
    mounted_keys,
    by_key,
    eff_top_cap: top_cap,
    eff_bot_cap: bot_cap,
    active_idx,
    above_count,
    below_count,
    above_overflow,
    below_overflow,
    top_edge: te,
    bottom_edge: be,
    top_stack_h,
    bot_stack_h,
    top_edge_idx,
    bot_edge_idx,
    top_push_idx,
    top_push_by,
    bot_push_idx,
    bot_push_by,
    active_bottom,
    next_top,
  }
}

///|
/// Register virtualized section stacking on a list's `ListPlace`, keeping `View::scrolls_window`, `View::scrolls_reused`,
/// `flex::Style`, and `ListPlace` ABI unchanged.
///
/// - `head`: identifies section heading keys.
/// - `tail`: identifies trailing non-section keys (`load_more`, footers, etc.) that terminate the last section.
/// - `top_edge` / `bottom_edge`: available-viewport top and bottom insets for section stacking and clipping.
/// - `rows`: returns `(top_cap, bot_cap)` max visible stacked rows at top/bottom (`0` disables that edge completely).
/// - `air`: optional top air offset for `ListPlace::bring_section`.
/// - `chrome`: optional list-owned overlay presenter receiving live `SectionChrome[K]` without layout readback.
pub fn[K] ListPlace::set_sections(
  self : ListPlace[K],
  head : (K) -> Bool,
  tail? : (K) -> Bool = fn(_) { false },
  top_edge? : () -> Double = fn() { 0.0 },
  bottom_edge? : () -> Double = fn() { 0.0 },
  rows? : () -> (Int, Int) = fn() { (1, 0) },
  air? : (K) -> Double = fn(_) { 0.0 },
  chrome? : (View, () -> SectionChrome[K]) -> Unit,
) -> Unit {
  let ids = self.ids
  let sl = self.slices
  let key_of = fn(i : Int) { ids.key(sl.kid_of(i)) }
  let is_first_slice = fn(i : Int) { sl.sid(sl.kid_of(i), 0) == i }
  let chrome_ids = chrome.map(fn(make_chrome) {
    fn(v : View, read : () -> SectionChrome[Int]) {
      make_chrome(v, fn() {
        let c = read()
        {
          active: c.active.map(key_of),
          above_count: c.above_count,
          below_count: c.below_count,
          above_overflow: c.above_overflow,
          below_overflow: c.below_overflow,
          top_edge: c.top_edge,
          bottom_edge: c.bottom_edge,
          top_stack_h: c.top_stack_h,
          bot_stack_h: c.bot_stack_h,
          top_edge_key: c.top_edge_key.map(key_of),
          bot_edge_key: c.bot_edge_key.map(key_of),
          top_push: c.top_push.map(fn(p) { (key_of(p.0), p.1) }),
          bot_push: c.bot_push.map(fn(p) { (key_of(p.0), p.1) }),
          active_bottom: c.active_bottom,
          next_top: c.next_top,
        }
      })
    }
  })
  self.at.sections = Some({
    head: fn(i) { is_first_slice(i) && head(key_of(i)) },
    tail: fn(i) { tail(key_of(i)) },
    top_edge,
    bottom_edge,
    rows,
    air: fn(i) { air(key_of(i)) },
    chrome: chrome_ids,
  })
  self.at.sections_rev = self.at.sections_rev + 1
  (self.at.on_sections)()
  (self.at.laid_again)()
}

///|
/// Jump or glide to section heading `key` so it lands at its exact stacked top slot `L + S_j`
/// (`offset = air_j - S_j + scroll.top_covered() - section_top_edge`), accepting scroll-end clamping cleanly.
pub fn[K : Hash + Eq] ListPlace::bring_section(self : ListPlace[K], key : K, glide? : Bool = true) -> Unit {
  (self.at.bring_section)(self.slices.sid(self.ids.id(key), 0), glide)
}

///|
/// Handler-only query returning the current `SectionState` (`Flow`, `Active`, `Above`, `Below`) of section heading `key`.
pub fn[K : Hash + Eq] ListPlace::section_state(self : ListPlace[K], key : K) -> SectionState {
  (self.at.section_state)(self.slices.sid(self.ids.id(key), 0))
}

///|
/// Mark a node inside a virtualized list's section heading block as participating in the list's bidirectional section
/// stacking (`ListPlace::set_sections`): offset by the closed-form solver in the unified sticky walk, drawn in the
/// dedicated foreground pass above body rows and below scrollbar/`foot`, hit-tested in reverse foreground order, and
/// clipped to `[top_edge, vh - bottom_edge]`.
pub fn View::sticky_section(self : View) -> View {
  guard self.live() is Some(_) else { return self }
  let tree = self.tree
  let at = self.at
  let gen = self.gen
  tree.section_stickies[at] = gen
  tree.place_marked_at(at)
  self.owns(fn() {
    match tree.section_stickies.get(at) {
      Some(g) if g == gen => tree.section_stickies.remove(at)
      _ => ()
    }
  })
  |> ignore
  self
}

///|
/// Extracted per-list section-stacking host state & methods (kept out of `View::scrolls_window_ids` so `mbc` splits
/// section-stacking code into its own parallel C unit instead of inflating `scrolls_window_ids`).
priv struct SectionWindowHost {
  list : View
  scroll : Scroll
  place_at : PlaceAt
  from_end : Bool
  keys : () -> Array[Int]
  laid_get : () -> Column[Int]
  laid_untracked : () -> Column[Int]
  laid_at : Map[Int, Int]
  places_of : Ref[(Column[Int]) -> Places[Int]]
  sec_under_of : Ref[() -> Double]
  laid_rev : Ref[Int]
  keys_rev : Ref[Int]
  sec_config_rev : Ref[Int]
  sections_ver : @signals.Signal[Int]
  members_ver : @signals.Signal[Int]
  config_ver : @signals.Signal[Int]
  pinned_sections : @signals.Signal[Array[Int]]
  held_node : Ref[Int]
  sec_index_cache : Ref[(Int, Int, Array[Int], Int)?]
  sec_head_set : Map[Int, Bool]
  sec_cache : Ref[(Int, Int, Bool, Double, Double, Double, Double, Double, Double, Int, Int, Double, Double, SectionSolved)?]
  hooks_attached : Ref[Bool]
  chrome_v : Ref[View?]
}

///|
fn SectionWindowHost::sec_off(self : SectionWindowHost, all : Places[Int], vh : Double) -> Double {
  if !self.from_end {
    return 0.0
  }
  dmax(0.0, vh - (all.foot() + (self.sec_under_of.val)()))
}

///|
fn SectionWindowHost::clear_cache(self : SectionWindowHost) -> Unit {
  self.sec_index_cache.val = None
  self.sec_cache.val = None
}

///|
fn SectionWindowHost::indices_now(self : SectionWindowHost, all : Places[Int]) -> (Array[Int], Int) {
  guard self.place_at.sections is Some(sec) else { return ([], -1) }
  let krev = self.keys_rev.val
  let srev = self.place_at.sections_rev + self.sec_config_rev.val
  match self.sec_index_cache.val {
    Some((c_krev, c_srev, heads, tail_idx)) if c_krev == krev && c_srev == srev => return (heads, tail_idx)
    _ => ()
  }
  let n = all.length()
  let heads : Array[Int] = []
  self.sec_head_set.clear()
  for i in 0..<n {
    let k = all.key(i)
    if @signals.untracked(fn() { (sec.head)(k) }) {
      heads.push(i)
      self.sec_head_set[k] = true
    }
  }
  let mut tail_idx = -1
  if !heads.is_empty() {
    let last_sec_idx = heads[heads.length() - 1]
    for t in (last_sec_idx + 1)..<n {
      if @signals.untracked(fn() { (sec.tail)(all.key(t)) }) {
        tail_idx = t
        break
      }
    }
  }
  self.sec_index_cache.val = Some((krev, srev, heads, tail_idx))
  (heads, tail_idx)
}

///|
fn SectionWindowHost::solve_now(self : SectionWindowHost, all : Places[Int], x : Double, vh : Double) -> SectionSolved {
  guard self.place_at.sections is Some(sec) else { return SectionSolved::empty(0.0, 0.0) }
  let (te, be, (tc, bc)) = @signals.untracked(fn() { ((sec.top_edge)(), (sec.bottom_edge)(), (sec.rows)()) })
  let off = self.sec_off(all, vh)
  let lrev = self.laid_rev.val
  let srev = self.place_at.sections_rev + self.sec_config_rev.val
  let static_places = all.froms.is_empty() && all.tail_spans.is_empty()
  let tree = self.list.tree
  let (drawn_t, logic_t) = if static_places {
    (-1.0, -1.0)
  } else {
    @signals.untracked(fn() { (tree.drawn_said(), tree.logic_said()) })
  }
  let g = if tree.rows_grid > 0.0 { tree.rows_grid } else { tree.pixel_grid }
  match self.sec_cache.val {
    Some((c_lrev, c_srev, c_st, c_dt, c_lt, c_x, c_vh, c_te, c_be, c_tc, c_bc, c_off, c_g, solved)) if c_lrev == lrev &&
      c_srev == srev &&
      c_st == static_places &&
      c_dt == drawn_t &&
      c_lt == logic_t &&
      c_x == x &&
      c_vh == vh &&
      c_te == te &&
      c_be == be &&
      c_tc == tc &&
      c_bc == bc &&
      c_off == off &&
      c_g == g => return solved
    _ => ()
  }
  let (heads, tail_idx) = self.indices_now(all)
  if heads.is_empty() {
    let empty = SectionSolved::empty(te, be)
    self.sec_cache.val = Some((lrev, srev, static_places, drawn_t, logic_t, x, vh, te, be, tc, bc, off, g, empty))
    return empty
  }
  let n = all.length()
  let geoms : Array[SectionGeom] = []
  for i in heads {
    if i < n {
      geoms.push({ key: all.key(i), p: all.top(i) + off, r: all.h(i) })
    }
  }
  if geoms.is_empty() {
    let empty = SectionSolved::empty(te, be)
    self.sec_cache.val = Some((lrev, srev, static_places, drawn_t, logic_t, x, vh, te, be, tc, bc, off, g, empty))
    return empty
  }
  let tail_end = if tail_idx >= 0 && tail_idx < n { all.top(tail_idx) + off } else { all.foot() + off }
  let solved = solve_sections(geoms, tail_end, x, vh, te, be, tc, bc, g)
  self.sec_cache.val = Some((lrev, srev, static_places, drawn_t, logic_t, x, vh, te, be, tc, bc, off, g, solved))
  solved
}

///|
fn SectionWindowHost::solve_pin_x(
  self : SectionWindowHost,
  all : Places[Int],
  vh : Double,
  pk : Int,
  raw_proj_y : Double,
  r_j : Double,
  cur_tx : Double,
  was_pushed : Bool,
  pin_span0 : Ref[Double?],
) -> Double {
  guard self.place_at.sections is Some(_) else { return cur_tx }
  guard self.laid_at.get(pk) is Some(pi) && pi < all.length() else { return cur_tx }
  let (heads, tail_idx) = self.indices_now(all)
  let mut sj = -1
  for j in 0..<heads.length() {
    if heads[j] == pi {
      sj = j
      break
    }
  }
  guard sj >= 0 else { return cur_tx }
  let solved = self.solve_now(all, cur_tx, vh)
  let cur_r_j = if sj < solved.rs.length() { solved.rs[sj] } else { r_j }
  let c = solved.top_edge + (if sj < solved.top_sums.length() { solved.top_sums[sj] } else { 0.0 })
  let off = self.sec_off(all, vh)
  let p_j = all.top(pi) + off
  let n = all.length()
  let e_j = if sj + 1 < heads.length() && heads[sj + 1] < n {
    all.top(heads[sj + 1]) + off
  } else if tail_idx >= 0 && tail_idx < n {
    all.top(tail_idx) + off
  } else {
    all.foot() + off
  }
  if was_pushed {
    dmax(0.0, e_j - cur_r_j - raw_proj_y)
  } else {
    let lo_eff = dmax(0.0, p_j - c)
    let hi = e_j - cur_r_j - c
    let span = hi - lo_eff
    if span <= 0.0 {
      lo_eff
    } else {
      let span0 = match pin_span0.val {
        Some(s0) => s0
        None => {
          pin_span0.val = Some(span)
          span
        }
      }
      // Proportionally contract `x` within `[lo_eff, hi(t)]` along the curtain S-curve so the sticky heading stays
      // pinned at `y = c` on every frame while avoiding the C1 velocity kink of hitting `cur_tx == hi(t)` mid-collapse.
      if cur_tx > lo_eff && span0 > 0.0 && span < span0 {
        let frac = dclamp((cur_tx - lo_eff) / span0, 0.0, 1.0)
        lo_eff + frac * span
      } else {
        dclamp(cur_tx, lo_eff, hi)
      }
    }
  }
}

///|
fn SectionWindowHost::sync_slots(
  self : SectionWindowHost,
  held : View,
  slot_views : Map[Int, View],
  slot_oob_bind : Map[Int, () -> Unit],
) -> Unit {
  let hat = held.at
  let tree = self.list.tree
  let stacking = match self.place_at.sections {
    Some(sec) => {
      let (tc, bc) = @signals.untracked(sec.rows)
      tc > 0 || bc > 0
    }
    None => false
  }
  if stacking {
    for k, sv in slot_views {
      if sv.alive() && self.sec_head_set.contains(k) {
        tree.section_slots[sv.at] = (sv.gen, hat, k)
        match slot_oob_bind.get(k) {
          Some(bind) => bind()
          None => ()
        }
      } else if sv.alive() {
        match tree.section_slots.get(sv.at) {
          Some((g, h, _)) if g == sv.gen && h == hat => tree.section_slots.remove(sv.at)
          _ => ()
        }
      }
    }
  } else {
    for _, sv in slot_views {
      if sv.alive() {
        match tree.section_slots.get(sv.at) {
          Some((g, h, _)) if g == sv.gen && h == hat => tree.section_slots.remove(sv.at)
          _ => ()
        }
      }
    }
  }
}

///|
fn SectionWindowHost::ensure_hooks(
  self : SectionWindowHost,
  held : View,
  slot_keys : @signals.Signal[Array[Int]],
  slot_views : Map[Int, View],
  slot_oob_bind : Map[Int, () -> Unit],
  laid_again : () -> Unit,
) -> Unit {
  guard self.place_at.sections is Some(_) && held.alive() else { return }
  let tree = self.list.tree
  if !self.hooks_attached.val {
    self.hooks_attached.val = true
    let held_at = held.at
    let list_at = self.list.at
    let list_gen = self.list.gen
    let list_vh_now = fn() {
      if self.list.alive() && tree.nodes[list_at].lh > 0.0 {
        tree.nodes[list_at].lh
      } else {
        match self.scroll.seen.untracked() {
          Some((_, vh)) => vh
          None => 0.0
        }
      }
    }
    let solve_for_walk = fn() {
      let all = (self.places_of.val)((self.laid_untracked)())
      let vh = list_vh_now()
      let x = -tree.scroll_off_now(tree.nodes[held_at]).1
      (self.solve_now(all, x, vh), vh)
    }
    tree.section_lists[held_at] = {
      dy_of: fn(k, oy) {
        let (solved, vh) = solve_for_walk()
        match solved.by_key.get(k) {
          Some(j) => {
            let base_top = if self.pinned_sections.untracked().contains(k) && !slot_keys.untracked().contains(k) {
              let counted_all = Places::counted((self.laid_untracked)())
              match self.laid_at.get(k) {
                Some(i) if i < counted_all.length() => counted_all.top(i) + self.sec_off(counted_all, vh)
                _ => solved.ps[j]
              }
            } else {
              solved.ps[j]
            }
            if oy == 0.0 {
              if base_top == solved.ps[j] {
                solved.dys[j]
              } else {
                solved.drawn[j] - base_top
              }
            } else {
              let q = solved.ps[j] + oy
              let floor_j = solved.top_floors[j]
              let ceil_j = solved.bot_ceils[j]
              let target = if q < floor_j {
                floor_j
              } else if q > ceil_j {
                ceil_j
              } else {
                q
              }
              target - (base_top + oy)
            }
          }
          None => 0.0
        }
      },
      clip_of: fn() {
        guard self.list.alive() && tree.nodes[list_at].gen == list_gen else { return None }
        guard self.place_at.sections is Some(sec) else { return None }
        let (lx, ly, _, ls) = tree.projected(list_at, drawn=true)
        let ln = tree.nodes[list_at]
        let te = dmax(0.0, @signals.untracked(sec.top_edge))
        let be = dmax(0.0, @signals.untracked(sec.bottom_edge))
        let g = if tree.rows_grid > 0.0 { tree.rows_grid } else { tree.pixel_grid }
        let te_q = if g > 0.0 { (te * g).round() / g } else { te }
        let bot_y = dmax(te, ln.lh - be)
        let bot_q = if g > 0.0 { dmax(te_q, (bot_y * g).round() / g) } else { bot_y }
        Some((lx, ly + te_q * ls, lx + ln.lw * ls, ly + bot_q * ls))
      },
    }
    held.owns(fn() { tree.section_lists.remove(held_at) }) |> ignore
    let mem_watch_init = Ref(true)
    let prev_members : Ref[(Array[Int], Int)] = Ref(([], -1))
    self.list.reacts(
      fn() {
        let v = self.sections_ver.get()
        let ks = (self.keys)()
        match self.place_at.sections {
          Some(sec) => {
            let n = ks.length()
            let heads : Array[Int] = []
            let head_keys : Array[Int] = []
            for i in 0..<n {
              let k = ks[i]
              if (sec.head)(k) {
                heads.push(i)
                head_keys.push(k)
              }
            }
            let mut tail_idx = -1
            if !heads.is_empty() {
              let last_sec_idx = heads[heads.length() - 1]
              for t in (last_sec_idx + 1)..<n {
                if (sec.tail)(ks[t]) {
                  tail_idx = t
                  break
                }
              }
            }
            (v, heads, head_keys, tail_idx)
          }
          None => (v, [], [], -1)
        }
      },
      fn(res) {
        let (_, heads, head_keys, tail_idx) = res
        let changed = mem_watch_init.val || prev_members.val != (heads, tail_idx)
        prev_members.val = (heads, tail_idx)
        self.sec_config_rev.val = self.sec_config_rev.val + 1
        self.sec_head_set.clear()
        for hk in head_keys {
          self.sec_head_set[hk] = true
        }
        self.sec_index_cache.val = Some(
          (self.keys_rev.val, self.place_at.sections_rev + self.sec_config_rev.val, heads, tail_idx),
        )
        self.sec_cache.val = None
        self.sync_slots(held, slot_views, slot_oob_bind)
        if mem_watch_init.val {
          mem_watch_init.val = false
        } else if changed {
          self.members_ver.set(self.members_ver.untracked() + 1)
          tree.order_marked_in(held_at)
          laid_again()
        }
      },
      at_start=true,
    )
    let cfg_watch_init = Ref(true)
    self.list.reacts(
      fn() {
        let v = self.sections_ver.get()
        match self.place_at.sections {
          Some(sec) => (v, (sec.top_edge)(), (sec.bottom_edge)(), (sec.rows)())
          None => (v, 0.0, 0.0, (0, 0))
        }
      },
      fn(_) {
        self.sec_cache.val = None
        if cfg_watch_init.val {
          cfg_watch_init.val = false
        } else {
          self.sync_slots(held, slot_views, slot_oob_bind)
          tree.order_marked_in(held_at)
          self.config_ver.set(self.config_ver.untracked() + 1)
          laid_again()
        }
      },
      at_start=true,
    )
  } else {
    self.sync_slots(held, slot_views, slot_oob_bind)
    tree.order_marked_in(held.at)
  }
}

///|
fn SectionWindowHost::sync_chrome(
  self : SectionWindowHost,
  room_under : () -> Double,
  foot_room : @signals.Signal[Double],
) -> Unit {
  guard self.list.alive() else { return }
  let tree = self.list.tree
  match self.chrome_v.val {
    Some(old) => {
      self.chrome_v.val = None
      if old.alive() {
        self.list.drop(old)
      }
    }
    None => ()
  }
  match self.place_at.sections {
    Some({ chrome: Some(make_chrome), .. }) => {
      let ch = self.list.box(fn(host) {
        let hs = tree.nodes[host.at].flex.style
        hs.position = @flex.PositionType::Absolute
        hs.set_inset_left(Pt(0.0))
        hs.set_inset_right(Pt(0.0))
        hs.set_inset_top(Pt(0.0))
        hs.set_inset_bottom(Pt(0.0))
        host.drawn_clear_of(self.list) |> ignore
        let read_chrome = fn() -> SectionChrome[Int] {
          self.members_ver.get() |> ignore
          self.config_ver.get() |> ignore
          let all = (self.places_of.val)((self.laid_get)())
          let vh = match self.scroll.seen.get() {
            Some((_, h)) => h
            None => 0.0
          }
          let under = room_under() + self.scroll.tuck_room.get() + foot_room.get()
          let smost = self.scroll.most_now()
          let max_x = if !smost.is_nan() && !smost.is_inf() && smost >= 0.0 {
            smost
          } else {
            dmax(0.0, all.foot() + under - vh)
          }
          let raw_x = self.scroll.drawn(tree)
          let clamped_x = if raw_x.is_nan() || raw_x < 0.0 {
            0.0
          } else if raw_x.is_inf() || raw_x > max_x {
            max_x
          } else {
            raw_x
          }
          let x = if self.held_node.val >= 0 &&
            self.held_node.val < tree.nodes.length() &&
            tree.nodes[self.held_node.val].live {
            -self.scroll.drawn_off(tree, self.held_node.val, clamped_x, 0.0)
          } else {
            clamped_x
          }
          match self.place_at.sections {
            Some(sec) => {
              let _ = ((sec.top_edge)(), (sec.bottom_edge)(), (sec.rows)())
            }
            None => ()
          }
          let solved = self.solve_now(all, x, vh)
          {
            active: if solved.active_idx >= 0 { Some(solved.keys[solved.active_idx]) } else { None },
            above_count: solved.above_count,
            below_count: solved.below_count,
            above_overflow: solved.above_overflow,
            below_overflow: solved.below_overflow,
            top_edge: solved.top_edge,
            bottom_edge: solved.bottom_edge,
            top_stack_h: solved.top_stack_h,
            bot_stack_h: solved.bot_stack_h,
            top_edge_key: if solved.top_edge_idx >= 0 { Some(solved.keys[solved.top_edge_idx]) } else { None },
            bot_edge_key: if solved.bot_edge_idx >= 0 { Some(solved.keys[solved.bot_edge_idx]) } else { None },
            top_push: if solved.top_push_idx >= 0 { Some((solved.keys[solved.top_push_idx], solved.top_push_by)) } else { None },
            bot_push: if solved.bot_push_idx >= 0 { Some((solved.keys[solved.bot_push_idx], solved.bot_push_by)) } else { None },
            active_bottom: solved.active_bottom,
            next_top: solved.next_top,
          }
        }
        make_chrome(host, read_chrome)
      })
      self.chrome_v.val = Some(ch)
      let kids = tree.nodes[self.list.at].kids
      match (kids.search(ch.at), kids.search(self.held_node.val)) {
        (Some(ci), Some(hi)) if ci > hi + 1 => {
          kids.remove(ci) |> ignore
          kids.insert(hi + 1, ch.at)
          self.list.boxes_again()
          tree.order_marked_in(self.list.at)
        }
        _ => ()
      }
    }
    _ => ()
  }
}

///|
fn SectionWindowHost::attach(
  self : SectionWindowHost,
  held : View,
  slot_keys : @signals.Signal[Array[Int]],
  slot_views : Map[Int, View],
  slot_oob_bind : Map[Int, () -> Unit],
  laid_again : () -> Unit,
  room_under : () -> Double,
  foot_room : @signals.Signal[Double],
) -> Unit {
  self.place_at.on_sections = fn() {
    self.sections_ver.set(self.place_at.sections_rev)
    self.clear_cache()
    self.ensure_hooks(held, slot_keys, slot_views, slot_oob_bind, laid_again)
    self.sync_chrome(room_under, foot_room)
  }
  self.list.owns(fn() {
    self.chrome_v.val = None
    self.place_at.on_sections = fn() {  }
  })
  |> ignore
  if self.place_at.sections is Some(_) {
    self.ensure_hooks(held, slot_keys, slot_views, slot_oob_bind, laid_again)
    self.sync_chrome(room_under, foot_room)
  }
}
