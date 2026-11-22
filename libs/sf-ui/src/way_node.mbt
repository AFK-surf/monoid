// A way to where something is (way_line's: the places over it, each a way back to it, in a line that neither scrolls
// nor wraps) as nodes of the window's tree: what has not the room leaves the line as it is laid out (View::fits,
// View::drops), never read back to make it otherwise; a … where they were offers them in a menu.

///|
#derive(Eq)
priv enum WayEntry {
  Step(Int, String, Int)
  More
}

///|
/// The way `steps` (where it is the last) in a line in `parent`, `look` how it looks, a chevron between, each but the
/// last a way back to it (`go`, given its index). Where the line has not the room, steps leave it whole, never cut
/// short: those between the first and the last first (the one after the first first, the one before the last last),
/// then the first; a … where they were offers them instead (a menu of those left out as it is pressed, in their order).
/// Only where the last alone has not the room are its words cut short. Reuses step nodes by index as the steps change.
/// `last_link`: the last a way back to it too, in the steps' words (a folder's trail of the folders over it alone:
/// way_line's). Its node.
#callsite(autofill(loc))
pub fn way_line_node(
  parent : @view.View,
  steps : () -> Array[String],
  look : () -> WayLook,
  go : (Int) -> Unit,
  last_link? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(line) {
    style_node(line, fn() { look().line })
    line.fits(Is(true)) |> ignore
    let chevron = fn(p : @view.View) {
      icon_node(p, "chevron-right", @signals.untracked(fn() { look().chevron }), By(fn() { look().chevron_ink }))
    }
    // (each step's part by its index: which the line left out, read as the … is pressed)
    let parts : Map[Int, @view.View] = Map([])
    let entries = fn() -> Array[WayEntry] {
      let cur = steps()
      let n = cur.length()
      let out : Array[WayEntry] = []
      for i, name in cur {
        out.push(Step(i, name, n))
        if i == 0 && n > 1 {
          out.push(More)
        }
      }
      out
    }
    let key_of = fn(e : WayEntry) -> Int {
      match e {
        Step(i, _, _) => i
        More => -1
      }
    }
    // (a step and the chevron after it but the last: what leaves the line takes its own chevron with it, so what
    // stays has one between each two, the … too, none before the first that stays)
    line.each(at_once=true, entries, key_of, fn(p, entry) {
      style_node(p, fn() { way_part }, in_row=true)
      match entry.untracked() {
        More => {
          // (the …, there only while one is out: after the first, or in its place once it is out too)
          p.drops(Is(-1)) |> ignore
          @headless.button(
            p,
            fn() { t("common.more") },
            fn(s) {
              let cur = @signals.untracked(steps)
              let n = cur.length()
              let gone : Array[MenuItem?] = []
              for k in 0..<(n - 1) {
                match parts.get(k) {
                  Some(part) if part.left_out() =>
                    gone.push(Some(menu_item_of(cur[k], fn() { go(k) }, icon="folder")))
                  _ => ()
                }
              }
              // (opened by the … itself: beside it wherever it is laid out while open, the focus given back to it
              // as the menu goes)
              present(Menu(gone, "", Start, Bottom), Node(s))
            },
            fn(s, _) {
              s.focus_ring_theme() |> ignore
              style_node(s, fn() { look().step }, in_row=true)
              words_node(s, fn() { way_more }, fn() { look().words }) |> ignore
            },
          )
          |> ignore
          chevron(p) |> ignore
        }
        Step(i, _, _) => {
          parts[i] = p
          p.owns(fn() { parts.remove(i) }) |> ignore
          let name = fn() {
            match entry.get() {
              Step(_, s, _) => s
              More => ""
            }
          }
          let total = fn() {
            match entry.get() {
              Step(_, _, n) => n
              More => 0
            }
          }
          let last = fn() { i == total() - 1 }
          let clickable = fn() { !last() || last_link }
          // (the last: always there, its words kept whole while another may leave, cut short only after;
          // another: whole with its chevron, or out of the line; the first the last of them to go)
          p
          .fit_whole(By(last))
          .drops(By(fn() { if last() { 0 } else if i == 0 { total() } else { i } }))
          .min_width(By(fn() { if last() { Some(0.0) } else { None } }))
          .shrink(By(fn() { if last() { 1.0 } else { 0.0 } }))
          |> ignore
          p.box(fn(s) {
            style_node(s, fn() { look().step }, in_row=true)
            s
            .min_width(By(fn() { if last() { Some(0.0) } else { None } }))
            .shrink(By(fn() { if last() { 1.0 } else { 0.0 } }))
            |> ignore
            presses_node(s, fn() { if clickable() { go(i) } }, on=clickable)
            s.says(By(fn() { if clickable() { Some(@view.said(Link, label=name())) } else { None } })) |> ignore
            words_node(s, name, fn() {
              if last() && last_link {
                look().words.then(way_last)
              } else if last() {
                look().here.then(way_last)
              } else {
                look().words
              }
            })
            .min_width(By(fn() { if last() { Some(0.0) } else { None } }))
            |> ignore
          })
          |> ignore
          chevron(p).laid_nowhere(By(last)) |> ignore
        }
      }
    })
  })
}
