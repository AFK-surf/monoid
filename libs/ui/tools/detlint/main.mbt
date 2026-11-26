// detlint: what a run's determinism must not rest on: a guessed time, a wait for the app to "settle", a frame the
// app asks for itself, the machine's own clock. mbui runs it on itself; still.fail's apps/mbui runs the one of the
// mbui it pins ($MBUI_DIR/scripts/detlint apps/mbui) with its own apps/mbui/detlint.json.
//
//     scripts/detlint [ROOT]            check ROOT (default: mbui) against ROOT/detlint.json
//     scripts/detlint ROOT --update     write the counts found as the new bar (never above the old one;
//                                       --update=raise to raise it, said why in the commit)
//     scripts/detlint ROOT --list RULE  every finding of RULE, file:line
//
// The bar (a ratchet): detlint.json keeps each rule's count of findings, file by file, and each file is held to its
// own: one more in any file fails (a finding moved to another file too), naming it and its lines; fewer fails too,
// until --update lowers the bar (the migration's own commit: what was moved off stays off). A rule whose bar is 0 is
// simply forbidden. says each rule; rule_words (rules.mbt) is what a failure prints. When detlint.json sets
// `counts_dir` (e.g. `"detlint.counts"`), `rules` lists the baselined rules in detlint.json and each package's or
// top-level directory's non-zero counts and excused entries live in `<counts_dir>/<shard>.json`, so changes in
// different packages never edit the same bar file.
//
// An exception is written on the line itself or on the line above it, with its reason:
//
//     c.request_frame() // det-ok(frame-request): the bench mode draws every frame on purpose
//     # det-ok(script-wait): the emulator's boot has no event to wait for
//
// They are printed with their reasons, and counted (detlint.json's `excused`, by rule and file), and only go down:
// marking a finding det-ok does not make it go away. app-clock alone (swappable: a time shown is right) lets an
// exception take the place of a finding there was (found and excused together never above their bar).
//
// What it reads: MoonBit through a lexer of its own (file.mbt), a call being NAME ( … ) with what is before it (a
// receiver `.`, a package `@pkg.`, a type `T::`) and its arguments split at the top level, the enclosing top-level
// item (a `test` block, a `fn`) and blocks with their headers (if / while / match / guards). It does not know types:
// `x.request_frame()` is the Ctx's for any x.

///|
let drive_wait : @re.Regex = rx("^\\s*(wait|linger)\\s+[0-9]")

///|
/// a drive's `rest` step: a flow's line, or a line of drive text in a string (a test's, a script's)
let drive_rest : @re.Regex = rx("^\\s*rest\\s*(#.*)?$")

///|
let drive_rest_text : @re.Regex = rx("(\\\\n|^\\s*#\\||\"|')rest\\s*(\\\\n|\"|'|$)")

///|
/// a picture at the app's rest
let shot_rest : @re.Regex = rx("\\b(MBUI_SHOT_MS|shot_at|SHOT_AT)\\s*=\\s*[\"']?rest\\b")

///|
/// a picture of the app taken off a device, an emulator or a simulator
let device_shots : Array[@re.Regex] = [
  rx("\\bscreencap\\b"),
  rx("\\bsimctl\\s+io\\b.*\\bscreenshot\\b"),
]

///|
let script_waits : Array[@re.Regex] = [
  rx("(?<![\\w-])sleep\\s+[\"'$0-9.]"),
  rx("\\bMBUI_SHOT_AT=[\"'$0-9]"),
  rx("\\bsetTimeout\\(.*[^\\w.][0-9]"),
  rx("\\bwaitForTimeout\\("),
  rx("\\btime\\.sleep\\("),
]

///|
let page_settle : @re.Regex = rx("\\b__mb\\w*\\.(?:settled|unsettled)\\b")

///|
/// a host doing something a fixed time later: Android's Handler, Apple's GCD and a selector's delay, Windows' timers,
/// GLib's (Linux's)
let host_delays : Array[@re.Regex] = [
  rx("\\bpostDelayed\\("),
  rx("\\bdispatch_after\\("),
  rx("afterDelay:"),
  rx("\\bSetTimer\\("),
  rx("\\bCreateTimerQueueTimer\\("),
  rx("\\bsetTimeout\\("),
  rx("\\bg_timeout_add(?:_full|_seconds)?\\("),
]

///|
/// a test's end without its idle check: Tester::settle's, a replay's Flow::end's (an argument, not a declaration)
let unsettled_ok : @re.Regex = rx("\\bunsettled_ok\\s*=")

///|
/// Every #version 300 es fragment shader (a shader block declaring a float precision before void main) declares
/// `precision highp int;` too: ESSL 3.00 defaults fragment `int` to 16-bit `mediump`, while software and desktop GL
/// promote it to 32-bit.
let shader_float_prec : @re.Regex = rx("\\bprecision\\s+(?:highp|mediump|lowp)\\s+float\\s*;")

///|
let shader_highp_int : @re.Regex = rx("\\bprecision\\s+highp\\s+int\\s*;")

///|
fn lint_shader_int(rel : String, src : String, out : Array[Finding]) -> Unit {
  let lines = src.split("\n").map(fn(l) { l.to_owned() }).to_array()
  let mut at = -1
  let mut head = ""
  let mut float_prec = false
  let mut highp_int = false
  let flush = fn() {
    if at > 0 && float_prec && !highp_int {
      out.push(finding("shader-int", rel, at, head))
    }
    at = -1
    float_prec = false
    highp_int = false
  }
  for i, line in lines {
    let s = line.trim_start(chars=" \t\r\n\u{b}\u{c}").to_owned()
    if s.has_prefix("//") || s.has_prefix("*") || s.has_prefix("/*") {
      continue
    }
    if line.contains("#version 300 es") && !line.contains("strlen(") && !line.contains("snprintf(") {
      flush()
      at = i + 1
      head = trim(line)
    }
    if at > 0 {
      let cs = line.to_array()
      if shader_float_prec.search_chars_from(cs, 0) is Some(_) {
        float_prec = true
      }
      if shader_highp_int.search_chars_from(cs, 0) is Some(_) {
        highp_int = true
      }
      if line.contains("void main(") {
        flush()
      }
    }
  }
  flush()
}

///|
fn find_chars(s : Array[Char], w : String) -> Int {
  let cs = w.to_array()
  let mut i = 0
  while i + cs.length() <= s.length() {
    let mut ok = true
    for k, c in cs {
      if s[i + k] != c {
        ok = false
        break
      }
    }
    if ok {
      return i
    }
    i += 1
  }
  -1
}

///|
/// A library's package (moon.pkg `rel`): each import it names that is not among `allowed` (prefixes).
fn lint_library(rel : String, src : String, allowed : Array[String], out : Array[Finding]) -> Unit {
  for n0, line in src.split("\n").to_array() {
    let line = line.to_owned()
    let s = line.trim_start(chars=" \t\r\n\u{b}\u{c}").to_owned()
    if s.has_prefix("//") {
      continue
    }
    // every quoted name with a slash in it: a package
    let parts = line.split("\"").to_array()
    let mut i = 1
    while i < parts.length() {
      let name = parts[i].to_owned()
      if name.contains("/") && !name.contains(" ") && !allowed.iter().any(fn(a) { name.has_prefix(a) }) {
        out.push(finding("library-import", rel, n0 + 1, trim(line)))
        break
      }
      i = i + 2
    }
  }
}

///|
fn lint_lines(
  rel : String,
  src : String,
  rule : String,
  pats : Array[@re.Regex],
  out : Array[Finding],
  comment : String,
) -> Unit {
  for n0, line in src.split("\n").to_array() {
    let line = line.to_owned()
    let s = line.trim_start(chars=" \t\r\n\u{b}\u{c}").to_owned()
    if s.has_prefix(comment) && !s.contains("det-ok(") {
      continue
    }
    let cs = line.to_array()
    for p in pats {
      match p.search_chars_from(cs, 0) {
        Some(m) => {
          // in a comment after the code
          let ci = find_chars(cs, " " + comment + " ")
          if ci >= 0 && ci < m.start() {
            continue
          }
          out.push(finding(rule, rel, n0 + 1, trim(line)))
          break
        }
        None => ()
      }
    }
  }
}

///|
fn excuse(findings : Array[Finding], texts : Map[String, Array[String]]) -> Unit {
  for fd in findings {
    let lines = match texts.get(fd.file) {
      Some(l) => l
      None => continue
    }
    for ln in [fd.line, fd.line - 1] {
      if ln < 1 || ln > lines.length() {
        continue
      }
      match exc_re.search(lines[ln - 1]) {
        Some(m) => {
          let rules = m.get(1).split(",").map(fn(r) { trim(r.to_owned()) }).to_array()
          if rules.contains(fd.rule) {
            let reason = trim(m.get(2))
            if reason == "" {
              fd.excused = None
              fd.what = fd.what + "   (det-ok without a reason: not taken)"
            } else {
              fd.excused = Some(reason)
            }
            break
          }
        }
        None => ()
      }
    }
  }
}

///|
fn read(path : String) -> String {
  match @sys.read_text(path) {
    Some(s) => s
    None => ""
  }
}

///|
fn sorted(names : Array[String]) -> Array[String] {
  let a = names.copy()
  a.sort_by(@rjson.str_cmp)
  a
}

///|
fn lines_of(src : String) -> Array[String] {
  src.split("\n").map(fn(l) { l.to_owned() }).to_array()
}

///|
fn has_any_suffix(n : String, sufs : Array[String]) -> Bool {
  sufs.iter().any(fn(s) { n.has_suffix(s) })
}

///|
/// What detlint reads a file as: 0 nothing, 1 a package's moon.pkg, 2 MoonBit, 3 a flow, 4 a script, 5 a host's source
fn kind_of(rel : String, cfg : Config) -> Int {
  let n = @sys.basename(rel)
  if matches(rel, cfg.skip) {
    0
  } else if n == "moon.pkg" && under(rel, cfg.mbt_roots) {
    1
  } else if n.has_suffix(".mbt") && under(rel, cfg.mbt_roots) {
    2
  } else if matches(rel, cfg.flows) {
    3
  } else if matches(rel, cfg.scripts) {
    4
  } else if matches(rel, cfg.hosts) {
    5
  } else {
    0
  }
}

///|
/// The files under root detlint reads, (path relative to root, text), as os.walk goes: a directory's files, then
/// its directories, each sorted
fn sources(root : String, cfg : Config) -> Array[(String, String)] {
  let out = []
  fn walk(rd : String) -> Unit {
    let dir = if rd == "" { root } else { @sys.join(root, rd) }
    let files = []
    let dirs = []
    for n in sorted(@sys.list_dir(dir)) {
      let path = @sys.join(dir, n)
      let rel = if rd == "" { n } else { rd + "/" + n }
      if @sys.is_dir(path) {
        if !n.has_prefix(".") &&
          !["_build", "node_modules", "target", ".mooncakes", "out"].contains(n) &&
          (cfg.counts_dir == "" || rel != cfg.counts_dir) &&
          !matches(rel, cfg.skip) &&
          !@sys.is_link(path) { // (os.walk lists a link to a directory but does not go in)
          dirs.push(rel)
        }
      } else if kind_of(rel, cfg) != 0 {
        files.push((rel, path))
      }
    }
    for f in files {
      out.push((f.0, read(f.1)))
    }
    for d in dirs {
      walk(d)
    }
  }

  walk("")
  out
}

///|
fn collect(root : String, cfg : Config) -> Array[Finding] {
  let files = sources(root, cfg)
  lap("read")
  lint_sources(files, cfg)
}

///|
fn lint_sources(files : Array[(String, String)], cfg : Config) -> Array[Finding] {
  let findings = []
  let app_words = cfg.app_words.map(rx)
  let texts : Map[String, Array[String]] = Map([])
  let mbts : Array[MbtFile] = []
  for x in files {
    let (rel, src) = x
    let kind = kind_of(rel, cfg)
    if kind != 0 {
      texts[rel] = lines_of(src)
    }
    match kind {
      1 => {
        if !src.contains("is-main") {
          lint_lines(rel, src, "host-import", [host_import], findings, "//")
        }
        if under(rel, cfg.library) {
          lint_library(rel, src, cfg.library_imports, findings)
        }
      }
      2 => {
        let t0 = @env.now()
        mbts.push(MbtFile::new(rel, src))
        lex_ms.val += @env.now() - t0
        lint_lines(rel, src, "unsettled-ok", [unsettled_ok], findings, "//")
        lint_lines(rel, src, "at-rest-wait", [drive_rest_text, shot_rest], findings, "//")
      }
      3 => {
        lint_lines(rel, src, "flow-wait", [drive_wait], findings, "#")
        lint_lines(rel, src, "at-rest-wait", [drive_rest], findings, "#")
      }
      4 => {
        let comment = if has_any_suffix(rel, [".mjs", ".js", ".ts"]) {
          "//"
        } else {
          "#"
        }
        lint_lines(rel, src, "script-wait", script_waits, findings, comment)
        lint_lines(rel, src, "page-settle", [page_settle], findings, comment)
        lint_lines(rel, src, "device-shot", device_shots, findings, comment)
        lint_lines(rel, src, "at-rest-wait", [shot_rest, drive_rest_text], findings, comment)
        if matches(rel, cfg.hosts) {
          lint_lines(rel, src, "host-delay", host_delays, findings, "//")
          lint_shader_int(rel, src, findings)
        }
      }
      5 => {
        lint_lines(rel, src, "host-delay", host_delays, findings, "//")
        lint_shader_int(rel, src, findings)
      }
      _ => ()
    }
    // (what names an app, in any file read: its comment's mark as each kind has it)
    if kind != 0 && app_words.length() > 0 {
      let comment = if kind == 3 ||
        (kind == 4 && !has_any_suffix(rel, [".mjs", ".js", ".ts"])) {
        "#"
      } else {
        "//"
      }
      // (a block comment's lines too: C's, Java's)
      let code = src
        .split("\n")
        .map(fn(l) {
          let t = l.trim_start(chars=" \t")
          if comment == "//" && (t.has_prefix("*") || t.has_prefix("/*")) {
            ""
          } else {
            l.to_owned()
          }
        })
        .to_array()
        .join("\n")
      lint_lines(rel, code, "app-word", app_words, findings, comment)
    }
  }
  if times_on {
    @sys.eprintln("detlint: of which MbtFile::new \{lex_ms.val} ms")
  }
  lap("lexed, lines")
  let returns = Map([])
  for f in mbts {
    for k, v in f.returns() {
      returns[k] = v
    }
  }
  let readers = host_readers(mbts, cfg)
  lap("host readers")
  for m in motion_returns {
    if !returns.contains(m.0) {
      returns[m.0] = m.1
    }
  }
  let painted = paint_fns(mbts)
  let moving_fields = motion_fields(mbts)
  for f in mbts {
    lint_mbt(f, cfg, findings, returns, readers, painted, moving_fields)
    lint_style(f, cfg, findings)
    lint_radius(f, cfg, findings)
    lint_style_text(f, findings)
  }
  lap("calls, style")
  lint_globals(mbts, cfg, findings)
  lap("globals")
  lint_read_before_run(mbts, cfg, findings)
  lint_reset_by_hand(mbts, cfg, findings)
  lint_build_effects(mbts, cfg, findings)
  lap("build effects")
  lint_perf(mbts, cfg, findings)
  lap("perf")
  excuse(findings, texts)
  findings
}

// ---------------------------------------------------------------------------------------------------------------------
// The bar, the report

///|
/// file -> count, in the order first counted
priv struct Counts {
  m : Map[String, Int]
}

///|
fn Counts::new() -> Counts {
  { m: Map([]) }
}

///|
fn Counts::at(self : Counts, p : String) -> Int {
  self.m.get(p).unwrap_or(0)
}

///|
fn Counts::total(self : Counts) -> Int {
  let mut n = 0
  for _, v in self.m {
    n += v
  }
  n
}

///|
fn tally(
  findings : Array[Finding],
  excused : Bool,
  rules : Array[String],
) -> Map[String, Counts] {
  let counts = Map([])
  for r in rules {
    counts[r] = Counts::new()
  }
  for fd in findings {
    if (fd.excused is Some(_)) == excused {
      match counts.get(fd.rule) {
        Some(c) => c.m[fd.file] = c.at(fd.file) + 1
        None => ()
      }
    }
  }
  counts
}

///|
/// the rules where an exception may take the place of a finding there was (a time shown is right);
/// elsewhere an exception's count only goes down, apart from the findings'
let swappable : Array[String] = ["app-clock"]

///|
fn union_keys(a : Counts, b : Counts) -> Array[String] {
  let s : Map[String, Unit] = Map([])
  for k, _ in a.m {
    s[k] = ()
  }
  for k, _ in b.m {
    s[k] = ()
  }
  sorted(s.keys().collect())
}

///|
/// The files (of one rule) above their bar: (file, found, its bar, found and excused, their bar)
fn over(
  cf : Counts,
  ce : Counts,
  bf_ : Counts,
  be_ : Counts,
  rule : String,
) -> Array[(String, Int, Int, Int, Int)] {
  let out = []
  for p in union_keys(cf, ce) {
    let f = cf.at(p)
    let e = ce.at(p)
    let bf = bf_.at(p)
    let be = be_.at(p)
    if f > bf || (if swappable.contains(rule) { f + e > bf + be } else { e > be }) {
      out.push((p, f, bf, f + e, bf + be))
    }
  }
  out
}

///|
/// The files (of one rule) below their bar: found fewer, or found and excused fewer
fn under_bar(cf : Counts, ce : Counts, bf_ : Counts, be_ : Counts) -> Array[String] {
  let out = []
  for p in union_keys(bf_, be_) {
    let f = cf.at(p)
    let e = ce.at(p)
    let bf = bf_.at(p)
    let be = be_.at(p)
    if f < bf || f + e < bf + be {
      out.push(p)
    }
  }
  out
}

///|
fn parse_int(s : String) -> Int {
  let mut n = 0
  for ch in s {
    if ch >= '0' && ch <= '9' {
      n = n * 10 + (ch.to_int() - '0'.to_int())
    }
  }
  n
}

///|
/// a rule's bar in detlint.json (counts or excused): None when the rule has none
fn bar_of(conf : @rjson.Value, sect_name : String, rule : String) -> Counts? {
  match conf.get(sect_name) {
    Some(s) =>
      match s.get(rule) {
        Some(Obj(kv)) => {
          let c = Counts::new()
          for x in kv {
            match x.1 {
              Num(n) => c.m[x.0] = parse_int(n)
              _ => ()
            }
          }
          Some(c)
        }
        Some(Null) | None => None
        Some(_) => Some(Counts::new())
      }
    None => None
  }
}

///|
/// Which shard file holds a path's bar under `counts_dir`: `src/<pkg>/…` -> `<pkg>`, `<dir>/…` -> `<dir>`, else `_root`
fn shard_of(rel : String) -> String {
  let parts = rel.split("/").map(fn(s) { s.to_owned() }).to_array()
  if parts.length() >= 3 &&
    parts[0] == "src" &&
    parts[1] != "" &&
    parts[1] != "." &&
    parts[1] != ".." {
    parts[1]
  } else if parts.length() >= 2 &&
    parts[0] != "" &&
    parts[0] != "." &&
    parts[0] != ".." {
    parts[0]
  } else {
    "_root"
  }
}

///|
/// Read and validate `counts_dir` from detlint.json: (ok, dir_rel), where "" means unsharded inline counts
fn counts_dir_of(conf : @rjson.Value, err : Array[String]) -> (Bool, String) {
  match conf.get("counts_dir") {
    None | Some(Null) => (true, "")
    Some(Str(raw)) => {
      let mut dir = raw
      while dir.has_suffix("/") && dir.length() > 0 {
        dir = dir.exact_view(end=dir.length() - 1).to_owned()
      }
      if dir == "" || dir.has_prefix("/") {
        err.push("detlint: detlint.json: invalid counts_dir: \{raw}")
        return (false, "")
      }
      for seg in dir.split("/") {
        let seg = seg.to_owned()
        if seg == "" || seg == "." || seg == ".." {
          err.push("detlint: detlint.json: invalid counts_dir: \{raw}")
          return (false, "")
        }
      }
      (true, dir)
    }
    Some(_) => {
      err.push("detlint: detlint.json: counts_dir must be a string")
      (false, "")
    }
  }
}

///|
/// All rule bars loaded from detlint.json (either inline or merged from counts_dir shards); absent key means no bar yet
priv struct Bars {
  counts : Map[String, Counts]
  excused : Map[String, Counts]
}

///|
fn load_bars(
  root : String,
  conf : @rjson.Value,
  counts_dir : String,
  err : Array[String],
) -> Bars? {
  let counts : Map[String, Counts] = Map([])
  let excused : Map[String, Counts] = Map([])
  if counts_dir == "" {
    for r in rule_names {
      match bar_of(conf, "counts", r) {
        Some(bf) => {
          counts[r] = bf
          excused[r] = bar_of(conf, "excused", r).unwrap_or(Counts::new())
        }
        None => ()
      }
    }
    return Some({ counts, excused })
  }
  match conf.get("counts") {
    None | Some(Null) => ()
    Some(_) => {
      err.push("detlint: detlint.json: counts_dir cannot be combined with inline counts")
      return None
    }
  }
  match conf.get("excused") {
    None | Some(Null) => ()
    Some(_) => {
      err.push("detlint: detlint.json: counts_dir cannot be combined with inline excused")
      return None
    }
  }
  match conf.get("rules") {
    None | Some(Null) => ()
    Some(Arr(rs)) =>
      for x in rs {
        match x {
          Str(r) => {
            counts[r] = Counts::new()
            excused[r] = Counts::new()
          }
          _ => {
            err.push("detlint: detlint.json: rules must be strings")
            return None
          }
        }
      }
    Some(_) => {
      err.push("detlint: detlint.json: rules must be an array")
      return None
    }
  }
  let dir_path = @sys.join(root, counts_dir)
  if @sys.exists(dir_path) && !@sys.is_dir(dir_path) {
    err.push("detlint: \{counts_dir} is not a directory")
    return None
  }
  if @sys.is_dir(dir_path) {
    for name in sorted(@sys.list_dir(dir_path)) {
      if !name.has_suffix(".json") {
        continue
      }
      let shard = name.exact_view(end=name.length() - 5).to_owned()
      let file_path = @sys.join(dir_path, name)
      let rel_shard = counts_dir + "/" + name
      let val = @rjson.parse(read(file_path)) catch {
        @rjson.JsonError(e) => {
          err.push("detlint: \{rel_shard}: \{e}")
          return None
        }
      }
      match val {
        Obj(_) => ()
        _ => {
          err.push("detlint: \{rel_shard}: expected a JSON object")
          return None
        }
      }
      for sect_info in [("counts", counts), ("excused", excused)] {
        let (sect_name, dest) = sect_info
        match val.get(sect_name) {
          None | Some(Null) => ()
          Some(Obj(rules_kv)) =>
            for rk in rules_kv {
              let (rule, rval) = rk
              match rval {
                Obj(files_kv) =>
                  for fk in files_kv {
                    let (file, nval) = fk
                    let expected = shard_of(file)
                    if expected != shard {
                      err.push(
                        "detlint: \{rel_shard}: \{file} belongs in \{counts_dir}/\{expected}.json",
                      )
                      return None
                    }
                    match nval {
                      Num(n) =>
                        match dest.get(rule) {
                          Some(c) => c.m[file] = parse_int(n)
                          None => ()
                        }
                      _ => {
                        err.push("detlint: \{rel_shard}: \{rule} \{file}: count must be a number")
                        return None
                      }
                    }
                  }
                _ => {
                  err.push("detlint: \{rel_shard}: \{sect_name}.\{rule} must be an object")
                  return None
                }
              }
            }
          Some(_) => {
            err.push("detlint: \{rel_shard}: \{sect_name} must be an object")
            return None
          }
        }
      }
    }
  }
  Some({ counts, excused })
}

///|
fn write_sharded_bars(
  root : String,
  conf_path : String,
  conf : @rjson.Value,
  counts_dir : String,
  nf_by_rule : Map[String, Counts],
  ne_by_rule : Map[String, Counts],
) -> Unit {
  let shard_set : Map[String, Unit] = Map([])
  for r in rule_names {
    for p, v in nf_by_rule[r].m {
      if v != 0 {
        shard_set[shard_of(p)] = ()
      }
    }
    for p, v in ne_by_rule[r].m {
      if v != 0 {
        shard_set[shard_of(p)] = ()
      }
    }
  }
  let dir_path = @sys.join(root, counts_dir)
  let active_shards = sorted(shard_set.keys().collect())
  if active_shards.length() > 0 {
    @sys.makedirs(dir_path)
  }
  for shard in active_shards {
    let scounts = []
    let sexc = []
    for r in rule_names {
      let cobj = []
      for p in sorted(nf_by_rule[r].m.keys().collect()) {
        if nf_by_rule[r].at(p) != 0 && shard_of(p) == shard {
          cobj.push((p, @rjson.Value::Num(nf_by_rule[r].at(p).to_string())))
        }
      }
      if cobj.length() > 0 {
        scounts.push((r, @rjson.Value::Obj(cobj)))
      }
      let eobj = []
      for p in sorted(ne_by_rule[r].m.keys().collect()) {
        if ne_by_rule[r].at(p) != 0 && shard_of(p) == shard {
          eobj.push((p, @rjson.Value::Num(ne_by_rule[r].at(p).to_string())))
        }
      }
      if eobj.length() > 0 {
        sexc.push((r, @rjson.Value::Obj(eobj)))
      }
    }
    let fields : Array[(String, @rjson.Value)] = []
    if scounts.length() > 0 {
      fields.push(("counts", @rjson.Value::Obj(scounts)))
    }
    if sexc.length() > 0 {
      fields.push(("excused", @rjson.Value::Obj(sexc)))
    }
    let text = @rjson.dumps(@rjson.Value::Obj(fields), ensure_ascii=false, indent=2) + "\n"
    let file_path = @sys.join(dir_path, shard + ".json")
    if @sys.read_text(file_path) != Some(text) {
      let _ = @sys.write_text(file_path, text)
    }
  }
  if @sys.is_dir(dir_path) {
    for name in sorted(@sys.list_dir(dir_path)) {
      if name.has_suffix(".json") {
        let shard = name.exact_view(end=name.length() - 5).to_owned()
        if !shard_set.contains(shard) {
          let _ = @sys.remove(@sys.join(dir_path, name))
        }
      }
    }
  }
  let rules_val = @rjson.Value::Arr(rule_names.map(fn(r) { @rjson.Value::Str(r) }))
  let new_conf = conf.set("rules", rules_val)
  let new_conf_text = @rjson.dumps(new_conf, ensure_ascii=false, indent=2) + "\n"
  if @sys.read_text(conf_path) != Some(new_conf_text) {
    let _ = @sys.write_text(conf_path, new_conf_text)
  }
}

///|
fn pad_right(s : String, w : Int) -> String {
  let n = s.to_array().length()
  if n >= w {
    s
  } else {
    s + String::make(w - n, ' ')
  }
}

///|
fn pad_left(s : String, w : Int) -> String {
  let n = s.to_array().length()
  if n >= w {
    s
  } else {
    String::make(w - n, ' ') + s
  }
}

///|
fn excused_note(fd : Finding) -> String {
  match fd.excused {
    Some(r) => "   [det-ok: \{r}]"
    None => ""
  }
}

///|
fn list_findings(
  findings : Array[Finding],
  want : String?,
  out : Array[String],
) -> Unit {
  let order = Array::makei(findings.length(), fn(i) { i })
  order.sort_by(fn(a, b) {
    let x = findings[a]
    let y = findings[b]
    let c = @rjson.str_cmp(x.rule, y.rule)
    if c != 0 {
      return c
    }
    let c = @rjson.str_cmp(x.file, y.file)
    if c != 0 {
      return c
    }
    if x.line != y.line {
      return x.line.compare(y.line)
    }
    a.compare(b)
  })
  for i in order {
    let fd = findings[i]
    if want is None || want == Some(fd.rule) {
      let ex = excused_note(fd)
      out.push("\{fd.rule}\t\{fd.file}:\{fd.line}\t\{fd.what}\{ex}")
    }
  }
}

///|
fn run_preset_tree(
  root : String,
  flags : Array[String],
  want : String?,
  out : Array[String],
  err : Array[String],
) -> Int {
  if flags.iter().any(fn(a) { a.has_prefix("--update") }) {
    err.push("detlint: --update cannot be used with --preset=tree")
    return 2
  }
  if !@sys.is_dir(root) {
    err.push("detlint: no directory \{root}")
    return 2
  }
  let cfg = preset_tree_config()
  let findings = collect(root, cfg).filter(fn(fd) {
    preset_tree_rules.contains(fd.rule)
  })
  if flags.contains("--list") {
    list_findings(findings, want, out)
    return 0
  }
  let found = tally(findings, false, preset_tree_rules)
  let excused = tally(findings, true, preset_tree_rules)
  let mut bad = false
  out.push(
    "detlint (\{@sys.basename(root)}, preset=tree): rule, found / 0, det-ok",
  )
  for r in preset_tree_rules {
    let cf = found[r]
    let ce = excused[r]
    let notes = []
    let line = "  \{pad_right(r, 20)} \{pad_left(cf.total().to_string(), 5)} / 0     \{pad_left(ce.total().to_string(), 4)} det-ok"
    if cf.total() > 0 {
      bad = true
      for p in sorted(cf.m.keys().collect()) {
        let f = cf.at(p)
        if f > 0 {
          notes.push("    \{r}: \{p}: \{f} > 0: \{rule_words[r]}")
          for fd in findings {
            if fd.rule == r && fd.file == p && fd.excused is None {
              notes.push("        \{p}:\{fd.line}  \{fd.what}")
            }
          }
          notes.push(
            "      an exception says why on its line (`det-ok(\{r}): <why>`)",
          )
        }
      }
    }
    out.push(line)
    for fd in findings {
      match fd.excused {
        Some(_) if fd.rule == r =>
          out.push("      \{fd.file}:\{fd.line}  \{fd.what}" + excused_note(fd))
        _ => ()
      }
    }
    for x in notes {
      out.push(x)
    }
  }
  if bad {
    1
  } else {
    0
  }
}

///|
fn run(argv : Array[String], out : Array[String], err : Array[String]) -> Int {
  let args : Array[String] = []
  let flags : Array[String] = []
  let mut preset : String? = None
  let mut i = 0
  while i < argv.length() {
    let a = argv[i]
    if a.has_prefix("--preset=") {
      preset = Some(a.exact_view(start=9).to_owned())
    } else if a == "--preset" {
      if i + 1 < argv.length() {
        i += 1
        preset = Some(argv[i])
      } else {
        err.push("detlint: --preset requires a name (available: tree)")
        return 2
      }
    } else if a.has_prefix("--") {
      flags.push(a)
    } else {
      args.push(a)
    }
    i += 1
  }
  match preset {
    None | Some("tree") => ()
    Some(other) => {
      err.push("detlint: unknown preset '\{other}' (available: tree)")
      return 2
    }
  }
  let is_list = flags.contains("--list")
  let default_root = fn() {
    match @sys.getenv("DETLINT_HOME") {
      Some(h) => @sys.join(h, "..")
      None => "."
    }
  }
  let (raw_root, want) = if is_list {
    if args.length() == 0 {
      (default_root(), None)
    } else if args.length() == 1 {
      if rule_words.contains(args[0]) && !@sys.is_dir(args[0]) {
        (default_root(), Some(args[0]))
      } else {
        (args[0], None)
      }
    } else if (rule_words.contains(args[0]) && !@sys.is_dir(args[0])) ||
      (!@sys.is_dir(args[0]) && @sys.is_dir(args[1])) {
      (args[1], Some(args[0]))
    } else {
      (args[0], Some(args[1]))
    }
  } else {
    (if args.length() > 0 { args[0] } else { default_root() }, None)
  }
  let root = normpath(@sys.abspath(raw_root))
  if preset == Some("tree") {
    return run_preset_tree(root, flags, want, out, err)
  }
  let conf_path = @sys.join(root, "detlint.json")
  if !@sys.exists(conf_path) {
    err.push("detlint: no \{conf_path}")
    return 2
  }
  let conf = @rjson.parse(read(conf_path)) catch {
    @rjson.JsonError(e) => {
      err.push("detlint: \{conf_path}: \{e}")
      return 2
    }
  }
  let (cdir_ok, counts_dir) = counts_dir_of(conf, err)
  if !cdir_ok {
    return 2
  }
  let cfg = Config::new(conf)
  let findings = collect(root, cfg)
  if is_list {
    let listed = findings.filter(fn(fd) {
      want is Some(_) || rule_names.contains(fd.rule)
    })
    list_findings(listed, want, out)
    return 0
  }
  let bars = match load_bars(root, conf, counts_dir, err) {
    Some(b) => b
    None => return 2
  }
  let found = tally(findings, false, rule_names)
  let excused = tally(findings, true, rule_names)
  let update = flags.search_by(fn(a) { a.has_prefix("--update") }).map(fn(i) { flags[i] })
  match update {
    Some(update) => {
      let counts = []
      let exc = []
      let nf_by_rule : Map[String, Counts] = Map([])
      let ne_by_rule : Map[String, Counts] = Map([])
      let summary = []
      for r in rule_names {
        let nf = Counts::new()
        let ne = Counts::new()
        for k, v in found[r].m {
          nf.m[k] = v
        }
        for k, v in excused[r].m {
          ne.m[k] = v
        }
        match bars.counts.get(r) {
          Some(bf) if update != "--update=raise" => {
            let be = bars.excused.get(r).unwrap_or(Counts::new())
            for o in over(found[r], excused[r], bf, be, r) {
              let (p, f, b, fe, bfe) = o
              err.push(
                "detlint: \{r} in \{p} is above its bar (\{f} found, \{fe} with det-ok; the bar \{b}, \{bfe}): kept (--update=raise to raise it, and say why)",
              )
              nf.m[p] = bf.at(p)
              ne.m[p] = be.at(p)
            }
          }
          _ => ()
        }
        nf_by_rule[r] = nf
        ne_by_rule[r] = ne
        let cobj = []
        for p in sorted(nf.m.keys().collect()) {
          if nf.at(p) != 0 {
            cobj.push((p, @rjson.Value::Num(nf.at(p).to_string())))
          }
        }
        let eobj = []
        for p in sorted(ne.m.keys().collect()) {
          if ne.at(p) != 0 {
            eobj.push((p, @rjson.Value::Num(ne.at(p).to_string())))
          }
        }
        counts.push((r, @rjson.Value::Obj(cobj)))
        exc.push((r, @rjson.Value::Obj(eobj)))
        let ct = nf.total()
        let et = ne.total()
        summary.push("\{r} \{ct}" + (if eobj.length() > 0 { " (+\{et} det-ok)" } else { "" }))
      }
      if counts_dir == "" {
        let conf = conf.set("counts", Obj(counts)).set("excused", Obj(exc))
        let _ = @sys.write_text(
          conf_path,
          @rjson.dumps(conf, ensure_ascii=false, indent=2) + "\n",
        )
      } else {
        write_sharded_bars(root, conf_path, conf, counts_dir, nf_by_rule, ne_by_rule)
      }
      out.push("detlint: bars written: " + summary.join(", "))
      return 0
    }
    None => ()
  }
  let mut bad = false
  out.push(
    "detlint (\{@sys.basename(root)}): rule, found / bar, det-ok / bar (each file against its own)",
  )
  for r in rule_names {
    let cf = found[r]
    let ce = excused[r]
    let notes = []
    let mut line = "  \{pad_right(r, 14)} \{pad_left(cf.total().to_string(), 5)} / "
    match bars.counts.get(r) {
      None => {
        bad = true
        line = line + "-"
        notes.push("    \{r}: no bar in detlint.json (scripts/detlint --update)")
      }
      Some(bf) => {
        let be = bars.excused.get(r).unwrap_or(Counts::new())
        line = line +
          "\{pad_right(bf.total().to_string(), 5)} \{pad_left(ce.total().to_string(), 4)} / \{pad_right(be.total().to_string(), 4)}"
        if bf.total() == 0 && be.total() == 0 {
          line = line + "  forbidden"
        }
        for o in over(cf, ce, bf, be, r) {
          let (p, f, b, fe, bfe) = o
          bad = true
          if f > b {
            notes.push("    \{r}: \{p}: \{f} > \{b}: \{rule_words[r]}")
          } else {
            notes.push(
              "    \{r}: \{p}: \{fe - f} det-ok, the bar \{bfe - b}: " +
              (if swappable.contains(r) {
                "an exception may only take the place of a finding there was"
              } else {
                "this rule's exceptions only go down (a finding marked det-ok is still a finding)"
              }),
            )
          }
          for fd in findings {
            if fd.rule == r && fd.file == p {
              notes.push("        \{p}:\{fd.line}  \{fd.what}" + excused_note(fd))
            }
          }
          if f > b {
            notes.push(
              "      an exception says why on its line (`det-ok(\{r}): <why>`), in place of a finding there was",
            )
          }
        }
        let lower = under_bar(cf, ce, bf, be)
        if lower.length() > 0 {
          bad = true
          notes.push(
            "    \{r}: fewer than the bar in \{lower.join(", ")}: lower it to what is now (scripts/detlint --update), so it stays there",
          )
        }
      }
    }
    out.push(line)
    for fd in findings {
      match fd.excused {
        Some(why) if fd.rule == r => out.push("      det-ok \{fd.file}:\{fd.line}: \{why}")
        _ => ()
      }
    }
    for x in notes {
      out.push(x)
    }
  }
  if bad {
    1
  } else {
    0
  }
}

///|
/// a/b/../c → a/c, a/./b → a/b
fn normpath(p : String) -> String {
  let parts = []
  for s in p.split("/") {
    let s = s.to_owned()
    if s == "" || s == "." {
      continue
    }
    if s == ".." {
      let _ = parts.pop()
      continue
    }
    parts.push(s)
  }
  "/" + parts.join("/")
}

///|
fn main {
  let argv = @env.args()
  let out = []
  let err = []
  let code = run(argv[1:].to_owned(), out, err)
  for l in err {
    @sys.eprintln(l)
  }
  if out.length() > 0 {
    @sys.out(out.join("\n") + "\n")
  }
  @sys.exit(code)
}

///|
/// DETLINT_TIMES=1: how long each part took, on stderr
let times_on : Bool = @sys.getenv("DETLINT_TIMES") is Some(_)

///|
let lap_t : Ref[UInt64] = { val: @env.now() }

///|
fn lap(what : String) -> Unit {
  if times_on {
    let t = @env.now()
    @sys.eprintln("detlint: \{what} \{(t - lap_t.val).to_string()} ms")
    lap_t.val = t
  }
}

///|
let lex_ms : Ref[UInt64] = { val: 0 }
