// The hooks a session's runtime runs as a command (agents/repo-rules.ts `hookCommand`), run by the station's own program
// where a release has no Node (agent_runtimes `hook_node`): `stillfail-reader <…>/repo-rules-hook.mjs` and
// `stillfail-reader <…>/subagent-hook.mjs [writes]` do what those files do under Node, line for line
// (src/agents/repo-rules-hook.mjs, src/agents/subagent-hook.mjs), reading the hook's JSON on stdin and writing their
// answer on stdout. Anything that goes wrong lets the call through, as the command's `|| true` does.

///|
/// Which hook `argv` runs, by its first argument's name.
pub fn hook_of(argv : Array[String]) -> String? {
  guard argv.length() >= 2 else { None }
  let a = argv[1].replace_all(old="\\", new="/")
  if a.has_suffix("/repo-rules-hook.mjs") || a == "repo-rules-hook.mjs" {
    Some("repo-rules")
  } else if a.has_suffix("/subagent-hook.mjs") || a == "subagent-hook.mjs" {
    Some("subagent")
  } else {
    None
  }
}

///|
/// What stdin holds, whole.
async fn stdin_text(host : @host.Host) -> String {
  let lines = []
  while host.line() is Some(l) {
    lines.push(l)
  }
  lines.push(host.unended())
  lines.join("\n")
}

///|
fn text_of(v : Json?) -> String? {
  opt_str(v)
}

///|
fn field(v : Json?, k : String) -> Json? {
  match v {
    Some(Object(o)) => o.get(k)
    _ => None
  }
}

///|
/// subagent-hook.mjs: a subagent's call of a tool by which a session speaks is refused before it is made. `writes`: the
/// Slack methods that write (argv[2], joined by commas). Its answer ("" lets it through).
pub fn subagent_hook(input : String, writes : String?) -> String {
  let input : Json = @json.parse(input) catch { _ => return "" }
  let agent = field(Some(input), "agent_id")
  match agent {
    None | Some(Null) | Some(String("")) => return ""
    _ => ()
  }
  let tool = match text_of(field(Some(input), "tool_name")) {
    Some(t) => {
      let parts = t.split("__").to_array()
      parts[parts.length() - 1].to_owned()
    }
    None => "this tool"
  }
  let instead = "Nothing was sent or changed. Do not retry, and do not look for another way to do it: finish your task and give what you did or found as your final answer. The agent that started you reads it and posts what people need."
  let mut reason = "Refused: you are a subagent, and \{tool} is only for the agent that started you. A subagent does not post to the chat, end the turn, write to another chat's agent, or open, leave or archive a chat. \{instead}"
  if tool == "slack_api" {
    let meth = match text_of(field(field(Some(input), "tool_input"), "method")) {
      Some(m) => m.trim().to_owned()
      None => ""
    }
    let ws = writes.unwrap_or("").split(",").map(w => w.to_owned()).filter(w => w != "").to_array()
    if !ws.iter().any(w => meth.has_prefix(w)) {
      return ""
    }
    reason = "Refused: you are a subagent, and writing to Slack (\{js_slice(meth, 0, 60)}) is only for the agent that started you. Reading Slack with slack_api is fine (conversations.history, conversations.replies, users.info, files.info and the like). \{instead}"
  }
  (
    {
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
      },
    } : Json
  ).stringify()
}

///|
/// JavaScript's `s.slice(from, to)` (UTF-16 units, clamped).
fn js_slice(s : String, from : Int, to : Int) -> String {
  let n = s.length()
  let a = if from < 0 { 0 } else if from > n { n } else { from }
  let b = if to < a { a } else if to > n { n } else { to }
  s[a:b].to_owned()
}

///|
/// What one call tells at most, its headings included: under Claude Code's 10,000.
let rules_max : Int = 9_800

///|
/// A piece of a file is begun only with this much room left; with less the file waits for the next call.
let rules_least : Int = 1_500

///|
let rules_between : String = "\n\n---\n\n"

///|
/// What the repository rules' hook is given of the machine (its tests give their own).
pub(all) struct RulesWorld {
  sep : String
  windows : Bool
  cwd : String
  home : String?
  tmpdir : String
  /// STILLFAIL_REPO_RULES.
  switch_ : String?
  exists : (String) -> Bool
  /// A path's time (ms) and whether it is a directory; none where it is not there.
  stat : (String) -> (Double, Bool)?
  realpath : (String) -> String?
  read : (String) -> String?
  write : (String, String) -> Unit
  remove : (String) -> Unit
}

///|
/// The machine as the hook finds it.
pub fn machine_rules_world() -> RulesWorld {
  let windows = is_windows()
  let sep = if windows { "\\" } else { "/" }
  {
    sep,
    windows,
    cwd: @drive.cwd(),
    home: env_get("HOME"),
    tmpdir: tmpdir(),
    switch_: env_get("STILLFAIL_REPO_RULES"),
    exists: p => attempt(() => @drive.stat(p)) is Ok(_),
    stat: p => match attempt(() => @drive.stat(p)) {
      Ok(s) => Some((s.mtime_ms, s.dir))
      Err(_) => None
    },
    realpath: p => attempt(() => @drive.realpath(p)).to_option(),
    read: p => match attempt(() => @drive.read_all(p)) {
      Ok(b) => Some(@utf8.decode_lossy(b))
      Err(_) => None
    },
    write: (p, text) => {
      ignore(attempt(() => @drive.mkdir(@nodepath.dirname(sep, p), true)))
      let data = @utf8.encode(text)
      ignore(
        attempt(() => @drive.write_part(p, {
          create: true,
          offset: 0.0,
          data,
          at_least: None,
          truncate: Some(data.length().to_double()),
          sync: false,
        })),
      )
    },
    remove: p => @drive.rm_force(p),
  }
}

///|
fn rules_resolve(w : RulesWorld, path : String) -> String {
  if @nodepath.is_absolute(w.sep, path) {
    @nodepath.join(w.sep, [path])
  } else {
    @nodepath.join(w.sep, [w.cwd, path])
  }
}

///|
/// The paths the tool was given: its file or path, or what in a shell command reads as one.
fn rules_paths(w : RulesWorld, tool : Json?) -> Array[String] {
  let out = []
  for key in ["file_path", "path", "notebook_path", "Path", "TargetFile", "SearchPath", "DirectoryPath", "Cwd"] {
    if text_of(field(tool, key)) is Some(p) {
      out.push(p)
    }
  }
  let command = match text_of(field(tool, "command")) {
    Some(c) => Some(c)
    None => text_of(field(tool, "CommandLine"))
  }
  if command is Some(c) {
    // (as `split(/[\s;&|()<>`'"=]+/)`)
    let words = []
    let word = StringBuilder()
    let mut has = false
    for ch in c {
      let parts = " \t\n\r\u{0B}\u{0C}\u{A0}\u{FEFF}\u{2028}\u{2029};&|()<>`'\"="
      if parts.contains_char(ch) || (ch.to_int() >= 0x2000 && ch.to_int() <= 0x200A) || ch.to_int() == 0x1680 || ch.to_int() == 0x202F || ch.to_int() == 0x205F || ch.to_int() == 0x3000 {
        if has {
          words.push(word.to_string())
          word.reset()
          has = false
        } else if words.length() == 0 {
          words.push("")
        }
      } else {
        word.write_char(ch)
        has = true
      }
    }
    words.push(word.to_string())
    for wd in words {
      if (wd.contains("/") || (w.windows && wd.contains("\\"))) && !wd.contains("://") {
        out.push(if wd.has_prefix("~") { w.home.unwrap_or("~") + wd[1:].to_owned() } else { wd })
      }
    }
    if out.length() == 0 {
      out.push(w.cwd)
    }
  }
  out
}

///|
/// The nearest existing directory of `path`.
fn rules_dir_of(w : RulesWorld, path : String) -> String? {
  let mut p = rules_resolve(w, path)
  for i = 0; i < 64 && !(w.exists)(p); i = i + 1 {
    p = @nodepath.dirname(w.sep, p)
  }
  guard (w.realpath)(p) is Some(real) else { None }
  match (w.stat)(real) {
    Some((_, true)) => Some(real)
    Some(_) => Some(@nodepath.dirname(w.sep, real))
    None => None
  }
}

///|
/// The rule files from `dir`'s repository root down to `dir` (none outside a repository).
fn rules_for(w : RulesWorld, dir : String) -> Array[String] {
  let chain = []
  let mut root = None
  let mut p = dir
  while true {
    chain.insert(0, p)
    if (w.exists)(@nodepath.join(w.sep, [p, ".git"])) {
      root = Some(p)
      break
    }
    if @nodepath.dirname(w.sep, p) == p {
      break
    }
    p = @nodepath.dirname(w.sep, p)
  }
  guard root is Some(root) else { [] }
  let files = []
  for d in chain {
    let agents = @nodepath.join(w.sep, [d, "AGENTS.md"])
    let claude = @nodepath.join(w.sep, [d, "CLAUDE.md"])
    let dot = @nodepath.join(w.sep, [d, ".claude", "CLAUDE.md"])
    if (w.exists)(agents) {
      files.push(agents)
    } else if (w.exists)(claude) {
      files.push(claude)
    } else if d == root && (w.exists)(dot) {
      files.push(dot)
    }
  }
  files
}

///|
/// `text.slice(i, i + 4)` begins a heading, a list's item, a numbered one or a paragraph.
fn begins_part(text : String, i : Int) -> Bool {
  let s = js_slice(text, i, i + 4)
  if s.has_prefix("#") || s.has_prefix("\n") {
    return true
  }
  if s.length() >= 2 && (s[0] == '-' || s[0] == '*' || s[0] == '>') && s[1] == ' ' {
    return true
  }
  let mut k = 0
  while k < s.length() && s[k] >= '0' && s[k] <= '9' {
    k += 1
  }
  k > 0 && k + 1 < s.length() && s[k] == '.' && s[k + 1] == ' '
}

///|
/// Where to cut `text` at `room` characters or fewer: before a heading, a list's item or a paragraph when one begins in
/// the second half of the room, else at a line's end, else at the room.
fn rules_cut(text : String, room : Int) -> Int {
  let mut i = room
  while i.to_double() > room.to_double() / 2.0 {
    if i - 1 >= 0 && i - 1 < text.length() && text[i - 1] == '\n' && begins_part(text, i) {
      return i
    }
    i -= 1
  }
  // text.lastIndexOf("\n", room - 1)
  let mut end = -1
  let mut j = if room - 1 >= text.length() { text.length() - 1 } else { room - 1 }
  while j >= 0 {
    if text[j] == '\n' {
      end = j
      break
    }
    j -= 1
  }
  if end > 0 {
    end + 1
  } else {
    room
  }
}

///|
fn num(v : Json?) -> Double? {
  opt_num(v)
}

///|
priv struct Waiting {
  file : String
  mut mtime : Double
  mut at : Int
}

///|
/// repo-rules-hook.mjs over `w`: its answer on stdout ("" for none).
pub fn repo_rules_hook(w : RulesWorld, input : String) -> String {
  let input : Json = @json.parse(input) catch { _ => return "" }
  let agy = text_of(field(Some(input), "hookEventName")) is Some(_)
  if w.switch_ == Some("0") {
    return if agy { "{}" } else { "" }
  }
  let event = if agy {
    text_of(field(Some(input), "hookEventName"))
  } else {
    text_of(field(Some(input), "hook_event_name"))
  }
  let w = match text_of(field(Some(input), "cwd")) {
    Some(c) => { ..w, cwd: c }
    None => w
  }
  let tool = if agy {
    field(field(Some(input), "toolCall"), "args")
  } else {
    field(Some(input), "tool_input")
  }
  let tool = match tool {
    None | Some(Null) => Some(Json::object({}))
    t => t
  }
  let session_id = if agy {
    field(Some(input), "conversationId")
  } else {
    field(Some(input), "session_id")
  }
  let id_text = (v : Json?, none : String) => match v {
    None | Some(Null) => none
    Some(String(s)) => s
    Some(other) => js_string(other)
  }
  let who_raw = "\{if agy { "agy-" } else { "" }}\{id_text(session_id, "none")}-\{id_text(field(Some(input), "agent_id"), "main")}"
  let who = StringBuilder()
  for ch in who_raw {
    let c = ch.to_int()
    if (c >= 'a'.to_int() && c <= 'z'.to_int()) || (c >= 'A'.to_int() && c <= 'Z'.to_int()) || (c >= '0'.to_int() && c <= '9'.to_int()) || ch == '_' || ch == '.' || ch == '-' {
      who.write_char(ch)
    } else if c > 0xFFFF {
      // (a character past the BMP is two UTF-16 units, each replaced, as the regex without /u does)
      who.write_string("__")
    } else {
      who.write_char('_')
    }
  }
  let state_dir = @nodepath.join(w.sep, [w.tmpdir, "stillfail-repo-rules"])
  let state_file = @nodepath.join(w.sep, [state_dir, "\{who.to_string()}.json"])
  if event == Some("SessionStart") || event == Some("PostCompact") {
    if event == Some("PostCompact") || text_of(field(Some(input), "source")) == Some("compact") {
      (w.remove)(state_file)
    }
    return if agy { "{}" } else { "" }
  }
  let seen : Map[String, Json] = match (w.read)(state_file) {
    Some(t) =>
      match attempt(() => @json.parse(t)) {
        Ok(Object(o)) => o
        _ => Map([])
      }
    None => Map([])
  }
  let kept = Json::object(seen).stringify()
  let line : Array[Waiting] = match seen.get("waiting") {
    Some(Array(xs)) =>
      xs.filter_map(x => match (text_of(field(Some(x), "file")), num(field(Some(x), "at"))) {
        (Some(file), Some(at)) => Some({ file, mtime: num(field(Some(x), "mtime")).unwrap_or(0.0), at: at.to_int() })
        _ => None
      })
    _ => []
  }
  let named = rules_paths(w, tool)
  let dirs : Array[String] = []
  for p in named {
    if rules_dir_of(w, p) is Some(d) && !dirs.contains(d) {
      dirs.push(d)
    }
  }
  let own : Array[String] = named.filter_map(p => (w.realpath)(rules_resolve(w, p)))
  for dir in dirs {
    for file in rules_for(w, dir) {
      guard (w.stat)(file) is Some((mtime, _)) else { continue }
      if num(seen.get(file)) == Some(mtime) {
        continue
      }
      let before = seen.get(file)
      seen[file] = Json::number(mtime)
      let waiting = line.search_by(x => x.file == file)
      if before is Some(_) && own.contains(file) {
        if waiting is Some(i) {
          ignore(line.remove(i))
        }
        continue
      }
      match waiting {
        None => line.push({ file, mtime, at: 0 })
        Some(i) => {
          line[i].mtime = mtime
          line[i].at = 0
        }
      }
    }
  }
  let save = () => {
    if line.length() > 0 {
      seen["waiting"] = Json::array(
        line.map(x => { "file": Json::string(x.file), "mtime": Json::number(x.mtime), "at": Json::number(x.at.to_double()) }),
      )
    } else {
      seen.remove("waiting")
    }
    let now = Json::object(seen).stringify()
    if now != kept {
      (w.write)(state_file, now)
    }
  }
  if agy && event == Some("PostToolUse") {
    save()
    return "{}"
  }
  let scope_of = (file : String) => {
    let d = @nodepath.dirname(w.sep, file)
    if d.has_suffix("\{w.sep}.claude") {
      @nodepath.dirname(w.sep, d)
    } else {
      d
    }
  }
  let told : Array[String] = []
  let mut room = rules_max
  while line.length() > 0 {
    let next = line[0]
    let text = match (w.stat)(next.file) {
      Some((mtime, _)) => {
        if mtime != next.mtime {
          next.mtime = mtime
          next.at = 0
        }
        seen[next.file] = Json::number(mtime)
        match (w.read)(next.file) {
          Some(t) => t
          None => {
            ignore(line.remove(0))
            continue
          }
        }
      }
      None => {
        ignore(line.remove(0))
        continue
      }
    }
    if text.trim().to_owned() == "@AGENTS.md" {
      ignore(line.remove(0))
      continue
    }
    let lines = (to : Int) => {
      let part = js_slice(text, 0, to)
      let mut n = 1
      for ch in part {
        if ch == '\n' {
          n += 1
        }
      }
      n - (if to == 0 || text[to - 1] == '\n' { 1 } else { 0 })
    }
    let head = (which : String) => "Contents of \{next.file} (the repository's rules for agents working in \{scope_of(next.file)}\{w.sep}; follow them)\{which}:\n\n"
    let last = head(if next.at == 0 { "" } else { ", lines \{lines(next.at) + 1} to \{lines(text.length())}, the last of it" })
    if last.length() + text.length() - next.at <= room {
      told.push(last + js_slice(text, next.at, text.length()))
      room -= told[told.length() - 1].length() + rules_between.length()
      ignore(line.remove(0))
      continue
    }
    let more = "\n[more of this file follows after your next tool call]"
    let within = room - head(", lines 00000 to 00000 of 00000").length() - more.length()
    if told.length() > 0 && (last.length() + text.length() - next.at <= rules_max || within < rules_least) {
      break
    }
    let rest = js_slice(text, next.at, text.length())
    let to = next.at + rules_cut(rest, if within > 1 { within } else { 1 })
    told.push(head(", lines \{lines(next.at) + 1} to \{lines(to)} of \{lines(text.length())}") + js_slice(text, next.at, to) + more)
    next.at = to
    break
  }
  save()
  if told.length() == 0 {
    return if agy { "{}" } else { "" }
  }
  let said = told.join(rules_between)
  (
    if agy {
      { "injectSteps": [{ "systemMessage": { "systemMessage": said } }] }
    } else {
      { "hookSpecificOutput": { "hookEventName": "PostToolUse", "additionalContext": said } }
    } : Json
  ).stringify()
}

///|
/// `String(v)` of a JSON value that is no string (a session's id given as a number).
fn js_string(v : Json) -> String {
  match v {
    String(s) => s
    Number(n, ..) => if n == n.floor() && n.abs() < 1.0e21 { n.to_int64().to_string() } else { n.to_string() }
    True => "true"
    False => "false"
    Null => "null"
    Array(_) => "[object Array]"
    Object(_) => "[object Object]"
  }
}

///|
/// Runs the hook `which` (`hook_of`) on stdin, its answer on stdout; 0 always (the command's `|| true`).
pub async fn run_hook(host : @host.Host, which : String, argv : Array[String]) -> Int {
  let input = stdin_text(host)
  let said = match which {
    "subagent" => subagent_hook(input, if argv.length() > 2 { Some(argv[2]) } else { None })
    _ => repo_rules_hook(machine_rules_world(), input)
  }
  if said != "" {
    out_write(said)
  }
  0
}

///|
fn[T] attempt(f : () -> T raise) -> Result[T, Error] {
  try Ok(f()) catch {
    e => Err(e)
  }
}
