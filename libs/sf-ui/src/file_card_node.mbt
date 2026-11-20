// A file's card in a message (file_card's, as a message's file draws it: card_item) as nodes of the window's tree: its
// capsule, its mark, its name over its size or what its download says or why it failed, its own ↻ and ✕ at its end,
// each following what it is told as that changes.

///|
/// A message's file as a card in `parent` (file_card's, as card_item asks it): its capsule on the neutral ground, 236
/// at most, as wide as what it says; its line mark (red where it failed), its name (cut short in its middle, never its
/// extension) over `meta` (its size, how far its download has come, why it failed: `failed` in red); `retry` its ↻,
/// `remove` its ✕ at its end, each concentric with the end where it is the last, named as `retry_label` and
/// `remove_label` say, their tips in `tips`; pressed, `on_press` with what was pressed (the card itself: Open), the
/// hover ground under the pointer; right clicked or held by a finger, `menu` where (its menu: file_menu's). Read out as
/// a group named by its name; its name whole in a tip by it while what it says shows cut short (file_card's).
/// `pending`: still going up (not `failed`; none said: a card that never goes up, its mark alone, nothing more made for
/// it), its mark a ring in its place: how far it has come where `progress` says
/// (0 … 1, the accent's arc), turning where it does not or every byte is gone (确认中). `open`: whether it opens at
/// all: not, no hover ground and nothing pressed (a file not sent yet has nothing to open). The node.
#callsite(autofill(loc))
pub fn file_card_node(
  parent : @view.View,
  tips : TipLayer,
  name : () -> String,
  meta : () -> String,
  failed : () -> Bool,
  retry : () -> Bool,
  remove : () -> Bool,
  retry_label : () -> String,
  remove_label : () -> String,
  on_press : (FileCardPress) -> Unit,
  menu? : (Double, Double) -> Unit,
  pending? : () -> Bool,
  progress? : () -> Double? = fn() { None },
  open? : () -> Bool = fn() { true },
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(card) {
    style_node(card, fn() {
      if retry() || remove() {
        card_box.then(card_box_round).then(card_end_justified)
      } else {
        card_box.then(card_box_round)
      }
    })
    hover_ground_node(card, on=open)
    card.says(By(fn() { Some(@view.said(Group, label=name())) })) |> ignore
    // (its name whole by it while what it says shows cut short: file_card's tip)
    tip_node(tips, card, name, repeats=true) |> ignore
    match menu {
      // (right clicked, its menu where the pointer is; held by a finger, there, felt, the press the menu's: lifting it
      // opens nothing. A mouse's button held is a press as long as any: file_menu's, menu_asked's)
      Some(menu_at) =>
        menu_presses_node(card, fn() { if open() { on_press(Open) } }, fn(x, y, _) { if open() { menu_at(x, y) } })
      None => card_presses_node(card, fn() { on_press(Open) }, open)
    }
    // (its mark, 24, concentric with its round start; going up, the ring in its place: how far, or turning while that
    // is not known or every byte is gone and its station is still to say so)
    card.box(fn(m) {
      style_node(m, fn() { card_mark }, in_row=true)
      let mark = fn(mark : @view.View) {
        icon_node(mark, "file", card_mark_size, By(fn() { if failed() { theme().p.red } else { theme().p.muted } }), name_now=fn() {
          file_mark(name())
        })
        |> ignore
      }
      match pending {
        None => mark(m)
        Some(going_up) =>
          m.pick(fn() { going_up() && !failed() }, at_once=true, fn(d, going) {
            if going {
              progress_spinner_node(
                d,
                fn() {
                  match progress() {
                    Some(p) if p < 1.0 => Some(if p < 0.0 { 0.0 } else { p })
                    _ => None
                  }
                },
                size=tile_going_spinner,
              )
              |> ignore
            } else {
              mark(d)
            }
          })
      }
    })
    |> ignore
    // (as wide as what it says, cut short where the card is at its widest)
    card.box(fn(w) {
      style_node(w, fn() { card_words_hug }, in_row=true)
      file_name_node(w, name)
      words_node(w, meta, fn() { if failed() { card_failed } else { card_meta } }) |> ignore
    })
    |> ignore
    card.show(retry, fn(e) {
      card_end_node(e, tips, "refresh", fn() {
        if retry_label() != "" {
          retry_label()
        } else {
          t("web-main.composer.retryUpload")
        }
      }, fn() { on_press(Retry) })
    })
    card.show(remove, fn(e) {
      card_end_node(e, tips, "close", fn() {
        if remove_label() != "" {
          remove_label()
        } else {
          t("web-main.file.remove", args=[("name", name())])
        }
      }, fn() { on_press(Remove) })
    })
  })
}

///|
/// A file's card `v` pressed as presses_node's is while `on` says so; while it does not, it takes no finger, no focus
/// and no press of its own, and what it holds (its ↻, ✎ and ✕ at its end) is still pressed: never View::presses,
/// whose `inert` would take its own buttons with it.
fn card_presses_node(v : @view.View, press : () -> Unit, on : () -> Bool) -> Unit {
  v
  .focusable(By(on))
  .focus_ring_theme()
  .takes(fn(w, h, _) { if on() { [(0.0, 0.0, w, h)] } else { [] } })
  .on_press(fn() { if on() { press() } })
  |> ignore
  let on_it = fn(d : @view.Drag) { on() && v.finger_target(d.wx, d.wy) }
  v.gesture(
    @ui.touch_slop(),
    tap=fn(d) { if on_it(d) { press() } },
    drag=fn(d) { if d.kind == Up && @ui.pointing() is Mouse && on_it(d) { press() } },
  )
  |> ignore
}

///|
/// A file's name on one line in `parent` (file_name's): what is cut short the middle of it, never its extension (7 at
/// most, its dot with it).
#callsite(autofill(loc))
fn file_name_node(parent : @view.View, name : () -> String, loc~ : SourceLoc) -> Unit {
  let split = fn() -> (String, String) {
    let n = name()
    match n.rev_find(".") {
      Some(i) if i > 0 && n.length() - i <= name_ext_most =>
        (n.exact_view(end=i).to_owned(), n.exact_view(start=i).to_owned())
      _ => (n, "")
    }
  }
  parent.box(made_for=loc, fn(row) {
    style_node(row, fn() { name_row })
    row.box(fn(stem) {
      style_node(stem, fn() { name_stem_cut }, in_row=true)
      words_node(stem, fn() { split().0 }, fn() { card_name }) |> ignore
    })
    |> ignore
    row.show(fn() { split().1 != "" }, fn(e) { words_node(e, fn() { split().1 }, fn() { card_name }) |> ignore })
  })
  |> ignore
}

///|
/// A button at the end of a message's file card (card_end's and card_button's): in a room 24, 22 round, the hover
/// ground under the hand, its icon in the muted ink (the text's under the hand), named `label`, its tip saying it.
#callsite(autofill(loc))
fn card_end_node(
  parent : @view.View,
  tips : TipLayer,
  icon : String,
  label : () -> String,
  press : () -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(room) {
    style_node(room, fn() { card_end_room }, in_row=true)
    @headless.button(room, label, fn(_) { press() }, fn(b, _) {
      b.focus_ring_theme() |> ignore
      style_node(b, fn() { if lit_node(b) { card_button_hot } else { card_button_box } })
      icon_node(b, icon, if icon == "close" { card_close_icon } else { card_button_icon }, By(fn() {
        let p = theme().p
        if lit_node(b) {
          p.text
        } else {
          p.muted
        }
      }))
      |> ignore
      tip_node(tips, b, label) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A file's name's stem as a node: as wide as it is, giving way to the extension after it where its row is short of
/// room (as the old view's name_stem comes out, laid out by the old view: a node's `Hug` gives no way).
// kept across runs: a value (no field of it changes)
let name_stem_cut : @ui.Style = @ui.css("w=Cut")

///|
// kept across runs: a value (no field of it changes)
let card_box_round : @ui.Style = @ui.css("radius=Full")
