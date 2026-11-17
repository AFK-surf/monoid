// ⌘F's bar (find_bar's) as nodes of the window's tree, made once in a chat's bar while its find is open there: what it
// did not look in before its field, while that is so; the field (finding's, the one Field the find keeps) 320 wide,
// giving way first down to 160, its count and its three round buttons at its end. What is typed is looked for
// find_typing_ms after the last edit, at that edit's moment and that much later (View::at_moment), never by watching
// it; Enter the next, ⇧Enter the one before (the keymap's `find.prev` where the bar is, `Find`: settings' keymap.mbt), Escape the frame's.
// It fades in as it comes (kit's tip_in: 120 ms, eased out), and out as long once the find closes, what holds it keeping
// it that long (chat_bar_wide_node's pick, `leave_of`), showing what it showed as the find closed (what the core found,
// where the reader was, the words typed), not the find as it is once closed; opened again meanwhile, back in from where
// it is (@motion.presence_in: a fade, carrying nothing).

///|
/// ⌘F's bar in `parent` (a row it lies along in) for chat `r` (its thread `thread`, as the chat's view has it), the list
/// it goes along `list`; its buttons' tips in `tips`. The bar's node.
pub fn find_bar_node(
  parent : @view.View,
  src : Source,
  r : ChatRef,
  thread : () -> Double?,
  list : FindList,
  tips : @sf.TipLayer,
) -> @view.View {
  let key = chat_key(r)
  let made : Ref[@view.View?] = Ref(None)
  // (what it shows of the find: as it is while it is open in this chat, held as it was once it closes, so the bar going
  // fades out as it was; sfpages' find_close empties the find at once)
  let open_here = fn() { finding.chat.get() == key }
  let found = @signals.signal(finding.found.untracked())
  let place = @signals.signal(
    (finding.position.untracked(), finding.total.untracked()),
    same=fn(a, b) { a == b },
  )
  let bringing = @signals.signal(finding.bringing.untracked(), same=fn(a, b) { a == b })
  parent.box(fn(bar) {
    made.val = Some(bar)
    @sf.style_node(bar, fn() { find_bar_style }, in_row=true)
    // (giving way along the row as an old view's box does, its field first down to its least)
    bar.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    // (as it comes: faded in from its making, its cause's moment; out as what holds it lets it go, back in as it is
    // shown again on its way out: a fade, carrying nothing)
    bar.alpha(By(@motion.presence_in(bar, @motion.tween(find_in_ms, ease=Out)))) |> ignore
    bar.reacts(
      fn() {
        if open_here() {
          Some((finding.found.get(), find_position(), finding.bringing.get()))
        } else {
          None
        }
      },
      fn(now) {
        match now {
          Some((f, at, b)) => {
            found.set(f)
            place.set(at)
            bringing.set(b)
          }
          None => ()
        }
      },
    )
    // (⇧Enter: the one before, as it comes, before the field takes it as its Enter)
    bar
    .key_context("Find")
    .on_action("find.prev", fn(_) {
      find_move(src, key, list, -1)
      true
    })
    |> ignore
    // what it did not look in, while it is so
    bar.show(
      fn() {
        match found.get() {
          Some(f) => !f.whole
          None => false
        }
      },
      fn(n) {
        @sf.style_node(n, fn() { find_note_box }, in_row=true)
        n.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(
          n,
          fn() {
            let (held, of) = match found.get() {
              Some(f) => (f.held, f.of)
              None => (0, 0)
            }
            if bringing.get() {
              @sf.t("web-main.find.bringing", args=[("held", held.to_string())])
            } else {
              @sf.t("web-main.find.partial", args=[("held", held.to_string()), ("of", of.to_string())])
            }
          },
          fn() { find_meta },
        )
        |> ignore
      },
    )
    bar.box(fn(f) {
      @sf.style_node(f, fn() { find_field_style }, in_row=true)
      f.shrink(Is(1.0)) |> ignore
      // (what is typed as it stands as the bar is made: looked for that much later, as an edit's is)
      finding.query = @signals.untracked(fn() { finding.field.text() }).replace_all(old="\n", new="")
      let due = Ref(fn() {  })
      let ask = fn(typed : String) {
        (due.val)()
        due.val = fn() {  }
        guard typed != finding.asked.untracked() else { return }
        let now = fn() {
          // (closed meanwhile: nothing asked)
          guard finding.chat.untracked() == key else { return }
          match @signals.untracked(thread) {
            Some(th) => find_ask(src, r.station, th, key, list, typed)
            None => ()
          }
        }
        // (none typed: nothing found at once)
        if typed.trim(chars=" ").is_empty() {
          now()
        } else {
          due.val = f.at_moment(f.cause_at() + find_typing_ms, now)
        }
      }
      ask(finding.query)
      @ui.field(
        f,
        finding.field,
        placeholder_by=fn() { @sf.t("web-main.find.placeholder") },
        font_size=14.0,
        line=20.0,
        max_lines=1,
        enter_sends=true,
        colors_by=fn() {
          let p = @sf.theme().p
          (p.text, p.muted, p.accent)
        },
        // Enter: the next one, as it is pressed
        submitted=fn(_) { find_move(src, key, list, 1) },
        edited=fn(words) {
          guard finding.chat.untracked() == key else { return }
          // (a new line put in it otherwise: taken out)
          let typed = words.replace_all(old="\n", new="")
          finding.query = typed
          ask(typed)
        },
      )
      .grow(Is(1.0))
      .basis(Is(Some(0.0)))
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      |> ignore
      // which of how many, or none (nothing found yet while the rest is read is not "nothing found"; nor before the core
      // has said where the reader is among them)
      let counted = fn() {
        let (at, total) = place.get()
        match found.get() {
          Some(_) => !(bringing.get() && total == 0) && !(total > 0 && at == 0)
          None => false
        }
      }
      f.show(counted, fn(n) {
        @sf.style_node(n, fn() { find_count_box }, in_row=true)
        @sf.words_node(
          n,
          fn() {
            let (at, total) = place.get()
            if total > 0 {
              "\{at}/\{total}"
            } else {
              @sf.t("web-main.find.none")
            }
          },
          fn() { find_meta },
        )
        |> ignore
      })
      // (as far apart as makes each a press's room across: @sf.keys_row)
      f.box(fn(k) {
        @sf.style_node(k, fn() { @sf.keys_row(size=find_button_w) }, in_row=true)
        let some = fn() { place.get().1 > 0 }
        find_button_node(k, "chevron-up", fn() { @sf.t("web-main.find.prev") }, some, tips, fn() {
          find_move(src, key, list, -1)
        })
        find_button_node(k, "chevron-down", fn() { @sf.t("web-main.find.next") }, some, tips, fn() {
          find_move(src, key, list, 1)
        })
        find_button_node(k, "close", fn() { @sf.t("web-main.find.close") }, fn() { true }, tips, fn() {
          (list.forget)()
          find_close()
        })
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  made.val.unwrap()
}

///|
/// One of the bar's buttons (find_button's) in `parent`: `icon` (16, the words' ink) in a circle 26 across, the
/// pointer's ground on it; named `label` for a screen reader and in its tip under it; while `on()` is false fainter
/// (half) and not pressed; pressed, `press`.
fn find_button_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  on : () -> Bool,
  tips : @sf.TipLayer,
  press : () -> Unit,
) -> Unit {
  parent.box(fn(b) {
    @sf.presses_node(b, press, on~)
    b
    .width(Is(Some(find_button_w)))
    .height(Is(Some(find_button_w)))
    .min_width(Is(Some(find_button_w)))
    .radius(Is(find_button_w / 2.0))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .alpha(By(fn() { if on() { 1.0 } else { find_button_faint } }))
    .says(By(fn() { Some(@view.said(Button, label=label())) }))
    |> ignore
    @sf.hover_ground_node(b, on~)
    @sf.icon_node(b, icon, 16.0, By(fn() { @sf.theme().p.text })) |> ignore
    @sf.tip_node(tips, b, label, side=Bottom) |> ignore
  })
  |> ignore
}

///|
/// How faint a button of the bar that does nothing now is (find_button_off's O50).
let find_button_faint : Double = 0.5

///|
/// How long the bar takes to come, and to go (kit's tip_in, as find_bar's @motion.entering), the chat's buttons as long
/// coming back in its place (chat_bar_wide_node's).
pub let find_in_ms : Double = 120.0
