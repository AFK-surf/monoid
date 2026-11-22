// Programs for the Linux X11 desktop (src/screens/linux-tools.ts). Prefer the machine's pair; on Debian-family systems
// the station can prepare its own pair without installing packages into the operating system or requiring an
// administrator.

///|
/// What stops a piece of work (AbortController's signal): told once, with its reason.
pub struct AbortSignal {
  priv mut aborted : Bool
  priv mut reason : Error?
  priv listeners : Array[(Int, () -> Unit)]
  priv mut next : Int
}

///|
pub fn AbortSignal::new() -> AbortSignal {
  { aborted: false, reason: None, listeners: [], next: 0 }
}

///|
/// `controller.abort()`: its reason the AbortError DOMException's.
pub fn AbortSignal::abort(self : AbortSignal) -> Unit {
  if self.aborted {
    return
  }
  self.aborted = true
  self.reason = Some(fail("This operation was aborted"))
  for l in self.listeners.copy() {
    (l.1)()
  }
  self.listeners.clear()
}

///|
fn AbortSignal::on_abort(self : AbortSignal, f : () -> Unit) -> Int {
  self.next += 1
  self.listeners.push((self.next, f))
  self.next
}

///|
fn AbortSignal::off(self : AbortSignal, id : Int) -> Unit {
  take_out(self.listeners, id)
}

///|
/// `signal.throwIfAborted()`.
fn AbortSignal::throw_if_aborted(self : AbortSignal) -> Unit raise {
  if self.aborted {
    raise self.reason.unwrap_or(fail("This operation was aborted"))
  }
}

///|
/// A command of the preparation, run as a group of its own: stopped, out of time or saying too much, it is ended whole,
/// and it answers only once nothing of it holds its output any more.
async fn tools_run(
  io : Io,
  program : String,
  args : Array[String],
  env : Env,
  signal : AbortSignal,
  timeout : Double,
  max_buffer? : Double? = None,
) -> String {
  let most = max_buffer.unwrap_or(1048576.0)
  let stdout = Buffer()
  let said = Ref(0.0)
  let failed : Ref[Error?] = Ref(None)
  let d : @effect.Deferred[String] = @effect.Deferred::new()
  let child_ref : Ref[Child?] = Ref(None)
  let end = (why : Error) => {
    if failed.val is None {
      failed.val = Some(why)
    }
    match child_ref.val {
      Some(c) => (c.kill)("SIGKILL")
      None => ()
    }
  }
  let late : Ref[() -> Unit] = Ref(() => ())
  let listener : Ref[Int] = Ref(0)
  let done = (answer : () -> Unit) => {
    (late.val)()
    signal.off(listener.val)
    answer()
  }
  let hear = (keep : Bool) => (chunk : Bytes) => {
    said.val = said.val + chunk.length().to_double()
    if said.val > most {
      end(fail("\{program} said more than \{num_text(most)} bytes"))
    } else if keep {
      stdout.write_bytes(chunk)
    }
  }
  let child = (io.procs.spawn)(
    program,
    args,
    { env: Some(env), group: true, verbatim: false, stdio: ("ignore", "pipe", "pipe") },
    {
      out: hear(true),
      err: hear(false),
      // (not started at all: nothing of it to wait for)
      error: e => done(() => ignore(d.fail(failed.val.unwrap_or(fail(e))))),
      close: (code, sig) => done(() => match failed.val {
        Some(f) => ignore(d.fail(f))
        None =>
          if code == Some(0) {
            ignore(d.succeed(@utf8.decode_lossy(stdout.to_bytes())))
          } else {
            let why = match code {
              Some(c) => c.to_string()
              None => sig.unwrap_or("null")
            }
            ignore(d.fail(fail("\{program} ended with \{why}")))
          }
      }),
    },
  )
  child_ref.val = Some(child)
  let stopped = () => end(signal.reason.unwrap_or(fail("\{program} stopped")))
  // The command's time, the machine's: one left going is ended, its whole group.
  late.val = (io.clock.after)(timeout, () => end(fail("\{program} took more than \{num_text(timeout)} ms")))
  if signal.aborted {
    stopped()
  } else {
    listener.val = signal.on_abort(stopped)
  }
  d.wait()
}

///|
/// Resolve only executables, without invoking a shell or consulting a different user's environment.
pub async fn executable(io : Io, name : String, env : Env) -> String? {
  let paths = if name.has_prefix("/") || name.contains("/") {
    [name]
  } else {
    env.get("PATH").unwrap_or("").split(":").map(v => v.to_string()).collect().filter(d => d != "").map(d => pj([d, name]))
  }
  for p in paths {
    if (io.fs.access)(p, 1) {
      return Some(p)
    }
  }
  None
}

///|
pub(all) struct LinuxToolPair {
  ffmpeg : String
  xdotool : String
  env : Env
}

///|
async fn pair_at(io : Io, root : String, env : Env) -> LinuxToolPair? {
  let ffmpeg = executable(io, pj([root, "usr/bin/ffmpeg"]), env)
  let xdotool = executable(io, pj([root, "usr/bin/xdotool"]), env)
  let arch = match io.os.arch {
    "x64" => Some("x86_64-linux-gnu")
    "arm64" => Some("aarch64-linux-gnu")
    _ => None
  }
  guard ffmpeg is Some(ffmpeg) && xdotool is Some(xdotool) && arch is Some(arch) else { return None }
  let libraries = [
    Some(pj([root, "usr/lib", arch])),
    Some(pj([root, "lib", arch])),
    Some(pj([root, "usr/lib"])),
    Some(pj([root, "lib"])),
    env.get("LD_LIBRARY_PATH"),
  ].filter_map(x => x.filter(s => s != "")).join(":")
  let e = env.copy()
  e.set("LD_LIBRARY_PATH", libraries)
  Some({ ffmpeg, xdotool, env: e })
}

///|
/// `/\bD\s+x11grab\b/`.
fn has_x11grab(t : String) -> Bool {
  let cs = t.to_array()
  let wordy = (c : Char) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
  for i, c in cs {
    if c != 'D' || (i > 0 && wordy(cs[i - 1])) {
      continue
    }
    let mut j = i + 1
    while j < cs.length() && is_js_space(cs[j]) {
      j += 1
    }
    if j == i + 1 {
      continue
    }
    let word = "x11grab".to_array()
    if j + word.length() > cs.length() {
      continue
    }
    let mut all = true
    for k, w in word {
      if cs[j + k] != w {
        all = false
        break
      }
    }
    if all && (j + word.length() == cs.length() || !wordy(cs[j + word.length()])) {
      return true
    }
  }
  false
}

///|
/// Programs and their dependencies extracted under the station's data directory from the machine's APT repositories
/// (linux-tools.ts `LinuxScreenTools`). APT verifies its repositories' package hashes; dpkg-deb only unpacks the
/// archives, never runs maintainer scripts.
pub struct LinuxScreenTools {
  priv io : Io
  priv dir : String
  priv preparing : Shared[Unit]
  priv mut abort : AbortSignal?
  priv mut closed : Bool
}

///|
pub fn LinuxScreenTools::new(io : Io, data : String) -> LinuxScreenTools {
  { io, dir: pj([data, "screen-tools", "apt"]), preparing: Shared::new(), abort: None, closed: false }
}

///|
/// The pair prepared here, with its libraries searched only by its own child processes.
pub async fn LinuxScreenTools::prepared(self : LinuxScreenTools, env : Env) -> LinuxToolPair? {
  if !(self.io.fs.access)(pj([self.dir, "ready"]), 4) {
    return None
  }
  pair_at(self.io, pj([self.dir, "root"]), env)
}

///|
/// Whether this machine has the Debian package tools and an architecture the station ships for.
pub async fn LinuxScreenTools::can_prepare(self : LinuxScreenTools, env : Env) -> Bool {
  (self.io.os.arch == "x64" || self.io.os.arch == "arm64") &&
  executable(self.io, "apt-get", env) is Some(_) &&
  executable(self.io, "dpkg-deb", env) is Some(_)
}

///|
/// Concurrent requests in one station share the download; an interrupted or failed preparation can be tried again.
pub async fn LinuxScreenTools::prepare(self : LinuxScreenTools, env : Env) -> Unit {
  if self.closed {
    raise fail("screen tools closed")
  }
  if !self.preparing.is_going() {
    let abort = AbortSignal::new()
    self.abort = Some(abort)
    let d = self.preparing.start(self.io, async fn() {
      let r = try Ok({
        if self.prepared(env) is None {
          self.install(env, abort)
        }
      }) catch {
        e => Err(e)
      }
      self.abort = None
      match r {
        Ok(_) => ()
        Err(e) => raise e
      }
    })
    d.wait()
    return
  }
  self.preparing.start(self.io, async fn() { () }).wait()
}

///|
pub fn LinuxScreenTools::close(self : LinuxScreenTools) -> Unit {
  self.closed = true
  match self.abort {
    Some(a) => a.abort()
    None => ()
  }
}

///|
async fn LinuxScreenTools::install(self : LinuxScreenTools, env : Env, signal : AbortSignal) -> Unit {
  let io = self.io
  let apt = executable(io, "apt-get", env)
  let dpkg = executable(io, "dpkg-deb", env)
  guard apt is Some(apt) && dpkg is Some(dpkg) && self.can_prepare(env) else {
    raise fail("APT package tools are unavailable")
  }
  let parent = pj([self.dir, ".."])
  (io.fs.mkdir)(parent, true, Some(0o700))
  let stage = (io.fs.mkdtemp)(pj([parent, ".apt-"]))
  let archives = pj([stage, "archives"])
  let root = pj([stage, "root"])
  let r = try Ok({
    (io.fs.mkdir)(pj([archives, "partial"]), true, Some(0o700))
    // This is read-only with respect to the system's package database.
    let apt_env = env.copy()
    apt_env.set("DEBIAN_FRONTEND", "noninteractive")
    ignore(
      tools_run(
        io,
        apt,
        [
          "--download-only", "--assume-yes", "--reinstall", "--no-remove", "--no-install-recommends", "-o", "Debug::NoLocking=1",
          "-o", "Dir::Cache::archives=\{archives}", "-o", "Dir::Cache::pkgcache=", "-o", "Dir::Cache::srcpkgcache=",
          "install", "ffmpeg", "xdotool",
        ],
        apt_env,
        signal,
        180000.0,
        max_buffer=Some(4194304.0),
      ),
    )
    let packages = (io.fs.readdir)(archives).map(e => e.name).filter(f => f.has_suffix(".deb"))
    packages.sort_by(compare_units)
    if packages.length() == 0 {
      raise fail("APT returned no packages")
    }
    (io.fs.mkdir)(root, false, Some(0o700))
    for file in packages {
      ignore(tools_run(io, dpkg, ["--extract", pj([archives, file]), root], env, signal, 30000.0))
    }
    guard pair_at(io, root, env) is Some(pair) else { raise fail("APT packages lack the screen programs") }
    let got = @effect.all([
      async fn() { tools_run(io, pair.ffmpeg, ["-hide_banner", "-devices"], pair.env, signal, 30000.0) },
      async fn() { tools_run(io, pair.xdotool, ["--version"], pair.env, signal, 30000.0) },
    ])
    if !has_x11grab(got[0]) {
      raise fail("FFmpeg does not support X11 capture")
    }
    (io.fs.rm)(archives, true, true)
    (io.fs.write)(pj([stage, "ready"]), b"\n", Some(0o600))
    signal.throw_if_aborted()
    // Do not replace a pair another station process finished preparing during a handover.
    (io.fs.rename)(stage, self.dir) catch {
      e => if self.prepared(env) is None { raise e }
    }
  }) catch {
    e => Err(e)
  }
  (io.fs.rm)(stage, true, true) catch { _ => () }
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
}

///|
/// Strings in UTF-16 code unit order (`Array.prototype.sort`'s).
fn compare_units(a : String, b : String) -> Int {
  @jsjson.js_compare(a, b)
}
