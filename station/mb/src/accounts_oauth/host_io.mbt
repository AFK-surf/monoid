// These parts' IO on the station's program: the shell's (`@host.Host::shell`, client/shell's `run`), on the program's
// runtime. What the shell does not offer yet is said where it is asked, never made up:
// - `fetch` follows redirects (reqwest's), so a request asking `manual` is still followed;
// - a folder made only where it is not (`mkdir` alone, EEXIST) is a look then a make, not one step: two programs
//   taking one lock at the same moment may both have it, which Claude Code's `mkdir` never lets happen;
// - a folder held open has no `utimes`: a lock's heartbeat stops at its first beat (as one that fails does), so a lock
//   held past 60 s may be taken by another as stale;
// - a command's run has no stdin and keeps the station's environment, the variables a login drops unset by `sh`
//   (`commands_on`), its stderr kept in a file beside it; not run through `sh` on Windows (no stderr there).

///|
fn shell_value(answer : Json) -> Json {
  answer
}

///|
fn enoent(path : String, what : String) -> Error {
  FsError("ENOENT", "ENOENT: no such file or directory, \{what} '\{path}'")
}

///|
async fn sh(host : @host.Host, op : String, args : Json) -> Json {
  shell_value(host.shell(op, args).0)
}

///|
/// The record of what these parts ask, on `host`: its clock, its runtime's timers, the shell's network and files.
pub fn host_io(host : @host.Host) -> Io {
  let rt = host.rt
  let tmp_n = Ref(0)
  {
    now: () => @host.now(),
    wall: () => @host.epoch_ms(),
    sleep: ms => @effect.sleep(ms),
    after: (ms, f) => {
      let fiber = rt.fork(async fn() {
        @effect.sleep(ms.to_int())
        f()
      })
      () => fiber.interrupt()
    },
    every: (ms, f) => {
      // timer: what asks for it says which kind (oauth.ts's lock's heartbeat)
      let fiber = rt.fork(async fn() {
        while true {
          @effect.sleep(ms.to_int())
          f()
        }
      })
      () => fiber.interrupt()
    },
    spawn: f => ignore(
      rt.fork_daemon("accounts_oauth", f, on_error=e => @host.note("accounts_oauth: background work failed: \{e}")),
    ),
    fetch: req => {
      let args : Map[String, Json] = {
        "url": Json::string(req.url),
        "method": Json::string(req.method_),
        "headers": Json::array(req.headers.map(p => Json::array([Json::string(p.0), Json::string(p.1)]))),
      }
      let call = async fn() {
        let (answer, body) = match req.body {
          Some(b) => host.shell("fetch", Json::object(args), bytes=utf8_of(b))
          None => host.shell("fetch", Json::object(args))
        }
        let headers = match get(Some(answer), "headers") {
          Some(Array(hs)) =>
            hs.filter_map(h => match h {
              Array([String(k), String(v), ..]) => Some((k, v))
              _ => None
            })
          Some(Object(m)) => m.to_array().filter_map(p => str_of(Some(p.1)).map(v => (p.0, v)))
          _ => []
        }
        {
          status: num_of(get(Some(answer), "status")).unwrap_or(0.0).to_int(),
          headers,
          body: match body {
            Some(b) => @utf8.decode_lossy(b)
            None => ""
          },
        }
      }
      match @effect.timeout(req.timeout_ms, call) {
        Some(r) => r
        None => raise Failed("The operation was aborted due to timeout")
      }
    },
    read: path => match sh(host, "fs.read", { "path": Json::string(path) }) {
      String(s) => s
      _ => raise enoent(path, "open")
    },
    write_private: (path, text) => {
      tmp_n.val += 1
      let tmp = "\{path}.\{@host.pid()}.\{tmp_n.val}.tmp"
      ignore(sh(host, "fs.mkdir", { "path": Json::string(@nodepath.dirname("/", path)) }))
      ignore(host.shell("fs.put", { "path": Json::string(tmp), "exclusive": true, "mode": 384, "sync": true }, bytes=utf8_of(text)))
      ignore(sh(host, "fs.rename", { "from": Json::string(tmp), "to": Json::string(path) })) catch {
        e => {
          ignore(sh(host, "fs.remove", { "path": Json::string(tmp) })) catch {
            _ => ()
          }
          raise e
        }
      }
    },
    write: (path, text) => ignore(sh(host, "fs.write", { "path": Json::string(path), "text": Json::string(text) })),
    mkdir: (path, recursive) => {
      if !recursive && !(sh(host, "fs.stat", { "path": Json::string(path), "lstat": true }) is Null) {
        raise FsError("EEXIST", "EEXIST: file already exists, mkdir '\{path}'")
      }
      ignore(sh(host, "fs.mkdir", { "path": Json::string(path) }))
    },
    rmdir: path => {
      if sh(host, "fs.stat", { "path": Json::string(path), "lstat": true }) is Null {
        raise enoent(path, "rmdir")
      }
      ignore(sh(host, "fs.remove", { "path": Json::string(path) }))
    },
    rm: (path, recursive) => ignore(sh(host, "fs.remove", { "path": Json::string(path), "recursive": Json::boolean(recursive) })),
    stat: path => {
      let st = sh(host, "fs.lstat", { "path": Json::string(path) })
      if st is Null {
        raise enoent(path, "stat")
      }
      {
        dev: 0.0,
        ino: num_of(get(Some(st), "ino")).unwrap_or(0.0),
        size: num_of(get(Some(st), "size")).unwrap_or(0.0),
        mtime_ms: num_of(get(Some(st), "mtimeMs")).unwrap_or(0.0),
      }
    },
    exists: path => !(sh(host, "fs.stat", { "path": Json::string(path) }) is Null),
    realpath: path => match sh(host, "fs.realpath", { "path": Json::string(path) }) {
      String(s) => s
      _ => raise enoent(path, "realpath")
    },
    readdir: path => match sh(host, "fs.readdir", { "path": Json::string(path) }) {
      Array(a) =>
        a.filter_map(v => match v {
          String(s) => Some(s)
          Array([String(s), ..]) => Some(s)
          _ => None
        })
      _ => raise enoent(path, "scandir")
    },
    hold: path => {
      // What a folder held open says of itself is what it was as it was opened: its inode.
      let st = sh(host, "fs.lstat", { "path": Json::string(path) })
      if st is Null {
        raise enoent(path, "open")
      }
      let held : Stat = {
        dev: 0.0,
        ino: num_of(get(Some(st), "ino")).unwrap_or(0.0),
        size: 0.0,
        mtime_ms: num_of(get(Some(st), "mtimeMs")).unwrap_or(0.0),
      }
      {
        stat: async fn() { held },
        utimes: async fn(_) { raise Failed("the shell offers no fs.utimes") },
        close: async fn() {  },
      }
    },
    log: (level, part, words, fields) => @host.note("[\{level}] \{part}: \{words} \{fields.stringify()}"),
  }
}

///|
/// The variables a run unsets where its environment does not name them: those that would point a command at another
/// home or account (login.ts SCRUBBED, machine.ts's).
let pointing : Array[String] = [
  "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
  "CLAUDE_CODE_OAUTH_TOKEN", "CODEX_HOME", "OPENAI_API_KEY", "CODEX_API_KEY", "GROK_HOME", "GROK_AUTH", "GROK_AUTH_PATH", "XAI_API_KEY",
  "WINDSURF_API_KEY", "XDG_DATA_HOME", "GEMINI_API_KEY", "GOOGLE_API_KEY", "AGY_ADC_AUTH", "AGY_ACCOUNT", "ANTIGRAVITY_GEMINI_DIR",
]

///|
/// Commands run by the shell's `proc.run` (through `sh`, where there is one, for their stderr and the variables
/// unset): not found where `sh` says so (127), timed out or killed where the shell gives nothing back.
pub fn commands_on(host : @host.Host, posix? : Bool = true) -> Commands {
  let n = Ref(0)
  {
    run: (command, args, env, ms) => {
      let vars : Map[String, Json] = Map([])
      for k, v in env {
        vars[k] = Json::string(v)
      }
      if !posix {
        let got = sh(host, "proc.run", {
          "command": Json::string(command),
          "args": jstrings(args),
          "env": Json::object(vars),
          "timeoutMs": Json::number(ms.to_double()),
          "code": true,
        })
        return match got {
          Null => NotFound("spawn \{command} ENOENT")
          v =>
            Ended(
              num_of(get(Some(v), "code")).map(d => d.to_int()),
              str_of(get(Some(v), "out")).unwrap_or(""),
              "",
            )
        }
      }
      n.val += 1
      let err_file = "/tmp/stillfail-run-\{@host.pid()}-\{n.val}.err"
      let unset = pointing.filter(k => !env.contains(k))
      vars["STILLFAIL_RUN_ERR"] = Json::string(err_file)
      let script = "unset \{unset.join(" ")}; \"$@\" 2>\"$STILLFAIL_RUN_ERR\""
      let got = sh(host, "proc.run", {
        "command": "/bin/sh",
        "args": jstrings(["-c", script, "sh", command] + args),
        "env": Json::object(vars),
        "timeoutMs": Json::number(ms.to_double()),
        "code": true,
      })
      let err = match sh(host, "fs.read", { "path": Json::string(err_file) }) {
        String(s) => s
        _ => ""
      }
      ignore(sh(host, "fs.remove", { "path": Json::string(err_file) })) catch {
        _ => ()
      }
      match got {
        Null => TimedOut
        v => {
          let code = num_of(get(Some(v), "code")).map(d => d.to_int())
          if code == Some(127) && (includes(err, "not found") || includes(err, "No such file")) {
            NotFound("spawn \{command} ENOENT")
          } else {
            Ended(code, str_of(get(Some(v), "out")).unwrap_or(""), err)
          }
        }
      }
    },
  }
}
