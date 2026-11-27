// Which stations may use a shared account (可用的 station), for one account's page (pick_stations) and for the
// profiles' batch management page (pick_stations_many), plus batch move / refresh / delete helpers.

///|
/// What a 可用的 station dialog is choosing: the workspace's stations (ShareStation, or a station's row: `id`, `name`,
/// `online`, `acceptAutoChats`, `tasksOnly`), the one that has the account (`own`, ticked and not to be unticked; ""
/// where the accounts are on several stations), which others are ticked, every station as it was said with none
/// other than `own` to tick (`future_all`), and whether it follows the whitelist (`follow`, offered where `auto_ok`).
priv struct SharePick {
  stations : Array[Json]
  own : String
  ticked : @sf.LiveMap[String, Bool]
  future_all : @signals.Signal[Bool]
  follow : @signals.Signal[Bool]
  auto_ok : Bool
}

///|
/// A station on the workspace's whitelist as its item says it: it takes automatically assigned chats and does not
/// only run tasks (the core's `onWhitelist`, the station's `autoAllow`).
fn share_on_whitelist(x : Json) -> Bool {
  flag(Some(x), "acceptAutoChats") && !flag(Some(x), "tasksOnly") && text(Some(x), "mode") != "tasks"
}

///|
fn SharePick::others(self : SharePick) -> Bool {
  for i = 0; i < self.stations.length(); i = i + 1 {
    if text(Some(self.stations[i]), "id") != self.own {
      return true
    }
  }
  false
}

///|
/// Every station ticked (none but `own`: as said), not following the whitelist.
fn SharePick::all(self : SharePick) -> Bool {
  if self.follow.get() {
    return false
  }
  if self.others() {
    for i = 0; i < self.stations.length(); i = i + 1 {
      let xid = text(Some(self.stations[i]), "id")
      if xid != self.own && !self.ticked.get(xid).unwrap_or(false) {
        return false
      }
    }
    true
  } else {
    self.future_all.get()
  }
}

///|
/// Whether anything more than `own` is chosen: every station, the whitelist (a rule, even while it names none), or one
/// ticked.
fn SharePick::any(self : SharePick) -> Bool {
  if self.all() || self.follow.get() {
    return true
  }
  for i = 0; i < self.stations.length(); i = i + 1 {
    let xid = text(Some(self.stations[i]), "id")
    if xid != self.own && self.ticked.get(xid).unwrap_or(false) {
      return true
    }
  }
  false
}

///|
/// How many stations are on the whitelist now (`own` counted where it is on it).
fn SharePick::listed(self : SharePick) -> Int {
  self.stations.iter().filter(share_on_whitelist).count()
}

///|
/// Ticks every station other than `own` as `ticked` says of it.
fn SharePick::tick_all(self : SharePick, ticked : (Json) -> Bool) -> Unit {
  for x in self.stations {
    let xid = text(Some(x), "id")
    if xid != self.own {
      self.ticked.set(xid, ticked(x))
    }
  }
}

///|
/// The stations ticked besides `own`, as ids.
fn SharePick::picked(self : SharePick) -> Array[String] {
  self.stations.filter_map(fn(x) {
    let xid = text(Some(x), "id")
    if xid != self.own && self.ticked.get(xid).unwrap_or(false) {
      Some(xid)
    } else {
      None
    }
  })
}

///|
/// A pick of `stations` for the account on `own`: following the whitelist (`follow`, where the station can, `auto_ok`),
/// its rows showing the stations on it; else every station (`allowed` None, not `initial`); else those `allowed` names;
/// a first share or neutral multi-select only `own`.
fn share_pick_of(stations : Array[Json], own : String, allowed : Array[String]?, initial : Bool, follow : Bool, auto_ok : Bool) -> SharePick {
  let following = follow && auto_ok
  let ticked : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  for x in stations {
    let xid = text(Some(x), "id")
    ticked.put(
      xid,
      if following {
        xid == own || share_on_whitelist(x)
      } else if initial {
        xid == own
      } else {
        match allowed {
          None => true
          Some(a) => a.contains(xid)
        }
      },
    )
  }
  {
    stations,
    own,
    ticked,
    future_all: @signals.signal(!initial && !following && allowed is None),
    follow: @signals.signal(following),
    auto_ok,
  }
}

///|
/// The dialog's choice in node `v`: 全部 station and 跟随工作区白名单 (one or the other, the rows following what is
/// chosen), then each station, ticking one by hand choosing by hand (`own` ticked, not to be unticked, 此 station).
fn share_pick_node(v : @view.View, pick : SharePick) -> Unit {
  @sf.group_node(v, fn(g) {
    @sf.switch_row_node(
      g,
      fn() { @sf.t("web-pages.profiles.share.allStations") },
      fn() { pick.all() },
      fn(now) {
        pick.follow.set(false)
        pick.future_all.set(now)
        pick.tick_all(fn(_) { now })
      },
      note=fn() {
        if pick.all() {
          @sf.t("web-pages.profiles.share.futureIn")
        } else {
          @sf.t("web-pages.profiles.share.futureOut")
        }
      },
    )
    @sf.switch_row_node(
      g,
      fn() { @sf.t("web-pages.profiles.share.followAuto") },
      fn() { pick.follow.get() },
      fn(now) {
        pick.follow.set(now)
        if now {
          pick.future_all.set(false)
          pick.tick_all(share_on_whitelist)
        }
      },
      note=fn() {
        if !pick.auto_ok {
          @sf.t("web-pages.profiles.share.followAutoOld")
        } else if pick.listed() == 0 {
          @sf.t("web-pages.profiles.share.followAutoEmpty")
        } else {
          @sf.t("web-pages.profiles.share.followAutoNote", args=[("n", pick.listed().to_string())])
        }
      },
      disabled=fn() { !pick.auto_ok },
    )
  })
  @sf.group_node(v, fn(g) {
    g.each(fn() { pick.stations.mapi(fn(i, x) { (i, x) }) }, fn(x) { x.0 }, fn(row, x) {
      let xv = Some(x.untracked().1)
      let xid = text(xv, "id")
      let self = xid == pick.own
      @sf.switch_row_node(
        row,
        fn() { text(xv, "name") },
        fn() { self || pick.ticked.get(xid).unwrap_or(false) },
        fn(now) {
          if !self {
            // (chosen by hand: no longer every station nor the whitelist, the others as they were)
            pick.follow.set(false)
            pick.ticked.set(xid, now)
          }
        },
        note=fn() {
          if self {
            @sf.t("web-pages.profiles.share.here")
          } else if flag(xv, "online") {
            ""
          } else {
            @sf.t("web-pages.stations.offline")
          }
        },
        disabled=fn() { self },
      )
    })
  })
}

///|
/// What `profile.share` is asked for one account on `own` once the pick is said: on, and following the whitelist,
/// every station (no `allow`), or those ticked with `own`; `among` the stations chosen from where it was shared already
/// (only theirs change: a choice made in another workspace stays), none for a first share (as it is said whole).
fn SharePick::params(self : SharePick, address : String, id : String, own : String, shared : Bool) -> Json {
  let params = [("station", str(address)), ("id", str(id)), ("on", Json::boolean(true))]
  if self.follow.get() {
    params.push(("allowAuto", Json::boolean(true)))
    return obj(params)
  }
  if !self.all() {
    let allow : Array[Json] = [str(own)]
    for s in self.picked() {
      if s != own {
        allow.push(str(s))
      }
    }
    params.push(("allow", Json::array(allow)))
  }
  if shared {
    params.push(("among", Json::array(self.stations.map(fn(x) { str(text(Some(x), "id")) }))))
  }
  obj(params)
}

///|
/// 可用的 station of the account `id` on station `address` (whose id is `own`): every station, the whitelist
/// (`follow`, where the station can, `auto_ok`), or those ticked; a first share's (`initial`) with its confirmation's
/// words, a Claude subscription's warning with them. `stop`: when true and `!initial`, offers 停止分享 alongside
/// 取消 and 完成 (used by 批量管理; account detail pages leave `stop=false` because they already have a toggle).
fn pick_stations(
  core : Core,
  address : String,
  id : String,
  stations : Array[Json],
  own : String,
  allowed : Array[String]?,
  initial? : Bool = false,
  subscription? : Bool = false,
  claude? : Bool = false,
  follow? : Bool = false,
  auto_ok? : Bool = false,
  stop? : Bool = false,
  still_here? : () -> Bool = fn() { true },
) -> Unit {
  let pick = share_pick_of(stations, own, allowed, initial, follow, auto_ok)
  let title = if initial {
    if claude {
      @sf.t("web-pages.profiles.share.confirmClaudeTitle")
    } else {
      @sf.t("web-pages.profiles.share.confirmTitle")
    }
  } else {
    @sf.t("web-pages.profiles.share.stations")
  }
  let description = if initial {
    if claude {
      @sf.t("web-pages.profiles.share.confirmClaudeBody")
    } else if subscription {
      @sf.t("web-pages.profiles.share.confirmSubscriptionBody")
    } else {
      @sf.t("web-pages.profiles.share.confirmCopyBody")
    }
  } else {
    ""
  }
  open_dialog_nodes(
    title,
    description~,
    fn(v, _) {
      if initial && claude {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.share.confirmClaudeWarning") }, bad=fn() { true })
      }
      share_pick_node(v, pick)
    },
    fn(v, shut) {
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      if stop && !initial {
        @sf.button_node(
          v,
          fn() { @sf.t("web-pages.profiles.batch.stop") },
          fn() {
            shut()
            @sf.confirm(
              @sf.t("web-pages.profiles.sharing.stopOneTitle"),
              @sf.t("web-pages.profiles.sharing.stopOneBody"),
              @sf.t("web-pages.profiles.batch.stop"),
              fn() {
                if !@signals.untracked(still_here) {
                  return
                }
                @settings.act(
                  core,
                  @sf.t("web-pages.profiles.batch.stop"),
                  "profile.share",
                  obj([("station", str(address)), ("id", str(id)), ("on", Json::boolean(false))]),
                  done=@sf.t("web-pages.profiles.share.unshared"),
                )
              },
              danger=true,
            )
          },
          tone=GhostDanger,
        )
        |> ignore
      }
      @sf.button_node(
        v,
        fn() {
          if initial {
            if claude {
              @sf.t("web-pages.profiles.share.confirmUnderstood")
            } else {
              @sf.t("web-pages.profiles.share.confirmAction")
            }
          } else {
            @sf.t("web-pages.profiles.share.done")
          }
        },
        fn() {
          shut()
          if !@signals.untracked(still_here) {
            return
          }
          let params = pick.params(address, id, own, !initial)
          if initial {
            @settings.act(
              core,
              @sf.t("web-pages.profiles.share.switch"),
              "profile.share",
              params,
              done=@sf.t("web-pages.profiles.share.shared"),
            )
          } else {
            @settings.act(core, @sf.t("web-pages.profiles.share.stations"), "profile.share", params)
          }
        },
        tone=Primary,
        disabled=fn() { initial && !pick.any() },
      )
      |> ignore
    },
  )
}

// ── several accounts at once: 批量管理 ─────────────────────────────────────

///|
/// The station id of a station's address (`<workspace>/<id>`).
fn share_station_id(address : String) -> String {
  match address.find("/") {
    Some(i) => address.exact_view(start=i + 1).to_owned()
    None => address
  }
}

///|
/// What the batch share button says of the shareable accounts `rows`: 开启分享 where none is shared,
/// 可用 station where all are, 分享与 station where some are.
pub fn profiles_batch_label(rows : Array[Json]) -> String {
  let shared = rows.iter().filter(fn(r) { flag(Some(r), "shared") }).count()
  if shared == 0 {
    @sf.t("web-pages.profiles.batch.share")
  } else if shared == rows.length() {
    @sf.t("web-pages.profiles.batch.stations")
  } else {
    @sf.t("web-pages.profiles.batch.mixed")
  }
}

///|
/// Why an account cannot be shared in batch (`batchShareWhy`); "" where it can.
pub fn profiles_batch_why(row : Json?) -> String {
  match text(row, "batchShareWhy") {
    "" => ""
    why => @sf.t("web-pages.profiles.batch.why." + why)
  }
}

///|
/// Runs a batch of core calls `(row_key, op_name, params)` concurrently and invokes `done` once all settle with
/// `(row_key, error_text)` for each failed call (deduplicating repeated row keys while preserving first error).
fn batch_each(core : Core, calls : Array[(String, String, Json)], done : (Array[(String, String)]) -> Unit) -> Unit {
  let failed : Array[(String, String)] = []
  let seen_failed : Map[String, Bool] = Map([])
  let left = Ref(calls.length())
  if calls.length() == 0 {
    done(failed)
    return
  }
  for c in calls {
    let (key, op, params) = c
    (core.call)(op, params, fn(r) {
      match r {
        Ok(_) => ()
        Err(e) =>
          if !seen_failed.contains(key) {
            seen_failed[key] = true
            failed.push((key, error_text(e)))
          }
      }
      left.val -= 1
      if left.val == 0 {
        done(failed)
      }
    })
  }
}

///|
/// Reports batch completion: `ok_msg` when all succeeded, else partial failure summary.
fn batch_said(core : Core, n : Int, failed : Array[(String, String)], ok_msg : String) -> Unit {
  if failed.length() == 0 {
    (core.say)(ok_msg)
    @ui.haptic(Confirm)
  } else {
    @ui.haptic(Reject)
    (core.say)(
      @sf.t(
        "web-pages.profiles.batch.partial",
        args=[("ok", (n - failed.length()).to_string()), ("failed", failed.length().to_string()), ("why", failed[0].1)],
      ),
    )
  }
}

///|
/// The batch 可用的 station dialog for `rows` (shareable rows, `canBatchShare`) of `stations`:
/// - All whitelist (`all_auto`) -> pre-fills whitelist
/// - All every-station (`all_every`) -> pre-fills all stations
/// - All unshared (`all_unshared`) -> first-share default
/// - Mixed or multiple custom allow lists -> neutral undecided state (`initial=true, follow=false`, Primary disabled
///   until user explicitly chooses a policy).
pub fn pick_stations_many(
  core : Core,
  rows : Array[Json],
  stations : Array[Json],
  busy : @signals.Signal[Bool],
  done : (Array[String]) -> Unit,
  skipped? : Int = 0,
  still_here? : () -> Bool = fn() { true },
) -> Unit {
  if rows.is_empty() || stations.is_empty() {
    return
  }
  let hosts : Array[String] = []
  for r in rows {
    let h = share_station_id(text(Some(r), "station"))
    if !hosts.contains(h) {
      hosts.push(h)
    }
  }
  let own = if hosts.length() == 1 { hosts[0] } else { "" }
  let unshared = rows.filter(fn(r) { !flag(Some(r), "shared") })
  let claude = unshared.iter().any(fn(r) {
    let p = field(Some(r), "profile")
    text(p, "runtime") == "claude" && text(field(p, "access"), "kind") == "subscription"
  })
  let mut auto_ok = true
  let mut rows_all_auto = true
  let mut rows_all_every = true
  for i = 0; i < rows.length(); i = i + 1 {
    let rv = Some(rows[i])
    if !flag(rv, "batchShareAllowAuto") {
      auto_ok = false
    }
    let sa = flag(rv, "shareAuto")
    if !sa {
      rows_all_auto = false
    }
    if sa || field(rv, "shareStationCount") is Some(_) {
      rows_all_every = false
    }
  }
  let all_shared = unshared.is_empty()
  let all_auto = all_shared && rows_all_auto
  let all_every = all_shared && rows_all_every
  let all_unshared = unshared.length() == rows.length()
  let neutral_mixed = !(all_auto || all_every || all_unshared)
  let pick = if all_auto {
    share_pick_of(stations, own, None, false, true, auto_ok)
  } else if all_every {
    share_pick_of(stations, own, None, false, false, auto_ok)
  } else if all_unshared {
    share_pick_of(stations, own, None, true, auto_ok, auto_ok)
  } else {
    // Neutral undecided state: nothing pre-selected until user explicitly picks a target policy.
    share_pick_of(stations, own, None, true, false, auto_ok)
  }
  let title = if unshared.length() > 0 && claude {
    @sf.t("web-pages.profiles.share.confirmClaudeTitle")
  } else {
    profiles_batch_label(rows)
  }
  let description = @sf.t("web-pages.profiles.batch.applies", args=[("n", rows.length().to_string())])
  open_dialog_nodes(
    title,
    description~,
    fn(v, _) {
      if claude {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.share.confirmClaudeWarning") }, bad=fn() { true })
      }
      if skipped > 0 {
        @sf.page_note_node(v, fn() {
          @sf.t("web-pages.profiles.manage.skipShare", args=[("ok", rows.length().to_string()), ("skip", skipped.to_string())])
        })
      }
      if neutral_mixed {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.sharing.mixedOverride") })
      } else if unshared.length() > 0 {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.batch.sharesToo") })
      }
      if own == "" {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.batch.ownKept") })
      }
      if !auto_ok {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.batch.autoOld") })
      }
      share_pick_node(v, pick)
    },
    fn(v, shut) {
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      @sf.button_node(
        v,
        fn() {
          if claude {
            @sf.t("web-pages.profiles.share.confirmUnderstood")
          } else {
            @sf.t("web-pages.profiles.share.done")
          }
        },
        fn() {
          shut()
          if stations.is_empty() || !@signals.untracked(still_here) {
            return
          }
          let calls = rows.map(fn(r) {
            let rv = Some(r)
            let address = text(rv, "station")
            (
              text(rv, "key"),
              "profile.share",
              pick.params(address, text(field(rv, "profile"), "id"), share_station_id(address), flag(rv, "shared")),
            )
          })
          busy.set(true)
          batch_each(core, calls, fn(failed) {
            busy.set(false)
            if !@signals.untracked(still_here) {
              return
            }
            batch_said(core, calls.length(), failed, @sf.t("web-pages.profiles.batch.done", args=[("n", calls.length().to_string())]))
            done(failed.map(fn(f) { f.0 }))
          })
        },
        tone=Primary,
        disabled=fn() { !pick.any() },
      )
      |> ignore
    },
  )
}

///|
/// Batch 停止分享 for `rows`: confirms once, then stops sharing each shared row.
pub fn stop_sharing_many(
  core : Core,
  rows : Array[Json],
  busy : @signals.Signal[Bool],
  done : (Array[String]) -> Unit,
  still_here? : () -> Bool = fn() { true },
) -> Unit {
  let shared = rows.filter(fn(r) { flag(Some(r), "canBatchShare") && flag(Some(r), "shared") })
  if shared.length() == 0 {
    return
  }
  @sf.confirm(
    @sf.t("web-pages.profiles.batch.stopTitle", args=[("n", shared.length().to_string())]),
    @sf.t("web-pages.profiles.batch.stopBody"),
    @sf.t("web-pages.profiles.batch.stop"),
    fn() {
      if !@signals.untracked(still_here) {
        return
      }
      let calls = shared.map(fn(r) {
        let rv = Some(r)
        (
          text(rv, "key"),
          "profile.share",
          obj([("station", str(text(rv, "station"))), ("id", str(text(field(rv, "profile"), "id"))), ("on", Json::boolean(false))]),
        )
      })
      busy.set(true)
      batch_each(core, calls, fn(failed) {
        busy.set(false)
        if !@signals.untracked(still_here) {
          return
        }
        batch_said(core, calls.length(), failed, @sf.t("web-pages.profiles.batch.done", args=[("n", calls.length().to_string())]))
        done(failed.map(fn(f) { f.0 }))
      })
    },
    danger=true,
  )
}

///|
/// Batch 迁移到… (`profile.move`) for selected `rows`: picks a target station, explains skipped items (machine logins /
/// unsupported stations / already on target), confirms, and runs `profile.move` concurrently.
pub fn move_profiles_many(
  core : Core,
  rows : Array[Json],
  stations : Array[Json],
  busy : @signals.Signal[Bool],
  done : (Array[String]) -> Unit,
  still_here? : () -> Bool = fn() { true },
) -> Unit {
  let movable = rows.filter(fn(r) { can_move_row(r, stations~) })
  if movable.is_empty() || stations.is_empty() {
    return
  }
  let skipped_static = rows.length() - movable.length()
  open_dialog_bare_nodes(
    @sf.t("web-pages.profiles.manage.moveTitle"),
    description=@sf.t("web-pages.profiles.manage.moveDesc"),
    fn(v, shut) {
      if skipped_static > 0 {
        @sf.page_note_node(v, fn() {
          @sf.t("web-pages.profiles.manage.moveSkip", args=[("n", skipped_static.to_string())])
        })
      }
      v.box(fn(block) {
        @sf.style_node(block, fn() { @sf.panel_card_last_node(block) })
        @sf.group_node(block, fn(g) {
          g.each(fn() { stations.mapi(fn(i, x) { (i, x) }) }, fn(x) { x.0 }, fn(row, x) {
            let xv = Some(x.untracked().1)
            let online = flag(xv, "online")
            let target_addr = text(xv, "station")
            let target_id = text(xv, "id")
            let target_name = text(xv, "name")
            let all_here = movable.iter().all(fn(r) { text(Some(r), "station") == target_addr })
            let can_pick = online && !all_here
            @sf.link_row_node(
              row,
              fn() { target_name },
              fn() {
                shut()
                if !@signals.untracked(still_here) {
                  return
                }
                let to_move = movable.filter(fn(r) { text(Some(r), "station") != target_addr })
                if to_move.is_empty() {
                  (core.say)(@sf.t("web-pages.profiles.manage.moveNone", args=[("station", target_name)]))
                  return
                }
                let total_skip = rows.length() - to_move.length()
                let body = if total_skip > 0 {
                  @sf.t(
                    "web-pages.profiles.manage.moveConfirmBodySkip",
                    args=[("n", to_move.length().to_string()), ("station", target_name), ("skip", total_skip.to_string())],
                  )
                } else {
                  @sf.t("web-pages.profiles.manage.moveConfirmBody", args=[("station", target_name)])
                }
                @sf.confirm(
                  @sf.t("web-pages.profiles.manage.moveConfirmTitle", args=[("n", to_move.length().to_string()), ("station", target_name)]),
                  body,
                  @sf.t("web-pages.profiles.manage.moveAction"),
                  fn() {
                    if !@signals.untracked(still_here) {
                      return
                    }
                    let calls = to_move.map(fn(r) {
                      let rv = Some(r)
                      (
                        text(rv, "key"),
                        "profile.move",
                        obj([
                          ("station", str(text(rv, "station"))),
                          ("id", str(text(field(rv, "profile"), "id"))),
                          ("to", str(target_id)),
                        ]),
                      )
                    })
                    busy.set(true)
                    batch_each(core, calls, fn(failed) {
                      busy.set(false)
                      if !@signals.untracked(still_here) {
                        return
                      }
                      batch_said(
                        core,
                        calls.length(),
                        failed,
                        @sf.t("web-pages.profiles.manage.moveDone", args=[("n", calls.length().to_string()), ("station", target_name)]),
                      )
                      done(failed.map(fn(f) { f.0 }))
                    })
                  },
                )
              },
              value=fn() {
                if !online {
                  @sf.t("web-pages.stations.offline")
                } else if all_here {
                  @sf.t("web-pages.profiles.manage.moveHere")
                } else {
                  ""
                }
              },
              chevron=false,
              goes=can_pick,
              lead=LeadLine(fn(l) { @sf.state_dot_node(l, fn() { if online { "online" } else { "offline" } }) }),
            )
          })
        })
      })
      |> ignore
    },
  )
}

///|
/// Batch 刷新额度 for selected online `rows`: sends `profile.check` for each row and also `profile.quota` for
/// subscription/login/quota-bearing profiles.
pub fn refresh_profiles_many(
  core : Core,
  rows : Array[Json],
  busy : @signals.Signal[Bool],
  done : (Array[String]) -> Unit,
  still_here? : () -> Bool = fn() { true },
) -> Unit {
  if rows.is_empty() || !@signals.untracked(still_here) {
    return
  }
  let calls : Array[(String, String, Json)] = []
  for r in rows {
    let rv = Some(r)
    let key = text(rv, "key")
    let p = field(rv, "profile")
    let params = obj([("station", str(text(rv, "station"))), ("id", str(text(p, "id")))])
    calls.push((key, "profile.check", params))
    if shows_quota(p) && text(field(p, "quota"), "state") != "unsupported" {
      calls.push((key, "profile.quota", params))
    }
  }
  let count = rows.length()
  busy.set(true)
  batch_each(core, calls, fn(failed) {
    busy.set(false)
    if !@signals.untracked(still_here) {
      return
    }
    batch_said(core, count, failed, @sf.t("web-pages.profiles.manage.refreshDone", args=[("n", count.to_string())]))
    done(failed.map(fn(f) { f.0 }))
  })
}

///|
/// Batch 删除 (`profile.delete`) for selected online own `rows` with strong danger confirmation listing account &
/// host names.
pub fn delete_profiles_many(
  core : Core,
  rows : Array[Json],
  stations : Array[Json],
  busy : @signals.Signal[Bool],
  done : (Array[String]) -> Unit,
  still_here? : () -> Bool = fn() { true },
) -> Unit {
  let deletable = rows.filter(fn(r) { !flag(Some(r), "machine") })
  if deletable.is_empty() {
    return
  }
  let skipped = rows.length() - deletable.length()
  let preview : Array[String] = []
  for i, r in deletable {
    if i >= 3 {
      break
    }
    let rv = Some(r)
    let st = pm_station_name(stations, text(rv, "station"))
    preview.push(profiles_batch_name(rv) + " (" + st + ")")
  }
  let sep = @sf.t("web-main.list.separator")
  let list_text = if deletable.length() > 3 { preview.join(sep) + "…" } else { preview.join(sep) }
  let body = if skipped > 0 {
    @sf.t(
      "web-pages.profiles.manage.deleteBodySkip",
      args=[("n", deletable.length().to_string()), ("skip", skipped.to_string()), ("list", list_text)],
    )
  } else {
    @sf.t("web-pages.profiles.manage.deleteBody", args=[("n", deletable.length().to_string()), ("list", list_text)])
  }
  @sf.confirm(
    @sf.t("web-pages.profiles.manage.deleteTitle", args=[("n", deletable.length().to_string())]),
    body,
    @sf.t("web-pages.profiles.manage.delete"),
    fn() {
      if !@signals.untracked(still_here) {
        return
      }
      let calls = deletable.map(fn(r) {
        let rv = Some(r)
        (
          text(rv, "key"),
          "profile.delete",
          obj([("station", str(text(rv, "station"))), ("id", str(text(field(rv, "profile"), "id")))]),
        )
      })
      busy.set(true)
      batch_each(core, calls, fn(failed) {
        busy.set(false)
        if !@signals.untracked(still_here) {
          return
        }
        batch_said(core, calls.length(), failed, @sf.t("web-pages.profiles.manage.deleteDone", args=[("n", calls.length().to_string())]))
        done(failed.map(fn(f) { f.0 }))
      })
    },
    danger=true,
  )
}

///|
/// Parses a `maxConcurrentSessions` input: blank or `"0"` clears to unlimited (`Some(Json::null())`), a positive
/// 1..9 digit integer returns `Some(Json::number(n))`, and anything else (negative, non-digits, `"00"`, >= 10 digits)
/// returns `None`. Shared by single-account `ask_max_sessions` and batch `set_max_sessions_many`.
fn parse_max_sessions(raw : String) -> Json? {
  let trimmed = raw.trim(chars=" \t\n").to_owned()
  if trimmed == "" || trimmed == "0" {
    return Some(Json::null())
  }
  let mut n = 0
  let mut ok = trimmed.length() > 0 && trimmed.length() <= 9
  for c in trimmed {
    if c >= '0' && c <= '9' {
      n = n * 10 + (c.to_int() - '0'.to_int())
    } else {
      ok = false
    }
  }
  if ok && n > 0 {
    Some(Json::number(n.to_double()))
  } else {
    None
  }
}

///|
/// Batch 最大并发会话数 (`profile.put` with `maxConcurrentSessions`) for selected subscription/membership own `rows`.
pub fn set_max_sessions_many(
  core : Core,
  rows : Array[Json],
  busy : @signals.Signal[Bool],
  done : (Array[String]) -> Unit,
  still_here? : () -> Bool = fn() { true },
) -> Unit {
  let eligible = rows.filter(fn(r) { profile_max_sessions(field(Some(r), "profile")) })
  if eligible.is_empty() {
    (core.say)(@sf.t("web-pages.profiles.manage.maxSessionsNone"))
    return
  }
  let skipped = rows.length() - eligible.length()
  let base_hint = @sf.t("web-pages.profiles.maxConcurrentSessionsHint")
  let hint = if skipped > 0 {
    @sf.t(
      "web-pages.profiles.manage.maxSessionsHintSkip",
      args=[("ok", eligible.length().to_string()), ("n", skipped.to_string())],
    ) + " " + base_hint
  } else {
    base_hint
  }
  @sf.ask(
    @sf.t("web-pages.profiles.maxConcurrentSessions"),
    @sf.t("common.save"),
    fn(raw) {
      if !@signals.untracked(still_here) {
        return
      }
      match parse_max_sessions(raw) {
        None => @sfbase.toast_later(@sf.t("web-pages.profiles.maxConcurrentSessionsInvalid"))
        Some(val) => {
          let calls = eligible.map(fn(r) {
            let rv = Some(r)
            (
              text(rv, "key"),
              "profile.put",
              obj([
                ("station", str(text(rv, "station"))),
                ("id", str(text(field(rv, "profile"), "id"))),
                ("input", obj([("maxConcurrentSessions", val)])),
              ]),
            )
          })
          busy.set(true)
          batch_each(core, calls, fn(failed) {
            busy.set(false)
            if !@signals.untracked(still_here) {
              return
            }
            let ok_msg = if skipped > 0 {
              @sf.t(
                "web-pages.profiles.manage.maxSessionsDoneSkip",
                args=[("n", calls.length().to_string()), ("skip", skipped.to_string())],
              )
            } else {
              @sf.t("web-pages.profiles.manage.maxSessionsDone", args=[("n", calls.length().to_string())])
            }
            batch_said(core, calls.length(), failed, ok_msg)
            done(failed.map(fn(f) { f.0 }))
          })
        }
      }
    },
    value="",
    placeholder=@sf.t("web-pages.profiles.maxConcurrentSessionsUnlimited"),
    hint~,
    empty=true,
  )
}
