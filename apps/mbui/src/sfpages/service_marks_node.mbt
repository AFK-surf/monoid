// What marking a service's page shows (service_marks.mbt's, Preview.kt MarkMode, MarksOver, Note) as nodes of the
// window's tree, made once: the mode's bar in the address's place, each mark's box on its element, its numbered pin,
// what is said of it beside the pin or its note open; each bound to what the page keeps of its marks as that is told
// (ServicePage::said), what it does done at its press. What marking does is sfbase's (service_marks.mbt).

///|
/// In the address's place while marking, in `parent` (page_mark_mode's): its dot (ringed while picking), how many or
/// what to do (why putting them failed, in red), its × leaving marking, then 添加到对话 (正在截图 while it is).
fn page_mark_mode_node(parent : @view.View, src : Source, p : ServicePage, site : @ui.NativeView) -> Unit {
  let m = p.marks
  let marking = fn() {
    p.said()
    m.marking
  }
  let n = fn() {
    p.said()
    m.marks.length()
  }
  let busy = fn() {
    p.said()
    m.shot is Some(_)
  }
  let error = fn() {
    p.said()
    m.error
  }
  parent.box(fn(bar) {
    @sf.style_node(bar, fn() { mark_mode_bar }, in_row=true)
    bar.box(fn(ring) {
      @sf.style_node(ring, fn() { if marking() { mark_dot_ring } else { mark_dot_box } }, in_row=true)
      ring.box(fn(dot) { @sf.style_node(dot, fn() { if marking() { mark_dot_on } else { mark_dot } }) }) |> ignore
    })
    |> ignore
    bar.box(fn(w) {
      @sf.style_node(w, fn() { mark_words_box }, in_row=true)
      w.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      w.pick(at_once=true, fn() { error() != "" }, fn(k, failed) {
        k.row(Is(true)).gap(Is(@ui.Space::S2.px())).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        if failed {
          @sf.words_node(k, error, fn() { mark_error_words }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        } else {
          @sf.words_node(
            k,
            fn() {
              if n() > 0 {
                svc("android-chat.preview.marked", args=[("n", n().to_string())])
              } else {
                svc("android-chat.preview.pick")
              }
            },
            fn() { mark_count_words },
          )
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          |> ignore
          k.show(at_once=true, fn() { marking() && n() > 0 }, fn(more) {
            more.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(more, fn() { svc("android-chat.preview.pickMore") }, fn() { mark_more_words }) |> ignore
          })
        }
      })
    })
    |> ignore
    // ×: marking left
    @sf.action_box_node(bar, fn() { @sf.t("common.close") }, fn(_) { page_marks_leave(p, site) }, disabled=busy, fn(v) {
      @sf.style_node(v, fn() { mark_close }, in_row=true)
      @sf.hover_ground_node(v, on=fn() { !busy() }, lit=Some(fn() { v.pointed() || v.pressed() || v.focus_shown() }))
      @sf.icon_node(v, "close", mark_small_icon, By(fn() { @sf.theme().p.muted })) |> ignore
    })
    |> ignore
    // 添加到对话
    let able = fn() { !busy() && n() > 0 }
    @sf.action_box_node(
      bar,
      fn() { svc(if busy() { "android-chat.preview.shooting" } else { "android-chat.preview.put" }) },
      fn(_) { page_marks_put(p, site, src) },
      disabled=fn() { !able() },
      fn(v) {
        @sf.style_node(v, fn() { if able() { mark_put_pill } else { mark_put_off } }, in_row=true)
        @sf.icon_node(v, "send", mark_small_icon, By(fn() {
          let t = @sf.theme()
          if t.dark {
            t.p.bg
          } else {
            0xFFFFFFFFL
          }
        }))
        |> ignore
        @sf.words_node(v, fn() { svc(if busy() { "android-chat.preview.shooting" } else { "android-chat.preview.put" }) }, fn() {
          mark_put_words
        })
        |> ignore
      },
    )
    |> ignore
  })
  |> ignore
}

///|
/// A mark as its row shows it: its number, its box on the page now, what is said of it, what it is.
#derive(Eq)
priv struct MarkSeen {
  n : Int
  rect : (Double, Double, Double, Double)
  comment : String
  kind : String
}

///|
/// The marks over the page in `parent` (the stage, `size()` as it is given; page_marks_over's), where the page is drawn
/// (a sized page where its canvas has it): each a box on its element, a numbered pin on its corner (kept in sight at the
/// stage's edges), what is said of it beside the pin, or its note open; a press on its pin or what is said opens its
/// note, on an open one's pin closes it.
fn service_marks_over_node(parent : @view.View, p : ServicePage, site : @ui.NativeView, size : () -> (Double, Double)) -> Unit {
  let m = p.marks
  parent.box(fn(layer) {
    layer.over(Is(true)) |> ignore
    // (each mark as it is now, by its number: a row told only as its own changes)
    let seen = layer.keyed_by(
      fn() {
        p.said()
        if p.session == "" {
          []
        } else {
          m.marks.map(fn(x) { { n: x.n, rect: m.at.get(x.n).unwrap_or(x.rect), comment: x.comment, kind: x.kind } })
        }
      },
      fn(x : MarkSeen) { x.n },
    )
    layer.each(
      fn() { seen.keys() },
      fn(n) { n },
      fn(row, key) {
        let n = key.untracked()
        row.over(Is(true)) |> ignore
        let mark = fn() -> MarkSeen? { seen.get(n) }
        // (CSS pixels to the stage's: the page's own ratio, then its scale; where the page stands on the stage)
        let place = fn(n_ : @view.View) -> (Double, Double, Double) {
          p.said()
          let (sw, _) = size()
          match placed_on(p, n_, size) {
            Some(pl) => (pl.x, pl.y, if m.css_w > 0.0 { pl.w / m.css_w * pl.scale } else { pl.scale })
            None => (0.0, 0.0, if m.css_w > 0.0 { sw / m.css_w } else { 1.0 })
          }
        }
        let rect = fn(n_ : @view.View) -> (Double, Double, Double, Double) {
          let (ox, oy, k) = place(n_)
          let (bx, by, bw, bh) = match mark() {
            Some(mk) => mk.rect
            None => (0.0, 0.0, 0.0, 0.0)
          }
          (ox + bx * k, oy + by * k, bw * k, bh * k)
        }
        let open = fn() {
          p.said()
          m.editing == Some(n)
        }
        let pin_at = fn(n_ : @view.View) -> (Double, Double) {
          let (x, y, _, _) = rect(n_)
          (dmax(pin_edge, x), dmax(pin_top, y))
        }
        // its box on its element: open, the accent round it over its 8%; else its edge 1.5 of the accent's 55%
        row.box(fn(b) {
          b
          .over(Is(true))
          .presses(Is(false))
          .offset(By(fn() {
            let (x, y, _, _) = rect(b)
            (x, y)
          }))
          .width(By(fn() { Some(rect(b).2) }))
          .height(By(fn() { Some(rect(b).3) }))
          .radius(Is(mark_box_r))
          .edge(By(fn() {
            let t = @sf.theme()
            if open() {
              (2.0, t.p.accent)
            } else {
              (mark_edge, @sf.alpha(t.p.accent, mark_edge_a))
            }
          }))
          .ground(By(fn() { if open() { @sf.alpha(@sf.theme().p.accent, 0.08) } else { @sf.no_ground } }))
          |> ignore
        })
        |> ignore
        // its pin, its point on the element's top-left corner
        let opens = fn() {
          match mark() {
            Some(mk) => {
              if m.editing == Some(n) {
                m.editing = None
              } else {
                m.editing = Some(n)
                m.note.set(mk.comment)
                m.note.focus()
              }
              p.tell()
            }
            None => ()
          }
        }
        let pin = @sf.step_circle_button_node(row, fn() { "\{n}" }, fn() { "\{n}" }, fn(_) { opens() })
        pin
        .over(Is(true))
        .offset(By(fn() {
          let (x, y) = pin_at(pin)
          (x - pin_edge, y - pin_rise)
        }))
        |> ignore
        // what is said of it beside the pin (on its left where the right has too little room), or its note open
        let comment = fn() {
          match mark() {
            Some(mk) => mk.comment
            None => ""
          }
        }
        row.pick(at_once=true, fn() { if open() { 2 } else if comment() != "" { 1 } else { 0 } }, fn(k, what) {
          k.over(Is(true)) |> ignore
          match what {
            2 => mark_note_node(k, p, site, n, @signals.untracked(fn() { mark().map(fn(x) { x.kind }).unwrap_or("") }), pin_at, size)
            1 => {
              let side = fn(n_ : @view.View) -> (Bool, Double) {
                let (sw, _) = size()
                let (px, _) = pin_at(n_)
                let right = sw - px - said_from >= dmin(said_room, px - said_left)
                (right, dmax(said_least, if right { sw - px - said_from } else { px - said_left }))
              }
              k.box(fn(r) {
                r
                .over(Is(true))
                .row(Is(true))
                .offset(By(fn() {
                  let (right, _) = side(r)
                  let (px, py) = pin_at(r)
                  (if right { px + pin_w + pin_edge * 2.0 } else { 0.0 }, py - pin_rise - 1.0)
                }))
                .width(By(fn() {
                  let (right, most) = side(r)
                  let (px, _) = pin_at(r)
                  Some(if right { most } else { px - said_beside })
                }))
                |> ignore
                r.box(fn(g) { g.grow(By(fn() { if side(r).0 { 0.0 } else { 1.0 } })) |> ignore }) |> ignore
                @sf.action_box_node(r, comment, fn(_) {
                  m.editing = Some(n)
                  m.note.set(comment())
                  m.note.focus()
                  p.tell()
                }, fn(v) {
                  @sf.style_node(v, fn() { mark_said }, in_row=true)
                  mark_bubble_node(v)
                  v.max_width(By(fn() { Some(side(r).1) })) |> ignore
                  @sf.words_node(v, comment, fn() { mark_said_words }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                })
                |> ignore
              })
              |> ignore
            }
            _ => ()
          }
        })
      },
    )
  })
  |> ignore
}

///|
/// What is said about mark `n` in `parent` (page_mark_note's): a bubble beside its pin (`pin_at`), 280 wide at most and
/// 8 clear of the stage's sides; its field (what it is for while empty), done closing it; its remove key taking the mark
/// off the page too.
fn mark_note_node(
  parent : @view.View,
  p : ServicePage,
  site : @ui.NativeView,
  n : Int,
  kind : String,
  pin_at : (@view.View) -> (Double, Double),
  size : () -> (Double, Double),
) -> Unit {
  let m = p.marks
  parent.box(fn(b) {
    @sf.style_node(b, fn() { mark_note })
    mark_bubble_node(b)
    let width = fn() { dmin(note_most, size().0 - 2.0 * note_clear) }
    b
    .over(Is(true))
    .width(By(fn() { Some(width()) }))
    .offset(By(fn() {
      let (x, y) = pin_at(b)
      let sw = size().0
      (dmin(dmax(note_clear, x + note_off), dmax(note_clear, sw - width() - note_clear)), dmax(note_clear, y - note_off))
    }))
    |> ignore
    b.box(fn(f) {
      @sf.style_node(f, fn() { mark_note_field }, in_row=true)
      f.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      @ui.field(
        f,
        m.note,
        placeholder=svc("android-chat.preview.mark.comment", args=[("kind", kind)]),
        font_size=note_font,
        max_lines=1,
        enter_sends=true,
        colors_by=fn() {
          let t = @sf.theme()
          (t.p.text, t.p.muted, t.p.accent)
        },
        label=svc("android-chat.preview.mark.comment", args=[("kind", kind)]),
        edited=fn(words) {
          for mk in m.marks {
            if mk.n == n {
              mk.comment = words
            }
          }
        },
        submitted=fn(_) {
          m.editing = None
          m.note.let_go()
          p.tell()
        },
      )
      |> ignore
    })
    |> ignore
    @sf.action_box_node(b, fn() { @sf.t("common.delete") }, fn(_) {
      page_marks_remove(p, site, n)
      m.note.let_go()
    }, fn(v) {
      @sf.style_node(v, fn() { mark_note_remove }, in_row=true)
      @sf.hover_ground_node(v, lit=Some(fn() { v.pointed() || v.pressed() || v.focus_shown() }))
      @sf.icon_node(v, "trash", note_icon, By(fn() { @sf.theme().p.muted })) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A bubble over the page in node `v` (what is said of a mark, its note): 75% panel liquid glass, with the light or
/// dark bubble color as solid fallback so text and icons stay legible over any web page background.
fn mark_bubble_node(v : @view.View) -> Unit {
  @sf.glass_capsule_node(
    v,
    sharing=false,
    panel=true,
    solid=fn() { @ui.tree_theme().color(if @sf.theme().dark { @sf.mark_bubble_dark } else { @sf.mark_bubble }) },
  )
  |> ignore
}
