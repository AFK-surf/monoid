// Shared sub-chats list (led child chats from `chat_create for: "me"`) rendered as nodes for the Medium/Large
// popover, the right side-panel `subchats` tab, and the Small bottom sheet.

///|
/// Only the chats this chat's agent leads (`led == true`): chats opened for a person (`for: "person"`) are excluded.
pub fn led_subchats(opened : Array[@sfbase.OpenedChat]) -> Array[@sfbase.OpenedChat] {
  opened.filter(fn(o) { o.led })
}

///|
/// Highest-priority status tone across led sub-chats for the bar entry dot: `"fail"` > `"need"` > `"run"` > `""`.
pub fn opened_summary_tone(opened : Array[@sfbase.OpenedChat]) -> String {
  let mut has_need = false
  let mut has_run = false
  for o in opened {
    if !o.led || o.archived {
      continue
    }
    if o.mark == "failed" {
      return "fail"
    }
    if o.state_lead is ("need" | "decision") || o.mark == "block" {
      has_need = true
    } else if o.mark == "run" {
      has_run = true
    }
  }
  if has_need {
    "need"
  } else if has_run {
    "run"
  } else {
    ""
  }
}

///|
/// Count of active led sub-chats currently running (`mark == "run"`).
pub fn subchats_running_count(subchats : Array[@sfbase.OpenedChat]) -> Int {
  let mut n = 0
  for o in subchats {
    if !o.archived && o.mark == "run" {
      n += 1
    }
  }
  n
}

///|
/// Count of active led sub-chats waiting on a person or blocked (`state_lead` is `"need"`/`"decision"` or `mark == "block"`).
pub fn subchats_need_count(subchats : Array[@sfbase.OpenedChat]) -> Int {
  let mut n = 0
  for o in subchats {
    if !o.archived && (o.state_lead is ("need" | "decision") || o.mark == "block") {
      n += 1
    }
  }
  n
}

///|
/// Whether a led sub-chat belongs in the collapsible "Done" group: ended, whether it said done or stopped without a state
/// (idle, aborted). Running, waiting on its own work (`wait`/`watch`), failed, blocked or asking stay in the main list.
pub fn subchat_is_done(o : @sfbase.OpenedChat) -> Bool {
  !o.archived &&
  !(o.mark is ("run" | "failed" | "block")) &&
  !(o.state_lead is ("need" | "decision" | "wait" | "watch"))
}

///|
/// How many of the finished sub-chats a list shows first where none is at work (the latest), the rest behind a press.
pub let subchats_recent_limit : Int = 3

///|
/// Which led sub-chats a list leads with (subchats_list_node, the Small sheet): `0` those at work, while any is; else
/// `1` the done ones; else `2` the archived ones. What it does not lead with folds under it (已完成 under those at
/// work, 已归档 under those or the done ones).
pub fn subchats_lead_kind(subchats : Array[@sfbase.OpenedChat]) -> Int {
  if subchats.iter().any(fn(o) { !o.archived && !subchat_is_done(o) }) {
    0
  } else if subchats.iter().any(fn(o) { subchat_is_done(o) }) {
    1
  } else if subchats.iter().any(fn(o) { o.archived }) {
    2
  } else {
    0
  }
}

///|
/// What a list leads with (subchats_lead_kind's), in order: all of those at work; of the done or archived ones the
/// latest `subchats_recent_limit` unless `more`, then all. With how many past that limit there are (0: none, so no
/// press to show them).
pub fn subchats_lead(subchats : Array[@sfbase.OpenedChat], more : Bool) -> (Array[@sfbase.OpenedChat], Int) {
  match subchats_lead_kind(subchats) {
    0 => (subchats.filter(fn(o) { !o.archived && !subchat_is_done(o) }), 0)
    kind => {
      let all = if kind == 1 { subchats.filter(fn(o) { subchat_is_done(o) }) } else { subchats.filter(fn(o) { o.archived }) }
      let past = all.length() - subchats_recent_limit
      if past <= 0 {
        (all, 0)
      } else if more {
        (all, past)
      } else {
        (all[:subchats_recent_limit].to_owned(), past)
      }
    }
  }
}

///|
/// The words of the press that shows (`more` false) or folds back (`more`) the `n` finished sub-chats past the latest.
pub fn subchats_more_words(n : Int, more : Bool) -> String {
  @sf.t(if more { "web-pages.chat.subchatsLess" } else { "web-pages.chat.subchatsMore" }, args=[("n", n.to_string())])
}

///|
/// Secondary state line for a sub-chat row: hides stale text on archived rows and omits bare "已完成" / "Done" inside
/// the Done group while keeping summary lines such as "已完成：…".
pub fn subchat_row_state_text(o : @sfbase.OpenedChat) -> String {
  if o.archived {
    ""
  } else if subchat_is_done(o) && o.state_text == @sf.t("core-views.present.done") {
    ""
  } else {
    o.state_text
  }
}

///|
/// Secondary line for a search hit: shows message body excerpt (`found_text`) when present (including for archived
/// rows), otherwise falls back to `subchat_row_state_text`.
pub fn subchat_hit_row_text(hit : @sfbase.SubchatHit) -> String {
  if hit.found_text != "" {
    hit.found_text
  } else {
    subchat_row_state_text(hit.opened)
  }
}

///|
/// Local fallback filter over already-loaded `OpenedChat` items by title and state text (used when core has not yet
/// answered `chatSubchats`, or in unit tests without a core `Source`).
pub fn subchats_filter_local(items : Array[@sfbase.OpenedChat], q : String) -> Array[@sfbase.SubchatHit] {
  let words : Array[String] = []
  for part in q.trim().to_lower().split(" ") {
    let w = part.to_owned()
    if w != "" {
      words.push(w)
    }
  }
  if words.is_empty() {
    return items.map(fn(o) { { opened: o, found_text: "", found_marks: [] } })
  }
  let titled : Array[@sfbase.SubchatHit] = []
  let rest : Array[@sfbase.SubchatHit] = []
  for o in items {
    let tl = o.chat.title.to_lower()
    if words.iter().all(fn(w) { tl.contains(w) }) {
      titled.push({ opened: o, found_text: "", found_marks: [] })
    } else {
      let sl = o.state_text.to_lower()
      if words.iter().all(fn(w) { sl.contains(w) }) {
        rest.push({ opened: o, found_text: "", found_marks: [] })
      }
    }
  }
  for r in rest {
    titled.push(r)
  }
  titled
}

///|
/// Reads filtered sub-chats for a non-empty trimmed query `q`: subscribes to `chatSubchats` only when `q != ""` and
/// `src`/`chat` are given, falling back to `subchats_filter_local` before the core answers so typing never flashes empty.
pub fn subchats_search_results(
  src : @sfbase.Source?,
  chat : @sfbase.ChatRef?,
  all_items : () -> Array[@sfbase.OpenedChat],
  include_opened : Bool,
  q : String,
) -> (Array[@sfbase.SubchatHit], Bool) {
  let trimmed = q.trim().to_owned()
  if trimmed == "" {
    return ([], false)
  }
  match (src, chat) {
    (Some(s), Some(r)) => {
      let t = s.topic("chatSubchats", @sfbase.subchats_search_params(r, trimmed)).get()
      match @sfbase.subchats_search_view(t.value) {
        Some(sv) => {
          let hits = if include_opened { sv.items } else { sv.items.filter(fn(h) { h.opened.led }) }
          (hits, sv.reading)
        }
        None => (subchats_filter_local(all_items(), trimmed), true)
      }
    }
    _ => (subchats_filter_local(all_items(), trimmed), false)
  }
}

///|
/// Status mark kind for a sub-chat row: 0=run dot, 1=need dot, 2=fail dot, 3=archived icon, 4=done icon, 5=spawned icon.
pub fn subchat_mark_kind(o : @sfbase.OpenedChat?) -> Int {
  match o {
    Some(o) =>
      if o.archived {
        3
      } else if o.mark == "failed" {
        2
      } else if o.state_lead is ("need" | "decision") || o.mark == "block" {
        1
      } else if o.mark == "run" {
        0
      } else if o.state_lead == "done" {
        4
      } else {
        5
      }
    None => 5
  }
}

///|
/// Live running / waiting counts as separate nodes (never `·`-joined), shared by the popover header and Small sheet `head_end`.
pub fn subchats_counts_node(parent : @view.View, opened : () -> Array[@sfbase.OpenedChat]) -> Unit {
  let subchats = fn() { led_subchats(opened()) }
  let running_count = fn() { subchats_running_count(subchats()) }
  let need_count = fn() { subchats_need_count(subchats()) }
  parent.box(fn(counts) {
    @sf.style_node(counts, fn() { subchats_counts }, in_row=true)
    counts.show(at_once=true, fn() { running_count() > 0 }, fn(rn) {
      @sf.words_node(
        rn,
        fn() { @sf.t("web-pages.chat.subchatsRunning", args=[("n", running_count().to_string())]) },
        fn() { subchats_count_words },
      )
      .ink(By(fn() { @sf.theme().p.green_ink }))
      |> ignore
    })
    // (none at work, the list not empty: said so, quietly, so a look tells nothing runs)
    counts.show(at_once=true, fn() { subchats().length() > 0 && subchats_lead_kind(subchats()) != 0 }, fn(idle) {
      @sf.words_node(idle, fn() { @sf.t("web-pages.chat.subchatsIdle") }, fn() { subchats_count_words })
      .ink(By(fn() { @sf.theme().p.muted }))
      |> ignore
    })
    counts.show(at_once=true, fn() { need_count() > 0 }, fn(nn) {
      @sf.words_node(
        nn,
        fn() { @sf.t("web-pages.chat.subchatsNeed", args=[("n", need_count().to_string())]) },
        fn() { subchats_count_words },
      )
      .ink(By(fn() { @sf.theme().p.warn_ink }))
      |> ignore
    })
  })
  |> ignore
}

///|
/// Shared sub-chats list in `v`: optional header with live running/waiting counts (separate nodes, never `·`-joined),
/// what it leads with first (subchats_lead: those at work; none at work, the latest done ones, the rest behind a press
/// in place; none done either, the archived ones the same), what it does not lead with under it in quiet folding rows
/// (已完成, 已归档: folded until pressed), and optional footer action to open
/// the right side-panel `subchats` tab (`in_panel`). When `scroll_most` is given (Medium/Large popover), the header and
/// footer stay pinned while only the middle list scrolls within `scroll_most()`.
pub fn subchats_list_node(
  v : @view.View,
  opened : () -> Array[@sfbase.OpenedChat],
  src? : @sfbase.Source,
  chat? : @sfbase.ChatRef,
  close? : () -> Unit,
  in_panel? : () -> Unit,
  show_head? : Bool = true,
  scroll_most? : () -> Double,
  fills? : Bool = false,
  include_opened? : Bool = false,
) -> Unit {
  let led = fn() { led_subchats(opened()) }
  let other = fn() { if include_opened { opened().filter(fn(o) { !o.led }) } else { [] } }
  let subchats = fn() {
    let l = led()
    if include_opened && l.is_empty() {
      other()
    } else {
      l
    }
  }
  let extra_other = fn() { if include_opened && !led().is_empty() { other() } else { [] } }
  let all_items = fn() { if include_opened { opened() } else { led() } }
  let done = fn() { subchats().filter(fn(o) { subchat_is_done(o) }) }
  let archived = fn() { subchats().filter(fn(o) { o.archived }) }
  // Folded until pressed; the finished ones led with, the latest until pressed
  let done_open : @signals.Signal[Bool] = @signals.signal(false)
  let archived_open : @signals.Signal[Bool] = @signals.signal(false)
  let other_open : @signals.Signal[Bool] = @signals.signal(false)
  let done_more : @signals.Signal[Bool] = @signals.signal(false)
  let archived_more : @signals.Signal[Bool] = @signals.signal(false)
  let lead_kind = fn() { subchats_lead_kind(subchats()) }
  let more_of = fn(kind : Int) { if kind == 2 { archived_more } else { done_more } }
  let more_open = fn() { lead_kind() != 0 && more_of(lead_kind()).get() }
  let lead = fn() { subchats_lead(subchats(), more_open()) }
  let scroll : @view.Scroll? = if scroll_most is Some(_) || fills {
    Some(@view.Scroll::new())
  } else {
    None
  }
  let search_field = @ui.Field::new()
  let query : @signals.Signal[String] = @signals.signal("")
  let search_focused : @signals.Signal[Bool] = @signals.signal(false)
  let query_trimmed = fn() { query.get().trim().to_owned() }
  let search_active = fn() { query_trimmed() != "" || search_focused.get() }
  if show_head {
    v.box(fn(head) {
      @sf.style_node(head, fn() { subchats_head })
      @sf.words_node(head, fn() { @sf.t("web-pages.chat.subchats") }, fn() { subchats_head_title }) |> ignore
      subchats_counts_node(head, opened)
    })
    |> ignore
    match scroll {
      Some(sc) =>
        v.box(fn(l) {
          @sf.style_node(l, fn() { subchats_head_divider })
          l.alpha(By(fn() { if sc.overflows_past_tuck() { 1.0 } else { 0.0 } })) |> ignore
        })
        |> ignore
      None => ()
    }
  }
  let render_body = fn(host : @view.View) {
    match scroll {
      Some(sc) =>
        host.show(at_once=true, fn() { all_items().length() > 0 }, fn(sw) {
          @sf.style_node(sw, fn() { subchats_search_wrap })
          let field_view = @sf.search_input_node(
            sw,
            search_field,
            fn() { @sf.t("web-pages.chat.subchatsSearch") },
            at=Side,
            edited=fn(s) { query.set(s) },
            cleared=fn() { query.set("") },
            escape=fn() {
              if search_field.text() != "" {
                search_field.set("")
                query.set("")
                true
              } else {
                false
              }
            },
          )
          field_view.reacts(fn() { field_view.focused() }, fn(f) { search_focused.set(f) })
          sc.tucks(sw, fn() { 0.0 }, kept=fn() { !search_active() })
        })
      None => ()
    }
    host.pick(at_once=true, fn() { query_trimmed() != "" }, fn(zone, filtering) {
      if filtering {
        let hit_key = fn(h : @sfbase.SubchatHit) { h.opened.chat.station + "\u{1}" + h.opened.chat.session }
        let res = @signals.computed(fn(_) { subchats_search_results(src, chat, all_items, include_opened, query_trimmed()) })
        let hits = fn() { res.get().0 }
        let reading = fn() { res.get().1 }
        let by_hit = zone.keyed_by(hits, hit_key)
        zone.pick(at_once=true, fn() { hits().length() == 0 }, fn(body, none_found) {
          if none_found {
            body.box(fn(e) {
              @sf.style_node(e, fn() { subchats_empty })
              @sf.words_node(
                e,
                fn() {
                  if reading() {
                    @sf.t("web-pages.chat.subchatsSearching")
                  } else {
                    @sf.t("web-pages.chat.subchatsNoMatch")
                  }
                },
                fn() { subchats_empty_words },
              )
              |> ignore
            })
            |> ignore
            return
          }
          body.box(fn(g) {
            @sf.style_node(g, fn() { subchats_group })
            g.each(fn() { hits().map(hit_key) }, fn(k) { k }, fn(row, k) {
              let id = k.untracked()
              subchat_hit_row_node(row, fn() { by_hit.get(id) }, close?=close)
            })
          })
          |> ignore
        })
        return
      }
      zone.pick(at_once=true, fn() { subchats().length() == 0 }, fn(body, empty) {
        if empty {
          body.box(fn(e) {
            @sf.style_node(e, fn() { subchats_empty })
            @sf.words_node(e, fn() { @sf.t("web-pages.chat.subchatsNone") }, fn() { subchats_empty_words }) |> ignore
          })
          |> ignore
          return
        }
        let key_of = fn(o : @sfbase.OpenedChat) { o.chat.station + "\u{1}" + o.chat.session }
        let by_key = body.keyed_by(all_items, key_of)
        body.box(fn(list) {
          @sf.style_node(list, fn() { subchats_list })
          list.box(fn(g) {
            @sf.style_node(g, fn() { subchats_group })
            g.each(fn() { lead().0.map(key_of) }, fn(k) { k }, fn(row, k) {
              let id = k.untracked()
              subchat_row_node(row, fn() { by_key.get(id) }, close?=close)
            })
            // (the finished ones past the latest, shown or folded back in place)
            g.show(at_once=true, fn() { lead().1 > 0 }, fn(m) {
              subchats_more_node(m, fn() { lead().1 }, more_open, fn() {
                let more = more_of(@signals.untracked(lead_kind))
                let folding = more.untracked()
                more.set(!folding)
                // (folded back, what it shows is the latest again, from the top: the press, under the last of all of
                // them, has nothing above it to stay beside)
                match scroll {
                  Some(sc) if folding => sc.put(sc.tuck_height())
                  _ => ()
                }
              })
            })
          })
          |> ignore
          // (what it does not lead with, folded under it: 6 under what it leads with, the heads 2 apart as its rows are)
          let folds_done = fn() { if lead_kind() == 0 { done() } else { [] } }
          let folds_archived = fn() { if lead_kind() != 2 { archived() } else { [] } }
          // (a hairline between what it leads with and what folds under it, only while something folds there)
          list.show(
            at_once=true,
            fn() { folds_done().length() > 0 || folds_archived().length() > 0 || extra_other().length() > 0 },
            fn(sec) {
              @sf.style_node(sec, fn() { subchats_list })
              sec.box(fn(l) { @sf.style_node(l, fn() { subchats_sec_line }) }) |> ignore
              sec.box(fn(heads) {
                @sf.style_node(heads, fn() { subchats_group })
                subchats_collapsible_group_node(
                  heads,
                  fn() { @sf.t("web-pages.chat.subchatsDone") },
                  "check",
                  folds_done,
                  done_open,
                  fn() { false },
                  key_of,
                  by_key,
                  close?=close,
                )
                subchats_collapsible_group_node(
                  heads,
                  fn() { @sf.t("web-pages.chat.subchatsArchived") },
                  "archive",
                  folds_archived,
                  archived_open,
                  // (spaced only from an open 已完成 above it: under a folded one the two heads stand as rows of one list)
                  fn() { folds_done().length() > 0 && done_open.get() },
                  key_of,
                  by_key,
                  close?=close,
                )
                subchats_collapsible_group_node(
                  heads,
                  fn() { @sf.t("web-pages.chat.subchatsOther") },
                  "spawned",
                  extra_other,
                  other_open,
                  fn() {
                    (folds_done().length() > 0 && done_open.get()) ||
                    (folds_archived().length() > 0 && archived_open.get())
                  },
                  key_of,
                  by_key,
                  close?=close,
                )
              })
              |> ignore
            },
          )
        })
        |> ignore
      })
    })
  }
  match (scroll_most, scroll) {
    (Some(cap), Some(sc)) =>
      v.box(fn(wrap) {
        @sf.style_node(wrap, fn() { subchats_scroll_wrap })
        wrap.shrink(Is(1.0)).min_height(Is(Some(0.0))).max_height(By(fn() { Some(cap()) })) |> ignore
        // (always keep clipping and input bounds active so a tucked search bar above top never leaks visually or accepts clicks)
        wrap.scrolls(sc, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(s) { render_body(s) })
        .clips(Is(true))
        .bounds_input(Is(true))
        |> ignore
      })
      |> ignore
    (None, Some(sc)) =>
      v.box(fn(wrap) {
        @sf.style_node(wrap, fn() { subchats_scroll_wrap })
        wrap.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
        wrap.scrolls(sc, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(s) { render_body(s) })
        .grow(Is(1.0))
        .min_height(Is(Some(0.0)))
        .clips(Is(true))
        .bounds_input(Is(true))
        |> ignore
      })
      |> ignore
    _ => render_body(v)
  }
  match in_panel {
    Some(open_panel) =>
      v.show(at_once=true, fn() { subchats().length() > 0 }, fn(foot) {
        @sf.style_node(foot, fn() { subchats_foot })
        foot.box(fn(l) { @sf.style_node(l, fn() { subchats_divider }) }) |> ignore
        let words = fn() { @sf.t("web-main.jobs.inPanel") }
        @sf.action_box_node(foot, words, fn(_) { open_panel() }, fn(b) {
          @sf.style_node(b, fn() { subchats_foot_btn.then(subchats_round) }, in_row=true)
          b.min_height(By(fn() { Some(@sf.row_least()) })) |> ignore
          @sf.hover_ground_node(b)
          @sf.focus_ring_node(b)
          @sf.icon_node(b, "panel-open", 14.0, By(fn() { if @sf.lit_node(b) { @sf.theme().p.text } else { @sf.theme().p.muted } }))
          |> ignore
          @sf.words_node(b, words, fn() { if @sf.lit_node(b) { subchats_foot_hot } else { subchats_foot_words } }) |> ignore
        })
        |> ignore
      })
    None => ()
  }
}

///|
/// A folding group of the list (已完成, 已归档) under what it leads with: a quiet row (its words and count in Meta,
/// muted till pointed at or open), its chevron down to open it in place and up to fold it, in the rows' chevron column;
/// as tall as a row at least (row_least); spaced from what shows above it only while `spaced_above`.
fn subchats_collapsible_group_node(
  list : @view.View,
  label : () -> String,
  icon : String,
  items : () -> Array[@sfbase.OpenedChat],
  folded_open : @signals.Signal[Bool],
  spaced_above : () -> Bool,
  key_of : (@sfbase.OpenedChat) -> String,
  by_key : @signals.KeyedList[String, @sfbase.OpenedChat],
  close? : () -> Unit,
) -> Unit {
  let open = fn() { folded_open.get() }
  list.show(at_once=true, fn() { items().length() > 0 }, fn(g) {
    @sf.style_node(g, fn() {
      if spaced_above() {
        subchats_group_spaced
      } else {
        subchats_group
      }
    })
    @sf.action_box_node(
      g,
      label,
      fn(_) { folded_open.set(!folded_open.untracked()) },
      expanded=open,
      fn(h) {
        @sf.style_node(h, fn() { subchats_section_head.then(subchats_round) })
        h.min_height(By(fn() { Some(@sf.row_least()) })) |> ignore
        @sf.hover_ground_node(h)
        let hot = fn() { @sf.lit_node(h) || open() }
        // (its mark and words on the rows' axes, muted: what folds stays under what is led with)
        h.box(fn(l) {
          @sf.style_node(l, fn() { subchats_section_left }, in_row=true)
          l.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.icon_node(l, icon, 14.0, By(fn() { if hot() { @sf.theme().p.text } else { @sf.theme().p.muted } })) |> ignore
          @sf.words_node(l, label, fn() { if hot() { subchats_section_hot } else { subchats_section_words } }) |> ignore
        })
        |> ignore
        h.box(fn(end) {
          @sf.style_node(end, fn() { subchats_section_end }, in_row=true)
          end.shrink(Is(0.0)) |> ignore
          @sf.words_node(end, fn() { items().length().to_string() }, fn() { subchats_section_count }) |> ignore
          subchats_chevron_node(end, open, fn() { @sf.lit_node(h) })
        })
        |> ignore
      },
    )
    |> ignore
    g.show(open, fn(ag) {
      @sf.style_node(ag, fn() { subchats_group })
      ag.each(fn() { items().map(key_of) }, fn(k) { k }, fn(row, k) {
        let id = k.untracked()
        subchat_row_node(row, fn() { by_key.get(id) }, close?=close)
      })
    })
  })
}

///|
/// A chevron in the rows' chevron column (16 wide) of `h`: down while what it opens is folded, up while open.
fn subchats_chevron_node(h : @view.View, open : () -> Bool, lit : () -> Bool) -> Unit {
  h.box(fn(c) {
    c.width(Is(Some(16.0))).shrink(Is(0.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    @sf.icon_node(
      c,
      "",
      14.0,
      By(fn() { if lit() { @sf.theme().p.text } else { @sf.theme().p.subtle } }),
      name_now=fn() { if open() { "chevron-up" } else { "chevron-down" } },
    )
    |> ignore
  })
  |> ignore
}

///|
/// The press under the latest finished sub-chats that shows the `past` others in place (展开其余 N 个) or folds them
/// back (收起其余 N 个): its words where the rows' titles start, its chevron in their marks' column.
fn subchats_more_node(m : @view.View, past : () -> Int, open : () -> Bool, press : () -> Unit) -> Unit {
  let words = fn() { subchats_more_words(past(), open()) }
  @sf.action_box_node(m, words, fn(_) { press() }, expanded=open, fn(b) {
    @sf.style_node(b, fn() { subchats_more_row.then(subchats_round) })
    b.min_height(By(fn() { Some(@sf.row_least()) })) |> ignore
    @sf.hover_ground_node(b)
    let lit = fn() { @sf.lit_node(b) }
    b.box(fn(c) {
      c.width(Is(Some(14.0))).shrink(Is(0.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      @sf.icon_node(
        c,
        "",
        14.0,
        By(fn() { if lit() { @sf.theme().p.text } else { @sf.theme().p.subtle } }),
        name_now=fn() { if open() { "chevron-up" } else { "chevron-down" } },
      )
      |> ignore
    })
    |> ignore
    @sf.words_node(b, words, fn() { if lit() { subchats_more_words_hot } else { subchats_more_words_rest } }) |> ignore
  })
  |> ignore
}

///|
/// A single sub-chat search hit row: delegates to `subchat_row_node_with_text` using `subchat_hit_row_text`.
fn subchat_hit_row_node(row : @view.View, hit : () -> @sfbase.SubchatHit?, close? : () -> Unit) -> Unit {
  subchat_row_node_with_text(
    row,
    fn() {
      match hit() {
        Some(h) => Some(h.opened)
        None => None
      }
    },
    fn() {
      match hit() {
        Some(h) => subchat_hit_row_text(h)
        None => ""
      }
    },
    close?=close,
  )
}

///|
/// A single sub-chat row: first-line aligned status mark, title + optional state summary, first-line aligned chevron.
fn subchat_row_node(row : @view.View, item : () -> @sfbase.OpenedChat?, close? : () -> Unit) -> Unit {
  subchat_row_node_with_text(
    row,
    item,
    fn() {
      match item() {
        Some(o) => subchat_row_state_text(o)
        None => ""
      }
    },
    close?=close,
  )
}

///|
fn subchat_row_node_with_text(
  row : @view.View,
  item : () -> @sfbase.OpenedChat?,
  state_text : () -> String,
  close? : () -> Unit,
) -> Unit {
  let title = fn() {
    match item() {
      Some(o) => o.chat.title
      None => ""
    }
  }
  let is_archived = fn() {
    match item() {
      Some(o) => o.archived
      None => false
    }
  }
  let mark_kind = fn() { subchat_mark_kind(item()) }
  @sf.action_box_node(row, title, fn(_) {
    match @signals.untracked(item) {
      Some(o) => {
        match close {
          Some(f) => f()
          None => ()
        }
        @sfbase.open_page(Chat(o.chat))
      }
      None => ()
    }
  }, fn(b) {
    @sf.style_node(b, fn() { subchats_row.then(subchats_round) })
    b.min_height(Is(Some(44.0))) |> ignore
    @sf.hover_ground_node(b)
    @sf.focus_ring_node(b)
    b.box(fn(on) {
      @sf.style_node(on, fn() { subchats_row_on }, in_row=true)
      on.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      @sf.first_line_node(on, Ui, leading=L6, fn(d) {
        d.width(Is(Some(14.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
        d.pick(at_once=true, mark_kind, fn(m, kind) {
          match kind {
            0 => @sf.state_dot_node(m, size=8.0, breathes=true, fn() { "live" })
            1 => @sf.state_dot_node(m, size=8.0, breathes=true, fn() { "restart" })
            2 => @sf.state_dot_node(m, size=8.0, breathes=false, fn() { "fail" })
            3 => @sf.icon_node(m, "archive", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
            4 => @sf.icon_node(m, "check", 14.0, By(fn() { @sf.theme().p.green_ink })) |> ignore
            _ => @sf.icon_node(m, "spawned", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
          }
        })
      })
      |> ignore
      on.box(fn(w) {
        @sf.style_node(w, fn() { subchats_row_text }, in_row=true)
        w.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(w, title, fn() { if is_archived() { subchats_title_archived } else { subchats_title } })
        .allow_ellipsis(Is(true))
        |> ignore
        w.show(at_once=true, fn() { state_text() != "" }, fn(st) {
          @sf.words_node(st, state_text, fn() { subchats_state_words }).allow_ellipsis(Is(true)) |> ignore
        })
      })
      |> ignore
    })
    |> ignore
    @sf.first_line_node(b, Ui, leading=L6, fn(e) {
      e.width(Is(Some(16.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      @sf.icon_node(e, "chevron-right", 14.0, By(fn() { if @sf.lit_node(b) { @sf.theme().p.text } else { @sf.theme().p.subtle } }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let subchats_round : @ui.Style = @ui.style(radius=@sf.panel_in)

///|
// kept across runs: a value (no field of it changes)
let subchats_head : @ui.Style = @ui.css("row w=Full pt=S1_5 px=S2_5 pb=S1_5 gap=S2 align=ACenter justify=JBetween")

///|
// kept across runs: a value (no field of it changes)
let subchats_head_divider : @ui.Style = @sf.rule_line

///|
// kept across runs: a value (no field of it changes)
let subchats_scroll_wrap : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let subchats_search_wrap : @ui.Style = @ui.css("w=Full pt=S1 pb=S1_5 px=S1")

///|
// kept across runs: a value (no field of it changes)
let subchats_counts : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let subchats_head_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, leading=L6, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let subchats_count_words : @ui.TextStyle = @ui.text_style(size=Caption, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let subchats_empty : @ui.Style = @ui.css("w=Full py=S6 px=S4 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let subchats_empty_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, wrap=true)

///|
// kept across runs: a value (no field of it changes)
let subchats_list : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let subchats_group : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let subchats_group_spaced : @ui.Style = @ui.css("w=Full mt=S1_5 gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let subchats_section_head : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_5 gap=S2_5 align=ACenter justify=JBetween")

///|
// kept across runs: a value (no field of it changes)
let subchats_section_left : @ui.Style = @ui.css("row gap=S2_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let subchats_section_end : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let subchats_sec_line : @ui.Style = @sf.rule_line.then(@ui.css("my=S1_5"))

///|
// kept across runs: a value (no field of it changes)
let subchats_more_row : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_5 gap=S2_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let subchats_section_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Muted, leading=L6, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let subchats_section_hot : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, leading=L6, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let subchats_more_words_rest : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let subchats_more_words_hot : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let subchats_section_count : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, tabular=true, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let subchats_row : @ui.Style = @ui.css("row w=Full py=S2 px=S2_5 gap=S2_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let subchats_row_on : @ui.Style = @ui.css("row gap=S2_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let subchats_row_text : @ui.Style = @ui.css("gap=SPx")

///|
// kept across runs: a value (no field of it changes)
let subchats_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, leading=L6, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let subchats_title_archived : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Muted, leading=L6, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let subchats_state_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let subchats_foot : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
// kept across runs: a value (no field of it changes)
let subchats_divider : @ui.Style = @sf.rule_line.then(@ui.css("mb=S1_5"))

///|
// kept across runs: a value (no field of it changes)
let subchats_foot_btn : @ui.Style = @ui.css("row w=Full py=S1_5 px=S2_5 gap=S2_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let subchats_foot_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let subchats_foot_hot : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false)
