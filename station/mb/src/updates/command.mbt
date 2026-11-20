// command.ts: `stillfail-station update [--beta|--stable] --app DIR [--data DIR]`, what `stillfail update` asks before
// it runs the installer: the channel set first when one is named, then the channel's latest release verified as the
// pages' update does it, and what to run said on stdout, a line each: `script=<the installer this release carries>`
// and the variables to give it. A delta the feed lists is taken here (applied in this process), and what it made
// handed on as STILLFAIL_ARCHIVE. A refusal on stderr, exit code 1; a usage error, exit code 2.
// `stillfail-station update --apply-delta --app DIR --delta FILE --out FILE`: the applier the running station starts
// apart from itself, the delta applied to the release in DIR and what it makes written to FILE.

///|
/// How long the delta may take, its download and applying (then the installer downloads the whole release).
pub let delta_ms : Double = 600000.0

///|
/// still.fail's own cloud (cloud/transport.ts CLOUD_ORIGIN).
pub let cloud_origin : String = "https://app.still.fail"

///|
/// `releaseBaseIn`: where the releases of the control plane the station is in are (cloud.json: its origin, and
/// Comma's under /stations); none before it joined one.
pub async fn release_base_in(w : World, data : String) -> String? {
  let file = pjoin([data, "mesh", "cloud.json"])
  let said = (try Some(read_json_file(w, file)) catch {
    e =>
      if field_of(e, "code") is Some(Str(u)) && @jsjson.sanitize_str(u) == "ENOENT" {
        None
      } else {
        raise e
      }
  })
  match get(said, "origin") {
    Some(Str(u)) if u.length() > 0 => {
      let origin = @jsjson.sanitize_str(u)
      // (`origin.replace(/\/+$/, "")`)
      let mut e = origin.length()
      while e > 0 && cu(origin, e - 1) == 47 {
        e -= 1
      }
      let trimmed = slice(origin, 0, end=e)
      if get(said, "provider") is Some(Str(p)) && @jsjson.sanitize_str(p) == "comma" {
        Some("\{trimmed}/stations")
      } else {
        Some(trimmed)
      }
    }
    _ => None
  }
}

///|
/// `readJsonFile(path)` (ops/json-file.ts): refused as InvalidJsonFile where it is not JSON.
pub async fn read_json_file(w : World, path : String) -> J {
  let t = w.read_text(path, sync=true)
  parse(t) catch {
    _ => raise invalid_json_file(path)
  }
}

///|
/// Applied here, in the command's own process.
fn apply_here(w : World, deflate : async (Bytes) -> Bytes) -> Applier {
  async fn(app, delta, out, _signal) { apply_file(w, Dir(app), delta, out, deflate) }
}

///|
/// `updateCommand`.
pub async fn update_command(
  w : World,
  args : Array[String],
  data : String,
  trusted : Array[(String, String)]?,
  deflate : async (Bytes) -> Bytes,
) -> Int {
  if args.contains("--apply-delta") {
    return apply_delta_command(w, args, deflate)
  }
  let app = flag(args, "--app")
  let asked = args.filter(a => a == "--beta" || a == "--stable")
  let positional = []
  for i, a in args {
    if !starts_with(a, "--") && !(i > 0 && ["--app", "--data"].contains(args[i - 1])) {
      positional.push(a)
    }
  }
  guard app is Some(app) && app != "" && asked.length() <= 1 && positional.length() == 1 else { return 2 }
  let lang = station_lang()
  let mut transport = false
  let code = (try {
    let base = match release_base_in(w, data) {
      Some(b) => b
      None => raise fail(tr(lang, "station.updates.notJoined"))
    }
    let named = match asked {
      ["--beta"] => Some("beta")
      ["--stable"] => Some("stable")
      _ => None
    }
    match named {
      Some(n) => set_channel(w, data, n, 10000.0)
      None => ()
    }
    let mut raw = jo([])
    if w.exists(config_path(data), sync=true) {
      raw = read_json_file(w, config_path(data))
    }
    ignore(w.call("CloudTransport.new", []))
    transport = true
    let request = request_by(w, if base == cloud_origin { "cloud.fetch" } else { "fetch" })
    let channel = channel_of(w, raw, app)
    let installed = release_channel(w, app).unwrap_or(channel)
    // (the feed read again after a failure on the way: this process runs once, on the machine's own time)
    let wall_sleep : Wait = async fn(ms) { w.tell("wall.sleep", [jn(ms)]) }
    let plan = plan_update(w, base, channel, app, installed, lang, trusted, request, wait=wall_sleep)
    // timer: a deadline of an outside request (the delta's download), past which the installer downloads the release.
    let handed = take_delta(w, plan, app, apply_here(w, deflate), Signal::new(), request, wait=wall_sleep)
    let env : Array[(String, String)] = []
    for p in plan.env + handed {
      match env.search_by(q => q.0 == p.0) {
        Some(i) => env[i] = p
        None => env.push(p)
      }
    }
    let lines = ["script=\{plan.script}"] + env.map(p => "\{p.0}=\{p.1}")
    if lines.iter().any(l => includes(l, "\r") || includes(l, "\n")) {
      raise fail("a line break in \{stringify(jstrs(lines))}")
    }
    w.now("console.log", [js(lines.join("\n"))])
    0
  } catch {
    e => {
      w.now("console.error", [js("Error: \{message_of(e)}")])
      1
    }
  })
  if transport {
    w.now("CloudTransport.close", [])
  }
  code
}

///|
/// `update --apply-delta`: the delta applied to the release in `--app`, what it makes written to `--out`.
async fn apply_delta_command(w : World, args : Array[String], deflate : async (Bytes) -> Bytes) -> Int {
  match (flag(args, "--app"), flag(args, "--delta"), flag(args, "--out")) {
    (Some(app), Some(delta), Some(out)) if app != "" && delta != "" && out != "" =>
      (try {
        apply_file(w, Dir(app), delta, out, deflate)
        0
      } catch {
        e => {
          w.now("console.error", [js("Error: \{message_of(e)}")])
          1
        }
      })
    _ => 2
  }
}
