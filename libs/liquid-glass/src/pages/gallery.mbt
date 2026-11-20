// The gallery around the pages (src/gallery shows it in a window, and on the web: scripts/web.sh): the page asked for
// first, under a bar of glass at the window's top middle that chooses the page (Overview, Interactive, Dialog) and
// the look (Light, Dark). The bar is the gallery's, not the catalog's: its glass is LiquidBottomTabs' (`@paint.Glass::liquid`),
// each choice a capsule in it 4 in, the chosen one over a share of the accent. Without `chrome` there is no bar (the
// page shown in another page, alone).

///|
/// The bar's height: a choice's capsule (36) and 4 round it.
pub let bar_h : Double = 44.0

///|
/// How far the bar sits from the window's top.
pub let bar_top : Double = 12.0

///|
/// How far in from the bar's edge a choice's capsule is (the bar's corner 22 less this: a choice's 18).
let bar_pad : Double = 4.0

///|
/// A choice's capsule: its height, and how far in its words are from its sides.
let choice_h : Double = 36.0

///|
let choice_px : Double = 14.0

///|
/// How much of the accent the chosen choice's capsule is (its words the words' colour over it: the accent itself,
/// 0091FF in the dark, is under 4.5:1 over the bar's glass).
let chosen_share : Double = 0.24

///|
/// The pages the bar chooses among, each with the name it shows.
pub let gallery_pages : Array[(String, String)] = [
  ("overview", "Overview"),
  ("interactive", "Interactive"),
  ("merge", "Merge"),
  ("dialog", "Dialog"),
]

///|
/// The bar's glass: LiquidBottomTabs' (liquid_bottom_tabs.mbt, tabs_glass), unlit.
fn bar_glass() -> @paint.Glass {
  let d = @lg.is_dark()
  @paint.Glass::liquid(
    blur=2.1,
    tint=if d { 0x202020FFL } else { 0xFDFCFD67L },
    solid=if d { 0x1E1F24FFL } else { 0xFAFAFAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=28.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// One choice of the bar in `g`, `rg`'s item `key`, showing and read out as `label`: a capsule 36 high, its words in
/// the words' colour; the accent under them where it is the chosen one, the tabs' idle lens colour under a pointer or a
/// finger on it; a ring in the accent where the keyboard's focus is on it.
fn[K : Eq] choice(g : @view.View, rg : @headless.RadioGroup[K], key : K, label : String) -> Unit {
  rg.item(g, fn() { key }, fn() { label }, fn(t, it) {
    t
    .row(Is(true))
    .height(Is(Some(choice_h)))
    .padding(Is((choice_px, 0.0, choice_px, 0.0)))
    .radius(Is(choice_h / 2.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() {
      let c = @lg.colors()
      if it.chosen() {
        @lg.alpha(c.accent, chosen_share)
      } else if it.pressed() || it.hovered() {
        c.lens_idle
      } else {
        @lg.clear
      }
    }))
    |> ignore
    t.box(fn(w) {
      w
      .words(Is(label), look=@lg.words_at(14.0, weight=@lg.weight_medium))
      .ink(By(fn() { @lg.colors().content }))
      |> ignore
    })
    |> ignore
    t.show(fn() { it.focus_shown() }, fn(ring) {
      ring.over(Is(true)).radius(Is(choice_h / 2.0)).edge(By(fn() { (2.0, @lg.colors().accent) })) |> ignore
    })
  })
  |> ignore
}

///|
/// The bar in `parent` (a box over the page, as wide as it): its glass capsule in its middle, `bar_top` from its top,
/// choosing the page `name` holds and the look.
fn bar(parent : @view.View, name : @signals.Signal[String]) -> Unit {
  parent.box(fn(over) {
    over.over(Is(true)).padding(Is((0.0, bar_top, 0.0, 0.0))).lines_up(Is(Some(Middle))) |> ignore
    over.box(fn(b) {
      b
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .gap(Is(bar_pad * 2.0))
      .height(Is(Some(bar_h)))
      .padding(Is((bar_pad, bar_pad, bar_pad, bar_pad)))
      .radius(Is(bar_h / 2.0))
      .shadow(Is(@lg.shadow_default))
      .shadow_outside(Is(true))
      .glass(By(fn() { Some(bar_glass()) }))
      |> ignore
      @headless.radio_group(b, fn() { "Page" }, fn() { name.get() }, fn(n) { name.set(n) }, kind=Tab, fn(g, rg) {
        g.row(Is(true)).gap(Is(bar_pad)) |> ignore
        for p in gallery_pages {
          choice(g, rg, p.0, p.1)
        }
      })
      |> ignore
      // (a hairline between the two choices, 20 high in the bar's middle)
      b.box(fn(line) {
        line.width(Is(Some(1.0))).height(Is(Some(20.0))).ground(By(fn() { @lg.alpha(@lg.colors().content, 0.12) }))
        |> ignore
      })
      |> ignore
      @headless.radio_group(b, fn() { "Look" }, fn() { @lg.is_dark() }, fn(d) { @lg.set_dark(Some(d)) }, fn(g, rg) {
        g.row(Is(true)).gap(Is(bar_pad)) |> ignore
        choice(g, rg, false, "Light")
        choice(g, rg, true, "Dark")
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The gallery in the window's `root`: the page named `first` (as `page` makes it; made anew as another is chosen),
/// under the bar where `chrome` says, the parts moved down below it. Closing the dialog page's dialog leaves the
/// overview chosen.
pub fn gallery(root : @view.View, first : String, chrome? : Bool = true) -> Unit {
  let name = @signals.signal(first)
  let top = if chrome { bar_top + bar_h } else { 0.0 }
  root.box(fn(w) {
    w.grow(Is(1.0)) |> ignore
    w.pick(fn() { name.get() }, at_once=true, fn(p, n) {
      p.grow(Is(1.0)) |> ignore
      page(p, n, top~, closed=fn() { name.set("overview") })
    })
    // (none while the dialog page's dialog is open: it is modal, what is not in it neither read out nor pressed, and
    // over its scrim the bar would show as if it were)
    if chrome {
      w.show(fn() { name.get() != "dialog" }, fn(o) {
        o.over(Is(true)) |> ignore
        bar(o, name)
      })
    }
  })
  |> ignore
}
