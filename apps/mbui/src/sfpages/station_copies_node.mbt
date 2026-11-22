// A station's backups of its chats in its 设置 (StationCopies, the core's copies.ts; the station's replica/), made once
// as nodes: one summary row by default (and on an empty station, a backup of a lost station with 恢复到这台). When the
// station reports `backup` settings and the viewer manages it while online, 管理 expands target selection (other
// stations: auto / manual / off + acceptOthers) and external R2 / S3 object storage (add, edit, test, remove, and
// one-time display of auto-generated encryption recovery keys).

///|
// kept across runs: a value (no field of it changes)
let copies_s3_actions : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let copies_sub_gap : @ui.Style = @ui.css("mt=S3")

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
/// Its backups (`copies`, the overview's) in node `b`: 备份, a summary row (or restore offers on an empty station),
/// and expandable target / R2-S3 configuration for managers while online.
fn station_copies_node(
  b : @view.View,
  core : Core,
  address : String,
  copies : () -> Json?,
  manager : Bool,
  online : () -> Bool,
) -> Unit {
  let offers = fn() { items(copies(), "offers") }
  let backup = fn() { field(copies(), "backup") }
  let has_backup = fn() { backup() is Some(Object(_)) }
  let can_edit = fn() { has_backup() && manager && online() }
  let open = @signals.signal(@settings.station_copies_open.get(address).unwrap_or(false))
  let picked_manual = @signals.signal(false)
  let saving = fn() { is_doing(core, ["copies.setSettings"], [("station", address)]) }
  let selected_stations = fn() -> Array[String] {
    let out : Array[String] = []
    for x in items(backup(), "stations") {
      match x {
        String(s) if s != "" => out.push(s)
        _ => ()
      }
    }
    out
  }
  let ui_mode = fn() -> String {
    if text(backup(), "mode") == "auto" {
      "auto"
    } else if selected_stations().length() > 0 || picked_manual.get() {
      "manual"
    } else {
      "off"
    }
  }
  let peers = fn() { items(backup(), "peers") }
  let s3_items = fn() { items(backup(), "s3") }
  st_section_node(
    b,
    fn() { @sf.t("web-pages.stations.copies.section") },
    ends=(can_edit, fn(e) {
      @sf.action_node(e, fn() {
        if open.get() {
          @sf.t("web-pages.stations.copies.collapse")
        } else {
          @sf.t("web-pages.stations.copies.manage")
        }
      }, fn() {
        let now = !open.untracked()
        @settings.station_copies_open[address] = now
        open.set(now)
      })
    }),
    fn(sec) {
      @sf.group_node(sec, fn(g) {
        g.show(fn() { offers().length() == 0 }, fn(r) { said_row_node(r, fn() { text(copies(), "line") }) })
        // (a backup to restore here: its row, 恢复到这台 at its end in the card's corner, concentric with it, asked first;
        // S3 offers carry a longer source suffix so they use setting_node(in_card=true) to avoid narrow truncation;
        // while it is restored, and once it is, the row only says how it goes)
        g.each(offers, fn(x) { text(Some(x), "station") + "/" + text(Some(x), "gen") }, fn(row, x) {
          let can = fn() { flag(copies(), "canRestore") && !flag(Some(x.get()), "busy") }
          let from_s3 = fn() { text(Some(x.get()), "fromS3") != "" }
          row.pick(fn() { (can(), from_s3()) }, fn(r, k) {
            let (live, is_s3) = k
            if live && is_s3 {
              @sf.setting_node(r, fn() { text(Some(x.get()), "line") }, in_card=true, fn(e) {
                @sf.button_node(e, fn() { @sf.t("web-pages.stations.copies.restore") }, fn() {
                  copies_restore_confirm(core, address, Some(@signals.untracked(fn() { x.get() })))
                }, tone=Primary)
                |> ignore
              })
            } else if live {
              @sf.corner_row_node(r, fn() { text(Some(x.get()), "line") }, fn(e) {
                @sf.button_node(e, fn() { @sf.t("web-pages.stations.copies.restore") }, fn() {
                  copies_restore_confirm(core, address, Some(@signals.untracked(fn() { x.get() })))
                }, tone=Primary)
                |> ignore
              })
            } else {
              said_row_node(r, fn() { text(Some(x.get()), "line") })
            }
          })
        })
        // A. Back up to other stations (expanded for managers while online)
        g.show(fn() { can_edit() && open.get() }, fn(o) {
          @sf.setting_node(
            o,
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
                        obj([("station", str(address)), ("mode", str("auto"))]),
                        done=@sf.t("web-pages.stations.copies.saved"),
                      )
                    }
                    "off" => {
                      picked_manual.set(false)
                      @settings.act(
                        core,
                        @sf.t("web-pages.stations.copies.saveWhat"),
                        "copies.setSettings",
                        obj([("station", str(address)), ("mode", str("manual")), ("stations", Json::array([]))]),
                        done=@sf.t("web-pages.stations.copies.saved"),
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
                          ("station", str(address)),
                          ("mode", str("manual")),
                          ("stations", Json::array(next.map(str))),
                        ]),
                        done=@sf.t("web-pages.stations.copies.saved"),
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
          o.show(fn() { ui_mode() == "manual" }, fn(pm) {
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
                      ("station", str(address)),
                      ("mode", str("manual")),
                      ("stations", Json::array(next.map(str))),
                    ]),
                    done=@sf.t("web-pages.stations.copies.saved"),
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
            o,
            fn() { @sf.t("web-pages.stations.copies.acceptOthers") },
            fn() { flag(backup(), "acceptOthers") },
            fn(now) {
              @settings.act(
                core,
                @sf.t("web-pages.stations.copies.saveWhat"),
                "copies.setSettings",
                obj([("station", str(address)), ("acceptOthers", Json::boolean(now))]),
                done=@sf.t("web-pages.stations.copies.saved"),
              )
            },
            note=fn() { @sf.t("web-pages.stations.copies.acceptOthersNote") },
            busy=saving,
          )
        })
      })
      // B. External object storage (R2 / S3)
      sec.show(fn() { can_edit() && open.get() }, fn(s3_wrap) {
        s3_wrap.box(fn(box) {
          @sf.style_node(box, fn() { copies_sub_gap })
          st_section_node(
            box,
            fn() { @sf.t("web-pages.stations.copies.s3Heading") },
            ends=(fn() { true }, fn(e) {
              @sf.action_node(e, fn() { @sf.t("web-pages.stations.copies.s3Add") }, fn() {
                copies_s3_form_dialog(core, address, @signals.untracked(backup), None)
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
                  @sf.setting_node(
                    row,
                    fn() { text(sv(), "name") },
                    note=fn() {
                      let bucket = text(sv(), "bucket")
                      let status = text(sv(), "statusLine")
                      let fp = text(sv(), "keyFingerprint")
                      let parts : Array[String] = []
                      if bucket != "" {
                        parts.push(bucket)
                      }
                      if status != "" {
                        parts.push(status)
                      }
                      if fp != "" {
                        parts.push(@sf.t("web-pages.stations.copies.s3KeyFp", args=[("fp", fp)]))
                      }
                      parts.join("\n")
                    },
                    in_card=true,
                    fn(c) {
                      c.box(fn(btns) {
                        @sf.style_node(btns, fn() { copies_s3_actions })
                        @sf.button_node(btns, fn() { @sf.t("web-pages.stations.copies.s3Edit") }, fn() {
                          copies_s3_form_dialog(core, address, @signals.untracked(backup), Some(@signals.untracked(fn() { x.get() })))
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
                                obj([("station", str(address)), ("s3", Json::array(kept))]),
                                done=@sf.t("web-pages.stations.copies.saved"),
                              )
                            },
                            danger=true,
                          )
                        }, tone=Ghost, disabled=saving)
                        |> ignore
                      })
                      |> ignore
                    },
                  )
                })
              })
            },
          )
        })
        |> ignore
      })
    },
  )
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
/// Dialog/sheet to add or edit an R2/S3 backup target, with connection test and one-time generated key display.
pub fn copies_s3_form_dialog(core : Core, address : String, backup : Json?, editing : Json?) -> Unit {
  let is_edit = editing is Some(Object(_))
  let edit_id = text(editing, "id")
  let f_name = @ui.Field::new(text=if is_edit { text(editing, "name") } else { "" })
  let f_endpoint = @ui.Field::new(text=if is_edit { text(editing, "endpoint") } else { "" })
  let f_bucket = @ui.Field::new(text=if is_edit { text(editing, "bucket") } else { "" })
  let f_region = @ui.Field::new(text=if is_edit && text(editing, "region") != "" { text(editing, "region") } else { "auto" })
  let f_prefix = @ui.Field::new(text=if is_edit { text(editing, "prefix") } else { "stillfail-backup" })
  let f_access = @ui.Field::new(text="")
  let f_secret = @ui.Field::new(text="")
  let f_enc = @ui.Field::new(text="")
  let testing : @signals.Signal[Bool] = @signals.signal(false)
  let test_res : @signals.Signal[(Bool, String)?] = @signals.signal(None)
  let saving = fn() { is_doing(core, ["copies.setSettings"], [("station", address)]) }
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
      @sf.field_node(v, fn() { @sf.t("web-pages.stations.copies.s3FieldName") }, fn(f) {
        @sf.input_node(
          f,
          f_name,
          placeholder=@sf.t("web-pages.stations.copies.s3FieldNamePh"),
          label=@sf.t("web-pages.stations.copies.s3FieldName"),
        )
        |> ignore
      })
      @sf.field_node(v, fn() { @sf.t("web-pages.stations.copies.s3FieldEndpoint") }, fn(f) {
        @sf.input_node(
          f,
          f_endpoint,
          placeholder=@sf.t("web-pages.stations.copies.s3FieldEndpointPh"),
          label=@sf.t("web-pages.stations.copies.s3FieldEndpoint"),
        )
        |> ignore
      })
      @sf.field_node(v, fn() { @sf.t("web-pages.stations.copies.s3FieldBucket") }, fn(f) {
        @sf.input_node(
          f,
          f_bucket,
          placeholder=@sf.t("web-pages.stations.copies.s3FieldBucketPh"),
          label=@sf.t("web-pages.stations.copies.s3FieldBucket"),
        )
        |> ignore
      })
      @sf.field_node(v, fn() { @sf.t("web-pages.stations.copies.s3FieldRegion") }, fn(f) {
        @sf.input_node(f, f_region, placeholder="auto", label=@sf.t("web-pages.stations.copies.s3FieldRegion"))
        |> ignore
      })
      @sf.field_node(v, fn() { @sf.t("web-pages.stations.copies.s3FieldPrefix") }, fn(f) {
        @sf.input_node(f, f_prefix, placeholder="stillfail-backup", label=@sf.t("web-pages.stations.copies.s3FieldPrefix"))
        |> ignore
      })
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
          if is_edit && edit_id != "" {
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
        disabled=fn() { !can_submit() || testing.get() || saving() },
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
pub fn copies_restore_confirm(core : Core, address : String, copy : Json?) -> Unit {
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
      @settings.act(core, @sf.t("web-pages.stations.copies.restoreWhat"), "copies.restore", obj(params))
    },
  )
}
