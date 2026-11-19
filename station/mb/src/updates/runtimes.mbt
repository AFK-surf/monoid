// runtimes.ts: Claude Code, Codex, DeepSeek Harness, Grok Build, Devin and Pi on this machine (Cursor's SDK:
// updates.mbt read_cursor): where the station's PATH finds them, how each is updated the way it was installed
// (`claude update`, `pi update`, Devin's installer, npm, Homebrew, winget, Vite+, Codex's standalone installer) or
// installed when it is not there, and running those commands.

///|
/// The runtimes (agents/runtime.ts RUNTIME_KINDS), and the station with them.
pub let runtime_kinds : Array[String] = ["claude", "codex", "dsh", "grok", "cursor", "devin", "hermes", "agy", "pi"]

///|
pub let kinds : Array[String] = ["station"] + runtime_kinds

///|
/// How a runtime is named to people (agents/runtime.ts `runtimeLabel`).
pub fn runtime_label(r : String) -> String {
  match r {
    "claude" => "Claude Code"
    "codex" => "Codex"
    "dsh" => "DeepSeek Harness"
    "grok" => "Grok Build"
    "cursor" => "Cursor"
    "hermes" => "Hermes Agent"
    "agy" => "Antigravity CLI"
    "pi" => "Pi"
    _ => "Devin"
  }
}

///|
pub fn kind_name(k : String) -> String {
  if k == "station" {
    "Station"
  } else {
    runtime_label(k)
  }
}

///|
pub fn kind_command(k : String) -> String {
  if k == "station" {
    "stillfail-station"
  } else {
    k
  }
}

///|
/// Where the latest is said: the npm registry's latest of the runtime's package.
pub fn kind_package(k : String) -> String {
  match k {
    "claude" => "@anthropic-ai/claude-code"
    "codex" => "@openai/codex"
    "dsh" => "@deepseek-ai/dsh"
    "grok" => "@xai-official/grok"
    "cursor" => "@cursor/sdk"
    "pi" => "@earendil-works/pi-coding-agent"
    _ => ""
  }
}

///|
/// Where the Devin CLI's installer reads the latest build ({version, platforms}).
pub let devin_manifest : String = "https://static.devin.ai/cli/current/manifest.json"

///|
/// Where the station keeps the Nodes it installs.
pub fn own_node_home(data : String) -> String {
  pjoin([data, "node"])
}

///|
/// JavaScript's sort of strings (by UTF-16 units).
fn js_compare(a : String, b : String) -> Int {
  @jsjson.js_compare(a, b)
}

///|
fn js_sort(xs : Array[String]) -> Array[String] {
  let out = xs.copy()
  out.sort_by(js_compare)
  out
}

///|
/// `ownNode`: the Node the station installs for npm where the machine has none; none where nodejs.org has no build.
pub async fn own_node(w : World, data : String, version : String) -> OwnNode? {
  let build = w.call("platform.nodeBuild", [js(version)])
  guard build is Obj(_) else { return None }
  let at = pjoin([own_node_home(data), text(get(Some(build), "dist")).unwrap_or("")])
  Some({ version, build, at, bin: pjoin([at, text(get(Some(build), "bin")).unwrap_or("")]) })
}

///|
/// `putOwnNodes`: each Node the station installed, newest first, put last on `env`'s PATH, in place. Read as the
/// station starts.
pub async fn put_own_nodes(w : World, env : Env, data : String) -> Unit {
  let build = w.call("platform.nodeBuild", [js("0")])
  guard build is Obj(_) else { return }
  let names = match (try Some(w.call("fs.readdirSync", [js(own_node_home(data))])) catch { _ => None }) {
    Some(Arr(xs)) => xs.filter_map(x => text(Some(x))).filter(n => starts_with(n, "node-v"))
    _ => return
  }
  let sorted = js_sort(names)
  sorted.rev_in_place()
  for name in sorted {
    let bin = pjoin([own_node_home(data), name, text(get(Some(build), "bin")).unwrap_or("")])
    let has = w.call("fs.existsSync", [js(pjoin([bin, text(get(Some(build), "npm")).unwrap_or("")]))])
    if has is Bool(true) {
      append_path(env, bin)
    }
  }
}

///|
/// `putOwnNodesSoon`: `put_own_nodes` off the station's thread (a Node installed while it serves).
pub async fn put_own_nodes_soon(w : World, env : Env, data : String) -> Unit {
  let build = w.call("platform.nodeBuild", [js("0")])
  guard build is Obj(_) else { return }
  let names = match (try Some(w.readdir(own_node_home(data))) catch { _ => None }) {
    Some(xs) => xs.filter(n => starts_with(n, "node-v"))
    None => return
  }
  let sorted = js_sort(names)
  sorted.rev_in_place()
  for name in sorted {
    let bin = pjoin([own_node_home(data), name, text(get(Some(build), "bin")).unwrap_or("")])
    if w.exists_soon(pjoin([bin, text(get(Some(build), "npm")).unwrap_or("")])) {
      append_path(env, bin)
    }
  }
}

///|
/// `removeOwnNodeLinks`: the links 0.1.4393 made into ~/.local/bin to a Node the station installed and what its npm
/// installed there, removed.
pub async fn remove_own_node_links(w : World, env : Env, data : String) -> Unit {
  guard home_of(env) is Some(home) && home != "" else { return }
  let bin = pjoin([home, ".local", "bin"])
  let own = own_node_home(data) + path_sep.val
  for name in ["node", "npm", "npx"] + runtime_kinds.map(kind_command) {
    let link = pjoin([bin, name])
    let st = (try Some(w.call("fs.lstatSync", [js(link)])) catch { _ => None })
    match st {
      Some(s) if stat_of(s).symlink => {
        let target = (try text(Some(w.call("fs.readlinkSync", [js(link)]))) catch { _ => None })
        match target {
          Some(t) if starts_with(t, own) => ignore(w.call("fs.unlinkSync", [js(link)])) catch { _ => () }
          _ => ()
        }
      }
      _ => ()
    }
  }
}

///|
/// `pinNpmVersion`: the prefetched build's version in place of `@latest`, npm's package index revalidated.
pub fn pin_npm_version(how : How, pkg : String, version : String) -> How {
  {
    program: how.program,
    args: how.args.map(a => if a == "\{pkg}@latest" { "\{pkg}@\{version}" } else { a }) + ["--prefer-online"],
    node: None,
    no_update: None,
    mark: "",
  }
}

///|
/// A command as the station's PATH finds it: where it was found (the link on PATH) and what that is.
pub struct Found {
  on_path : String
  real : String
}

///|
pub fn Found::to_j(self : Found) -> J {
  jo([("onPath", js(self.on_path)), ("real", js(self.real))])
}

///|
fn found_of(j : J) -> Found? {
  match (text(get(Some(j), "onPath")), text(get(Some(j), "real"))) {
    (Some(o), Some(r)) => Some({ on_path: o, real: r })
    _ => None
  }
}

///|
/// `findCommandSoon(name, env)`: a command on `env`'s PATH as a shell finds it.
pub async fn find_command_soon(w : World, name : String, env : Env) -> Found? {
  found_of(w.call("platform.findCommandSoon", [js(name), env_j(env)]))
}

///|
/// `withShellCommand(name, env)` (ops/shell-path.ts).
pub async fn with_shell_command(w : World, name : String, env : Env) -> Env {
  env_of(w.call("shellPath.withShellCommand", [js(name), env_j(env)]))
}

///|
/// Why a runtime cannot be updated from here: said in the language it is read in.
pub struct Unable {
  key : String
  args : J
}

///|
pub fn Unable::say(self : Unable, lang : String) -> String {
  tr(lang, self.key, args=self.args)
}

///|
fn unable(key : String, args? : Array[(String, J)] = []) -> Unable {
  { key, args: jo(args) }
}

///|
/// How a runtime is updated, or why it cannot be.
pub(all) enum HowOr {
  Can(How)
  Cannot(Unable)
}

///|
pub fn HowOr::to_j(self : HowOr) -> J {
  match self {
    Can(h) => h.to_j()
    Cannot(u) => jo([("key", js(u.key)), ("args", u.args)])
  }
}

///|
fn can(program : String, args : Array[String]) -> HowOr {
  Can({ program, args, node: None, no_update: None, mark: "" })
}

///|
/// `howToUpdateSoon`: how a runtime installed as `found` is updated, or why it cannot be from here.
pub async fn how_to_update_soon(w : World, kind : String, found : Found, env : Env) -> HowOr {
  // The markers below are written with `/`.
  let real_path = split(found.real, separator()).join("/")
  let name = kind_name(kind)
  if kind == "station" {
    return Cannot(unable(""))
  }
  // The Antigravity CLI updates itself on asking.
  if kind == "agy" {
    return can(found.on_path, ["update"])
  }
  if kind == "hermes" {
    return Cannot(unable("station.updates.hermesExternal"))
  }
  if kind == "devin" {
    return if includes(real_path, "/devin/cli/_versions/") {
      Can(machine.val.devin_install)
    } else {
      Cannot(unable("station.updates.devinElsewhere", args=[("path", js(real_path))]))
    }
  }
  // Pi installed by its own installer updates itself the way it was installed.
  if kind == "pi" && !includes(real_path, "/lib/node_modules/") {
    return can(found.on_path, ["update"])
  }
  // A package manager's of this machine's kind.
  let shim = w.call("platform.shimUpdate", [found.to_j(), js(kind_package(kind)), env_j(env)])
  match shim {
    Str(u) if @jsjson.sanitize_str(u) == "no-npm" => return Cannot(unable("station.updates.noNpm", args=[("name", js(name))]))
    Obj(_) => return Can(how_of(shim))
    _ => ()
  }
  // Vite+ global commands are shims pointing to vp itself.
  if pbasename(real_path) == "vp" {
    let beside = pjoin([pdirname(found.on_path), "vp"])
    let mut vp : String? = if w.realpath_or_null(beside) == Some(real_path) { Some(beside) } else { None }
    if vp is None {
      match find_command_soon(w, "vp", env) {
        Some(other) if other.real == real_path => vp = Some(other.on_path)
        _ => ()
      }
    }
    return match vp {
      None => Cannot(unable("station.updates.noVp", args=[("name", js(name))]))
      Some(vp) => can(vp, ["install", "-g", "\{kind_package(kind)}@latest"])
    }
  }
  let brew = async fn() -> Result[String, Unable] {
    match find_command_soon(w, "brew", env) {
      Some(b) => Ok(b.on_path)
      None => Err(unable("station.updates.noBrew", args=[("name", js(name))]))
    }
  }
  let npm = async fn() -> Result[String, Unable] {
    let at = index_of(real_path, "/lib/node_modules/")
    if at >= 0 {
      let own = pjoin([slice(found.real, 0, end=at), "bin/npm"])
      if w.exists_soon(own) {
        return Ok(own)
      }
    }
    let beside = pjoin([pdirname(found.on_path), "npm"])
    if w.exists_soon(beside) {
      return Ok(beside)
    }
    match find_command_soon(w, "npm", env) {
      Some(n) => Ok(n.on_path)
      None => Err(unable("station.updates.noNpm", args=[("name", js(name))]))
    }
  }
  let by = (program : Result[String, Unable], args : Array[String]) => match program {
    Ok(p) => can(p, args)
    Err(u) => Cannot(u)
  }
  let pkg = "\{kind_package(kind)}@latest"
  // Homebrew has Claude Code and Codex.
  let npm_only = kind == "dsh" || kind == "grok" || kind == "pi"
  if !npm_only && includes(real_path, "/Caskroom/") {
    return by(brew(), ["upgrade", "--cask", if kind == "claude" { "claude-code" } else { "codex" }])
  }
  if !npm_only && includes(real_path, "/Cellar/") {
    return by(brew(), ["upgrade", if kind == "claude" { "claude-code" } else { "codex" }])
  }
  if includes(real_path, "/node_modules/") {
    let at = index_of(real_path, "/lib/node_modules/")
    if at < 0 {
      return Cannot(unable("station.updates.npmRootUnknown", args=[("path", js(real_path))]))
    }
    return by(npm(), ["install", "-g", pkg, "--prefix", slice(found.real, 0, end=at)])
  }
  if kind == "claude" {
    return can(found.on_path, ["update"])
  }
  if npm_only {
    return Cannot(unable("station.updates.codexElsewhere", args=[("path", js(real_path))]))
  }
  if machine.val.codex_standalone && includes(real_path, "/packages/standalone/releases/") {
    return standalone_codex_update(found)
  }
  Cannot(unable("station.updates.codexElsewhere", args=[("path", js(real_path))]))
}

///|
/// Codex's standalone install, updated by its own installer, keeping both the package home and the visible command
/// where this station has them.
fn standalone_codex_update(found : Found) -> HowOr {
  let invalid = Cannot(unable("station.updates.standaloneUnknown", args=[("path", js(found.on_path))]))
  let marker = "/packages/standalone/releases/"
  let at = last_index_of(found.real, marker)
  if at < 0 {
    return invalid
  }
  let home = slice(found.real, 0, end=at)
  let release = slice(found.real, at + marker.length())
  let slash = index_of(release, "/")
  if slash < 0 {
    return invalid
  }
  let binary = slice(release, slash + 1)
  let bin = pdirname(found.on_path)
  let standalone = pjoin([home, "packages/standalone"])
  // Never replace a binary inside an immutable release, or make current/bin link into itself.
  if !(binary == "bin/codex" || binary == "codex") || bin == standalone || starts_with(bin, "\{standalone}/") {
    return invalid
  }
  let script =
    #|set -eu
    #|installer=$(curl -fsSL https://chatgpt.com/codex/install.sh)
    #|CODEX_HOME="$1" CODEX_INSTALL_DIR="$2" CODEX_NON_INTERACTIVE=1 sh -c "$installer" -- --release latest
  can("/bin/sh", ["-c", script, "stillfail-codex-update", home, bin])
}

///|
/// `howToInstallSoon`: how a runtime the machine has not is installed, or why it cannot be from here.
pub async fn how_to_install_soon(w : World, kind : String, env : Env, node : OwnNode?) -> HowOr {
  if kind == "station" {
    return Cannot(unable(""))
  }
  if kind == "hermes" {
    return Cannot(unable("station.updates.hermesExternal"))
  }
  if kind == "claude" {
    return Can(machine.val.claude_install)
  }
  if kind == "agy" {
    return Can(machine.val.agy_install)
  }
  if kind == "devin" {
    return Can(machine.val.devin_install)
  }
  if kind == "dsh" || kind == "grok" {
    return npm_install_soon(w, env, node, ["install", "-g", "\{kind_package(kind)}@latest"], kind_name(kind))
  }
  if kind == "pi" {
    return npm_install_soon(
      w,
      env,
      node,
      ["install", "-g", "--ignore-scripts", "\{kind_package(kind)}@latest"],
      kind_name(kind),
    )
  }
  let args = ["install", "-g", "@openai/codex@latest"]
  match find_command_soon(w, "npm", env) {
    Some(npm) => return can(npm.on_path, args)
    None => ()
  }
  if machine.val.codex_standalone {
    return standalone_codex_install()
  }
  match find_command_soon(w, "brew", env) {
    Some(brew) => return can(brew.on_path, ["install", "--cask", "codex"])
    None => ()
  }
  npm_install_soon(w, env, node, args, kind_name(kind))
}

///|
/// `npmInstallSoon`: npm running `args`: the machine's, else `node`'s (installed first; into that Node, unless `args`
/// give a prefix), else why it cannot be from here.
pub async fn npm_install_soon(w : World, env : Env, node : OwnNode?, args : Array[String], name : String) -> HowOr {
  match find_command_soon(w, "npm", env) {
    Some(npm) => return can(npm.on_path, args)
    None => ()
  }
  match node {
    Some(n) =>
      Can({
        program: pjoin([n.bin, text(get(Some(n.build), "npm")).unwrap_or("")]),
        args: if args.contains("--prefix") { args } else { args + ["--prefix", n.at] },
        node: Some(n),
        no_update: None,
        mark: "",
      })
    None => Cannot(unable("station.updates.noNpmInstall", args=[("name", js(name))]))
  }
}

///|
/// Codex by its own installer where the machine has no npm.
fn standalone_codex_install() -> HowOr {
  let script =
    #|set -eu
    #|installer=$(curl -fsSL https://chatgpt.com/codex/install.sh)
    #|CODEX_NON_INTERACTIVE=1 sh -c "$installer" -- --release latest
  can("/bin/sh", ["-c", script, "stillfail-codex-install"])
}

///|
/// `isNpmInstall`: whether `how` is npm installing a package.
pub fn is_npm_install(how : How) -> Bool {
  let b = @jscase.lower(pbasename(how.program))
  (b == "npm" || b == "npm.cmd") && how.args.length() > 0 && how.args[0] == "install"
}

///|
/// `linkBesideNpm`: after an npm install that left `kind`'s command off the station's PATH: the command as npm put it
/// in its global prefix's bin, linked beside that npm. Whether it was linked.
pub async fn link_beside_npm(w : World, kind : String, how : How, env : Env) -> Bool {
  if !is_npm_install(how) || how.args.contains("--prefix") {
    return false
  }
  let (ok, _, out, _, _) = run_both(w, how.program, ["prefix", "-g"], env, 20000.0, _ => (), "en")
  let lines = split(trim(out), "\n")
  let prefix = trim(lines[lines.length() - 1])
  if !ok || prefix == "" {
    return false
  }
  let with_path = env.copy()
  match with_path.search_by(p => p.0 == "PATH") {
    Some(i) => with_path[i] = ("PATH", pjoin([prefix, "bin"]))
    None => with_path.push(("PATH", pjoin([prefix, "bin"])))
  }
  match find_command_soon(w, kind_command(kind), with_path) {
    None => false
    Some(found) =>
      w.call("platform.linkCommand", [js(found.on_path), js(pdirname(how.program))]) is Bool(true)
  }
}

///|
/// A command that did not end in time.
fn not_finished(message : String) -> Error {
  thrown("NotFinished", message)
}

///|
/// `runLines`: runs a command to its end: whether it succeeded, what it said (stdout and stderr), each line told as it
/// is said; its exit code too (none for a signal), unsigned.
pub async fn run_lines(
  w : World,
  program : String,
  args : Array[String],
  env : Env,
  timeout_ms : Double,
  on_line : async (String) -> Unit,
  lang? : String = "zh",
) -> (Bool, String, Double?) {
  let (ok, said, _, _, code) = run_both(w, program, args, env, timeout_ms, on_line, lang)
  (
    ok,
    said,
    match code {
      Some(c) => Some(if c < 0.0 { c + 4294967296.0 } else { c })
      None => None
    },
  )
}

///|
/// `run`: as `run_lines`; what it said: stdout, then stderr.
pub async fn run(
  w : World,
  program : String,
  args : Array[String],
  env : Env,
  timeout_ms : Double,
  lang? : String = "zh",
) -> (Bool, String) {
  let (ok, _, out, err, _) = run_both(w, program, args, env, timeout_ms, _ => (), lang)
  (ok, out + err)
}

///|
/// Runs a command to its end, out of any repository (the temporary directory) and in its own process group; its
/// environment exactly `env` (with what its shell's PATH adds).
pub async fn run_both(
  w : World,
  program : String,
  args : Array[String],
  given_env : Env,
  timeout_ms : Double,
  on_line : async (String) -> Unit,
  lang : String,
) -> (Bool, String, String, String, Double?) {
  let env = with_shell_command(w, program, given_env)
  let tmp = w.call("os.tmpdir", [])
  let child = w.call("processes.startCommand", [
    js(program),
    jstrs(args),
    jo([("env", env_j(env)), ("cwd", tmp), ("stdio", jstrs(["ignore", "pipe", "pipe"]))]),
  ])
  let timed : @effect.Deferred[Unit] = @effect.Deferred::new()
  let cancel = (w.wall_after)(timeout_ms, fn() { ignore(timed.succeed(())) })
  let mut said = ""
  let whole = ["", ""]
  let carry = ["", ""]
  let take = async fn(which : Int, chunk : String) {
    whole[which] = whole[which] + chunk
    carry[which] = carry[which] + chunk
    while true {
      let at = index_of(carry[which], "\n")
      if at < 0 {
        break
      }
      let line = slice(carry[which], 0, end=at)
      carry[which] = slice(carry[which], at + 1)
      on_line(line)
      said = said + line + "\n"
    }
  }
  let end = async fn(which : Int) {
    if carry[which] != "" {
      on_line(carry[which])
      said = said + carry[which] + "\n"
    }
  }
  for ev in events_of(child) {
    match ev {
      Arr([Str(k), Str(t), ..]) if @jsjson.sanitize_str(k) == "stdout" => take(0, @jsjson.sanitize_str(t))
      Arr([Str(k), Str(t), ..]) if @jsjson.sanitize_str(k) == "stderr" => take(1, @jsjson.sanitize_str(t))
      Arr([Str(k), Str(m), ..]) if @jsjson.sanitize_str(k) == "error" => {
        cancel()
        raise fail(@jsjson.sanitize_str(m))
      }
      Arr([Str(k), code, ..]) if @jsjson.sanitize_str(k) == "close" => {
        end(0)
        end(1)
        cancel()
        let c = match code {
          Num(n) => Some(n)
          _ => None
        }
        return (c == Some(0.0), said, whole[0], whole[1], c)
      }
      _ => ()
    }
  }
  // (it never ends by itself: its deadline ends it)
  timed.wait()
  w.now("processes.endCommand", [js(program), js("SIGKILL")])
  raise not_finished(tr(lang, "station.updates.notFinished", args=jo([("program", js(program))])))
}
