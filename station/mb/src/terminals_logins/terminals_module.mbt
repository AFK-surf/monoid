// station/src/terminals/module.ts: the station's terminals as a part of it: their views on members' links (`terminal`
// requests), GET /terminals and ending one (POST /terminals/<id>/end), `terminals` on the event stream as they change.
// Each is a runner's (`term-<id>`), its meta beside it in <data>/run/terminals/<id>.json, so the station after this one
// (an update, a crash) takes them up as they are; a station that stops leaves them to it. A new one opens only on a
// station updated on the test channel (features.ts `stationFeature("terminal")`, #6853).

///|
/// A runner's id is a terminal's (agents/runner.ts `TERMINAL_RUNNER`).
pub const TERMINAL_RUNNER : String = "term-"

///|
pub fn is_terminal_runner(id : String) -> Bool {
  id.has_prefix(TERMINAL_RUNNER)
}

///|
/// The shell a terminal opens: the person's login shell, as a terminal app starts it.
pub fn shell_of(os : String, shell : String?) -> (String, Array[String]) {
  if os == "windows" {
    return ("powershell.exe", ["-NoLogo"])
  }
  let program = match shell {
    Some(s) if s != "" => s
    _ => "/bin/sh"
  }
  (program, ["-l"])
}

///|
/// The environment a terminal's shell is started with (module.ts `shellEnv`): `env` with what makes an interactive
/// login shell say its folder after each command (`OSC 7`) without touching the person's dotfiles: macOS's
/// /etc/zshrc reads /etc/zshrc_Apple_Terminal with `TERM_PROGRAM=Apple_Terminal` (its session files off), and bash runs
/// `PROMPT_COMMAND` where none is set.
pub fn shell_env(os : String, env : Map[String, String]) -> Map[String, String] {
  let out = env.copy()
  if os == "darwin" || os == "macos" {
    if !out.contains("TERM_PROGRAM") {
      out["TERM_PROGRAM"] = "Apple_Terminal"
    }
    if !out.contains("SHELL_SESSIONS_DISABLE") {
      out["SHELL_SESSIONS_DISABLE"] = "1"
    }
  }
  match out.get("PROMPT_COMMAND") {
    Some(p) if p != "" => ()
    _ => out["PROMPT_COMMAND"] = "printf '\\033]7;file://%s%s\\007' \"${HOSTNAME:-}\" \"$PWD\""
  }
  out
}

///|
/// What was kept of a terminal, read back (none where it is not one).
pub fn meta_of(v : J?) -> TerminalMeta? {
  guard v is Some(Obj(_) | Arr(_)) else { return None }
  match (text(get(v, "by")), num(get(v, "at")), text(get(v, "cwd")), text(get(v, "workspace"))) {
    (Some(by), Some(at), Some(cwd), Some(workspace)) => Some({ by, by_email: text(get(v, "byEmail")), at, cwd, chat: text(get(v, "chat")), workspace })
    _ => None
  }
}

///|
/// The station's `beta` feature `id` on a station updated on `channel` (features.ts `featureOnChannel`, with the
/// core's registry's spec: `stage`, `station`).
pub fn feature_on_channel(stage : String?, station : Bool, channel : String) -> Bool {
  stage == Some("beta") && station && channel == "beta"
}

///|
/// The channel a station is updated on (updates/versions.ts `channelFrom`): config.json's `updateChannel` where it
/// names one, else its release's (CHANNEL), else stable.
pub fn channel_from(raw : J?, release : String?) -> String {
  let id_of = (s : String) => {
    let t = @jscase.trim(s)
    if t == "stable" || t == "beta" {
      Some(t)
    } else {
      None
    }
  }
  match text(get(raw, "updateChannel")) {
    Some(s) if id_of(s) is Some(c) => c
    _ =>
      // (the release's channel as its CHANNEL said it, read already: `releaseChannel`)
      match release {
        Some(r) => r
        None => "stable"
      }
  }
}

///|
/// A runner as `liveRunners` lists it (agents/runner.ts RunnerInfo: what the terminals read of it).
pub(all) struct RunnerInfo {
  id : String
  pty : J?
  cols : J?
  rows : J?
}

///|
/// What the terminals ask of the station's other parts and of the machine.
pub(all) struct TerminalsIo {
  data : String
  home : String
  os : String
  /// `process.env.SHELL`.
  shell : String?
  /// The store's session: its `cwd ?? workspace`, if it is one.
  session_dir : (String) -> String?
  /// Eight random bytes in hex (`randomBytes(8).toString("hex")`).
  random_hex : () -> String
  /// `stationFeature("terminal", config.raw(), app)`.
  offered : () -> Bool
  /// events.tell("terminals", value, `terminals\0<workspace>`, {workspace}).
  tell : (String, J) -> Unit
  mkdir : async (String) -> Unit
  /// Written whole, mode 0600.
  write_file : async (String, String) -> Unit
  /// rm(path, {force: true}).
  remove : async (String) -> Unit
  read_file : async (String) -> String
  /// startRunner(data, id, program, args, the station's environment with `shell_env`'s hooks, cwd, {cols, rows}): the
  /// runner, started.
  start_runner : async (String, String, Array[String], String, Int, Int) -> RunnerInfo
  live_runners : async () -> Array[RunnerInfo]
  listening_soon : async (RunnerInfo) -> Bool
  /// runnerWire(info).
  wire : (RunnerInfo) -> Wire
  now : () -> Double
  spawn : (async () -> Unit) -> Unit
  log : (String, J) -> Unit
}

///|
pub struct TerminalsPart {
  terminals : Terminals
  priv io : TerminalsIo
}

///|
fn meta_dir(data : String) -> String {
  data + "/run/terminals"
}

///|
fn meta_file(data : String, id : String) -> String {
  meta_dir(data) + "/" + id + ".json"
}

///|
/// The part made: its terminals (told as they change), and those a station before this one opened taken up.
pub async fn TerminalsPart::start(io : TerminalsIo) -> TerminalsPart {
  let holder : Ref[Terminals?] = Ref(None)
  let tell = workspace => match holder.val {
    None => ()
    Some(t) => (io.tell)(workspace, jo([("terminals", t.list(workspace))]))
  }
  let terminals = Terminals::new({
    home: io.home,
    chat_dir: io.session_dir,
    new_id: () => TERMINAL_RUNNER + (io.random_hex)(),
    offered: Some(io.offered),
    changed: tell,
    meta: Some((id, meta) => (io.spawn)(async fn() {
      (io.write_file)(meta_file(io.data, id), stringify(meta.to_json())) catch {
        _ => ()
      }
    })),
    gone: id => (io.spawn)(async fn() { (io.remove)(meta_file(io.data, id)) catch { _ => () } }),
    start: async fn(id, o, cwd, meta) {
      (io.mkdir)(meta_dir(io.data))
      (io.write_file)(meta_file(io.data, id), stringify(meta.to_json()))
      let (program, args) = shell_of(io.os, io.shell)
      let info = (io.start_runner)(id, program, args, cwd, o.cols, o.rows)
      TerminalLink::new((io.wire)(info))
    },
    now: io.now,
    spawn: io.spawn,
    log: io.log,
  })
  holder.val = Some(terminals)
  // Those a station before this one opened: their runners, with what was kept of them.
  for info in (io.live_runners)() {
    if !is_terminal_runner(info.id) || !(info.pty is Some(Bool(true))) || !(io.listening_soon)(info) {
      continue
    }
    let kept = try parse((io.read_file)(meta_file(io.data, info.id))) catch { _ => J::Null }
    let meta = meta_of(Some(kept))
    guard meta is Some(m) else { continue }
    terminals.keep(info.id, TerminalLink::new((io.wire)(info)), m, (info.cols, info.rows))
    (io.log)("taken up", jo([("id", js(info.id))]))
  }
  { terminals, io }
}

///|
/// GET /terminals: the viewer's workspace's.
pub fn TerminalsPart::listed(self : TerminalsPart, workspace : String) -> (Int, String) {
  (200, stringify(jo([("terminals", self.terminals.list(workspace))])))
}

///|
/// POST /terminals/<raw>/end, by `viewer`.
pub fn TerminalsPart::end_asked(self : TerminalsPart, raw : String, viewer : Viewer) -> (Int, String) {
  if read_only(viewer.role) {
    return (403, stringify(jo([("error", js("a read-only member does not end a terminal"))])))
  }
  guard @api_routes.decode_uri_component(raw) is Some(id) else {
    return (404, stringify(jo([("error", js("no such terminal"))])))
  }
  let by = if viewer.name != "" { viewer.name } else { viewer.email }
  if self.terminals.end(id, by, viewer.workspace) {
    (200, "{}")
  } else {
    (404, stringify(jo([("error", js("no such terminal"))])))
  }
}

///|
/// The station stops: each runner keeps its terminal for the next one.
pub fn TerminalsPart::detach(self : TerminalsPart) -> Unit {
  ignore(self.io)
  self.terminals.detach()
}
