// A row of a list in a sidebar as a node of the window's tree (nav_item's: a station's, a profile's, a device's), laid
// out as a chat's row is (list_row's): its mark beside its first line, its title with what stands at that line's end,
// the lines under them from the mark's edge, a last line across the row (an allowance's chips) in its foot corner; its
// ground as a sidebar row's (nav_ground_node). Its looks the theme's chats' list's as they are now.

///|
/// A row of a list in a sidebar (nav_item's) in `parent`, where its list stands (`at`): `mark` beside its first line,
/// `title` on that line (nav_title_node) with `end` at its end (never cut: the title gives way), `lines` under them
/// (list_row_line_node each), their room kept for `keep_lines` of them whatever they say now (a station away keeps its
/// figures' room: every station's row as high); `foot` a last line across the row while `foot_on()`, `foot_capsule` the
/// height of the capsules on it, which stand as far in from the row's foot corner as makes them concentric with it. Its ground the
/// pointer's while it is pointed at, the selected one's while `on()`; the room of another under it while `more()`.
/// Pressed, `press` given the row (what it opens beside it); read out a button named `label()`.
#callsite(autofill(loc))
pub fn nav_item_node(
  parent : @view.View,
  at : ListAt,
  on : () -> Bool,
  label : () -> String,
  press : (@view.View) -> Unit,
  mark : (@view.View) -> Unit,
  title : (@view.View) -> Unit,
  end? : (@view.View) -> Unit,
  lines? : (@view.View) -> Unit,
  keep_lines? : Int = 0,
  more? : () -> Bool = fn() { false },
  foot? : (@view.View) -> Unit,
  foot_on? : () -> Bool = fn() { true },
  foot_capsule? : Double,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(o) {
    // (rows that keep room for lines under the title stand as cards: 6 apart, so two lit at once never read as one)
    style_node(o, fn() {
      if !more() {
        nav_item_last
      } else if keep_lines > 0 {
        nav_item_card_more
      } else {
        list_more(at)
      }
    })
    @headless.button(o, label, press, fn(r, _) {
      style_node(r, fn() {
        let l = theme().chat_list
        // (a capsule on its last line kept as far in from its foot corner as one of its height is from a corner)
        let item = match (at, foot_capsule) {
          (Side | Tape, Some(h)) if foot_on() => {
            let bottom = @ui.capsule_in(row_corner, h) - (l.meta_h - h) / 2.0
            l.item.then(@ui.style(pb=room(bottom)))
          }
          _ => l.item
        }
        item.then(list_row_in(at))
      })
      nav_ground_node(r, on)
      // (its mark beside its first line alone, the lines under them from the mark's edge, as its foot's capsules are:
      // one edge down the row, the user, 2026-11-10: 「第二行到底对哪里齐」)
      // (each as narrow as the row leaves it, its title cut short there, not past the row)
      let top = fn(t : @view.View) {
        style_node(t, fn() { theme().chat_list.text }, in_row=true)
        t.min_width(Is(Some(0.0))) |> ignore
        t.box(fn(m) {
          style_node(m, fn() { list_row_marked })
          m.min_width(Is(Some(0.0))) |> ignore
          m.box(fn(k) {
            style_node(k, fn() { list_row_mark }, in_row=true)
            // (as high as its first line: list_looks)
            k.height(By(fn() { Some(list_looks(k).head_h) })) |> ignore
            mark(k)
          })
          |> ignore
          m.box(fn(u) {
            style_node(u, fn() { list_row_under }, in_row=true)
            u.min_width(Is(Some(0.0))) |> ignore
            u.box(fn(h) {
              style_node(h, fn() { list_looks(h).head })
              h.min_width(Is(Some(0.0))) |> ignore
              title(h)
              match end {
                Some(e) =>
                  h.box(fn(x) {
                    style_node(x, fn() { nav_item_end_node }, in_row=true)
                    e(x)
                  })
                  |> ignore
                None => ()
              }
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        match lines {
          // (the room of `keep_lines` of them kept, whatever they say now)
          Some(f) if keep_lines > 0 =>
            t.box(fn(ls) {
              // (as far apart as the lines of its words' column: theme's chats' list's `text`)
              style_node(ls, fn() { theme().chat_list.text })
              ls.min_height(By(fn() {
                let gap = style_room(theme().chat_list.text.base.gap).unwrap_or(0.0)
                Some(keep_lines.to_double() * (list_looks(ls).meta_h + gap) - gap)
              }))
              |> ignore
              f(ls)
            })
            |> ignore
          // (none kept: only those it says, nothing in their place while it says none)
          Some(f) => f(t)
          None => ()
        }
      }
      match foot {
        None => r.box(top) |> ignore
        Some(f) =>
          r.box(fn(t) {
            style_node(t, fn() { theme().chat_list.text }, in_row=true)
            t.min_width(Is(Some(0.0))) |> ignore
            t.box(fn(tr) {
              style_node(tr, fn() { nav_item_top })
              tr.box(top) |> ignore
            })
            |> ignore
            // A foot may take more than one line when what it says cannot fit on one; a single line keeps the same
            // height and centring as the row's other lines. There while `foot_on()`, the row as it was round it.
            t.show(at_once=true, foot_on, fn(fb) {
              style_node(fb, fn() {
                let l = theme().chat_list
                l.meta.then(@ui.style(h=Hug, min_h=Fixed(l.meta_h)))
              })
              f(fb)
            })
          })
          |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// A row's title (nav_title's) in `parent`: a chat's title's look, as long as there is room (cut short where the row
/// has not); `away()`, what it names is not there now: muted. `after` right after it on its line while `after_shown()`
/// says (a tag: an account's plan), 8 apart across their middle, the first to leave the line where it has not the room
/// for both: the title is never cut short for it (the user, 2026-11-14: the plan cut the name short in the narrowest
/// sidebar; 2026-11-17: 「侧栏加回套餐，窄了先收起」).
#callsite(autofill(loc))
pub fn nav_title_node(
  parent : @view.View,
  words : () -> String,
  away? : () -> Bool = fn() { false },
  after? : (@view.View) -> Unit,
  after_shown? : () -> Bool = fn() { true },
  loc~ : SourceLoc,
) -> Unit {
  let look = fn() {
    let look = theme().chat_list.title.then(nav_cut)
    if away() {
      look.then(nav_title_away)
    } else {
      look
    }
  }
  parent.box(made_for=loc, fn(w) {
    w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    match after {
      None => words_node(w, words, look) |> ignore
      Some(a) => {
        w.row(Is(true)).lines_up(Is(Some(Middle))).fits(Is(true)) |> ignore
        // (the title kept whole while what follows may leave for it: cut short only once that has gone)
        w.box(fn(x) {
          x.shrink(Is(1.0)).min_width(Is(Some(0.0))).fit_whole(Is(true)) |> ignore
          words_node(x, words, look) |> ignore
        })
        |> ignore
        w.show(after_shown, fn(s) {
          s.margin(Is((8.0, 0.0, 0.0, 0.0))).drops(Is(1)) |> ignore
          a(s)
        })
      }
    }
  })
  |> ignore
}

///|
/// What a row says in a line under its title (nav_meta's) in `parent`: a chat's second line's look, cut short where the
/// line has not the room.
#callsite(autofill(loc))
pub fn nav_meta_node(parent : @view.View, words : () -> String, look? : () -> @ui.TextStyle, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(w) {
    w.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    words_node(w, words, fn() {
      let base = theme().chat_list.last.then(nav_cut)
      match look {
        Some(f) => base.then(f())
        None => base
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// The last row of a run: no room of another under it.
// kept across runs: a value (no field of it changes)
let nav_item_last : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
// (pb: S1_5, 6 under a card-high row with another under it)
let nav_item_card_more : @ui.Style = @ui.css("w=Full pb=S1_5")

///|
/// What stands at its first line's end, 5 apart, kept whole.
// kept across runs: a value (no field of it changes)
let nav_item_end_node : @ui.Style = @ui.css("row gap=S1_25 align=ACenter")

///|
/// Its first line and what is under it beside nothing, over its foot.
// kept across runs: a value (no field of it changes)
let nav_item_top : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")
