// The library's specimen: every part in its states, on a wide window (two columns) and a narrow one (one), what
// src/shots draws offscreen for people to look at and what the tests hold to mbui's audit. Its state is its own
// signals, made anew with each page, so a press in a film or a test changes what it shows as it would in an app.

///|
/// What the specimen's controls hold.
priv struct State {
  period : @signals.Signal[Int]
  sync : @signals.Signal[Bool]
  drafts : @signals.Signal[Bool]
  digest : @signals.Signal[Bool]
  saved : @signals.Signal[Int]
}

///|
fn State::new() -> State {
  {
    period: @signals.signal(1),
    sync: @signals.signal(true),
    drafts: @signals.signal(true),
    digest: @signals.signal(false),
    saved: @signals.signal(0),
  }
}

///|
/// The specimen in `root`: `wide` its two columns (a desktop's window), else one (a phone's). Its theme is said for
/// mbui's parts that draw by it.
pub fn page(root : @view.View, wide? : Bool = true) -> Unit {
  @ui.set_tree_theme(@appui.ui_theme)
  let s = State::new()
  root.box(fn(p) {
    p
    .grow(Is(1.0))
    .padding(Is(if wide { gutter_all(@appui.G32) } else { gutter_all(@appui.G24) }))
    .gap(Is(@appui.S16.pt()))
    .ground(By(fn() { @appui.palette().canvas }))
    |> ignore
    p.box(fn(h) {
      h.gap(Is(@appui.S4.pt())) |> ignore
      @appui.text_node(h, fn() { "Components" }, Title, fn() { @appui.palette().ink }, weight=@appui.weight_medium)
      |> ignore
      @appui.text_node(
        h,
        fn() { "Dense, adaptive parts on one spacing scale, concentric corners and two weights." },
        Body,
        fn() { @appui.palette().muted },
        wrap=true,
      )
      |> ignore
    })
    |> ignore
    if wide {
      p.box(fn(cols) {
        cols.row(Is(true)).gap(Is(@appui.S16.pt())).lines_up(Is(Some(Start))) |> ignore
        column(cols, fn(c) {
          buttons_card(c, s)
          controls_card(c, s)
        })
        column(cols, fn(c) {
          inbox_card(c, s)
          confirm_card(c, s)
          drafts_card(c, s)
        })
      })
      |> ignore
    } else {
      inbox_card(p, s)
      confirm_card(p, s)
      drafts_card(p, s)
    }
  })
  |> ignore
}

///|
fn gutter_all(g : @appui.Gutter) -> (Double, Double, Double, Double) {
  (g.pt(), g.pt(), g.pt(), g.pt())
}

///|
/// One of the wide page's two columns, as wide as the other.
fn column(parent : @view.View, make : (@view.View) -> Unit) -> Unit {
  parent.box(fn(c) {
    c.grow(Is(1.0)).basis(Is(Some(0.0))).gap(Is(@appui.S16.pt())) |> ignore
    make(c)
  })
  |> ignore
}

///|
/// The buttons: each intent at each size, then an icon before and after, at work, disabled.
fn buttons_card(parent : @view.View, s : State) -> Unit {
  @appui.card(parent, fn(card) {
    @appui.card_head(card, fn() { "Buttons" }) |> ignore
    card.box(fn(c) {
      c.padding(Is(@appui.pad(S8, S0, S8, S8))).gap(Is(@appui.S12.pt())) |> ignore
      // (the first of them what the keyboard's first Tab comes to: its focus ring)
      for size in [@appui.Lg, @appui.Sm, @appui.Xs] {
        c.box(fn(r) {
          r.row(Is(true)).gap(Is(@appui.S8.pt())).lines_up(Is(Some(Middle))).wraps(Is(Some(@appui.S8.pt()))) |> ignore
          @appui.button(r, fn() { "Save" }, fn() { s.saved.set(s.saved.get() + 1) }, intent=Primary, size~) |> ignore
          @appui.button(r, fn() { "Cancel" }, fn() {  }, intent=Secondary, size~) |> ignore
          @appui.button(r, fn() { "Skip" }, fn() {  }, intent=Ghost, size~) |> ignore
          @appui.button(r, fn() { "Delete" }, fn() {  }, intent=Destructive, size~) |> ignore
          @appui.button(r, fn() { "Search" }, fn() {  }, intent=Ghost, size~, leading=Search, icon_only=true)
          |> ignore
        })
        |> ignore
      }
      c.box(fn(r) {
        r.row(Is(true)).gap(Is(@appui.S8.pt())).lines_up(Is(Some(Middle))).wraps(Is(Some(@appui.S8.pt()))) |> ignore
        @appui.button(r, fn() { "New issue" }, fn() {  }, intent=Primary, leading=Plus) |> ignore
        @appui.button(r, fn() { "Open" }, fn() {  }, intent=Secondary, trailing=Arrow) |> ignore
        @appui.button(r, fn() { "Saving" }, fn() {  }, intent=Secondary, busy=fn() { true }) |> ignore
        @appui.button(r, fn() { "Archive" }, fn() {  }, intent=Secondary, disabled=fn() { true }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The controls: a segmented choice, and rows each ending in a switch or a checkbox.
fn controls_card(parent : @view.View, s : State) -> Unit {
  @appui.card(parent, fn(c) {
    @appui.card_head(c, fn() { "Controls" }) |> ignore
    c.box(fn(b) {
      b.padding(Is(@appui.pad(S8, S0, S8, S8))) |> ignore
      @appui.segmented(b, fn() { "Period" }, ["Day", "Week", "Month"], fn() { s.period.get() }, fn(i) { s.period.set(i) })
      |> ignore
    })
    |> ignore
    @appui.list_row(c, fn() { "Sync in the background" }, note=fn() { "Keeps every list current while the window is closed." }, trailing=fn(e) {
      @appui.switch_(e, fn() { s.sync.get() }, fn(v) { s.sync.set(v) }, fn() { "Sync in the background" }) |> ignore
    })
    |> ignore
    @appui.list_row(c, fn() { "Show drafts" }, trailing=fn(e) {
      @appui.switch_(e, fn() { s.drafts.get() }, fn(v) { s.drafts.set(v) }, fn() { "Show drafts" }) |> ignore
    })
    |> ignore
    @appui.list_row(c, fn() { "Weekly digest" }, note=fn() { "A summary every Monday." }, trailing=fn(e) {
      @appui.checkbox(e, fn() { s.digest.get() }, fn(v) { s.digest.set(v) }, fn() { "Weekly digest" }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A list of rows of several lines: each icon and what ends it on its first line.
fn inbox_card(parent : @view.View, _s : State) -> Unit {
  @appui.card(parent, fn(c) {
    @appui.card_head(c, fn() { "Inbox" }, note=fn() { "Three things need you today." }) |> ignore
    @appui.list_row(
      c,
      fn() { "Review the onboarding flow" },
      note=fn() { "The second step wraps on narrow windows and its primary action moves; check it keeps its corner." },
      leading=Inbox,
      trailing=fn(e) { @appui.meta(e, fn() { "2h" }, icon=Calendar) |> ignore },
      press=fn() {  },
    )
    |> ignore
    @appui.list_row(
      c,
      fn() { "Rotate the signing keys" },
      note=fn() { "Due before Friday." },
      leading=Alert,
      trailing=fn(e) { @appui.tag(e, fn() { "Urgent" }) |> ignore },
      press=fn() {  },
    )
    |> ignore
    @appui.list_row(c, fn() { "Weekly notes" }, leading=Folder, trailing=fn(e) {
      @appui.meta(e, fn() { "Mon" }) |> ignore
    }, press=fn() {  })
    |> ignore
  })
  |> ignore
}

///|
/// A card asking before something is done, its actions at its foot: the main one at its left corner.
fn confirm_card(parent : @view.View, s : State) -> Unit {
  @appui.card(parent, gap=S6, fn(c) {
    @appui.card_head(c, fn() { "Archive 3 projects?" }, note=fn() {
      "They leave every list and stop sending updates. You can bring them back from Settings."
    })
    |> ignore
    @appui.card_footer(c, fn(f) {
      @appui.button(f, fn() { "Archive projects" }, fn() { s.saved.set(s.saved.get() + 1) }, intent=Primary) |> ignore
      @appui.button(f, fn() { "Keep them" }, fn() {  }, intent=Secondary) |> ignore
      @appui.button(f, fn() { "Remind me later" }, fn() {  }, intent=Ghost) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A column some of whose parts hide (drafts, as the switch says): a line only between two that show.
fn drafts_card(parent : @view.View, s : State) -> Unit {
  @appui.card(parent, fn(c) {
    @appui.divided_column(c, [
      (fn() { true }, fn(v) { @appui.list_row(v, fn() { "Published" }, leading=Check, trailing=fn(e) { @appui.meta(e, fn() { "12" }) |> ignore }) |> ignore }),
      (fn() { s.drafts.get() }, fn(v) { @appui.list_row(v, fn() { "Drafts" }, leading=Folder, trailing=fn(e) { @appui.meta(e, fn() { "4" }) |> ignore }) |> ignore }),
      (fn() { true }, fn(v) { @appui.list_row(v, fn() { "Archived" }, leading=Trash, trailing=fn(e) { @appui.meta(e, fn() { "31" }) |> ignore }) |> ignore }),
    ])
    |> ignore
  })
  |> ignore
}
