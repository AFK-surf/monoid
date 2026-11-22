// Quota and meter chip nodes (moved from libs/sf-ui/src/quota_node.mbt).

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
      Some(rw) => x.box(made_for=loc, fn(held) { build(held, rw) }) |> ignore
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
/// How wide a small chip of `mark` and `words` is in node `v`'s tree (fill_chip_node's: its words' room and theirs, its
/// mark and figure 5 apart normally or separated by the refresh icon when spent).
fn nav_quota_chip_w(v : @view.View) -> (String, String, Bool) -> Double {
  let look = @ui.style_words(@sf.chip_text)
  let label_look = @ui.style_words(@sf.chip_label_text)
  let refill_label_look = @ui.style_words(@sf.chip_refill_label_text)
  let size = @sf.node_sp(v, look.size)
  let fig_cache : Map[String, Double] = Map([])
  let mark_cache : Map[String, Double] = Map([])
  let refill_mark_cache : Map[String, Double] = Map([])
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
  let refill_mark_w = fn(s : String) {
    if s == "" {
      0.0
    } else {
      match refill_mark_cache.get(s) {
        Some(w) => w
        None => {
          let w = @sf.node_words_w(s, size, weight=refill_label_look.weight)
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
  let look = @ui.style_words(nav_quota_group)
  let size = @sf.node_sp(v, look.size)
  parts.fold(init=0.0, fn(m, p) { if p.0 == "" { m } else { @sf.dmax(m, @sf.node_words_w(p.0, size, weight=look.weight).ceil()) } })
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
      let one_sig = @signals.computed(fn(_) { @sf.dmax(widest().0, line_w_sig.get()) <= room() + 0.01 })
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
      Some(rw) => x.box(made_for=loc, fn(held) { build(held, rw) }) |> ignore
      None => x.by_room(loc~, fn(held, given) { build(held, fn() { given.width() }) }) |> ignore
    }
  })
}
