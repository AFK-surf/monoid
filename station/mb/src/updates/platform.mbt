// What of the machine's platform (station/src/platform) the updates read as values: which system and architecture
// it is, how its installer is named and run, and its runtimes' own installers. Its functions (finding a command, a
// package manager's update, starting the installer) are asked of the world as `platform.<name>`.

///|
/// How an update is done: a program and its arguments; for an npm install on a machine that has no npm, the Node it
/// is done with, installed first; the exit code with which the program says it has no update it can apply.
/// `mark`: which of the platform's own installers it is, when it is one (`how === platform.claudeInstall`).
pub struct How {
  program : String
  args : Array[String]
  node : OwnNode?
  no_update : Double?
  mark : String
}

///|
/// A Node as nodejs.org builds it, for what npm installs where the machine has none: `version`, its build, unpacked
/// at `at` (<data>/node/<dist>), its commands in `bin`.
pub struct OwnNode {
  version : String
  build : J
  at : String
  bin : String
}

///|
pub fn How::to_j(self : How) -> J {
  let fs = [("program", js(self.program)), ("args", jstrs(self.args))]
  match self.node {
    Some(n) => fs.push(("node", n.to_j()))
    None => ()
  }
  match self.no_update {
    Some(c) => fs.push(("noUpdate", jn(c)))
    None => ()
  }
  jo(fs)
}

///|
pub fn OwnNode::to_j(self : OwnNode) -> J {
  jo([("version", js(self.version)), ("build", self.build), ("at", js(self.at)), ("bin", js(self.bin))])
}

///|
/// A How as the platform gives one (`{program, args, noUpdate?}`).
pub fn how_of(j : J, mark? : String = "") -> How {
  {
    program: text(get(Some(j), "program")).unwrap_or(""),
    args: match get(Some(j), "args") {
      Some(Arr(xs)) => xs.filter_map(x => text(Some(x)))
      _ => []
    },
    node: None,
    no_update: num(get(Some(j), "noUpdate")),
    mark,
  }
}

///|
/// The machine as the updates read it.
pub struct Machine {
  /// `platform.buildOs`: darwin, linux, windows (none where the station has no build).
  build_os : String?
  /// `process.arch` as the runtimes name it: arm64, x64 (none otherwise).
  arch : String?
  /// `platform.installerExt`: sh, ps1.
  installer_ext : String
  /// `platform.codexStandalone`.
  codex_standalone : Bool
  /// Its paths' and environment's ways (`platform.paths`, `prependPath`, `appendPath`, `home`, `exe`).
  plat : @ops_platform.Plat
  claude_install : How
  agy_install : How
  devin_install : How
  /// The applier run apart (release.ts applyApart): Node and the module it runs (a checkout's scripts/delta.ts, or
  /// the release's main.js); "" where `exec_path` is the station's own program (stillfail-reader), run with no module.
  exec_path : String
  applier : String
}

///|
let machine : Ref[Machine] = Ref({
  build_os: Some("darwin"),
  arch: Some("arm64"),
  installer_ext: "sh",
  codex_standalone: true,
  plat: Unix,
  claude_install: how_of(jo([("program", js("/bin/sh"))]), mark="claude"),
  agy_install: how_of(jo([("program", js("/bin/sh"))]), mark="agy"),
  devin_install: how_of(jo([("program", js("/bin/sh"))]), mark="devin"),
  exec_path: "node",
  applier: "main.js",
})

///|
/// The machine of a station's own program (station_main): its system and processor, its installers' kind, Node
/// (`exec_path`) and the applier it runs (`applier`: "" where `exec_path` is the station's own program).
pub fn Machine::of(
  build_os~ : String?,
  arch~ : String?,
  windows~ : Bool,
  cwd~ : String,
  exec_path~ : String,
  applier~ : String,
) -> Machine {
  let sh = if windows { "powershell.exe" } else { "/bin/sh" }
  {
    build_os,
    arch,
    installer_ext: if windows { "ps1" } else { "sh" },
    codex_standalone: true,
    plat: if windows { Windows(cwd) } else { Unix },
    claude_install: how_of(jo([("program", js(sh))]), mark="claude"),
    agy_install: how_of(jo([("program", js(sh))]), mark="agy"),
    devin_install: how_of(jo([("program", js(sh))]), mark="devin"),
    exec_path,
    applier,
  }
}

///|
pub fn set_machine(m : Machine) -> Unit {
  machine.val = m
}

///|
/// This machine as the runtimes name their builds (`darwin-arm64`…).
pub fn platform() -> String? {
  match (machine.val.build_os, machine.val.arch) {
    (Some(os), Some(arch)) => Some("\{os}-\{arch}")
    _ => None
  }
}

///|
/// `platform.exe(name)`.
pub fn exe(name : String) -> String {
  match machine.val.plat {
    Unix => name
    Windows(_) => name + ".exe"
  }
}

///|
/// The environment commands run in, as pairs (what is undefined left out).
pub type Env = Array[(String, String)]

///|
pub fn env_get(env : Env, k : String) -> String? {
  match env.search_by(p => p.0 == k) {
    Some(i) => Some(env[i].1)
    None => None
  }
}

///|
pub fn env_j(env : Env) -> J {
  jo(env.map(p => (p.0, js(p.1))))
}

///|
pub fn env_of(j : J) -> Env {
  match j {
    Obj(ps) =>
      ps.filter_map(p => match p.1 {
        Str(u) => Some((@jsjson.sanitize_str(p.0), @jsjson.sanitize_str(u)))
        _ => None
      })
    _ => []
  }
}

///|
/// `platform.home(env)`.
pub fn home_of(env : Env) -> String? {
  match machine.val.plat {
    Unix => env_get(env, "HOME")
    Windows(_) =>
      match env_get(env, "HOME") {
        Some(h) => Some(h)
        None => env_get(env, "USERPROFILE")
      }
  }
}

///|
/// `platform.prependPath(env, dir)`.
pub fn prepend_path(env : Env, dir : String) -> Env {
  match machine.val.plat {
    Unix => @ops_platform.unix_prepend_path(env, dir)
    Windows(_) => @ops_platform.win_prepend_path(env, dir, ";")
  }
}

///|
/// `platform.appendPath(env, dir)`, in place.
pub fn append_path(env : Env, dir : String) -> Unit {
  match machine.val.plat {
    Unix => @ops_platform.unix_append_path(env, dir)
    Windows(_) => @ops_platform.win_append_path(env, dir, ";")
  }
}

///|
/// `platform.paths.within(path, dir)`.
pub fn within(path : String, dir : String) -> Bool {
  @ops_platform.within(machine.val.plat, path, dir)
}

///|
/// `platform.paths.separator`.
pub fn separator() -> String {
  match machine.val.plat {
    Unix => "/"
    Windows(_) => "\\"
  }
}
