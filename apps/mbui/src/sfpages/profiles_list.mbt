// Profiles, the model accounts the agents run on (settings/Profiles.kt ProfilesScreen; the core's `profiles` view and
// each station's overview), made once as nodes of the window's tree in every frame, laid out by its width (page_node):
// every station's in one list, a section a kind of account, an account a row (its vendor's mark, its name and plan, what
// needs a look, its allowance), each station's own logins not used yet after them; from a station's page that station's
// only. And an account on several stations (ProfileAccountScreen): how it is, its allowance, each station's part.

///|
/// The profiles' list (ProfilesScreen) in node `v`, laid out by the `width` its frame gives it (narrow where none is
/// given), in the frame it is given: the workspace's (`only` "") as the core's `profiles` says them now, or station
/// `only`'s as that part of its overview says them; each section's heading and each account's row a block of its own (a
/// row a piece of its section's card), by its key, so one coming or going comes and goes where it is. Adding one (on a
/// station online) at its title's end, where the frame does not hold it itself (a place's notch names the page:
/// `frame().named`), or in a frame's bar (`bar_actions`). `here`: who and where, as that changes. 概览 pressed:
/// `on_show_overview` (a pushed page's own by default; the bottom bar's place says its own).
pub fn profiles_list_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  only : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
  bar_actions? : ((@view.View) -> Unit, (@sf.Look) -> Double) -> Unit,
) -> Unit {
  let tips = match tips {
    Some(t) => t
    None => @sf.TipLayer::new(fn() { Some(v) })
  }
  let profiles = fn() { (core.topic)("profiles", { "scope": str(here().workspace) }).get() }
  let stations_topic = fn() { @settings.stations_of(core, here()) }
  // the station it is of, where it is one's (none while the stations are read)
  let one_now = @signals.computed(fn(_) {
    match stations_topic().value {
      Some(Array(a)) if only != "" => a.iter().find_first(fn(x) { text(Some(x), "station") == only })
      _ => None
    }
  }, same=json_opt_same)
  let one = fn() { one_now.get() }
  // (its rows by section, each worked out once for each change of what it reads: the workspace's entries, or the
  // station's own profiles)
  let rows_now : @signals.Computed[Array[Json]] = @signals.computed(fn(_) {
    if only == "" {
      items(profiles().value, "items")
    } else {
      match @settings.station_part(core, here(), only, "profiles") {
        Some(Array(a)) => a
        _ => []
      }
    }
  }, same=jsons_same)
  // (its sections' headings and accounts' rows, each a block by its key, kept by key as its rows change: a block reads
  // its own, told only as that one changes, comes or goes, and none of them works its sections out again: View::keyed_by)
  let parts : @signals.KeyedList[String, (String, PlPart)] = v.keyed_by(
    fn() {
      let out : Array[(String, PlPart)] = []
      for g in pl_groups(rows_now.get()) {
        let grp = @sfbase.quota_compact_group(
          v,
          g.2.map(fn(r) {
            if only == "" {
              if flag(Some(r), "usable") {
                field(field(Some(r), "profile"), "quota")
              } else {
                None
              }
            } else {
              field(Some(r), "quota")
            }
          }),
        )
        out.push(("g/" + g.0, PlGroup(g.1)))
        for i, e in g.2 {
          let k = "p/" + g.0 + "/" + pl_key(only, e)
          let prev = if i > 0 { Some("p/" + g.0 + "/" + pl_key(only, g.2[i - 1])) } else { None }
          out.push((k, PlRow(e, @sf.card_piece_of(i, g.2.length()), prev, grp)))
        }
      }
      out
    },
    fn(e) { e.0 },
    same=pl_entry_same,
  )
  let row_lit = @sf.CardRowLit::new()
  // the machines' own logins not used yet, a block a station up that offers one: the workspace's by station, each
  // block reading its own
  let offers : @signals.KeyedList[String, (Json, Array[Json])] = v.keyed_by(
    fn() { if only == "" { @settings.profiles_offers(profiles().value) } else { [] } },
    fn(o) { text(Some(o.0), "station") },
    same=fn(a, b) { json_same(a.0, b.0) && jsons_same(a.1, b.1) },
  )
  let offers_now = fn() -> Array[String] {
    if only == "" {
      offers.keys()
    } else if flag(one(), "online") {
      [only]
    } else {
      []
    }
  }
  let manages = fn() {
    if only == "" {
      flag(profiles().value, "manages")
    } else {
      @settings.manager_of(core, here()) == Some(true)
    }
  }
  let add = fn() {
    if only == "" {
      @settings.place_action(core, here(), "profiles") is Some(_)
    } else {
      flag(one(), "online")
    }
  }
  let adding = fn(at : @view.View) {
    if only == "" {
      match @settings.place_action(core, @signals.untracked(here), "profiles") {
        Some(run) => run(Node(at))
        None => ()
      }
    } else if @signals.untracked(fn() { flag(one(), "online") }) {
      (core.push)(NewProfile(only))
    }
  }
  // (the subscriptions' allowances shared as a picture, the workspace's list's: share_quota.mbt; has_pools=false)
  let share_avail = profile_share_available(core, here, has_pools=fn() { false })
  let share_shown = fn() { only == "" && !frame().named && share_avail.get() }
  let actions = fn(l : @view.View) {
    @sf.bar_actions_pill_node(
      l,
      share_shown,
      count=fn() { if share_shown() { 1 } else { 0 } },
      fn(g) {
        if only == "" {
          profile_share_node(g, core, here, fn() { !frame().named }, Some(tips), has_pools=fn() { false })
        }
      },
    )
  }
  match bar_actions {
    Some(f) =>
      f(
        fn(l) {
          if only == "" {
            profile_share_node(l, core, here, fn() { true }, Some(tips), bar=true, has_pools=fn() { false })
          }
        },
        fn(_) { @sf.button_height() },
      )
    None => ()
  }
  let wait = fn() { field(profiles().value, "wait") }
  @sf.page_node(
    v,
    fn() { @sf.t("android-misc.bar.place.profiles") },
    fn() {
      let out : Array[String] = []
      if only == "" {
        let list = rows_now.get()
        match profiles().value {
          None => return ["waiting"]
          Some(_) if list.length() == 0 && (flag(wait(), "reading") || items(wait(), "failing").length() > 0) => return ["waiting"]
          _ => ()
        }
        // Three-tier architecture: 1. Collection (Overview + Batch Management), 2. Add Profile (only when the frame
        // does not own the bottom-bar ＋ action), 3. Individual accounts.
        if list.length() > 0 {
          out.push("collection")
        }
        if add() && !frame().named {
          out.push("add")
        }
        if list.length() == 0 {
          out.push("none")
        }
      } else {
        match one() {
          None => return ["waiting"]
          Some(_) => {
            if manages() && rows_now.get().length() > 0 {
              out.push("station-sharing")
            }
            if add() {
              out.push("add")
            }
            if rows_now.get().length() == 0 {
              out.push("empty")
            }
          }
        }
      }
      out.append(parts.keys())
      if only == "" && flag(wait(), "reading") {
        out.push("reading")
      }
      for s in offers_now() {
        out.push("o/" + s)
      }
      out
    },
    fn(b, key) {
      match key {
        "waiting" =>
          @sf.waiting_node(
            b,
            fn(s) {
              @sf.section_heading_node(s, fn() { @sf.sample_words(4) })
              let n = profiles_sample.length()
              s.each(fn() { Array::makei(n, fn(i) { i }) }, fn(i) { i }, fn(row, i) {
                let idx = i.untracked()
                let e = profiles_sample[idx]
                let piece = fn() { @sf.card_piece_of(idx, n) }
                @sf.card_piece_node(row, piece, wide_group=true, wide_group_ends_pad=true, fn(card) {
                  @sf.card_sep_node(card, piece)
                  pl_account_row_node(card, core.quiet(), fn() { Some(e) }, tips, sample=true)
                })
              })
            },
            error=fn() {
              let e = if only == "" { profiles().error } else { stations_topic().error }
              match e {
                Some(x) => error_text(x)
                None => ""
              }
            },
            note=fn() {
              let failing = @settings.failing_of(wait())
              { reading: failing.length() == 0, text: "", failing }
            },
          )
        "collection" => {
          let summed = @signals.computed(fn(_) { profiles_side_summary(rows_now.get()) }, same=fn(a, b) { a.0 == b.0 && a.1 == b.1 })
          let share_sum = @signals.computed(fn(_) { profiles_sharing_summary(rows_now.get()) }, same=fn(a, b) { a == b })
          @sf.group_node(b, fn(g) {
            g.pick(fn() { summed.get().1 == "amber" }, fn(x, amber) {
              @sf.link_row_node(
                x,
                fn() { @sf.t("web-pages.profiles.overview.title") },
                fn() { (core.push)(ProfilesOverview) },
                note=fn() { if summed.get().1 == "red" { "" } else { summed.get().0 } },
                trouble=fn() { if summed.get().1 == "red" { summed.get().0 } else { "" } },
                lacks=amber,
                lead=LeadLine(fn(l) { @sf.icon_node(l, "chart", pl_logo, By(fn() { @sf.theme().p.text })) |> ignore }),
              )
            })
            g.show(manages, at_once=true, fn(x) {
              @sf.link_row_node(
                x,
                fn() { @sf.t("web-pages.profiles.sharing.title") },
                fn() { (core.push)(ProfilesManage("")) },
                value=fn() { share_sum.get() },
                lead=LeadLine(fn(l) { @sf.icon_node(l, "select-all", pl_logo, By(fn() { @sf.theme().p.text })) |> ignore }),
              )
            })
          })
        }
        "station-sharing" =>
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(
              g,
              fn() { @sf.t("web-pages.profiles.sharing.title") },
              fn() { (core.push)(ProfilesManage(only)) },
              lead=LeadLine(fn(l) { @sf.icon_node(l, "select-all", pl_logo, By(fn() { @sf.theme().p.text })) |> ignore }),
            )
          })
        "add" => {
          b.margin(Is((0.0, 4.0, 0.0, 0.0))) |> ignore
          @sf.group_node(b, fn(g) {
            g.box(fn(anchor) {
              @sf.link_row_node(
                anchor,
                fn() { @sf.t("web-pages.settings.profiles.add") },
                fn() { adding(anchor) },
                lead=LeadLine(fn(l) { @sf.icon_node(l, "plus", pl_logo, By(fn() { @sf.theme().p.text })) |> ignore }),
              )
            })
            |> ignore
          })
        }
        "none" => {
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(g, fn() { @sf.t("web-pages.settings.profiles.none") }, fn() {  }, goes=false)
          })
          @sf.page_note_node(b, fn() { @sf.t("android-settings.profiles.note") })
        }
        "empty" =>
          @sf.group_node(b, fn(g) {
            g.pick(fn() { (field(one(), "overview") is None || @settings.station_part(core, here(), only, "profiles") is None) && flag(one(), "online") }, fn(
              p,
              reading,
            ) {
              if reading {
                p.box(fn(w) {
                  @sf.style_node(w, fn() { pl_wait_room })
                  @sf.wait_line_node(w, fn() { @sf.t("common.reading") }) |> ignore
                })
                |> ignore
              } else {
                @sf.link_row_node(
                  p,
                  fn() {
                    @sf.t(if field(one(), "overview") is None { "android-settings.profiles.stationOffline" } else { "android-settings.profiles.empty" })
                  },
                  fn() {  },
                  goes=false,
                )
              }
            })
          })
        "reading" =>
          @sf.group_node(b, fn(g) {
            g.box(fn(w) {
              @sf.style_node(w, fn() { pl_wait_room })
              @sf.wait_line_node(w, fn() {
                match text(wait(), "text") {
                  "" => @sf.t("common.reading")
                  x => x
                }
              })
              |> ignore
            })
            |> ignore
          })
        k if k.has_prefix("g/") => {
          let title = fn() {
            match parts.get(k) {
              Some((_, PlGroup(t))) => t
              _ => ""
            }
          }
          // (its name alone, each account's mark its row's, as the sidebar's rows have it, a station's as the
          // workspace's: a group of keys holds several vendors'; the user, 2026-11-14 and 2026-11-26)
          @sf.section_heading_node(b, title)
        }
        k if k.has_prefix("p/") => pl_row_block(b, core, only, parts, tips, fn() { k }, row_lit)
        k if k.has_prefix("o/") => {
          let station = k.exact_view(start=2).to_owned()
          let sv = @signals.computed(fn(_) {
            if only != "" {
              one()
            } else {
              offers.get(station).map(fn(o) { o.0 })
            }
          }, same=json_opt_same)
          let logins = fn() {
            if only != "" {
              @settings.station_part(core, here(), only, "machineLogins")
            } else {
              offers.get(station).map(fn(o) { Json::array(o.1) })
            }
          }
          pl_machine_offers_node(b, core, station, fn() { sv.get() }, logins, fn(_) { (core.push)(NewProfile(station)) }, tips)
        }
        _ => ()
      }
    },
    on_back~,
    frame~,
    actions~,
    said?,
    width?,
    tips~,
    // (from a station's page, back to it by its name, as the old page said it)
    back_as=fn() { if only == "" { "" } else { text(one(), "name") } },
    // (an account's row put by as it leaves what shows and taken by the next, reading the key it shows now)
    reused=fn(k) { if k.has_prefix("p/") { Some(0) } else { None } },
    make_reused=fn(b, _, key) { pl_row_block(b, core, only, parts, tips, key, row_lit) },
  )
}

///|
/// What a block of the profiles' list is: a section's heading (its title), or an account's row (its JSON, which
/// piece of its section's card it is, the key of the row immediately preceding it in its section, and its
/// section's dynamically-measured compact quota group layout).
#derive(Eq)
priv enum PlPart {
  PlGroup(String)
  PlRow(Json, @sf.CardPiece, String?, @sfbase.QuotaCompactGroup)
}

///|
/// The same block of the profiles' list: its key, and what it is the same (an account's JSON as json_same says).
fn pl_entry_same(a : (String, PlPart), b : (String, PlPart)) -> Bool {
  a.0 == b.0 &&
  (match (a.1, b.1) {
    (PlGroup(x), PlGroup(y)) => x == y
    (PlRow(x, px, prevx, grpx), PlRow(y, py, prevy, grpy)) =>
      px == py && prevx == prevy && grpx == grpy && json_same(x, y)
    _ => false
  })
}

///|
/// An account's key among the rows of its list: the workspace's entry's own, a station's profile's id.
fn pl_key(only : String, e : Json) -> String {
  if only == "" {
    text(Some(e), "key")
  } else {
    text(Some(e), "id")
  }
}

///|
/// The rows by the kind they are listed under (`group`, `groupTitle`), in order: each kind, its title, its rows.
fn pl_groups(list : Array[Json]) -> Array[(String, String, Array[Json])] {
  let out : Array[(String, String, Array[Json])] = []
  for p in list {
    let g = text(Some(p), "group")
    let mut found : Int? = None
    for i = 0; i < out.length(); i = i + 1 {
      if out[i].0 == g {
        found = Some(i)
        break
      }
    }
    match found {
      Some(i) => out[i].2.push(p)
      None => out.push((g, text(Some(p), "groupTitle"), [p]))
    }
  }
  out
}

///|
/// Block `key()` of the profiles' list ("p/<group>/<key>"), the key it shows now: an account's row, a piece of its
/// section's card, as it is now (as it was last, while it goes).
fn pl_row_block(
  b : @view.View,
  core : Core,
  only : String,
  parts : @signals.KeyedList[String, (String, PlPart)],
  tips : @sf.TipLayer,
  key : () -> String,
  row_lit : @sf.CardRowLit,
) -> Unit {
  let last : Ref[(Json, @sf.CardPiece, String?, @sfbase.QuotaCompactGroup)?] = Ref(None)
  let now = @signals.computed(fn(_) {
    match parts.get(key()) {
      Some((_, PlRow(e, piece, prev, grp))) => last.val = Some((e, piece, prev, grp))
      _ => ()
    }
    last.val
  }, same=fn(a, b) {
    match (a, b) {
      (Some((x, px, prevx, grpx)), Some((y, py, prevy, grpy))) =>
        px == py && prevx == prevy && grpx == grpy && json_same(x, y)
      (None, None) => true
      _ => false
    }
  })
  let row_now = @signals.computed(fn(_) { now.get().map(fn(n) { n.0 }) }, same=json_opt_same)
  let piece = fn() { now.get().map(fn(n) { n.1 }).unwrap_or(@sf.CardPiece::CardWhole) }
  let prev_key = fn() { now.get().bind(fn(n) { n.2 }) }
  let group_sig = @signals.computed(fn(_) { now.get().map(fn(n) { n.3 }).unwrap_or(@sfbase.QuotaCompactGroup::empty()) }, same=fn(a, b) {
    a == b
  })
  let group = fn() { group_sig.get() }
  b.grow(Is(1.0)) |> ignore
  // (wide, a piece of its section's list card as wide_group_node's: symmetric `pad` ends keep row_corner concentric in panes)
  @sf.card_piece_node(b, piece, wide_group=true, wide_group_ends_pad=true, fn(card) {
    @sf.card_sep_node(card, piece, lit=row_lit, key_now=key, prev_key~)
    if only == "" {
      pl_account_row_node(card, core, fn() { row_now.get() }, tips, group~, lit=row_lit, key_now=key)
    } else {
      pl_station_row_node(card, core, only, fn() { row_now.get() }, tips, group~, lit=row_lit, key_now=key)
    }
  })
}

///|
/// Plan tag for an account row: `planText`, or `kindText` for `service` access.
fn pl_plan_tag(p : Json?) -> String {
  match text(p, "planText") {
    "" => if text(field(p, "access"), "kind") == "service" { text(p, "kindText") } else { "" }
    s => s
  }
}

///|
/// Compact workspace account row (`only == ""`):
/// - Line 1: 20x20 mark box (18pt provider mark), single-line account name + droppable plan tag,
///   and a silent compact state dot at the right end only when abnormal or unusable.
/// - Line 2 (flush left under the mark, full width): fixed-column compact quota slots when usable with quota
///   (plus single-line cut alert underneath if `state.text` is also present), or a single-line compact fallback
///   for state alert, credits + detail (separate nodes, no `·`), API key usage/kind, or unchecked/detail/unknown.
fn pl_account_row_node(
  r : @view.View,
  core : Core,
  ev : () -> Json?,
  tips : @sf.TipLayer,
  sample? : Bool = false,
  group? : () -> @sfbase.QuotaCompactGroup,
  lit? : @sf.CardRowLit,
  key_now? : () -> String,
) -> Unit {
  let p = fn() { field(ev(), "profile") }
  let usable = fn() { flag(ev(), "usable") }
  let state = fn() { field(ev(), "state") }
  let quota = fn() { field(p(), "quota") }
  let windows = fn() { usable() && @sfbase.has_quota(quota()) }
  let name = fn() {
    match text(p(), "name") {
      "" => text(ev(), "title")
      n => n
    }
  }
  let plan_tag = fn() { pl_plan_tag(p()) }
  let state_text = fn() { text(state(), "text") }
  let state_tone = fn() {
    if state_text() == "" {
      0
    } else {
      match text(state(), "tone") {
        "red" => 2
        "neutral" | "" => 0
        _ => 1
      }
    }
  }
  let state_style = fn() {
    match state_tone() {
      2 => pl_meta_red_cut
      1 => pl_meta_amber_cut
      _ => pl_meta_muted_cut
    }
  }
  let fallback_text = fn() {
    if !usable() {
      ""
    } else if text(ev(), "group") == "key" {
      match text(p(), "usesText") {
        "" => text(p(), "kindText")
        u => u
      }
    } else if quota() is (None | Some(Null)) {
      @sf.t("web-main.quota.unchecked")
    } else if text(quota(), "detail") != "" {
      text(quota(), "detail")
    } else if text(quota(), "state") == "unsupported" {
      @sf.t("android-settings.quota.none")
    } else if text(quota(), "state") != "ok" {
      @sf.t("web-main.quota.unknown")
    } else {
      ""
    }
  }
  let press = fn() {
    let e = @signals.untracked(ev)
    (core.push)(Profile(text(e, "station"), text(field(e, "profile"), "id")))
  }
  r.box(fn(row) {
    row.transitions_only() |> ignore
    @sf.style_node(row, fn() { pl_row_multi })
    row.radius(Is(@sf.row_corner)) |> ignore
    row.alpha(By(fn() { if usable() { 1.0 } else { pl_away } })) |> ignore
    if !sample {
      match (lit, key_now) {
        (Some(g), Some(k)) => g.bind_top_now(k, row)
        _ => ()
      }
      @sf.hover_ground_node(row)
      @sf.rippled_node(row, press, @sf.row_corner, name)
      row.on_menu(fn(m) {
        let e = @signals.untracked(ev)
        let named = match text(field(e, "profile"), "name") {
          "" => text(e, "title")
          n => n
        }
        pl_menu(fn() { (core.push)(Profile(text(e, "station"), text(field(e, "profile"), "id"))) }, named, m)
      })
      |> ignore
    }
    // Line 1: 20x20 mark box, name + droppable plan tag, and silent right status dot only when abnormal/unusable
    row.box(fn(head) {
      @sf.style_node(head, fn() { pl_head })
      head.box(fn(m) {
        @sf.style_node(m, fn() { pl_mark_box }, in_row=true)
        @sfbase.provider_mark_node(m, fn() { (text(p(), "runtime"), text(field(p(), "access"), "kind"), text(p(), "providerMark")) }, pl_logo)
      })
      |> ignore
      head.box(fn(n) {
        @sf.style_node(n, fn() { pl_name_row })
        n.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).fits(Is(true)) |> ignore
        @sf.words_node(n, name, fn() { if usable() { pl_name } else { pl_name_off } })
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        |> ignore
        n.show(at_once=true, fn() { plan_tag() != "" }, fn(a) {
          a.drops(Is(pl_drop_plan)) |> ignore
          @sf.row_tag_node(a, plan_tag)
        })
      })
      |> ignore
      if !sample {
        head.show(at_once=true, fn() { state_tone() >= 1 || !usable() }, fn(dot) {
          @sf.state_dot_node(
            dot,
            fn() {
              if state_tone() == 2 {
                "error"
              } else if state_tone() == 1 {
                "busy"
              } else {
                "offline"
              }
            },
            size=pl_dot_side,
          )
        })
      }
    })
    |> ignore
    // Line 2: compact quota slots (when available & usable) or compact single-line status/credits/key/fallback
    row.pick(
      fn() {
        if windows() {
          0
        } else if state_text() != "" {
          1
        } else if usable() && text(quota(), "state") == "ok" && text(quota(), "creditsText") != "" {
          2
        } else {
          3
        }
      },
      at_once=true,
      fn(sub, mode) {
        match mode {
          0 => {
            sub.width_share(Is(1.0)).gap(Is(@ui.Space::S0_5.px())) |> ignore
            @sfbase.quota_compact_node(sub, quota, group?, at_foot=fn() { state_text() == "" }, tips~)
            sub.show(at_once=true, fn() { state_text() != "" }, fn(al) {
              @sf.words_node(al, state_text, state_style) |> ignore
            })
          }
          1 => @sf.words_node(sub, state_text, state_style) |> ignore
          2 => {
            @sf.style_node(sub, fn() { pl_sub_row })
            @sf.words_node(sub, fn() { text(quota(), "creditsText") }, fn() { pl_meta_muted })
            .shrink(Is(0.0))
            |> ignore
            sub.show(at_once=true, fn() { text(quota(), "detail") != "" }, fn(dt) {
              dt.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(dt, fn() { text(quota(), "detail") }, fn() { pl_meta_muted_cut }) |> ignore
            })
          }
          _ =>
            sub.show(at_once=true, fn() { fallback_text() != "" }, fn(fb) {
              @sf.words_node(fb, fallback_text, fn() { pl_meta_muted_cut }) |> ignore
            })
        }
      },
    )
  })
  |> ignore
}

///|
/// Compact station profile row (`only != ""`), matching `pl_account_row_node`:
/// - Line 1: 20x20 mark box, account name + droppable plan tag, right-aligned doing/error mark.
/// - Line 2: compact quota slots when available, else independent silent metadata nodes (no `·`).
/// - Optional trouble + `seeFix` block underneath only when a trouble/quota block exists.
fn pl_station_row_node(
  r : @view.View,
  core : Core,
  station : String,
  pv : () -> Json?,
  tips : @sf.TipLayer,
  group? : () -> @sfbase.QuotaCompactGroup,
  lit? : @sf.CardRowLit,
  key_now? : () -> String,
) -> Unit {
  let id = fn() { text(pv(), "id") }
  let name = fn() { text(pv(), "name") }
  let plan_tag = fn() { pl_plan_tag(pv()) }
  let on = fn() { [("station", station), ("id", id())] }
  let calls = ["profile.check", "profile.quota"]
  let quota = fn() { field(pv(), "quota") }
  let has_trouble_obj = fn() { field(pv(), "trouble") is Some(Object(_)) }
  let trouble_title = fn() {
    match field(pv(), "trouble") {
      Some(Object(_)) as t => text(t, "title")
      _ => ""
    }
  }
  let trouble_detail = fn() {
    match field(pv(), "trouble") {
      Some(Object(_)) as t => text(t, "detail")
      _ =>
        match text(quota(), "state") {
          "blocked" | "unavailable" | "unsupported" => text(quota(), "detail")
          _ => ""
        }
    }
  }
  let uses_or_kind = fn() {
    if flag(pv(), "machine") {
      text(pv(), "kindText")
    } else {
      match text(pv(), "usesText") {
        "" => text(pv(), "kindText")
        u => u
      }
    }
  }
  let press = fn() { (core.push)(Profile(station, @signals.untracked(id))) }
  r.box(fn(row) {
    row.transitions_only() |> ignore
    @sf.style_node(row, fn() { pl_row_multi })
    row.radius(Is(@sf.row_corner)) |> ignore
    match (lit, key_now) {
      (Some(g), Some(k)) => g.bind_top_now(k, row)
      _ => ()
    }
    @sf.hover_ground_node(row)
    @sf.rippled_node(row, press, @sf.row_corner, name)
    row.on_menu(fn(m) { pl_menu(press, text(@signals.untracked(pv), "name"), m) }) |> ignore
    // Line 1: mark, name + droppable plan tag, right-aligned doing mark
    row.box(fn(head) {
      @sf.style_node(head, fn() { pl_head })
      head.box(fn(m) {
        @sf.style_node(m, fn() { pl_mark_box }, in_row=true)
        @sfbase.provider_mark_node(m, fn() { (text(pv(), "runtime"), text(field(pv(), "access"), "kind"), text(pv(), "providerMark")) }, pl_logo)
      })
      |> ignore
      head.box(fn(n) {
        @sf.style_node(n, fn() { pl_name_row })
        n.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).fits(Is(true)) |> ignore
        @sf.words_node(n, name, fn() { pl_name }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        n.show(at_once=true, fn() { plan_tag() != "" }, fn(a) {
          a.drops(Is(pl_drop_plan)) |> ignore
          @sf.row_tag_node(a, plan_tag)
        })
      })
      |> ignore
      head.show(at_once=true, fn() { is_doing(core, calls, on()) || failed_of(core, calls, on()) is Some(_) }, fn(t) {
        @sf.style_node(t, fn() { pl_tail }, in_row=true)
        doing_mark_node(t, fn() { is_doing(core, calls, on()) }, fn() { failed_of(core, calls, on()) }, tips~)
      })
    })
    |> ignore
    // Line 2: compact quota slots if available, else independent silent metadata nodes (no `·`)
    row.pick(fn() { @sfbase.has_quota(quota()) }, at_once=true, fn(sub, has_q) {
      if has_q {
        @sfbase.quota_compact_node(sub, quota, group?, at_foot=fn() { trouble_title() == "" && trouble_detail() == "" }, tips~)
      } else {
        @sf.style_node(sub, fn() { pl_sub_row })
        sub.show(at_once=true, fn() { text(pv(), "checkText") != "" }, fn(x) {
          @sf.words_node(x, fn() { text(pv(), "checkText") }, fn() { pl_meta_muted }).shrink(Is(0.0)) |> ignore
        })
        sub.show(at_once=true, fn() { uses_or_kind() != "" }, fn(x) {
          x.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(x, uses_or_kind, fn() { pl_meta_muted_cut }) |> ignore
        })
        sub.show(at_once=true, fn() { text(pv(), "modelsText") != "" }, fn(x) {
          x.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(x, fn() { text(pv(), "modelsText") }, fn() { pl_meta_muted_cut }) |> ignore
        })
      }
    })
    // Trouble + seeFix when present
    row.show(at_once=true, fn() { trouble_title() != "" || trouble_detail() != "" }, fn(c) {
      @sf.style_node(c, fn() { pl_trouble })
      c.show(at_once=true, fn() { trouble_title() != "" }, fn(tt) {
        @sf.words_node(tt, trouble_title, fn() { pl_offer_note }) |> ignore
      })
      c.show(at_once=true, fn() { trouble_detail() != "" }, fn(td) {
        @sf.words_node(td, trouble_detail, fn() { pl_offer_note }) |> ignore
      })
      c.show(at_once=true, has_trouble_obj, fn(f) {
        @sf.words_node(f, fn() { @sf.t("android-settings.profile.seeFix") }, fn() { pl_see_fix }) |> ignore
      })
    })
  })
  |> ignore
}

///|
/// An account's row menu at the pointer's other button's press `m`: its page opened (`open`), its `name` copied.
fn pl_menu(open : () -> Unit, name : String, m : @view.Menu) -> Unit {
  @sf.menu(
    [
      Some(@sf.menu_item_of(@sf.t("web-pages.rowMenu.open"), open, icon="arrow-up-right")),
      copy_item("web-pages.rowMenu.copyName", name),
    ].filter(fn(i) { i is Some(_) }),
    from=@sf.at_point(m.wx, m.wy),
  )
}

///|
/// The accounts a station machine's own Claude Code and Codex are signed in with that no profile uses yet
/// (machine_login_offers' MachineLoginOffers), `s` the station, `logins` those it has: a section titled by the station
/// they are on, a list card's row each. Its vendor's mark, what it is, its plan and what is done with it on its first
/// line (the mark and the action on that line, never across the row's lines: the user, 2026-11-14); how it is signed in,
/// what is wrong and its allowance under them, from the mark. One the station reads used as it is
/// (`profile.useMachineLogin`, its page opened over the list), one it cannot signed in again for still.fail (`go_new`),
/// a refused one only said so.
fn pl_machine_offers_node(
  b : @view.View,
  core : Core,
  station : String,
  s : () -> Json?,
  logins : () -> Json?,
  go_new : (String) -> Unit,
  tips : @sf.TipLayer,
) -> Unit {
  let offers = fn() {
    match logins() {
      Some(Array(a)) => a.filter(fn(l) { flag(Some(l), "offered") })
      _ => []
    }
  }
  b.show(fn() { offers().length() > 0 }, fn(x) {
    @sf.style_node(x, fn() { pl_offers })
    @sf.section_heading_node(x, fn() { @sf.t("web-mobile.profiles.machineLogins", args=[("station", text(s(), "name"))]) })
    @sf.group_node(x, fn(g) {
      g.each(offers, fn(l) { text(Some(l), "runtime") }, fn(row, l) {
        let lv = fn() { Some(l.get()) }
        let rt = @signals.untracked(fn() { text(lv(), "runtime") })
        let quota = fn() { field(lv(), "quota") }
        let blocked = fn() { text(quota(), "state") == "blocked" }
        let trouble = fn() {
          match text(quota(), "state") {
            "blocked" | "unavailable" | "unsupported" => text(quota(), "detail")
            _ => ""
          }
        }
        @sf.link_row_node(
          row,
          fn() { @settings.runtime_label(rt) },
          fn() {  },
          goes=false,
          lead=LeadLine(fn(m) { @sf.provider_logo_node(m, rt, "subscription", pl_logo, "") |> ignore }),
          lines_from_lead=true,
          title_cut=true,
          title_after=fn(a) {
            a.drops(Is(pl_drop_plan)) |> ignore
            @sf.row_tag_node(a, fn() { text(lv(), "planText") })
          },
          title_after_shown=fn() { text(lv(), "planText") != "" },
          // (a refused one has nothing to do with it here)
          control=fn(e) {
            e.show(fn() { !blocked() }, fn(y) {
              // (the card's first row's in its top end corner, concentric with it; another's at its row's end)
              let first = fn() { offers().get(0).map(fn(o) { text(Some(o), "runtime") }) == Some(rt) }
              y.pick(fn() { (flag(lv(), "usable"), first()) }, fn(z, k) {
                let (usable, first) = k
                let end = fn(label : () -> String, press : () -> Unit, busy : () -> Bool) {
                  if first {
                    @sf.row_corner_button_node(z, label, press, busy~)
                  } else {
                    @sf.row_end_button_node(z, label, press, busy~)
                  }
                }
                let button = if usable {
                  end(
                    fn() { @sf.t("android-settings.machine.use") },
                    fn() {
                      (core.call)("profile.useMachineLogin", obj([("station", str(station)), ("runtime", str(rt))]), fn(r) {
                        match r {
                          Ok(v) => {
                            (core.say)(@sf.t("android-settings.machine.added"))
                            (core.push)(Profile(station, text(Some(v), "id")))
                          }
                          Err(e) => (core.say)(@settings.error_text(e))
                        }
                      })
                    },
                    fn() { is_doing(core, ["profile.useMachineLogin"], [("station", station), ("runtime", rt)]) },
                  )
                } else {
                  end(fn() { @sf.t("android-settings.login.signIn") }, fn() { go_new(rt) }, fn() { false })
                }
                @sf.tip_node(tips, button, fn() {
                  if usable {
                    @sf.t("web-pages.profiles.useMachineTip")
                  } else {
                    @sf.t("web-pages.profiles.keychainTip", args=[("name", @sf.product())])
                  }
                })
                |> ignore
              })
            })
          },
          below=fn(q) {
            q.box(fn(c) {
              @sf.style_node(c, fn() { pl_offer_under })
              c.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              // (how it is signed in: a dot in its tone, then status and email as separate nodes, no `·`)
              c.box(fn(line) {
                @sf.style_node(line, fn() { pl_offer_signed })
                @sf.state_dot_node(line, fn() { if blocked() { "error" } else { "online" } }, size=pl_offer_dot)
                @sf.words_node(line, fn() {
                  @sf.t(if blocked() { "android-settings.quota.blocked" } else { "android-settings.machine.signedIn" })
                }, fn() { if blocked() { pl_offer_bad_status } else { pl_offer_status } })
                .shrink(Is(0.0))
                |> ignore
                @sf.words_node(line, fn() {
                  match text(lv(), "email") {
                    "" => @sf.t("android-settings.machine.someone")
                    e => e
                  }
                }, fn() { if blocked() { pl_offer_bad_line } else { pl_offer_line } })
                .grow(Is(1.0))
                .shrink(Is(1.0))
                .min_width(Is(Some(0.0)))
                |> ignore
              })
              |> ignore
              c.show(fn() { trouble() != "" }, fn(y) {
                @sf.words_node(y, trouble, fn() { if blocked() { pl_offer_bad_note } else { pl_offer_note } }) |> ignore
              })
              @sfbase.quota_chips_node(c, quota, tips~)
            })
            |> ignore
          },
          below_open=fn() { 1.0 },
        )
      })
    })
  })
}

///|
/// A check's tone as a dot's state.
fn pl_tone_dot(tone : String) -> String {
  match tone {
    "green" => "online"
    "red" => "error"
    "neutral" => "offline"
    _ => "busy"
  }
}

///|
/// The workspace's profiles made up, for what is shown while they are read (in their bones): three of one kind.
// kept across runs: a value (no field of it changes)
let profiles_sample : Array[Json] = [(8, 14), (6, 18), (9, 12)].mapi(fn(i, n) {
  Json::object({
    "key": Json::string("sample" + i.to_string()),
    "usable": true,
    "group": "",
    "groupTitle": Json::string(@sf.sample_words(4)),
    "where": Json::string(@sf.sample_words(n.1)),
    "profile": {
      "id": Json::string("sample" + i.to_string()),
      "name": Json::string(@sf.sample_words(n.0)),
      "group": "",
      "kindText": Json::string(@sf.sample_words(n.1)),
    },
  })
})

///|
/// An account on several stations (ProfileAccountScreen) in node `v`, by its key in the workspace's profiles, laid out by
/// the `width` its frame gives it, in the frame it is given: its name, under it its account, kind and plan; how it is
/// (its check), its allowance (profile_quota_node, its page's), then each station it is signed in on, a row each leading
/// to its page there. While it is read, a made-up one's in its bones; gone from the workspace, said so.
pub fn profile_account_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  key : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let tips = match tips {
    Some(t) => t
    None => @sf.TipLayer::new(fn() { Some(v) })
  }
  // (that account alone, whole: its own topic, by its key; null where the workspace has it no more)
  let topic = fn() { @settings.profile_by_key_read(core, here(), key) }
  let entry_now = @signals.computed(fn(_) {
    match topic().value {
      Some(Object(_)) as x => x
      _ => None
    }
  }, same=json_opt_same)
  let ev = fn() { entry_now.get() }
  let p = fn() { field(ev(), "profile") }
  let members_now = @signals.computed(fn(_) { items(ev(), "members").filter(fn(m) { text(Some(m), "role") != "user" }) }, same=jsons_same)
  @sf.page_node(
    v,
    fn() {
      match text(p(), "name") {
        "" => "Profile"
        n => n
      }
    },
    fn() {
      match ev() {
        None => if topic().value is Some(_) { ["none"] } else { ["waiting"] }
        // (each station it is on a block of its own, a piece of their card: only those that show made)
        Some(_) => ["check", "quota", "each"] + members_now.get().map(fn(m) { "m/" + pa_member_key(m) })
      }
    },
    fn(b, k) {
      match k {
        "none" => @sf.page_note_node(b, fn() { @sf.t("android-settings.profile.none") })
        "waiting" =>
          @sf.waiting_node(
            b,
            fn(s) {
              @sf.group_node(s, fn(g) {
                g.each(fn() { account_members_sample }, fn(m) { text(Some(m), "station") }, fn(r, m) {
                  pa_member_row_node(r, core.quiet(), fn() { Some(m.get()) })
                })
              })
            },
            error=fn() {
              match topic().error {
                Some(x) => error_text(x)
                None => ""
              }
            },
          )
        "check" =>
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(
              g,
              fn() { text(p(), "checkText") },
              fn() {  },
              goes=false,
              // (what its check says; when its allowance was read is said under the allowance: account_blocks')
              note=fn() {
                match opt_text(field(p(), "check"), "detail") {
                  Some(x) => x
                  None => @sf.t("android-settings.profile.notChecked")
                }
              },
              lead=LeadLine(fn(l) { @sf.state_dot_node(l, fn() { pl_tone_dot(text(p(), "checkTone")) }) }),
            )
          })
        // (by the station and the profile it is asked of as they are now: an account on several stations may come to be
        // read of another, the block kept)
        "quota" =>
          b.pick(fn() { (text(ev(), "station"), text(p(), "id")) }, fn(q, at) {
            profile_quota_node(q, core, at.0, at.1, fn() { None }, p, Some(tips), read_under=true)
          })
        "each" => @sf.section_heading_node(b, fn() { @sf.t("web-pages.profiles.account.each") })
        k if k.has_prefix("m/") => {
          let key = k.exact_view(start=2).to_owned()
          // (as it is now, as it was last while it goes; its piece of the card by where it is among them)
          let last : Ref[(Json, @sf.CardPiece)?] = Ref(None)
          let now = fn() {
            let all = members_now.get()
            for i, m in all {
              if pa_member_key(m) == key {
                last.val = Some((m, @sf.card_piece_of(i, all.length())))
              }
            }
            last.val
          }
          let mv = @signals.computed(fn(_) { now().map(fn(n) { n.0 }) }, same=json_opt_same)
          guard @signals.untracked(fn() { mv.get() }) is Some(_) else { return }
          @sf.card_piece_node(b, fn() { now().map(fn(n) { n.1 }).unwrap_or(@sf.CardPiece::CardWhole) }, wide_group=true, fn(card) {
            pa_member_row_node(card, core, fn() { mv.get() })
          })
        }
        _ => ()
      }
    },
    on_back~,
    frame~,
    lead=fn() { join([text(p(), "email"), text(p(), "kindText"), text(p(), "planText")], " · ") },
    said?,
    width?,
    tips~,
  )
}

///|
/// A station an account is signed in on, by its key among them: the station and its profile there.
fn pa_member_key(m : Json) -> String {
  text(Some(m), "station") + "/" + text(Some(m), "profileId")
}

///|
/// A station an account is signed in on (account_blocks' row), `mv` as it is now: how it is there by its first line, the
/// station's name; under it what it is there, or that the station is away. Pressed, its page there.
fn pa_member_row_node(r : @view.View, core : Core, mv : () -> Json?) -> Unit {
  @sf.link_row_node(
    r,
    fn() { text(mv(), "title") },
    fn() {
      let m = @signals.untracked(mv)
      (core.push)(Profile(text(m, "station"), text(m, "profileId")))
    },
    note=fn() { if flag(mv(), "online") { text(mv(), "about") } else { @sf.t("android-settings.profiles.stationOffline") } },
    lead=LeadLine(fn(l) {
      @sf.state_dot_node(l, fn() {
        if !flag(mv(), "online") {
          "offline"
        } else if !flag(mv(), "usable") {
          "error"
        } else {
          pl_tone_dot(text(mv(), "checkTone"))
        }
      })
    }),
    title_cut=true,
  )
}

///|
/// The stations an account is on made up, for what its page shows while it is read (in their bones).
// kept across runs: a value (no field of it changes)
let account_members_sample : Array[Json] = [6, 9].mapi(fn(i, n) {
  Json::object({
    "station": Json::string("sample/" + i.to_string()),
    "profileId": "sample",
    "title": Json::string(@sf.sample_words(n)),
    "about": Json::string(@sf.sample_words(n + 6)),
    "online": true,
    "usable": true,
    "checkTone": "green",
  })
})

// ── styles ─────────────────────────────────────────

///|
/// A dimmed account's (its station away) opacity.
let pl_away : Double = 0.55

///|
/// An account's vendor's mark by its name.
let pl_logo : Double = 18.0

///|
/// Compact status dot size on an account row (matches `station_dot_side`).
let pl_dot_side : Double = 6.0

///|
/// Its plan after its name leaves its line before the name is cut short under four of its size.
let pl_drop_plan : Int = 1

///|
/// Its allowance's windows, a line of their own 6 under its words (used by share_quota.mbt).
// kept across runs: a value (no field of it changes)
let pl_quota_line : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
/// Compact two-line account row: symmetric 12pt horizontal and 10pt vertical padding, 4pt line gap, >= 44pt height.
// kept across runs: a value (no field of it changes)
let pl_row_multi : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S1 min_h=S11")

///|
/// Line 1 of an account row: mark, name + plan tag, optional right state dot.
// kept across runs: a value (no field of it changes)
let pl_head : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pl_mark_box : @ui.Style = @ui.css("w=S5 h=S5 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let pl_name_row : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pl_name : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Subtle, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let pl_name_off : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let pl_sub_row : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pl_meta_muted : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pl_meta_muted_cut : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let pl_meta_amber_cut : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=WarnInk, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let pl_meta_red_cut : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=Danger, wrap=false, w=Cut)

///|
/// What is under way with a station's profile and its unscoped allowance at its row's end, 8 apart.
// kept across runs: a value (no field of it changes)
let pl_tail : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
/// The machine's own logins' section: its title and card.
// kept across runs: a value (no field of it changes)
let pl_offers : @ui.Style = @ui.css("w=Full")

///|
/// What is under a machine's login's first line: how it is signed in, what is wrong, its allowance, 2 apart.
// kept across runs: a value (no field of it changes)
let pl_offer_under : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
/// How a machine's login is signed in: its dot, status, and email as separate nodes, 6 apart.
// kept across runs: a value (no field of it changes)
let pl_offer_signed : @ui.Style = @ui.css("row w=Full gap=S1_5 align=ACenter")

///|
/// How a machine's login is signed in, its dot across.
let pl_offer_dot : Double = 6.0

///|
// kept across runs: a value (no field of it changes)
let pl_offer_status : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pl_offer_bad_status : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pl_offer_line : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let pl_offer_bad_line : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let pl_offer_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let pl_offer_bad_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger, w=Full)

///|
/// Why a station's profile cannot be used, and how to mend it: 2 apart.
// kept across runs: a value (no field of it changes)
let pl_trouble : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
/// How to mend it, in the link's ink.
// kept across runs: a value (no field of it changes)
let pl_see_fix : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=AccentText, wrap=false)

///|
/// A wait said on a card: its words a row's room in.
// kept across runs: a value (no field of it changes)
let pl_wait_room : @ui.Style = @ui.css("w=Full px=S4 py=S3")
