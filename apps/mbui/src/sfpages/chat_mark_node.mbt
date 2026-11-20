// A chat's mark, its row's second line led by where it stands, and who is in it (chat_mark.mbt, row_picture.mbt) as
// nodes of the window's tree: the same marks, made once, each following what the core says of its chat as it changes.

///|
/// A chat's mark (chat_mark's) in `parent` as `tone` says it now (busy, done, alert, wait; anything else none): a dot 8
/// across, blue or red, or at work a yellow ring stepping round in 10. One that comes while it shows fades in over
/// @sf.dur_ms (140 ms Out, no scale); one there as it is made does not.
pub fn chat_mark_node(parent : @view.View, tone : () -> String) -> Unit {
  let pop = @motion.NodeWay::new(1.0)
  parent.box(fn(m) {
    // (one there as it is made does not fade in: only one that comes while it shows)
    let first = Ref(true)
    m.reacts(tone, fn(t) {
      if first.val {
        first.val = false
        return
      }
      if t != "" && !@ui.reduced_motion() {
        pop.go_from(m, 0.0, 1.0, @motion.tween(@sf.dur_ms, ease=Out))
      }
    })
    m.alpha(By(fn() { pop.shown(m) })) |> ignore
    m.says(By(fn() {
      match tone() {
        "busy" | "done" | "alert" | "wait" => Some(@view.said(Image, label=@sf.t("web-main.chatMark." + tone())))
        _ => None
      }
    }))
    |> ignore
    m.pick(fn() {
      match tone() {
        "done" | "wait" => 1
        "alert" => 2
        "busy" => 3
        _ => 0
      }
    }, fn(k, which) {
      match which {
        // (the pick's own box the dot)
        1 | 2 =>
          k
          .width(Is(Some(chat_mark_dot)))
          .height(Is(Some(chat_mark_dot)))
          .radius(Is(1.0e6))
          .ground(By(fn() { @ui.tree_theme().color(if which == 1 { @sf.mark_blue } else { @sf.mark_red }) }))
          |> ignore
        3 => @sf.work_ring_node(k, mark_busy_side, @sf.mark_yellow) |> ignore
        _ => ()
      }
    })
  })
  |> ignore
}

///|
/// A chat's mark's dot across (mark_done's, mark_alert's: S2).
let chat_mark_dot : Double = 8.0

///|
/// The state line (state_line's) in `parent`, as the core says it now: `text`, what leads it (`lead`), a card's lead
/// word (`lead_text`), what follows the lead (`rest`); `alert` (a message that did not go) in red. A lead said as an
/// icon stands in the title's mark's column (its tip in `tips`, saying what it is); waiting's and watching's move.
pub fn state_line_node(
  parent : @view.View,
  tips : @sf.TipLayer,
  text : () -> String,
  lead : () -> String,
  lead_text : () -> String,
  rest : () -> String,
  alert : () -> Bool,
) -> Unit {
  let turn = fn() { lead() == "decision" || lead() == "need" }
  let words = fn() {
    let look = @sf.theme().chat_list
    if alert() {
      look.state_alert
    } else if turn() {
      look.state_turn
    } else {
      look.state_quiet
    }
  }
  parent.pick(fn() {
    match lead() {
      "need" | "done" | "archive" | "wait" | "watch" => lead()
      "decision" if lead_text() != "" && text().has_prefix(lead_text()) => "decision"
      _ => ""
    }
  }, fn(p, which) {
    // (giving way along its row: its words one line cut short where the row has not the room)
    p.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    match which {
      "" => @sf.words_node(p, text, words) |> ignore
      "decision" =>
        p.box(fn(r) {
          @sf.style_node(r, fn() { state_row })
          @sf.words_node(r, lead_text, fn() { words().then(@sf.theme().chat_list.state_lead) }) |> ignore
          @sf.words_node(r, fn() { text().clamped_view(start=lead_text().length()).to_owned() }, fn() {
            words().then(state_rest_cut)
          })
          |> ignore
        })
        |> ignore
      icon => {
        let label = fn() {
          match icon {
            "watch" => text()
            "need" => @sf.t("web-main.chatMark.alert")
            "done" => @sf.t("web-main.status.done")
            "archive" => @sf.t("web-main.chatMark.settled")
            _ => @sf.t("web-main.status.waiting")
          }
        }
        let ink = fn() {
          let p = @sf.theme().p
          if alert() {
            p.red
          } else if turn() {
            p.text
          } else {
            p.muted
          }
        }
        p.box(fn(line) {
          @sf.style_node(line, state_lead_line)
          // (read out whole)
          line.says(By(fn() { Some(@view.said(Text, label=text())) })) |> ignore
          line.box(fn(slot) {
            @sf.style_node(slot, fn() { state_slot }, in_row=true)
            slot.says(By(fn() { Some(@view.said(Image, label=label())) })) |> ignore
            lead_icon_node(slot, icon, ink)
            @sf.tip_node(tips, slot, label, within=true) |> ignore
          })
          |> ignore
          line.show(fn() { rest() != "" }, fn(r) {
            r.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(r, rest, words) |> ignore
          })
        })
        |> ignore
      }
    }
  })
}

///|
/// The lead's icon (lead_icon's) in `parent`, 14 in its 10 wide column (2 out of it each side), in `ink` as it is now:
/// a bell, a check, the archive box; waiting's arc with its three dots breathing one after another; watching's dot
/// beating, its arcs lit after it, every lead_loop_ms (at rest with motion reduced). `centred`: in the middle of a
/// column at least as wide as it instead (an option's disc's: need_card_node).
fn lead_icon_node(parent : @view.View, lead : String, ink : () -> Int64, centred? : Bool = false) -> Unit {
  let name = match lead {
    "need" => "bell"
    "done" => "check"
    _ => lead
  }
  // (where in its loop a part `delay` late is: 0 to 1, at rest with motion reduced)
  let at = fn(v : @view.View, delay : Double) {
    if @ui.reduced_motion() {
      0.0
    } else {
      let g = @motion.resident_cycle(v, lead_loop_ms) - delay / lead_loop_ms
      g - g.floor()
    }
  }
  parent.box(fn(b) {
    b
    .width(Is(Some(state_icon)))
    .height(Is(Some(state_icon)))
    .offset(Is((if centred { 0.0 } else { -state_icon_out }, 0.0)))
    |> ignore
    match lead {
      // (its arc, and its dots breathing one after another, in one icon)
      "wait" =>
        @sf.icon_inks_node(b, name, state_icon, fn(v) {
          let out = [([0], ink())]
          for k, d in wait_delays {
            out.push(([k + 1], @sf.alpha(ink(), lead_breathe(at(v, d)))))
          }
          out
        })
        |> ignore
      // (its arcs lit after its dot in one icon; its dot beating over them)
      "watch" => {
        @sf.icon_inks_node(b, name, state_icon, fn(v) {
          // (its dot at rest under the one that beats: the icon read whole)
          [([0], ink())] + watch_delays.mapi(fn(k, d) { ([2 * k + 1, 2 * k + 2], @sf.alpha(ink(), lead_lit(at(v, d)))) })
        })
        |> ignore
        b.box(fn(o) {
          o.over(Is(true)) |> ignore
          let dot = @sf.icon_parts_node(o, name, [0], state_icon, By(ink))
          dot.scale(By(fn() { lead_beat(at(dot, 0.0)) })) |> ignore
        })
        |> ignore
      }
      _ => @sf.icon_node(b, name, state_icon, By(ink)) |> ignore
    }
  })
  |> ignore
}

///|
/// Who is in a chat (row_aside's) in `parent`, as the core says it now: its agents' marks (past three, +N) and its
/// people's faces (each 3 over the one before with a pixel of `ground` round it as it is now; who started it, of more
/// than one, ringed in ink a pixel past that, over the others), those that lead first, 6 apart; their tips in `tips`.
/// `stint`: the page's time on top, what the faces' pictures are asked for on.
/// `reach`: how far it reaches past the end of `parent` (its last part in the column of the row's end), set with its style.
pub fn row_aside_node(
  parent : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  item : () -> ChatItem,
  lead : String,
  ground : () -> Int64,
  stint : () -> Int,
  reach? : () -> Double,
) -> Unit {
  let groups = fn() { @sfbase.row_agent_groups(item()) }
  let with_people = fn() { row_with_people(item(), lead) }
  let agents = fn(a : @view.View) {
    let said = fn() {
      item().agents.map(fn(a) { a.text }).filter(fn(s) { s != "" }).join(@sf.t("web-main.list.separator"))
    }
    a.show(fn() { groups().length() > 0 }, fn(g) {
      @sf.style_node(g, fn() { aside_agents })
      g.says(By(fn() { Some(@view.said(Image, label=said())) })) |> ignore
      let key = fn(x : @sfbase.RowAgent) { x.maker + "\u{1}" + x.runtime }
      // (each mark its own group, given it by the list: its maker and runtime are its key)
      g.each(fn() { groups().iter().take(aside_most).collect() }, key, fn(slot, x) {
        let x = x.untracked()
        @sf.style_node(slot, fn() { aside_agent }, in_row=true)
        @sf.maker_mark_node(slot, x.maker, x.runtime, @sf.theme().chat_list.agent_mark) |> ignore
      })
      g.show(fn() { groups().length() > aside_most }, fn(n) {
        @sf.words_node(n, fn() { "+\{groups().length() - aside_most}" }, fn() { aside_more }) |> ignore
      })
      @sf.tip_node(tips, g, said, within=true) |> ignore
    })
  }
  let faces = fn(a : @view.View) {
    a.show(with_people, fn(g) {
      @sf.style_node(g, fn() { aside_faces })
      g.says(By(fn() { Some(@view.said(Image, label=item().people_text)) })) |> ignore
      let shown = fn() {
        let people = item().people
        if people.length() > aside_most {
          people[:aside_most].to_owned()
        } else {
          people
        }
      }
      // (the first shown, by member: a change of it tells the two faces it concerns)
      let first_is = g.selected(fn() { shown().get(0).map(fn(q) { q.id }) })
      // (each face its own person, given it by the list: told only as that one changes)
      g.each(shown, fn(q) { q.id }, fn(slot, person) {
        let id = person.untracked().id
        let p = fn() { person.get() }
        let first = fn() { first_is(id) }
        let starter = fn() { item().people.length() > 1 && p().id == item().creator }
        // (its slot the room its face takes in the row: a face's, less what it lies over the one before, and a pixel more
        // after who started it, past its face)
        let face = slot
        let l = @sf.theme().chat_list
        face
        .width(By(fn() {
          Some((if first() { l.face_d } else { l.face_d - face_over }) + (if starter() { face_gap_w } else { 0.0 }))
        }))
        .height(Is(Some(l.face_d)))
        |> ignore
        face.box(fn(at) {
          // (where it lies over the face before it, and who started it ringed round its face and the ground round
          // that: a ring of what holds the face, laid out nowhere of its own; the two set together, as either changes)
          at
          .over(Is(true))
          .radius(Is(1.0e6))
          .sets_together(fn() { (first(), starter(), @sf.theme().p.text) }, fn(w) {
            let (first, starter, ink) = w
            at.offset(Is((if first { 0.0 } else { -face_over }, 0.0))) |> ignore
            at.ring(Is(if starter { (face_ring_out - face_ring_in, face_ring_in, ink) } else { (0.0, 0.0, 0L) })) |> ignore
          })
          |> ignore
          // (its ground a pixel round it, over the face before it: the face's ring, no box of its own)
          @sf.avatar_node(at, fn() { if p().email != "" { p().email } else { p().id } }, fn() { p().name }, fn() {
            if p().picture != "" {
              (src.picture)(p().picture, stint())
            } else {
              ""
            }
          }, l.face_d, ring=fn() { (face_ring_in, 0.0, ground()) })
        })
        |> ignore
      })
      g.show(fn() { item().people.length() > shown().length() }, fn(n) {
        @sf.words_node(n, fn() { "+\{item().people.length() - shown().length()}" }, fn() { aside_more }) |> ignore
      })
      @sf.tip_node(tips, g, fn() { item().people_text }, within=true) |> ignore
    })
  }
  // (in the box it is given, a box of its own: no box round it)
  let row = parent
  // (`reach`: how far its end reaches out past the end of the box it is given, row_aside's)
  @sf.style_node(row, fn() {
    match reach {
      Some(r) => aside_row.then(@sf.outset_end(r()))
      None => aside_row
    }
  })
  if lead == "people" {
    faces(row)
    agents(row)
  } else {
    agents(row)
    faces(row)
  }
}
