// Workspace-wide backup settings (`backup_node`), per-station backup configuration (`station_backup_node`), and the
// concise restore section on a station's 设置 tab (`station_copies_node`). Backed by the core's `copies.ts`
// (`StationCopies`) and `copies.*` ops (peer target selection, acceptOthers, encrypted R2/S3 targets, connection test,
// one-time generated recovery key display, and restore from peer or R2/S3).

///|
// kept across runs: a value (no field of it changes)
let copies_s3_actions : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let copies_form_pair : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let copies_key_card : @ui.Style = @ui.css("w=Full p=S3 bg=Surface border=B0_5 border_color=Line radius=Lg")

///|
// kept across runs: a value (no field of it changes)
let copies_key_words : @ui.TextStyle = @ui.text_style(size=Body, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let copies_test_ok : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=AccentText, w=Full)

///|
// kept across runs: a value (no field of it changes)
let copies_apply_bar : @ui.Style = @ui.css("w=Full gap=S2 pt=S2 align=AStart")

///|
/// Concise restore/status section shown on a station's 设置 tab when an empty station has restorable offers.
fn station_copies_node(
  b : @view.View,
  core : Core,
  address : String,
  copies : () -> Json?,
) -> Unit {
  st_section_node(
    b,
    fn() { @sf.t("web-pages.stations.copies.section") },
    fn(sec) {
      @sf.group_node(sec, fn(g) {
        copies_offers_or_line_node(g, core, address, copies)
      })
    },
  )
}

///|
/// Shared status line or restorable offers rows inside a `@sf.group_node`.
fn copies_offers_or_line_node(
  g : @view.View,
  core : Core,
  address : String,
  copies : () -> Json?,
  on_restored? : () -> Unit,
) -> Unit {
  let offers = fn() { items(copies(), "offers") }
  g.show(fn() { offers().length() == 0 }, fn(r) { said_row_node(r, fn() { text(copies(), "line") }) })
  g.each(offers, fn(x) { text(Some(x), "station") + "/" + text(Some(x), "gen") }, fn(row, x) {
    let can = fn() { flag(copies(), "canRestore") && !flag(Some(x.get()), "busy") }
    let from_s3 = fn() { text(Some(x.get()), "fromS3") != "" }
    row.pick(fn() { (can(), from_s3()) }, fn(r, k) {
      let (live, is_s3) = k
      if live && is_s3 {
        @sf.setting_node(r, fn() { text(Some(x.get()), "line") }, in_card=true, fn(e) {
          @sf.button_node(e, fn() { @sf.t("web-pages.stations.copies.restore") }, fn() {
            copies_restore_confirm(core, address, Some(@signals.untracked(fn() { x.get() })), on_restored?)
          }, tone=Primary)
          |> ignore
        })
      } else if live {
        @sf.corner_row_node(r, fn() { text(Some(x.get()), "line") }, fn(e) {
          @sf.button_node(e, fn() { @sf.t("web-pages.stations.copies.restore") }, fn() {
            copies_restore_confirm(core, address, Some(@signals.untracked(fn() { x.get() })), on_restored?)
          }, tone=Primary)
          |> ignore
        })
      } else {
        said_row_node(r, fn() { text(Some(x.get()), "line") })
      }
    })
  })
}

///|
/// Extract non-empty selected station IDs from a `backup` object.
fn copies_selected_ids(backup : Json?) -> Array[String] {
  let out : Array[String] = []
  for x in items(backup, "stations") {
    match x {
      String(s) if s != "" => out.push(s)
      _ => ()
    }
  }
  out
}

///|
/// Compute the UI mode ("auto" | "manual" | "off") from a `backup` object.
fn copies_mode_of(backup : Json?, picked_manual : Bool) -> String {
  if text(backup, "mode") == "auto" {
    "auto"
  } else if copies_selected_ids(backup).length() > 0 || picked_manual {
    "manual"
  } else {
    "off"
  }
}

///|
/// Format the note lines for an R2 / S3 target row (bucket + status, key fingerprint).
fn copies_s3_note(sv : Json?) -> String {
  let bucket = text(sv, "bucket")
  let status = text(sv, "statusLine")
  let fp = text(sv, "keyFingerprint")
  let line1 = if bucket != "" && status != "" {
    bucket + " · " + status
  } else if bucket != "" {
    bucket
  } else {
    status
  }
  let line2 = if fp != "" {
    @sf.t("web-pages.stations.copies.s3KeyFp", args=[("fp", fp)])
  } else {
    ""
  }
  if line1 != "" && line2 != "" {
    line1 + "\n" + line2
  } else if line1 != "" {
    line1
  } else {
    line2
  }
}

///|
/// Top-level 备份 page (`Route::Backup`): workspace-wide unified backup configuration (applying to all online stations
/// with a shared generated recovery key) plus per-station rows leading to `Route::StationBackup(address)`.
pub fn backup_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  stint~ : () -> Int,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let read = fn() { @settings.stations_of(core, here()).value }
  let stations_list = fn() -> Array[Json] {
    match read() {
      Some(Array(a)) => a
      _ => []
    }
  }
  let manager = fn() {
    let r = role_of(core, here())
    r == "owner" || r == "admin"
  }
  let station_copies = fn(address : String) -> Json? { @settings.station_part(core, here(), address, "copies") }
  let online_targets = fn() -> Array[(String, String)] {
    let out : Array[(String, String)] = []
    for s in stations_list() {
      if flag(Some(s), "online") {
        let addr = text(Some(s), "station")
        let id = text(Some(s), "id")
        if field(station_copies(addr), "backup") is Some(Object(_)) {
          out.push((addr, if id != "" { id } else { addr }))
        }
      }
    }
    out
  }
  let first_backup = fn() -> Json? {
    for s in stations_list() {
      if flag(Some(s), "online") {
        let addr = text(Some(s), "station")
        match field(station_copies(addr), "backup") {
          Some(Object(_)) as b => return b
          _ => ()
        }
      }
    }
    None
  }
  let init_backup = @signals.untracked(first_backup)
  let seeded = @signals.signal(init_backup is Some(Object(_)))
  let draft_mode = @signals.signal(
    match init_backup {
      Some(Object(_)) as b => copies_mode_of(b, false)
      _ => "auto"
    },
  )
  let draft_stations : @signals.Signal[Array[String]] = @signals.signal(
    match init_backup {
      Some(Object(_)) as b => copies_selected_ids(b)
      _ => []
    },
  )
  let draft_s3 : @signals.Signal[Array[Json]] = @signals.signal(
    match init_backup {
      Some(Object(_)) as b => items(b, "s3")
      _ => []
    },
  )
  let applying = @signals.signal(false)
  let s3_dirty = @signals.signal(false)
  let next_draft_seq = Ref(1)
  @sf.page_node(v, fn() { @sf.t("web-pages.backup.title") }, on_back~, frame~, said?, width?, fn() { ["about", "unified", "stations"] }, fn(b, key) {
    match key {
      "about" => @sf.page_note_node(b, fn() { @sf.t("web-pages.backup.description") })
      "unified" =>
        @sf.section_node(b, fn() { @sf.t("web-pages.backup.unified.title") }, fn(sec) {
          sec.reacts(first_backup, fn(fb) {
            if !seeded.untracked() {
              match fb {
                Some(Object(_)) as bk => {
                  seeded.set(true)
                  draft_mode.set(copies_mode_of(bk, false))
                  draft_stations.set(copies_selected_ids(bk))
                  draft_s3.set(items(bk, "s3"))
                }
                _ => ()
              }
            }
          })
          sec.pick(manager, fn(u, is_mgr) {
            if !is_mgr {
              @sf.page_note_node(u, fn() { @sf.t("web-pages.backup.unified.adminOnly") })
              return
            }
            @sf.group_node(u, fn(g) {
              @sf.setting_node(
                g,
                fn() { @sf.t("web-pages.stations.copies.modeLabel") },
                note=fn() { @sf.t("web-pages.stations.copies.modeNote") },
                in_card=true,
                fn(c) {
                  @sf.select_node(
                    c,
                    fn() { draft_mode.get() },
                    fn() {
                      [
                        ("auto", @sf.t("web-pages.stations.copies.modeAuto")),
                        ("manual", @sf.t("web-pages.stations.copies.modeManual")),
                        ("off", @sf.t("web-pages.stations.copies.modeOff")),
                      ]
                    },
                    fn(chosen) { draft_mode.set(chosen) },
                    label=fn() { @sf.t("web-pages.stations.copies.modeLabel") },
                    disabled=fn() { applying.get() },
                    whole=true,
                  )
                },
              )
              g.show(fn() { draft_mode.get() == "manual" }, fn(pm) {
                pm.show(fn() { stations_list().is_empty() }, fn(empty_row) {
                  said_row_node(empty_row, fn() { @sf.t("web-pages.stations.copies.noPeers") })
                })
                pm.each(stations_list, fn(s) { text(Some(s), "station") }, fn(row, s) {
                  let sv = fn() { Some(s.get()) }
                  let addr = text(@signals.untracked(sv), "station")
                  let id_raw = text(@signals.untracked(sv), "id")
                  let sid = if id_raw != "" { id_raw } else { addr }
                  @sf.switch_row_node(
                    row,
                    fn() { text(sv(), "name") },
                    fn() { draft_stations.get().contains(sid) },
                    fn(checked) {
                      let next = draft_stations.untracked().filter(fn(x) { x != sid })
                      if checked {
                        next.push(sid)
                      }
                      draft_stations.set(next)
                    },
                    note=fn() {
                      if !flag(sv(), "online") {
                        @sf.t("web-pages.stations.copies.peerOffline")
                      } else {
                        ""
                      }
                    },
                    busy=fn() { applying.get() },
                  )
                })
              })
            })
            st_section_node(
              u,
              fn() { @sf.t("web-pages.stations.copies.s3Heading") },
              ends=(fn() { true }, fn(e) {
                @sf.action_node(e, fn() { @sf.t("web-pages.stations.copies.s3Add") }, fn() {
                  let test_addr = match @signals.untracked(online_targets).get(0) {
                    Some((a, _)) => a
                    None => ""
                  }
                  copies_s3_form_dialog(
                    core,
                    test_addr,
                    None,
                    None,
                    on_save=Some(fn(entry, shut) {
                      let next = draft_s3.untracked().copy()
                      let with_id = match entry {
                        Object(fields) => {
                          let copy : Map[String, Json] = Map([])
                          fields.each(fn(fk, fv) { copy[fk] = fv })
                          if text(Some(entry), "id") == "" {
                            let seq = next_draft_seq.val
                            next_draft_seq.val = seq + 1
                            copy["id"] = str("s3-draft-" + seq.to_string())
                          }
                          Json::object(copy)
                        }
                        _ => entry
                      }
                      next.push(with_id)
                      draft_s3.set(next)
                      s3_dirty.set(true)
                      shut()
                    }),
                  )
                }, disabled=fn() { applying.get() })
              }),
              fn(s3_sec) {
                @sf.group_node(s3_sec, fn(g) {
                  g.show(fn() { draft_s3.get().is_empty() }, fn(r) {
                    said_row_node(r, fn() { @sf.t("web-pages.stations.copies.s3Empty") })
                  })
                  g.each(fn() { draft_s3.get() }, fn(x) {
                    let id = text(Some(x), "id")
                    if id != "" { id } else { text(Some(x), "name") + "/" + text(Some(x), "bucket") }
                  }, fn(row, x) {
                    let sv = fn() { Some(x.get()) }
                    let sid = text(@signals.untracked(sv), "id")
                    @sf.row_box_node(row, fn() { text(sv(), "name") }, fn(s) {
                      s.note(fn() { copies_s3_note(sv()) })
                      s.tail(fn(c) {
                        c.box(fn(btns) {
                          @sf.style_node(btns, fn() { copies_s3_actions })
                          @sf.button_node(btns, fn() { @sf.t("web-pages.stations.copies.s3Edit") }, fn() {
                            let test_addr = match @signals.untracked(online_targets).get(0) {
                              Some((a, _)) => a
                              None => ""
                            }
                            let cur_item = @signals.untracked(fn() { x.get() })
                            copies_s3_form_dialog(
                              core,
                              test_addr,
                              None,
                              Some(cur_item),
                              on_save=Some(fn(entry, shut) {
                                let next : Array[Json] = []
                                for item in draft_s3.untracked() {
                                  if text(Some(item), "id") == sid {
                                    next.push(entry)
                                  } else {
                                    next.push(item)
                                  }
                                }
                                draft_s3.set(next)
                                s3_dirty.set(true)
                                shut()
                              }),
                            )
                          }, tone=Ghost, disabled=fn() { applying.get() })
                          |> ignore
                          @sf.button_node(btns, fn() { @sf.t("web-pages.stations.copies.s3Delete") }, fn() {
                            let sname = @signals.untracked(fn() { text(sv(), "name") })
                            @sf.confirm(
                              @sf.t("web-pages.stations.copies.s3DeleteTitle", args=[("name", sname)]),
                              @sf.t("web-pages.stations.copies.s3DeleteBody", args=[("name", sname)]),
                              @sf.t("web-pages.stations.copies.s3Delete"),
                              fn() {
                                let kept = draft_s3.untracked().filter(fn(item) { text(Some(item), "id") != sid })
                                draft_s3.set(kept)
                                s3_dirty.set(true)
                              },
                              danger=true,
                            )
                          }, tone=Ghost, disabled=fn() { applying.get() })
                          |> ignore
                        })
                        |> ignore
                      })
                    })
                  })
                })
              },
            )
            u.box(fn(bar) {
              @sf.style_node(bar, fn() { copies_apply_bar })
              bar.show(fn() { online_targets().is_empty() }, fn(n) {
                @sf.page_note_node(n, fn() { @sf.t("web-pages.backup.unified.noOnline") })
              })
              @sf.button_node(
                bar,
                fn() {
                  if applying.get() {
                    @sf.t("web-pages.backup.unified.applying")
                  } else {
                    @sf.t("web-pages.backup.unified.apply")
                  }
                },
                fn() {
                  let targets = @signals.untracked(online_targets)
                  let total = @signals.untracked(stations_list).length()
                  let skipped = if total > targets.length() { total - targets.length() } else { 0 }
                  if targets.is_empty() {
                    return
                  }
                  applying.set(true)
                  let mode = draft_mode.untracked()
                  let sel = draft_stations.untracked()
                  let send_s3 = s3_dirty.untracked()
                  let current_s3 : Ref[Array[Json]] = Ref(draft_s3.untracked().map(copies_s3_draft_wire))
                  let generated_pairs : Array[(String, String)] = []
                  let generated_captured = Ref(false)
                  let ok_count = Ref(0)
                  let fail_count = Ref(0)
                  let first_err = Ref("")
                  fn run_step(idx : Int) -> Unit {
                    if idx >= targets.length() {
                      applying.set(false)
                      if fail_count.val > 0 {
                        (core.say)(
                          @sf.t(
                            "web-pages.backup.unified.failed",
                            args=[("n", fail_count.val.to_string()), ("error", first_err.val)],
                          ),
                        )
                      } else {
                        if send_s3 {
                          s3_dirty.set(false)
                        }
                        if skipped > 0 {
                          (core.say)(
                            @sf.t(
                              "web-pages.backup.unified.appliedPartial",
                              args=[("ok", ok_count.val.to_string()), ("skipped", skipped.to_string())],
                            ),
                          )
                        } else {
                          (core.say)(@sf.t("web-pages.backup.unified.applied", args=[("n", ok_count.val.to_string())]))
                        }
                      }
                      if generated_pairs.length() > 0 {
                        copies_generated_key_dialog(core, generated_pairs)
                      }
                      return
                    }
                    let (addr, self_id) = targets[idx]
                    let params : Array[(String, Json)] = [("station", str(addr))]
                    match mode {
                      "auto" => params.push(("mode", str("auto")))
                      "off" => {
                        params.push(("mode", str("manual")))
                        params.push(("stations", Json::array([])))
                      }
                      _ => {
                        let peers_for_this = sel.filter(fn(id) { id != self_id && id != addr })
                        params.push(("mode", str("manual")))
                        params.push(("stations", Json::array(peers_for_this.map(str))))
                      }
                    }
                    if send_s3 {
                      params.push(("s3", Json::array(current_s3.val)))
                    }
                    (core.call)("copies.setSettings", obj(params), fn(r) {
                      match r {
                        Ok(val) => {
                          ok_count.val = ok_count.val + 1
                          if send_s3 && !generated_captured.val {
                            let gen_map : Map[String, String] = Map([])
                            match field(Some(val), "generatedKeys") {
                              Some(Object(m)) =>
                                m.each(fn(k, gv) {
                                  match gv {
                                    String(s) if s != "" => {
                                      generated_pairs.push((k, s))
                                      gen_map[k] = s
                                    }
                                    _ => ()
                                  }
                                })
                              _ => ()
                            }
                            if gen_map.length() > 0 {
                              generated_captured.val = true
                              // Share the generated id and recovery key from the first succeeding station with the rest
                              let used : Map[String, Bool] = Map([])
                              let updated : Array[Json] = []
                              for item in current_s3.val {
                                let id = text(Some(item), "id")
                                let has_ek = text(Some(item), "encryptionKey") != ""
                                if !has_ek {
                                  let matched : (String, String)? = match gen_map.get(id) {
                                    Some(k) => {
                                      used[id] = true
                                      Some((id, k))
                                    }
                                    None if id == "" => {
                                      let mut fallback : (String, String)? = None
                                      gen_map.each(fn(gk, gv) {
                                        if fallback is None && !used.contains(gk) {
                                          used[gk] = true
                                          fallback = Some((gk, gv))
                                        }
                                      })
                                      fallback
                                    }
                                    None => None
                                  }
                                  match (item, matched) {
                                    (Object(fields), Some((gk, ek))) => {
                                      let copy : Map[String, Json] = Map([])
                                      fields.each(fn(fk, fv) { copy[fk] = fv })
                                      copy["id"] = str(gk)
                                      copy["encryptionKey"] = str(ek)
                                      updated.push(Json::object(copy))
                                    }
                                    _ => updated.push(item)
                                  }
                                } else {
                                  updated.push(item)
                                }
                              }
                              current_s3.val = updated
                            }
                          }
                        }
                        Err(e) => {
                          fail_count.val = fail_count.val + 1
                          if first_err.val == "" {
                            first_err.val = @settings.error_text(e)
                          }
                        }
                      }
                      run_step(idx + 1)
                    })
                  }
                  run_step(0)
                },
                tone=Primary,
                busy=fn() { applying.get() },
                disabled=fn() { applying.get() || online_targets().is_empty() },
              )
              |> ignore
            })
            |> ignore
          })
        })
      _ =>
        @sf.section_node(
          b,
          fn() { @sf.t("web-pages.backup.stations.title") },
          about=fn() { @sf.t("web-pages.backup.stations.description") },
          fn(sec) {
            sec.pick(fn() { read() is None }, fn(p, reading) {
              if reading {
                @sf.waiting_node(
                  p,
                  fn(s) {
                    backup_rows_node(
                      s,
                      core.quiet(),
                      stint,
                      fn() {
                        [5, 3].mapi(fn(i, n) {
                          Json::object({
                            "station": Json::string("sample/" + i.to_string()),
                            "name": Json::string(@sf.sample_words(n)),
                            "online": true,
                            "overview": {},
                          })
                        })
                      },
                      fn(_) { Some(Json::object({ "line": Json::string(@sf.sample_words(12)), "level": Json::string("ok"), "offers": Json::array([]) })) },
                    )
                  },
                  note=fn() { { reading: true, text: @sf.t("common.readingStations"), failing: [] } },
                )
              } else {
                backup_rows_node(p, core, stint, stations_list, station_copies)
              }
            })
          },
        )
    }
  })
}

///|
/// Each station's backup summary row on the 备份 page, opening `Route::StationBackup(address)`.
fn backup_rows_node(
  v : @view.View,
  core : Core,
  stint : () -> Int,
  stations : () -> Array[Json],
  copies_of : (String) -> Json?,
) -> Unit {
  @sf.group_node(v, fn(g) {
    g.each(stations, fn(s) { text(Some(s), "station") }, fn(row, s) {
      let address = text(Some(s.untracked()), "station")
      backup_row_node(row, core, stint, fn() { Some(s.get()) }, fn() { copies_of(address) })
    })
  })
}

///|
/// A station's row on the 备份 page: online dot + mark + name, current backup settings summary + status from `stationPart` `"copies"`.
fn backup_row_node(v : @view.View, core : Core, stint : () -> Int, s : () -> Json?, copies : () -> Json?) -> Unit {
  let view = fn() { if flag(s(), "online") { copies() } else { None } }
  let settings_line = fn() { text(field(view(), "backup"), "settingsSummary") }
  let status_line = fn() {
    if !flag(s(), "online") {
      @sf.t("web-pages.automaticDecisions.offline")
    } else {
      match view() {
        Some(Object(_)) as c => {
          let offers = items(c, "offers")
          if offers.length() > 0 {
            @sf.t("web-pages.backup.stations.restoreOffer", args=[("line", text(Some(offers[0]), "line"))])
          } else {
            text(c, "line")
          }
        }
        None => @sf.t("common.connecting")
        _ => @sf.t("web-pages.backup.stations.upgrade")
      }
    }
  }
  let bad = fn() {
    match view() {
      Some(Object(_)) as c => items(c, "offers").is_empty() && text(c, "level") == "red"
      _ => false
    }
  }
  let lead = @sf.station_lead(fn() { flag(s(), "online") }, fn() { text(s(), "emoji") }, fn() { text(s(), "icon") }, stint)
  @sf.link_row_node(
    v,
    fn() { text(s(), "name") },
    fn() { (core.push)(StationBackup(text(s(), "station"))) },
    note=fn() {
      let cfg = settings_line()
      if bad() {
        cfg
      } else {
        let st = status_line()
        if cfg != "" && st != "" {
          cfg + "\n" + st
        } else if cfg != "" {
          cfg
        } else {
          st
        }
      }
    },
    trouble=fn() { if bad() { status_line() } else { "" } },
    lead~,
    goes=true,
  )
}

///|
/// Format a byte count concisely (e.g. `18.4 MB`), or `""` when zero.
fn copies_format_bytes(n : Double) -> String {
  if n <= 0.0 {
    return ""
  }
  let units = ["B", "KB", "MB", "GB", "TB"]
  let mut i = 0
  let mut x = n
  while x >= 1000.0 && i < units.length() - 1 {
    x = x / 1000.0
    i += 1
  }
  if i == 0 {
    x.to_int().to_string() + " B"
  } else {
    let tenths = (x * 10.0 + 0.5).to_int()
    let whole = tenths / 10
    let frac = tenths % 10
    if whole >= 100 || frac == 0 {
      whole.to_string() + " " + units[i]
    } else {
      whole.to_string() + "." + frac.to_string() + " " + units[i]
    }
  }
}

///|
/// Deterministic UTC `MM-DD HH:mm` timestamp from epoch milliseconds (no wall-clock reads).
fn copies_format_time(at_ms : Double) -> String {
  if at_ms <= 0.0 {
    return ""
  }
  let pad2 = fn(n : Int) { if n < 10 { "0" + n.to_string() } else { n.to_string() } }
  let total_sec = (at_ms / 1000.0).to_int64()
  let days = total_sec / 86400L
  let rem = (total_sec % 86400L).to_int()
  let hh = rem / 3600
  let mm = (rem % 3600) / 60
  let z = days + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = (doy - (153L * mp + 2L) / 5L + 1L).to_int()
  let m = (mp + (if mp < 10L { 3L } else { -9L })).to_int()
  pad2(m) + "-" + pad2(d) + " " + pad2(hh) + ":" + pad2(mm)
}

///|
/// Format the detail subtitle for one `copies.history` record.
fn copies_history_detail(rv : Json?) -> String {
  let kind = text(rv, "kind")
  let ok = text(rv, "status") == "ok"
  let target_kind = if text(rv, "targetKind") == "s3" {
    @sf.t("web-pages.backup.station.historyKindS3")
  } else {
    @sf.t("web-pages.backup.station.historyKindStation")
  }
  let chats = number(rv, "chats").to_int()
  let bytes_text = copies_format_bytes(number(rv, "bytes"))
  let reason_text = fn() {
    match text(rv, "reason") {
      "offline" => @sf.t("web-pages.backup.station.historyReasonOffline")
      "old" => @sf.t("web-pages.backup.station.historyReasonOld")
      _ => {
        let err = text(rv, "error")
        if err != "" {
          err
        } else {
          @sf.t("web-pages.backup.station.historyReasonError")
        }
      }
    }
  }
  let parts : Array[String] = []
  if kind == "restore" {
    if ok {
      parts.push(@sf.t("web-pages.backup.station.historyRestoreOk"))
      if chats > 0 {
        parts.push(@sf.t("web-pages.backup.station.historyChats", args=[("n", chats.to_string())]))
      }
      if bytes_text != "" {
        parts.push(bytes_text)
      }
    } else {
      parts.push(@sf.t("web-pages.backup.station.historyRestoreFail"))
      parts.push(reason_text())
    }
  } else if ok {
    parts.push(@sf.t("web-pages.backup.station.historySyncOk"))
    if chats > 0 {
      parts.push(@sf.t("web-pages.backup.station.historyChats", args=[("n", chats.to_string())]))
    }
    if bytes_text != "" {
      parts.push(bytes_text)
    }
  } else {
    parts.push(@sf.t("web-pages.backup.station.historySyncFail"))
    parts.push(target_kind)
    parts.push(reason_text())
  }
  parts.join(" · ")
}

///|
/// A keeper's name, or the start of its id where the station did not say it.
fn copies_keeper_name(kv : Json?) -> String {
  match text(kv, "name") {
    "" => {
      let id = text(kv, "station")
      if id.length() > 8 { id[:8].to_owned() } else { id }
    }
    name => name
  }
}

///|
/// The history newest first with each run of syncs that went well to one place said once, by its newest: a place
/// brought level at every pass otherwise fills the page with the same row (a station from before the station says so
/// itself, replica/copies.ts `#record`).
fn copies_history_runs(records : Array[Json]) -> Array[Json] {
  let last_ok : Map[String, Bool] = Map([])
  let out : Array[Json] = []
  for r in records {
    let rv = Some(r)
    let ok_sync = text(rv, "kind") != "restore" && text(rv, "status") == "ok"
    let key = text(rv, "kind") + "/" + text(rv, "target")
    if ok_sync && last_ok.get(key) == Some(true) {
      continue
    }
    last_ok[key] = ok_sync
    out.push(r)
  }
  out
}

///|
/// Per-station backup page (`Route::StationBackup(station)`): flat layout with current status / restore offers,
/// backup history (`copies.history`), per-station peer target selection and `acceptOthers`, and per-station R2/S3 targets.
pub fn station_backup_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  station : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let s = fn() { @settings.station_of(core, here(), station) }
  let online = fn() { flag(s(), "online") }
  let copies = fn() { if online() { field(field(s(), "overview"), "copies") } else { None } }
  let backup = fn() { field(copies(), "backup") }
  let has_backup = fn() { backup() is Some(Object(_)) }
  let manager = fn() {
    let r = role_of(core, here())
    r == "owner" || r == "admin"
  }
  let can_edit = fn() { online() && manager() && has_backup() }
  let title = fn() {
    match text(s(), "name") {
      "" => @sf.t("web-pages.backup.title")
      name => @sf.t("web-pages.backup.title") + " · " + name
    }
  }
  let picked_manual = @signals.signal(false)
  let history_loading : @signals.Signal[Bool] = @signals.signal(false)
  let history_records : @signals.Signal[Array[Json]] = @signals.signal([])
  let history_error : @signals.Signal[String] = @signals.signal("")
  let history_loaded : @signals.Signal[Bool] = @signals.signal(false)
  let load_seq = Ref(0)
  let load_history = fn() {
    if !@signals.untracked(online) {
      return
    }
    load_seq.val = load_seq.val + 1
    let seq = load_seq.val
    history_loading.set(true)
    history_error.set("")
    (core.call)(
      "copies.history",
      obj([("station", str(station)), ("limit", Json::number(30.0))]),
      fn(r) {
        if load_seq.val != seq {
          return
        }
        history_loading.set(false)
        history_loaded.set(true)
        match r {
          Ok(val) => {
            history_records.set(items(Some(val), "records"))
            history_error.set("")
          }
          Err(e) => {
            let code = text(Some(e), "code")
            let msg = @settings.error_text(e)
            if code == "not_found" || code == "notFound" || msg.contains("404") || msg.contains("Not Found") {
              history_error.set(@sf.t("web-pages.backup.station.historyUnsupported"))
            } else {
              history_error.set(@sf.t("web-pages.backup.station.historyError", args=[("error", msg)]))
            }
          }
        }
      },
    )
  }
  if @signals.untracked(online) {
    load_history()
  }
  let saving = fn() { is_doing(core, ["copies.setSettings"], [("station", station)]) }
  let selected_stations = fn() -> Array[String] { copies_selected_ids(backup()) }
  let ui_mode = fn() -> String { copies_mode_of(backup(), picked_manual.get()) }
  let peers = fn() { items(backup(), "peers") }
  let s3_items = fn() { items(backup(), "s3") }
  let blocks = fn() {
    let out = ["status"]
    if online() {
      out.push("history")
    }
    if !online() {
      out.push("offline")
    } else if !manager() {
      out.push("admin")
    } else if has_backup() {
      out.push("targets")
      out.push("s3")
    }
    out
  }
  @sf.page_node(v, title, on_back~, frame~, said?, width?, blocks, fn(b, key) {
    match key {
      "status" =>
        st_section_node(b, fn() { @sf.t("web-pages.backup.station.status") }, fn(sec) {
          @sf.group_node(sec, fn(g) {
            g.pick(fn() { online() && copies() is Some(Object(_)) }, fn(r, has_view) {
              if has_view {
                copies_offers_or_line_node(r, core, station, copies, on_restored=load_history)
              } else {
                said_row_node(r, fn() {
                  if !online() {
                    @sf.t("web-pages.automaticDecisions.offline")
                  } else if !(field(s(), "overview") is Some(Object(_))) {
                    @sf.t("common.connecting")
                  } else {
                    @sf.t("web-pages.backup.stations.upgrade")
                  }
                })
              }
            })
            // (each station that keeps its backups, how far what it holds goes: under the line, not in place of offers)
            g.each(
              fn() { if items(copies(), "offers").is_empty() { items(copies(), "keepers") } else { [] } },
              fn(x) { text(Some(x), "station") },
              fn(row, x) {
                let kv = fn() { Some(x.get()) }
                // (a row has one note: in amber while behind or not yet, made again as that changes)
                row.pick(fn() { text(kv(), "level") != "ok" }, fn(r, behind) {
                  @sf.row_box_node(r, fn() { copies_keeper_name(kv()) }, fn(s) {
                    s.note(fn() { text(kv(), "line") }, tone=if behind { NoteWarn } else { NoteMuted })
                  })
                })
              },
            )
          })
        })
      "history" =>
        st_section_node(
          b,
          fn() { @sf.t("web-pages.backup.station.history") },
          ends=(fn() { true }, fn(e) {
            @sf.action_node(
              e,
              fn() { @sf.t("web-pages.backup.station.historyRefresh") },
              load_history,
              disabled=fn() { history_loading.get() },
            )
          }),
          fn(sec) {
            sec.reacts(online, fn(is_on) {
              if is_on && !history_loaded.untracked() && !history_loading.untracked() {
                load_history()
              }
            })
            @sf.group_node(sec, fn(g) {
              g.show(fn() { history_loading.get() && history_records.get().is_empty() }, fn(r) {
                said_row_node(r, fn() { @sf.t("web-pages.backup.station.historyLoading") })
              })
              g.show(fn() { !history_loading.get() && history_error.get() != "" && history_records.get().is_empty() }, fn(r) {
                said_row_node(r, fn() { history_error.get() })
              })
              g.show(fn() { !history_loading.get() && history_error.get() == "" && history_records.get().is_empty() }, fn(r) {
                said_row_node(r, fn() { @sf.t("web-pages.backup.station.historyEmpty") })
              })
              g.each(
                fn() { copies_history_runs(history_records.get()) },
                fn(x) {
                  let id = text(Some(x), "id")
                  if id != "" { id } else { text(Some(x), "target") + "/" + number(Some(x), "at").to_string() }
                },
                fn(row, x) {
                  let rv = fn() { Some(x.get()) }
                  let title_of = fn() {
                    let tn = text(rv(), "targetName")
                    if tn != "" {
                      tn
                    } else {
                      let tg = text(rv(), "target")
                      if tg.length() > 8 { tg[:8].to_owned() } else { tg }
                    }
                  }
                  let is_err = fn() { text(rv(), "status") != "ok" }
                  let detail = fn() { copies_history_detail(rv()) }
                  @sf.row_box_node(row, title_of, fn(s) {
                    s.value(fn() { copies_format_time(number(rv(), "at")) })
                    s.note(fn() { if is_err() { "" } else { detail() } })
                    s.note(fn() { if is_err() { detail() } else { "" } }, tone=NoteBad)
                  })
                },
              )
            })
          },
        )
      "offline" => @sf.page_note_node(b, fn() { @sf.t("web-pages.backup.station.offline") })
      "admin" => @sf.page_note_node(b, fn() { @sf.t("web-pages.backup.station.adminOnly") })
      "targets" =>
        st_section_node(b, fn() { @sf.t("web-pages.backup.station.targets") }, fn(sec) {
          @sf.group_node(sec, fn(g) {
            @sf.setting_node(
              g,
              fn() { @sf.t("web-pages.stations.copies.modeLabel") },
              note=fn() { @sf.t("web-pages.stations.copies.modeNote") },
              in_card=true,
              fn(c) {
                @sf.select_node(
                  c,
                  ui_mode,
                  fn() {
                    [
                      ("auto", @sf.t("web-pages.stations.copies.modeAuto")),
                      ("manual", @sf.t("web-pages.stations.copies.modeManual")),
                      ("off", @sf.t("web-pages.stations.copies.modeOff")),
                    ]
                  },
                  fn(chosen) {
                    match chosen {
                      "auto" => {
                        picked_manual.set(false)
                        @settings.act(
                          core,
                          @sf.t("web-pages.stations.copies.saveWhat"),
                          "copies.setSettings",
                          obj([("station", str(station)), ("mode", str("auto"))]),
                          done=@sf.t("web-pages.stations.copies.saved"),
                          then=fn(_) { load_history() },
                        )
                      }
                      "off" => {
                        picked_manual.set(false)
                        @settings.act(
                          core,
                          @sf.t("web-pages.stations.copies.saveWhat"),
                          "copies.setSettings",
                          obj([("station", str(station)), ("mode", str("manual")), ("stations", Json::array([]))]),
                          done=@sf.t("web-pages.stations.copies.saved"),
                          then=fn(_) { load_history() },
                        )
                      }
                      _ => {
                        picked_manual.set(true)
                        let cur = @signals.untracked(selected_stations)
                        let next = if cur.length() > 0 {
                          cur
                        } else {
                          let first_ok = @signals.untracked(peers)
                            .iter()
                            .find_first(fn(p) { flag(Some(p), "acceptOthers") })
                          match first_ok {
                            Some(p) => [text(Some(p), "station")]
                            None => []
                          }
                        }
                        @settings.act(
                          core,
                          @sf.t("web-pages.stations.copies.saveWhat"),
                          "copies.setSettings",
                          obj([
                            ("station", str(station)),
                            ("mode", str("manual")),
                            ("stations", Json::array(next.map(str))),
                          ]),
                          done=@sf.t("web-pages.stations.copies.saved"),
                          then=fn(_) { load_history() },
                        )
                      }
                    }
                  },
                  label=fn() { @sf.t("web-pages.stations.copies.modeLabel") },
                  disabled=saving,
                  whole=true,
                )
              },
            )
            g.show(fn() { ui_mode() == "manual" }, fn(pm) {
              pm.show(fn() { peers().length() == 0 }, fn(empty_row) {
                said_row_node(empty_row, fn() { @sf.t("web-pages.stations.copies.noPeers") })
              })
              pm.each(peers, fn(p) { text(Some(p), "station") }, fn(row, p) {
                let pv = fn() { Some(p.get()) }
                let pid = text(@signals.untracked(pv), "station")
                @sf.switch_row_node(
                  row,
                  fn() { text(pv(), "name") },
                  fn() { selected_stations().contains(pid) },
                  fn(checked) {
                    let cur = @signals.untracked(selected_stations)
                    let next = cur.filter(fn(id) { id != pid })
                    if checked {
                      next.push(pid)
                    }
                    picked_manual.set(true)
                    @settings.act(
                      core,
                      @sf.t("web-pages.stations.copies.saveWhat"),
                      "copies.setSettings",
                      obj([
                        ("station", str(station)),
                        ("mode", str("manual")),
                        ("stations", Json::array(next.map(str))),
                      ]),
                      done=@sf.t("web-pages.stations.copies.saved"),
                      then=fn(_) { load_history() },
                    )
                  },
                  note=fn() {
                    if !flag(pv(), "acceptOthers") {
                      @sf.t("web-pages.stations.copies.peerDeclined")
                    } else if !flag(pv(), "online") {
                      @sf.t("web-pages.stations.copies.peerOffline")
                    } else {
                      ""
                    }
                  },
                  disabled=fn() { !flag(pv(), "acceptOthers") },
                  busy=saving,
                )
              })
            })
            @sf.switch_row_node(
              g,
              fn() { @sf.t("web-pages.stations.copies.acceptOthers") },
              fn() { flag(backup(), "acceptOthers") },
              fn(now) {
                @settings.act(
                  core,
                  @sf.t("web-pages.stations.copies.saveWhat"),
                  "copies.setSettings",
                  obj([("station", str(station)), ("acceptOthers", Json::boolean(now))]),
                  done=@sf.t("web-pages.stations.copies.saved"),
                  then=fn(_) { load_history() },
                )
              },
              note=fn() { @sf.t("web-pages.stations.copies.acceptOthersNote") },
              busy=saving,
            )
          })
        })
      _ =>
        st_section_node(
          b,
          fn() { @sf.t("web-pages.stations.copies.s3Heading") },
          ends=(can_edit, fn(e) {
            @sf.action_node(e, fn() { @sf.t("web-pages.stations.copies.s3Add") }, fn() {
              copies_s3_form_dialog(core, station, @signals.untracked(backup), None, on_saved=Some(load_history))
            }, disabled=saving)
          }),
          fn(s3_sec) {
            @sf.group_node(s3_sec, fn(g) {
              g.show(fn() { s3_items().length() == 0 }, fn(r) {
                said_row_node(r, fn() { @sf.t("web-pages.stations.copies.s3Empty") })
              })
              g.each(s3_items, fn(x) { text(Some(x), "id") }, fn(row, x) {
                let sv = fn() { Some(x.get()) }
                let sid = text(@signals.untracked(sv), "id")
                @sf.row_box_node(row, fn() { text(sv(), "name") }, fn(s) {
                  s.note(fn() { copies_s3_note(sv()) })
                  s.tail(fn(c) {
                    c.box(fn(btns) {
                      @sf.style_node(btns, fn() { copies_s3_actions })
                      @sf.button_node(btns, fn() { @sf.t("web-pages.stations.copies.s3Edit") }, fn() {
                        copies_s3_form_dialog(
                          core,
                          station,
                          @signals.untracked(backup),
                          Some(@signals.untracked(fn() { x.get() })),
                          on_saved=Some(load_history),
                        )
                      }, tone=Ghost, disabled=saving)
                      |> ignore
                      @sf.button_node(btns, fn() { @sf.t("web-pages.stations.copies.s3Delete") }, fn() {
                        let sname = @signals.untracked(fn() { text(sv(), "name") })
                        @sf.confirm(
                          @sf.t("web-pages.stations.copies.s3DeleteTitle", args=[("name", sname)]),
                          @sf.t("web-pages.stations.copies.s3DeleteBody", args=[("name", sname)]),
                          @sf.t("web-pages.stations.copies.s3Delete"),
                          fn() {
                            let kept : Array[Json] = []
                            for item in items(@signals.untracked(backup), "s3") {
                              if text(Some(item), "id") != sid {
                                kept.push(copies_s3_wire_item(Some(item)))
                              }
                            }
                            @settings.act(
                              core,
                              @sf.t("web-pages.stations.copies.saveWhat"),
                              "copies.setSettings",
                              obj([("station", str(station)), ("s3", Json::array(kept))]),
                              done=@sf.t("web-pages.stations.copies.saved"),
                              then=fn(_) { load_history() },
                            )
                          },
                          danger=true,
                        )
                      }, tone=Ghost, disabled=saving)
                      |> ignore
                    })
                    |> ignore
                  })
                })
              })
            })
          },
        )
    }
  })
}

///|
/// Existing S3 target encoded back for `copies.setSettings` (omitting secrets so the station keeps them).
fn copies_s3_wire_item(item : Json?) -> Json {
  obj([
    ("id", str(text(item, "id"))),
    ("name", str(text(item, "name"))),
    ("endpoint", str(text(item, "endpoint"))),
    ("region", str(text(item, "region"))),
    ("bucket", str(text(item, "bucket"))),
    ("prefix", str(text(item, "prefix"))),
    ("forcePathStyle", Json::boolean(flag(item, "forcePathStyle"))),
    ("includeTranscripts", Json::boolean(flag(item, "includeTranscripts"))),
  ])
}

///|
/// Unified-draft S3 target encoded for `copies.setSettings`, keeping any entered secrets for batch apply.
fn copies_s3_draft_wire(item : Json) -> Json {
  let v = Some(item)
  let out : Array[(String, Json)] = [
    ("name", str(text(v, "name"))),
    ("endpoint", str(text(v, "endpoint"))),
    ("region", str(if text(v, "region") != "" { text(v, "region") } else { "auto" })),
    ("bucket", str(text(v, "bucket"))),
    ("prefix", str(text(v, "prefix"))),
    ("forcePathStyle", Json::boolean(flag(v, "forcePathStyle"))),
    ("includeTranscripts", Json::boolean(flag(v, "includeTranscripts"))),
  ]
  let id = text(v, "id")
  if id != "" && !id.has_prefix("s3-draft-") {
    out.push(("id", str(id)))
  }
  let ak = text(v, "accessKeyId")
  if ak != "" {
    out.push(("accessKeyId", str(ak)))
  }
  let sk = text(v, "secretAccessKey")
  if sk != "" {
    out.push(("secretAccessKey", str(sk)))
  }
  let ek = text(v, "encryptionKey")
  if ek != "" {
    out.push(("encryptionKey", str(ek)))
  }
  obj(out)
}

///|
/// Dialog/sheet to add or edit an R2/S3 backup target, with connection test and one-time generated key display.
/// When `on_save` is provided (workspace-wide draft mode), saving passes the built target entry to `on_save`
/// instead of immediately calling `copies.setSettings` on a single station.
pub fn copies_s3_form_dialog(
  core : Core,
  address : String,
  backup : Json?,
  editing : Json?,
  on_save? : ((Json, () -> Unit) -> Unit)? = None,
  on_saved? : (() -> Unit)? = None,
) -> Unit {
  let is_edit = editing is Some(Object(_))
  let edit_id = text(editing, "id")
  let f_name = @ui.Field::new(text=if is_edit { text(editing, "name") } else { "" })
  let f_endpoint = @ui.Field::new(text=if is_edit { text(editing, "endpoint") } else { "" })
  let f_bucket = @ui.Field::new(text=if is_edit { text(editing, "bucket") } else { "" })
  let f_region = @ui.Field::new(text=if is_edit && text(editing, "region") != "" { text(editing, "region") } else { "auto" })
  let f_prefix = @ui.Field::new(text=if is_edit { text(editing, "prefix") } else { "stillfail-backup" })
  let f_access = @ui.Field::new(text=if is_edit { text(editing, "accessKeyId") } else { "" })
  let f_secret = @ui.Field::new(text=if is_edit { text(editing, "secretAccessKey") } else { "" })
  let f_enc = @ui.Field::new(text=if is_edit { text(editing, "encryptionKey") } else { "" })
  let testing : @signals.Signal[Bool] = @signals.signal(false)
  let test_res : @signals.Signal[(Bool, String)?] = @signals.signal(None)
  let saving = fn() { address != "" && is_doing(core, ["copies.setSettings"], [("station", address)]) }
  let can_submit = fn() {
    let ep = f_endpoint.text().trim().to_owned()
    let bk = f_bucket.text().trim().to_owned()
    let ak = f_access.text().trim().to_owned()
    let sk = f_secret.text().trim().to_owned()
    ep != "" && bk != "" && (is_edit || (ak != "" && sk != ""))
  }
  let title = if is_edit {
    @sf.t("web-pages.stations.copies.s3FormEditTitle", args=[("name", text(editing, "name"))])
  } else {
    @sf.t("web-pages.stations.copies.s3FormAddTitle")
  }
  open_dialog_nodes(
    title,
    fn(v, _) {
      v.box(fn(pair) {
        @sf.style_node(pair, fn() { copies_form_pair })
        pair.box(fn(col) {
          col.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.field_node(col, fn() { @sf.t("web-pages.stations.copies.s3FieldName") }, fn(f) {
            @sf.input_node(
              f,
              f_name,
              placeholder=@sf.t("web-pages.stations.copies.s3FieldNamePh"),
              label=@sf.t("web-pages.stations.copies.s3FieldName"),
            )
            |> ignore
          })
        })
        |> ignore
        pair.box(fn(col) {
          col.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.field_node(col, fn() { @sf.t("web-pages.stations.copies.s3FieldBucket") }, fn(f) {
            @sf.input_node(
              f,
              f_bucket,
              placeholder=@sf.t("web-pages.stations.copies.s3FieldBucketPh"),
              label=@sf.t("web-pages.stations.copies.s3FieldBucket"),
            )
            |> ignore
          })
        })
        |> ignore
      })
      |> ignore
      @sf.field_node(v, fn() { @sf.t("web-pages.stations.copies.s3FieldEndpoint") }, fn(f) {
        @sf.input_node(
          f,
          f_endpoint,
          placeholder=@sf.t("web-pages.stations.copies.s3FieldEndpointPh"),
          label=@sf.t("web-pages.stations.copies.s3FieldEndpoint"),
        )
        |> ignore
      })
      v.box(fn(pair) {
        @sf.style_node(pair, fn() { copies_form_pair })
        pair.box(fn(col) {
          col.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.field_node(col, fn() { @sf.t("web-pages.stations.copies.s3FieldRegion") }, fn(f) {
            @sf.input_node(f, f_region, placeholder="auto", label=@sf.t("web-pages.stations.copies.s3FieldRegion"))
            |> ignore
          })
        })
        |> ignore
        pair.box(fn(col) {
          col.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.field_node(col, fn() { @sf.t("web-pages.stations.copies.s3FieldPrefix") }, fn(f) {
            @sf.input_node(f, f_prefix, placeholder="stillfail-backup", label=@sf.t("web-pages.stations.copies.s3FieldPrefix"))
            |> ignore
          })
        })
        |> ignore
      })
      |> ignore
      @sf.field_node(
        v,
        fn() { @sf.t("web-pages.stations.copies.s3FieldAccessKey") },
        hint=fn() { if is_edit { @sf.t("web-pages.stations.copies.s3FieldSecretKeep") } else { "" } },
        fn(f) {
          @sf.input_node(f, f_access, label=@sf.t("web-pages.stations.copies.s3FieldAccessKey")) |> ignore
        },
      )
      @sf.field_node(
        v,
        fn() { @sf.t("web-pages.stations.copies.s3FieldSecretKey") },
        hint=fn() { if is_edit { @sf.t("web-pages.stations.copies.s3FieldSecretKeep") } else { "" } },
        fn(f) {
          @sf.input_node(f, f_secret, secret=true, label=@sf.t("web-pages.stations.copies.s3FieldSecretKey")) |> ignore
        },
      )
      @sf.field_node(
        v,
        fn() { @sf.t("web-pages.stations.copies.s3FieldEncKey") },
        hint=fn() { @sf.t("web-pages.stations.copies.s3FieldEncKeyHint") },
        fn(f) {
          @sf.input_node(f, f_enc, secret=true, label=@sf.t("web-pages.stations.copies.s3FieldEncKey")) |> ignore
        },
      )
      v.show(fn() { test_res.get() is Some(_) }, fn(r) {
        r.pick(fn() {
          match test_res.get() {
            Some((ok, _)) => ok
            None => true
          }
        }, fn(b, ok) {
          @sf.words_node(
            b,
            fn() {
              match test_res.get() {
                Some((_, msg)) => msg
                None => ""
              }
            },
            fn() { if ok { copies_test_ok } else { st_problem_bad } },
          )
          |> ignore
        })
      })
    },
    fn(v, shut) {
      @sf.button_node(
        v,
        fn() { @sf.t("web-pages.stations.copies.s3Test") },
        fn() {
          if address == "" {
            return
          }
          testing.set(true)
          test_res.set(None)
          let p : Array[(String, Json)] = [
            ("station", str(address)),
            ("endpoint", str(f_endpoint.text().trim().to_owned())),
            ("region", str(f_region.text().trim().to_owned())),
            ("bucket", str(f_bucket.text().trim().to_owned())),
            ("prefix", str(f_prefix.text().trim().to_owned())),
            ("forcePathStyle", Json::boolean(true)),
          ]
          if is_edit && edit_id != "" && !edit_id.has_prefix("s3-draft-") {
            p.push(("id", str(edit_id)))
          }
          let ak = f_access.text().trim().to_owned()
          if ak != "" {
            p.push(("accessKeyId", str(ak)))
          }
          let sk = f_secret.text().trim().to_owned()
          if sk != "" {
            p.push(("secretAccessKey", str(sk)))
          }
          let ek = f_enc.text().trim().to_owned()
          if ek != "" {
            p.push(("encryptionKey", str(ek)))
          }
          (core.call)("copies.testS3", obj(p), fn(r) {
            testing.set(false)
            match r {
              Ok(val) =>
                if flag(Some(val), "ok") {
                  test_res.set(Some((true, @sf.t("web-pages.stations.copies.s3TestOk"))))
                } else {
                  test_res.set(
                    Some((false, @sf.t("web-pages.stations.copies.s3TestFail", args=[("error", text(Some(val), "error"))]))),
                  )
                }
              Err(e) =>
                test_res.set(
                  Some((false, @sf.t("web-pages.stations.copies.s3TestFail", args=[("error", @settings.error_text(e))]))),
                )
            }
          })
        },
        tone=Ghost,
        busy=fn() { testing.get() },
        disabled=fn() { address == "" || !can_submit() || testing.get() || saving() },
      )
      |> ignore
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      @sf.button_node(
        v,
        fn() { @sf.t("common.save") },
        fn() {
          let name_val = f_name.text().trim().to_owned()
          let bucket_val = f_bucket.text().trim().to_owned()
          let region_val = f_region.text().trim().to_owned()
          let entry : Array[(String, Json)] = [
            ("name", str(if name_val != "" { name_val } else { bucket_val })),
            ("endpoint", str(f_endpoint.text().trim().to_owned())),
            ("region", str(if region_val != "" { region_val } else { "auto" })),
            ("bucket", str(bucket_val)),
            ("prefix", str(f_prefix.text().trim().to_owned())),
            ("forcePathStyle", Json::boolean(true)),
            ("includeTranscripts", Json::boolean(true)),
          ]
          if is_edit && edit_id != "" {
            entry.push(("id", str(edit_id)))
          }
          let ak = f_access.text().trim().to_owned()
          if ak != "" {
            entry.push(("accessKeyId", str(ak)))
          }
          let sk = f_secret.text().trim().to_owned()
          if sk != "" {
            entry.push(("secretAccessKey", str(sk)))
          }
          let ek = f_enc.text().trim().to_owned()
          if ek != "" {
            entry.push(("encryptionKey", str(ek)))
          }
          match on_save {
            Some(cb) => {
              let fp = text(editing, "keyFingerprint")
              if fp != "" {
                entry.push(("keyFingerprint", str(fp)))
              }
              let sl = text(editing, "statusLine")
              if sl != "" {
                entry.push(("statusLine", str(sl)))
              }
              cb(obj(entry), shut)
            }
            None => {
              let next_s3 : Array[Json] = []
              let mut replaced = false
              for item in items(backup, "s3") {
                if is_edit && text(Some(item), "id") == edit_id {
                  next_s3.push(obj(entry))
                  replaced = true
                } else {
                  next_s3.push(copies_s3_wire_item(Some(item)))
                }
              }
              if !replaced {
                next_s3.push(obj(entry))
              }
              @settings.act(
                core,
                @sf.t("web-pages.stations.copies.saveWhat"),
                "copies.setSettings",
                obj([("station", str(address)), ("s3", Json::array(next_s3))]),
                done=@sf.t("web-pages.stations.copies.saved"),
                then=fn(res) {
                  shut()
                  match on_saved {
                    Some(cb) => cb()
                    None => ()
                  }
                  match field(Some(res), "generatedKeys") {
                    Some(Object(m)) if m.length() > 0 => {
                      let pairs : Array[(String, String)] = []
                      m.each(fn(k, val) {
                        match val {
                          String(s) if s != "" => pairs.push((k, s))
                          _ => ()
                        }
                      })
                      if pairs.length() > 0 {
                        copies_generated_key_dialog(core, pairs)
                      }
                    }
                    _ => ()
                  }
                },
              )
            }
          }
        },
        tone=Primary,
        busy=saving,
        disabled=fn() { !can_submit() || saving() },
      )
      |> ignore
    },
  )
}

///|
/// One-time recovery key dialog shown immediately after the station generates a new S3/R2 encryption key.
fn copies_generated_key_dialog(core : Core, keys : Array[(String, String)]) -> Unit {
  let first_key = if keys.length() > 0 { keys[0].1 } else { "" }
  let all_text = keys.map(fn(p) { p.1 }).join("\n")
  open_dialog_nodes(
    @sf.t("web-pages.stations.copies.keyTitle"),
    fn(v, _) {
      @sf.words_node(v, fn() { @sf.t("web-pages.stations.copies.keyBody") }, fn() { st_memory }) |> ignore
      v.box(fn(card) {
        @sf.style_node(card, fn() { copies_key_card })
        @sf.words_node(card, fn() { all_text }, fn() { copies_key_words }) |> ignore
      })
      |> ignore
    },
    fn(v, shut) {
      @sf.button_node(v, fn() { @sf.t("web-pages.stations.copies.keyCopy") }, fn() {
        @ui.clipboard_set(first_key)
        (core.say)(@sf.t("web-pages.stations.copies.keyCopied"))
      }, tone=Ghost)
      |> ignore
      @sf.button_node(v, fn() { @sf.t("web-pages.stations.copies.keyDone") }, shut, tone=Primary) |> ignore
    },
  )
}

///|
/// 恢复到这台 asked first: what it restores and that the station must stay without chats until it restarts; then
/// `copies.restore` of `copy` (CopyOffer), passing `fromS3` for S3/R2 offers or `fromStation` for peer station offers.
pub fn copies_restore_confirm(core : Core, address : String, copy : Json?, on_restored? : () -> Unit) -> Unit {
  @sf.confirm(
    @sf.t("web-pages.stations.copies.restoreTitle", args=[("name", text(copy, "name"))]),
    @sf.t("web-pages.stations.copies.restoreBody", args=[("name", text(copy, "name"))]),
    @sf.t("web-pages.stations.copies.restore"),
    fn() {
      let from_s3 = text(copy, "fromS3")
      let params : Array[(String, Json)] = [
        ("station", str(address)),
        ("origin", str(text(copy, "station"))),
        ("gen", str(text(copy, "gen"))),
      ]
      if from_s3 != "" {
        params.push(("fromS3", str(from_s3)))
      } else {
        params.push(("fromStation", str(text(copy, "fromStation"))))
      }
      @settings.act(
        core,
        @sf.t("web-pages.stations.copies.restoreWhat"),
        "copies.restore",
        obj(params),
        then=fn(_) {
          match on_restored {
            Some(cb) => cb()
            None => ()
          }
        },
      )
    },
  )
}
