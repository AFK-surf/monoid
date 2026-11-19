// station/src/ops/places.ts (a path walked link by link, never into a folder macOS protects; why a directory or
// file may not be used), shell-path.ts (a shell's PATH read), log-export.ts and telemetry.ts (the log as it may leave
// the machine), self-memory.ts (the station's watch over its own memory), awake.ts (the machine held awake while the
// agents work), heap.ts (a heap snapshot asked for), links.ts (what stands in for a refused link).

// ── places.ts ────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let place_timeout_ms : Double = 5000.0

///|
/// places.ts `Look`: a folder the station may use (`real`), why not, or the protected folder the walk stopped at.
pub(all) enum Look {
  Ok(String)
  Gone
  NotADirectory
  Denied
  Protected(String, String, Bool)
}

///|
pub fn Look::to_json(self : Look) -> Json {
  match self {
    Ok(real) => { "state": "ok", "real": js(real) }
    Gone => { "state": "gone" }
    NotADirectory => { "state": "not_a_directory" }
    Denied => { "state": "denied" }
    Protected(path, top, helper) => { "state": "protected", "path": js(path), "top": js(top), "helper": jb(helper) }
  }
}

///|
fn place_parts(path : String) -> Array[String] {
  split_on(path, "/").filter(p => p != "" && p != ".")
}

///|
fn place_joined(p : Array[String]) -> String {
  "/" + p.join("/")
}

///|
/// places.ts `follow`: `path` with its links followed, a step at a time with lstat, but none at or under a folder
/// `locked` names (its top and whether still.fail Helper opens it), where the walk stops. `cwd` resolves a relative one.
pub fn place_follow(fs : Fs, path : String, cwd : String, locked : (String) -> (String, Bool)?) -> Look raise {
  let mut pending = place_parts(posix_resolve([path], cwd))
  let mut done : Array[String] = []
  let mut hops = 0
  while pending.length() > 0 {
    let name = pending[0]
    pending = pending[1:].to_owned()
    if name == ".." {
      done.pop() |> ignore
      continue
    }
    let next = [..done, name]
    let at = place_joined(next)
    match locked(at) {
      Some((top, helper)) => return Protected(place_joined([..next, ..pending]), top, helper)
      None => ()
    }
    let link = match fs.lstat(at) {
      Some(l) => l.kind == "link"
      None => return Gone
    }
    if !link {
      done = next
      continue
    }
    hops += 1
    if hops > 40 {
      return Gone
    }
    let target = fs.readlink(at).unwrap_or("")
    if starts(target, "/") {
      done = []
    }
    pending = [..place_parts(target), ..pending]
  }
  Ok(place_joined(done))
}

///|
/// places.ts `walk`: `follow`, then, outside them all, stated and listed.
pub fn place_walk(fs : Fs, path : String, cwd : String, locked : (String) -> (String, Bool)?) -> Look raise {
  let found = place_follow(fs, path, cwd, locked)
  guard found is Ok(real) else { return found }
  match fs.kind(real) {
    None => Gone
    Some("dir") => if fs.names(real) is None { Denied } else { found }
    Some(_) => NotADirectory
  }
}

///|
/// places.ts `#refused`'s words: why a directory or file may not be used, in `asker`'s words (an agent's English).
pub fn place_refused(
  catalog : Catalog,
  code : String,
  path : String,
  lang : String,
  agent : Bool,
  timeout_ms : Double,
  machine : String,
  unreadable : (String, String) -> String,
) -> String {
  let lang = if agent { "en" } else { lang }
  if code == "denied" {
    return unreadable(lang, path)
  }
  if code == "timeout" {
    return tr(catalog, lang, "station.place.timeout", {
      "cwd": js(path),
      "seconds": jn((timeout_ms / 1000.0).ceil()),
      "machine": js(machine),
    })
  }
  let key = match code {
    "gone" => "station.place.gone"
    "not_a_directory" => "station.place.notDir"
    "not_a_file" => "station.place.notFile"
    _ => "station.place.tooLarge"
  }
  tr(catalog, lang, key, { "cwd": js(path) })
}

///|
/// places.ts `#needs`'s words: still.fail Helper lacks the grant for `top` (its window `up`, `closed` or `none`).
pub fn place_needs(
  catalog : Catalog,
  grant : String,
  top : String,
  window : String,
  path : String,
  lang : String,
  agent : Bool,
  machine : String,
) -> String {
  let lang = if agent { "en" } else { lang }
  let key = if window == "up" {
    "station.place.grant"
  } else if window == "closed" {
    "station.place.grantClosed"
  } else {
    "station.place.grantNone"
  }
  let words = tr(catalog, lang, key, {
    "folder": js(tr(catalog, lang, "station.helper.window." + grant, Map([]))),
    "top": js(top),
    "cwd": js(path),
    "machine": js(machine),
  })
  if agent {
    words +
    " Ask a person for it: call the permissions tool with request=\{grant}, post what it says with chat_post kind=need_human and end your turn; try again once it is granted."
  } else {
    words
  }
}

///|
/// places.ts `#child`'s answer: the child's last line, as JSON (None where it is none).
pub fn place_answer(stdout : String) -> Json? {
  let lines = split_on(js_trim(stdout), "\n")
  js_parse(lines[lines.length() - 1])
}

///|
/// places.ts `#protectedDir`'s reading of a child's answer about a folder: what it is, or the failure's words.
pub fn place_dir_answer(answer : Json, dir : String) -> Result[Look, String] {
  match (str_field(answer, "state"), field(answer, "real")) {
    (Some("ok"), Some(String(real))) => Ok(Ok(real))
    (Some("gone"), _) => Ok(Gone)
    (Some("not_a_directory"), _) => Ok(NotADirectory)
    (Some("denied"), _) => Ok(Denied)
    _ => {
      let e = match field(answer, "error") {
        Some(Null) | None => "no answer"
        Some(v) => arg_text(v)
      }
      Err("couldn't check \{dir}: \{e}")
    }
  }
}

///|
/// places.ts `#copy`'s reading of a child's answer about a file copied: `ok`, or the refusal's code.
pub fn place_copy_answer(answer : Json) -> String {
  match str_field(answer, "state") {
    Some("ok") => "ok"
    Some("not_a_file") => "not_a_file"
    Some("too_large") => "too_large"
    Some("denied") => "denied"
    _ => "gone"
  }
}

///|
/// places.ts `machine`: the host's name without `.local`.
pub fn place_machine(hostname : String) -> String {
  if ends(hostname, ".local") {
    sub(hostname, 0, hostname.length() - 6)
  } else {
    hostname
  }
}

///|
/// places.ts `#once`'s key: one look at a time for the same path, asked the same way.
pub fn place_look_key(path : String, lang : String, agent : Bool, self_ : Bool) -> String {
  (if self_ { "self" } else { "dir" }) + ":" + (if agent { "agent" } else { lang }) + ":" + path
}

// ── shell-path.ts ────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let shell_keep_ms : Double = 30000.0

///|
pub let shell_probe_ms : Double = 8000.0

///|
pub let shell_max_output : Int = 262144

///|
/// shell-path.ts `probeEnv`: the environment without credentials.
pub fn probe_env(env : Array[(String, String)]) -> Array[(String, String)] {
  env.filter(p => {
    let u = upper(p.0)
    let credential = has(u, "TOKEN") ||
      has(u, "SECRET") ||
      has(u, "PASSWORD") ||
      has(u, "AUTH") ||
      key_word(u)
    !credential && p.0 != "CODEX_HOME" && p.0 != "CLAUDE_CONFIG_DIR"
  })
}

///|
/// `(^|_)KEY($|_)`.
fn key_word(u : String) -> Bool {
  let mut from = 0
  while true {
    let at = index_of(u, "KEY", from~)
    if at < 0 {
      return false
    }
    let before = at == 0 || cu(u, at - 1) == 95
    let after = at + 3 == u.length() || cu(u, at + 3) == 95
    if before && after {
      return true
    }
    from = at + 1
  }
  false
}

///|
/// shell-path.ts `readShellPath`'s command: the shell's arguments.
pub fn shell_probe_args(login : Bool) -> Array[String] {
  ["-i", ..(if login { ["-l"] } else { [] }), "-c", "\"$STILLFAIL_SHELL_NODE\" -e \"$STILLFAIL_SHELL_CODE\""]
}

///|
/// shell-path.ts `readShellPath`'s reading of what the shell said: the marked line's directories (base64 JSON),
/// None where there is none, it ended badly, or it said too much.
pub fn shell_path_of(output : String, marker : String, code : Int) -> Array[String]? {
  if code != 0 || utf8_len(output) > shell_max_output {
    return None
  }
  let line = split_lines(output).search_by(s => starts(s, marker)).map(i => split_lines(output)[i])
  guard line is Some(l) else { return None }
  let decoded = try @base64.decode(sub(l, marker.length(), l.length())) catch {
    _ => return None
  }
  match js_parse(@utf8.decode_lossy(decoded)) {
    Some(Array(a)) =>
      if a.iter().all(x => x is String(_)) {
        Some(a.filter_map(x => match x { String(t) => Some(t); _ => None }))
      } else {
        None
      }
    _ => None
  }
}

///|
/// shell-path.ts `kept`'s key: what is read again only after KEEP_MS, by its parts and environment (sorted by name).
pub fn shell_kept_key(parts : Array[Json], env : Array[(String, String)]) -> String {
  let clean = probe_env(env)
  let sorted = stable_sort(clean, (a, b) => locale_compare(a.0, b.0))
  let all = [..parts, Json::array(sorted.map(p => Json::array([js(p.0), js(p.1)])))]
  @cloud_net.sha256_hex(js_stringify(Json::array(all)))
}

///|
/// `a.localeCompare(b)` for the names of environment variables (letters, digits and `_`): case aside first, then
/// small before capital, as ICU's root collation orders them.
fn locale_compare(a : String, b : String) -> Int {
  @jsjson.locale_compare(a, b)
}

///|
/// shell-path.ts `withShellCommand`: where `name` is found: on PATH as given (`given`), with the registry's saved PATH
/// after it (`saved`), or with a shell's (`shell`, non-login then login); the environment to run it with.
pub fn with_shell_command(
  name : String,
  env : Array[(String, String)],
  found : (Array[(String, String)]) -> Bool,
  saved : Array[String]?,
  append : (Array[(String, String)], String) -> Unit,
  shell : String?,
  shell_dirs : (Bool) -> Array[String]?,
  prepend : (Array[(String, String)], String) -> Array[(String, String)],
) -> Array[(String, String)] {
  if has(name, "/") || has(name, "\\") || found(env) {
    return env
  }
  match saved {
    Some(dirs) => {
      let candidate = env.copy()
      for d in dirs {
        append(candidate, d)
      }
      if found(candidate) {
        return candidate
      }
    }
    None => ()
  }
  guard shell is Some(s) && s != "" else { return env }
  for login in [false, true] {
    match shell_dirs(login) {
      None => continue
      Some(dirs) => {
        let mut candidate = env
        let mut i = dirs.length() - 1
        while i >= 0 {
          candidate = prepend(candidate, dirs[i])
          i -= 1
        }
        if found(candidate) {
          return candidate
        }
      }
    }
  }
  env
}

// ── telemetry.ts and log-export.ts ───────────────────────────────────────────────────────────────────────────────

///|
fn not_path_unit(c : Int) -> Bool {
  // `[^/\s:'"()]`
  !(c == 47 || js_space(c) || c == 58 || c == 39 || c == 34 || c == 40 || c == 41)
}

///|
/// telemetry.ts `scrubPaths`: home directories (this user's and anyone's) as ~.
pub fn scrub_paths(text : String, home : String) -> String {
  let own = if home != "" && home != "/" { split_on(text, home).join("~") } else { text }
  // Windows' first: `[A-Za-z]:(?:\\\\|\\|\/)Users(?:\\\\|\\|\/)[^\\/\s:'"()]+`.
  let sep_len = (s : String, i : Int) => if i + 1 < s.length() && cu(s, i) == 92 && cu(s, i + 1) == 92 {
    2
  } else if i < s.length() && (cu(s, i) == 92 || cu(s, i) == 47) {
    1
  } else {
    0
  }
  let b = StringBuilder()
  let n = own.length()
  let mut i = 0
  while i < n {
    if i + 1 < n && is_alpha(cu(own, i)) && cu(own, i + 1) == 58 {
      let s1 = sep_len(own, i + 2)
      if s1 > 0 && starts(sub(own, i + 2 + s1, n), "Users") {
        let k = i + 2 + s1 + 5
        let s2 = sep_len(own, k)
        if s2 > 0 {
          let mut e = k + s2
          while e < n && not_path_unit(cu(own, e)) && cu(own, e) != 92 {
            e += 1
          }
          if e > k + s2 {
            b.write_string("~")
            i = e
            continue
          }
        }
      }
    }
    b.write_char(Int::unsafe_to_char(cu(own, i)))
    i += 1
  }
  let win = b.to_string()
  // `\/(?:Users|home)\/([^/\s:'"()]+)`
  let c = StringBuilder()
  let m = win.length()
  let mut j = 0
  while j < m {
    if cu(win, j) == 47 {
      let rest = sub(win, j + 1, m)
      let w = if starts(rest, "Users/") { 6 } else if starts(rest, "home/") { 5 } else { 0 }
      if w > 0 {
        let mut e = j + 1 + w
        while e < m && not_path_unit(cu(win, e)) {
          e += 1
        }
        if e > j + 1 + w {
          c.write_string("~")
          j = e
          continue
        }
      }
    }
    c.write_char(Int::unsafe_to_char(cu(win, j)))
    j += 1
  }
  c.to_string()
}

///|
/// telemetry.ts `scrubMessage`: without the text it quoted.
pub fn scrub_message(text : String, home : String) -> String {
  let chars = scrub_paths(text, home).iter().collect()
  let close_of = (c : Char) => match c {
    '"' => Some('"')
    '\'' => Some('\'')
    '`' => Some('`')
    '“' => Some('”')
    '「' => Some('」')
    _ => None
  }
  let b = StringBuilder()
  let mut i = 0
  while i < chars.length() {
    match close_of(chars[i]) {
      Some(close) => {
        let mut end = -1
        for k in (i + 1)..<chars.length() {
          if chars[k] == close {
            end = k
            break
          }
        }
        if end >= 0 {
          b.write_char(chars[i])
          b.write_char('…')
          b.write_char(close)
          i = end + 1
          continue
        }
      }
      None => ()
    }
    b.write_char(chars[i])
    i += 1
  }
  b.to_string()
}

///|
/// telemetry.ts `ErrorReports.report`'s event (its time and anonymous id given).
pub fn error_event(
  log : String,
  error : String?,
  station : String?,
  anonymous : String,
  release : String?,
  home : String,
  now : Double,
) -> Json {
  {
    "event": "$exception",
    "distinct_id": js(
      match station {
        Some(s) => "station:" + s
        None => anonymous
      },
    ),
    "timestamp": js(iso_time(now)),
    "properties": {
      "$exception_list": [
        {
          "type": "Error",
          "value": js(scrub_message(error.unwrap_or(log), home)),
          "mechanism": { "handled": true, "synthetic": false },
        },
      ],
      "log": js(scrub_paths(log, home)),
      "station": opt_s(station),
      "release": opt_s(release),
      "$process_person_profile": false,
      "$lib": "stillfail-station",
    },
  }
}

///|
/// telemetry.ts `builtKey`: posthog.json's key, where it reads as one.
pub fn built_key(text : String?) -> Json {
  match text {
    Some(t) =>
      match js_parse(t) {
        Some(v) =>
          match (str_field(v, "host"), str_field(v, "key"), str_field(v, "release")) {
            (Some(h), Some(k), Some(r)) => { "host": js(h), "key": js(k), "release": js(r) }
            _ => Json::null()
          }
        None => Json::null()
      }
    None => Json::null()
  }
}

///|
pub let log_max_value : Int = 2000

///|
/// `[^\s@"'`<>()=,;:]`.
fn email_unit(c : Int) -> Bool {
  !(js_space(c) ||
  c == 64 ||
  c == 34 ||
  c == 39 ||
  c == 96 ||
  c == 60 ||
  c == 62 ||
  c == 40 ||
  c == 41 ||
  c == 61 ||
  c == 44 ||
  c == 59 ||
  c == 58)
}

///|
/// log-export.ts `EMAIL`: `/[^\s@"'`<>()=,;:]+@[^\s@"'`<>()=,;:]+\.[A-Za-z]{2,}/g` as `<email>`.
fn scrub_emails(s : String) -> String {
  let b = StringBuilder()
  let n = s.length()
  let mut done = 0
  let mut i = 0
  while i < n {
    if cu(s, i) == 64 && i > done {
      // The local part: back as far as it goes (not before what was written).
      let mut a = i
      while a > done && email_unit(cu(s, a - 1)) {
        a -= 1
      }
      // The domain: as far as it goes, then back to its last `.` with two letters or more after it.
      let mut e = i + 1
      while e < n && email_unit(cu(s, e)) {
        e += 1
      }
      if a < i && e > i + 1 {
        // `[^…]+\.[A-Za-z]{2,}`: greedy, so the last `.` from which letters run to some point; the letters as many as
        // run there.
        let mut best = -1
        let mut k = e - 1
        while k > i + 1 {
          if cu(s, k) == 46 {
            let mut l = k + 1
            while l < n && is_alpha(cu(s, l)) {
              l += 1
            }
            if l - k - 1 >= 2 {
              best = l
              break
            }
          }
          k -= 1
        }
        if best > 0 {
          b.write_string(sub(s, done, a))
          b.write_string("<email>")
          done = best
          i = best
          continue
        }
      }
    }
    i += 1
  }
  b.write_string(sub(s, done, n))
  b.to_string()
}

///|
/// log-export.ts `EMAIL_SLUG`: `/\b[\w.+]+-(?:[a-z0-9]+-)*(?:com|net|org|me|io|cn|dev|ai|co|app)\b/gi` as `<email>`.
fn scrub_email_slugs(s : String) -> String {
  let tlds = ["com", "net", "org", "me", "io", "cn", "dev", "ai", "co", "app"]
  let slug_unit = (c : Int) => is_word(c) || c == 46 || c == 43
  let b = StringBuilder()
  let n = s.length()
  let mut done = 0
  let mut i = 0
  while i < n {
    // A match starts at a word boundary with a run of `[\w.+]`.
    if slug_unit(cu(s, i)) && boundary(s, i) {
      // The longest match from here (greedy runs, backing off): try each dash after the first run as the split.
      let mut end = -1
      let mut r = i
      while r < n && slug_unit(cu(s, r)) {
        r += 1
      }
      // `[\w.+]+` greedy: the first part ends at some dash at or before r (backing off over the run).
      let mut first_end = r
      while first_end > i && end < 0 {
        if first_end < n && cu(s, first_end) == 45 {
          // After the dash: `(?:[a-z0-9]+-)*` then a tld, then `\b`.
          end = slug_tail(s, first_end + 1, tlds)
        }
        first_end -= 1
      }
      if end > 0 {
        b.write_string(sub(s, done, i))
        b.write_string("<email>")
        done = end
        i = end
        continue
      }
    }
    i += 1
  }
  b.write_string(sub(s, done, n))
  b.to_string()
}

///|
/// From `at`: `(?:[a-z0-9]+-)*(?:tld)\b` (case aside), where the longest match ends; -1 where none.
fn slug_tail(s : String, at : Int, tlds : Array[String]) -> Int {
  let n = s.length()
  // Greedy: as many `[a-z0-9]+-` groups as can be taken, backing off.
  let starts_at = [at]
  let mut k = at
  while true {
    let mut e = k
    while e < n && is_alnum(cu(s, e)) {
      e += 1
    }
    if e > k && e < n && cu(s, e) == 45 {
      k = e + 1
      starts_at.push(k)
    } else {
      break
    }
  }
  let mut g = starts_at.length() - 1
  while g >= 0 {
    let p = starts_at[g]
    for t in tlds {
      if lower(sub(s, p, p + t.length())) == t && boundary(s, p + t.length()) {
        return p + t.length()
      }
    }
    g -= 1
  }
  -1
}

///|
/// log-export.ts `SECRET`: JWTs, keys and tokens by their prefixes, AWS keys, as `<secret>`.
fn scrub_secrets(s : String) -> String {
  let token_unit = (c : Int) => is_word(c) || c == 45
  let prefixes = ["sk", "pk", "rk", "ghp", "gho", "ghs", "ghu", "github_pat", "xoxa", "xoxb", "xoxp", "xoxr", "glpat"]
  let b = StringBuilder()
  let n = s.length()
  let mut done = 0
  let mut i = 0
  while i < n {
    if boundary(s, i) && i < n && is_word(cu(s, i)) {
      let rest = sub(s, i, n)
      // `eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]*`
      if starts(rest, "eyJ") {
        let mut e = i + 3
        while e < n && token_unit(cu(s, e)) {
          e += 1
        }
        if e - i - 3 >= 8 && e < n && cu(s, e) == 46 {
          let mut f = e + 1
          while f < n && token_unit(cu(s, f)) {
            f += 1
          }
          if f - e - 1 >= 8 && f < n && cu(s, f) == 46 {
            let mut g = f + 1
            while g < n && token_unit(cu(s, g)) {
              g += 1
            }
            b.write_string(sub(s, done, i))
            b.write_string("<secret>")
            done = g
            i = g
            continue
          }
        }
      }
      // `(?:prefix)[-_][\w-]{16,}`
      let mut hit = -1
      for p in prefixes {
        if starts(rest, p) && i + p.length() < n && (cu(s, i + p.length()) == 45 || cu(s, i + p.length()) == 95) {
          let mut e = i + p.length() + 1
          while e < n && token_unit(cu(s, e)) {
            e += 1
          }
          if e - i - p.length() - 1 >= 16 {
            hit = e
            break
          }
        }
      }
      // `AKIA[0-9A-Z]{16}\b`
      if hit < 0 && starts(rest, "AKIA") && rest.length() >= 20 && upper_digits(sub(rest, 4, 20)) && boundary(s, i + 20) {
        hit = i + 20
      }
      if hit > 0 {
        b.write_string(sub(s, done, i))
        b.write_string("<secret>")
        done = hit
        i = hit
        continue
      }
    }
    i += 1
  }
  b.write_string(sub(s, done, n))
  b.to_string()
}

///|
/// log-export.ts `scrubText`: a piece of the log as it may leave the machine.
pub fn scrub_text(text : String, home : String) -> String {
  let cut = if text.length() > log_max_value { sub(text, 0, log_max_value) + "…" } else { text }
  scrub_message(scrub_email_slugs(scrub_emails(scrub_secrets(cut))), home)
}

///|
let written_fields : Array[String] = ["text", "name", "title", "command", "args", "prompt", "body", "question", "content"]

///|
/// `/^[0-9A-HJKMNP-TV-Z]{26}$/`: a workspace's id.
fn workspace_id(s : String) -> Bool {
  s.length() == 26 &&
  all_units(s, c => is_digit(c) ||
    (is_upper(c) && c != 73 && c != 76 && c != 79 && c != 85))
}

///|
/// log-export.ts `scrubValue`.
pub fn scrub_value(key : String, value : Json, home : String) -> Json {
  if written_fields.contains(key) {
    return js("…")
  }
  match value {
    String(s) if key == "workspace" && !workspace_id(s) => js("…")
    String(s) => js(scrub_text(s, home))
    Array(a) => Json::array(a.map(v => scrub_value("", v, home)))
    Object(m) => {
      let out : Map[String, Json] = Map([])
      for k, v in m {
        out[k] = scrub_value(k, v, home)
      }
      Json::object(out)
    }
    _ => value
  }
}

///|
/// log-export.ts `attribute`.
pub fn attribute(key : String, value : Json) -> Json {
  let v : Json = match value {
    Number(n, ..) if is_safe_integer(n) => { "intValue": js(num_text(n)) }
    Number(n, ..) => { "doubleValue": jn(n) }
    True | False => { "boolValue": value }
    String(s) => { "stringValue": js(s) }
    _ => { "stringValue": js(js_stringify(value)) }
  }
  { "key": js(key), "value": v }
}

///|
/// log-export.ts `record`: a line as an OpenTelemetry log record, scrubbed.
pub fn log_record(ms : Double, level : String, at : String, message : String, fields : Json, home : String) -> Json {
  let attrs = [attribute("log.target", js(at))]
  match fields {
    Object(m) =>
      for k, v in m {
        attrs.push(attribute("log." + k, scrub_value(k, v, home)))
      }
    _ => ()
  }
  let severity = match level {
    "INFO" => 9
    "WARN" => 13
    _ => 17
  }
  let record : Map[String, Json] = {
    "timeUnixNano": js(nanos(js_round(ms))),
    "severityNumber": ji(severity),
    "severityText": js(level),
    "body": { "stringValue": js(scrub_text(message, home)) },
    "attributes": Json::array(attrs),
  }
  // (a trace's id, as OpenTelemetry has it on the record: its span's lines found by it; `log.trace` stays)
  match fields {
    Object(m) =>
      match m.get("trace") {
        Some(String(t)) if trace_id(t) => record["traceId"] = js(t)
        _ => ()
      }
    _ => ()
  }
  Json::object(record)
}

///|
/// log-export.ts `TRACE_ID`: 32 lowercase hex digits, not all zero.
fn trace_id(t : String) -> Bool {
  if t.length() != 32 {
    return false
  }
  let mut zero = true
  for c in t {
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      return false
    }
    if c != '0' {
      zero = false
    }
  }
  !zero
}

///|
/// `(BigInt(ms) * 1_000_000n).toString()`.
fn nanos(ms : Double) -> String {
  let t = num_text(ms)
  if t == "0" || t == "-0" {
    "0"
  } else if starts(t, "-") {
    "-" + sub(t, 1, t.length()) + "000000"
  } else {
    t + "000000"
  }
}

///|
/// A line of the log as the export keeps it.
pub(all) struct LogLine {
  ms : Double
  level : String
  at : String
  message : String
  fields : Json
}

///|
fn log_line_of(j : Json) -> LogLine {
  {
    ms: num_field(j, "ms").unwrap_or(0.0),
    level: str_or(j, "level", "INFO"),
    at: str_or(j, "at", ""),
    message: str_or(j, "message", ""),
    fields: field(j, "fields").unwrap_or(Json::object(Map([]))),
  }
}

///|
pub let log_max_waiting : Int = 5000

///|
pub let log_max_batch : Int = 500

///|
/// log-export.ts `LogExport`: lines kept waiting, sent a batch at a time.
pub struct LogExport {
  home : String
  mut waiting : Array[LogLine]
  mut dropped : Int
  mut closed : Bool
  mut configured : Bool
  /// What the batches say of the station beside its id and version (log-export.ts `os`, `arch`, `runtime`, `role`).
  mut described : Array[(String, String)]
}

///|
pub fn LogExport::new(home : String) -> LogExport {
  { home, waiting: [], dropped: 0, closed: false, configured: false, described: [] }
}

///|
/// log-export.ts `LogExportOptions`' `os`, `arch`, `runtime` and `role`: what each batch says the station runs on and
/// is (a whole station or a rig).
pub fn LogExport::describe(self : LogExport, os~ : String, arch~ : String, runtime~ : String, role~ : String) -> Unit {
  self.described = [("os.type", os), ("host.arch", arch), ("process.runtime.name", runtime), ("stillfail.role", role)]
}

///|
/// log-export.ts `shutdown`: nothing taken after it.
pub fn LogExport::close(self : LogExport) -> Unit {
  self.closed = true
}

///|
/// log-export.ts `add`.
pub fn LogExport::add(self : LogExport, line : LogLine, enabled : Bool) -> Unit {
  if self.closed || !self.configured || !enabled {
    return
  }
  self.waiting.push(line)
  self.trim()
}

///|
/// log-export.ts `trim`: past what is kept waiting the oldest INFO lines go first, the oldest of the rest only once none
/// is left.
fn LogExport::trim(self : LogExport) -> Unit {
  let mut over = self.waiting.length() - log_max_waiting
  if over <= 0 {
    return
  }
  self.dropped += over
  let kept = []
  for line in self.waiting {
    if over > 0 && line.level == "INFO" {
      over -= 1
    } else {
      kept.push(line)
    }
  }
  self.waiting = if over > 0 { kept[over:].to_owned() } else { kept }
}

///|
/// log-export.ts `body`: the batch of `lines` as it is sent.
pub fn LogExport::body(
  self : LogExport,
  lines : Array[LogLine],
  station : String,
  dropped : Int,
  version : String,
  now : Double,
) -> String {
  let records = lines.map(l => log_record(l.ms, l.level, l.at, l.message, l.fields, self.home))
  if dropped > 0 {
    records.push(
      log_record(now, "WARN", "telemetry", "log lines dropped before they could be sent", { "dropped": ji(dropped) }, self.home),
    )
  }
  let resource = [
    attribute("service.name", js("stillfail-station")),
    attribute("service.version", js(version)),
    attribute("stillfail.station", js(station)),
  ]
  for d in self.described {
    resource.push(attribute(d.0, js(d.1)))
  }
  js_stringify({
    "resourceLogs": [
      {
        "resource": { "attributes": Json::array(resource) },
        "scopeLogs": [{ "scope": { "name": "stillfail-station" }, "logRecords": Json::array(records) }],
      },
    ],
  })
}

///|
/// log-export.ts `refused`: a batch the control plane refused (4xx but 429) is not sent again.
pub fn log_refused(status : Double?) -> Bool {
  match status {
    Some(s) => s >= 400.0 && s < 500.0 && s != 429.0
    None => false
  }
}

///|
/// log-export.ts `configure`: lines are kept from now on.
pub fn LogExport::configure(self : LogExport) -> Unit {
  self.configured = true
}

///|
/// log-export.ts `sendAll`: what waits sent, a batch at a time (`send` the status it failed with, 0 for no answer;
/// None where it went). The bodies sent, in order.
pub fn LogExport::send_all(
  self : LogExport,
  enabled : Bool,
  station : String?,
  version : String,
  now : Double,
  send : (String) -> Double?,
) -> Array[String] {
  let sent = []
  while self.waiting.length() > 0 {
    if !self.configured || !enabled {
      self.waiting = []
      self.dropped = 0
      return sent
    }
    guard station is Some(st) else { return sent }
    let n = @cmp.minimum(log_max_batch, self.waiting.length())
    let lines = self.waiting[0:n].to_owned()
    self.waiting = self.waiting[n:].to_owned()
    let dropped = self.dropped
    self.dropped = 0
    let body = self.body(lines, st, dropped, version, now)
    sent.push(body)
    match send(body) {
      None => ()
      Some(status) => {
        if !log_refused(Some(status)) {
          self.waiting = [..lines, ..self.waiting]
          self.dropped += dropped
          self.trim()
        }
        return sent
      }
    }
  }
  sent
}

// ── self-memory.ts ───────────────────────────────────────────────────────────────────────────────────────────────

///|
let gib : Double = 1073741824.0

///|
fn clamp(n : Double, low : Double, high : Double) -> Double {
  if n < low {
    low
  } else if n > high {
    high
  } else {
    n
  }
}

///|
/// self-memory.ts `softLimitOf`.
pub fn soft_limit_of(total : Double) -> Double {
  clamp((total * 0.2).floor(), 2.0 * gib, 6.0 * gib)
}

///|
/// self-memory.ts `hardRssOf`.
pub fn hard_rss_of(total : Double) -> Double {
  clamp((total * 0.3).floor(), 3.0 * gib, 8.0 * gib)
}

///|
/// self-memory.ts `hardFrontOf`.
pub fn hard_front_of(total : Double) -> Double {
  clamp((total * 0.1).floor(), 1.0 * gib, 3.0 * gib)
}

///|
pub let self_sample_ms : Double = 30000.0

///|
pub let self_relief_ms : Double = 60000.0

///|
pub let self_sustained : Int = 3

///|
pub let self_startup_ms : Double = 600000.0

///|
pub let heap_most : Double = 2.5 * 1073741824.0

///|
/// self-memory.ts `SelfMemoryGovernor`: what each sample does, by the memory it is told.
pub struct SelfMemory {
  soft : Double
  hard_rss : Double
  hard_heap : Double
  hard_front : Double
  started_at : Double
  sustained : Int
  startup_ms : Double
  relief_ms : Double
  mut last_relief : Double?
  mut over : Int
  mut front_over : Int
  mut handed_over : Bool
}

///|
pub fn SelfMemory::new(total : Double, started_at : Double, o : Json) -> SelfMemory {
  {
    soft: num_field(o, "softBytes").unwrap_or(soft_limit_of(total)),
    hard_rss: num_field(o, "hardRssBytes").unwrap_or(hard_rss_of(total)),
    hard_heap: num_field(o, "hardHeapBytes").unwrap_or(heap_most),
    hard_front: num_field(o, "hardFrontBytes").unwrap_or(hard_front_of(total)),
    started_at,
    sustained: num_field(o, "sustained").map(n => n.to_int()).unwrap_or(self_sustained),
    startup_ms: num_field(o, "startupMs").unwrap_or(self_startup_ms),
    relief_ms: num_field(o, "reliefMs").unwrap_or(self_relief_ms),
    last_relief: None,
    over: 0,
    front_over: 0,
    handed_over: false,
  }
}

///|
/// A sample: what it is told (Node's rss and heap used, its programs' bytes, the front's, the machine's pressure),
/// what it can ask (let go what is idle: how many; the idle sessions' processes: how many; the launcher: whether there
/// is one, and whether asking it failed; the front's restart, where given). Its verdict, as self-memory.ts `SelfVerdict`.
pub fn SelfMemory::sample(
  self : SelfMemory,
  now : Double,
  node_rss : Double,
  heap_used : Double,
  children : Double,
  front : Double?,
  pressure : String?,
  trim_idle : () -> Double,
  evict_warm : (() -> Double)?,
  restart_front : Bool,
  handover : Bool,
  handover_fails : Bool,
) -> Json {
  let whole = node_rss + children
  let mut trimmed : Double? = None
  let mut evicted : Double? = None
  let mut handed : String? = None
  let mut front_said : String? = None
  let pressed = pressure == Some("high") || pressure == Some("critical")
  let relief_due = match self.last_relief {
    None => true
    Some(l) => now - l >= self.relief_ms
  }
  if (pressed || whole + front.unwrap_or(0.0) > self.soft) && relief_due {
    self.last_relief = Some(now)
    trimmed = Some(trim_idle())
    if pressed {
      match evict_warm {
        Some(f) => evicted = Some(f())
        None => ()
      }
    }
  }
  let started = now - self.started_at >= self.startup_ms
  self.front_over = match front {
    Some(f) if f > self.hard_front => self.front_over + 1
    _ => 0
  }
  if self.front_over >= self.sustained && started {
    self.front_over = 0
    front_said = Some(if restart_front { "asked" } else { "said" })
  }
  self.over = if whole > self.hard_rss || heap_used > self.hard_heap { self.over + 1 } else { 0 }
  if !(self.handed_over || self.over < self.sustained || !started) {
    self.over = 0
    if !handover {
      trimmed = Some(trim_idle())
      handed = Some("none")
    } else {
      self.handed_over = true
      if handover_fails {
        self.handed_over = false
      }
      handed = Some("asked")
    }
  }
  {
    "trimmed": opt_n(trimmed),
    "evictedWarm": opt_n(evicted),
    "handover": opt_s(handed),
    "front": opt_s(front_said),
  }
}

// ── awake.ts ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let awake_every_ms : Double = 20000.0

///|
pub let awake_linger_ms : Double = 60000.0

///|
pub let awake_job_span_ms : Double = 7200000.0

///|
/// awake.ts `working`: whether the station has work going at `now`, from what its store says: a turn running; a
/// recorded wait (`await_wait`: None where the store keeps none); the jobs (`jobs`: those that are work: each its
/// session and start); the last turns of the sessions asked (each its declared state, its end, its wait in seconds).
pub fn awake_working(
  any_running : Bool,
  awake_wait : Bool?,
  jobs : Array[(String, Double)],
  live : Array[String],
  last_turns : (Array[String]) -> Array[(String, String?, Double?, Double?)],
  now : Double,
) -> Bool {
  if any_running {
    return true
  }
  if awake_wait == Some(true) {
    return true
  }
  let keys = if awake_wait is None { live } else { [] }
  let asked = [..keys, ..jobs.map(j => j.0)]
  let turns = last_turns(asked)
  for t in turns {
    let (_, declared, ended, wait) = t
    match (declared, ended) {
      (Some("waiting"), Some(e)) if now < e + wait.unwrap_or(0.0) * 1000.0 + awake_linger_ms => return true
      _ => ()
    }
  }
  jobs.iter().any(j => {
    let since = match turns.search_by(t => t.0 == j.0) {
      Some(k) => turns[k].2.unwrap_or(now)
      None => j.1
    }
    now - since < awake_job_span_ms
  })
}

///|
/// awake.ts `Awake`: the machine held while there is work, and a minute after.
pub struct Awake {
  mut last_work : Double
  mut held : Bool
  mut unheld_said : Bool
}

///|
pub fn Awake::new() -> Awake {
  { last_work: @double.neg_infinity, held: false, unheld_said: false }
}

///|
/// awake.ts `check`: what it does now (`hold`, `release`, `cannot`, or nothing), `can_hold` whether the machine has a
/// way to be held.
pub fn Awake::check(self : Awake, now : Double, working : Bool, can_hold : Bool) -> String? {
  if working {
    self.last_work = now
  }
  let wanted = now - self.last_work < awake_linger_ms
  if wanted && !self.held {
    if can_hold {
      self.held = true
      Some("hold")
    } else if !self.unheld_said {
      self.unheld_said = true
      Some("cannot")
    } else {
      None
    }
  } else if !wanted && self.held {
    self.held = false
    Some("release")
  } else {
    None
  }
}

// ── heap.ts ──────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// heap.ts `SNAPSHOT`: `/^heap-.*\.heapsnapshot$/`.
pub fn heap_snapshot_name(name : String) -> Bool {
  starts(name, "heap-") &&
  ends(name, ".heapsnapshot") &&
  name.length() >= 18 &&
  !any_unit(sub(name, 5, name.length() - 13), c => c == 10 || c == 13 || c == 0x2028 || c == 0x2029)
}

///|
/// heap.ts's snapshot's name at `now`.
pub fn heap_snapshot_path(dir : String, now : Double) -> String {
  let t = iso_time(now).replace_all(old=":", new="-").replace_all(old=".", new="-")
  posix_join([dir, "heap-" + t + ".heapsnapshot"])
}

///|
/// heap.ts `heapCommand`'s end: what it prints and its exit, from the answer (None: none came).
pub fn heap_command_end(answer : Json?) -> (String, Int) {
  match answer {
    None => ("the station did not answer: is it running on this data directory?", 1)
    Some(a) =>
      match field(a, "error") {
        Some(e) => ("the station could not write a heap snapshot: " + arg_text(e), 1)
        None => {
          let mb = js_round(num_field(a, "bytes").unwrap_or(0.0) / 1048576.0)
          ("\{str_or(a, "path", "")} (\{num_text(mb)} MB, \{num_text(num_field(a, "ms").unwrap_or(0.0))} ms)", 0)
        }
      }
  }
}

///|
/// heap.ts's request taken by renaming it (two processes at a handover both see it, one takes it): whether this one
/// did, the request removed then.
pub fn heap_take(fs : Fs, dir : String, pid : Int) -> Bool {
  let claimed = posix_join([dir, "heap.request." + pid.to_string()])
  try fs.rename(posix_join([dir, "heap.request"]), claimed) catch {
    _ => return false
  }
  try fs.remove(claimed) catch {
    _ => ()
  }
  true
}

///|
/// heap.ts: the snapshots of before let go, as a new one is written.
pub fn heap_old_snapshots(names : Array[String]) -> Array[String] {
  names.filter(heap_snapshot_name)
}

// ── links.ts ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// links.ts `link`'s choice once a link was refused: what stands in (`junction`, `copy`), or `missing`, `refused`,
/// by what is allowed and what the target is (`dir`, `file`, None where it is not there).
pub fn link_stand_in(junction : Bool, copy : Bool, target : String?) -> String {
  if !junction && !copy {
    return "refused"
  }
  match target {
    None => "missing"
    Some("dir") => if junction { "junction" } else { "refused" }
    Some(_) => if copy { "copy" } else { "refused" }
  }
}
