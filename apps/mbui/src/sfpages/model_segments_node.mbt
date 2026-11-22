// Unified segmented model display for tight spaces: steps down from full name to short name,
// then drops effort (with its leading `·`), then drops the short name — without mid-word ellipsis
// unless `cuts_last=true` (model picker last resort).

///|
/// Static segmented model name inside a `fits` row (zero extra `pick`/`show` wrappers for keyed `each` items):
/// - When `short` is non-empty and differs from `full`, renders a `one_of` row with
///   `[full (drop=drop_short), short (drop=drop_hide)]`.
/// - Otherwise renders a single text node `full (drop=drop_hide)`.
pub fn model_name_segments_static(
  parent : @view.View,
  full : String,
  short : String,
  look : () -> @ui.TextStyle,
  ink? : (() -> Int64)? = None,
  drop_short? : Int = 1,
  drop_hide? : Int = 0,
  cuts_last? : Bool = false,
  fit_whole? : Bool = false,
) -> Unit {
  let text_ink = match ink {
    Some(f) => f
    None => fn() { @ui.style_ink(look()) }
  }
  if short != "" && short != full {
    parent.box(fn(o) {
      o
      .row(Is(true))
      .one_of(Is(true))
      .lines_up(Is(Some(Middle)))
      .shrink(Is(if cuts_last { 1.0 } else { 0.0 }))
      |> ignore
      if cuts_last {
        o.min_width(Is(Some(0.0))) |> ignore
      }
      if fit_whole {
        o.fit_whole(Is(true)) |> ignore
      }
      o.box(fn(w) {
        w
        .words(Is(full))
        .words_look(By(fn() { @ui.style_words(look()) }))
        .ink(By(text_ink))
        .shrink(Is(0.0))
        .drops(Is(drop_short))
        |> ignore
      })
      |> ignore
      o.box(fn(w) {
        w
        .words(Is(short))
        .words_look(By(fn() { @ui.style_words(look()) }))
        .ink(By(text_ink))
        .shrink(Is(if cuts_last { 1.0 } else { 0.0 }))
        |> ignore
        if drop_hide > 0 {
          w.drops(Is(drop_hide)) |> ignore
        }
        if cuts_last {
          w.min_width(Is(Some(0.0))).cuts(Is(true)).allow_ellipsis(Is(true)) |> ignore
        }
        if fit_whole {
          w.fit_whole(Is(true)) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  } else {
    parent.box(fn(w) {
      w
      .words(Is(full))
      .words_look(By(fn() { @ui.style_words(look()) }))
      .ink(By(text_ink))
      .shrink(Is(if cuts_last { 1.0 } else { 0.0 }))
      |> ignore
      if drop_hide > 0 {
        w.drops(Is(drop_hide)) |> ignore
      }
      if cuts_last {
        w.min_width(Is(Some(0.0))).cuts(Is(true)).allow_ellipsis(Is(true)).fit_whole(Is(true)) |> ignore
      }
      if fit_whole {
        w.fit_whole(Is(true)) |> ignore
      }
    })
    |> ignore
  }
}

///|
/// Reactive segmented model name for controls whose model can change in place (e.g. `model_triple_node`).
pub fn model_name_segments_node(
  parent : @view.View,
  full : () -> String,
  short : () -> String,
  look : () -> @ui.TextStyle,
  ink? : (() -> Int64)? = None,
  drop_short? : Int = 1,
  drop_hide? : Int = 0,
  cuts_last? : Bool = false,
  fit_whole? : Bool = false,
) -> Unit {
  parent.pick(at_once=true, fn() { (full(), short()) }, fn(slot, fs) {
    slot
    .row(Is(true))
    .fits(Is(true))
    .lines_up(Is(Some(Middle)))
    .shrink(Is(if cuts_last { 1.0 } else { 0.0 }))
    |> ignore
    if cuts_last {
      slot.min_width(Is(Some(0.0))) |> ignore
    }
    if fit_whole {
      slot.fit_whole(Is(true)) |> ignore
    }
    model_name_segments_static(slot, fs.0, fs.1, look, ink~, drop_short~, drop_hide~, cuts_last~, fit_whole~)
  })
}

///|
/// Static segmented agent label (`model_name` + optional `· effort`) inside a `fits` row:
/// degrades in order `full · effort` -> `short · effort` (`drop_short`) -> `short` (`drop_effort`) -> hidden (`drop_hide`).
/// Falls back to `fallback_who` when `model_name == ""` (legacy fixtures/replays).
pub fn model_agent_segments_static(
  parent : @view.View,
  model_name : String,
  model_short : String,
  effort : String,
  fallback_who : String,
  look : () -> @ui.TextStyle,
  ink? : (() -> Int64)? = None,
  drop_short? : Int = 1,
  drop_effort? : Int = 2,
  drop_hide? : Int = 3,
  cuts_last? : Bool = false,
) -> Unit {
  let text_ink = match ink {
    Some(f) => f
    None => fn() { @ui.style_ink(look()) }
  }
  if model_name != "" {
    model_name_segments_static(
      parent,
      model_name,
      model_short,
      look,
      ink~,
      drop_short~,
      drop_hide~,
      cuts_last~,
      fit_whole=cuts_last,
    )
    if effort != "" {
      let eff_label = "· " + effort_text(effort)
      parent.box(fn(ef) {
        ef
        .words(Is(eff_label))
        .words_look(By(fn() { @ui.style_words(look()) }))
        .ink(By(text_ink))
        .shrink(Is(0.0))
        .drops(Is(drop_effort))
        |> ignore
      })
      |> ignore
    }
  } else if fallback_who != "" {
    parent.box(fn(w) {
      w
      .words(Is(fallback_who))
      .words_look(By(fn() { @ui.style_words(look()) }))
      .ink(By(text_ink))
      .shrink(Is(if cuts_last { 1.0 } else { 0.0 }))
      |> ignore
      if drop_hide > 0 {
        w.drops(Is(drop_hide)) |> ignore
      }
      if cuts_last {
        w.min_width(Is(Some(0.0))).cuts(Is(true)).allow_ellipsis(Is(true)).fit_whole(Is(true)) |> ignore
      }
    })
    |> ignore
  }
}

///|
/// Reactive segmented agent label (`model_name` + optional `· effort`) for views whose agent changes in place
/// (e.g. `history_head_node`).
pub fn model_agent_segments_node(
  parent : @view.View,
  model_name : () -> String,
  model_short : () -> String,
  effort : () -> String,
  fallback_who : () -> String,
  look : () -> @ui.TextStyle,
  ink? : (() -> Int64)? = None,
  drop_short? : Int = 1,
  drop_effort? : Int = 2,
  drop_hide? : Int = 0,
  cuts_last? : Bool = false,
) -> Unit {
  parent.pick(at_once=true, fn() { (model_name(), model_short(), effort(), fallback_who()) }, fn(slot, cur) {
    slot.row(Is(true)).fits(Is(true)).gap(Is(4.0)).lines_up(Is(Some(Middle))).shrink(Is(1.0)).min_width(Is(Some(0.0)))
    |> ignore
    model_agent_segments_static(
      slot,
      cur.0,
      cur.1,
      cur.2,
      cur.3,
      look,
      ink~,
      drop_short~,
      drop_effort~,
      drop_hide~,
      cuts_last~,
    )
  })
}
