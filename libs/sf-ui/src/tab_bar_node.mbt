// A bar of tabs (标签栏) as nodes of the window's tree, made once: one of mbui's tab lists (@headless.radio_group, kind
// Tab), so Tab stops at the tab in front alone, ← → Home End step along them choosing each, a screen reader reads a
// tab list of tabs; each tab what its page draws in it (a mark, its words), its × at its end concentric with it where
// it closes (a control of its own beside what brings it in front, never in it), and what follows them (＋, a tool) in
// `trail`. A tab closed while the keyboard was on it gives the keyboard to the tab then in front. The files' tabs, the
// browser's, a chat's side panel's and a memory's pages are each one of these, their looks one of `TabLook`'s.

///|
/// How a bar's tabs look: `Capsule` (a chat's side panel's, a browser's: capsules 30 high along a row, the one in front
/// on the selected ground, the others the pointer's ground under the hand); `Groove` (the files' tabs: each as wide as
/// what it shows, in a tinted groove, the one in front raised on the page's ground); `Chip` (a memory's pages: pills
/// as wide as their words going on in lines, the one in front in the ink).
#derive(Eq, Debug)
pub(all) enum TabLook {
  Capsule
  Groove
  Chip
}

///|
/// When a tab's × shows: `Always`, or `Lit`: on a tab the hand or the keyboard is on alone (to a finger always, which
/// hovers over nothing). Its room is kept either way: the hand changes no box.
#derive(Eq, Debug)
pub(all) enum TabClose {
  Always
  Lit
}

///|
/// A tab as what it shows reads it: whether it is in front, whether the hand or the keyboard is on it.
pub struct TabShown {
  priv front_ : () -> Bool
  priv lit_ : () -> Bool
}

///|
/// Whether the tab is the one in front now.
pub fn TabShown::front(self : TabShown) -> Bool {
  (self.front_)()
}

///|
/// Whether the hand or the keyboard is on the tab (or its ×) now, it not being in front.
pub fn TabShown::lit(self : TabShown) -> Bool {
  (self.lit_)()
}

///|
/// A tab's words in `parent` (tab_bar_node's standard words): muted and small behind, the words' colour lit by the
/// hand, the words' colour and 500 in front; cut short where the tabs have not the room. The node.
#callsite(autofill(loc))
pub fn tab_words_node(parent : @view.View, words : () -> String, shown : TabShown, loc~ : SourceLoc) -> @view.View {
  words_node(loc~, parent, words, fn() {
    if shown.front() {
      tab_words_front
    } else if shown.lit() {
      tab_words_lit
    } else {
      tab_words
    }
  })
  .shrink(Is(1.0))
  .min_width(Is(Some(0.0)))
}

///|
/// The tabs `keys()` in `parent`, a tab list called `label()`, the one in front `front()`; a press or an arrow key on
/// another tells `show` its key. `title(key)`: what the tab is called, read out (and its tip, in `tips`, where `tip`
/// says so); `body` makes what the tab shows in it, given its key and how it is now. `close`: each tab where `closes`
/// says so (each, where it says nothing) has its × at its end (`close_label(key)` read out), pressed, or Delete or Backspace on the tab, telling
/// `close` its key; `close_shows` when it shows. `trail`: what follows the tabs in their row (＋, a tool). `scrolls`:
/// the tabs scroll across where they have not the room, the one in front brought into sight as it comes in front; else
/// they give way, their words cut short. `at_once`: a tab come or gone is there or not at once, making no way along the
/// row. `look`: TabLook's. The bar's node.
#callsite(autofill(loc))
pub fn tab_bar_node(
  parent : @view.View,
  label : () -> String,
  keys : () -> Array[String],
  front : () -> String,
  show : (String) -> Unit,
  title : (String) -> String,
  body : (@view.View, String, TabShown) -> Unit,
  look? : TabLook = Capsule,
  close? : (String) -> Unit,
  closes? : (String) -> Bool,
  close_label? : (String) -> String = fn(_) { t("web-pages.files.closeTab") },
  close_shows? : TabClose = Always,
  trail? : (@view.View) -> Unit,
  scrolls? : Bool = false,
  at_once? : Bool = false,
  tips? : TipLayer,
  tip? : (String) -> Bool = fn(_) { false },
  loc~ : SourceLoc,
) -> @view.View {
  // (the one in front held as its key, told on only as the key changes: what `front` reads besides, a chat's view
  // in a side panel's, wakes none of the bar's bindings, the radio group's own included)
  let front_given = front
  let front_key = @signals.signal(@signals.untracked(front_given))
  let front = fn() { front_key.get() }
  let tabs_in = fn(row : @view.View, made_for : SourceLoc?) {
    row.reacts(front_given, fn(k) { front_key.set(k) }, at_start=false)
    @headless.radio_group(row, label, front, show, kind=Tab, made_for?, fn(g, rg) {
      style_node(g, fn() { tab_list_look(look) }, in_row=true)
      g.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      // (short of room, every tab's words come down to four of their size before any gives way further, and then
      // each gives way past that alike, its mark and × whole, never over the next tab: View::fits, flex's
      // fit_soft_held; the pills wrap instead)
      if !(look is Chip) {
        g.fits(Is(true)) |> ignore
      }
      // (which tab is in front read by each by its own key: a tab is told only as it comes in front or leaves it)
      let front_of = g.selected(fn() { Some(front()) })
      let hands : @motion.Handoff? = match look {
        Capsule | Groove => Some(@motion.Handoff::new())
        Chip => None
      }
      if look is Chip {
        g.wraps(Is(Some(tab_chip_gap))) |> ignore
      }
      g.each(at_once~, keys, fn(k) { k }, fn(slot, k) {
        let key = k.untracked()
        let shut : Ref[@view.View?] = Ref(None)
        let on_shut = fn() {
          match shut.val {
            Some(x) => x.pointed() || x.pressed()
            None => false
          }
        }
        let item_ref : Ref[@view.View?] = Ref(None)
        let item_said : Ref[@headless.RadioItem?] = Ref(None)
        let on_item = fn() {
          match item_ref.val {
            Some(x) => lit_node(x)
            None => false
          }
        }
        let is_front = fn() { front_of(key) }
        let lit = fn() { !is_front() && (on_item() || on_shut()) }
        let shown : TabShown = { front_: is_front, lit_: lit }
        let can_close = fn() {
          close is Some(_) &&
          (match closes {
            Some(f) => f(key)
            None => true
          })
        }
        // (short of room a tab gives way, its words cut short, its mark and × whole)
        slot.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        if !(look is Chip) {
          slot.fits(Is(true)) |> ignore
        }
        match hands {
          Some(h) => {
            let part = h.part(fn(_) { if @signals.untracked(is_front) { 1.0 } else { 0.0 } })
            slot.box(fn(pill) {
              pill
              .over(Is(true), edges=(Some(0.0), Some(0.0), Some(0.0), Some(0.0)))
              .radius(Is(1.0e6))
              .ground(By(fn() {
                if is_front() {
                  match look {
                    Capsule => @ui.tree_theme().color(Selected)
                    Groove => @ui.tree_theme().color(Bg)
                    Chip => 0L
                  }
                } else {
                  0L
                }
              }))
              |> ignore
              if look is Groove {
                pill.shadow(By(fn() { if is_front() { (2.0, 1.0, @ui.tree_theme().shadow) } else { (0.0, 0.0, 0L) } }))
                |> ignore
              }
              part.draws(pill)
            })
            |> ignore
            if @signals.untracked(is_front) {
              part.came(0.0, @motion.snappy_damped, takes=false) |> ignore
            }
            slot.reacts(is_front, at_start=false, fn(on) {
              let at = slot.cause_at()
              if on {
                part.came(at, @motion.snappy_damped) |> ignore
              } else {
                part.left(at)
                part.still()
              }
            })
            slot.owns(fn() { part.gone() }) |> ignore
          }
          None => ()
        }
        if look is Chip {
          hover_ground_node(slot, on=fn() { !is_front() }, lit=Some(lit))
        }
        // (Delete or Backspace on a tab that closes closes it, as its × does, the keyboard handed to the tab then in
        // front where it was on it: the tab list's, @headless.radio_group's on_close)
        let on_close = close.map(fn(f) { fn() { f(key) } })
        let item = rg.item(slot, fn() { key }, fn() { title(key) }, on_close?, closes=can_close, fn(v, s) {
          item_ref.val = Some(v)
          item_said.val = Some(s)
          // (the one in front brought into sight as it comes in front)
          if scrolls {
            v.reacts(is_front, fn(f) { if f { v.tree.show_in_sight(v.id()) } }, at_start=false)
          }
          style_node(v, fn() { tab_body_look(look, can_close()) }, in_row=true)
          // (its words cut short as its row keeps them, its least never more than its tab's: View::fits)
          v.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          if look is Chip {
            v.focus_ring_theme() |> ignore
          } else {
            v.fits(Is(true)) |> ignore
          }
          // (in the groove, its words in its middle: as wide a room before them as its × takes after them)
          if look is Groove {
            let room = fn(r : @view.View) { r.box(fn(b) { style_node(b, fn() { tab_close_room(look) }, in_row=true) }) |> ignore }
            match (close, closes) {
              (Some(_), None) => room(v)
              (Some(_), Some(_)) => v.show(at_once=true, can_close, room)
              _ => ()
            }
          }
          body(v, key, shown)
        })
        // (its ground the one in front's, or the pointer's under the hand, and the keyboard's ring round the whole
        // capsule, its × too, concentric with it, one binding: what brings the tab in front is no rounded box of its
        // own beside its ×, pressed one height with it, heights.mbt; the pills' ring their own)
        if look is Chip {
          style_node(slot, fn() { tab_look(look, is_front(), lit()) }, in_row=true)
        } else {
          style_node_ring(
            slot,
            fn() { tab_look(look, is_front(), lit()) },
            fn() { if item.focus_shown() { (-1.0, 0.0, 0L) } else { (0.0, 0.0, 0L) } },
            in_row=true,
          )
        }
        match tips {
          Some(tl) if tip(key) => tip_node(tl, item, fn() { title(key) }, repeats=true) |> ignore
          _ => ()
        }
        // (its × made in the tab itself where each tab closes, in a structure of its own only where one may not)
        let shut_node = fn(c : @view.View) {
          let (side, icon) = tab_close_sizes(look)
          let x = icon_button_node(c, "close", fn() { close_label(key) }, fn() {
            if item_said.val is Some(s) {
              s.close()
            }
          }, size=side, icon_size=icon)
          // (no stop of Tab's: the tab list is one, Delete on a tab closing it as its × does)
          x.focusable(Is(false)).shrink(Is(0.0)) |> ignore
          shut.val = Some(x)
          x.owns(fn() { shut.val = None }) |> ignore
          if close_shows is Lit {
            x.alpha(By(fn() { if more_held() || lit_within_node(slot) { 1.0 } else { 0.0 } })) |> ignore
          }
        }
        match (close, closes) {
          (Some(_), None) => shut_node(slot)
          (Some(_), Some(_)) => slot.show(at_once=true, can_close, shut_node) |> ignore
          _ => ()
        }
      })
    })
  }
  let trail_in = fn(row : @view.View) {
    match trail {
      Some(f) =>
        row.box(fn(e) {
          e.shrink(Is(0.0)).row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(@ui.Space::S1.px())) |> ignore
          f(e)
        })
        |> ignore
      None => ()
    }
  }
  // (a row of capsules alone where nothing follows it and it does not scroll: no row of the bar's round it)
  if !scrolls && trail is None && look is Capsule {
    return tabs_in(parent, Some(loc))
  }
  parent.box(made_for=loc, fn(bar) {
    style_node(bar, fn() { tab_bar_look(look) }, in_row=true)
    bar.shrink(Is(1.0)) |> ignore
    if scrolls {
      bar.scrolls(@view.Scroll::across(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(held) {
        held.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(@ui.Space::S1.px())) |> ignore
        tabs_in(held, None) |> ignore
        trail_in(held)
      })
      |> ignore
    } else {
      tabs_in(bar, None) |> ignore
      trail_in(bar)
    }
  })
}

///|
/// The bar's row: as wide as what holds it gives it, giving way to what is beside it.
fn tab_bar_look(look : TabLook) -> @ui.Style {
  match look {
    Chip => tab_bar_chips
    _ => tab_bar_row
  }
}

///|
/// The tabs' list: a row of capsules 2 apart (Capsule), a groove (Groove), pills 6 apart going on in lines (Chip).
fn tab_list_look(look : TabLook) -> @ui.Style {
  match look {
    Capsule => tab_list_capsules
    Groove => tab_list_groove
    Chip => tab_list_chips
  }
}

///|
/// A tab's capsule as `look` has it, in front or not, lit or not: a capsule's ends as far in as its × stands
/// concentric with them.
fn tab_look(look : TabLook, front : Bool, lit : Bool) -> @ui.Style {
  match look {
    Capsule => if !front && lit { tab_capsule_lit } else { tab_capsule }
    Groove => if !front && lit { tab_groove_lit } else { tab_groove }
    Chip => if front { tab_chip_front } else { tab_chip }
  }
}

///|
/// What brings a tab in front, in its capsule: as high as it, what the tab shows in a row (its focus the capsule's
/// ring), its mark concentric with the capsule's start; with no × after it (`closes`), its words as far in from the
/// capsule's end as the mark is from its start.
fn tab_body_look(look : TabLook, closes : Bool) -> @ui.Style {
  match look {
    Capsule => if closes { tab_capsule_body } else { tab_capsule_body_open }
    Groove => tab_groove_body
    Chip => tab_chip_body
  }
}

///|
/// The × and its icon, by the tab's look: concentric with a 30 capsule's end (20, its icon 12), a groove tab's 28
/// (16, its icon 10).
fn tab_close_sizes(look : TabLook) -> (Double, Double) {
  match look {
    Groove => (tab_groove_close, 10.0)
    _ => (tab_capsule_close, 12.0)
  }
}

///|
/// As wide a room as the × takes, before a groove tab's words.
fn tab_close_room(look : TabLook) -> @ui.Style {
  let (side, _) = tab_close_sizes(look)
  @ui.style(w=Fixed(side), h=Fixed(side))
}

///|
let tab_capsule_close : Double = 20.0

///|
/// A capsule tab's mark (side_tab_mark_side's), its words as far in from its start where it has none.
let tab_mark_side : Double = 14.0

///|
let tab_groove_close : Double = 16.0

///|
/// The pills' lines' gap (Chip's), as their row's.
let tab_chip_gap : Double = 6.0

///|
// kept across runs: a value (no field of it changes)
let tab_bar_row : @ui.Style = @ui.css("row min_w=S0 align=ACenter gap=S1")

///|
// kept across runs: a value (no field of it changes)
let tab_bar_chips : @ui.Style = @ui.css("row min_w=S0 gap=S1")

///|
// kept across runs: a value (no field of it changes)
let tab_list_capsules : @ui.Style = @ui.css("row min_w=S0 gap=S0_5 align=ACenter clip=true")

///|
/// The files' groove (tabs_groove's): a tinted capsule, 2 in, its tabs 2 apart.
// kept across runs: a value (no field of it changes)
let tab_list_groove : @ui.Style = @ui.style(row=true, w=grow, min_w=S0, p=S0_5, gap=S0_5, radius=Full, bg=Tint)

///|
// kept across runs: a value (no field of it changes)
let tab_list_chips : @ui.Style = @ui.style(row=true, w=grow, min_w=S0, gap=S1_5)

///|
/// A capsule tab (side_tab_shape's): 30 high, round, its mark 8 in (concentric with its start), giving way to its
/// least.
// kept across runs: a value (no field of it changes)
let tab_capsule : @ui.Style = @ui.style(row=true, h=side_tab_h, min_w=S0, px=room_of(tab_close_in), gap=S1_5, align=ACenter, radius=Full)

///|
// kept across runs: a value (no field of it changes)
let tab_capsule_lit : @ui.Style = tab_capsule.then(@ui.css("bg=Hover"))

///|
/// How far in from a capsule tab's ends its × stands concentric with them (the capsule's own padding).
let tab_close_in : Double = @ui.capsule_in(side_tab_side / 2.0, tab_capsule_close, room=side_tab_side / 2.0)

///|
/// How far in past that its mark stands concentric with the capsule's start (the body's own padding).
let tab_mark_in : Double = @ui.capsule_in(side_tab_side / 2.0, tab_mark_side, room=side_tab_side / 2.0) - tab_close_in

///|
// kept across runs: a value (no field of it changes)
let tab_capsule_body : @ui.Style = @ui.style(
  row=true,
  h=Full,
  min_w=S0,
  pl=room_of(tab_mark_in),
  gap=S1_5,
  align=ACenter,
)

///|
/// A capsule's body with no × after it.
let tab_capsule_body_open : @ui.Style = tab_capsule_body.then(@ui.style(pr=room_of(tab_mark_in)))

///|
/// A groove tab (tab_off's): as wide as what it shows, giving way short of room, 28 high, 6 in (its × concentric
/// with its end), round.
// kept across runs: a value (no field of it changes)
let tab_groove : @ui.Style = @ui.css("row min_w=S0 h=S7 px=S1_5 gap=S1 radius=Full align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let tab_groove_lit : @ui.Style = tab_groove.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let tab_groove_body : @ui.Style = @ui.style(row=true, w=grow, min_w=S0, h=Full, gap=S1, align=ACenter, justify=JCenter)

///|
/// A page's pill (memoryChip's): 30 high, 12 in, round, the card's ground; the one in front the ink's.
// kept across runs: a value (no field of it changes)
let tab_chip : @ui.Style = @ui.style(h=side_tab_h).then(@ui.css("row radius=Full bg=Card align=ACenter"))

///|
// kept across runs: a value (no field of it changes)
let tab_chip_front : @ui.Style = tab_chip.then(@ui.css("bg=Fg"))

///|
// kept across runs: a value (no field of it changes)
let tab_chip_body : @ui.Style = @ui.css("row h=Full px=S3 gap=S1_5 align=ACenter radius=Full")

///|
/// A tab's words (side_tab_words'): muted, 13; lit by the hand, the words' colour; in front the words' colour and 500.
// kept across runs: a value (no field of it changes)
let tab_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let tab_words_lit : @ui.TextStyle = tab_words.then(@ui.text_style(color=Fg))

///|
// kept across runs: a value (no field of it changes)
let tab_words_front : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false, w=Cut)
