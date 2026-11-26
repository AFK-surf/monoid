// A workspace's devices (设备, 2026-11-10: the core's `devices`, client/core-ts/src/devices.ts): what agents use that runs
// no station, one list, each its person's. A device is attached to a station (on its USB, in its network) or is a
// person's phone lent by its app. On a whole station it is every chat's; on one that only runs tasks, and a phone, a
// chat uses it by its person's grant (a card in the chat, `rig.decide`), or 免批准 on it (`device.setOpen`).
//
// Here: a station's 设备 section (its devices, and adding one: any member on a whole station, its person on one that
// only runs tasks), a device's panel (where it is, whose, who uses it, 免批准 and taking it off for its person), and
// the words a list's row says of one (the stations' place lists them all: settings stations.mbt, sfdesk places.mbt).

///|
/// The workspace's devices as the core says them now.
pub fn devices_listed(core : Core, here : Here) -> Array[Json] {
  if !(core.devices_on)() {
    return []
  }
  let ask = devices_ask(here)
  items((core.topic)(ask.0, ask.1).get().value, "devices")
}

///|
/// What the core is asked for the workspace's devices (devices_listed's, where the core asks them at all): its `devices`.
pub fn devices_ask(here : Here) -> (String, Map[String, Json]) {
  ("devices", { "workspace": str(here.workspace) })
}

///|
/// The device `id` attached to station `station` (a phone's: "" for any station it is lent to), as the core says it now.
fn device_at(core : Core, here : Here, station : String, id : String) -> Json? {
  devices_listed(core, here)
  .iter()
  .find_first(fn(d) { text(Some(d), "id") == id && (station == "" || text(Some(d), "station") == station || text(Some(d), "via") == "phone") })
}

///|
/// What kind of thing `d` is, in words.
pub fn device_kind_words(d : Json?) -> String {
  if text(d, "via") == "phone" {
    return @sf.t("web-pages.devices.kind.phone")
  }
  @sf.t("web-pages.devices.kind." + text(d, "kind"))
}

///|
/// Its mark: a phone, a screen, the network's, a plug's.
pub fn device_icon(d : Json?) -> String {
  match (text(d, "via"), text(d, "kind")) {
    ("phone", _) | (_, "adb") => "phone"
    (_, "serial") => "plug"
    (_, "airplay") => "monitor"
    _ => "web"
  }
}

///|
/// Whose it is, to the viewer: 我的, or its owner's name.
pub fn device_whose(d : Json?) -> String {
  if flag(d, "mine") {
    @sf.t("web-pages.devices.mine")
  } else {
    let who = if text(d, "ownerName") != "" { text(d, "ownerName") } else { text(d, "ownerEmail") }
    @sf.t("web-pages.devices.owner", args=[("who", who)])
  }
}

///|
/// What a list's row says of `d`: its kind, where it is, whose, and how chats use it (or that it is away).
pub fn device_said(d : Json?) -> String {
  let state = match field(d, "online") {
    Some(False) => @sf.t("web-pages.devices.offline")
    _ => if flag(d, "open") { @sf.t("web-pages.devices.openAll") } else { @sf.t("web-pages.devices.needsGrant") }
  }
  let where_ = if text(d, "via") == "phone" { "" } else { @sf.t("web-pages.devices.on", args=[("station", text(d, "stationName"))]) }
  join([device_kind_words(d), where_, device_whose(d), state], " · ")
}

///|
/// A station's 设备 section, made once in `b`: its devices, a row each opening its panel, and 添加设备 where the viewer
/// may (`can_add`: any member on a whole station, its person on one that only runs tasks).
pub fn station_devices_node(b : @view.View, core : Core, here : () -> Here, station : String, rig : Bool, can_add : () -> Bool) -> Unit {
  // (worked out once a change, the section's count, its 添加设备 and its list reading it: its rows' own as they were
  // where what changed is none of this station's)
  let listed = @signals.computed(fn(_) {
    devices_listed(core, here()).filter(fn(d) { text(Some(d), "station") == station && text(Some(d), "via") != "phone" })
  }, same=fn(a, b) { a == b })
  let mine = fn() { listed.get() }
  let note = fn() { if rig { @sf.t("web-pages.devices.rigNote") } else { "" } }
  let count = fn() { mine().length() }
  @sf.section_node(
    b,
    fn() { @sf.t("web-pages.devices.title") },
    note~,
    title_after=fn(l) {
      l.show(fn() { count() > 0 }, fn(n) {
        @sf.words_node(n, fn() { count().to_string() }, fn() { @ui.text_style(size=Meta, leading=L7, weight=Medium, color=Subtle, wrap=false) }) |> ignore
      })
    },
    ends=fn(e) {
      e.show(fn() { can_add() && mine().length() > 0 }, fn(a) {
        @sf.action_node(a, fn() { @sf.t("web-pages.devices.add") }, fn() {
          let (x, y, w, h) = a.placed_window_now()
          add_device(core, @signals.untracked(here), station, rig, At(x, y, w, h))
        }, icon="plus")
      })
    },
    fn(s) {
      @sf.group_node(s, fn(g) {
        g.each(mine, fn(d) { "d/" + text(Some(d), "id") }, fn(row, d) {
          let dv = fn() { Some(d.get()) }
          row.box(fn(holder) {
            @sf.link_row_node(
              holder,
              fn() { text(dv(), "name") },
              fn() {
                let (x, y, w, h) = holder.placed_window_now()
                open_device(core, @signals.untracked(here), station, text(@signals.untracked(dv), "id"), @sf.Beside::At(x, y, w, h).anchor())
              },
              note=fn() { join([device_kind_words(dv()), text(dv(), "target"), device_whose(dv())], " · ") },
              lead=LeadLine(fn(l) { @sf.icon_node(l, @signals.untracked(fn() { device_icon(dv()) }), devices_row_glyph, By(fn() { @sf.theme().p.muted })) |> ignore }),
            )
          })
          |> ignore
        })
        g.show(fn() { mine().length() == 0 && !can_add() }, fn(o) {
          @sf.link_row_node(o, fn() { @sf.t("web-pages.devices.none") }, fn() {  }, goes=false, chevron=false, lacks=true)
        })
        g.show(fn() { can_add() && mine().length() == 0 }, fn(holder) {
          @sf.link_row_node(
            holder,
            fn() { @sf.t("web-pages.devices.add") },
            fn() {
              let (x, y, w, h) = holder.placed_window_now()
              add_device(core, @signals.untracked(here), station, rig, At(x, y, w, h))
            },
            note=fn() { @sf.t("web-pages.devices.addNote") },
            lead=LeadLine(fn(l) { @sf.icon_node(l, "plus", devices_row_glyph, By(fn() { @sf.theme().p.muted })) |> ignore }),
          )
        })
      })
    },
  )
}

///|
/// A device row's mark's side.
let devices_row_glyph : Double = 18.0

///|
/// A device added to `station`: which kind (a menu beside what asked), its name, what it is reached at, a serial
/// port's speed, then `device.add` (on one that only runs tasks, signed by its person: the core asks them). On a whole
/// station, AirPlay opens the LAN scan panel first.
pub fn add_device(core : Core, here : Here, station : String, rig : Bool, from : @sf.Beside) -> Unit {
  let kinds = ["tcp", "serial", "adb", "airplay"]
  @sf.menu(
    kinds.map(fn(k) {
      let icon = match k {
        "tcp" => "web"
        "serial" => "plug"
        "airplay" => "monitor"
        _ => "phone"
      }
      Some(@sf.menu_item_of(@sf.t("web-pages.devices.kind." + k), icon~, fn() {
        if k == "airplay" && !rig {
          add_airplay_scan(core, here, station, from.anchor())
        } else {
          add_device_named(core, here, station, rig, k)
        }
      }))
    }),
    from~,
    title=@sf.t("web-pages.devices.add"),
  )
}

///|
/// String array extracted from a JSON array field (empty if absent or not an array).
fn json_strings(v : Json?) -> Array[String] {
  match v {
    Some(Array(xs)) => {
      let out : Array[String] = []
      for x in xs {
        match x {
          String(s) if s != "" => out.push(s)
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
/// Integer extracted from a JSON number field, or `fallback`.
fn json_int(v : Json?, key : String, fallback : Int) -> Int {
  match field(v, key) {
    Some(Number(n, ..)) => n.to_int()
    _ => fallback
  }
}

///|
/// All protocol names advertised by an AirPlay scan candidate.
fn airplay_candidate_protocols(c : Json?) -> Array[String] {
  let out : Array[String] = []
  for p in items(c, "protocols") {
    let name = text(Some(p), "protocol")
    if name != "" && !out.contains(name) {
      out.push(name)
    }
  }
  out
}

///|
/// Protocols of an AirPlay scan candidate that require mandatory PIN pairing.
fn airplay_mandatory_protocols(c : Json?) -> Array[String] {
  let out : Array[String] = []
  for p in items(c, "protocols") {
    if text(Some(p), "pairing") == "mandatory" {
      let name = text(Some(p), "protocol")
      if name != "" && !out.contains(name) {
        out.push(name)
      }
    }
  }
  out
}

///|
/// Status badge text for an AirPlay scan candidate.
fn airplay_candidate_status(c : Json?) -> String {
  if flag(c, "alreadyAdded") {
    @sf.t("web-pages.devices.airplay.alreadyAdded")
  } else if airplay_mandatory_protocols(c).length() > 0 {
    @sf.t("web-pages.devices.airplay.needsPairing")
  } else {
    @sf.t("web-pages.devices.airplay.noPairingNeeded")
  }
}

///|
/// Pairing status text for an AirPlay device in its detail panel.
fn airplay_pair_status(d : Json?) -> String {
  match field(d, "paired") {
    Some(True) => @sf.t("web-pages.devices.airplay.paired")
    Some(False) => @sf.t("web-pages.devices.airplay.unpaired")
    _ => @sf.t("web-pages.devices.airplay.noPairingNeeded")
  }
}

///|
/// Human-readable capability list derived from an AirPlay device's protocols.
fn airplay_capabilities_text(d : Json?) -> String {
  let protos = json_strings(field(d, "protocols"))
  let caps : Array[String] = []
  let push_cap = fn(key : String) {
    let word = @sf.t("web-pages.devices.airplay.cap." + key)
    if !caps.contains(word) {
      caps.push(word)
    }
  }
  if protos.contains("companion") {
    push_cap("remote")
    push_cap("apps")
    push_cap("power")
    push_cap("keyboard")
  }
  if protos.contains("airplay") {
    push_cap("play_url")
    push_cap("playing")
  }
  if protos.contains("raop") {
    push_cap("stream_audio")
    push_cap("volume")
  }
  join(caps, if @sf.language() == "en" { ", " } else { "、" })
}

///|
/// AirPlay LAN scan panel: scans on open, offers one-click pyatv install if missing, lists candidates
/// (already-added disabled; mandatory-pairing enters PIN flow; pairing-free goes to naming), and
/// always keeps rescan + manual entry available at the foot.
fn add_airplay_scan(core : Core, here : Here, station : String, from : @sf.Anchor) -> Unit {
  let scanning : @signals.Signal[Bool] = @signals.signal(true)
  let installing : @signals.Signal[Bool] = @signals.signal(false)
  let env_ready : @signals.Signal[Bool] = @signals.signal(true)
  let env_error : @signals.Signal[String] = @signals.signal("")
  let scan_error : @signals.Signal[String] = @signals.signal("")
  let candidates : @signals.Signal[Array[Json]] = @signals.signal([])
  let alive : Ref[Bool] = { val: true }

  let do_scan = fn() {
    @signals.start_batch()
    scanning.set(true)
    scan_error.set("")
    @signals.end_batch()
    (core.call)(
      "device.scan",
      obj([("workspace", str(here.workspace)), ("station", str(station)), ("kind", str("airplay"))]),
      fn(r) {
        if !alive.val {
          return
        }
        match r {
          Ok(res) => {
            let env = field(Some(res), "env")
            let ready = match env {
              Some(_) => flag(env, "ready")
              None => true
            }
            @signals.start_batch()
            env_ready.set(ready)
            env_error.set(text(env, "error"))
            candidates.set(items(Some(res), "candidates"))
            scanning.set(false)
            @signals.end_batch()
          }
          Err(e) => {
            @signals.start_batch()
            scan_error.set(error_text(e))
            scanning.set(false)
            @signals.end_batch()
          }
        }
      },
    )
  }

  let do_install = fn() {
    if installing.untracked() {
      return
    }
    installing.set(true)
    (core.call)(
      "device.installAirplay",
      obj([("workspace", str(here.workspace)), ("station", str(station))]),
      fn(r) {
        if !alive.val {
          return
        }
        installing.set(false)
        match r {
          Ok(_) => do_scan()
          Err(e) => {
            @ui.haptic(Reject)
            (core.say)(fill("android-misc.act.failed", [("what", @sf.t("web-pages.devices.airplay.installPyatv")), ("error", error_text(e))]))
          }
        }
      },
    )
  }

  do_scan()

  let foot = fn(f : @view.View, close : () -> Unit) {
    @sf.foot_place_node(f, fn() { true }, fn(p) {
      @sf.button_node(
        p,
        fn() { @sf.t("web-pages.devices.airplay.manual") },
        fn() {
          close()
          add_device_named(core, here, station, false, "airplay")
        },
      )
      |> ignore
    })
    @sf.foot_place_node(f, fn() { true }, fn(p) {
      @sf.button_node(
        p,
        fn() { @sf.t("web-pages.devices.airplay.rescan") },
        fn() { do_scan() },
        tone=Primary,
        busy=fn() { scanning.get() },
        disabled=fn() { scanning.get() || installing.get() },
      )
      |> ignore
    })
  }

  @sf.panel_nodes(
    @sf.t("web-pages.devices.kind.airplay"),
    from~,
    gone=fn() { alive.val = false },
    foot~,
    fn(v, close) {
      v.show(fn() { scanning.get() }, fn(o) {
        @sf.panel_note_node(o, fn() { @sf.t("web-pages.devices.airplay.scanning") })
      })
      v.show(fn() { !scanning.get() && scan_error.get() != "" }, fn(o) {
        @sf.style_node(o, fn() { @sf.panel_words_in_node(o).then(airplay_block_pad) })
        @sf.words_node(o, fn() { scan_error.get() }, fn() { airplay_error_words }) |> ignore
      })
      v.show(fn() { !scanning.get() && scan_error.get() == "" && !env_ready.get() }, fn(o) {
        @sf.panel_note_node(o, fn() { @sf.t("web-pages.devices.airplay.pyatvMissing") })
        o.show(fn() { env_error.get() != "" }, fn(e) {
          @sf.panel_note_node(e, fn() { env_error.get() })
        })
        o.box(fn(b) {
          @sf.style_node(b, fn() { @sf.panel_words_in_node(b).then(airplay_block_pad) })
          @sf.button_node(
            b,
            fn() {
              if installing.get() {
                @sf.t("web-pages.devices.airplay.installing")
              } else {
                @sf.t("web-pages.devices.airplay.installPyatv")
              }
            },
            fn() { do_install() },
            tone=Primary,
            busy=fn() { installing.get() },
            disabled=fn() { installing.get() },
          )
          |> ignore
        })
        |> ignore
      })
      v.show(fn() { !scanning.get() && scan_error.get() == "" && env_ready.get() && candidates.get().length() == 0 }, fn(o) {
        @sf.panel_note_node(o, fn() { @sf.t("web-pages.devices.airplay.noneFound") })
      })
      v.show(fn() { !scanning.get() && scan_error.get() == "" && env_ready.get() && candidates.get().length() > 0 }, fn(o) {
        @sf.panel_group_node(o, fn() { "" }, fn(g) {
          g.each(fn() { candidates.get() }, fn(c) { "ap/" + text(Some(c), "identifier") }, fn(row, c) {
            let cv = fn() { Some(c.get()) }
            let added = flag(@signals.untracked(cv), "alreadyAdded")
            @sf.link_row_node(
              row,
              fn() { text(cv(), "name") },
              fn() {
                let now = @signals.untracked(cv)
                if flag(now, "alreadyAdded") {
                  return
                }
                let identifier = text(now, "identifier")
                let address = text(now, "address")
                let cand_name = text(now, "name")
                let model = text(now, "model")
                let all_protos = airplay_candidate_protocols(now)
                let mandatory = airplay_mandatory_protocols(now)
                close()
                if mandatory.length() == 0 {
                  ask_airplay_name(core, here, station, cand_name, identifier, model, all_protos, false, "", from)
                } else {
                  start_airplay_pairing(
                    core,
                    here,
                    station,
                    identifier,
                    address,
                    cand_name,
                    model,
                    mandatory,
                    from,
                    fn(pair_id, paired_protos) {
                      let final_protos = if paired_protos.length() > 0 { paired_protos } else { all_protos }
                      ask_airplay_name(core, here, station, cand_name, identifier, model, final_protos, paired_protos.length() > 0, pair_id, from)
                    },
                  )
                }
              },
              value=fn() { airplay_candidate_status(cv()) },
              note=fn() { join([text(cv(), "model"), text(cv(), "address")], ", ") },
              lead=LeadLine(fn(l) { @sf.icon_node(l, "monitor", devices_row_glyph, By(fn() { @sf.theme().p.muted })) |> ignore }),
              lacks=added,
              goes=!added,
              chevron=!added,
            )
          })
        })
      })
    },
  )
}

///|
/// Starts a multi-protocol AirPlay pairing session on `station`; opens the PIN panel if further
/// steps are required, or invokes `on_done` directly when already complete.
fn start_airplay_pairing(
  core : Core,
  here : Here,
  station : String,
  identifier : String,
  address : String,
  name : String,
  model : String,
  protocols : Array[String],
  from : @sf.Anchor,
  on_done : (String, Array[String]) -> Unit,
) -> Unit {
  let params : Array[(String, Json)] = [
    ("workspace", str(here.workspace)),
    ("station", str(station)),
    ("identifier", str(identifier)),
    ("protocols", Json::array(protocols.map(str))),
  ]
  if address != "" {
    params.push(("address", str(address)))
  }
  if name != "" {
    params.push(("name", str(name)))
  }
  if model != "" {
    params.push(("model", str(model)))
  }
  (core.call)("device.pairStart", obj(params), fn(r) {
    match r {
      Ok(res) => {
        let pair_id = text(Some(res), "pairId")
        if flag(Some(res), "done") {
          on_done(pair_id, json_strings(field(Some(res), "pairedProtocols")))
        } else {
          open_airplay_pin_panel(
            core,
            here,
            station,
            pair_id,
            json_int(Some(res), "step", 1),
            json_int(Some(res), "total", protocols.length()),
            text(Some(res), "protocol"),
            from,
            on_done,
          )
        }
      }
      Err(e) => {
        @ui.haptic(Reject)
        (core.say)(fill("android-misc.act.failed", [("what", @sf.t("web-pages.devices.airplay.pinTitle")), ("error", error_text(e))]))
      }
    }
  })
}

///|
/// 4-digit PIN entry panel stepping through AirPlay protocols; cancelling or closing early calls
/// `device.pairCancel` so the TV dismisses its PIN overlay.
fn open_airplay_pin_panel(
  core : Core,
  here : Here,
  station : String,
  pair_id : String,
  initial_step : Int,
  initial_total : Int,
  initial_protocol : String,
  from : @sf.Anchor,
  on_done : (String, Array[String]) -> Unit,
) -> Unit {
  let step_sig : @signals.Signal[Int] = @signals.signal(initial_step)
  let total_sig : @signals.Signal[Int] = @signals.signal(initial_total)
  let proto_sig : @signals.Signal[String] = @signals.signal(initial_protocol)
  let busy : @signals.Signal[Bool] = @signals.signal(false)
  let err : @signals.Signal[String] = @signals.signal("")
  let finished : Ref[Bool] = { val: false }
  let alive : Ref[Bool] = { val: true }
  let pin_field = @ui.Field::new()

  let finish_step = fn(pin : String, skip : Bool, close : () -> Unit) {
    if busy.untracked() {
      return
    }
    let trimmed = pin.trim(chars=" \t\n").to_owned()
    if !skip && trimmed == "" {
      return
    }
    @signals.start_batch()
    busy.set(true)
    err.set("")
    @signals.end_batch()
    let params : Array[(String, Json)] = [
      ("workspace", str(here.workspace)),
      ("station", str(station)),
      ("pairId", str(pair_id)),
    ]
    if skip {
      params.push(("skip", Json::boolean(true)))
    } else {
      params.push(("pin", str(trimmed)))
    }
    (core.call)("device.pairFinish", obj(params), fn(r) {
      if !alive.val {
        return
      }
      match r {
        Ok(res) => {
          if flag(Some(res), "done") {
            finished.val = true
            busy.set(false)
            let paired = json_strings(field(Some(res), "pairedProtocols"))
            close()
            on_done(pair_id, paired)
          } else {
            @signals.start_batch()
            busy.set(false)
            step_sig.set(json_int(Some(res), "step", step_sig.untracked() + 1))
            total_sig.set(json_int(Some(res), "total", total_sig.untracked()))
            proto_sig.set(text(Some(res), "protocol"))
            err.set("")
            pin_field.set("")
            @signals.end_batch()
          }
        }
        Err(e) => {
          @signals.start_batch()
          busy.set(false)
          err.set(error_text(e))
          @signals.end_batch()
          @ui.haptic(Reject)
        }
      }
    })
  }

  let foot = fn(f : @view.View, close : () -> Unit) {
    @sf.foot_place_node(f, fn() { true }, fn(p) {
      @sf.button_node(
        p,
        fn() { @sf.t("web-pages.devices.airplay.skipProtocol") },
        fn() {
          p.focus_let_go()
          finish_step("", true, close)
        },
        disabled=fn() { busy.get() },
      )
      |> ignore
    })
    @sf.foot_place_node(f, fn() { true }, fn(p) {
      @sf.button_node(
        p,
        fn() { @sf.t("web-pages.devices.continue") },
        fn() {
          finish_step(pin_field.text(), false, close)
        },
        tone=Primary,
        busy=fn() { busy.get() },
        disabled=fn() { busy.get() || pin_field.text().trim(chars=" \t\n").to_owned() == "" },
      )
      |> ignore
    })
  }

  @sf.panel_nodes(
    @sf.t("web-pages.devices.airplay.pinTitle"),
    from~,
    form=true,
    gone=fn() {
      alive.val = false
      if !finished.val {
        (core.call)(
          "device.pairCancel",
          obj([("workspace", str(here.workspace)), ("station", str(station)), ("pairId", str(pair_id))]),
          fn(_) {  },
        )
      }
    },
    foot~,
    fn(v, close) {
      v.box(fn(b) {
        @sf.style_node(b, fn() { @sf.panel_words_in_node(b).then(airplay_form_column) })
        @sf.words_node(
          b,
          fn() {
            fill(
              "web-pages.devices.airplay.pinStep",
              [("step", step_sig.get().to_string()), ("total", total_sig.get().to_string()), ("protocol", proto_sig.get())],
            )
          },
          fn() { airplay_step_words },
        )
        |> ignore
        @sf.words_node(b, fn() { @sf.t("web-pages.devices.airplay.pinHint") }, fn() { airplay_hint_words }) |> ignore
        let pin_in = @sf.input_node(
          b,
          pin_field,
          placeholder=@sf.t("web-pages.devices.airplay.pinPlaceholder"),
          disabled=fn() { busy.get() },
          submitted=fn(s) { finish_step(s, false, close) },
        )
        @sf.panel_opens_in_node(pin_in)
        b.show(fn() { err.get() != "" }, fn(e) {
          @sf.words_node(e, fn() { err.get() }, fn() { airplay_error_words }) |> ignore
        })
      })
      |> ignore
    },
  )
}

///|
/// Naming panel for a discovered AirPlay device (prefilled with its advertised name, allowing
/// submission without requiring an edit and preserving `pair_id` on retry if `device.add` fails).
fn ask_airplay_name(
  core : Core,
  here : Here,
  station : String,
  default_name : String,
  identifier : String,
  model : String,
  protocols : Array[String],
  paired : Bool,
  pair_id : String,
  from : @sf.Anchor,
) -> Unit {
  let name_field = @ui.Field::new()
  name_field.set(default_name)
  let busy : @signals.Signal[Bool] = @signals.signal(false)
  let err : @signals.Signal[String] = @signals.signal("")
  let added : Ref[Bool] = { val: false }
  let alive : Ref[Bool] = { val: true }

  let submit = fn(close : () -> Unit) {
    if busy.untracked() {
      return
    }
    let name = name_field.text().trim(chars=" \t\n").to_owned()
    if name == "" {
      return
    }
    @signals.start_batch()
    busy.set(true)
    err.set("")
    @signals.end_batch()
    let params : Array[(String, Json)] = [
      ("workspace", str(here.workspace)),
      ("station", str(station)),
      ("name", str(name)),
      ("kind", str("airplay")),
      ("target", str(identifier)),
      ("paired", Json::boolean(paired)),
    ]
    if model != "" {
      params.push(("model", str(model)))
    }
    if protocols.length() > 0 {
      params.push(("protocols", Json::array(protocols.map(str))))
    }
    if pair_id != "" {
      params.push(("pairId", str(pair_id)))
    }
    (core.call)("device.add", obj(params), fn(r) {
      if !alive.val {
        return
      }
      match r {
        Ok(v) => {
          added.val = true
          busy.set(false)
          match pending_said(v) {
            "" => {
              (core.say)(@sf.t("web-pages.devices.added"))
              @ui.haptic(Confirm)
            }
            waits => (core.say)(waits)
          }
          close()
        }
        Err(e) => {
          @signals.start_batch()
          busy.set(false)
          err.set(error_text(e))
          @signals.end_batch()
          @ui.haptic(Reject)
        }
      }
    })
  }

  let foot = fn(f : @view.View, close : () -> Unit) {
    @sf.foot_place_node(f, fn() { true }, fn(p) {
      @sf.button_node(p, fn() { tr("common.cancel") }, fn() {
        p.focus_let_go()
        close()
      })
      |> ignore
    })
    @sf.foot_place_node(f, fn() { true }, fn(p) {
      @sf.button_node(
        p,
        fn() { @sf.t("web-pages.devices.add") },
        fn() {
          p.focus_let_go()
          submit(close)
        },
        tone=Primary,
        busy=fn() { busy.get() },
        disabled=fn() { busy.get() || name_field.text().trim(chars=" \t\n").to_owned() == "" },
      )
      |> ignore
    })
  }

  @sf.panel_nodes(
    @sf.t("web-pages.devices.name"),
    from~,
    form=true,
    gone=fn() {
      alive.val = false
      if !added.val && pair_id != "" {
        (core.call)(
          "device.pairCancel",
          obj([("workspace", str(here.workspace)), ("station", str(station)), ("pairId", str(pair_id))]),
          fn(_) {  },
        )
      }
    },
    foot~,
    fn(v, close) {
      v.box(fn(b) {
        @sf.style_node(b, fn() { @sf.panel_words_in_node(b).then(airplay_form_column) })
        @sf.words_node(b, fn() { @sf.t("web-pages.devices.kindNote.airplay") }, fn() { airplay_hint_words }) |> ignore
        let name_in = @sf.input_node(
          b,
          name_field,
          placeholder=@sf.t("web-pages.devices.namePlaceholder"),
          disabled=fn() { busy.get() },
          submitted=fn(_) { submit(close) },
        )
        @sf.panel_opens_in_node(name_in)
        b.show(fn() { err.get() != "" }, fn(e) {
          @sf.words_node(e, fn() { err.get() }, fn() { airplay_error_words }) |> ignore
        })
      })
      |> ignore
    },
  )
}

///|
/// The rest of adding one of kind `kind`: asked a line at a time, each a step further in.
fn add_device_named(core : Core, here : Here, station : String, rig : Bool, kind : String) -> Unit {
  ignore(rig)
  ask(@sf.t("web-pages.devices.name"), "", @sf.t("web-pages.devices.namePlaceholder"), @sf.t("web-pages.devices.continue"), hint=@sf.t("web-pages.devices.kindNote." + kind), fn(name) {
    ask(
      @sf.t("web-pages.devices.target." + kind),
      "",
      @sf.t("web-pages.devices.target." + kind + "Placeholder"),
      if kind == "serial" { @sf.t("web-pages.devices.continue") } else { @sf.t("web-pages.devices.add") },
      fn(target) {
        let add = fn(baud : String) {
          let params : Array[(String, Json)] = [("workspace", str(here.workspace)), ("station", str(station)), ("name", str(name)), ("kind", str(kind)), ("target", str(target))]
          if baud != "" {
            params.push(("baud", str(baud)))
          }
          act(core, @sf.t("web-pages.devices.add"), "device.add", obj(params), done=@sf.t("web-pages.devices.added"))
        }
        if kind == "serial" {
          @sf.ask(@sf.t("web-pages.devices.baud"), @sf.t("web-pages.devices.add"), add, placeholder="115200", hint=@sf.t("web-pages.devices.baudHint"), empty=true)
        } else {
          add("")
        }
      },
    )
  })
}

///|
/// Device `id` (attached to `station`)'s panel beside what opened it: what it is and where, whose; the chats using it
/// (taken back by its person) and asking for it; 免批准 on one of a rig's (its person's); taking it off (its person's,
/// a whole station's by the workspace's owners and admins too).
pub fn open_device(core : Core, here : Here, station : String, id : String, from : @sf.Anchor) -> Unit {
  let d = fn() { device_at(core, here, station, id) }
  let first = d()
  let via = text(first, "via")
  let role = text(workspace_view(core, here).value, "role")
  let manager = role == "owner" || role == "admin"
  let on = fn() { [("device", id)] }
  let can_remove = fn() { via != "phone" && (flag(d(), "mine") || (via == "station" && manager)) }
  let foot : ((@view.View, () -> Unit) -> Unit)? = if via != "phone" {
    Some(fn(f, close) {
      @sf.foot_place_node(f, can_remove, fn(p) {
        @sf.button_node(
          p,
          fn() { @sf.t("web-pages.devices.remove") },
          fn() {
            close()
            confirm(@sf.t("web-pages.devices.removeAsk", args=[("name", text(first, "name"))]), @sf.t("web-pages.devices.removeNote"), @sf.t("web-pages.devices.remove"), danger=true, fn() {
              act(core, @sf.t("web-pages.devices.remove"), "device.remove", obj([("workspace", str(here.workspace)), ("station", str(station)), ("device", str(id))]), done=@sf.t("web-pages.devices.removed"))
            })
          },
          tone=Danger,
        )
        |> ignore
      })
    })
  } else {
    None
  }
  @sf.panel_nodes(text(first, "name"), from~, foot?, fn(v, close) {
    // taken off meanwhile (here or elsewhere): the panel goes
    v.reacts(fn() { d() is None }, fn(gone) {
      if gone {
        close()
      }
    })
    // what it is, a row each, named at its start and said at its end: its kind, its address (pressed, copied), the
    // station it is on (pressed, that station's page), whose it is, and which chats may use it
    @sf.panel_group_node(v, fn() { "" }, fn(g) {
      @sf.panel_row_node(g, fn() { @sf.t("web-pages.devices.label.kind") }, fn() {  }, note=fn() {
        let model = text(d(), "model")
        if text(d(), "kind") == "airplay" && model != "" {
          model
        } else {
          device_kind_words(d())
        }
      })
      @sf.panel_row_node(
        g,
        fn() { @sf.t("web-pages.devices.label.target") },
        fn() {
          @ui.clipboard_set(text(@signals.untracked(d), "target"))
          (core.say)(@sf.t("common.copied"))
        },
        note=fn() {
          text(d(), "target") +
          (match field(d(), "baud") {
            Some(Number(n, ..)) => " · " + n.to_int().to_string() + " baud"
            _ => ""
          })
        },
        end="copy",
      )
      g.show(fn() { via != "phone" }, fn(o) {
        @sf.panel_row_node(
          o,
          fn() { @sf.t("web-pages.devices.label.station") },
          fn() {
            close()
            (core.push)(Station(here.workspace + "/" + station))
          },
          note=fn() { text(d(), "stationName") },
          end="chevron-right",
        )
      })
      @sf.panel_row_node(g, fn() { @sf.t("web-pages.devices.label.owner") }, fn() {  }, note=fn() {
        if flag(d(), "mine") {
          @sf.t("web-pages.devices.me")
        } else if text(d(), "ownerName") != "" {
          text(d(), "ownerName")
        } else {
          text(d(), "ownerEmail")
        }
      })
      @sf.panel_row_node(g, fn() { @sf.t("web-pages.devices.label.who") }, fn() {  }, note=fn() {
        if flag(d(), "open") { @sf.t("web-pages.devices.whoAll") } else { @sf.t("web-pages.devices.whoGranted") }
      })
    })
    // 免批准 on one of a rig's: its person's switch
    v.show(fn() { via == "rig" && flag(d(), "mine") }, fn(o) {
      @sf.panel_switch_row_node(
        o,
        fn() { @sf.t("web-pages.devices.open") },
        fn() { flag(d(), "ownOpen") },
        fn(to) {
          act(core, @sf.t("web-pages.devices.open"), "device.setOpen", obj([("workspace", str(here.workspace)), ("station", str(station)), ("device", str(id)), ("open", Json::boolean(to))]))
        },
        note=fn() { @sf.t("web-pages.devices.openNote") },
      )
    })
    // who uses it: the chats granted it (a grant of its station gives it too), taken back by its person
    v.show(fn() { via != "station" }, fn(o) {
      // (its heading where the rows' words start, as the rows above it have theirs: not in by a row's padding)
      o.box(fn(l) {
        @sf.style_node(l, device_using_at)
        @sf.words_node(l, fn() { @sf.t("web-pages.devices.using") }, device_using_words) |> ignore
      })
      |> ignore
      @sf.panel_group_node(o, fn() { "" }, fn(g) {
        g.each(fn() { items(d(), "grants") }, fn(x) { "g/" + text(Some(x), "request") }, fn(row, x) {
          let r = fn() { Some(x.get()) }
          @sf.panel_row_node(
            row,
            fn() { device_chat_title(r()) },
            fn() {
              let now = @signals.untracked(r)
              if !flag(@signals.untracked(d), "mine") || flag(now, "whole") || via != "rig" {
                return
              }
              confirm(device_chat_title(now), "", @sf.t("web-pages.rigs.revoke"), danger=true, fn() {
                act(core, @sf.t("web-pages.rigs.revoke"), "rig.revoke", obj([("workspace", str(here.workspace)), ("rig", str(station)), ("request", str(text(now, "request"))), ("station", str(text(now, "station")))]))
              })
            },
            note=fn() {
              if flag(r(), "whole") {
                @sf.t("web-pages.devices.byStation", args=[("name", text(d(), "stationName"))])
              } else {
                @sf.t("web-pages.devices.chatOn", args=[("station", text(r(), "stationName"))])
              }
            },
          )
        })
        g.show(fn() { items(d(), "grants").length() == 0 && !flag(d(), "open") }, fn(n) { @sf.panel_note_node(n, fn() { @sf.t("web-pages.devices.useNone") }) })
      })
    })
    // AirPlay capabilities and pairing status
    v.show(fn() { text(d(), "kind") == "airplay" && airplay_capabilities_text(d()) != "" }, fn(o) {
      o.box(fn(l) {
        @sf.style_node(l, device_using_at)
        @sf.words_node(l, fn() { @sf.t("web-pages.devices.airplay.capabilities") }, device_using_words) |> ignore
      })
      |> ignore
      o.box(fn(c) {
        @sf.style_node(c, fn() { airplay_caps_at })
        @sf.words_node(c, fn() { airplay_capabilities_text(d()) }, fn() { airplay_hint_words }) |> ignore
      })
      |> ignore
    })
    v.show(fn() { text(d(), "kind") == "airplay" && !(via == "station" && (flag(d(), "mine") || manager)) }, fn(o) {
      @sf.panel_note_node(o, fn() { airplay_pair_status(d()) })
    })
    // Re-pair an AirPlay device on a whole station
    v.show(fn() { text(d(), "kind") == "airplay" && via == "station" && (flag(d(), "mine") || manager) }, fn(o) {
      @sf.panel_row_node(
        o,
        fn() { @sf.t("web-pages.devices.airplay.repair") },
        fn() {
          let now = @signals.untracked(d)
          let protos = json_strings(field(now, "protocols"))
          let target_protos = if protos.length() > 0 { protos } else { ["airplay", "companion", "raop"] }
          close()
          start_airplay_pairing(
            core,
            here,
            station,
            text(now, "target"),
            "",
            text(now, "name"),
            text(now, "model"),
            target_protos,
            from,
            fn(pair_id, _paired) {
              act(
                core,
                @sf.t("web-pages.devices.airplay.repair"),
                "device.rebindPair",
                obj([("workspace", str(here.workspace)), ("station", str(station)), ("device", str(id)), ("pairId", str(pair_id))]),
                done=@sf.t("web-pages.devices.airplay.repaired"),
              )
            },
          )
        },
        icon=fn() { "refresh" },
        note=fn() { airplay_pair_status(d()) },
        end="chevron-right",
      )
    })
    ignore(on)
  })
}

///|
/// A chat as a grant names it: its title, or that it has none yet.
fn device_chat_title(r : Json?) -> String {
  let title = text(r, "title")
  if title == "" {
    @sf.t("web-pages.rigs.grant.untitled")
  } else {
    title
  }
}

///|
/// The heading of a device's chats in its panel: the panel's quiet words, a little over its rows.
fn device_using_words() -> @ui.TextStyle {
  @ui.text_style(size=Meta, leading=L5, color=Muted)
}

///|
fn device_using_at() -> @ui.Style {
  @ui.css("pt=S3 pb=S1")
}

///|
// kept across runs: a value (no field of it changes)
let airplay_block_pad : @ui.Style = @ui.css("pt=S2 pb=S1")

///|
// kept across runs: a value (no field of it changes)
let airplay_caps_at : @ui.Style = @ui.css("pb=S2")

///|
// kept across runs: a value (no field of it changes)
let airplay_form_column : @ui.Style = @ui.css("w=Full pt=S2 gap=S2")

///|
// kept across runs: a value (no field of it changes)
let airplay_step_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, weight=Medium, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let airplay_hint_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let airplay_error_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger, w=Full)
