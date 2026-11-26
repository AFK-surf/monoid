// The made-up workspace's devices (设备: the core's `devices` topic, devices.mbt) and the `device.*` calls changing
// them: 门口摄像头 on Willow (a whole station: every chat's), the viewer's; 开发板 on build-box (the viewer's station
// that only runs tasks), one chat using it and one asking; 陈's phone, lent to Willow. settings-stations-devices: the
// stations' list with them; place-stations-devices: the stations' place on a wide frame; settings-station-devices:
// Willow's page, its 设备 section.

///|
priv struct DevicesFixture {
  /// the ids taken off
  removed : Array[String]
  /// added since: (station, name, kind, target, model, protocols, paired)
  added : Array[(String, String, String, String, String, Array[String], Bool?)]
  /// 免批准 on the board
  mut open : Bool
  /// whether pyatv is installed in the fixture
  mut airplay_ready : Bool
  /// current AirPlay pairing step (1-based; 0 = idle)
  mut pair_step : Int
  /// protocols queued for the active AirPlay pairing session
  pair_protocols : Array[String]
  /// protocols paired so far in the active session
  paired_protocols : Array[String]
}

///|
let fx_devices : DevicesFixture = {
  removed: [],
  added: [],
  open: false,
  airplay_ready: true,
  pair_step: 0,
  pair_protocols: [],
  paired_protocols: [],
}

///|
/// Whether the fixture's `mode` is one with the made-up devices in it.
fn devices_fixture_mode(mode : String) -> Bool {
  mode.has_suffix("-devices") || mode.has_prefix("settings-station-tasks")
}

///|
/// As a run starts.
fn devices_fixture_reset() -> Unit {
  fx_devices.removed.clear()
  fx_devices.added.clear()
  fx_devices.open = false
  fx_devices.airplay_ready = true
  fx_devices.pair_step = 0
  fx_devices.pair_protocols.clear()
  fx_devices.paired_protocols.clear()
}

///|
fn fx_device(
  id : String,
  name : String,
  kind : String,
  target : String,
  via : String,
  station : String,
  station_name : String,
  mine : Bool,
  owner : (String, String),
  open : Bool,
  grants : Array[Json],
  requests : Array[Json],
  baud? : Int = 0,
  model? : String = "",
  protocols? : Array[String] = [],
  paired? : Bool,
) -> Json {
  let out : Array[(String, Json)] = [
    ("id", str(id)),
    ("name", str(name)),
    ("kind", str(kind)),
    ("target", str(target)),
    ("via", str(via)),
    ("station", str(station)),
    ("stationName", str(station_name)),
    ("owner", str(owner.0)),
    ("ownerEmail", str(owner.0)),
    ("ownerName", str(owner.1)),
    ("mine", Json::boolean(mine)),
    ("online", Json::boolean(true)),
    ("open", Json::boolean(open)),
    ("ownOpen", Json::boolean(via == "rig" && open)),
    ("grants", Json::array(grants)),
    ("requests", Json::array(requests)),
  ]
  if baud > 0 {
    out.push(("baud", Json::number(baud.to_double())))
  }
  if model != "" {
    out.push(("model", str(model)))
  }
  if protocols.length() > 0 {
    out.push(("protocols", Json::array(protocols.map(str))))
  }
  match paired {
    Some(b) => out.push(("paired", Json::boolean(b)))
    None => ()
  }
  obj(out)
}

///|
/// The `devices` topic of the made-up workspace.
fn devices_fixture_topic() -> Json {
  let lin = ("lin@example.com", "林")
  let all : Array[Json] = [
    fx_device("0a1b2c3d4e5f6071", "门口摄像头", "tcp", "192.168.1.20:554", "station", "st1", "Willow", true, lin, true, [], []),
    fx_device(
      "3d4e5f60718293a4",
      "客厅 Apple TV",
      "airplay",
      "AA:BB:CC:DD:EE:FF",
      "station",
      "st1",
      "Willow",
      true,
      lin,
      true,
      [],
      [],
      model="Apple TV 4K (3rd gen)",
      protocols=["airplay", "companion", "raop"],
      paired=true,
    ),
    fx_device(
      "1b2c3d4e5f607182",
      "开发板",
      "serial",
      "/dev/ttyUSB0",
      "rig",
      "aa11",
      "build-box",
      true,
      lin,
      fx_devices.open,
      [
        obj([
          ("request", str("r-12")),
          ("station", str("st1")),
          ("stationName", str("Willow")),
          ("session", str("s-c1")),
          ("chat", str("CHAT/1")),
          ("title", str("刷新固件")),
          ("by", str("zhou@example.com")),
          ("timeoutKind", str("idle")),
          ("timeoutSeconds", Json::number(3600.0)),
          ("exp", Json::number(2.0e9)),
          ("until", Json::number(1.9e9)),
          ("whole", Json::boolean(false)),
        ]),
      ],
      [],
      baud=9600,
    ),
    fx_device("2c3d4e5f60718293", "陈 的 Pixel 8", "adb", "192.168.1.31:5555", "phone", "st1", "Willow", false, ("chen@example.com", "陈"), false, [], []),
  ]
  for i, a in fx_devices.added {
    all.push(fx_device("ff" + i.to_string(), a.1, a.2, a.3, "station", a.0, "Willow", true, lin, true, [], [], model=a.4, protocols=a.5, paired?=a.6))
  }
  obj([("app", Json::boolean(true)), ("devices", Json::array(all.filter(fn(d) { !fx_devices.removed.contains(text(Some(d), "id")) })))])
}

///|
/// A `device.*` call answered, the made-up devices changed as the core would say them next; None: not one of them.
fn devices_fixture_call(name : String, p : Json?) -> Result[Json, Json]? {
  match name {
    "device.add" => {
      let paired : Bool? = match field(p, "paired") {
        Some(True) => Some(true)
        Some(False) => Some(false)
        _ => None
      }
      fx_devices.added.push((text(p, "station"), text(p, "name"), text(p, "kind"), text(p, "target"), text(p, "model"), json_strings(field(p, "protocols")), paired))
      fx_changed()
      Some(Ok(obj([])))
    }
    "device.remove" => {
      fx_devices.removed.push(text(p, "device"))
      fx_changed()
      Some(Ok(obj([])))
    }
    "device.setOpen" => {
      fx_devices.open = flag(p, "open")
      fx_changed()
      Some(Ok(obj([])))
    }
    "device.scan" => {
      let cands : Array[Json] = if fx_devices.airplay_ready {
        [
          obj([
            ("identifier", str("11:22:33:44:55:66")),
            ("name", str("卧室 Apple TV")),
            ("address", str("192.168.1.51")),
            ("model", str("Apple TV 4K (2nd gen)")),
            (
              "protocols",
              Json::array([
                obj([("protocol", str("airplay")), ("pairing", str("mandatory"))]),
                obj([("protocol", str("companion")), ("pairing", str("mandatory"))]),
              ]),
            ),
            ("alreadyAdded", Json::boolean(false)),
          ]),
          obj([
            ("identifier", str("22:33:44:55:66:77")),
            ("name", str("书房 HomePod")),
            ("address", str("192.168.1.52")),
            ("model", str("HomePod mini")),
            (
              "protocols",
              Json::array([
                obj([("protocol", str("airplay")), ("pairing", str("not_needed"))]),
                obj([("protocol", str("raop")), ("pairing", str("not_needed"))]),
              ]),
            ),
            ("alreadyAdded", Json::boolean(false)),
          ]),
        ]
      } else {
        []
      }
      Some(
        Ok(
          obj([
            ("candidates", Json::array(cands)),
            (
              "env",
              obj([
                ("ready", Json::boolean(fx_devices.airplay_ready)),
                ("python", str("/usr/bin/python3")),
                ("pyatvVersion", str("0.16.1")),
              ]),
            ),
          ]),
        ),
      )
    }
    "device.installAirplay" => {
      fx_devices.airplay_ready = true
      Some(Ok(obj([("ok", Json::boolean(true)), ("pyatvVersion", str("0.16.1")), ("python", str("/usr/bin/python3"))])))
    }
    "device.pairStart" => {
      fx_devices.pair_protocols.clear()
      fx_devices.paired_protocols.clear()
      fx_devices.pair_protocols.push("airplay")
      fx_devices.pair_protocols.push("companion")
      fx_devices.pair_step = 1
      Some(
        Ok(
          obj([
            ("pairId", str("pair-1")),
            ("done", Json::boolean(false)),
            ("step", Json::number(1.0)),
            ("total", Json::number(2.0)),
            ("protocol", str("airplay")),
            ("deviceProvidesPin", Json::boolean(true)),
            ("pairedProtocols", Json::array([])),
          ]),
        ),
      )
    }
    "device.pairFinish" => {
      let pair_id = text(p, "pairId")
      let skip = flag(p, "skip")
      let pin = text(p, "pin")
      if !skip && pin == "0000" {
        return Some(Err(obj([("code", str("invalid_pin")), ("message", str("配对码不正确"))])))
      }
      if fx_devices.pair_step >= 1 && fx_devices.pair_step <= fx_devices.pair_protocols.length() {
        if !skip {
          fx_devices.paired_protocols.push(fx_devices.pair_protocols[fx_devices.pair_step - 1])
        }
        fx_devices.pair_step = fx_devices.pair_step + 1
      }
      if fx_devices.pair_step > fx_devices.pair_protocols.length() {
        Some(
          Ok(
            obj([
              ("pairId", str(pair_id)),
              ("done", Json::boolean(true)),
              ("protocols", Json::array(fx_devices.pair_protocols.map(str))),
              ("pairedProtocols", Json::array(fx_devices.paired_protocols.map(str))),
            ]),
          ),
        )
      } else {
        let next_proto = fx_devices.pair_protocols[fx_devices.pair_step - 1]
        Some(
          Ok(
            obj([
              ("pairId", str(pair_id)),
              ("done", Json::boolean(false)),
              ("step", Json::number(fx_devices.pair_step.to_double())),
              ("total", Json::number(fx_devices.pair_protocols.length().to_double())),
              ("protocol", str(next_proto)),
              ("deviceProvidesPin", Json::boolean(true)),
              ("pairedProtocols", Json::array(fx_devices.paired_protocols.map(str))),
            ]),
          ),
        )
      }
    }
    "device.pairCancel" => {
      fx_devices.pair_step = 0
      Some(Ok(obj([("ok", Json::boolean(true))])))
    }
    "device.rebindPair" => {
      fx_changed()
      Some(Ok(obj([("device", str(text(p, "device")))])))
    }
    _ => None
  }
}
