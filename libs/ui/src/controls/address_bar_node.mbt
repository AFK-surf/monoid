// A web page's address (地址栏) as nodes of the window's tree, made once: the place's capsule (bar_field_node), the
// address in it as the page it shows says it, followed while nobody writes in it; pressed into, all of it picked, to be
// written over (as a browser's is), on the card's ground with the accent round it while written in; Enter goes to what
// is written, Escape gives the writing up, the page's address in it again; how far the page came along its foot. A web
// service's, Farview's and a station's browser's bars are each this capsule, their keys (← → ⟳) and tools round it
// (address_bar_node).

///|
/// The address in `parent`, written in `field` (the caller's, that asks it the keys: ⌘L): `url()` the page's address
/// as it is now, put in the field (its caret at its start) whenever nobody writes in it; `go` told what is written as
/// Enter is pressed (the keyboard's 前往), the field let go; Escape lets it go, the page's address in it again. `label`:
/// what a screen reader calls it; `placeholder`: what it says empty. `lead`: what stands before the words in the
/// capsule (the web's mark, a site's name); `end`: what stands at its end in a press's room (reload); `progress`: how far
/// the page came, along its foot (its share and colour; none: nothing). `anywhere`: a press anywhere on the capsule
/// (its lead too) writes there, taken by a box of no ground in it that is a ground to the hand, so the words' room grown
/// round them past the capsule (rule 2) is the field's still; else only the words take a press, their room so grown. `least`: how narrow it
/// comes to (bar_field_node's). `framed`: on a bar of the canvas's own ground (a station's browser's), the capsule on
/// the card's ground with its line round it and the address in the words' colour (bar_field_node's). `selects`: pressed
/// into, all of it picked to be written over, the address put back with its caret at its start (a whole address, its
/// site read first); else (a path after a name the lead says) the caret at its end, what is typed going after it. The
/// capsule.
#callsite(autofill(loc))
pub fn address_field_node(
  parent : @view.View,
  field : @ui.Field,
  url : () -> String,
  go : (String) -> Unit,
  label : () -> String,
  placeholder? : () -> String = fn() { "" },
  editable? : () -> Bool = fn() { true },
  lead? : (@view.View) -> Unit,
  end? : ((@view.View) -> Unit)? = None,
  progress? : () -> (Double, @ui.Color)? = fn() { None },
  least? : Double = bar_field_least,
  anywhere? : Bool = false,
  framed? : Bool = false,
  selects? : Bool = true,
  loc~ : SourceLoc,
) -> @view.View {
  let writing = @signals.signal(false)
  // (the page's address put back: a whole one's caret at its start, its site read first, not scrolled to its end; a
  // path's at its end, to write after)
  let put_back = fn() {
    let u = @signals.untracked(url)
    if field.text() != u {
      if selects {
        field.set(u, caret=0)
      } else {
        field.set(u)
      }
    }
  }
  bar_field_node(
    loc~,
    parent,
    fn() { writing.get() && editable() },
    fn(cap) {
      // (a press anywhere on it writes there, where the caller says so and it is editable: taken by a box of no ground
      // over the capsule's own (the capsule's ground, as tall as it is drawn, beside a bar's keys of another height, is
      // no press's), a ground to the hand (not one of the tree's press boxes) taking a finger only in itself, so the
      // words' room grown past it (rule 2) is the field's still. Where the capsule holds an end key, `cap` is that box,
      // bar_field_node's words; else one is made as it makes it)
      let ibeam : @view.Live[@view.Cursor?] = By(fn() { if editable() { Some(IBeam) } else { None } })
      // (a press there the field's own, as on its words: a tap its caret and its menu to paste, a long press its 粘贴,
      // @ui.field_menu_on)
      let anywhere_in = fn(w : @view.View) {
        w
        .cursor(ibeam)
        .presses(By(editable))
        .on_press(fn() {  })
        .takes(fn(bw, bh, _) { [(0.0, 0.0, bw, bh)] })
        .as_ground()
        |> ignore
        @ui.field_menu_on(w, field, enabled=editable)
      }
      let made = fn(b : @view.View) {
        // (Escape, which the field takes not, gives the writing up: the page's address again, the field let go)
        b.on_key(fn(k) {
          if k.code == @ui.key_escape && k.mods == 0 && field.focused() {
            field.let_go()
            put_back()
            true
          } else {
            false
          }
        })
        |> ignore
        match lead {
          Some(f) => f(b)
          None => ()
        }
        // where the page is is what it says, unless someone is writing there
        b.reacts(fn() { (url(), writing.get(), editable()) }, fn(told) {
          if !told.2 && field.focused() {
            field.let_go()
          }
          if !told.1 || !told.2 {
            put_back()
          }
        })
        b.box(fn(f) {
          f.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).presses(By(editable)) |> ignore
          let input = @ui.field(
            f,
            field,
            max_lines=1,
            enter_sends=true,
            ime_action=@hostapi.ime_action_go,
            label=@signals.untracked(label),
            placeholder_by=placeholder,
            size_by=fn() { theme().t.ui },
            colors_by=fn() {
              let t = theme()
              (if editable() && (writing.get() || framed) { t.p.text } else { t.p.muted }, t.p.muted, t.p.accent)
            },
            submitted=fn(typed) {
              if !@signals.untracked(editable) {
                field.let_go()
                put_back()
                return
              }
              let to = typed.trim().to_owned()
              field.let_go()
              if to == "" {
                put_back()
                return
              }
              go(to)
            },
          )
          // pressed into: all of it picked, to be written over (where it `selects`). Taken from it by a layer put over it (a panel, a menu:
          // presenter_visible as it goes) it is written in still, what was written kept and nothing picked again as the
          // keys come back
          let under_layer = Ref(false)
          input.reacts(fn() { field.focused() }, fn(on) {
            if on {
              let fresh = !under_layer.val
              under_layer.val = false
              writing.set(true)
              if fresh && selects {
                field.pick(0, field.text().length())
              }
            } else if @signals.untracked(presenter_visible) {
              under_layer.val = true
            } else {
              under_layer.val = false
              writing.set(false)
            }
          })
        })
        |> ignore
      }
      match end {
        None if anywhere => {
          cap.cursor(ibeam) |> ignore
          cap.box(fn(w) {
            style_node(w, fn() { bar_field_words }, in_row=true)
            anywhere_in(w)
            made(w)
          })
          |> ignore
        }
        _ => {
          if anywhere {
            anywhere_in(cap)
          }
          made(cap)
        }
      }
    },
    end~,
    part=progress,
    least~,
    framed~,
  )
}

///|
/// A browser's row in `parent`: ← (able as `can_back` says), → and ⟳ where `keys_shown` says there is the room (⟳ the
/// cross of stopping while `busy`, `stop` then), the address (address_field_node's, `field`, `url`, `go`, `label`,
/// `placeholder`, `lead`, `progress`), what `start` makes before the keys and `end` after the address (a tool, the tabs'
/// count, ⋯), each key and tool a press's room apart; `framed` as address_field_node's. Its tips in `tips`. The row.
#callsite(autofill(loc))
pub fn address_bar_node(
  parent : @view.View,
  field : @ui.Field,
  url : () -> String,
  go : (String) -> Unit,
  label : () -> String,
  back : () -> Unit,
  forward : () -> Unit,
  reload : () -> Unit,
  can_back? : () -> Bool = fn() { true },
  can_forward? : () -> Bool = fn() { true },
  can_reload? : () -> Bool = fn() { true },
  editable? : () -> Bool = fn() { true },
  busy? : () -> Bool = fn() { false },
  stop? : () -> Unit = fn() {  },
  keys_shown? : () -> Bool = fn() { true },
  placeholder? : () -> String = fn() { "" },
  lead? : (@view.View) -> Unit,
  progress? : () -> (Double, @ui.Color)? = fn() { None },
  start? : (@view.View) -> Unit,
  end? : (@view.View) -> Unit,
  tips? : TipLayer,
  framed? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(row) {
    style_node(row, fn() { address_row.then(@ui.style(gap=keys_gap(size=theme().bars.key))) }, in_row=true)
    match start {
      Some(f) => f(row)
      None => ()
    }
    bar_key_node(row, fn() { "arrow-left" }, fn() { t("web-pages.screen.back") }, back, enabled=can_back, tips?) |> ignore
    row.show(at_once=true, keys_shown, fn(k) {
      k.row(Is(true)).lines_up(Is(Some(Middle))).gap(By(fn() { keys_apart(size=theme().bars.key) })) |> ignore
      bar_key_node(k, fn() { "arrow-right" }, fn() { t("web-pages.screen.forward") }, forward, enabled=can_forward, tips?)
      |> ignore
      bar_key_node(
        k,
        fn() { if busy() { "close" } else { "refresh" } },
        fn() { t(if busy() { "android-chat.agent.stop" } else { "web-pages.screen.reload" }) },
        fn() { if @signals.untracked(busy) { stop() } else { reload() } },
        enabled=can_reload,
        tips?,
      )
      |> ignore
    })
    address_field_node(row, field, url, go, label, placeholder~, editable~, lead?, progress~, least=0.0, framed~) |> ignore
    match end {
      Some(f) => f(row)
      None => ()
    }
  })
}

///|
/// A browser's row: across what holds it, its keys and the address in its middle.
// kept across runs: a value (no field of it changes)
let address_row : @ui.Style = @ui.css("row w=Full min_w=S0 align=ACenter")
