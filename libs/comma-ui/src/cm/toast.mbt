// Comma's toasts (toast/Toast, Toaster, styles.ts) as nodes of the window's tree: cards at the window's foot's end in
// the layer, the newest last, each popup-primary in the primary border half a point, rounded 2xl, 16 and 12 in, the lg
// shadow, 356 wide; its intent's mark before its title (sm, medium), its description under it (sm, the toast's
// secondary); gone after `stays` ms (4000, as Comma's Toaster) or at its ✕, each making its way in and out. How they
// live is mbui's headless toaster's (@headless.toaster: each one's time, stopped while the pointer is over one or the
// focus on its ✕ and going on from what each had left as they leave; swiped to the right past a third of it, or quick,
// put away; read out politely as it comes, a status, in a region): this is their look.

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
/// The toasts of a window: those showing, and where they are drawn (toaster_node); how long each stays, by its key.
pub struct Toaster {
  shown : @signals.Signal[Array[ToastSaid]]
  mut next : Int
  at : Ref[@view.View?]
  priv stays : Map[Int, Double]
}

///|
/// A window's toaster, none showing.
pub fn Toaster::new() -> Toaster {
  {
    shown: @signals.signal([]),
    next: 0,
    at: Ref(None),
    stays: Map([]),
  }
}

///|
/// How long a toast stays (Comma's Toaster's 4 s).
pub let toast_stays : Double = 4000.0

///|
/// A toast saying `title` (and `description`) with `intent`, from the moment of what caused it, gone `stays` ms after
/// (counted while its card shows and nothing holds the toasts' time: @headless.toaster).
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
/// Where `toaster`'s toasts are drawn in `layer`: a column at the window's foot's end, 24 in, 12 apart, the newest last
/// (@headless.toaster's region, read out "Notifications"; its times as "cm-toast"'s: @headless.toaster_due, toaster_rest).
pub fn toaster_node(layer : Layer, toaster : Toaster) -> Unit {
  match layer.at.val {
    None => @halt.saying("cm: a toaster made before its layer (layer_node)")
    Some(l) =>
      l.box(fn(col) {
        col
        .over(Is(true))
        .lies_along(Is(End))
        .lines_up(Is(Some(End)))
        .padding(Is((space_3xl, space_3xl, space_3xl, space_3xl)))
        |> ignore
        toaster.at.val = Some(col)
        @headless.toaster(
          col,
          fn() { toaster.shown.get() },
          fn(t) { t.id.to_string() },
          fn(t) { (t.title, t.description) },
          fn(t) { toaster.stays.get(t.id).unwrap_or(toast_stays) },
          fn(region) { region.width_share(Is(1.0)).lines_up(Is(Some(End))).gap(Is(space_lg)) |> ignore },
          fn(card, s) { toast_card(card, s) },
          fn(_) {  },
          fn(id) {
            match toaster.shown.untracked().iter().find_first(fn(t) { t.id.to_string() == id }) {
              Some(t) => toaster.dismiss(t.id)
              None => ()
            }
          },
          key="cm-toast",
          label="Notifications",
        )
        |> ignore
      })
      |> ignore
  }
}

///|
/// Toast `s`'s card, in its node `card` (@headless.toaster's) as wide as the card, saying what it says now; its ✕ closes it
/// (ToastItem::close), the toasts' time stopped while the focus is on it (ToastItem::action's).
#callsite(autofill(loc))
fn toast_card(card : @view.View, s : @headless.ToastItem[ToastSaid], loc~ : SourceLoc) -> Unit {
  let said = fn() { s.toast() }
  s.row().max_width(Is(None), within=true) |> ignore
  card.max_width(Is(None), within=true) |> ignore
  card.box(made_for=loc, fn(card) {
    card
    .width(Is(Some(356.0)))
    .max_width(Is(Some(356.0)), within=true)
    .gap(Is(space_xxs))
    .padding(Is((space_xl, space_lg, space_xl, space_lg)))
    .radius(Is(radius_2xl))
    .ground(By(fn() { colors().bg_popup_primary }))
    .edge(By(fn() { (0.5, colors().border_primary) }))
    .shadow(By(fn() { cast(shadow_lg, shadow_dark_lg) }))
    |> ignore
    card.box(fn(r) {
      r.row(Is(true)).lines_up(Is(Some(Start))).gap(Is(space_md)) |> ignore
      // (its intent's glyph, 20 across: Central's filled circle-info, -check, exclamation-circle and -x)
      icon_node(
        r,
        match @signals.untracked(fn() { said().intent }) {
          Neutral => icon_circle_info_filled
          Success => icon_circle_check_filled
          Warning => icon_exclamation_circle_filled
          Error => icon_circle_x_filled
        },
        space_2xl,
        fn() {
          let c = colors()
          match said().intent {
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
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        .words(By(fn() { said().title }), look=words_in(type_small, weight=weight_medium, wrap=true))
        .ink(By(fn() { colors().toast_text_primary }))
        |> ignore
      })
      |> ignore
      @headless.button(r, fn() { "Dismiss" }, fn(_) { s.close() }, fn(x, _) {
        let hand = eased_by(x, fn() { lit(x, fn() { true }) }, ms_state_change, ease_soft_in_out)
        x
        .padding(Is((space_xxs, space_xxs, space_xxs, space_xxs)))
        .radius(Is(radius_xs))
        .ground(By(fn() { alpha(colors().bg_secondary, hand.shown(x)) }))
        |> ignore
        icon_node(x, icon_cross, 16.0, fn() { colors().toast_icon_primary }) |> ignore
      })
      |> ignore
    })
    |> ignore
    card.show(fn() { said().description != "" }, fn(d) {
      d.padding(Is((space_2xl + space_md, 0.0, 0.0, 0.0))) |> ignore
      d.box(fn(w) {
        w
        .words(By(fn() { said().description }), look=words_in(type_small, wrap=true))
        .ink(By(fn() { colors().toast_text_secondary }))
        |> ignore
      })
      |> ignore
    })
  })
  |> ignore
}
