// codex-repair.ts: a Codex copied without its code-mode host cannot use the station's tools. Recognise the native
// executable (including npm's launcher), and only offer to replace a command in the person's home. The old entry is
// kept as a backup.

///|
fn triple_of(target : String) -> String? {
  match target {
    "linux-x64" => Some("x86_64-unknown-linux-musl")
    "linux-arm64" => Some("aarch64-unknown-linux-musl")
    "darwin-x64" => Some("x86_64-apple-darwin")
    "darwin-arm64" => Some("aarch64-apple-darwin")
    _ => None
  }
}

///|
let native_magic : Array[String] = [
  "7f454c46", "feedfacf", "cffaedfe", "feedface", "cefaedfe", "cafebabe", "bebafeca",
]

///|
/// A native executable, not a shell or another package manager's wrapper whose target we cannot know.
async fn native_soon(w : World, path : String) -> Bool {
  match (try w.read_at(path, 4, 0.0) catch { _ => Some(b"") }) {
    Some(b) => b.length() == 4 && native_magic.contains(hex(b))
    None => false
  }
}

///|
/// A file that runs.
async fn executable_soon(w : World, path : String) -> Bool {
  (try {
    w.access(path, mode=1)
    w.stat(path).file
  } catch {
    _ => false
  })
}

///|
/// Whether the code-mode host is beside `binary`.
pub async fn has_codex_host_soon(w : World, binary : String) -> Bool {
  executable_soon(w, pjoin([pdirname(binary), exe("codex-code-mode-host")]))
}

///|
/// The directory of package `name` as Node's resolution finds it from `from` (node_modules up the tree).
async fn platform_package(w : World, from : String, name : String) -> String? {
  let mut dir = pdirname(from)
  while true {
    let at = pjoin([dir, "node_modules"] + split(name, "/"))
    let st = (try Some(w.stat(pjoin([at, "package.json"]))) catch { _ => None })
    if st is Some(s) && s.file {
      return Some(w.realpath_or_null(at).unwrap_or(at))
    }
    if pdirname(dir) == dir {
      return None
    }
    dir = pdirname(dir)
  }
  None
}

///|
/// `codexBinarySoon`: the actual executable behind npm's official launcher, or the native command itself.
pub async fn codex_binary_soon(w : World, found : Found) -> String? {
  if native_soon(w, found.real) {
    return Some(found.real)
  }
  if !ends_with(replace_all(found.real, "\\", "/"), "/node_modules/@openai/codex/bin/codex.js") {
    return None
  }
  guard platform() is Some(target) && triple_of(target) is Some(triple) else { return None }
  guard platform_package(w, found.real, "@openai/codex-\{target}") is Some(binary) else { return None }
  let at = pjoin([binary, "vendor", triple, "bin", exe("codex")])
  if native_soon(w, at) && executable_soon(w, at) {
    w.realpath_or_null(at)
  } else {
    None
  }
}

///|
fn is_word_char(c : Int) -> Bool {
  (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95
}

///|
/// `/^code_mode_host[ \t]+(?!removed\b)[^\r\n]*?[ \t]+true[ \t]*$/m`: what `codex features list` says when it uses
/// the host.
pub fn uses_codex_host(listed : String) -> Bool {
  let lines = split_units(listed, c => c == 10 || c == 13 || c == 0x2028 || c == 0x2029)
  let tab = (c : Int) => c == 32 || c == 9
  for line in lines {
    if !starts_with(line, "code_mode_host") {
      continue
    }
    let r = slice(line, 14)
    let mut i = 0
    while i < r.length() && tab(cu(r, i)) {
      i += 1
    }
    if i == 0 {
      continue
    }
    if i == 1 && starts_with(slice(r, 1), "removed") && (r.length() == 8 || !is_word_char(cu(r, 8))) {
      continue
    }
    let mut e = line.length()
    while e > 0 && tab(cu(line, e - 1)) {
      e -= 1
    }
    let t = slice(line, 0, end=e)
    if !ends_with(t, "true") {
      continue
    }
    let j = t.length() - 5
    if j >= 15 && tab(cu(t, j)) {
      return true
    }
  }
  false
}

///|
/// What the code-mode host is missing for: the native binary and where its host would be.
pub struct Missing {
  binary : String
  helper : String
}

///|
pub fn Missing::to_j(self : Missing) -> J {
  jo([("binary", js(self.binary)), ("helper", js(self.helper))])
}

///|
/// How `codex features list` is read (`missingCodexHost`'s third parameter): its output, none where it failed.
pub type Features = async (String, Env) -> String?

///|
/// The features as Codex says them (`codex features list`).
pub fn codex_features(w : World) -> Features {
  async fn(command, e) {
    (try {
      let (ok, out) = run(w, command, ["features", "list"], e, 20000.0)
      if ok {
        Some(out)
      } else {
        None
      }
    } catch {
      _ => None
    })
  }
}

///|
/// `missingCodexHost`: only flag a missing host when this version says it uses one.
pub async fn missing_codex_host(w : World, found : Found, env : Env, features? : Features) -> Missing? {
  guard codex_binary_soon(w, found) is Some(binary) else { return None }
  let helper = pjoin([pdirname(binary), exe("codex-code-mode-host")])
  if has_codex_host_soon(w, binary) {
    return None
  }
  let listed = (features.unwrap_or(codex_features(w)))(found.on_path, env)
  match listed {
    Some(l) if uses_codex_host(l) => Some({ binary, helper })
    _ => None
  }
}

///|
/// `findMissingCodexHost`: resolve the command the runner will use; an unknown relative path is left for the runner.
pub async fn find_missing_codex_host(w : World, command : String, env : Env) -> Missing? {
  let effective = with_shell_command(w, command, env)
  let mut found : Found? = None
  if pis_absolute(command) {
    match w.realpath_or_null(command) {
      Some(real) => found = Some({ on_path: command, real })
      None => ()
    }
  } else if !(includes(command, "\\") || includes(command, "/")) {
    found = find_command_soon(w, command, effective)
  }
  match found {
    Some(f) => missing_codex_host(w, f, effective)
    None => None
  }
}

///|
/// `canSwitchCodex`: changing a command in a system directory or through a directory link out of the home is not an
/// automatic repair (looked at on the caller's thread).
pub async fn can_switch_codex(w : World, found : Found, env : Env) -> Bool {
  if !machine.val.codex_standalone || !pis_absolute(found.on_path) {
    return false
  }
  guard home_of(env) is Some(home) && home != "" else { return false }
  (try {
    let dir = w.realpath(pdirname(found.on_path), sync=true)
    let home_real = w.realpath(home, sync=true)
    if !within(dir, home_real) {
      return false
    }
    w.access(dir, mode=2, sync=true)
    let entry = w.lstat(found.on_path, sync=true)
    (entry.file || entry.symlink) && w.realpath(found.on_path, sync=true) == found.real
  } catch {
    _ => false
  })
}

///|
/// `canSwitchCodexSoon`: `can_switch_codex` off the station's thread.
pub async fn can_switch_codex_soon(w : World, found : Found, env : Env) -> Bool {
  if !machine.val.codex_standalone || !pis_absolute(found.on_path) {
    return false
  }
  guard home_of(env) is Some(home) && home != "" else { return false }
  (try {
    let dir = w.realpath(pdirname(found.on_path))
    if !within(dir, w.realpath(home)) {
      return false
    }
    w.access(dir, mode=2)
    let entry = w.lstat(found.on_path)
    (entry.file || entry.symlink) && w.realpath(found.on_path) == found.real
  } catch {
    _ => false
  })
}

///|
/// A file's identity: what tells it changed.
pub struct Identity {
  dev : Double
  ino : Double
  size : Double
  mtime_ms : Double
}

///|
fn identity(s : Stat) -> Identity {
  { dev: s.dev, ino: s.ino, size: s.size, mtime_ms: s.mtime_ms }
}

///|
fn same_identity(a : Identity, b : Identity) -> Bool {
  a.dev == b.dev && a.ino == b.ino && a.size == b.size && a.mtime_ms == b.mtime_ms
}

///|
/// The entry and its target as they were before npm ran.
pub struct CodexEntry {
  found : Found
  entry : Identity
  target : Identity
}

///|
/// `captureCodexSoon`: remember the entry and its target before npm runs, so a change made meanwhile is never
/// replaced.
pub async fn capture_codex_soon(w : World, found : Found, env : Env) -> CodexEntry? {
  if !can_switch_codex_soon(w, found, env) {
    return None
  }
  (try {
    let entry = identity(w.lstat(found.on_path))
    let target = identity(w.stat(found.on_path))
    Some({ found, entry, target })
  } catch {
    _ => None
  })
}

///|
async fn random_hex(w : World, n : Int) -> String {
  hex(w.random_bytes(n))
}

///|
/// `switchCodex`: installs the new link only if the entry still names the one checked; the old entry is kept.
pub async fn switch_codex(w : World, captured : CodexEntry, launcher : String, env : Env) -> String {
  let found = captured.found
  if !can_switch_codex(w, found, env) {
    raise fail("Codex command changed or is not writable in the home directory")
  }
  let suffix = random_hex(w, 8)
  let backup = "\{found.on_path}.stillfail-backup-\{suffix}"
  let changed = !same_identity(identity(w.lstat(found.on_path, sync=true)), captured.entry) ||
    !same_identity(identity(w.stat(found.on_path, sync=true)), captured.target) ||
    w.realpath(found.on_path, sync=true) != found.real
  if changed {
    raise fail("Codex command changed while repairing it")
  }
  w.rename(found.on_path, backup, sync=true)
  let switched : Result[String, Error] = try {
    let saved = w.lstat(backup, sync=true)
    let moved = !same_identity(identity(saved), captured.entry) ||
      !same_identity(identity(w.stat(backup, sync=true)), captured.target) ||
      (saved.symlink && w.realpath(backup, sync=true) != found.real)
    if moved {
      raise fail("Codex command changed while repairing it")
    }
    // symlink() fails if someone created an entry while the old one was being moved; it never replaces theirs.
    w.symlink(launcher, found.on_path, sync=true)
    Ok(backup)
  } catch {
    e => Err(e)
  }
  match switched {
    Ok(b) => b
    Err(error) => {
      restore_entry(w, backup, found.on_path) catch {
        _ => raise fail("Codex command could not be restored; its backup is \{backup}")
      }
      raise error
    }
  }
}

///|
/// Link the saved entry back without replacing any command someone created in the meantime.
async fn restore_entry(w : World, backup : String, path : String) -> Unit {
  if w.lstat(backup, sync=true).symlink {
    w.symlink(w.readlink(backup, sync=true), path, sync=true)
  } else {
    w.link(backup, path, sync=true)
  }
  w.rm(backup, sync=true)
}

///|
/// `restoreCodex`: do not overwrite a command someone changed after the switch, even when a later validation fails.
pub async fn restore_codex(w : World, path : String, launcher : String, backup : String) -> Unit {
  let entry = w.lstat(path, sync=true)
  if !entry.symlink || w.readlink(path, sync=true) != launcher {
    raise fail("Codex command changed; its backup is \{backup}")
  }
  let moved = "\{path}.stillfail-failed-\{random_hex(w, 8)}"
  w.rename(path, moved, sync=true)
  let restored : Result[Unit, Error] = try {
    if !same_identity(identity(w.lstat(moved, sync=true)), identity(entry)) || w.readlink(moved, sync=true) != launcher {
      raise fail("Codex command changed while restoring it")
    }
    restore_entry(w, backup, path)
    Ok(())
  } catch {
    e => Err(e)
  }
  match restored {
    Ok(_) => ()
    Err(error) => {
      restore_entry(w, moved, path) catch {
        _ => ()
      }
      raise fail("Codex command could not be restored; its backup is \{backup}: \{message_of(error)}")
    }
  }
  w.rm(moved, sync=true) catch {
    _ => ()
  }
}
