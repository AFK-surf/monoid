// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/destinations/DialogContent.kt. Over the page dimmed by
// the scrim's colour, a card of glass 40 in from the window's sides, its corners 48: what is under it brightened (by
// 0.2 in the light, none in the dark) and made vivid (a saturation of 1.5), blurred (16 in the light, 8 in the dark),
// bent by a lens 24 deep moving it by up to 48 with depth, its highlight Plain, the dialog's container colour over it.
// In it its title (24, medium) 28 in and 24 down, its words (15, at 68% of the words' colour, 5 lines at most) 24 in,
// and two capsule buttons 48 high side by side, 16 apart and 24 in: Cancel on the container's colour at 20%, the action
// on the accent in white. What it is to the keys and a screen reader is mbui's headless dialog's: modal, read out a
// dialog by its title, the focus taken in as it opens and given back as it goes, closed by Escape, the system's back
// and a press outside it (on the scrim).

///|
/// The card's glass (iOS 27 regular liquid glass, large card blur=8.0).
fn dialog_glass() -> @paint.Glass {
  let d = is_dark()
  let c = colors()
  @paint.Glass::liquid(
    blur=8.0,
    tint=if d { 0x202020FFL } else { 0xFDFCFD67L },
    solid=alpha(c.dialog_container, if d { 1.0 / 0.4 } else { 1.0 / 0.6 }),
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=48.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// One of a dialog's buttons in `parent`: a capsule 48 high taking its share of the row, its `label` (16) in `ink` on
/// `ground`; pressed, `press` is called.
#callsite(autofill(loc))
fn dialog_button(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  ground : () -> Int64,
  ink : () -> Int64,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, fn(b, btn) {
    b
    .grow(Is(1.0))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .height(Is(Some(button_h)))
    .padding(Is((button_px, 0.0, button_px, 0.0)))
    .radius(Is(button_h / 2.0))
    .ground(By(ground))
    |> ignore
    b.box(fn(w) { w.words(By(label), look=words_at(type_body)).ink(By(ink)) |> ignore }) |> ignore
    b.show(fn() { btn.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .margin(Is((-3.0, -3.0, -3.0, -3.0)))
      .radius(Is(button_h / 2.0 + 3.0))
      .edge(By(fn() { (2.0, colors().accent) }))
      |> ignore
    })
  })
}

///|
/// A LiquidDialog in `parent` (the window's root, or a layer over all of it: what it is made in it covers), open while
/// `open` says: read out a dialog named `title`, its words `text`; `cancel` (its first button) and `close` (Escape,
/// back, a press on the scrim) tell `on_close`; its action, `action`, tells `on_action`. At most `width` wide in the
/// window's middle, 40 in from its sides. The node holding it.
#callsite(autofill(loc))
pub fn liquid_dialog_node(
  parent : @view.View,
  open : () -> Bool,
  on_close : () -> Unit,
  title : () -> String,
  text : () -> String,
  on_action? : () -> Unit = fn() {  },
  cancel? : () -> String = fn() { "Cancel" },
  action? : () -> String = fn() { "Okay" },
  width? : Double = 480.0,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(h) {
    h.over(Is(true)) |> ignore
    h.show(open, fn(s) {
      s.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      // (the scrim: the page dimmed; a press on it is outside the dialog, which closes it)
      s.box(fn(scrim) { scrim.over(Is(true)).ground(By(fn() { colors().scrim })) |> ignore }) |> ignore
      s.box(fn(room) {
        room
        .width(Is(Some(width + 2.0 * dialog_inset)))
        .max_width(Is(Some(width + 2.0 * dialog_inset)), within=true)
        .padding(Is((dialog_inset, dialog_inset, dialog_inset, dialog_inset)))
        |> ignore
        @headless.dialog(room, title, open, on_close, description=text, fn(card, _) {
          card
          .radius(Is(dialog_radius))
          .shadow(Is(shadow_default))
          .glass(By(fn() { Some(dialog_glass()) }))
          |> ignore
          card.box(fn(t) {
            t.padding(Is((28.0, 24.0, 28.0, 12.0))) |> ignore
            t.box(fn(w) {
              w
              .words(By(title), look=words_at(type_title, weight=weight_medium, wrap=true))
              .ink(By(fn() { colors().content }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
          card.box(fn(t) {
            t.padding(Is((24.0, 12.0, 24.0, 12.0))) |> ignore
            t.box(fn(w) {
              w
              .words(By(text), look=words_at(type_dialog_text, wrap=true, lines=5))
              .ink(By(fn() { alpha(colors().content, 0.68) }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
          card.box(fn(r) {
            r.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))).padding(Is((24.0, 12.0, 24.0, 24.0))) |> ignore
            dialog_button(r, cancel, on_close, cancel_ground, fn() { colors().content })
            |> ignore
            dialog_button(r, action, on_action, fn() { colors().accent }, fn() { white }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
  })
}

///|
/// The Cancel button's ground: the dialog's container colour at 20% (`containerColor.copy(0.2f)`: its alpha put, not
/// scaled).
fn cancel_ground() -> Int64 {
  (colors().dialog_container & 0xFFFFFF00L) | 0x33L
}
