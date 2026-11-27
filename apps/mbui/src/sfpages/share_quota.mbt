// Pictures to share of what is left of the accounts (2026-11-17 用户：「支持一下把订阅和额度分享成图片，还有把消耗恢复图也
// 做成分享图片」), both shared from Profile and drawn as the app draws them there (「为啥不用我们本来的 ui」): the
// workspace's subscriptions and their allowances, as 账号 lists them (accounts_share_open: 「不是单个账号分享，是多个」), and
// every pool's quota and refills, each as 概览 charts it (pool_share_open: 「要把所有 tab 平铺出来」). Each on the stage the
// card to share of the agents at work has (stations_now.mbt), as wide (@sf.share_w_most), handed out the same way, on the
// page's ground in the theme the app is in. An account's name is said with most of an email's part before the @ hidden
// (share_name), or all of it under dots (「再支持一下账号完全打码」「打码用打码的样式，不要改账号名」: share_mask_all, chosen
// over the picture).

///|
/// A picture to share on a stage of its own (share_card_open's: the picture alone over the night, under it the button
/// that hands it out), its title the app's words' `title`, drawn by `draw` in node `v` (`flat`: handed out, its ground to
/// its edges), made anew as what it reads changes, laid out `w` wide (a portrait poster's, share_w_most, unless what it
/// holds asks more); `above` what is chosen over its buttons (share_mask_pick_node).
fn share_picture_open(
  title : String,
  draw : (@view.View, Bool) -> Unit,
  above? : (@view.View) -> Unit,
  w? : Double = @sf.share_w_most,
  scroll? : @view.Scroll,
  reset_copied? : () -> String = fn() { "" },
) -> Unit {
  let clip_in_stage = scroll is Some(_)
  @sf.stage_panel_nodes(
    @sf.t(title),
    fn(v, _) { draw(v, clip_in_stage) },
    w~,
    scroll?,
    bg=fn() { @sf.theme().p.bg },
    above?,
    live=fn() { (@sf.t(title), "", "") },
    foot=fn(f, _) {
      let taking : @signals.Signal[Bool] = @signals.signal(false)
      let copied : @signals.Signal[Bool] = @signals.signal(false)
      let album = @sf.picture_to_album()
      let (label, icon) = @sf.picture_out_way()
      // Reset inline copied state whenever the preview content changes (provider filter / mask mode).
      f.reacts(reset_copied, fn(_) { copied.set(false) }, at_start=false)
      @sf.button_node(
        f,
        fn() { if !album && copied.get() { @sf.t("common.copied") } else { label } },
        tone=Primary,
        icon~,
        on_night=true,
        busy=fn() { taking.get() },
        disabled=fn() { taking.get() },
        done=fn() { !album && copied.get() },
        fn() {
          if taking.untracked() {
            return
          }
          taking.set(true)
          copied.set(false)
          @ui.take_picture(
            share_shot,
            w,
            fn(paper) { draw(paper, true) },
            fn(png) {
              taking.set(false)
              // Show inline checkmark on the copy button instead of popping a bottom toast over the stage footer.
              if picture_out_now(png, copy_said=!album) && !album {
                copied.set(true)
              }
            },
            scale=share_scale,
          )
        },
      )
      |> ignore
    },
  )
}

///|
/// A picture shared of Profile (share_quota.mbt's) in `v`: a panel of the page's ground in the theme it is in (round as
/// one, pane_corner, or `flat`: handed out, its ground to its edges), its cards 16 in as a panel's are; still.fail's name
/// at its head and `count` at its line's end, what `body` makes under them, still.fail's line at its foot, those words
/// where a section's heading starts.
fn share_frame_node(v : @view.View, flat : Bool, count : () -> String, body : (@view.View) -> Unit) -> Unit {
  v.box(fn(p) {
    p.padding(Is((sa_pad, sa_pad, sa_pad, sa_pad))).ground(By(fn() { @sf.theme().p.bg })) |> ignore
    if !flat {
      p.radius(Is(@sf.pane_corner)).clips(Is(true)) |> ignore
    }
    p.box(fn(h) {
      h.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)).padding(Is((sa_head_x, 0.0, sa_head_x, 4.0))) |> ignore
      h.box(fn(w) {
        w
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        // (its dot still.fail's orange, deepened on a light ground as on a till's paper: the words' contrast)
        .words_runs(By(fn() {
          let dot = if @sf.theme().dark { @sf.share_orange } else { @sf.share_receipt_orange }
          [@ui.span("still"), @ui.span(".", color=dot), @ui.span("fail")]
        }))
        .words_look(Is(@ui.style_words(sa_brand)))
        .ink(By(fn() { @ui.style_ink(sa_brand) }))
        |> ignore
      })
      |> ignore
      @sf.words_node(h, count, fn() { sa_count }).shrink(Is(0.0)) |> ignore
    })
    |> ignore
    body(p)
    p.box(fn(t) {
      t.padding(Is((sa_head_x, 4.0, sa_head_x, 0.0))) |> ignore
      @sf.words_node(t, fn() { @sf.t("web-main.stations.shareTagline") }, fn() { sa_tagline }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

// ── the subscriptions' allowances ──────────────────────────────────────

///|
/// Short vendor label for the share stage's provider filter tabs: maps canonical group keys directly (locale-independent)
/// and falls back to stripping trailing subscription suffixes from `title` for any other group.
fn share_group_tab_label(key : String, title : String) -> String {
  match key {
    "claude" => "Claude"
    "chatgpt" => "ChatGPT"
    "grok" => "SuperGrok"
    "kimi" => "Kimi Code"
    "opencode" => "OpenCode Go"
    "cursor" => "Cursor"
    "devin" => "Devin"
    "agy" => "Google"
    "colab" => "Google Colab"
    "copilot" => "GitHub Copilot"
    _ => {
      for suffix in [" 订阅", "订阅", " subscriptions", " Subscriptions", " subscription", " Subscription"] {
        if title.has_suffix(suffix) {
          let trimmed = title[:title.length() - suffix.length()].trim(chars=" ").to_owned()
          if trimmed != "" {
            return trimmed
          }
        }
      }
      title
    }
  }
}

///|
/// The picture of the workspace's subscriptions and what is left of each, as the core's `profiles` of workspace `scope`
/// says those with an allowance to show: how many at its head; each kind as Profile's 账号 lists it, its heading over its
/// card, each account its row there (share_account_row); scrollable at readable width on the stage when tall, filtered
/// by provider when more than one group exists, and masked as `share_mask_all` says.
pub fn accounts_share_open(core : Core, scope : () -> String) -> Unit {
  let entries = @signals.computed(fn(_) {
    items((core.topic)("profiles", { "scope": Json::string(scope()) }).get().value, "items").filter(fn(e) {
      let q = field(field(Some(e), "profile"), "quota")
      text(q, "state") == "ok" && items(q, "windows").length() > 0
    })
  }, same=jsons_same)
  let all_groups = @signals.computed(fn(_) { pl_groups(entries.get()) }, same=fn(a, b) {
    if a.length() != b.length() {
      return false
    }
    for i in 0..<a.length() {
      if a[i].0 != b[i].0 || a[i].1 != b[i].1 || !jsons_same(a[i].2, b[i].2) {
        return false
      }
    }
    true
  })
  let chosen_group : @signals.Signal[String] = @signals.signal("")
  let scroll = @view.Scroll::new()
  let active_group = fn() {
    let g = chosen_group.get()
    if g != "" && all_groups.get().iter().any(fn(x) { x.0 == g }) {
      g
    } else {
      ""
    }
  }
  let shown_groups = fn() {
    let g = active_group()
    let gs = all_groups.get()
    if g == "" {
      gs
    } else {
      gs.filter(fn(x) { x.0 == g })
    }
  }
  let shown_count = fn() {
    let mut n = 0
    for g in shown_groups() {
      n = n + g.2.length()
    }
    n
  }
  let group_tabs = fn() -> Array[(String, String)] {
    let out : Array[(String, String)] = [("", @sf.t("web-main.filter.all"))]
    for g in all_groups.get() {
      out.push((g.0, share_group_tab_label(g.0, g.1)))
    }
    out
  }
  share_picture_open(
    "web-main.share.accounts",
    scroll~,
    reset_copied=fn() { "\{active_group()}|\{share_mask_all.get()}" },
    fn(v, flat) {
      share_frame_node(v, flat, fn() { shown_count().to_string() + " " + @sf.t("web-main.share.accountsCount") }, fn(p) {
        p.each(at_once=true, shown_groups, fn(g) { g.0 }, fn(x, g) {
          @sf.section_heading_node(x, fn() { g.get().1 })
          let grp_sig = @signals.computed(
            fn(_) {
              @sfbase.quota_compact_group(
                x,
                g.get().2.map(fn(e) { field(field(Some(e), "profile"), "quota") }),
              )
            },
            same=fn(a, b) { a == b },
          )
          let grp = fn() { grp_sig.get() }
          @sf.group_node(x, fn(rows) {
            let keyed = fn() {
              let list = g.get().2
              let n = list.length()
              list.mapi(fn(i, e) { (e, @sf.card_piece_of(i, n)) })
            }
            rows.each(at_once=true, keyed, fn(item) { text(Some(item.0), "key") }, fn(r, item) {
              let piece = fn() { item.get().1 }
              @sf.card_sep_node(r, piece)
              // Share rows never carry a trailing status line below the quota strip, so `at_foot=true` matches
              // Profiles' exact compact row height across every row in the group.
              share_account_row(r, fn() { Some(item.get().0) }, grp, fn() { true })
            })
          })
        })
      })
    },
    above=fn(v) {
      v.box(fn(all) {
        @sf.style_node(all, fn() { groups_and_looks })
        // Clear a vanished provider filter permanently so a later quota refresh cannot hijack the view back to it.
        all.reacts(fn() { all_groups.get() }, fn(gs) {
          let g = chosen_group.untracked()
          if g != "" && !gs.iter().any(fn(x) { x.0 == g }) {
            chosen_group.set("")
            scroll.put(0.0)
          }
        }, at_start=false)
        all.show(at_once=true, fn() { all_groups.get().length() > 1 }, fn(row) {
          row.fills_across(Is(true)) |> ignore
          @sf.share_tabs_each_node(
            row,
            fn() { @sf.t("web-main.projects.filter_section") },
            group_tabs,
            active_group,
            fn(k) {
              chosen_group.set(k)
              scroll.put(0.0)
            },
          )
          |> ignore
        })
        share_mask_tabs_node(all)
      })
      |> ignore
    },
  )
}

///|
/// Whether the picture of the subscriptions hides their names whole, dots in their place (link_row_node's `title_masked`), or all but an
/// email's first two letters and its domain; the last chosen in this run.
// kept across runs: what a person chose over the picture, as long as the app runs; a new run sets it back (pages.mbt)
let share_mask_all : @signals.Signal[Bool] = @signals.signal(false)

///|
/// 部分打码 | 完全打码 tab row on the stage night scrim.
fn share_mask_tabs_node(v : @view.View) -> Unit {
  @sf.share_tabs_node(
    v,
    fn() { @sf.t("web-main.share.mask") },
    [false, true],
    fn(b) { @sf.t(if b { "web-main.share.maskAll" } else { "web-main.share.maskSome" }) },
    fn() { share_mask_all.get() },
    fn(b) { share_mask_all.set(b) },
  )
  |> ignore
}

///|
/// Whether the workspace has an account whose allowance a picture can show (its share offered only then).
pub fn accounts_shareable(core : Core, scope : String) -> Bool {
  items((core.topic)("profiles", { "scope": Json::string(scope) }).get().value, "items").iter().any(fn(e) {
    let q = field(field(Some(e), "profile"), "quota")
    text(q, "state") == "ok" && items(q, "windows").length() > 0
  })
}

///|
/// Whether Profile's header share button has any shareable quota picture (pool overview or per-account quotas).
fn profile_share_available(
  core : Core,
  here : () -> Here,
  has_pools? : () -> Bool = fn() { false },
) -> @signals.Computed[Bool] {
  let scope = fn() { here().workspace }
  @signals.computed(fn(_) { has_pools() || accounts_shareable(core, scope()) })
}

///|
/// Profile's header shares the available pictures. The accounts list opens its own picture directly.
fn profile_share_node(
  l : @view.View,
  core : Core,
  here : () -> Here,
  shown : () -> Bool,
  tips : @sf.TipLayer?,
  bar? : Bool = false,
  has_pools? : () -> Bool = fn() { false },
) -> Unit {
  let scope = fn() { here().workspace }
  let accounts = @signals.computed(fn(_) { accounts_shareable(core, scope()) })
  let available = profile_share_available(core, here, has_pools~)
  l.show(fn() { shown() && available.get() }, fn(s) {
    let label = fn() {
      if !has_pools() {
        @sf.t("web-main.share.accounts")
      } else if accounts.get() {
        @sf.t("web-main.chat.share")
      } else {
        @sf.t("web-main.share.pool")
      }
    }
    let press = fn() {
      let ws = @signals.untracked(scope)
      let charts = fn() { pool_share_open(core, fn() { ws }) }
      let subscriptions = fn() { accounts_share_open(core, fn() { ws }) }
      if !has_pools() {
        subscriptions()
      } else if !accounts.get() {
        charts()
      } else {
        @sf.menu([
          Some(@sf.menu_item_of(@sf.t("web-main.share.pool"), charts, further=true)),
          Some(@sf.menu_item_of(@sf.t("web-main.share.accounts"), subscriptions, further=true)),
        ], from=Node(s), along=End, title=label())
      }
    }
    if bar {
      @sf.bar_icon_node(s, "share", label, press, tips?)
    } else {
      @sf.icon_button_node(s, "share", label, press, tips?) |> ignore
    }
  })
}

///|
/// An account's name as a picture shared says it: an email's part before the @ hidden but its first two letters.
fn share_name(name : String) -> String {
  let chars = name.to_array()
  match chars.search('@') {
    Some(at) if at > 0 => {
      let kept = String::from_array(chars[0:(if at < 2 { at } else { 2 })].to_owned())
      kept + "•••" + String::from_array(chars[at:].to_owned())
    }
    _ => name
  }
}

///|
/// An account's row on the picture, matching Profile's compact grouped row (`pl_account_row_node`) with
/// non-interactive layout:
/// - Line 1: 20x20 mark box (18pt provider mark), masked single-line account name (`share_name` or spoiler dots
///   via `@sf.masked_words_box` while `share_mask_all` holds) + droppable plan tag.
/// - Line 2 (flush left under the mark): group-aligned equal-width 16pt micro-capsule quota strip (`quota_compact_node`).
fn share_account_row(
  r : @view.View,
  ev : () -> Json?,
  group : () -> @sfbase.QuotaCompactGroup,
  at_foot : () -> Bool,
) -> Unit {
  let p = fn() { field(ev(), "profile") }
  let name = fn() {
    match text(p(), "name") {
      "" => text(ev(), "title")
      n => n
    }
  }
  let plan_tag = fn() { pl_plan_tag(p()) }
  r.box(fn(row) {
    @sf.style_node(row, fn() { pl_row_multi })
    // Line 1: 20x20 mark box, masked single-line account name + droppable plan tag
    row.box(fn(head) {
      @sf.style_node(head, fn() { pl_head })
      head.box(fn(m) {
        @sf.style_node(m, fn() { pl_mark_box }, in_row=true)
        @sfbase.provider_mark_node(
          m,
          fn() { (text(p(), "runtime"), text(field(p(), "access"), "kind"), text(p(), "providerMark")) },
          pl_logo,
        )
      })
      |> ignore
      head.box(fn(n) {
        @sf.style_node(n, fn() { pl_name_row })
        n.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).fits(Is(true)) |> ignore
        @sf.masked_words_box(n, Some(fn() { share_mask_all.get() }), fn(w) {
          w.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(
            w,
            fn() { if share_mask_all.get() { name() } else { share_name(name()) } },
            fn() { pl_name },
          )
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          |> ignore
        })
        n.show(at_once=true, fn() { plan_tag() != "" }, fn(a) {
          a.drops(Is(pl_drop_plan)) |> ignore
          @sf.row_tag_node(a, plan_tag)
        })
      })
      |> ignore
    })
    |> ignore
    // Line 2: compact equal-width 16pt micro-capsule quota strip, flush left under the mark
    @sfbase.quota_compact_node(row, fn() { field(p(), "quota") }, group~, at_foot~)
  })
  |> ignore
}

// ── every pool's quota and refills ─────────────────────────────────────

///|
/// The picture of every pool Profile's 概览 charts (each of its tabs, one under another), as the core's
/// `profilesOverview` of workspace `scope` says them: each its heading (its name, how many of its accounts are ready at
/// its end) over a card of its two charts side by side as the page draws them where it has the room (ov_charts_node:
/// 「消耗两个图横着排」, so the picture is pool_share_w wide).
pub fn pool_share_open(core : Core, scope : () -> String) -> Unit {
  let pools = @signals.computed(fn(_) {
    items((core.topic)("profilesOverview", { "scope": Json::string(scope()) }).get().value, "pools").map(ov_pool_of)
  }, same=fn(a, b) { a == b })
  share_picture_open("web-main.share.pool", w=pool_share_w, scroll=@view.Scroll::new(), fn(v, flat) {
    share_frame_node(v, flat, fn() { "" }, fn(p) {
      p.each(fn() { pools.get() }, fn(pool) { pool.title }, fn(x, pool) {
        @sf.section_heading_node(x, fn() { pool.get().title }, trailing=fn() {
          let pv = pool.get()
          @sf.t("web-main.share.poolReady", args=[("ready", pv.ready.to_string()), ("total", pv.total.to_string())])
        })
        // (on a card as the accounts' rows are, the panel's: group_node's)
        @sf.group_node(x, fn(card) { ov_charts_node(card, fn() { Some(pool.get()) }, None, None, show_speed=false) })
      })
    })
  })
}

///|
/// The pools' picture: as wide as a pool's two charts side by side take (ov_charts_node's two columns of 270 and 24
/// between, in a card's and the picture's room).
let pool_share_w : Double = 680.0

///|
/// The pictures of Profile: a panel's, its cards 16 in as a panel's are, its head's and its line's words where a
/// section's heading starts (heading_node's, 12 in).
let sa_pad : Double = 16.0

///|
let sa_head_x : Double = 12.0

///|
// kept across runs: a value (no field of it changes)
let sa_brand : @ui.TextStyle = @ui.text_style(size=Xl, weight=Bold, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sa_count : @ui.TextStyle = @ui.text_style(size=Sm, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sa_tagline : @ui.TextStyle = @ui.text_style(size=Sm, color=Muted, tracking=Widest, wrap=false)
