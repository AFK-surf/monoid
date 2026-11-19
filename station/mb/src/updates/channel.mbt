// channel.ts: `stillfail-station channel [stable|beta] [--app DIR] [--data DIR]`: the channel the station is updated
// on, set when one is named, then said on the last line. A station running there holds the config: it is asked
// (SIGHUP to the pid in run/station.json, the channel in run/channel-ask) and its answer waited for; with none running,
// the config is written here.

///|
/// Where `stillfail-station channel` asks the running station for an update channel, and where it answers.
pub let channel_ask : String = "channel-ask"

///|
pub let channel_answer : String = "channel-answer"

///|
/// The station's environment as these read it: STILLFAIL_CONFIG, its pid.
let env_config : Ref[String?] = Ref(None)

///|
let own_pid : Ref[Int] = Ref(0)

///|
pub fn set_process(config : String?, pid : Int) -> Unit {
  env_config.val = config
  own_pid.val = pid
}

///|
fn config_path(data : String) -> String {
  match env_config.val {
    Some(c) if c != "" => c
    _ => pjoin([data, "config.json"])
  }
}

///|
/// `writeWhole`: `text` written to `path` whole (a reader never sees half of it).
pub async fn write_whole(w : World, path : String, t : String) -> Unit {
  let tmp = "\{path}.tmp-\{own_pid.val}"
  w.write_file(tmp, t)
  w.rename(tmp, path)
}

///|
/// Whether `pid` is alive (`process.kill(pid, 0)`; EPERM: it is, another user's).
async fn alive(w : World, pid : Double) -> Bool {
  (try {
    ignore(w.call("process.kill", [jn(pid), ji(0)]))
    true
  } catch {
    e => field_of(e, "code") is Some(Str(u)) && @jsjson.sanitize_str(u) == "EPERM"
  })
}

///|
/// `setChannelIn`: sets the channel in the config (with no station running to ask). A config that is there but cannot
/// be read is not written over.
pub async fn set_channel_in(w : World, data : String, channel : String) -> Unit {
  ignore(w.call("ConfigFile.new", [js(data)]))
  let raw = w.call("ConfigFile.raw", [js(data)])
  ignore(w.call("ConfigFile.update", [js(data), set(raw, "updateChannel", js(channel))]))
}

///|
/// The JSON in `path`; none where it is not there or not JSON.
async fn read_json(w : World, path : String) -> J? {
  match w.read_text_or_null(path) {
    Some(t) => (try Some(parse(t)) catch { _ => None })
    None => None
  }
}

///|
/// `setChannel`: puts the station of `data` on `channel`: the running station asked when there is one that takes the
/// ask, else the config written here. Its refusal is raised with its words.
pub async fn set_channel(
  w : World,
  data : String,
  channel : String,
  wait_ms : Double,
  station? : async (Double) -> Bool,
) -> Unit {
  let station = match station {
    Some(s) => s
    None => async fn(pid) { w.call("platform.isLauncher", [jn(pid)]) is Bool(true) }
  }
  let run_dir = pjoin([data, "run"])
  w.mkdir(run_dir, opts=jo([("recursive", jb(true))]))
  let said = read_json(w, pjoin([run_dir, "station.json"]))
  let pid = match get(said, "pid") {
    Some(Num(p)) if is_safe_integer(Some(Num(p))) && p > 0.0 => Some(p)
    _ => None
  }
  let takes = match pid {
    None => false
    Some(p) => get(said, "channel") is Some(Num(1.0)) && alive(w, p) && station(p)
  }
  if !takes {
    return set_channel_in(w, data, channel)
  }
  let pid = pid.unwrap()
  // (the channel its config already says: nothing to ask)
  match get(read_json(w, config_path(data)), "updateChannel") {
    Some(Str(u)) if @jsjson.sanitize_str(u) == channel => return
    _ => ()
  }
  let answer = pjoin([run_dir, channel_answer])
  w.rm(answer)
  write_whole(w, pjoin([run_dir, channel_ask]), channel)
  // The launcher hears it (Unix's SIGHUP, a line on Windows' pipe) and tells the station's process.
  ignore(w.call("platform.askLauncher", [jn(pid), js("hup")])) catch {
    e => {
      w.rm(pjoin([run_dir, channel_ask]))
      raise fail(
        tr(station_lang(), "station.cli.signalFailed", args=jo([("pid", jn(pid)), ("error", js(message_of(e)))])),
      )
    }
  }
  match answer_in(w, answer, wait_ms) {
    Some(t) => {
      w.rm(answer)
      let t = trim(t)
      if starts_with(t, "ok") {
        return
      }
      raise fail(if starts_with(t, "error ") { slice(t, 6) } else { t })
    }
    None => ()
  }
  w.rm(pjoin([run_dir, channel_ask]))
  raise fail(tr(station_lang(), "station.cli.noAnswer"))
}

///|
/// The running station's answer in `path`, once it is there: looked at as its directory changes and every 100 ms
/// besides (a change can go unheard); none after `wait_ms`.
async fn answer_in(w : World, path : String, wait_ms : Double) -> String? {
  @effect.race_first(async fn() -> String? { (w.clock.sleep)(wait_ms); None }, async fn() -> String? {
    let changed : Ref[@effect.Deferred[Unit]] = Ref(@effect.Deferred::new())
    let base = pbasename(path)
    let close = (try
      Some(
        (w.watch)(pdirname(path), name => match name {
          Some(n) if n != base => ()
          _ => ignore(changed.val.succeed(()))
        }),
      ) catch {
      _ => None
    })
    let got : Result[String, Error] = try {
      while true {
        changed.val = @effect.Deferred::new()
        match w.read_text_or_null(path) {
          Some(t) => break Ok(t)
          None => ()
        }
        let woke = changed.val
        @effect.race_first(async fn() { (w.clock.sleep)(100.0) }, async fn() { woke.wait() })
      } nobreak {
        Err(fail(""))
      }
    } catch {
      e => Err(e)
    }
    match close {
      Some(c) => c()
      None => ()
    }
    match got {
      Ok(t) => Some(t)
      Err(e) => raise e
    }
  })
}

///|
/// `flag(args, name)`: the value after `name`.
pub fn flag(args : Array[String], name : String) -> String? {
  match args.search(name) {
    Some(at) if at + 1 < args.length() => Some(args[at + 1])
    _ => None
  }
}

///|
/// `channelCommand`: `args` as the station was given them. Says the channel on stdout; a refusal on stderr, exit code
/// 1; a usage error, exit code 2.
pub async fn channel_command(w : World, args : Array[String], data : String) -> Int {
  let app = flag(args, "--app")
  let valued = ["--app", "--data", "--port", "--handoff", "--node"]
  let positional = []
  for i, a in args {
    if !starts_with(a, "--") && !(i > 0 && valued.contains(args[i - 1])) {
      positional.push(a)
    }
  }
  let from = match positional.search("channel") {
    Some(i) => i + 1
    None => 0
  }
  let named = positional[from:].to_owned()
  if named.length() > 1 {
    return 2
  }
  (try {
    if named.length() == 1 {
      let channel = match channel_of_id(named[0]) {
        Some(c) => c
        None => raise fail(tr(station_lang(), "station.cli.badChannel", args=jo([("channel", js(named[0]))])))
      }
      set_channel(w, data, channel, 10000.0)
    }
    // (a config that is there but not JSON is refused, as before: only one that is not there is `{}`)
    let path = config_path(data)
    let t = (try Some(w.read_text(path)) catch {
      e =>
        if field_of(e, "code") is Some(Str(u)) && @jsjson.sanitize_str(u) == "ENOENT" {
          None
        } else {
          raise e
        }
    })
    let raw = match t {
      None => jo([])
      Some(t) => (try parse(t) catch { _ => raise invalid_json_file(path) })
    }
    // No --app: as the Rust command, the release is "" (a CHANNEL beside where it runs).
    w.now("console.log", [js(channel_of_soon(w, raw, app.unwrap_or("")))])
    0
  } catch {
    e => {
      w.now("console.error", [js("Error: \{message_of(e)}")])
      1
    }
  })
}

///|
/// ops/json-file.ts `InvalidJsonFile`.
fn invalid_json_file(path : String) -> Error {
  thrown(
    "InvalidJsonFile",
    tr(
      station_lang(),
      "station.files.invalidJson",
      args=jo([("path", js(path)), ("program", js(machine.val.exec_path))]),
    ),
  )
}
