// Quota and meter chip nodes (moved from libs/ui/src/controls/quota_node.mbt).

///|
/// An allowance's windows as chips in a line (quota_chips', not worded, as a node) in `parent`, `q` as the core says it
/// now: a chip per window, what is left in it, filled as far as that, its mark before it where `marked`; `small` a lower
/// line; `gap` apart; nothing while the core cannot say or there is no window. Each says what is left of it and when it
/// fills again over it while it is pointed at, in `tips` (`tips_within`: while the pointer is within it, fill_chip_node's).
pub fn quota_chips_node(
  parent : @view.View,
  q : () -> Json?,
  small? : Bool = false,
  marked? : Bool = true,
  gap? : Double = 8.0,
  tips? : @sf.TipLayer,
  tips_within? : Bool = false,
) -> Unit {
  let windows = fn() {
    match @sf.chip_field(q(), "windows") {
      Some(Array(a)) => a
      _ => []
    }
  }
  parent.show(fn() { has_quota(q()) }, fn(r) {
    @sf.style_node(r, fn() { quota_chips_row }, in_row=true)
    r.gap(Is(gap)).shrink(Is(0.0)) |> ignore
    r.each(fn() { Array::makei(windows().length(), fn(i) { i }) }, fn(i) { i }, fn(c, i) {
      let k = i.untracked()
      let w = fn() { windows().get(k) }
      @sf.fill_chip_node(
        c,
        fn() { @sf.chip_left(w()) },
        fn() { @sf.chip_str(w(), "level") },
        fn() { if marked { quota_mark(w()) } else { "" } },
        fn() { quota_figure(w()) },
        small~,
        label_muted=true,
        refill=fn() { quota_is_refill(w()) },
        said=fn() { quota_said(w()) },
        tips?,
        tips_within~,
      )
      |> ignore
    })
  })
}

///|
/// A machine's CPU, memory and disk in `parent`, as `meters` says them now: each a chip, what
/// is left in it, filled as far as is used, its mark before it; 8 apart in a line; what it is (its name, how much of
/// how much, a note) over it while it is pointed at, in `tips`.
#callsite(autofill(loc))
pub fn meter_chips_node(parent : @view.View, meters : () -> Array[Json], tips? : @sf.TipLayer, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(r) {
    @sf.style_node(r, fn() { meter_line_way }, in_row=true)
    r.shrink(Is(0.0)) |> ignore
    r.each(fn() { Array::makei(meters().length(), fn(i) { i }) }, fn(i) { i }, fn(c, i) {
      let k = i.untracked()
      let m = fn() { meters().get(k) }
      @sf.fill_chip_node(
        c,
        fn() { 100 - @sf.chip_left(m()) },
        fn() { @sf.chip_str(m(), "level") },
        fn() { @sf.chip_str(m(), "short") },
        fn() { @sf.chip_str(m(), "remaining") },
        said=fn() {
          let note = @sf.chip_str(m(), "note")
          match @sf.chip_str(m(), "label") {
            "" => ""
            label => label + " " + @sf.chip_str(m(), "value") + (if note != "" { " · " + note } else { "" })
          }
        },
        tips?,
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// Window names and figures in one row when they fit, else by their marks (quota_chips' worded ways). Where even that
/// line does not fit, its lines (quota_chips_lines'): the account's windows a line by their names, each multi-window
/// model pool a line of its own with its group name in a column on the left and its short `[5h │ %] [W │ %]` capsules
/// beside it, what single models have to themselves a line by their marks; a line going on in lines where it must.
/// Pointing at a chip shows its full quota and refill description.
#callsite(autofill(loc))
pub fn quota_worded_node(
  parent : @view.View,
  q : () -> Json?,
  gap? : Double = 8.0,
  tips? : @sf.TipLayer,
  room_w? : () -> Double,
  loc~ : SourceLoc,
) -> Unit {
  parent.show(fn() { has_quota(q()) }, fn(x) {
    let windows_sig = @signals.computed(fn(_) {
      match @sf.chip_field(q(), "windows") {
        Some(Array(a)) => a
        _ => []
      }
    })
    let windows = fn() { windows_sig.get() }
    let parts_sig = @signals.computed(fn(_) { quota_parts(windows()) })
    let parts = fn() { parts_sig.get() }
    let pooled_sig = @signals.computed(fn(_) { parts().iter().any(fn(p) { p.0 != "" }) })
    let pooled = fn() { pooled_sig.get() }
    let part = fn(k : Int) { parts().get(k).unwrap_or(("", [])) }
    let build = fn(held : @view.View, avail_w : () -> Double) {
      // (how wide a line of its chips said `form`'s way stands, `gap` apart: each chip its words' room and theirs)
      let wide = fn(form : Int) {
        let look = @ui.style_words(@sf.chip_text)
        let label_look = @ui.style_words(@sf.chip_label_text)
        let size = @sf.node_sp(held, look.size)
        let fig_cache : Map[String, Double] = Map([])
        let mark_cache : Map[String, Double] = Map([])
        let fig_w = fn(s : String) {
          if s == "" {
            0.0
          } else {
            match fig_cache.get(s) {
              Some(w) => w
              None => {
                let w = @sf.node_words_w(s, size, weight=look.weight)
                fig_cache[s] = w
                w
              }
            }
          }
        }
        let mark_w = fn(s : String) {
          if s == "" {
            0.0
          } else {
            match mark_cache.get(s) {
              Some(w) => w
              None => {
                let w = @sf.node_words_w(s, size, weight=label_look.weight)
                mark_cache[s] = w
                w
              }
            }
          }
        }
        let side = @ui.Space::S2.px()
        let mut used = 0.0
        for i, w in windows() {
          let (mark, words) = quota_worded(Some(w), form)
          let refill = quota_is_refill(Some(w))
          let chip_w = if refill {
            2.0 * side + (if mark == "" { 0.0 } else { mark_w(mark) + 4.0 }) + 10.5 + 4.0 + fig_w(words)
          } else {
            let between = if mark == "" { 0.0 } else { @ui.Space::S1_25.px() }
            2.0 * side + mark_w(mark) + between + fig_w(words)
          }
          used = used + (if i > 0 { gap } else { 0.0 }) + chip_w
        }
        used
      }
      let wide1_sig = @signals.computed(fn(_) {
        let _ = @sf.theme()
        let _ = held.words_scale()
        wide(1)
      })
      let wide2_sig = @signals.computed(fn(_) {
        let _ = @sf.theme()
        let _ = held.words_scale()
        wide(2)
      })
      let form_sig = @signals.computed(fn(_) {
        if wide1_sig.get() <= avail_w() + 0.01 {
          1
        } else {
          2
        }
      })
      let form = fn() { form_sig.get() }
      let lined_sig = @signals.computed(fn(_) { pooled() && !(wide2_sig.get() <= avail_w() + 0.01) })
      let lined = fn() { lined_sig.get() }
      let label_w_sig = @signals.computed(fn(_) {
        let _ = @sf.theme()
        let _ = held.words_scale()
        nav_quota_label_w(held, parts())
      })
      let label_w = fn() { label_w_sig.get() }
      // (where its windows come in pools, on one line where their marks fit it, else on its lines, each pool's under its
      // group's name: only the active branch is mounted)
      held.pick(at_once=true, lined, fn(r, is_lined) {
        if is_lined {
          r
          .row(Is(false))
          .lines_up(Is(Some(Start)))
          .gap(Is(@ui.Space::S1_5.px()))
          .wraps(Is(None))
          |> ignore
          r.each(fn() { Array::makei(parts().length(), fn(k) { k }) }, fn(k) { k }, fn(c, k) {
            // (a pool's line: its name in a column as wide as the widest pool's, its short capsules beside it)
            let k = k.untracked()
            c.width_share(Is(1.0)) |> ignore
            @sf.style_node(c, fn() { quota_chips_part })
            c.gap(Is(gap)) |> ignore
            c.show(fn() { part(k).0 != "" }, fn(l) {
              l.width(By(fn() { Some(label_w()) })).shrink(Is(0.0)) |> ignore
              @sf.words_node(l, fn() { part(k).0 }, fn() { nav_quota_group }) |> ignore
            })
            c.box(fn(cs) {
              @sf.style_node(cs, fn() { quota_chips_row })
              cs.gap(Is(gap)).grow(Is(1.0)).min_width(Is(Some(0.0))).wraps(Is(Some(quota_chips_part_lines))) |> ignore
              let ws = fn() { part(k).1 }
              cs.each(fn() { Array::makei(ws().length(), fn(j) { j }) }, fn(j) { j }, fn(d, j) {
                let j = j.untracked()
                let w = fn() { ws().get(j) }
                @sf.fill_chip_node(
                  d,
                  fn() { @sf.chip_left(w()) },
                  fn() { @sf.chip_str(w(), "level") },
                  fn() { quota_line_mark(part(k).0, w()) },
                  fn() { quota_figure(w()) },
                  label_muted=true,
                  refill=fn() { quota_is_refill(w()) },
                  said=fn() { quota_said(w()) },
                  tips?,
                )
                |> ignore
              })
            })
            |> ignore
          })
        } else {
          r
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .gap(Is(gap))
          .wraps(Is(Some(gap)))
          |> ignore
          r.each(fn() { Array::makei(windows().length(), fn(i) { i }) }, fn(i) { i }, fn(c, i) {
            // (a window as a chip of the line, by its name where the line has the room, else by its mark)
            let i = i.untracked()
            let w = fn() { windows().get(i) }
            @sf.fill_chip_node(
              c,
              fn() { @sf.chip_left(w()) },
              fn() { @sf.chip_str(w(), "level") },
              fn() { quota_worded(w(), form()).0 },
              fn() { quota_figure(w()) },
              label_muted=true,
              refill=fn() { quota_is_refill(w()) },
              said=fn() { quota_said(w()) },
              tips?,
            )
            |> ignore
          })
        }
      })
    }
    match room_w {
      Some(rw) => build(x, rw)
      None => x.by_room(loc~, fn(held, given) { build(held, fn() { given.width() }) }) |> ignore
    }
  })
}

///|
/// A window's mark on its line of an allowance's lines (quota_chips_lines'): within its pool, less the pool's name
/// (`5h`, `W`); a single model's by its mark (`Fable`); the account's own by its name (`每周`).
fn quota_line_mark(group : String, w : Json?) -> String {
  if group != "" {
    quota_part_mark(group, w)
  } else {
    quota_worded(w, if @sf.chip_str(w, "scope") != "" { 2 } else { 1 }).0
  }
}

///|
/// The room an allowance's chips need on one line of a sidebar's row (nav_quota_line's, in node `v`'s tree: its words at
/// the system's size there), as nav_quota_chips_node lays them out: a pool's group's column and its short chips where
/// the windows come in groups, the widest of those; else every chip; 0 where it shows none.
pub fn nav_quota_line_node(v : @view.View, q : Json?) -> Double {
  guard has_quota(q) else { return 0.0 }
  let windows = match @sf.chip_field(q, "windows") {
    Some(Array(a)) => a
    _ => []
  }
  let chip = nav_quota_chip_w(v)
  let parts = quota_parts(windows)
  let label_w = nav_quota_label_w(v, parts)
  if label_w > 0.0 {
    return parts.fold(init=0.0, fn(most, p) {
      let mut sum = if p.0 == "" { 0.0 } else { label_w + @ui.Space::S1_5.px() }
      for i, w in p.1 {
        sum += chip(quota_part_mark(p.0, Some(w)), quota_figure(Some(w)), quota_is_refill(Some(w))) +
          (if i > 0 { @ui.Space::S1.px() } else { 0.0 })
      }
      @sf.dmax(most, sum)
    })
  }
  let mut sum = 0.0
  for i, w in windows {
    sum += chip(quota_mark(Some(w)), quota_figure(Some(w)), quota_is_refill(Some(w))) +
      (if i > 0 { @ui.Space::S1.px() } else { 0.0 })
  }
  sum
}

///|
/// Shared per-text-environment cache for quota chip and pool label measurements across all calls to
/// `nav_quota_room_node` / `nav_quota_line_node` / `nav_quota_label_w`, so opening Profiles with dozens of accounts
/// measures each distinct mark/figure/label once instead of re-measuring per account.
/// Invalidated whenever font scale, `words_redone` (tracks font family/metrics/DPR reloads), tabular-numerals toggle,
/// target pixel size, or UI language (`@sf.language()`) changes, and cleared on `@ui.on_reset`.
priv struct QuotaMeasCache {
  mut chip_env : (Double, Int, Bool, Double, String)
  mut label_env : (Double, Int, Bool, Double, String)
  fig : Map[String, Double]
  mark : Map[String, Double]
  refill_mark : Map[String, Double]
  label : Map[String, Double]
  mut hits : Int
  mut misses : Int
}

///|
// kept across runs: cleared on reset via init and automatically invalidated when text scale/font/tabular/language changes
let quota_meas_cache : QuotaMeasCache = {
  chip_env: (0.0, -1, false, 0.0, ""),
  label_env: (0.0, -1, false, 0.0, ""),
  fig: Map([]),
  mark: Map([]),
  refill_mark: Map([]),
  label: Map([]),
  hits: 0,
  misses: 0,
}

///|
fn init {
  @ui.on_reset(fn() {
    quota_meas_cache.chip_env = (0.0, -1, false, 0.0, "")
    quota_meas_cache.label_env = (0.0, -1, false, 0.0, "")
    quota_meas_cache.fig.clear()
    quota_meas_cache.mark.clear()
    quota_meas_cache.refill_mark.clear()
    quota_meas_cache.label.clear()
    quota_meas_cache.hits = 0
    quota_meas_cache.misses = 0
  })
}

///|
/// Return `(hits, misses)` of `quota_meas_cache` in the current run (for budget/regression tests).
pub fn quota_meas_cache_stats() -> (Int, Int) {
  (quota_meas_cache.hits, quota_meas_cache.misses)
}

///|
fn quota_meas_sync_chip(v : @view.View, size : Double) -> Unit {
  let next = (v.words_scale(), v.words_redone(), @ui.tree_theme().tabular, size, @sf.language())
  if quota_meas_cache.chip_env != next {
    quota_meas_cache.chip_env = next
    quota_meas_cache.fig.clear()
    quota_meas_cache.mark.clear()
    quota_meas_cache.refill_mark.clear()
  }
}

///|
fn quota_meas_sync_label(v : @view.View, size : Double) -> Unit {
  let next = (v.words_scale(), v.words_redone(), @ui.tree_theme().tabular, size, @sf.language())
  if quota_meas_cache.label_env != next {
    quota_meas_cache.label_env = next
    quota_meas_cache.label.clear()
  }
}

///|
/// How wide a small chip of `mark` and `words` is in node `v`'s tree (fill_chip_node's: its words' room and theirs, its
/// mark and figure 5 apart normally or separated by the refresh icon when spent).
fn nav_quota_chip_w(v : @view.View) -> (String, String, Bool) -> Double {
  let look = @ui.style_words(@sf.chip_text)
  let label_look = @ui.style_words(@sf.chip_label_text)
  let refill_label_look = @ui.style_words(@sf.chip_refill_label_text)
  let size = @sf.node_sp(v, look.size)
  quota_meas_sync_chip(v, size)
  let fig_cache = quota_meas_cache.fig
  let mark_cache = quota_meas_cache.mark
  let refill_mark_cache = quota_meas_cache.refill_mark
  let fig_w = fn(s : String) {
    if s == "" {
      0.0
    } else {
      match fig_cache.get(s) {
        Some(w) => {
          quota_meas_cache.hits += 1
          w
        }
        None => {
          quota_meas_cache.misses += 1
          let w = @sf.node_words_w(s, size, weight=look.weight)
          if fig_cache.length() >= 256 {
            fig_cache.clear()
          }
          fig_cache[s] = w
          w
        }
      }
    }
  }
  let mark_w = fn(s : String) {
    if s == "" {
      0.0
    } else {
      match mark_cache.get(s) {
        Some(w) => {
          quota_meas_cache.hits += 1
          w
        }
        None => {
          quota_meas_cache.misses += 1
          let w = @sf.node_words_w(s, size, weight=label_look.weight)
          if mark_cache.length() >= 256 {
            mark_cache.clear()
          }
          mark_cache[s] = w
          w
        }
      }
    }
  }
  let refill_mark_w = fn(s : String) {
    if s == "" {
      0.0
    } else {
      match refill_mark_cache.get(s) {
        Some(w) => {
          quota_meas_cache.hits += 1
          w
        }
        None => {
          quota_meas_cache.misses += 1
          let w = @sf.node_words_w(s, size, weight=refill_label_look.weight)
          if refill_mark_cache.length() >= 256 {
            refill_mark_cache.clear()
          }
          refill_mark_cache[s] = w
          w
        }
      }
    }
  }
  fn(mark, words, refill) {
    let side = @ui.Space::S1_25.px()
    let gap = @ui.Space::S1.px()
    let w = if refill {
      2.0 * side + (if mark == "" { 0.0 } else { refill_mark_w(mark) + gap }) + 9.0 + gap + fig_w(words)
    } else {
      let between = if mark == "" || @sf.chip_joined(mark, words) { 0.0 } else { @ui.Space::S1_25.px() }
      2.0 * side + mark_w(mark) + between + fig_w(words)
    }
    w.ceil()
  }
}

///|
/// How wide each of an allowance's chips is (`q`'s windows, every one a marked capsule) in node `v`'s tree, and the room
/// all of it needs on one line (nav_quota_line_node): what a sidebar's rows of a provider are laid out by
/// (nav_quota_chips_node's `widest`).
pub fn nav_quota_room_node(v : @view.View, q : Json?) -> (Double, Array[Double]) {
  guard has_quota(q) else { return (0.0, []) }
  let windows = match @sf.chip_field(q, "windows") {
    Some(Array(a)) => a
    _ => []
  }
  let chip = nav_quota_chip_w(v)
  let parts = quota_parts(windows)
  let label_w = nav_quota_label_w(v, parts)
  let widths = windows.map(fn(w) { chip(quota_mark(Some(w)), quota_figure(Some(w)), quota_is_refill(Some(w))) })
  let line_w = if label_w > 0.0 {
    parts.fold(init=0.0, fn(most, p) {
      let mut sum = if p.0 == "" { 0.0 } else { label_w + @ui.Space::S1_5.px() }
      for i, w in p.1 {
        sum += chip(quota_part_mark(p.0, Some(w)), quota_figure(Some(w)), quota_is_refill(Some(w))) +
          (if i > 0 { @ui.Space::S1.px() } else { 0.0 })
      }
      @sf.dmax(most, sum)
    })
  } else {
    let mut sum = 0.0
    for i, cw in widths {
      sum += cw + (if i > 0 { @ui.Space::S1.px() } else { 0.0 })
    }
    sum
  }
  (line_w, widths)
}

///|
/// How many lines chips `widths` wide take on lines `room` wide, each as many as its line holds, 4 apart: 1 for none.
fn nav_quota_lines(widths : Array[Double], room : Double) -> Int {
  let gap = @ui.Space::S1.px()
  let mut lines = 1
  let mut used = 0.0
  for cw in widths {
    if used > 0.0 && used + gap + cw > room + 0.01 {
      lines = lines + 1
      used = cw
    } else {
      used = used + (if used > 0.0 { gap } else { 0.0 }) + cw
    }
  }
  lines
}

///|
/// How wide the widest of `parts`' group names is in node `v`'s tree (nav_quota_group's words): 0 where none has one.
fn nav_quota_label_w(v : @view.View, parts : Array[(String, Array[Json])]) -> Double {
  let mut has_any = false
  for p in parts {
    if p.0 != "" {
      has_any = true
      break
    }
  }
  if !has_any {
    return 0.0
  }
  let look = @ui.style_words(nav_quota_group)
  let size = @sf.node_sp(v, look.size)
  quota_meas_sync_label(v, size)
  let cache = quota_meas_cache.label
  parts.fold(init=0.0, fn(m, p) {
    if p.0 == "" {
      m
    } else {
      let w = match cache.get(p.0) {
        Some(cached) => {
          quota_meas_cache.hits += 1
          cached
        }
        None => {
          quota_meas_cache.misses += 1
          let measured = @sf.node_words_w(p.0, size, weight=look.weight).ceil()
          if cache.length() >= 128 {
            cache.clear()
          }
          cache[p.0] = measured
          measured
        }
      }
      @sf.dmax(m, w)
    }
  })
}

///|
/// An allowance's chips across a sidebar's row (nav_quota_chips', as a node) in `parent`, `q` as the core says it now:
/// from under the row's mark, every window a marked capsule, all on one line where the room the widest of its
/// provider's rows needs fits (`widest`: that row's nav_quota_room_node, the one whose line is the longest), the same
/// for every row of a provider; else on as many lines as that widest one takes, every row of the provider (the user,
/// 2026-11-13: 「相同供应商的账号用同一种就行」), each line of a row as many of its chips as share them out, a pool's
/// group's name over its chips. Where its windows come
/// in pools, one line has the group's name in a column of its own, its short capsules beside it, a pool a line. Its
/// last capsules as far in from the row's foot corner as makes them concentric with it (the row's `foot_capsule`).
/// Each says what is left of it and when it fills again over it while it is pointed at, in `tips`. `at`: where its
/// row's list stands (its words' room: band_pad_in). Nothing while the core cannot say or there is no window.
#callsite(autofill(loc))
pub fn nav_quota_chips_node(
  parent : @view.View,
  q : () -> Json?,
  at : @sf.ListAt,
  widest : () -> (Double, Array[Double]),
  tips? : @sf.TipLayer,
  room_w? : () -> Double,
  loc~ : SourceLoc,
) -> Unit {
  let inset = @ui.capsule_in(@sf.row_corner, @sf.fill_chip_small_h)
  let side = @sf.band_pad_in(at)
  // (a capsule reaches the corner until it is past the outer corner's circle-equivalent radius)
  let clear = @sf.dmax(0.0, inset + @sf.fill_chip_small_h / 2.0 - side)
  let pad_y = fn() { @sf.dmax(0.0, (@sf.theme().chat_list.meta_h - @sf.fill_chip_small_h) / 2.0) }
  // (the chips of `ws()`, each the window at its place there, its mark less its pool's name `group()`)
  let chips = fn(r : @view.View, ws : () -> Array[Json], group : () -> String) {
    r.each(fn() { Array::makei(ws().length(), fn(i) { i }) }, fn(i) { i }, fn(c, i) {
      let k = i.untracked()
      // (its window as it is now, told on only as it comes out otherwise: another's changing runs none of this one's)
      let held = @signals.computed(fn(_) { ws().get(k) })
      let w = fn() { held.get() }
      @sf.fill_chip_node(
        c,
        fn() { @sf.chip_left(w()) },
        fn() { @sf.chip_str(w(), "level") },
        fn() { quota_part_mark(group(), w()) },
        fn() { quota_figure(w()) },
        small=true,
        label_muted=true,
        refill=fn() { quota_is_refill(w()) },
        said=fn() { quota_said(w()) },
        tips?,
      )
      |> ignore
    })
  }
  parent.show(fn() { has_quota(q()) }, fn(x) {
    let windows_sig = @signals.computed(fn(_) {
      match @sf.chip_field(q(), "windows") {
        Some(Array(a)) => a
        _ => []
      }
    })
    let windows = fn() { windows_sig.get() }
    let parts_sig = @signals.computed(fn(_) { quota_parts(windows()) })
    let parts = fn() { parts_sig.get() }
    // (the pool at `k` of them as it is now)
    let part = fn(k : Int) { parts().get(k).unwrap_or(("", [])) }
    let part_keys = fn() { Array::makei(parts().length(), fn(k) { k }) }
    // (all of what its line leaves it: the room it is fitted to)
    x.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    let build = fn(held : @view.View, avail_w : () -> Double) {
      // (on one line where the room the widest of its provider's rows needs fits beside the corner's: else on lines)
      let room = fn() { avail_w() - (inset - side) - clear }
      let line_w_sig = @signals.computed(fn(_) {
        let _ = @sf.theme()
        let _ = held.words_scale()
        nav_quota_line_node(held, q())
      })
      let one_sig = @signals.computed(fn(_) {
        let r = room() + 0.01
        widest().0 <= r && line_w_sig.get() <= r
      })
      let one = fn() { one_sig.get() }
      // (on lines: as many as the widest of its provider's take, each of this row's as many of its chips as share them)
      let per_sig = @signals.computed(fn(_) {
        let n = windows().length()
        if one() {
          n
        } else {
          let lines = nav_quota_lines(widest().1, room())
          @sf.dmax(1.0, (n.to_double() / lines.to_double()).ceil()).to_int()
        }
      })
      let per = fn() { per_sig.get() }
      let label_w_sig = @signals.computed(fn(_) {
        let _ = @sf.theme()
        let _ = held.words_scale()
        nav_quota_label_w(held, parts())
      })
      let label_w = fn() { label_w_sig.get() }
      held.pick(at_once=true, fn() { label_w() > 0.0 }, fn(b, pooled) {
        b.width_share(Is(1.0)) |> ignore
        if pooled {
          b.pick(at_once=true, one, fn(a, single) {
            if single {
              // one line a pool, its name in a column of its own, its short capsules beside it
              a
              .width_share(Is(1.0))
              .margin(By(fn() { (inset - side, pad_y(), 0.0, pad_y()) }))
              .padding(Is((0.0, 0.0, clear, 0.0)))
              .gap(Is(@ui.Space::px(S1)))
              |> ignore
              a.each(part_keys, fn(k) { k }, fn(p, k) {
                let k = k.untracked()
                p.row(Is(true)).width_share(Is(1.0)).lines_up(Is(Some(Middle))).gap(Is(@ui.Space::px(S1_5))) |> ignore
                p.show(fn() { part(k).0 != "" }, fn(l) {
                  l.width(By(fn() { Some(label_w()) })) |> ignore
                  @sf.words_node(l, fn() { part(k).0 }, fn() { nav_quota_group }) |> ignore
                })
                p.box(fn(r) {
                  @sf.style_node(r, fn() { quota_chips_row.then(@ui.style(gap=S1)) }, in_row=true)
                  chips(r, fn() { part(k).1 }, fn() { part(k).0 })
                })
                |> ignore
              })
            } else {
              // on lines: a pool's name over its capsules, each pool's on as many lines as they take
              a
              .width_share(Is(1.0))
              .margin(By(fn() { (inset - side, pad_y(), clear, pad_y()) }))
              .gap(Is(@ui.Space::px(S1)))
              |> ignore
              a.each(part_keys, fn(k) { k }, fn(p, k) {
                let k = k.untracked()
                p.width_share(Is(1.0)).gap(Is(@ui.Space::px(S0_5))) |> ignore
                p.show(fn() { part(k).0 != "" }, fn(n) {
                  @sf.words_node(n, fn() { part(k).0 }, fn() { nav_quota_group }) |> ignore
                })
                p.box(fn(r) {
                  @sf.style_node(r, fn() { quota_chips_part.then(@ui.style(gap=S1)) })
                  r.wraps(Is(Some(@ui.Space::S1.px()))) |> ignore
                  chips(r, fn() { part(k).1 }, fn() { part(k).0 })
                })
                |> ignore
              })
            }
          })
        } else {
          // every window a marked capsule, on one line where it has the room, else on as many as per() says
          b
          .margin(By(fn() { (inset - side, if one() { 0.0 } else { pad_y() }, clear, if one() { 0.0 } else { pad_y() }) }))
          .gap(Is(@ui.Space::px(S1)))
          |> ignore
          b.each(fn() { Array::makei((windows().length() + per() - 1) / @sf.dmax(1.0, per().to_double()).to_int(), fn(i) { i }) }, fn(i) { i }, at_once=true, fn(r, i) {
            let i = i.untracked()
            @sf.style_node(r, fn() { quota_chips_part.then(@ui.style(gap=S1)) })
            chips(r, fn() { windows().iter().drop(i * per()).take(per()).collect() }, fn() { "" })
          })
        }
      })
    }
    match room_w {
      Some(rw) => build(x, rw)
      None => x.by_room(loc~, fn(held, given) { build(held, fn() { given.width() }) }) |> ignore
    }
  })
}

///|
/// Dynamic per-provider-group column layout for `quota_compact_node`:
/// - `columns` / `col_widths`: canonical column order (`5h`, `W`, `M`, then remaining marks in first-seen
///   order) and measured max slot widths across all non-pooled accounts in the group.
/// - `pool_label_w`: measured max pool-name width (`Gemini`, `Claude / GPT`, ...) across all pooled
///   accounts in the group so single-pool and multi-pool sibling accounts align vertically.
/// - `pool_columns` / `pool_col_widths`: canonical column order and measured max slot widths across all
///   pooled windows in the group.
#derive(Eq)
pub struct QuotaCompactGroup {
  columns : Array[String]
  col_widths : Array[Double]
  pool_label_w : Double
  pool_columns : Array[String]
  pool_col_widths : Array[Double]
}

///|
/// Empty group layout (used as default when no row is bound yet).
pub fn QuotaCompactGroup::empty() -> QuotaCompactGroup {
  { columns: [], col_widths: [], pool_label_w: 0.0, pool_columns: [], pool_col_widths: [] }
}

///|
/// Canonical column order (`5h`, `W`, `M`, then remaining marks in first-seen order).
fn quota_compact_order(seen : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for fixed in ["5h", "W", "M"] {
    if seen.contains(fixed) {
      out.push(fixed)
    }
  }
  for mk in seen {
    if !out.contains(mk) {
      out.push(mk)
    }
  }
  out
}

///|
/// Normalize ASCII digits to `'8'` when measuring tabular figures: matches `tabular=true` advance width
/// and guarantees 0 fanout when normal percentage/countdown values refresh (`76% -> 71%`, `4h21m -> 4h19m`).
fn quota_compact_tabular_sample(s : String) -> String {
  let buf = StringBuilder()
  for c in s {
    if c >= '0' && c <= '9' {
      buf.write_char('8')
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
/// Measure a provider group's compact quota column layout in node `v`'s tree, reactive to theme,
/// `words_scale()`, and language (`W -> 周`, `M -> 月` in Chinese). Reuses `nav_quota_chip_w(v)` so
/// every `@sf.fill_chip_node(small=true)` micro-capsule fits its group-shared column width with 0
/// reflow on normal percentage/countdown refreshes (digits normalized to `'8'`).
pub fn quota_compact_group(v : @view.View, quotas : Array[Json?]) -> QuotaCompactGroup {
  let _ = @sf.theme()
  let _ = v.words_scale()
  let _ = @sf.language()
  let chip = nav_quota_chip_w(v)
  let slot_w = fn(mark : String, w : Json?) -> Double {
    let shown = quota_compact_mark_text(mark)
    let fig = quota_compact_tabular_sample(quota_figure(w))
    chip(shown, fig, quota_is_refill(w)) + 1.0
  }
  let non_pool_seen : Array[String] = []
  let pool_seen : Array[String] = []
  let mut pool_label_w = 0.0
  let entries : Array[(Bool, Array[Json], Array[(String, Array[Json])])] = []
  for q in quotas {
    if !has_quota(q) {
      continue
    }
    let ws = match @sf.chip_field(q, "windows") {
      Some(Array(a)) => a
      _ => []
    }
    let parts = quota_parts(ws)
    let is_pooled = parts.iter().any(fn(p) { p.0 != "" })
    entries.push((is_pooled, ws, parts))
    if is_pooled {
      pool_label_w = @sf.dmax(pool_label_w, nav_quota_label_w(v, parts))
      for p in parts {
        for w in p.1 {
          let mk = quota_part_mark(p.0, Some(w))
          if mk != "" && !pool_seen.contains(mk) {
            pool_seen.push(mk)
          }
        }
      }
    } else {
      for w in ws {
        let mk = quota_mark(Some(w))
        if mk != "" && !non_pool_seen.contains(mk) {
          non_pool_seen.push(mk)
        }
      }
    }
  }
  let columns = quota_compact_order(non_pool_seen)
  let pool_columns = quota_compact_order(pool_seen)
  let col_widths = Array::make(columns.length(), 0.0)
  let pool_col_widths = Array::make(pool_columns.length(), 0.0)
  for entry in entries {
    let (is_pooled, ws, parts) = entry
    if is_pooled {
      for p in parts {
        for w in p.1 {
          let mk = quota_part_mark(p.0, Some(w))
          match pool_columns.search(mk) {
            Some(idx) => pool_col_widths[idx] = @sf.dmax(pool_col_widths[idx], slot_w(mk, Some(w)))
            None => ()
          }
        }
      }
    } else {
      for w in ws {
        let mk = quota_mark(Some(w))
        match columns.search(mk) {
          Some(idx) => col_widths[idx] = @sf.dmax(col_widths[idx], slot_w(mk, Some(w)))
          None => ()
        }
      }
    }
  }
  { columns, col_widths, pool_label_w, pool_columns, pool_col_widths }
}

///|
/// Align quota windows to a provider group's canonical `columns` order: missing leading or intermediate
/// columns become `None` placeholders; trailing empty columns after the row's last present window are
/// trimmed so narrow screens do not wrap unnecessarily; any window whose mark is not in `columns` is
/// appended at the end.
fn quota_compact_aligned(
  windows : Array[Json],
  columns : Array[String],
  mark_of : (Json?) -> String,
) -> Array[(String, Json?)] {
  if columns.length() == 0 {
    return windows.map(fn(w) { (mark_of(Some(w)), Some(w)) })
  }
  let used = Array::make(windows.length(), false)
  let out : Array[(String, Json?)] = []
  for col in columns {
    let mut found : Json? = None
    for i, w in windows {
      if !used[i] && mark_of(Some(w)) == col {
        used[i] = true
        found = Some(w)
        break
      }
    }
    out.push((col, found))
  }
  for i, w in windows {
    if !used[i] {
      out.push((mark_of(Some(w)), Some(w)))
    }
  }
  let mut last = out.length()
  while last > 0 && out[last - 1].1 is None {
    last -= 1
  }
  if last < out.length() {
    out.truncate(last)
  }
  out
}

///|
/// Compact dynamically-measured equal-width micro-capsule quota readout for high-density account rows
/// (`profiles_list.mbt`):
/// - Each slot reuses `@sf.fill_chip_node(small=true)` (16pt ultra-compact height, concentric radius,
///   proportional progress fill bar in grey/amber/red or soft-red refill countdown, full `says()` & tip).
/// - Column widths are measured per provider group (`QuotaCompactGroup` via `quota_compact_group` using
///   `nav_quota_chip_w`) with ASCII digits normalized to `'8'` so micro-capsules align pixel-for-pixel
///   across rows while normal percentage/countdown refreshes cause zero group-wide reflow; short marks
///   localize `W -> 周` and `M -> 月` in Chinese while keeping `W` / `M` in English.
/// - Regular 1–3 windows (e.g. `5h`, `周`/`W`, `月`/`M`, single-model `Fable`/`Sonnet`): single horizontal
///   row (`gap=S1_5`, graceful `wraps(2.0)` only at extreme narrow widths + 1.3x font scale); rows missing
///   a leading window render an equal-width empty placeholder box so later columns stay vertically aligned.
/// - Multi-window model pools (e.g. Antigravity `Gemini` / `Claude / GPT` via `quota_parts`): one compact
///   row per pool (`gap=S1` between rows, `gap=S2` after the group-shared pool-name column `pool_label_w`)
///   with group-measured `pool_columns` / `pool_col_widths` on the right.
#callsite(autofill(loc))
pub fn quota_compact_node(
  parent : @view.View,
  q : () -> Json?,
  group? : () -> QuotaCompactGroup,
  at_foot? : () -> Bool = fn() { true },
  tips? : @sf.TipLayer,
  loc~ : SourceLoc,
) -> Unit {
  parent.show(at_once=true, loc~, fn() { has_quota(q()) }, fn(x) {
    let windows_sig = @signals.computed(fn(_) {
      match @sf.chip_field(q(), "windows") {
        Some(Array(a)) => a
        _ => []
      }
    })
    let windows = fn() { windows_sig.get() }
    let parts_sig = @signals.computed(fn(_) { quota_parts(windows()) })
    let parts = fn() { parts_sig.get() }
    let pooled_sig = @signals.computed(fn(_) { parts().iter().any(fn(p) { p.0 != "" }) })
    let pooled = fn() { pooled_sig.get() }
    let part = fn(k : Int) { parts().get(k).unwrap_or(("", [])) }
    let grp_sig = @signals.computed(
      fn(_) {
        match group {
          Some(g) => g()
          None => quota_compact_group(x, [q()])
        }
      },
      same=fn(a, b) { a == b },
    )
    let grp = fn() { grp_sig.get() }
    x.width_share(Is(1.0)) |> ignore
    x.pick(at_once=true, pooled, fn(r, is_pooled) {
      if is_pooled {
        @sf.style_node(r, fn() { quota_compact_pools })
        let label_w = fn() {
          let g = grp().pool_label_w
          if g > 0.0 { g } else { nav_quota_label_w(r, parts()) }
        }
        r.each(fn() { Array::makei(parts().length(), fn(k) { k }) }, fn(k) { k }, fn(c, k) {
          let k = k.untracked()
          @sf.style_node(c, fn() { quota_compact_pool_row })
          c.show(at_once=true, fn() { part(k).0 != "" }, fn(l) {
            l.min_width(By(fn() { Some(label_w()) })).shrink(Is(0.0)) |> ignore
            @sf.words_node(l, fn() { part(k).0 }, fn() { nav_quota_group }) |> ignore
          })
          c.box(fn(cs) {
            @sf.style_node(cs, fn() { quota_compact_row })
            cs.grow(Is(1.0)).min_width(Is(Some(0.0))).wraps(Is(Some(2.0))) |> ignore
            let aligned_sig = @signals.computed(fn(_) {
              let p = part(k)
              quota_compact_aligned(p.1, grp().pool_columns, fn(w) { quota_part_mark(p.0, w) })
            })
            let aligned = fn() { aligned_sig.get() }
            cs.each(fn() { Array::makei(aligned().length(), fn(j) { j }) }, fn(j) { j }, fn(d, j) {
              let j = j.untracked()
              let slot = fn() { aligned().get(j) }
              let col_w = fn() { grp().pool_col_widths.get(j).unwrap_or(0.0) }
              d.pick(at_once=true, fn() { slot().bind(fn(s) { s.1 }) is Some(_) }, fn(cell, has_w) {
                if has_w {
                  let held = @signals.computed(fn(_) { slot().bind(fn(s) { s.1 }) }, same=fn(a, b) { a == b })
                  let w = fn() { held.get() }
                  quota_compact_slot_node(cell, w, fn() { quota_part_mark(part(k).0, w()) }, col_w, tips?)
                } else {
                  cell.min_width(By(fn() { Some(col_w()) })).shrink(Is(0.0)) |> ignore
                }
              })
            })
          })
          |> ignore
        })
      } else {
        @sf.style_node(r, fn() { quota_compact_row })
        let side = @ui.Space::S3.px()
        let clear = @sf.dmax(0.0, @sf.row_corner - side)
        r
        .margin(By(fn() {
          let look = @ui.style_words(@sf.chip_text)
          let scale = r.words_scale()
          let line = if look.line < 0.0 { -look.line * @ui.sp_at(scale, look.size) } else { @ui.sp_at(scale, look.line) }
          let chip_h = @sf.dmax(@sf.fill_chip_small_h, line)
          let inset = @ui.capsule_in(@sf.row_corner, chip_h)
          let dx = inset - side
          let dy = if at_foot() && inset < @ui.Space::S2_5.px() { inset - @ui.Space::S2_5.px() } else { 0.0 }
          (dx, 0.0, 0.0, dy)
        }))
        .padding(Is((0.0, 0.0, clear, 0.0)))
        .wraps(Is(Some(2.0)))
        |> ignore
        let aligned_sig = @signals.computed(fn(_) {
          quota_compact_aligned(windows(), grp().columns, quota_mark)
        })
        let aligned = fn() { aligned_sig.get() }
        r.each(fn() { Array::makei(aligned().length(), fn(i) { i }) }, fn(i) { i }, fn(c, i) {
          let i = i.untracked()
          let slot = fn() { aligned().get(i) }
          let col_w = fn() { grp().col_widths.get(i).unwrap_or(0.0) }
          c.pick(at_once=true, fn() { slot().bind(fn(s) { s.1 }) is Some(_) }, fn(cell, has_w) {
            if has_w {
              let held = @signals.computed(fn(_) { slot().bind(fn(s) { s.1 }) }, same=fn(a, b) { a == b })
              let w = fn() { held.get() }
              quota_compact_slot_node(cell, w, fn() { quota_mark(w()) }, col_w, tips?)
            } else {
              cell.min_width(By(fn() { Some(col_w()) })).shrink(Is(0.0)) |> ignore
            }
          })
        })
      }
    })
  })
}

///|
/// Localize compact window short marks (`W` -> `周`, `M` -> `月` in Chinese; keep `W`/`M` in English,
/// and keep `5h`, `7d`, model names, etc. unchanged).
fn quota_compact_mark_text(mark : String) -> String {
  if @sf.language() == "zh" {
    match mark {
      "W" => "周"
      "M" => "月"
      _ => mark
    }
  } else {
    mark
  }
}

///|
/// One equal-width ultra-compact quota micro-capsule (`@sf.fill_chip_node(small=true)`).
fn quota_compact_slot_node(
  s : @view.View,
  w : () -> Json?,
  mark : () -> String,
  min_w : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let shown_mark = fn() { quota_compact_mark_text(mark()) }
  let chip = @sf.fill_chip_node(
    s,
    fn() { @sf.chip_left(w()) },
    fn() { @sf.chip_str(w(), "level") },
    shown_mark,
    fn() { quota_figure(w()) },
    small=true,
    label_muted=true,
    refill=fn() { quota_is_refill(w()) },
    said=fn() { quota_said(w()) },
    tips?,
    tips_within=true,
  )
  chip
  .min_width(By(fn() { Some(min_w()) }))
  .shrink(Is(0.0))
  .says(By(fn() {
    match w() {
      Some(_) => Some(@view.said(Image, label=quota_said(w())))
      None => None
    }
  }))
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let quota_compact_row : @ui.Style = @ui.css("row w=Full gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let quota_compact_pools : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let quota_compact_pool_row : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
/// Whether `q`'s windows split into multiple lines in `quota_table_chips_node` (multi-pool allowances such as Google).
pub fn quota_is_pooled(q : Json?) -> Bool {
  guard has_quota(q) else { return false }
  let windows = match @sf.chip_field(q, "windows") {
    Some(Array(a)) => a
    _ => []
  }
  let parts = quota_parts(windows)
  parts.length() > 1 && parts.iter().any(fn(p) { p.0 != "" })
}

///|
/// Compact quota chips for table cells and narrow batch-manage rows: renders every window as a `small=true`
/// `fill_chip_node` (matching the sidebar's `nav_quota_chips_node`), wrapping cleanly when space is tight and
/// rendering multi-pool allowances (such as Google subscriptions) with aligned pool-name columns. Uses zero per-row
/// `by_room` passes.
pub fn quota_table_chips_node(
  parent : @view.View,
  q : () -> Json?,
  tips? : @sf.TipLayer,
) -> Unit {
  let chips = fn(r : @view.View, ws : () -> Array[Json], group : () -> String) {
    r.each(fn() { Array::makei(ws().length(), fn(i) { i }) }, fn(i) { i }, fn(c, i) {
      let k = i.untracked()
      let held = @signals.computed(fn(_) { ws().get(k) })
      let w = fn() { held.get() }
      @sf.fill_chip_node(
        c,
        fn() { @sf.chip_left(w()) },
        fn() { @sf.chip_str(w(), "level") },
        fn() { quota_part_mark(group(), w()) },
        fn() { quota_figure(w()) },
        small=true,
        label_muted=true,
        refill=fn() { quota_is_refill(w()) },
        said=fn() { quota_said(w()) },
        tips?,
      )
      |> ignore
    })
  }
  parent.show(at_once=true, fn() { has_quota(q()) }, fn(x) {
    let windows_sig = @signals.computed(fn(_) {
      match @sf.chip_field(q(), "windows") {
        Some(Array(a)) => a
        _ => []
      }
    })
    let windows = fn() { windows_sig.get() }
    let parts_sig = @signals.computed(fn(_) { quota_parts(windows()) })
    let parts = fn() { parts_sig.get() }
    let part = fn(k : Int) { parts().get(k).unwrap_or(("", [])) }
    let part_keys = fn() { Array::makei(parts().length(), fn(k) { k }) }
    let label_w_sig = @signals.computed(fn(_) {
      let _ = @sf.theme()
      let _ = x.words_scale()
      nav_quota_label_w(x, parts())
    })
    let label_w = fn() { label_w_sig.get() }
    x.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    x.pick(at_once=true, fn() { label_w() > 0.0 }, fn(b, pooled) {
      b.width_share(Is(1.0)) |> ignore
      if pooled {
        b.gap(Is(@ui.Space::S1.px())) |> ignore
        b.each(part_keys, fn(k) { k }, fn(p, k) {
          let k = k.untracked()
          p.row(Is(true)).width_share(Is(1.0)).lines_up(Is(Some(Middle))).gap(Is(@ui.Space::S1_5.px())) |> ignore
          p.show(at_once=true, fn() { part(k).0 != "" }, fn(l) {
            l.width(By(fn() { Some(label_w()) })).shrink(Is(0.0)) |> ignore
            @sf.words_node(l, fn() { part(k).0 }, fn() { nav_quota_group }) |> ignore
          })
          p.box(fn(r) {
            @sf.style_node(r, fn() { quota_chips_row.then(@ui.style(gap=S1)) }, in_row=true)
            r.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).wraps(Is(Some(@ui.Space::S1.px()))) |> ignore
            chips(r, fn() { part(k).1 }, fn() { part(k).0 })
          })
          |> ignore
        })
      } else {
        b.box(fn(r) {
          @sf.style_node(r, fn() { quota_chips_part.then(@ui.style(gap=S1)) })
          r.wraps(Is(Some(@ui.Space::S1.px()))) |> ignore
          chips(r, windows, fn() { "" })
        })
        |> ignore
      }
    })
  })
}
