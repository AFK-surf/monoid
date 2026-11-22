// These parts' IO on the station's program: the shell's (`@host.Host::shell`, client/shell's `run`), on the program's
// runtime. What the shell does not offer yet is said where it is asked, never made up:
// - `fetch` follows redirects (up to ten) as Node's `fetch` does, but a request's `manual` (`redirect: "manual"`)
//   answers a 3xx as it came;
// - a command's run has no stdin and keeps the station's environment, the variables a login drops unset by `sh`
//   (`commands_on`), its stderr kept in a file beside it; not run through `sh` on Windows (no stderr there).

///|
fn enoent(path : String, what : String) -> Error {
  FsError("ENOENT", @host_world.enoent_msg(what, path))
}

///|
/// The record of what these parts ask, on `host`: its clock, its runtime's timers, the shell's network and files.
pub fn host_io(host : @host.Host) -> Io {
  {
    now: () => @host.now(),
    wall: () => @host.epoch_ms(),
    sleep: ms => @host_world.sleep_ms(ms),
    after: (ms, f) => @host_world.after(host, ms.to_int(), f),
    every: (ms, f) => @host_world.every(host, ms.to_int(), async fn() { f() }),
    spawn: f => @host_world.spawn_daemon(host, "accounts_oauth", f),
    fetch: req => {
      let r = host.fetch(
        req.url,
        method_=req.method_,
        headers=req.headers,
        body?=req.body.map(utf8_of),
        timeout_ms=req.timeout_ms,
        redirect=if req.manual { "manual" } else { "follow" },
      ) catch {
        @host.FetchTimeout => raise Failed(@host.fetch_timed_out)
        e => raise e
      }
      { status: r.status, headers: r.headers, body: r.text() }
    },
    read: path => match @host_world.fs_read_text(host, path) {
      Some(s) => s
      None => raise enoent(path, "open")
    },
    write_private: (path, text) => {
      let tmp = @host.unique_tmp(path)
      @host_world.fs_mkdir(host, @nodepath.dirname("/", path))
      @host_world.fs_put(host, tmp, utf8_of(text), exclusive=true, mode=384, sync_disk=true)
      @host_world.fs_rename(host, tmp, path) catch {
        e => {
          @host_world.fs_remove(host, tmp) catch {
            _ => ()
          }
          raise e
        }
      }
    },
    write: (path, text) => @host_world.fs_write(host, path, text),
    mkdir: (path, recursive) => {
      @host_world.fs_mkdir(host, path, recursive~) catch {
        e =>
          if includes("\{e}", "EEXIST") {
            raise FsError("EEXIST", @host_world.eexist_msg("mkdir", path))
          } else {
            raise e
          }
      }
    },
    rmdir: path => {
      if !@host_world.fs_exists(host, path, lstat=true) {
        raise enoent(path, "rmdir")
      }
      @host_world.fs_remove(host, path)
    },
    rm: (path, recursive) => @host_world.fs_remove(host, path, recursive~),
    stat: path => match @host_world.fs_lstat(host, path) {
      Some(st) => { dev: 0.0, ino: st.ino, size: st.size, mtime_ms: st.mtime_ms }
      None => raise enoent(path, "stat")
    },
    exists: path => @host_world.fs_exists(host, path),
    realpath: path => match @host_world.fs_realpath(host, path) {
      Some(s) => s
      None => raise enoent(path, "realpath")
    },
    readdir: path => match @host_world.fs_readdir(host, path) {
      Some(xs) => xs
      None => raise enoent(path, "scandir")
    },
    hold: path => {
      // What a folder held open says of itself is what it was as it was opened: its inode.
      let st = match @host_world.fs_lstat(host, path) {
        Some(s) => s
        None => raise enoent(path, "open")
      }
      let held : Stat = { dev: 0.0, ino: st.ino, size: 0.0, mtime_ms: st.mtime_ms }
      {
        stat: async fn() { held },
        utimes: async fn(at_ms) {
          match @host_world.fs_lstat(host, path) {
            Some(cur) if held.ino == 0.0 || cur.ino == held.ino =>
              @host_world.fs_utimes(host, path, at_ms.to_double())
            _ => raise enoent(path, "utimes")
          }
        },
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
        let got = @host_world.shell_call(host, false, "proc.run", {
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
      let got = @host_world.shell_call(host, false, "proc.run", {
        "command": "/bin/sh",
        "args": jstrings(["-c", script, "sh", command] + args),
        "env": Json::object(vars),
        "timeoutMs": Json::number(ms.to_double()),
        "code": true,
      })
      let err = @host_world.fs_read_text(host, err_file).unwrap_or("")
      @host_world.fs_remove(host, err_file) catch {
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
