// A panel of the presenters' that goes in steps, what it holds nodes (panel_nodes' `steps`, panel_go_nodes), opened by
// nothing: one dialog in the middle of the window (dialog_layer_node, its frame panel_centred_node's) whose steps are
// pages of it, as a sheet's are on 小屏 (sheet_node: panel_page's `more`): the one that shows in its column, those
// before it off to its start, kept as they were left; a step in slides in from its end over the one before as that one
// slides off, the dialog going to the height of the one that shows, the window's middle with it; back (its back key,
// Escape, the system's back) slides it away again, the one before back in place as it was left. Each step its own head (its
// back key past the first, its title) under the close button over the dialog's corner, what it says under it, what it
// holds and its foot on the dialog's words' line, as a titled dialog's. A press outside and its close button close all
// of it.

///|
/// A centred panel `x` in `parent` that goes in steps (its pages: `x` itself, then `keyed`'s `more`), while `open()`;
/// `close`, `cancel`, `shown`, `gone`, `dims`, `covered` as panel_centred_node's.
fn steps_centred_node(
  parent : @view.View,
  open : () -> Bool,
  x : PanelOf,
  close : () -> Unit,
  cancel : () -> Unit,
  keyed : Presented,
  shown? : () -> Unit = fn() {  },
  gone? : () -> Unit = fn() {  },
  dims? : () -> Bool = fn() { true },
  covered? : () -> Bool = fn() { false },
) -> Unit {
  // (its pages, `n` each's: its own the first)
  let pages = fn() -> Array[(Int, PanelOf)] {
    let all = [(0, x)]
    for m in keyed.more.get() {
      all.push((m.n, m.x))
    }
    all
  }
  // (back: told to the flow its steps follow where they follow one (flow_back); a step back where it is past its first;
  // a step further in from another presenter's panel, back to that one)
  let back = fn() { flow_back(keyed) || panel_pop(keyed) || back_under(keyed) }
  dialog_layer_node(parent, open, cancel, outside=true, shown~, gone~, dims~, covered~, within=back, fn(across, layer, look, veil) {
    let w = fn() { dmin(if x.wide { dialog_wide_w } else { dialog_w }, over_room(layer).0 - dialog_margin) }
    let words_in = panel_words - dialog_pad
    // (in a column of its own in the window's middle: its height's way down that column, View::resizes)
    across.box(fn(column) {
      column.box(fn(d) {
        d
        .width(By(fn() { Some(w()) }))
        .max_height(By(fn() { Some(dmax(0.0, over_room(layer).1 - dialog_room)) }))
        .padding(Is((0.0, 0.0, 0.0, 0.0)))
        .radius(Is(dialog_r))
        .ground(By(fn() { panel_ground() }))
        .edge(By(fn() { (1.0, @ui.tree_theme().color(Line)) }))
        .shadow(By(fn() { (dialog_shadow, dialog_shadow_y, library_theme().p.shadow) }))
        .clips(Is(true))
        .alpha(By(fn() { look().alpha }))
        .scale(By(fn() { look().sx }))
        .offset(By(fn() { (look().dx, look().dy) }))
        // (read out by its own title: what its steps say is theirs)
        .says(Is(Some(@view.said(Dialog, label=x.title, description=x.description))))
        |> ground_node
        |> ignore
        // (another step put on or taken off: the dialog from as tall as it is now to as tall as the one that shows makes
        // it, one way down the column it stands in (View::resizes), the window's middle following it; said before the
        // step changes, while it is laid out as it was: steps_reshaping)
        steps_reshaping[keyed.serial] = fn() { d.resizes() |> ignore }
        d.owns(fn() { steps_reshaping.remove(keyed.serial) }) |> ignore
        // (each page's slide: where it is off to the dialog's side, in its widths (0 in place, -1 off to its start, 1 off
        // to its end), from where, to where, from when and how long, said as a page is put on or taken off; sheet_node's)
        let ways : Map[Int, @signals.Signal[(Double, Double, Double, Double)]] = Map([])
        let way_at = fn(wy : (Double, Double, Double, Double), t : Double) {
          wy.1 + @ui.move_path(wy.0 - wy.1, 0.0, t - wy.2, wy.3).0
        }
        // (each page off to a side once its slide there is over: laid out nowhere then, kept as it was left)
        let aways : Map[Int, @signals.Signal[Bool]] = Map([])
        let dues : Map[Int, () -> Unit] = Map([])
        let away_after = fn(n : Int, wy : (Double, Double, Double, Double)) {
          match dues.get(n) {
            Some(f) => f()
            None => ()
          }
          dues.remove(n)
          guard aways.get(n) is Some(a) else { return }
          a.set(false)
          if wy.1 != 0.0 {
            dues[n] = layer.at_moment(wy.2 + wy.3, fn() { a.set(true) })
          }
        }
        let made_with : Ref[Bool] = Ref(true)
        let top = fn() {
          let all = pages()
          all[all.length() - 1].0
        }
        let shown_was : Ref[Array[Int]] = Ref(@signals.untracked(fn() { pages().map(fn(pg) { pg.0 }) }))
        d.reacts(at_start=false, fn() { pages().map(fn(pg) { pg.0 }) }, fn(ids) {
          let was = shown_was.val
          shown_was.val = ids
          guard ids.length() > 0 && was.length() > 0 && ids[ids.length() - 1] != was[was.length() - 1] else { return }
          let at = d.cause_at()
          let dur = @ui.move_ms(w())
          let go = fn(n : Int, to : Double) {
            match ways.get(n) {
              Some(wy) => {
                wy.set((way_at(wy.untracked(), at), to, at, dur))
                away_after(n, wy.untracked())
              }
              None => ()
            }
          }
          let showed = was[was.length() - 1]
          for n in was {
            if !ids.contains(n) {
              if n == showed {
                go(n, 1.0)
              } else {
                match ways.get(n) {
                  Some(wy) => wy.set((1.0, 1.0, at, 0.0))
                  None => ()
                }
              }
            }
          }
          for i, n in ids {
            go(n, if i + 1 == ids.length() { 0.0 } else { -1.0 })
          }
        })
        // (its pages: the one that shows in its column, as tall as it makes the dialog; the rest over it, off to its sides
        // (cut off by it), kept as they were left)
        d.box(fn(stack) {
          stack.clips(Is(true)).shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          stack.each(
            leave=1.0,
            fn() { pages().map(fn(pg) { StepItem::{ n: pg.0, x: pg.1 } }) },
            fn(it) { it.n },
            fn(page, item) {
              // (its own page, given it by the list as it is made: no walk of the pages for it)
              let { n: k, x: px } = item.untracked()
              let shows = fn() { top() == k }
              let slide = (d.cause_at(), @ui.move_ms(@signals.untracked(w)))
              let way = @signals.signal(
                if made_with.val {
                  if k == @signals.untracked(top) {
                    (0.0, 0.0, 0.0, 0.0)
                  } else {
                    (-1.0, -1.0, 0.0, 0.0)
                  }
                } else {
                  (1.0, 0.0, slide.0, slide.1)
                },
                same=fn(a, b) { a == b },
              )
              ways[k] = way
              aways[k] = @signals.signal(way.untracked().1 != 0.0)
              page.owns(fn() {
                ways.remove(k)
                aways.remove(k)
                match dues.get(k) {
                  Some(f) => f()
                  None => ()
                }
                dues.remove(k)
              })
              |> ignore
              let away = aways[k]
              page
              .over(By(fn() { !shows() }))
              .laid_nowhere(By(fn() { away.get() }))
              // (none of it seen while it is away)
              .alpha(By(fn() { if away.get() { 0.0 } else { 1.0 } }))
              .shrink(Is(1.0))
              .min_height(Is(Some(0.0)))
              .presses(By(shows))
              .hides(By(fn() { !shows() }))
              .moved_by(
                fn(pw, _, t) { (way_at(way.get(), t) * pw, 0.0) },
                fn(_, _) {
                  let wy = way.get()
                  wy.2 + wy.3
                },
                holds_leaving=true,
              )
              |> ignore
              step_page_node(page, px, k, close, keyed, look, words_in, fn() { back() |> ignore })
            },
          )
          made_with.val = false
        })
        |> ignore
        // (its close button over its steps, in its corner concentric with it, laid after them: a step sliding in or away
        // under it; no stop of Tab's, as the old one's: a press, Escape and back close it)
        d.box(fn(o) {
          o.over(Is(true)).width(By(fn() { Some(w()) })) |> ignore
          o.box(fn(row) {
            style_node(row, fn() { dialog_close_row })
            row.alpha(By(fn() { look().words })) |> ignore
            row.box(fn(at) {
              style_node(at, fn() { dialog_close_corner() })
              icon_button_node(at, "close", fn() { t("common.close") }, fn() {
                field_let_go(keyed)
                cancel()
              }, size=dialog_close)
              .tab_stop(Is(false))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // (another dialog over it: dimmed over all of itself, its corners its own)
        d.box(fn(v) { v.over(Is(true)).radius(Is(dialog_r)).ground(By(veil)) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
    layer
  })
}

///|
/// A step of a centred panel that goes in steps in its page `page` (steps_centred_node's): its head (its back key, `back`,
/// past the first; its title, under the close button over the dialog's corner), what it says, what it holds (a share of the window tall
/// where `px` says one, as tall as what it holds up to it where it `hugs`) and its foot, on the dialog's words' line.
#callsite(autofill(loc))
fn step_page_node(
  page : @view.View,
  px : PanelOf,
  k : Int,
  close : () -> Unit,
  keyed : Presented,
  look : () -> @ui.Look,
  words_in : Double,
  back : () -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let now = fn() {
    match px.live {
      Some(f) => f()
      None => (px.title, "", px.description)
    }
  }
  page.box(made_for=loc, fn(part) {
    // (from under the close button over the dialog's corner, as an untitled dialog's body is: dialog_untitled_top)
    style_node(part, fn() { centred_part_in(@ui.capsule_in(dialog_r, dialog_close) + dialog_close, 0.0) })
    part.alpha(By(fn() { look().words })) |> ignore
    // (its head: as high as a titled dialog's, its back key past its first step before its title, the row no taller for
    // it (step_head's), under the close button over the dialog's corner)
    part.box(fn(line) {
      style_node(line, fn() { dialog_step_head.then(step_head_gap).then(@ui.style(pl=room(words_in))) })
      if k != 0 || keyed.under is Some(_) {
        line.box(fn(key) {
          // (out of the words' line by as far as its chevron stands in, the row no taller for it: step_head's)
          style_node(key, fn() {
            in_line(step_back_side - @ui.tree_theme().text_size(Heading).1).then(@ui.style(ml=room(-step_back_in)))
          }, in_row=true)
          icon_button_node(key, "chevron-left", fn() { t("common.back") }, back, size=step_back_side) |> ignore
        })
        |> ignore
      }
      line.box(fn(l) {
        style_node(l, fn() { dialog_title_line }, in_row=true)
        l.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        words_node(l, fn() { title_plain(now().0) }, fn() { if now().1 != "" { dialog_title_one } else { dialog_title } }) |> ignore
        words_node(l, fn() { now().1 }, fn() { dialog_step }) |> ignore
      })
      |> ignore
    })
    |> ignore
    part.show(fn() { now().2 != "" }, fn(lead) {
      style_node(lead, fn() { dialog_lead_at.then(@ui.style(pl=room(words_in))) })
      words_node(lead, fn() { now().2 }, fn() { dialog_lead }) |> ignore
    })
  })
  |> ignore
  let nodes = px.nodes
  let footed = nodes.bind(fn(n) { n.foot }) is Some(_)
  page.box(made_for=loc, fn(b) {
    style_node(b, fn() { centred_part_in(0.0, 0.0) })
    b.shrink(Is(1.0)).min_height(Is(Some(0.0))).alpha(By(fn() { look().words })) |> ignore
    b.box(fn(col) {
      style_node(col, fn() { (if footed { dialog_body } else { dialog_body_end }).then(@ui.style(px=room(words_in))) })
      col.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      panel_in_lend(col, Wide, 0.0, sides=dialog_pad + words_in, rows_out=panel_words - panel_card_in, centred=true)
      col.box(fn(held) {
        if px.tall > 0.0 && !px.form {
          let share = fn() { Some(dmax(0.0, px.tall * over_room(held).1 - dialog_frame_h)) }
          match nodes {
            Some(n) if n.hugs => held.max_height(By(share)) |> ignore
            _ => held.height(By(share)) |> ignore
          }
        }
        held.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        match nodes {
          Some(n) => (n.body)(held, close)
          None => ()
        }
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  match nodes.bind(fn(n) { n.foot }) {
    Some(f) =>
      page.box(made_for=loc, fn(fv) {
        style_node(fv, fn() { centred_part_in(0.0, 0.0) })
        fv.alpha(By(fn() { look().words })) |> ignore
        fv.box(fn(row) {
          style_node(row, fn() { dialog_foot.then(dialog_corner_foot(dialog_pad)) })
          f(row, close)
        })
        |> ignore
      })
      |> ignore
    None => ()
  }
}

///|
/// What each centred panel in steps (by its presented's serial) says as a step of it is put on or taken off, before
/// that changes what it shows: its height's way from as it is laid out then (steps_centred_node's).
// kept across runs: what each dialog in steps says, let go with it
let steps_reshaping : Map[Int, () -> Unit] = Map([])

///|
/// A step's page as its panel's list of steps (panel_steps_node's View::each) has it: its number and its panel. A page
/// is made with the panel it is given as it is made and keeps it (its number is its key), so it is told as the same item
/// by its number alone: a panel is no value to compare.
priv struct StepItem {
  n : Int
  x : PanelOf
}

///|
impl Eq for StepItem with equal(a, b) {
  a.n == b.n
}
