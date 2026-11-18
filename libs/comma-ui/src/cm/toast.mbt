// Comma's toasts (toast/Toast, Toaster, styles.ts) as nodes of the window's tree: cards at the window's foot's end in
// the layer, the newest last, each popup-primary in the primary border half a point, rounded 2xl, 16 and 12 in, the lg
// shadow, 356 wide; its intent's mark before its title (sm, medium), its description under it (sm, the toast's
// secondary); gone after `stays` ms (4000, as Comma's Toaster) or at its ✕, each making its way in and out. The time of
// all of them stopped while the pointer is over one or the focus in one, going on from what each had left as they leave
// (as mbui's kit's toast_node holds them).

///|
/// What a toast says it is (Comma's ToastIntent): its mark's colour.
#derive(Eq, Debug)
pub(all) enum Intent {
  Neutral
  Success
  Warning
  Error
}

///|
/// A toast shown: its key, its words, its intent.
#derive(Eq, Debug)
pub(all) struct ToastSaid {
  id : Int
  title : String
  description : String
  intent : Intent
}

///|
/// The toasts of a window: those showing, and where they are drawn (toaster_node); how long each stays, by its key, and
/// how many of them hold the time of all (the pointer over one, the focus in one).
pub struct Toaster {
  shown : @signals.Signal[Array[ToastSaid]]
  mut next : Int
  at : Ref[@view.View?]
  priv stays : Map[Int, Double]
  priv held : @signals.Signal[Int]
}

///|
/// A window's toaster, none showing.
pub fn Toaster::new() -> Toaster {
  {
    shown: @signals.signal([]),
    next: 0,
    at: Ref(None),
    stays: Map([]),
    held: @signals.signal(0, same=fn(a, b) { a == b }),
  }
}

///|
/// How long a toast stays (Comma's Toaster's 4 s).
pub let toast_stays : Double = 4000.0

///|
/// A toast saying `title` (and `description`) with `intent`, from the moment of what caused it, gone `stays` ms after
/// (counted while its card shows and nothing holds the toasts' time).
pub fn Toaster::show(
  self : Toaster,
  title : String,
  description? : String = "",
  intent? : Intent = Neutral,
  stays? : Double = toast_stays,
) -> Unit {
  let id = self.next
  self.next += 1
  self.stays[id] = stays
  let now = self.shown.untracked().copy()
  now.push({ id, title, description, intent })
  self.shown.set(now)
}

///|
/// Toast `id` gone.
pub fn Toaster::dismiss(self : Toaster, id : Int) -> Unit {
  self.stays.remove(id)
  self.shown.set(self.shown.untracked().filter(fn(t) { t.id != id }))
}

///|
/// Where `toaster`'s toasts are drawn in `layer`: a column at the window's foot's end, 24 in, 12 apart.
pub fn toaster_node(layer : Layer, toaster : Toaster) -> Unit {
  match layer.at.val {
    None => @halt.saying("cm: a toaster made before its layer (layer_node)")
    Some(l) =>
      l.box(fn(col) {
        col
        .over(Is(true))
        .lies_along(Is(End))
        .lines_up(Is(Some(End)))
        .gap(Is(space_lg))
        .padding(Is((space_3xl, space_3xl, space_3xl, space_3xl)))
        |> ignore
        toaster.at.val = Some(col)
        col.each(fn() { toaster.shown.get() }, fn(t) { t.id }, fn(card, said) {
          let id = @signals.untracked(fn() { said.get().id })
          let dismiss = fn() { toaster.dismiss(id) }
          let close : Ref[@view.View?] = Ref(None)
          let c = toast_card(card, said, dismiss, close)
          // (its ground takes the hand, as kit's toast's: the pointer over it is over it, not over what is under it)
          c.presses(Is(true)) |> ignore
          toast_times(c, toaster.stays.get(id).unwrap_or(toast_stays), toaster.held, dismiss)
          // (held: the pointer on it (on its ✕ too) or the focus on its ✕, one of the toasts holding them all; its ground
          // pointed at by being read so (View::pointed: it takes no press of its own), its ✕ found in it)
          hold_while(c, toaster.held, fn() {
            c.pointed() ||
            c.pointed_in() ||
            (match close.val {
              Some(x) => x.focused()
              None => false
            })
          })
        })
      })
      |> ignore
  }
}

///|
/// One toast's card in `parent`, saying what `said` says; its ✕ calls `dismiss` (its node put in `close`). The card.
#callsite(autofill(loc))
fn toast_card(
  parent : @view.View,
  said : @signals.Signal[ToastSaid],
  dismiss : () -> Unit,
  close : Ref[@view.View?],
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(card) {
    card
    .width(Is(Some(356.0)))
    .gap(Is(space_xxs))
    .padding(Is((space_xl, space_lg, space_xl, space_lg)))
    .radius(Is(radius_2xl))
    .ground(By(fn() { colors().bg_popup_primary }))
    .edge(By(fn() { (0.5, colors().border_primary) }))
    .shadow(By(fn() { cast(shadow_lg, shadow_dark_lg) }))
    .says(By(fn() { Some(@view.said(Status, label=said.get().title, description=said.get().description)) }))
    |> ignore
    card.box(fn(r) {
      r.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(space_md)) |> ignore
      // (its intent's glyph, 20 across: Central's filled circle-info, -check, exclamation-circle and -x)
      icon_node(
        r,
        match @signals.untracked(fn() { said.get().intent }) {
          Neutral => icon_circle_info_filled
          Success => icon_circle_check_filled
          Warning => icon_exclamation_circle_filled
          Error => icon_circle_x_filled
        },
        space_2xl,
        fn() {
          let c = colors()
          match said.get().intent {
            Neutral => c.toast_icon_primary
            Success => c.fg_success_primary
            Warning => c.fg_warning_primary
            Error => c.fg_error_primary
          }
        },
      )
      |> ignore
      r.box(fn(w) {
        w
        .grow(Is(1.0))
        .words(By(fn() { said.get().title }), look=words_in(type_small, weight=weight_medium, wrap=true))
        .ink(By(fn() { colors().toast_text_primary }))
        |> ignore
      })
      |> ignore
      close.val = Some(@headless.button(r, fn() { "Dismiss" }, fn(_) { dismiss() }, fn(x, _) {
        let hand = eased_by(x, fn() { lit(x, fn() { true }) }, ms_state_change, ease_soft_in_out)
        x
        .padding(Is((space_xxs, space_xxs, space_xxs, space_xxs)))
        .radius(Is(radius_xs))
        .ground(By(fn() { alpha(colors().bg_secondary, hand.shown(x)) }))
        |> ignore
        icon_node(x, icon_cross, 16.0, fn() { colors().toast_icon_primary }) |> ignore
      }))
    })
    |> ignore
    card.show(fn() { said.get().description != "" }, fn(d) {
      d.padding(Is((space_2xl + space_md, 0.0, 0.0, 0.0))) |> ignore
      d.box(fn(w) {
        w
        .words(By(fn() { said.get().description }), look=words_in(type_small, wrap=true))
        .ink(By(fn() { colors().toast_text_secondary }))
        |> ignore
      })
      |> ignore
    })
  })
}


///|
/// The time of the toast whose card is `card`: `stays` ms from the moment it is made, `dismiss` told then; stopped while
/// `held` says any holds it, going on from what it had left as none does (kit's toast_node's). The one place it is
/// counted from: as it is made, as the toasts are held and let go.
fn toast_times(card : @view.View, stays : Double, held : @signals.Signal[Int], dismiss : () -> Unit) -> Unit {
  // (what is left of it while it is stopped; when it is out while it counts; its wake, let go as it stops)
  let left = Ref(stays)
  let ends : Ref[Double?] = Ref(None)
  let due : Ref[() -> Unit] = Ref(fn() {  })
  card.reacts(fn() { held.get() > 0 }, fn(stopped) {
    let at = card.cause_at()
    match (stopped, ends.val) {
      (true, Some(e)) => {
        (due.val)()
        due.val = fn() {  }
        left.val = e - at
        ends.val = None
      }
      (false, None) => {
        let e = at + left.val
        ends.val = Some(e)
        due.val = card.at_moment(e, dismiss)
      }
      _ => ()
    }
  })
}

///|
/// While `on` says so of node `n`, one more holding the toasts' time (`held`), let go with it (kit's toast_node's).
fn hold_while(n : @view.View, held : @signals.Signal[Int], on : () -> Bool) -> Unit {
  let had = Ref(false)
  n.reacts(on, fn(h) {
    if h != had.val {
      had.val = h
      held.set(held.untracked() + (if h { 1 } else { -1 }))
    }
  })
  n.owns(fn() {
    if had.val {
      had.val = false
      held.set(held.untracked() - 1)
    }
  })
  |> ignore
}
