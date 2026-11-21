// Tabs (标签页) as nodes of the window's tree, made once: a tab list over the panel of the tab chosen. Two looks
// (`TabsLook`): `Underline`, words along a hairline, the chosen one's in the ink with a bar under it; `Pill`, words in a
// quiet capsule track, the chosen one's on a lifted capsule. The bar or the capsule slides from where it is to the tab
// chosen as that changes, at that moment, as a thing moved does (@motion's move_spring), its width moving with its
// place (@ui.cover_rect). What it is to the hand, the keyboard and a screen reader is mbui's tabs (@headless.Tabs: a
// tab list of tabs, Tab stopping at the chosen one, ← → Home End choosing along it, or moving the focus alone where
// `manual`, Space or Enter choosing; each panel read out while its tab is chosen); here their look.

///|
/// How a tabs_node's tab list looks: words along a hairline, a bar under the chosen one's (`Underline`), or words in a
/// quiet capsule track, the chosen one's on a lifted capsule (`Pill`).
#derive(Eq, Debug)
pub(all) enum TabsLook {
  Underline
  Pill
}

///|
/// Tabs in `parent` as wide as where they are: a tab list called `label` of `tabs` (each its key and its words), the one
/// chosen `chosen()`, `choose` told the key a press or a key chooses (the caller says it chosen then); under it the
/// panel of the chosen tab, made by `content` (given the panel and its key) while its tab is chosen, or once and kept
/// while another is (`keep_mounted`: what it holds keeps its state, hidden, taking no input and no room). `look` its
/// tab list's look; `manual`: the arrow keys move the focus alone, Space or Enter choosing. The node.
#callsite(autofill(loc))
pub fn[K : Eq] tabs_node(
  parent : @view.View,
  label : () -> String,
  tabs : Array[(K, () -> String)],
  chosen : () -> K,
  choose : (K) -> Unit,
  content : (@view.View, K) -> Unit,
  look? : TabsLook = Underline,
  manual? : Bool = false,
  keep_mounted? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let t = @headless.Tabs::new(chosen, choose, manual~)
  let place_of = fn(k : K) -> Int { tabs.search_by(fn(e) { e.0 == k }).unwrap_or(0) }
  let tab_h = match look {
    Underline => tabs_line_h
    Pill => tabs_pill_h
  }
  parent.box(made_for=loc, fn(col) {
    style_node(col, fn() { tabs_column })
    let panel_way = @motion.NodeWay::new(1.0)
    let panel_dir : Ref[Double] = Ref(1.0)
    // its tab list (a row as wide as where it is, its track as wide as its tabs)
    col.box(fn(line) {
      style_node(line, fn() { tabs_line })
      @headless.Tabs::list(t, line, label, made_for=loc, fn(list, rg) {
        style_node(list, fn() {
          match look {
            Underline => tabs_list_line
            Pill => tabs_list_pill
          }
        })
        // (underlined, across its line, its hairline under the room after its tabs too; a pill's track as wide as its
        // tabs)
        if look is Underline {
          list.grow(Is(1.0)) |> ignore
        }
        list.box(fn(strip) {
          style_node(strip, fn() { tabs_strip })
          // (each tab as wide as its words, 500, at the system's size of words, with its sides: measured again as all
          // words are, the size of words changed)
          let w_of = fn(i : Int) {
            strip.words_redone() |> ignore
            match tabs.get(i) {
              Some((_, words)) => node_words_w(words(), node_sp(strip, theme().t.ui), weight=500) + 2.0 * tabs_in
              None => 0.0
            }
          }
          let x_of = fn(i : Int) {
            let mut x = 0.0
            for j in 0..<i {
              x = x + w_of(j) + tabs_gap
            }
            x
          }
          // (where the bar or the capsule is along the strip and how wide: off from where it set out to the chosen
          // tab's place and width together as that changes, on snappy_damped; the words' size changed, there at once)
          let tab_h_now = fn() {
            strip.words_redone() |> ignore
            let tl = @ui.tree_theme().text_line
            let line = theme().t.ui * (if tl > 0.0 { tl } else { 1.4 })
            dmax(tab_h, node_sp(strip, line).ceil() + 2.0 * 2.0)
          }
          let rect = @motion.cover_indicator(
            strip,
            fn() { place_of(chosen()) },
            fn(k) {
              if k >= 0 && k < tabs.length() {
                Some((x_of(k), 0.0, w_of(k), tab_h_now()))
              } else {
                None
              }
            },
            spec=@motion.snappy_damped,
          )
          let prev_idx = Ref(place_of(@signals.untracked(chosen)))
          strip.reacts(chosen, at_start=false, fn(k) {
            let to_k = place_of(k)
            let from_k = prev_idx.val
            prev_idx.val = to_k
            if to_k != from_k {
              panel_dir.val = if to_k > from_k { 1.0 } else { -1.0 }
              if !@ui.reduced_motion() {
                panel_way.go_from(strip, 0.0, 1.0, @motion.tween(180.0, ease=Out))
              }
            }
          })
          let held = @motion.NodeWay::new(0.0)
          let pressed_id : @signals.Signal[@view.NodeId?] = @signals.signal(None)
          if look is Pill {
            strip.reacts(
              fn() { !strip.glass_solid() && !@ui.reduced_motion() && pressed_id.get() is Some(_) },
              fn(down) { held.go(strip, if down { 1.0 } else { 0.0 }, @motion.backdrop_press_spring) },
            )
          }
          let lens = fn() {
            if !(look is Pill) || strip.glass_solid() || @ui.reduced_motion() {
              0.0
            } else {
              held.shown(strip)
            }
          }
          strip.box(fn(mark) {
            mark
            .over(Is(true))
            .width(Is(Some(0.0)))
            .ground_drawn(By(fn() {
              match rect() {
                Some((x, _, w, _)) => {
                  dx: x,
                  dy: match look {
                    Underline => tab_h_now() - tabs_bar_h
                    Pill => 0.0
                  },
                  dw: w,
                  dh: 0.0,
                  corners: None,
                }
                None => @view.ground_as_laid
              }
            }))
            |> ignore
            match look {
              Underline =>
                mark
                .height(Is(Some(tabs_bar_h)))
                .radius(Is(tabs_bar_h / 2.0))
                .ground(By(fn() { theme().p.text }))
                |> ignore
              Pill =>
                mark
                .height(By(fn() { Some(tab_h_now()) }))
                .radius(By(fn() { tab_h_now() / 2.0 }))
                .ground(By(fn() { @ui.tree_theme().lifted }))
                .edge(By(fn() { (0.5, theme().p.line) }))
                .shadow(By(fn() { (1.0, 0.0, theme().p.shadow) }))
                .alpha(By(fn() { seg_thumb_alpha(lens()) }))
                |> ignore
            }
          })
          |> ignore
          for i, tab in tabs {
            let (key, words) = tab
            rg.item(strip, fn() { key }, words, made_for=loc, fn(o, item) {
              if look is Pill {
                seg_bind_item_press(o, fn() { item.pressed() }, pressed_id)
              }
              o
              .focus_ring_theme()
              .width(By(fn() { Some(w_of(i)) }))
              .height(By(fn() { Some(tab_h_now()) }))
              .radius(By(fn() { if look is Pill { tab_h_now() / 2.0 } else { tabs_corner } }))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              |> ignore
              o.box(fn(w) {
                w
                .words(By(words))
                .words_look(By(fn() {
                  // (its line so many times its size as drawn, at the system's size of words: seg_node's)
                  {
                    size: theme().t.ui,
                    weight: 500,
                    line: -@ui.tree_theme().text_line,
                    wrap: false,
                    tracking: @view.letters_own,
                    balance: false,
                    max_lines: 0,
                  }
                }))
                .ink(By(fn() {
                  if item.chosen() || (!item.disabled() && (item.hovered() || item.pressed())) {
                    theme().p.text
                  } else {
                    theme().p.muted
                  }
                }))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          }
          if look is Pill {
            seg_lens_overlay_node(strip, lens, tab_h_now, rect)
          }
        })
        |> ignore
        if look is Underline {
          list.box(fn(rule) { style_node(rule, fn() { tabs_rule }) }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
    // the panels: the chosen one's laid out, the others (kept) taking no room
    col.box(fn(panels) {
      style_node(panels, fn() { tabs_panels })
      for tab in tabs {
        let (key, words) = tab
        t.panel(
          panels,
          key,
          words,
          made_for=loc,
          keep_mounted~,
          fn(p, shown) {
            style_node(p, fn() { tabs_panel })
            p
            .laid_nowhere(By(fn() { !shown.selected() }))
            .offset(By(fn() {
              let q = panel_way.shown(p)
              (panel_dir.val * 12.0 * (1.0 - q), 0.0)
            }))
            .alpha(By(fn() { panel_way.shown(p) }))
            .carries_until(fn() { panel_way.ends_at() })
            |> ignore
          },
          fn(p) { content(p, key) },
        )
        |> ignore
      }
    })
    |> ignore
  })
}

///|
/// An underlined tab's height, a pill's, and the bar under the chosen underlined one.
let tabs_line_h : Double = 36.0

///|
let tabs_pill_h : Double = 28.0

///|
let tabs_bar_h : Double = 2.0

///|
/// Words in from a tab's sides, and the room between tabs.
let tabs_in : Double = 12.0

///|
let tabs_gap : Double = 2.0

///|
/// An underlined tab's corner (its focus ring's, its ground none).
let tabs_corner : Double = 6.0

///|
// kept across runs: a value (no field of it changes)
let tabs_column : @ui.Style = @ui.css("w=Full gap=S3")

///|
/// Its tab list's line, as wide as where it is.
// kept across runs: a value (no field of it changes)
let tabs_line : @ui.Style = @ui.css("row w=Full")

///|
/// The underlined list: across its line, its tabs over a hairline.
// kept across runs: a value (no field of it changes)
let tabs_list_line : @ui.Style = @ui.css("w=Full")

///|
/// The hairline under underlined tabs, across their list.
// kept across runs: a value (no field of it changes)
let tabs_rule : @ui.Style = @ui.css("w=Full h=SPx bg=Line")

///|
/// The pill's track: a quiet capsule round its tabs, 4 in (so the capsule in it stands concentric with it).
// kept across runs: a value (no field of it changes)
let tabs_list_pill : @ui.Style = @ui.css("row p=S1 radius=Full bg=A(Fg,O5)")

///|
// kept across runs: a value (no field of it changes)
let tabs_strip : @ui.Style = @ui.css("row gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let tabs_panels : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let tabs_panel : @ui.Style = @ui.css("w=Full gap=S2")
