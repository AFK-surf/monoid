// A quote in a message as nodes of the window's tree (quote_card's, a message's: not the composer's, its styles the
// same): the passage, two lines at most, small and quiet after a quote's mark and whose it is (a page's or an image's
// mark: its pin's number and its first line instead); its own picture under it; what is said about it. Where it leads
// to its message, its words in the text's ink under the pointer, a tip saying so, a press going there.

///|
/// One quote of a message (quote_card's) in `parent`, as what it is given says as that changes: `author`'s `words`
/// (`role` a page's or an image's mark: its pin), what is said about it (`comment`, "" none). Where it `jumps` (where it
/// leads and the message it quotes is said), pressed it does `jump`, its tip says so and its words take the text's ink
/// under the pointer; a pin's that does not, its tip its words whole. Its picture, where it `pictured`, made by
/// `picture` in its foot's corners (quote_picture's room). Its words are none of what is picked where what holds it has
/// its words picked (lent a picker that picks none: the old card's were not of what is picked). The card's node.
#callsite(autofill(loc))
pub fn quote_card_node(
  parent : @view.View,
  tips : TipLayer,
  author : () -> String,
  words : () -> String,
  role : () -> String,
  comment : () -> String,
  jumps : () -> Bool,
  jump : () -> Unit,
  pictured? : () -> Bool = fn() { false },
  picture? : (@view.View) -> Unit = fn(_) {  },
  loc~ : SourceLoc,
) -> @view.View {
  let pin = fn() { pin_of(author(), role()) }
  parent.box(made_for=loc, fn(card) {
    style_node(card, fn() { quote_box_message.then(@ui.style(clip=true)) })
    // (its words none of what is picked: what holds the list lends its picker to every words in pieces in it)
    card.lends(@view.runs_picker, fn(_) { Is((0, 0)) }) |> ignore
    quote_source_node(card, tips, author, words, pin, jumps, jump, fn() {
      if pin() != "" {
        quote_source_pin
      } else {
        quote_source
      }
    })
    card.show(pictured, fn(b) {
      style_node(b, fn() { quote_picture })
      picture(b)
    })
    card.show(fn() { comment() != "" }, fn(b) {
      style_node(b, fn() { quote_comment })
      words_node(b, comment, fn() { quote_said }) |> ignore
    })
  })
}

///|
/// A quote card's head (its source) in `card`: its mark and whose it is (a pin's number and first line instead), laid
/// out by `look` (a message's or the composer's room round it); where it `jumps`, pressed it does `jump`, its tip says
/// so and its words take the text's ink under the pointer; a pin's that does not, its tip its words whole.
#callsite(autofill(loc))
fn quote_source_node(
  card : @view.View,
  tips : TipLayer,
  author : () -> String,
  words : () -> String,
  pin : () -> String,
  jumps : () -> Bool,
  jump : () -> Unit,
  look : () -> @ui.Style,
  loc~ : SourceLoc,
) -> Unit {
  card.box(made_for=loc, fn(source) {
    // (a pin in its top corner: there the ladder's inset from both its edges, concentric with it)
    style_node(source, look)
    // (where it leads nowhere, a pin's tip says its words whole, shown by the pointer within it: tip_node's `within`,
    // what is pressed in it taking no press then)
    tip_node(tips, source, fn() { if !jumps() && pin() != "" { words() } else { "" } }, within=true) |> ignore
    // (what is pressed where it leads: all of its words' box, laid over it (what is pressed found past its words,
    // which take none); taking no press where it leads nowhere, and so not the words' box itself, whose tip a pin's
    // words have then)
    // (where it leads, mbui's headless button over all of it (button_while_node: no box of its own, the pick's laid
    // over it), its tip saying where, as a control's; lit, its words take the text's ink. `hit`: the button as it is
    // now, made before the words' ink reads it (the pick asked for first, so made again first as jumps() changes);
    // a Ref, setting it wakes nothing: what reads it reads jumps() and the button's hand, signals both)
    let hit : Ref[@view.View?] = Ref(None)
    button_while_node(
      source,
      jumps,
      fn() { t("web-main.quote.jump") },
      fn(_) { jump() },
      fn(b, pressed) {
        hit.val = if pressed { Some(b) } else { None }
        if pressed {
          tip_node(tips, b, fn() { t("web-main.quote.jump") }) |> ignore
        }
      },
      fills=true,
      over=true,
      plain=false,
    )
    // (its words' row, made anew as it comes to be a pin's or not: the pick's own box is the row, as quote_words')
    source.pick(fn() { pin() != "" }, fn(p, pinned) {
      style_node(p, fn() { quote_words })
      if pinned {
        p.box(fn(mark) {
          style_node(mark, fn() { quote_pin })
          // (its number part of a mark of a size said: at its size whatever the system's size of words, as a
          // badge's, apps/mbui/AGENTS.md; the old pin's grew out of it at 1.3, the coordinator of the migration,
          // 2026-11-12)
          mark_words_node(mark, pin, fn() { quote_pin_words }) |> ignore
        })
        |> ignore
        words_node(p, fn() { words().split("\n").next().map(fn(s) { s.to_owned() }).unwrap_or("") }, fn() {
          quote_text
        })
        |> ignore
      } else {
        p.box(fn(mark) {
          style_node(mark, fn() { quote_mark })
          icon_node(mark, "quote-open", quote_icon, By(fn() { theme().p.accent })) |> ignore
        })
        |> ignore
        let look = fn() {
          if jumps() && (match hit.val { Some(b) => b.alive() && lit_node(b); None => false }) {
            quote_text_hot
          } else {
            quote_text
          }
        }
        // (beside its mark, in the room the row leaves it, as an old view's words in a row are)
        p.box(fn(w) {
          w
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          .words_runs(By(fn() {
            [
              @ui.span(t("web-main.quote.author", args=[("author", author())]), weight=500, color=theme().p.text),
              @ui.span(words()),
            ]
          }))
          .words_look(By(fn() { @ui.style_words(quote_text) }))
          .ink(By(fn() { @ui.style_ink(look()) }))
          .allow_ellipsis(Is(true))
          |> ignore
        })
        |> ignore
      }
    })
  })
  |> ignore
}

///|
/// A quote waiting in the composer (quote_card's `composer`) in `parent`: as a message's card, its corner the
/// composer's inner, its words further in, leading nowhere; its own picture where it `pictured` (`picture` makes it, in
/// the composer's room for it); under it the line for what is said about it, made by `comment_field`; its ✕ hung on its
/// corner (with_corner_remove_node), `remove` what a press on it does, named `remove_label`. `whole`: given what holds
/// the card and its ✕ as one, its ground and corners the card's (what flies as one card, ✕ and all, says so on it:
/// mbui's View::shared). The card's node.
#callsite(autofill(loc))
pub fn composer_quote_card_node(
  parent : @view.View,
  tips : TipLayer,
  author : () -> String,
  words : () -> String,
  role : () -> String,
  comment_field : (@view.View) -> Unit,
  remove : () -> Unit,
  remove_label : () -> String,
  pictured? : () -> Bool = fn() { false },
  picture? : (@view.View) -> Unit = fn(_) {  },
  whole? : (@view.View) -> Unit = fn(_) {  },
  loc~ : SourceLoc,
) -> @view.View {
  let pin = fn() { pin_of(author(), role()) }
  let made : Ref[@view.View?] = Ref(None)
  let held = with_corner_remove_node(parent, remove_label, composer_inner(), fn(hung) {
    hung.box(made_for=loc, fn(card) {
      made.val = Some(card)
      // (its ground and corners what holds it and its ✕ draws, below: one box, which a flight of them goes as)
      style_node(card, fn() { @ui.style(w=Full, radius=composer_inner_radius(), clip=true) })
      card.lends(@view.runs_picker, fn(_) { Is((0, 0)) }) |> ignore
      quote_source_node(card, tips, author, words, pin, fn() { false }, fn() {  }, fn() {
        if pin() != "" {
          quote_source_hung_pin
        } else {
          quote_source_hung
        }
      })
      card.show(pictured, fn(b) {
        style_node(b, fn() { quote_picture_composer })
        picture(b)
      })
      card.box(fn(b) {
        style_node(b, fn() { quote_comment_composer })
        comment_field(b)
      })
      |> ignore
    })
    |> ignore
  // (as wide as what waits in the composer is, its ✕ reaching past its end into the room round it, as the old
  // composer's quote_card: no room kept for it at its end)
  }, remove, hung=false)
  // (what holds the card and its ✕, as big as the card: the card's ground and corners, the one box a flight of the two
  // goes as)
  style_node(held, fn() { quote_box_composer().then(composer_card()).then(@ui.style(clip=false)) })
  whole(held)
  made.val.unwrap()
}
