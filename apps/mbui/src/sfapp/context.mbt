// An agent's context by hand, between turns (openContext):
// its context's tile in the agent's card opens, a step further in from the card (the card closed for it: the
// presenters' step, its back key back to the card), what compacts it (its chat is told when it is done) or clears it
// (asked first in a sheet of its own): its next message starts a new session. Over them, how often its runtime session
// compacted it, where it has (the core's card: views/brief.ts `card`).

///|
/// What is under way or failed of `call` on `key`'s session (the core's doing, as AppState.isDoing has it).
fn context_key(call : String, station : String, key : String) -> String {
  call + "/" + station + "/" + key
}

///|
/// What can be done to its context from its tile: opens it; under way or failed, said
/// where the tile's › is; `compacts`: it can be compacted.
priv struct ContextTile {
  open : () -> Unit
  busy : Bool
  failed : Bool
  compacts : Bool
}

///|
/// The card's entry for its context (canCompact, canClear) as its session `s` says it now, read in node `v`: none when
/// nothing can be done to it; opened, the card closed (`close`) for it, a step further in from it.
fn context_entry_node(v : @view.View, src : Source, r : ChatRef, key : String, s : () -> Json?, close : () -> Unit) -> () -> ContextTile? {
  let compacting = context_key("session.compact", r.station, key)
  let clearing = context_key("session.clear", r.station, key)
  let compact_failed = @sfbase.failed_lately_node(v, compacting)
  let clear_failed = @sfbase.failed_lately_node(v, clearing)
  fn() {
    let sv = s()
    if !flag(sv, "canCompact") && !flag(sv, "canClear") {
      return None
    }
    Some({
      open: fn() {
        close()
        open_context(src, r, key)
      },
      busy: doing(compacting) || doing(clearing),
      failed: compact_failed() || clear_failed(),
      compacts: flag(sv, "canCompact"),
    })
  }
}

///|
/// What can be done to its context by hand, the library's panel (nodes of the window's tree, made once as it opens:
/// @sf.panel_nodes): compacted, or cleared (asked first: @sf.confirm); each row there while its session says it can.
fn open_context(src : Source, r : ChatRef, key : String) -> Unit {
  @sf.panel_nodes(tr("web-pages.chat.context"), from=Unanchored, fn(v, close) {
    let s = fn() { field(agent_json(src.topic("chat", chat_params(r)).get().value, key), "session") }
    let params = fn() -> Json { { "station": Json::string(r.station), "key": Json::string(key) } }
    let compacted = fn() {
      let card = src.topic("agentCard", { "station": Json::string(r.station), "key": Json::string(key) }).get().value
      text(field(card, "context"), "compacted")
    }
    // (quiet, at the rows' words' start: none of them, and no press)
    v.show(fn() { compacted() != "" }, fn(n) {
      n.padding(By(fn() { if !@sf.in_dialog_node(n) { (12.0, 0.0, 12.0, 0.0) } else { (0.0, 0.0, 0.0, 0.0) } })) |> ignore
      @sf.words_node(n, compacted, fn() { context_compacted_words }) |> ignore
    })
    v.show(fn() { flag(s(), "canCompact") }, fn(row) {
      @sf.choice_row_node(
        row,
        fn() { tr("web-pages.chat.compact") },
        fn() { false },
        note=fn() { tr("web-mobile.agent.compactSub") },
        press=fn() {
          close()
          act(src, tr("web-pages.chat.compact"), context_key("session.compact", r.station, key), "session.compact", params(), done=tr("web-mobile.agent.compacting"))
        },
      )
    })
    v.show(fn() { flag(s(), "canClear") }, fn(row) {
      @sf.choice_row_node(
        row,
        fn() { tr("web-pages.chat.clear") },
        fn() { false },
        note=fn() { tr("web-mobile.agent.clearSub") },
        ink=fn() { @sf.theme().p.red },
        press=fn() {
          close()
          // asked first: the row shows it under way, a failure said by a toast
          @sf.confirm(tr("web-pages.chat.clearConfirm"), tr("web-pages.chat.clearBody"), tr("web-pages.chat.clear"), danger=true, fn() {
            @ui.haptic(Confirm)
            act(src, tr("web-pages.chat.clear"), context_key("session.clear", r.station, key), "session.clear", params())
          })
        },
      )
    })
  })
}

///|
/// How often its runtime session compacted it, over the panel's rows: a note's size, muted.
// kept across runs: a value (no field of it changes)
let context_compacted_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)
