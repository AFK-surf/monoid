// External conversation import settings (`Route::Import`): detects supported tools on the chosen online station
// (T3 Code first), shows session counts, provides one-click batch import (`import.run`), and lets users inspect or
// import individual threads (`import.list`) and jump straight to already-imported still.fail chats.

///|
// kept across runs: a value (no field of it changes)
let import_source_stack : @ui.Style = @ui.css("w=Full gap=S3")

///|
// kept across runs: a value (no field of it changes)
let import_source_card : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let import_source_actions : @ui.Style = @ui.css("row w=Full gap=S2 pt=S2 align=ACenter")

///|
/// Format an RPC error returned by `import.*` calls, surfacing an upgrade hint for older stations (HTTP 404).
fn import_error_text(e : Json) -> String {
  let code = text(Some(e), "code")
  let msg = @settings.error_text(e)
  if code == "not_found" || code == "notFound" || msg.contains("404") || msg.contains("Not Found") {
    @sf.t("web-pages.import.unsupported")
  } else {
    @sf.t("web-pages.import.failed", args=[("error", msg)])
  }
}

///|
/// Summary note line for one probed external source card.
fn import_source_note(sv : Json?) -> String {
  if !flag(sv, "available") {
    if text(sv, "error") != "" {
      return ""
    }
    return @sf.t("web-pages.import.notDetected")
  }
  let active = number(sv, "activeCount").to_int()
  let archived = number(sv, "archivedCount").to_int()
  let imported = number(sv, "importedCount").to_int()
  let parts : Array[String] = []
  if archived > 0 {
    parts.push(
      @sf.t(
        "web-pages.import.availableWithArchived",
        args=[("active", active.to_string()), ("archived", archived.to_string())],
      ),
    )
  } else {
    parts.push(@sf.t("web-pages.import.available", args=[("active", active.to_string())]))
  }
  if imported > 0 {
    parts.push(@sf.t("web-pages.import.importedCount", args=[("n", imported.to_string())]))
  }
  join(parts, " · ")
}

///|
/// Unimported session count for a source's primary one-click button, or `-1` when exact pending count is unknown
/// before expanding the list (archived sessions exist alongside partial imports while `include_archived` is off).
fn import_pending_count(sv : Json?, include_archived : Bool, list_loaded : Bool, cands : Array[Json]) -> Int {
  if list_loaded {
    let mut n = 0
    for c in cands {
      if text(Some(c), "session") == "" {
        n += 1
      }
    }
    return n
  }
  let active = number(sv, "activeCount").to_int()
  let archived = number(sv, "archivedCount").to_int()
  let imported = number(sv, "importedCount").to_int()
  let total = if include_archived { active + archived } else { active }
  if total <= 0 {
    return 0
  }
  if include_archived || archived == 0 {
    let left = total - imported
    if left > 0 { left } else { 0 }
  } else if imported == 0 {
    active
  } else if imported >= active + archived {
    0
  } else {
    -1
  }
}

///|
/// Metadata subtitle for one candidate conversation row in the expanded list.
fn import_candidate_note(cv : Json?) -> String {
  let parts : Array[String] = []
  let proj = text(cv, "project")
  if proj != "" {
    parts.push(proj)
  }
  let model = text(cv, "model")
  let provider = text(cv, "provider")
  if model != "" {
    parts.push(model)
  } else if provider != "" {
    parts.push(provider)
  }
  let msgs = number(cv, "messageCount").to_int()
  parts.push(@sf.t("web-pages.import.messages", args=[("n", msgs.to_string())]))
  if flag(cv, "nativeResumable") {
    parts.push(@sf.t("web-pages.import.resumable"))
  }
  if flag(cv, "archived") {
    parts.push(@sf.t("web-pages.import.archivedTag"))
  }
  if text(cv, "session") != "" {
    parts.push(@sf.t("web-pages.import.importedTag"))
  }
  let updated = copies_format_time(number(cv, "updatedAt"))
  if updated != "" {
    parts.push(updated)
  }
  join(parts, " · ")
}

///|
/// Toast text and success flag for an `import.run` response.
fn import_done_message(val : Json) -> (String, Bool) {
  let imported = number(Some(val), "imported").to_int()
  let skipped = number(Some(val), "skipped").to_int()
  let failed = number(Some(val), "failed").to_int()
  if failed > 0 {
    let mut err = ""
    for item in items(Some(val), "items") {
      if text(Some(item), "status") == "failed" {
        err = text(Some(item), "error")
        if err != "" {
          break
        }
      }
    }
    (
      @sf.t(
        "web-pages.import.doneFailed",
        args=[("imported", imported.to_string()), ("failed", failed.to_string()), ("error", err)],
      ),
      false,
    )
  } else if imported == 0 {
    (@sf.t("web-pages.import.nothingNew"), true)
  } else if skipped > 0 {
    (
      @sf.t(
        "web-pages.import.doneSkipped",
        args=[("imported", imported.to_string()), ("skipped", skipped.to_string())],
      ),
      true,
    )
  } else {
    (@sf.t("web-pages.import.done", args=[("imported", imported.to_string())]), true)
  }
}

///|
/// Top-level 导入 page (`Route::Import`): pick a target online station (when more than one is online), inspect
/// detected external tools such as T3 Code, run one-click batch import, or open/import individual conversations.
pub fn import_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let read = fn() { @settings.stations_of(core, here()).value }
  let online_stations = fn() -> Array[(String, String)] {
    let out : Array[(String, String)] = []
    match read() {
      Some(Array(list)) =>
        for s in list {
          if flag(Some(s), "online") {
            let addr = text(Some(s), "station")
            let name = text(Some(s), "name")
            if addr != "" {
              out.push((addr, if name != "" { name } else { @settings.station_name(addr) }))
            }
          }
        }
      _ => ()
    }
    out
  }
  let picked_station = @signals.signal("")
  let active_station = fn() -> String {
    let list = online_stations()
    let picked = picked_station.get()
    if picked != "" && list.iter().any(fn(st) { st.0 == picked }) {
      picked
    } else {
      match list.get(0) {
        Some((addr, _)) => addr
        None => ""
      }
    }
  }
  let sources : @signals.Signal[Array[Json]] = @signals.signal([])
  let sources_loading = @signals.signal(false)
  let sources_error = @signals.signal("")
  let include_archived = @signals.signal(false)
  let expanded_source = @signals.signal("")
  let candidates : @signals.Signal[Array[Json]] = @signals.signal([])
  let candidates_loading = @signals.signal(false)
  let candidates_loaded = @signals.signal(false)
  let candidates_error = @signals.signal("")
  let running_source = @signals.signal("")
  let running_item = @signals.signal("")
  let loaded_station = Ref("")
  let sources_seq = Ref(0)
  let list_seq = Ref(0)

  let load_sources = fn(st : String) {
    if st == "" {
      return
    }
    sources_seq.val = sources_seq.val + 1
    let seq = sources_seq.val
    sources_loading.set(true)
    sources_error.set("")
    (core.call)("import.sources", obj([("station", str(st))]), fn(r) {
      if sources_seq.val != seq {
        return
      }
      sources_loading.set(false)
      match r {
        Ok(val) => {
          sources.set(items(Some(val), "sources"))
          sources_error.set("")
        }
        Err(e) => {
          sources.set([])
          sources_error.set(import_error_text(e))
        }
      }
    })
  }

  let load_candidates = fn(st : String, sid : String, inc : Bool) {
    if st == "" || sid == "" {
      return
    }
    list_seq.val = list_seq.val + 1
    let seq = list_seq.val
    candidates_loading.set(true)
    candidates_error.set("")
    (core.call)(
      "import.list",
      obj([("station", str(st)), ("source", str(sid)), ("includeArchived", Json::boolean(inc))]),
      fn(r) {
        if list_seq.val != seq {
          return
        }
        candidates_loading.set(false)
        candidates_loaded.set(true)
        match r {
          Ok(val) => {
            candidates.set(items(Some(val), "sessions"))
            candidates_error.set("")
          }
          Err(e) => {
            candidates.set([])
            candidates_error.set(import_error_text(e))
          }
        }
      },
    )
  }

  let run_import = fn(sid : String, ids : Array[String]?) {
    let st = @signals.untracked(active_station)
    if st == "" || sid == "" {
      return
    }
    let inc = include_archived.untracked()
    let params : Array[(String, Json)] = [("station", str(st)), ("source", str(sid))]
    match ids {
      Some(one) => {
        params.push(("ids", Json::array(one.map(str))))
        running_item.set(one.get(0).unwrap_or(""))
      }
      None => {
        params.push(("includeArchived", Json::boolean(inc)))
        running_source.set(sid)
      }
    }
    (core.call)("import.run", obj(params), fn(r) {
      match ids {
        Some(_) => running_item.set("")
        None => running_source.set("")
      }
      match r {
        Ok(val) => {
          let (msg, ok) = import_done_message(val)
          (core.say)(msg)
          @ui.haptic(if ok { Confirm } else { Reject })
          load_sources(st)
          if expanded_source.untracked() == sid {
            load_candidates(st, sid, include_archived.untracked())
          }
        }
        Err(e) => {
          @ui.haptic(Reject)
          (core.say)(import_error_text(e))
        }
      }
    })
  }

  let blocks = fn() {
    let out = ["about"]
    if read() is Some(_) && online_stations().is_empty() {
      out.push("empty")
      return out
    }
    if online_stations().length() > 1 {
      out.push("station")
    }
    out.push("sources")
    if expanded_source.get() != "" && active_station() != "" {
      out.push("sessions")
    }
    out
  }

  @sf.page_node(v, fn() { @sf.t("web-pages.import.title") }, on_back~, frame~, said?, width?, blocks, fn(b, key) {
    match key {
      "about" => @sf.page_note_node(b, fn() { @sf.t("web-pages.import.description") })
      "empty" => @sf.page_note_node(b, fn() { @sf.t("web-pages.import.noOnline") })
      "station" =>
        @sf.section_node(b, fn() { "" }, fn(sec) {
          @sf.group_node(sec, fn(g) {
            @sf.setting_node(g, fn() { @sf.t("web-pages.import.station") }, in_card=true, fn(c) {
              @sf.select_node(
                c,
                active_station,
                online_stations,
                fn(chosen) { picked_station.set(chosen) },
                label=fn() { @sf.t("web-pages.import.station") },
                disabled=fn() { running_source.get() != "" || running_item.get() != "" },
                whole=true,
              )
            })
          })
        })
      "sources" =>
        st_section_node(
          b,
          fn() { @sf.t("web-pages.import.sources") },
          ends=(fn() { active_station() != "" }, fn(e) {
            @sf.action_node(
              e,
              fn() { @sf.t("web-pages.import.refresh") },
              fn() {
                let st = @signals.untracked(active_station)
                load_sources(st)
                let exp = expanded_source.untracked()
                if exp != "" {
                  load_candidates(st, exp, include_archived.untracked())
                }
              },
              disabled=fn() { sources_loading.get() || running_source.get() != "" || running_item.get() != "" },
            )
          }),
          fn(sec) {
            sec.reacts(active_station, fn(st) {
              if st == "" {
                loaded_station.val = ""
                sources.set([])
                sources_error.set("")
                expanded_source.set("")
                candidates.set([])
                candidates_loaded.set(false)
                candidates_error.set("")
              } else if st != loaded_station.val {
                loaded_station.val = st
                expanded_source.set("")
                candidates.set([])
                candidates_loaded.set(false)
                candidates_error.set("")
                load_sources(st)
              }
            })
            sec.pick(fn() { read() is None }, fn(p, waiting) {
              if waiting {
                @sf.waiting_node(
                  p,
                  fn(s) {
                    @sf.group_node(s, fn(g) {
                      @sf.row_box_node(g, fn() { @sf.sample_words(3) }, fn(r) {
                        r.note(fn() { @sf.sample_words(8) })
                      })
                    })
                  },
                  note=fn() { { reading: true, text: @sf.t("common.readingStations"), failing: [] } },
                )
              } else {
                p.show(fn() { sources_loading.get() && sources.get().is_empty() }, fn(w) {
                  @sf.group_node(w, fn(g) {
                    said_row_node(g, fn() { @sf.t("web-pages.import.loading") })
                  })
                })
                p.show(fn() { !sources_loading.get() && sources_error.get() != "" && sources.get().is_empty() }, fn(w) {
                  @sf.group_node(w, fn(g) {
                    said_row_node(g, fn() { sources_error.get() })
                  })
                })
                p.box(fn(stack) {
                  @sf.style_node(stack, fn() { import_source_stack })
                  stack.each(fn() { sources.get() }, fn(s) { text(Some(s), "id") }, fn(card, s) {
                    let sv = fn() { Some(s.get()) }
                    let sid = text(@signals.untracked(sv), "id")
                    let is_expanded = fn() { expanded_source.get() == sid }
                    let list_ready = fn() { is_expanded() && candidates_loaded.get() }
                    let pending = fn() { import_pending_count(sv(), include_archived.get(), list_ready(), candidates.get()) }
                    let busy_here = fn() { running_source.get() == sid }
                    let any_busy = fn() { running_source.get() != "" || running_item.get() != "" }
                    card.box(fn(box) {
                      @sf.style_node(box, fn() { import_source_card })
                      @sf.group_node(box, fn(g) {
                        @sf.row_box_node(g, fn() { text(sv(), "name") }, fn(r) {
                          r.note(fn() { import_source_note(sv()) })
                          r.note(fn() { text(sv(), "error") }, tone=NoteBad)
                        })
                        g.show(fn() { flag(sv(), "available") && number(sv(), "archivedCount").to_int() > 0 }, fn(sw) {
                          @sf.switch_row_node(
                            sw,
                            fn() { @sf.t("web-pages.import.includeArchived") },
                            fn() { include_archived.get() },
                            fn(checked) {
                              include_archived.set(checked)
                              if expanded_source.untracked() == sid {
                                load_candidates(@signals.untracked(active_station), sid, checked)
                              }
                            },
                            busy=any_busy,
                          )
                        })
                      })
                      box.show(fn() { flag(sv(), "available") }, fn(act) {
                        @sf.style_node(act, fn() { import_source_actions })
                        act.wraps(Is(Some(8.0))) |> ignore
                        @sf.button_node(
                          act,
                          fn() {
                            if busy_here() {
                              @sf.t("web-pages.import.importing")
                            } else {
                              let n = pending()
                              if n == 0 {
                                @sf.t("web-pages.import.allImported")
                              } else if n > 0 {
                                @sf.t("web-pages.import.oneClickCount", args=[("n", n.to_string())])
                              } else {
                                @sf.t("web-pages.import.oneClick")
                              }
                            }
                          },
                          fn() { run_import(sid, None) },
                          tone=Primary,
                          busy=busy_here,
                          disabled=fn() { any_busy() || pending() == 0 },
                        )
                        |> ignore
                        @sf.button_node(
                          act,
                          fn() {
                            if is_expanded() {
                              @sf.t("web-pages.import.hideList")
                            } else {
                              @sf.t("web-pages.import.showList")
                            }
                          },
                          fn() {
                            if expanded_source.untracked() == sid {
                              expanded_source.set("")
                            } else {
                              expanded_source.set(sid)
                              candidates_loaded.set(false)
                              load_candidates(@signals.untracked(active_station), sid, include_archived.untracked())
                            }
                          },
                          tone=Ghost,
                          disabled=any_busy,
                        )
                        |> ignore
                      })
                    })
                    |> ignore
                  })
                })
                |> ignore
              }
            })
          },
        )
      _ =>
        st_section_node(b, fn() { @sf.t("web-pages.import.sessions") }, fn(sec) {
          @sf.group_node(sec, fn(g) {
            g.show(fn() { candidates_loading.get() && candidates.get().is_empty() }, fn(r) {
              said_row_node(r, fn() { @sf.t("web-pages.import.loading") })
            })
            g.show(fn() { !candidates_loading.get() && candidates_error.get() != "" && candidates.get().is_empty() }, fn(r) {
              said_row_node(r, fn() { candidates_error.get() })
            })
            g.show(fn() { !candidates_loading.get() && candidates_error.get() == "" && candidates.get().is_empty() }, fn(r) {
              said_row_node(r, fn() { @sf.t("web-pages.import.empty") })
            })
            g.each(fn() { candidates.get() }, fn(c) { text(Some(c), "id") }, fn(row, c) {
              let cv = fn() { Some(c.get()) }
              let cid = text(@signals.untracked(cv), "id")
              let sid = expanded_source.untracked()
              @sf.setting_node(
                row,
                fn() { text(cv(), "title") },
                note=fn() { import_candidate_note(cv()) },
                in_card=true,
                fn(t) {
                  t.pick(fn() { text(cv(), "session") != "" }, fn(btn, done) {
                    if done {
                      @sf.button_node(
                        btn,
                        fn() { @sf.t("web-pages.import.openChat") },
                        fn() {
                          let cur = @signals.untracked(cv)
                          let sess = text(cur, "session")
                          if sess != "" {
                            (core.open_chat)(@signals.untracked(active_station), sess, text(cur, "title"))
                          }
                        },
                        tone=Ghost,
                      )
                      |> ignore
                    } else {
                      let item_busy = fn() { running_item.get() == cid }
                      let any_busy = fn() { running_source.get() != "" || running_item.get() != "" }
                      @sf.button_node(
                        btn,
                        fn() {
                          if item_busy() {
                            @sf.t("web-pages.import.importing")
                          } else {
                            @sf.t("web-pages.import.importOne")
                          }
                        },
                        fn() { run_import(sid, Some([cid])) },
                        tone=Ghost,
                        busy=item_busy,
                        disabled=any_busy,
                      )
                      |> ignore
                    }
                  })
                },
              )
            })
          })
        })
    }
  })
}
