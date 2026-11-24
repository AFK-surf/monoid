// Experimental selection intent inference panel and pinned reply cards:
// shows only the inferred reply directly ("I'm feeling lucky" style), with Pin and Copy actions.

///|
fn open_selection_intent(
  src : Source,
  r : ChatRef,
  thread : Double,
  draft : String,
  selection : String,
  message_ts : String,
  author : String,
  role : String,
  from~ : @sf.Anchor,
) -> Unit {
  @sfbase.selection_intent_ask(src, r.station, thread, draft, selection, message_ts, author, role)
  @sf.panel_nodes(
    "",
    fn(v, _) { selection_intent_body(v, src) },
    from~,
    heads_itself=true,
    foot=fn(v, close) { selection_intent_foot(v, close) },
    gone=fn() { @sfbase.selection_intent_reset() },
  )
}

///|
#derive(Eq)
priv enum IntentViewKind {
  Loading
  Failed
  Ready
}

///|
fn selection_intent_body(v : @view.View, src : Source) -> Unit {
  let s = @sfbase.selection_intent
  v.pick(
    fn() {
      if s.loading.get() {
        IntentViewKind::Loading
      } else if s.error.get() != "" {
        IntentViewKind::Failed
      } else {
        IntentViewKind::Ready
      }
    },
    fn(area, kind) {
      @sf.style_node(area, fn() { intent_column })
      match kind {
        Loading =>
          area.box(fn(row) {
            @sf.style_node(row, fn() { intent_loading_row })
            @sf.spinner_node(row, size=14.0) |> ignore
            @sf.words_node(row, fn() { @sf.t("web-main.chat.inferIntent.loading") }, fn() { intent_meta_words })
            |> ignore
          })
          |> ignore
        Failed => {
          @sf.words_node(area, fn() { s.error.get() }, fn() { intent_error_words }) |> ignore
          area.box(fn(row) {
            @sf.style_node(row, fn() { intent_retry_row })
            @sf.button_node(
              row,
              fn() { @sf.t("web-main.chat.inferIntent.retry") },
              fn() { @sfbase.selection_intent_retry(src) },
              tone=Ghost,
            )
            |> ignore
          })
          |> ignore
        }
        Ready => @sf.words_node(area, fn() { s.reply.get() }, fn() { intent_reply_words }) |> ignore
      }
    },
  )
}

///|
fn selection_intent_foot(v : @view.View, close : () -> Unit) -> Unit {
  let s = @sfbase.selection_intent
  @sf.button_node(
    v,
    fn() { @sf.t("web-main.chat.inferIntent.pin") },
    fn() {
      if @sfbase.selection_intent_pin() {
        @sfbase.toast_later(@sf.t("web-main.chat.inferIntent.pinned"))
        close()
      }
    },
    tone=Ghost,
    icon="pin",
    disabled=fn() { s.loading.get() || s.reply.get() == "" },
  )
  |> ignore
  @sf.button_node(
    v,
    fn() { @sf.t("common.copy") },
    fn() {
      let reply = @signals.untracked(fn() { s.reply.get() })
      if reply != "" {
        @sfbase.copy_out(reply, said=@sf.t("common.copied"))
      }
    },
    tone=Primary,
    disabled=fn() { s.loading.get() || s.reply.get() == "" },
  )
  |> ignore
}

///|
/// Floating stack of pinned selection-intent reply cards in chat `draft`.
fn pinned_intents_node(v : @view.View, _src : Source, draft : String) -> Unit {
  v.show(
    fn() { @sfbase.selection_intent_feature.get() && @sfbase.pinned_intents_for(draft).length() > 0 },
    at_once=true,
    fn(layer) {
      layer.over(Is(true)) |> ignore
      @sf.style_node(layer, fn() { intent_pins_layer })
      layer.pick(fn() { @sfbase.pinned_intents_for(draft) }, fn(stack, list) {
        @sf.style_node(stack, fn() { intent_pins_stack })
        for p in list {
          pinned_intent_card(stack, p)
        }
      })
    },
  )
}

///|
fn pinned_intent_card(parent : @view.View, p : @sfbase.PinnedIntent) -> Unit {
  let id = p.id
  parent.box(fn(card) {
    @sf.style_node(card, fn() { intent_pin_card })
    @sf.glass_capsule_node(card, radius=Some(@sf.card_corner), panel=true) |> ignore
    // (its head's last key in its top right corner, concentric with the card's: as far in from the top and the right
    // as the card's corner is round past the key's)
    let corner_in = @sf.card_corner - intent_pin_btn / 2.0
    card.padding(Is((intent_pin_side_in, corner_in, corner_in, intent_pin_side_in))) |> ignore
    card.box(fn(head) {
      @sf.style_node(head, fn() { intent_pin_head })
      @sf.icon_node(head, "pin", intent_pin_icon, By(fn() { @sf.theme().p.accent_text })) |> ignore
      head.box(fn(t) {
        @sf.style_node(t, fn() { intent_pin_title_wrap }, in_row=true)
        if p.collapsed {
          @sf.words_node(t, fn() { p.reply }, fn() { intent_pin_preview }) |> ignore
        }
      })
      |> ignore
      @sf.icon_button_node(
        head,
        if p.collapsed { "chevron-down" } else { "chevron-up" },
        fn() { @sf.t(if p.collapsed { "web-main.chat.inferIntent.expand" } else { "web-main.chat.inferIntent.collapse" }) },
        fn() { @sfbase.selection_intent_toggle_collapse(id) },
        size=intent_pin_btn,
        icon_size=intent_pin_icon,
      )
      |> ignore
      @sf.icon_button_node(
        head,
        "copy",
        fn() { @sf.t("common.copy") },
        fn() { @sfbase.copy_out(p.reply, said=@sf.t("common.copied")) },
        size=intent_pin_btn,
        icon_size=intent_pin_icon,
      )
      |> ignore
      @sf.icon_button_node(
        head,
        "close",
        fn() { @sf.t("web-main.chat.inferIntent.unpin") },
        fn() { @sfbase.selection_intent_unpin(id) },
        size=intent_pin_btn,
        icon_size=intent_pin_icon,
      )
      |> ignore
    })
    |> ignore
    if !p.collapsed {
      @sf.words_node(card, fn() { p.reply }, fn() { intent_reply_words }) |> ignore
    }
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let intent_column : @ui.Style = @ui.css("w=Full pt=S2 pb=S1 gap=S2")

///|
// kept across runs: a value (no field of it changes)
let intent_loading_row : @ui.Style = @ui.css("row w=Full gap=S2 py=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let intent_retry_row : @ui.Style = @ui.css("row w=Full")

///|
// kept across runs: a value (no field of it changes)
let intent_reply_words : @ui.TextStyle = @ui.text_style(size=Body, color=Fg, leading=L5, w=Full)

///|
// kept across runs: a value (no field of it changes)
let intent_meta_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let intent_error_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, w=Full)

///|
// kept across runs: a value (no field of it changes)
let intent_pins_layer : @ui.Style = @ui.css("w=Full px=S5 pt=S16 align=AEnd")

///|
// kept across runs: a value (no field of it changes)
let intent_pins_stack : @ui.Style = @ui.css("gap=S2_5 align=AEnd")

///|
// kept across runs: a value (no field of it changes)
let intent_pin_card : @ui.Style = @ui.style(w=Fixed(@sf.panel_w), gap=S2, radius=Xl)

///|
/// How far a pinned answer's words are in from its card's left and foot.
let intent_pin_side_in : Double = 16.0

///|
// kept across runs: a value (no field of it changes)
let intent_pin_head : @ui.Style = @ui.css("row w=Full gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let intent_pin_title_wrap : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let intent_pin_preview : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Full)

///|
let intent_pin_btn : Double = 26.0

///|
let intent_pin_icon : Double = 14.0
