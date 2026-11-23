// What of the station's background jobs is the machine's (station/src/jobs/jobs.ts `Jobs`), which the sessions'
// program (station/mb src/reader/jobs.mbt, the pseudo-actor `#jobs`) asks for: a job's command started in a process
// group of its own under a shell that writes its exit code aside and moves it into place when it ends (`WRAPPER`),
// followed to its end (its exit file appearing, or its leader gone: looked at once a second), a signal sent to its
// group, a stop's grace, its log read and held to its bound, the claims on the screen written down for the next
// station, and the files of jobs long over collected. Jobs outlive the station: their own groups and exit files are
// what lets the next one take them up.

///|
pub let job_logs_kept_ms : Double = 14.0 * 24.0 * 3600_000.0

///|
pub let job_files_orphan_ms : Double = 3600_000.0

///|
pub let collect_yield_every : Int = 32

///|
pub let collect_batch_size : Int = 500

///|
pub let log_lines : Int = 50

///|
pub let notices_shown : Int = 20

///|
pub let awake_ms : Double = 300_000.0

///|
pub let stop_grace_ms : Int = 5000

///|
pub let stop_settle_ms : Int = 3000

///|
pub let stop_look_ms : Int = 100

///|
pub let follow_look_ms : Int = 1000

///|
pub let notify_body_limit : Int = 64 * 1024

///|
pub let job_log_cap : Double = 64.0 * 1048576.0

///|
let log_bytes : Int = 64 * 1024

///|
/// How a job's command runs: under a shell that writes its exit code to a file when it ends, aside and moved into
/// place, so a watch on jobs/exit never reads it half written.
pub let wrapper : String = "/bin/sh -c \"$1\"; code=$?; printf '%s' \"$code\" > \"$2.tmp\" && mv -f \"$2.tmp\" \"$2\"; exit \"$code\""

///|
pub let job_command_name : String = "stillfail-job"

///|
/// What `stillfail-job` is, in each job's PATH (jobs.ts `JOB_COMMAND`).
pub let job_command : String =
  #|#!/bin/sh
  #|# stillfail-job notify <words>: tells the agent that started this job (the words, or stdin's).
  #|# stillfail-job screen <command>...: runs the command with this machine's screen (windows, a simulator, screenshots),
  #|# one task's at a time: it waits while another task has it, and gives it back when the command ends. For work done in
  #|# minutes; a window kept up for a person is show's.
  #|# stillfail-job show <command>...: puts up a window for a person (a virtual machine, a simulator to look at) and leaves
  #|# it: waits for the screen to be free, then runs the command holding nothing.
  #|token=${STILLFAIL_JOB_TOKEN:-}
  #|notify=${STILLFAIL_JOB_NOTIFY:-}
  #|case "$1" in
  #|  notify)
  #|    shift
  #|    if [ "$#" -gt 0 ]; then printf '%s' "$*"; else cat; fi |
  #|      curl -fsS -X POST -H "Authorization: Bearer $token" -H "content-type: text/plain; charset=utf-8" --data-binary @- "$notify" >/dev/null
  #|    ;;
  #|  screen|show)
  #|    how=$1
  #|    shift
  #|    [ "$#" -gt 0 ] || { echo "usage: stillfail-job $how <command>..." >&2; exit 2; }
  #|    screen=${STILLFAIL_JOB_SCREEN:-}
  #|    [ -n "$screen" ] || exec "$@"
  #|    # (the process the station looks at: under Git's sh on Windows, Windows' own)
  #|    pid=$$
  #|    [ -r /proc/$$/winpid ] && pid=$(cat /proc/$$/winpid)
  #|    ask() { curl -sS -X POST -H "Authorization: Bearer $token" --data-binary "$1 $pid" "$screen" 2>&1; }
  #|    told=0 unheard=0
  #|    while :; do
  #|      said=$(ask take)
  #|      case "$said" in
  #|        *'"yours"'*) break ;;
  #|        *'"waiting"'*)
  #|          unheard=0
  #|          # (who has it: said once, and again when it is someone else)
  #|          who=$(printf '%s' "$said" | sed -n 's/.*"who":"\([^"]*\)".*/\1/p')
  #|          if [ "$told" != 1 ] || [ "$who" != "$was" ]; then
  #|            echo "stillfail-job $how: waiting for the screen (${who:-another task has it})" >&2
  #|          fi
  #|          told=1 was=$who ;;
  #|        *'"error"'*) echo "stillfail-job screen: $said" >&2; exit 1 ;;
  #|        *)
  #|          # (the station not answering: restarting, or gone)
  #|          unheard=$((unheard + 1))
  #|          if [ "$unheard" -ge 60 ]; then
  #|            echo "stillfail-job screen: the station has not answered for a minute; running it without waiting for the screen" >&2
  #|            break
  #|          fi ;;
  #|      esac
  #|      sleep 1
  #|    done
  #|    give() { ask give >/dev/null; }
  #|    # (show: the screen free, the window put up holding nothing)
  #|    if [ "$how" = show ]; then give; exec "$@"; fi
  #|    trap 'give; exit 129' HUP
  #|    trap 'give; exit 130' INT
  #|    trap 'give; exit 143' TERM
  #|    "$@"
  #|    code=$?
  #|    give
  #|    exit "$code"
  #|    ;;
  #|  *) echo "usage: stillfail-job notify <words> | stillfail-job screen <command>... | stillfail-job show <command>..." >&2; exit 2 ;;
  #|esac
  #|

///|
/// A job's record as serde writes it (jobs.ts `jobJson`): the token left out, `sessionKey` as `session`, `queued`,
/// `screen` and `small` said only when so.
pub fn job_json(j : Json) -> Json {
  let m : Map[String, Json] = Map([])
  let put_field = (to : String, from_key : String) => m[to] = field_or_null(j, from_key)
  put_field("id", "id")
  put_field("session", "sessionKey")
  for k in [
    "name", "command", "cwd", "port", "state", "pgid", "exitCode", "startedAt", "endedAt", "restarts",
    "log", "watch",
  ] {
    put_field(k, k)
  }
  for k in ["queued", "screen", "small"] {
    if field(j, k) is Some(True) {
      m[k] = jbool(true)
    }
  }
  Json::object(m)
}

///|
/// Whether a job is the queue's: another station's task (remote.ts names them `remote_…`).
pub fn queues(id : String) -> Bool {
  starts(id, "remote_")
}

///|
/// How a job is named to its agent.
pub fn job_named(id : String, name : String, port : Double?) -> String {
  match port {
    Some(p) => "Service \"\{name}\" (\{id}, port \{js_number(p)})"
    None => "Job \"\{name}\" (\{id})"
  }
}

///|
/// What a job a chat had running on a station retired is told as, started again (or not) as the chat moved
/// (jobs.ts `movedSaid`).
pub fn moved_said(why : String, id : String?, name : String, port : Double?, error : String?) -> String {
  let what = match id {
    Some(i) if i != "" => job_named(i, name, port)
    _ =>
      match port {
        Some(p) => "Service \"\{name}\" (port \{js_number(p)})"
        None => "Job \"\{name}\""
      }
  }
  match error {
    None => "\{why}; \{what} was started again."
    Some(e) => "\{why}; \{what} could not be started again: \{e}"
  }
}

///|
/// The name a job is shown by (jobs.ts `made`): its own, trimmed and cut to 60 code points, else its command's first
/// word, else "job".
pub fn shown_name(name : String, command : String) -> String {
  let n = trim(name)
  if n == "" {
    let words = @jscase.split_by(trim(command), @jscase.is_space)
    let first = if words.length() > 0 { words[0] } else { "" }
    return if first == "" { "job" } else { first }
  }
  let points = n.to_array()
  if points.length() > 60 {
    String::from_array(points[0:60].to_array())
  } else {
    n
  }
}

///|
/// The exit code a job's shell wrote (`/^[+-]?\d+$/` of it trimmed), if it did.
pub fn exit_code_of(t : String) -> Double? {
  let s = trim(t)
  let digits = if starts(s, "+") || starts(s, "-") { from(s, 1) } else { s }
  if !all_digits(digits) {
    return None
  }
  let n = digits_number(digits)
  Some(if starts(s, "-") { -n } else { n })
}

///|
/// The claims an earlier station left holding the screen, from what it wrote of them (jobs.ts `heldClaims`).
pub fn held_claims(t : String?) -> Json {
  guard t is Some(text) else { return Json::array([]) }
  let kept = @json.parse(text) catch { _ => return Json::array([]) }
  guard kept is Array(claims) else { return Json::array([]) }
  let out = []
  for c in claims {
    match (field(c, "job"), field(c, "pid"), field(c, "at")) {
      (Some(String(job)), Some(Number(pid, ..)), Some(Number(at, ..))) if pid == pid.floor() => {
        let m : Map[String, Json] = {
          "job": jstr(job),
          "pid": jnum(pid),
          "at": jnum(at),
          "held": jbool(true),
        }
        match field(c, "since") {
          Some(Number(s, ..)) => m["since"] = jnum(s)
          _ => ()
        }
        out.push(Json::object(m))
      }
      _ => ()
    }
  }
  Json::array(out)
}

///|
/// The id a file in jobs/logs (`.log`, `.log.1`, `.log.1.tmp`) or jobs/exit (`.lost`, `.tmp`) is of (jobs.ts
/// `collect`'s `idOf`).
pub fn job_file_id(name : String, sub : String) -> String? {
  let rests = if sub == "logs" { [".log", ".log.1", ".log.1.tmp"] } else { ["", ".lost", ".tmp"] }
  for i in 1..=name.length() {
    if rests.contains(from(name, i)) {
      return Some(slice(name, 0, i))
    }
  }
  None
}

///|
/// The words of a POST /jobs/notify or /jobs/screen: the bearer's token.
fn bearer(authorization : String?) -> String {
  match authorization {
    Some(a) if starts(a, "Bearer ") => from(a, 7)
    _ => ""
  }
}

///|
/// POST /jobs/notify (jobs.ts `notifyEndpoint`): a job's `stillfail-job notify`, its token as the bearer, its words
/// as the body (at most 64 KiB). {status, body}.
pub async fn notify_endpoint(
  authorization : String?,
  body : Bytes,
  notified : async (String, String) -> Unit,
) -> (Int, Json) {
  if body.length() > notify_body_limit {
    return (400, obj([("error", jstr("length limit exceeded"))]))
  }
  notified(bearer(authorization), @utf8.decode_lossy(body)) catch {
    e => return (400, obj([("error", jstr(words_of(e)))]))
  }
  (200, obj([("ok", jbool(true))]))
}

///|
/// POST /jobs/screen (jobs.ts `screenEndpoint`): `take <pid>` or `give <pid>` from the job with this token.
pub async fn screen_endpoint(
  authorization : String?,
  body : Bytes,
  asked : async (String, String, Double) -> Json,
) -> (Int, Json) {
  let t = @utf8.decode_lossy(body)
  // /^(take|give) ([0-9]{1,10})\s*$/
  let parsed = if starts(t, "take ") || starts(t, "give ") {
    let rest = from(t, 5)
    let mut i = 0
    while i < rest.length() && is_digit(rest.unsafe_charcode_at(i)) {
      i += 1
    }
    let digits = slice(rest, 0, i)
    let tail = from(rest, i)
    let mut blank = true
    for k in 0..<tail.length() {
      if !@jscase.is_space(tail.unsafe_charcode_at(k)) {
        blank = false
      }
    }
    if digits.length() >= 1 && digits.length() <= 10 && blank {
      Some((slice(t, 0, 4), digits_number(digits)))
    } else {
      None
    }
  } else {
    None
  }
  guard parsed is Some((what, pid)) else {
    return (400, obj([("error", jstr("take <pid> or give <pid>"))]))
  }
  let said = asked(bearer(authorization), what, pid) catch {
    e => return (400, obj([("error", jstr(words_of(e)))]))
  }
  (200, said)
}

///|
/// str::lines: split at \n (a \r before it goes too); no last empty line.
pub fn rust_lines(t : String) -> Array[String] {
  if t == "" {
    return []
  }
  let parts = split(t, "\n")
  let ended = parts[parts.length() - 1] == ""
  if ended {
    ignore(parts.pop())
  }
  let n = parts.length()
  parts.mapi((i, l) => if (i < n - 1 || ended) && ends(l, "\r") { slice(l, 0, l.length() - 1) } else { l })
}

///|
async fn tail_lines(host : @host.Host, path : String) -> Array[String] {
  match try_ask(host, "fs.tail", { "path": jstr(path), "bytes": jint(log_bytes) }) {
    Some(String(t)) => rust_lines(t)
    _ => []
  }
}

///|
/// The last `lines` lines of a log (read/jobs.ts `tail`), read on into what it kept of before (`<log>.1`) where it
/// was cut since with fewer.
pub async fn tail(host : @host.Host, path : String, lines : Int) -> String {
  let now = tail_lines(host, path)
  if now.length() >= lines {
    return join(now[now.length() - lines:].to_array(), "\n")
  }
  let before = tail_lines(host, path + ".1")
  let all = before + now
  let start = if all.length() > lines { all.length() - lines } else { 0 }
  join(all[start:].to_array(), "\n")
}

///|
/// When a log's output last grew (ms); None where it is empty or not there.
pub async fn output_at(host : @host.Host, path : String) -> Double? {
  match try_ask(host, "fs.meta", { "path": jstr(path) }) {
    Some(Object(_) as m) =>
      match (num(field(m, "size")), num(field(m, "mtimeMs"))) {
        (Some(s), Some(t)) if s > 0.0 => Some(t)
        _ => None
      }
    _ => None
  }
}

///|
/// A log other processes append to, cut where it is once past `cap` (ops/storage.ts `rotateInPlace`): its last `keep`
/// bytes copied to `<path>.1` (through `<path>.1.tmp`), then the file truncated to nothing, its inode the same.
pub async fn rotate_in_place(host : @host.Host, path : String, cap : Double, keep? : Double) -> Bool raise {
  let keep = keep.unwrap_or(cap)
  match ask(host, "fs.rotate", { "path": jstr(path), "cap": jnum(cap), "keep": jnum(keep) }) {
    True => true
    _ => false
  }
}

///|
/// The machine's processes as a job's shell asks them: a group's signal, whether a process or a group is there, when
/// a process started.
pub(all) struct Processes {
  signal_group : async (Int, String) -> Unit
  group_alive : async (Int) -> Bool
  pid_alive : async (Int) -> Bool
  start_time : async (Int) -> Double?
}

///|
/// The machine's own, through `kill` and `ps`; a process's start by `wall` (ms since the epoch; the system's wall clock
/// where none is given).
pub fn Processes::shell(host : @host.Host, wall? : () -> Double) -> Processes {
  let wall = wall.unwrap_or(() => @host.wall_ms().to_double())
  {
    signal_group: async fn(pgid, signal) {
      let sig = if starts(signal, "SIG") { from(signal, 3) } else { signal }
      ignore(run_code(host, "/bin/kill", ["-s", sig, "--", "-\{pgid}"]))
    },
    group_alive: async fn(pgid) {
      run_code(host, "/bin/kill", ["-0", "--", "-\{pgid}"]) is Some((0, _))
    },
    pid_alive: async fn(pid) {
      // (kill -0's EPERM is a process there too: its words say it)
      match run_code(host, "/bin/sh", ["-c", "kill -0 \"$0\" 2>&1", pid.to_string()]) {
        Some((0, _)) => true
        Some((_, out)) => index_ci(out, "not permitted") >= 0
        None => false
      }
    },
    start_time: async fn(pid) {
      guard run_program(host, "ps", ["-o", "etime=", "-p", pid.to_string()]) is Some(out) else {
        return None
      }
      let t = trim(out)
      if t == "" {
        return None
      }
      let (days, rest) = match t.find("-") {
        Some(i) => {
          guard all_digits(slice(t, 0, i)) else { return None }
          (digits_number(slice(t, 0, i)), from(t, i + 1))
        }
        None => (0.0, t)
      }
      let parts = split(rest, ":")
      if !parts.iter().all(all_digits) {
        return None
      }
      let p = parts.map(digits_number)
      let seconds = match p.length() {
        3 => p[0] * 3600.0 + p[1] * 60.0 + p[2]
        2 => p[0] * 60.0 + p[1]
        _ => return None
      }
      Some(wall() - (seconds + days * 86400.0) * 1000.0)
    },
  }
}

///|
/// A job's command as it runs, until its end is taken in.
priv struct Running {
  pgid : Int
  gone : @effect.Deferred[Unit]
  settled : @effect.Deferred[Unit]
}

///|
/// A job's record as the machine needs it to start one.
pub(all) struct JobStart {
  id : String
  name : String
  command : String
  cwd : String
  port : Double?
  token : String
  log : String
  session : String
}

///|
pub fn JobStart::from_json(j : Json) -> JobStart {
  {
    id: text(j, "id"),
    name: text(j, "name"),
    command: text(j, "command"),
    cwd: text(j, "cwd"),
    port: num(field(j, "port")),
    token: text(j, "token"),
    log: text(j, "log"),
    session: text(j, "sessionKey"),
  }
}

///|
/// The machine's side of the station's jobs, in `data`/jobs (logs/, bin/, exit/).
pub struct JobsHost {
  priv host : @host.Host
  priv rt : @effect.Runtime
  dir : String
  priv procs : Processes
  priv running : Map[String, Running]
  priv mut notify_url : String
  priv mut closing : Bool
  /// What a job's end is told to (the program's `exited`: its id, its group, its code, how long it ran).
  priv mut ended : async (String, Int, Double?, Double) -> Unit
  priv now : () -> Double
}

///|
/// Its directories made and `stillfail-job` put in its bin/.
pub async fn JobsHost::new(
  host : @host.Host,
  data : String,
  procs? : Processes,
  now? : () -> Double,
) -> JobsHost raise {
  let dir = pjoin([data, "jobs"])
  for sub in ["logs", "bin", "exit"] {
    mkdirs(host, pjoin([dir, sub]))
  }
  let script = pjoin([dir, "bin", job_command_name])
  write_text(host, script, job_command)
  ignore(ask(host, "fs.chmod", { "path": jstr(script), "mode": jint(0o755) }))
  {
    host,
    rt: host.rt,
    dir,
    procs: procs.unwrap_or(Processes::shell(host)),
    running: Map([]),
    notify_url: "",
    closing: false,
    ended: async fn(_, _, _, _) {  },
    now: now.unwrap_or(() => @host.epoch_ms().to_double()),
  }
}

///|
/// Where `stillfail-job notify` posts, once the endpoint listens.
pub fn JobsHost::set_notify_url(self : JobsHost, url : String) -> Unit {
  self.notify_url = url
}

///|
/// What a job's end is told to.
pub fn JobsHost::on_ended(self : JobsHost, f : async (String, Int, Double?, Double) -> Unit) -> Unit {
  self.ended = f
}

///|
pub fn JobsHost::exit_file(self : JobsHost, id : String) -> String {
  pjoin([self.dir, "exit", id])
}

///|
pub fn JobsHost::lost_file(self : JobsHost, id : String) -> String {
  pjoin([self.dir, "exit", id + ".lost"])
}

///|
/// The exit code a job's shell wrote when it ended, if it did.
pub async fn JobsHost::read_exit(self : JobsHost, id : String) -> Double? {
  read_text(self.host, self.exit_file(id)).bind(exit_code_of)
}

///|
/// The claims an earlier station left holding the screen.
pub async fn JobsHost::held_claims(self : JobsHost) -> Json {
  held_claims(read_text(self.host, pjoin([self.dir, "screen.json"])))
}

///|
/// The claims that hold the screen, written down for the next station (in place: a reader never sees half of it).
pub async fn JobsHost::keep_claims(self : JobsHost, held : Json) -> Unit {
  write_text(self.host, pjoin([self.dir, "screen.json"]), held.stringify() + "\n") catch {
    _ => ()
  }
}

///|
/// A word for sh, as it is.
fn sh_quoted(word : String) -> String {
  "'" + join(split(word, "'"), "'\\''") + "'"
}

///|
/// The variables a job runs with besides the station's (jobs.ts `spawn`).
pub fn JobsHost::job_env(self : JobsHost, job : JobStart, extra : Map[String, String], path : String) -> Map[String, String] {
  let env : Map[String, String] = Map([])
  let bin = pjoin([self.dir, "bin"])
  env["PATH"] = if path == "" { bin } else { bin + ":" + path }
  for k, v in extra {
    env[k] = v
  }
  env["STILLFAIL_JOB_ID"] = job.id
  env["STILLFAIL_JOB_TOKEN"] = job.token
  env["STILLFAIL_JOB_NOTIFY"] = self.notify_url
  if self.notify_url != "" {
    env["STILLFAIL_PEER_HTTP"] = if ends(self.notify_url, "/jobs/notify") {
      slice(self.notify_url, 0, self.notify_url.length() - 12) + "/peer"
    } else {
      self.notify_url
    }
    env["STILLFAIL_JOB_SCREEN"] = if ends(self.notify_url, "/notify") {
      slice(self.notify_url, 0, self.notify_url.length() - 7) + "/screen"
    } else {
      self.notify_url
    }
  }
  match job.port {
    Some(p) => env["PORT"] = js_number(p)
    None => ()
  }
  env
}

///|
/// The `/bin/sh -c` script that starts a job (`$0` its inner script, then its directory, command, exit file and log):
/// in a group of its own (setsid where the system has it, else perl's setpgrp; its pid its group's), `nice` lower than
/// the station, and never with the launcher's front, which `proc.run` passes on from the station's own environment
/// (a job that found it would bind its own key on the station's endpoint).
fn spawn_script(nice : Int) -> String {
  "unset STILLFAIL_MESH_FRONT; cd \"$1\" || exit 1; shift; set -f; " +
  "if command -v setsid >/dev/null 2>&1; then g='setsid'; else g='perl -e setpgrp(0,0);exec{$ARGV[0]}@ARGV --'; fi; " +
  "n=''; if [ \{nice} -gt 0 ] && [ -x /usr/bin/nice ]; then n='/usr/bin/nice -n \{nice}'; fi; " +
  "$g $n /bin/sh -c \"$0\" \{sh_quoted(job_command_name)} \"$@\" </dev/null >/dev/null 2>&1 & echo $!"
}

///|
/// Runs a job's command in a group of its own, its output appended to its log by its shell, lower than the station
/// (nice), and follows it to its end: its group's id.
pub async fn JobsHost::spawn(
  self : JobsHost,
  job : JobStart,
  extra? : Map[String, String] = {},
  nice? : Int = 10,
) -> Int raise {
  // Made (or found) here, so a log that cannot be written is said now.
  ignore(put(self.host, job.log, b""))
  let exit = self.exit_file(job.id)
  remove(self.host, exit)
  remove(self.host, exit + ".tmp")
  remove(self.host, self.lost_file(job.id))
  let env = self.job_env(job, extra, @env.get_env_var("PATH").unwrap_or(""))
  let inner = "exec >>\"$3\" 2>&1; \{wrapper}"
  let start = spawn_script(nice)
  let e : Map[String, Json] = Map([])
  for k, v in env {
    e[k] = jstr(v)
  }
  let said = ask(self.host, "proc.run", {
    "command": jstr("/bin/sh"),
    "args": Json::array([jstr("-c"), jstr(start), jstr(inner), jstr(job.cwd), jstr(job.command), jstr(exit), jstr(job.log)]),
    "env": Json::object(e),
    "timeoutMs": jint(10_000),
  })
  let pid = match said {
    String(s) if all_digits(trim(s)) => digits_number(trim(s)).to_int()
    _ => raise HostError("the job ended before it started")
  }
  self.follow(job.id, pid, (self.now)())
  pid
}

///|
/// Follows a job to its end: its exit file there, or its leader gone (looked at once a second: an end that writes no
/// file has no event). `began`: when it started, what its time ran is counted from.
pub fn JobsHost::follow(self : JobsHost, id : String, pgid : Int, began : Double) -> Unit {
  let running = { pgid, gone: @effect.Deferred::new(), settled: @effect.Deferred::new() }
  self.running[id] = running
  // (a follower that failed lets its job go from `running` as an end would, so nothing waits on it for ever)
  let failed = (e : Error) => {
    @host.note("job \{id} no longer followed: \{e}")
    ignore(running.gone.succeed(()))
    match self.running.get(id) {
      Some(r) if physical_equal(r, running) => self.running.remove(id)
      _ => ()
    }
    ignore(running.settled.succeed(()))
  }
  ignore(
    self.rt.fork_daemon("job followed", on_error=failed, async fn() {
      let exit = self.exit_file(id)
      while true {
        if there(self.host, exit) || !(self.procs.pid_alive)(pgid) {
          break
        }
        @effect.sleep(follow_look_ms) // timer: a sample of this machine (a process that is not this one's child)
      }
      ignore(running.gone.succeed(()))
      let code = self.read_exit(id)
      self.taken_in(id, running, code, (self.now)() - began)
    }),
  )
}

///|
/// Its end said to the program, which takes it in; what its shell left running in its group made to end, and its log
/// held to its bound.
async fn JobsHost::taken_in(self : JobsHost, id : String, running : Running, code : Double?, ran : Double) -> Unit {
  (self.ended)(id, running.pgid, code, ran) catch {
    _ => ()
  }
  match self.running.get(id) {
    Some(r) if physical_equal(r, running) => self.running.remove(id)
    _ => ()
  }
  ignore(running.settled.succeed(()))
  if !self.closing && (self.procs.group_alive)(running.pgid) {
    self.end_group(running.pgid, stop_grace_ms)
  }
}

///|
/// SIGTERM a group, SIGKILL it if it is still there after `grace_ms`, looked at every 100 ms (ops/group.ts
/// `endGroup`).
pub async fn JobsHost::end_group(self : JobsHost, pgid : Int, grace_ms : Int) -> Unit {
  (self.procs.signal_group)(pgid, "SIGTERM")
  let looks = if grace_ms / stop_look_ms > 1 { grace_ms / stop_look_ms } else { 1 }
  for i in 0..<looks {
    ignore(i)
    @effect.sleep(stop_look_ms) // timer: a deadline to a process
    if !(self.procs.group_alive)(pgid) {
      return
    }
  }
  (self.procs.signal_group)(pgid, "SIGKILL")
}

///|
pub async fn JobsHost::signal(self : JobsHost, pgid : Int, signal : String) -> Unit {
  (self.procs.signal_group)(pgid, signal)
}

///|
pub async fn JobsHost::pid_alive(self : JobsHost, pid : Int) -> Bool {
  (self.procs.pid_alive)(pid)
}

///|
/// A stop's wait for a job's end (jobs.ts `grace`): its leader's, then the members it left behind looked at within the
/// grace; killed if not ended by then, and its end taken in.
pub async fn JobsHost::grace(self : JobsHost, id : String) -> Unit {
  guard self.running.get(id) is Some(running) else { return }
  ignore(
    @effect.timeout(stop_grace_ms, async fn() {
      running.gone.wait()
      while (self.procs.group_alive)(running.pgid) {
        @effect.sleep(stop_look_ms) // timer: a deadline to a process
      }
    }) catch {
      _ => None
    },
  )
  if (self.procs.group_alive)(running.pgid) {
    (self.procs.signal_group)(running.pgid, "SIGKILL")
  }
  ignore(@effect.timeout(stop_settle_ms, async fn() { running.settled.wait() }) catch { _ => None })
}

///|
/// Whether this station follows a job's group (one it started or took up).
pub fn JobsHost::follows(self : JobsHost, pgid : Int) -> Bool {
  self.running.values().any(r => r.pgid == pgid)
}

///|
pub fn JobsHost::is_running(self : JobsHost, id : String) -> Bool {
  self.running.contains(id)
}

///|
/// Whether a group recorded by an earlier run is still that group (ops/group.ts `stillOurs`).
pub async fn JobsHost::still_ours(self : JobsHost, pgid : Int, started_at : Double) -> Bool {
  let ours = match (self.procs.start_time)(pgid) {
    Some(s) => (s - started_at).abs() < 5000.0
    None => (self.procs.group_alive)(pgid)
  }
  ours && (self.procs.group_alive)(pgid)
}

///|
/// A job's log held to JOB_LOG_CAP where it is, what it had kept in `<log>.1`.
pub async fn JobsHost::cap_log(self : JobsHost, path : String) -> Bool {
  if !starts(path, self.dir + "/") {
    return false
  }
  rotate_in_place(self.host, path, job_log_cap) catch {
    _ => false
  }
}

///|
async fn collect_files(
  dir : String,
  now : Double,
  up : Array[String],
  list_dir : async (String) -> Array[String],
  stat_file : async (String) -> Json?,
  remove_file : async (String) -> Unit,
  is_running : (String) -> Bool,
  job_of : (String) -> Json?,
  jobs_of? : ((Array[String]) -> Map[String, Json]?)? = None,
  yield_turn? : async () -> Unit = async fn() {
    @effect.sleep(1, later=true) // timer: yields a large upkeep sweep back to the host event loop
  },
) -> Array[String] {
  let gone : Array[String] = []
  let gone_set : Map[String, Bool] = {}
  let up_ids : Map[String, Bool] = {}
  for id in up {
    up_ids[id] = true
  }
  // (each job read once, and none of one up: a log and an exit file of one id read it once, jobs.ts `jobOf`)
  let looked : Map[String, Json?] = {}
  match jobs_of {
    Some(batch_lookup) => {
      let mut processed_any = false
      for sub in ["logs", "exit"] {
        let sub_dir = pjoin([dir, sub])
        let names = list_dir(sub_dir)
        let mut offset = 0
        while offset < names.length() {
          if processed_any {
            yield_turn()
          }
          processed_any = true
          let end = if offset + collect_batch_size < names.length() {
            offset + collect_batch_size
          } else {
            names.length()
          }
          let need : Array[String] = []
          let seen_need : Map[String, Bool] = {}
          for i in offset..<end {
            guard job_file_id(names[i], sub) is Some(id) else { continue }
            if up_ids.contains(id) || looked.contains(id) || seen_need.contains(id) {
              continue
            }
            seen_need[id] = true
            need.push(id)
          }
          if need.length() > 0 {
            match batch_lookup(need) {
              None => {
                // DB error: safely skip this batch without recording misses or deleting files.
                offset = end
                continue
              }
              Some(found) =>
                for id in need {
                  match found.get(id) {
                    Some(Null) | None => looked[id] = None
                    Some(v) => looked[id] = Some(v)
                  }
                }
            }
          }
          for i in offset..<end {
            let name = names[i]
            guard job_file_id(name, sub) is Some(id) else { continue }
            // (one whose end the store keeps is not up, though `taken_in` has yet to let it go: jobs.ts `asked`'s
            // `jobEnded`)
            if up_ids.contains(id) {
              continue
            }
            let job = match looked.get(id) {
              Some(j) => j
              None => continue
            }
            let file = pjoin([sub_dir, name])
            match job {
              None => {
                if is_running(id) {
                  continue
                }
                guard stat_file(file) is Some(st) else { continue }
                if now - num(field(st, "mtimeMs")).unwrap_or(now) < job_files_orphan_ms {
                  continue
                }
              }
              Some(job) => {
                let ended_at = num(field(job, "endedAt"))
                if text(job, "state") == "running" ||
                  ended_at is None ||
                  now - ended_at.unwrap() < job_logs_kept_ms {
                  continue
                }
              }
            }
            // (started again while the files were read)
            if is_running(id) &&
              (match job_of(id) {
                None => true
                Some(j) => text(j, "state") == "running"
              }) {
              continue
            }
            remove_file(file)
            if !gone_set.contains(id) {
              gone_set[id] = true
              gone.push(id)
            }
          }
          offset = end
        }
      }
    }
    None => {
      let mut since = 0
      for sub in ["logs", "exit"] {
        let sub_dir = pjoin([dir, sub])
        for name in list_dir(sub_dir) {
          since += 1
          if since >= collect_yield_every {
            since = 0
            yield_turn()
          }
          guard job_file_id(name, sub) is Some(id) else { continue }
          // (one whose end the store keeps is not up, though `taken_in` has yet to let it go: jobs.ts `asked`'s
          // `jobEnded`)
          if up_ids.contains(id) {
            continue
          }
          let file = pjoin([sub_dir, name])
          let job = match looked.get(id) {
            Some(j) => j
            None => {
              since += 1
              let j = job_of(id)
              looked[id] = j
              j
            }
          }
          match job {
            None => {
              if is_running(id) {
                continue
              }
              guard stat_file(file) is Some(st) else { continue }
              if now - num(field(st, "mtimeMs")).unwrap_or(now) < job_files_orphan_ms {
                continue
              }
            }
            Some(job) => {
              let ended_at = num(field(job, "endedAt"))
              if text(job, "state") == "running" ||
                ended_at is None ||
                now - ended_at.unwrap() < job_logs_kept_ms {
                continue
              }
            }
          }
          // (started again while the files were read)
          if is_running(id) &&
            (match job_of(id) {
              None => true
              Some(j) => text(j, "state") == "running"
            }) {
            continue
          }
          remove_file(file)
          if !gone_set.contains(id) {
            gone_set[id] = true
            gone.push(id)
          }
        }
      }
    }
  }
  gone
}

///|
/// The files in jobs/logs and jobs/exit of a job the store no longer has (`job_of` None), unchanged for
/// JOB_FILES_ORPHAN_MS, and those of a job that ended JOB_LOGS_KEPT_MS ago, removed; of one up (`up`) nothing. The job
/// ids whose files went.
pub async fn JobsHost::collect(
  self : JobsHost,
  now : Double,
  up : Array[String],
  job_of : (String) -> Json?,
  jobs_of? : ((Array[String]) -> Map[String, Json]?)? = None,
) -> Array[String] {
  collect_files(
    self.dir,
    now,
    up,
    async fn(dir) { readdir(self.host, dir).unwrap_or([]) },
    async fn(file) { lstat(self.host, file) },
    async fn(file) { remove(self.host, file) },
    id => self.running.contains(id),
    job_of,
    jobs_of~,
  )
}

///|
/// A session's jobs that are over taken off with their files: their logs (those in jobs/ only) and exit files.
pub async fn JobsHost::clear_files(self : JobsHost, gone : Array[(String, String)]) -> Array[String] {
  for g in gone {
    let (id, file) = g
    if starts(file, self.dir + "/") {
      remove(self.host, file)
    }
    remove(self.host, self.exit_file(id))
    remove(self.host, self.exit_file(id) + ".tmp")
  }
  gone.map(g => g.0)
}

///|
/// The station stops: its jobs go on (the next station takes them up); what followed them ends here.
pub fn JobsHost::shutdown(self : JobsHost) -> Unit {
  self.closing = true
}
