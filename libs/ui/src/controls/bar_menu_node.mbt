// A bottom bar's last slot where it stands for more places than the bar has slots, and the menu that slot's glass
// grows into: the slot a disclosure (its place's icon and a chevron, read out expanded while its menu is open), the
// menu a list of rows, one a place (its icon and its name), each a menu's item to the keyboard and a screen reader.
// The hand's part is the bar's (one gesture over all of it: a press on the slot opens the menu at once and the same
// finger goes on to pick a row), so these take no finger of their own (View::takes, nowhere): a finger on one is its
// holder's, the bar's node with that gesture; a key or a screen reader presses them here. Where each row is, how it
// rises and fades, and the glass round them are their caller's.

///|
/// How high a row of a bar's menu is, how far the rows are in from the menu's edge, where in a row its icon and its
/// name start, and how big that icon is.
pub let bar_menu_row_h : Double = 48.0

///|
pub let bar_menu_pad : Double = 8.0

///|
pub let bar_menu_icon_x : Double = 14.0

///|
pub let bar_menu_label_x : Double = 50.0

///|
pub let bar_menu_icon : Double = 24.0

///|
/// The chevron beside the last slot's icon (its box and what is drawn in it), and the gap between them.
pub let bar_more_chevron_w : Double = 10.0

///|
pub let bar_more_chevron_gap : Double = 3.0

///|
/// The ground of a bar's selection and of its menu's indicator on the bar's glass: a grey over it by day, a well sunk
/// into it by night (black, never a lighter grey).
pub fn tab_selection() -> Int64 {
  if theme().dark {
    0x0000004DL
  } else {
    0x00000014L
  }
}

///|
/// The last slot of a bottom bar in `at` (a box its slot's size), standing for the place `icon` says now (the stations'
/// glyph of `glance` where that gives one), a chevron after it, both together in the slot's middle; lit as far as
/// `lit` says as a node is drawn. A disclosure called `said`, expanded while `open`: `press` done as a key or a screen
/// reader presses it (no finger: that is its holder's).
#callsite(autofill(loc))
pub fn bar_more_node(
  at : @view.View,
  icon : () -> String,
  glance : () -> GlyphCounts?,
  lit : (@view.View) -> Double,
  said : () -> String,
  open : () -> Bool,
  press : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let idle_ink = fn() { if theme().dark { 0xD1D5DBFFL } else { 0x6B7280FFL } }
  let lit_ink = fn() { if theme().dark { 0xFFFFFFFFL } else { 0x111827FFL } }
  @headless.disclosure(at, said, open, press, made_for=loc, fn(b, _) {
    b.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)).takes(fn(_, _, _) { [] }) |> ignore
    focus_ring_node(b)
    let face = fn(parent : @view.View, color : () -> Int64) {
      parent
      .over(Is(true))
      .gap(Is(bar_more_chevron_gap))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .row(Is(true))
      |> ignore
      parent.box(fn(p) {
        p.width(Is(Some(28.0))).height(Is(Some(28.0))) |> ignore
        p.show(at_once=true, fn() { glance() is None }, fn(i) {
          i.over(Is(true)) |> ignore
          icon_node(i, "", 28.0, By(color), name_now=icon) |> ignore
        })
        p.show(at_once=true, fn() { glance() is Some(_) }, fn(g) {
          g.over(Is(true)) |> ignore
          station_glyph_node(
            g,
            fn() { glance().unwrap_or({ online: 0, dim: 0, failing: 0, working: 0, asleep: false, connecting: 0 }) },
            28.0,
            color,
            fn() { theme().p.red },
          )
          |> ignore
        })
      })
      |> ignore
      icon_node(parent, "chevron-up", bar_more_chevron_w, By(color)) |> ignore
    }
    b.box(fn(idle) {
      idle.alpha(By(fn() { if lit(idle) < 0.999 { 1.0 } else { 0.0 } })) |> ignore
      face(idle, idle_ink)
    })
    |> ignore
    b.box(fn(over) {
      over.alpha(
        By(fn() {
          let v = lit(over)
          if v > 0.001 {
            v
          } else {
            0.0
          }
        }),
      )
      |> ignore
      face(over, lit_ink)
    })
    |> ignore
  })
  |> ignore
}

///|
/// The rows of a bar's menu in `parent` (as wide as the menu, its top the menu's): one for each of `keys` from the
/// top, `bar_menu_row_h` high and `bar_menu_pad` in from the menu's edges, its icon (`icon`'s, the stations' glyph
/// where `glance` gives one for it) and its name (`name`'s) in the words' ink. A menu called `said`, each row an item
/// of it while `open` (none of it pressed or read while not): `pick` done as a key or a screen reader presses a row,
/// `close` as Escape is pressed in it. `row_look` is given each row's node once as it is made, with its key: how it
/// rises, fades and blurs is its caller's.
#callsite(autofill(loc))
pub fn bar_menu_node(
  parent : @view.View,
  keys : () -> Array[String],
  icon : (String) -> String,
  glance : (String) -> (() -> GlyphCounts)?,
  name : (String) -> String,
  said : () -> String,
  open : () -> Bool,
  act : (String?, @view.View) -> Unit,
  row_look : (@view.View, String) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let ink = fn() { theme().p.text }
  @headless.menu(
    parent,
    label=said,
    on_close=fn() { act(None, parent) },
    disabled=fn() { !open() },
    typeahead=false,
    // (opened from its slot, the keys' focus still there: the arrows and Escape the menu's while it is open)
    captures_unfocused=true,
    made_for=loc,
    fn(m, menu) {
      m.over(Is(true)).hides(By(fn() { !open() })) |> ignore
      m.each(at_once=true, keys, fn(k) { k }, fn(slot, key) {
        let key = key.untracked()
        let top = fn() { bar_menu_pad + keys().search(key).unwrap_or(0).to_double() * bar_menu_row_h }
        slot.over(Is(true)).padding(By(fn() { (bar_menu_pad, top(), bar_menu_pad, 0.0) })) |> ignore
        menu.item(slot, fn() { name(key) }, fn(v) { act(Some(key), v) }, made_for=loc, fn(row, _) {
          row
          .height(Is(Some(bar_menu_row_h)))
          .radius(Is(bar_menu_row_h / 2.0))
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .padding(Is((bar_menu_icon_x, 0.0, bar_menu_icon_x, 0.0)))
          .gap(Is(bar_menu_label_x - bar_menu_icon_x - bar_menu_icon))
          .takes(fn(_, _, _) { [] })
          |> ignore
          focus_ring_node(row)
          match glance(key) {
            Some(g) => station_glyph_node(row, g, bar_menu_icon, ink, fn() { theme().p.red }) |> ignore
            None => icon_node(row, icon(key), bar_menu_icon, By(ink)) |> ignore
          }
          row.box(fn(w) {
            w
            .grow(Is(1.0))
            .words(By(fn() { name(key) }))
            .words_look(
              By(fn() {
                let t = theme().t
                { size: t.ui, weight: 400, line: t.ui_line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
              }),
            )
            .ink(By(ink))
            |> ignore
          })
          |> ignore
          row_look(row, key)
        })
        |> ignore
      })
    },
  )
}

///|
/// What one of a bar's two contents is drawn through while the bar turns into its menu and back: defocused by `blur`
/// as far as it is not shown (`shown` 0 to 1), through nothing once it is whole or gone.
pub fn bar_morph_lens(shown : Double, blur : Double) -> @paint.ContentLens {
  if shown <= 0.001 || shown >= 0.999 {
    @paint.ContentLens::none()
  } else {
    { blur: blur * (1.0 - shown), refraction: 0.0, bezel: 0.0, alpha: 1.0 }
  }
}
