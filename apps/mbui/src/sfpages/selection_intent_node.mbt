// Experimental selection intent inference panel: shows the selected passage, the lightweight model's inferred intent,
// and its direct reply, with actions to copy the reply or quote the passage into the composer draft.

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
    @sf.t("web-main.chat.inferIntent.title"),
    fn(v, _) { selection_intent_body(v, src) },
    from~,
    live=fn() { (@sf.t("web-main.chat.inferIntent.title"), "", "") },
    foot=fn(v, close) { selection_intent_foot(v, src, close) },
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
  v.box(fn(col) {
    @sf.style_node(col, fn() { intent_column })
    // Selected passage preview
    col.box(fn(q) {
      @sf.style_node(q, fn() { intent_quote_box })
      @sf.words_node(q, fn() { s.selection.get() }, fn() { intent_quote_words }) |> ignore
    })
    |> ignore
    // Result area: loading / error / inferred intent + reply
    col.pick(
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
          Ready => {
            area.show(fn() { s.intent.get() != "" }, at_once=true, fn(box) {
              @sf.style_node(box, fn() { intent_section })
              @sf.words_node(box, fn() { @sf.t("web-main.chat.inferIntent.intentLabel") }, fn() { intent_label_words })
              |> ignore
              @sf.words_node(box, fn() { s.intent.get() }, fn() { intent_summary_words }) |> ignore
            })
            area.box(fn(box) {
              @sf.style_node(box, fn() { intent_section })
              @sf.words_node(box, fn() { @sf.t("web-main.chat.inferIntent.replyLabel") }, fn() { intent_label_words })
              |> ignore
              @sf.words_node(box, fn() { s.reply.get() }, fn() { intent_reply_words }) |> ignore
            })
            |> ignore
            area.show(fn() { s.model.get() != "" }, at_once=true, fn(m) {
              @sf.words_node(
                m,
                fn() { @sf.t("web-main.chat.inferIntent.model", args=[("model", s.model.get())]) },
                fn() { intent_meta_words },
              )
              |> ignore
            })
          }
        }
      },
    )
  })
  |> ignore
}

///|
fn selection_intent_foot(v : @view.View, src : Source, close : () -> Unit) -> Unit {
  let s = @sfbase.selection_intent
  @sf.button_node(
    v,
    fn() { @sf.t("web-main.chat.inferIntent.quoteToDraft") },
    fn() {
      let text = @signals.untracked(fn() { s.selection.get() })
      let draft = @signals.untracked(fn() { s.draft.get() })
      let author = @signals.untracked(fn() { s.author.get() })
      let ts = @signals.untracked(fn() { s.message_ts.get() })
      let role = @signals.untracked(fn() { s.role.get() })
      if text != "" && draft != "" {
        @sfbase.writing_quote(src, @sfbase.writing(src, draft), {
          "author": Json::string(author),
          "text": Json::string(text),
          "ts": Json::string(ts),
          "role": Json::string(role),
        })
      }
      close()
    },
    tone=Ghost,
  )
  |> ignore
  @sf.button_node(
    v,
    fn() { @sf.t("web-main.chat.inferIntent.copyReply") },
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
// kept across runs: a value (no field of it changes)
let intent_column : @ui.Style = @ui.css("w=Full gap=S3")

///|
// kept across runs: a value (no field of it changes)
let intent_section : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let intent_quote_box : @ui.Style = @ui.css("w=Full px=S3 py=S2 radius=Md bg=Neutral border=B1 border_color=Line")

///|
// kept across runs: a value (no field of it changes)
let intent_quote_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let intent_loading_row : @ui.Style = @ui.css("row w=Full gap=S2 py=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let intent_retry_row : @ui.Style = @ui.css("row w=Full")

///|
// kept across runs: a value (no field of it changes)
let intent_label_words : @ui.TextStyle = @ui.text_style(size=Caption, weight=Medium, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let intent_summary_words : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let intent_reply_words : @ui.TextStyle = @ui.text_style(size=Body, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let intent_meta_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let intent_error_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, w=Full)
