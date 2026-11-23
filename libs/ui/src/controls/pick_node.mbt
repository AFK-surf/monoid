// A long pick of the presenters' (the web's chooser with its search) as nodes of the window's
// tree: a modal layer over the window, nothing under it dimmed, its small panel beside what opened it (as menu_node's:
// View::beside, grown out of that side as it comes, gone at once as it closes, as the old presenter lets it go), chooser
// wide. Its search and its list are a combobox (@headless.combobox: what it is to the keys and a screen reader): over
// its list its search, the library's line (input_node), the keyboard's as it opens; what is typed finds by the words
// (pick_found: a choice's label, note and value), none found said so (common.noMatch). The keys stay in the search: ↓
// and ↑ move what is active among the choices found that may be chosen (the one chosen as it opens), bringing it into
// sight, Enter picks it; the pointer moving onto a row makes it active. Its list scrolls past pick_list_most
// (View::scrolls), each choice an option drawn as menu_item draws it (its mark or icon in a column before its words,
// its value after them, its note under them, the one chosen in the accent, the active one on the hover's ground):
// pressed, chosen. Escape clears what is typed in its search, then closes it; back and a press outside close it.

///|
/// A long pick in `parent` while `open()` (let go of at once once not): `title` (what it is called), `choices`, the one
/// `chosen`, its search's field `line`; beside what `anchor` makes in its layer, `offset` off it, lined up `along`
/// it. `choose` with a choice's key, once; `cancel` as it is closed unchosen.
/// `shown`, `gone`: as dialog_layer_node's.
pub fn pick_node(
  parent : @view.View,
  open : () -> Bool,
  anchor : (@view.View) -> @view.View,
  title : String,
  choices : Array[Choice],
  chosen : String,
  line : @ui.Field,
  along : @ui.Along,
  offset : Double,
  choose : (String) -> Unit,
  cancel : () -> Unit,
  shown? : () -> Unit = fn() {  },
  gone? : () -> Unit = fn() {  },
  side? : @ui.Side = Bottom,
) -> Unit {
  parent.show(
    open,
    fn(layer) {
      shown()
      layer.owns(gone) |> ignore
      let th = theme()
      // (how far in it is, from the moment it opened; out from the moment it closed)
      let way = @motion.NodeWay::new(0.0)
      if layout(layer.window_w()) is Small {
        presented_sheet_rest(layer, fn(_) { way.end() })
      }
      layer.reacts(fn() { layer.leaving() }, fn(going) {
        if going {
          way.go_ms(layer, 0.0, @motion.pop_out_ms, ease=@signals.untracked(fn() { pop_out_ease_for(layer) }))
        } else {
          way.go_ms(layer, 1.0, @motion.pop_ms)
        }
      })
      let look = fn() {
        let p = way.shown(layer)
        if layer.leaving() {
          pop_out_for(layer).at(p, p)
        } else {
          pop_in_for(layer).at(p, p)
        }
      }
      let live = fn() { !layer.leaving() }
      let words_in = fn() { look().words }
      // (what is found by the words typed, as they are now)
      let found = fn() { pick_found(choices, line.text()) }
      // (said once: the first choice, or a close)
      let said = Ref(false)
      let go = fn(k : String) {
        if !said.val && @signals.untracked(live) {
          said.val = true
          choose(k)
        }
      }
      layer.over(Is(true)) |> ignore
    // (what opened it, where it is drawn: what its panel goes beside)
    let at = anchor(layer)
    let reach = menu_row_reach(th.rows.pick)
    let list = @view.Scroll::new()
    anchored_popover_bridge(layer, at, look, side~, along~, offset~)
    layer.box(fn(p) {
      anchored_popover_shell(
        p,
        at.id(),
        look,
        side~,
        along~,
        offset~,
        holds_side=true,
      )
      .width(By(fn() { Some(dmin(chooser_menu_w, dmax(0.0, over_room(layer).0 - 16.0))) }))
      .max_height(By(fn() { Some(dmax(0.0, over_room(layer).1 - 16.0)) }))
      // (small_panel's padding: its search and rows reaching past it at its sides and top to stand concentric with its
      // corners, its last row at its foot, menu_item's at_foot)
      .padding(Is((panel_pad - reach, panel_pad - reach, panel_pad - reach, panel_pad)))
      .carries_until(fn() { way.ends_at() })
      |> ignore
      // (which of what is found the keys are on: the one chosen as it opens, where it is found and to be chosen, else
      // the first found that is; ↓ ↑ moving it bring it into sight: `keyed`)
      let active : @signals.Signal[String?] = @signals.signal(
        if choices.iter().any(fn(x) { x.key == chosen && !x.disabled }) { Some(chosen) } else { None },
        same=fn(a, b) { a == b },
      )
      let keyed : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
      let off_of : Map[String, Bool] = Map([])
      for x in choices {
        if !off_of.contains(x.key) {
          off_of[x.key] = x.disabled
        }
      }
      let search : Ref[@view.View?] = Ref(None)
      // (a combobox (@headless.combobox): its search keeps the keyboard, ↓ ↑ move what is active among what is found,
      // Enter picks it, Escape clears what is typed first, then closes it; what it is to a screen reader its own)
      @headless.combobox(
        p,
        fn() { title },
        fn() { found().map(fn(x) { x.key }) },
        fn() { active.get() },
        fn(k) {
          active.set(k)
          keyed.set(keyed.untracked() + 1)
        },
        go,
        chosen=fn() { if chosen == "" { None } else { Some(chosen) } },
        key_disabled=fn(k) { off_of.get(k).unwrap_or(false) },
        on_close=fn() { if line.text() != "" { line.set("") } else { cancel() } },
        fn(cv, cb) {
          // (what it holds, as the panel held it: no room of its own)
          cv.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          let is_morph = p.lent(pill_morph_lent) is Some(_) && !p.glass_solid()
          if is_morph {
            popover_content_motion(p, cv, words_in)
          }
          // (its search, a capsule in its top corners, the library's line: Enter in it picks the active one)
          cv.box(fn(s) {
            // (as far in as all else it holds, past the panel's own ground: Look's `words`)
            if !is_morph {
              s.alpha(By(words_in)) |> ignore
            }
            search.val = Some(
              input_node(s, line, placeholder_by=fn() { t("common.search") }, small=true, submitted=fn(_) {
                match @signals.untracked(fn() { cb.active() }) {
                  Some(k) => go(k)
                  None => ()
                }
              }),
            )
          })
          |> ignore
          // (none found: said so)
          cv.show(fn() { found().is_empty() }, fn(e) {
            if !is_morph {
              e.alpha(By(words_in)) |> ignore
            }
            e.padding(Is((@ui.Space::px(S2_5) + reach, @ui.Space::px(S2), @ui.Space::px(S2_5) + reach, @ui.Space::px(S2)))) |> ignore
            e.box(fn(w) {
              w
              .words(Is(t("common.noMatch")), look=toast_words_look(Meta, L5, 400, true))
              .ink(By(fn() { @ui.tree_theme().color(Muted) }))
              |> ignore
            })
            |> ignore
          })
          // (its list, scrolling past its most)
          cb.listbox(cv, fn(l) {
            // (all it holds as far in as its look says, past the panel's own ground, edge and shadow: its rows, their
            // grounds, icons and words, the same, Look's `words` as a surface's are)
            let side = panel_pad - reach
            l
            .margin(Is((-side, 0.0, -side, 0.0)))
            .max_height(Is(Some(pick_list_most)))
            .shrink(Is(1.0))
            .min_height(Is(Some(0.0)))
            |> ignore
            if !is_morph {
              l.alpha(By(words_in)) |> ignore
            }
            // (a finger scrolling what is found keeps its search's keyboard: View::scrolls' `for_in`)
            l.scrolls(list, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), for_in?=search.val.map(fn(v) { v.id() }), fn(b) {
              b.padding(Is((side, 0.0, side, 0.0))) |> ignore
              // (its choices by key, once: they are what it was given, the same while it is open; the first of a key the one)
              let by_key : Map[String, Choice] = Map([])
              for x in choices {
                if !by_key.contains(x.key) {
                  by_key[x.key] = x
                }
              }
              // (the last found, and the one the keys are on, by member: a change of either tells the two rows it concerns)
              let last_is = b.selected(fn() { found().last().map(fn(l) { l.key }) })
              let active_is = b.selected(fn() { cb.active() })
              b.each(fn() { found().map(fn(x) { x.key }) }, fn(k) { k }, fn(cell, k) {
                let k = k.untracked()
                match by_key.get(k) {
                  Some(x) => {
                    // (the last found reaching into the panel's padding at its foot, as menu_item's at_foot)
                    let last = fn() { last_is(x.key) }
                    pick_row_node(cb, cell, x, x.key == chosen, fn() { active_is(x.key) }, keyed, fn() { active.set(Some(x.key)) }, last, reach)
                  }
                  None => ()
                }
              })
            })
            // (cut at its box while what it holds is taller than it, as @kit.in_room's held list: else what reaches past
            // it, its last row into the panel's padding, drawn whole; what it paints alone, nothing laid out by it)
            .clips(By(fn() { list.goes() }))
            // (and taking presses within its box alone then too: else its last row's reach its own, as drawn)
            .bounds_input(By(fn() { list.goes() }))
            |> ignore
          })
          |> ignore
        },
      )
      |> ignore
      // (the focus its search's as it opens on keyboard/mouse; on touch focus the panel so the soft keyboard stays down)
      let init_focus = if native_input() is Finger { p } else { search.val.unwrap() }
      @headless.overlay(
        p,
        fn(_) { cancel() },
        modal=true,
        held_back_goes_on=true,
        dismiss_on_escape=true,
        dismiss_on_outside=true,
        inert=fn() { layer.leaving() },
        auto_focus=true,
        initial_focus=init_focus,
        label=fn() { title },
        before_dismiss=fn(how) {
          if how == Escape && line.text() != "" {
            line.set("")
            true
          } else {
            false
          }
        },
        in_node=true,
        fn(_, _) {  },
      )
      |> ignore
    })
    |> ignore
    },
    leave=@motion.pop_out_ms,
  )
}

///|
/// A choice of a long pick's (menu_item's look), an option of `cb` in `b`: its mark or icon in a column before its words,
/// its value after them, its note under them, in the accent where it is the one chosen (`on`); on the hover's ground
/// while `lit` (the keys on it), brought into sight as the keys move onto it (`keyed`), made active as the pointer moves
/// onto it (`point`); pressed, chosen (the combobox's).
#callsite(autofill(loc))
fn pick_row_node(
  cb : @headless.Combobox[String],
  b : @view.View,
  x : Choice,
  on : Bool,
  lit : () -> Bool,
  keyed : @signals.Signal[Int],
  point : () -> Unit,
  last : () -> Bool,
  reach : Double,
  loc~ : SourceLoc,
) -> Unit {
  let t = theme()
  let panel = x.icon != "" || x.mark is Some(_)
  let gap = if panel { panel_row_gap } else { menu_row_gap }
  let said = [x.label, x.value, x.note].filter(fn(s) { s != "" })
  cb.option(b, made_for=loc, fn() { x.key }, fn() { said.join(" ") }, fn(r, _) {
    r
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .min_height(Is(Some(t.rows.pick)))
    .margin(By(fn() { (0.0, 0.0, 0.0, if last() { -reach } else { 0.0 }) }))
    .padding(Is((text_in + reach, menu_row_over, text_in + reach, menu_row_over)))
    .gap(Is(gap))
    .radius(Is(small_panel_inner(r_menu)))
    // (the one the keys are on, the pointer's too as it moves onto it: on the hover's ground, moving at once across the
    // rows as a menu's bar does; one not to be chosen never, faint, taking no press, its note saying why)
    .ground(By(fn() { if !x.disabled && lit() { library_theme().p.hover } else { 0L } }))
    // (the pointer moving onto it: the one the keys are on)
    .on_pointer_moved(fn() { if !x.disabled { point() } })
    |> ignore
    // (made active by the keys: in sight where the list scrolls)
    r.reacts(fn() { keyed.get() }, at_start=false, fn(_) { if @signals.untracked(lit) { r.tree.show_in_sight(r.id()) } })
    let first_line = fn(into : @view.View) {
      if panel {
        into.box(fn(col) {
          col.width(Is(Some(panel_icon_col))).lines_up(Is(Some(Middle))) |> ignore
          match x.mark {
            Some(m) => choice_mark_node(col, m, panel_icon)
            None => icon_node(col, x.icon, panel_icon, By(fn() { library_theme().p.muted })) |> ignore
          }
        })
        |> ignore
      }
      into.box(fn(w) {
        w
        .grow(Is(1.0))
        // (20 a line, as menu_item sets its words)
        .words(Is(x.label), look={ ..toast_words_look(Ui, L5, if on { 500 } else { 400 }, false), line: pick_row_line })
        .ink(By(fn() {
          if x.disabled {
            @ui.tree_theme().color(Subtle)
          } else if on {
            library_theme().p.accent_text
          } else {
            library_theme().p.text
          }
        }))
        |> ignore
      })
      |> ignore
      if x.value != "" {
        into.box(fn(w) {
          w
          // (its line the theme's for words of no line of their own, as menu_item's note at its end has it)
          .words(Is(x.value), look={
            let l = toast_words_look(Meta, L5, 400, false)
            { ..l, line: @ui.tree_theme().text_line * l.size }
          })
          .ink(By(fn() { library_theme().p.muted }))
          |> ignore
        })
        |> ignore
      }
    }
    if x.note == "" {
      first_line(r)
    } else {
      // (its note under its words, as far in as they are; what leads it by its first line: lead_by_first_line)
      r.box(fn(lines) {
        lines.grow(Is(1.0)) |> ignore
        lines.box(fn(l) {
          l.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(gap)) |> ignore
          first_line(l)
        })
        |> ignore
        lines.box(fn(u) {
          u.padding(Is((if panel { panel_icon_col + gap } else { 0.0 }, 0.0, 0.0, 0.0))) |> ignore
          u.box(fn(w) {
            w
            .words(Is(x.note), look=toast_words_look(Meta, L5, 400, true))
            .ink(By(fn() { library_theme().p.muted }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  })
  |> ignore
}

///|
/// A long pick's row's words' line (menu_item's: 20).
let pick_row_line : Double = 20.0
