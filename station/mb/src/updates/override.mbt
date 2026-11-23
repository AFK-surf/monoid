// override.ts: local station override metadata (<app>/OVERRIDE) and conditional auto-update rules (`autoUpdateWhen` in config.json).

///|
pub(all) struct OverrideMeta {
  base_version : String?
  base_build : Double?
  base_commit : String?
  kind : String
  replaced_at : Double
  note : String?
}

///|
#derive(Eq, Show, Debug)
pub(all) enum WaitCondition {
  Pr(Int)
  Fix(Int)
  Commit(String)
  Version(String)
  After(String)
}

///|
pub(all) struct AutoUpdateWhen {
  wait : Array[WaitCondition]
  restore_auto : Bool
  for_override : Bool
  set_at : Double?
}

///|
pub(all) struct ReleaseIncluded {
  build : Double
  commit : String
  base_build : Double
  base_commit : String
  window_from_build : Double
  prs : Array[Int]
  fixes : Array[Int]
  commits : Array[String]
}

///|
fn is_hex_str(s : String, min_len : Int, max_len : Int) -> Bool {
  s.length() >= min_len &&
  s.length() <= max_len &&
  s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
}

///|
fn parse_pos_int(s : String) -> Int? {
  if !all_digits(s) || s.length() == 0 {
    return None
  }
  let n = try @string.parse_int(s) catch { _ => -1 }
  if n > 0 { Some(n) } else { None }
}

///|
pub fn parse_override_json(t : String) -> OverrideMeta? {
  let raw = try parse(t) catch { _ => return None }
  guard raw is Obj(_) else { return None }
  let kind = match text(get(Some(raw), "kind")) {
    Some("bundle") => "bundle"
    Some("overlay") => "overlay"
    _ => return None
  }
  let base_version = match text(get(Some(raw), "baseVersion")) {
    Some(s) if trim(s) != "" => Some(trim(s))
    _ => None
  }
  let base_build = match get(Some(raw), "baseBuild") {
    Some(Num(n)) if is_safe_integer(Some(Num(n))) => Some(n)
    _ => build_or_none(base_version)
  }
  let base_commit = match text(get(Some(raw), "baseCommit")) {
    Some(s) if trim(s) != "" => Some(trim(s))
    _ => None
  }
  let replaced_at = num(get(Some(raw), "replacedAt")).unwrap_or(0.0)
  let note = match text(get(Some(raw), "note")) {
    Some(s) if trim(s) != "" => Some(trim(s))
    _ => None
  }
  Some({ base_version, base_build, base_commit, kind, replaced_at, note })
}

///|
pub async fn read_override(w : World, app : String, sync? : Bool = false) -> OverrideMeta? {
  match w.read_text_or_null(pjoin([app, "OVERRIDE"]), sync~) {
    Some(t) => parse_override_json(t)
    None => None
  }
}

///|
pub fn parse_wait_spec(spec : String) -> WaitCondition raise {
  let s = trim(spec)
  let low = @jscase.lower(s)
  if starts_with(low, "pr:") {
    match parse_pos_int(slice(s, 3)) {
      Some(n) => return Pr(n)
      None => ()
    }
  } else if starts_with(s, "#") {
    match parse_pos_int(slice(s, 1)) {
      Some(n) => return Pr(n)
      None => ()
    }
  } else if starts_with(low, "fix:fb-") {
    match parse_pos_int(slice(s, 7)) {
      Some(n) => return Fix(n)
      None => ()
    }
  } else if starts_with(low, "fix:fb") {
    match parse_pos_int(slice(s, 6)) {
      Some(n) => return Fix(n)
      None => ()
    }
  } else if starts_with(low, "fix:") {
    match parse_pos_int(slice(s, 4)) {
      Some(n) => return Fix(n)
      None => ()
    }
  } else if starts_with(low, "fb-") {
    match parse_pos_int(slice(s, 3)) {
      Some(n) => return Fix(n)
      None => ()
    }
  } else if starts_with(low, "fb") {
    match parse_pos_int(slice(s, 2)) {
      Some(n) => return Fix(n)
      None => ()
    }
  } else if starts_with(low, "commit:") {
    let h = slice(s, 7)
    if is_hex_str(h, 7, 40) {
      return Commit(@jscase.lower(h))
    }
  } else if starts_with(low, "version:") {
    let v = slice(s, 8)
    if build_or_none(Some(v)) is Some(_) {
      return Version(v)
    }
  } else if starts_with(low, "after:") {
    let v = slice(s, 6)
    if build_or_none(Some(v)) is Some(_) {
      return After(v)
    }
  } else if build_or_none(Some(s)) is Some(_) {
    return Version(s)
  }
  raise fail(
    "invalid wait condition: \{spec} (expected pr:N, #N, fix:FB-N, FB-N, commit:SHA, version:0.1.N, or after:0.1.N)",
  )
}

///|
pub fn format_wait_condition(c : WaitCondition) -> String {
  match c {
    Pr(n) => "#\{n}"
    Fix(n) => "FB-\{n}"
    Commit(h) => "commit \{if h.length() > 12 { slice(h, 0, end=12) } else { h }}"
    Version(v) => ">= \{v}"
    After(v) => "> \{v}"
  }
}

///|
pub fn wait_condition_to_j(c : WaitCondition) -> J {
  match c {
    Pr(n) => jo([("kind", js("pr")), ("value", ji(n))])
    Fix(n) => jo([("kind", js("fix")), ("value", ji(n))])
    Commit(h) => jo([("kind", js("commit")), ("value", js(h))])
    Version(v) => jo([("kind", js("version")), ("value", js(v))])
    After(v) => jo([("kind", js("after")), ("value", js(v))])
  }
}

///|
pub fn parse_wait_condition(j : J) -> WaitCondition? {
  match (text(get(Some(j), "kind")), get(Some(j), "value")) {
    (Some("pr"), Some(Num(n))) if is_safe_integer(Some(Num(n))) && n > 0.0 => Some(Pr(n.to_int()))
    (Some("fix"), Some(Num(n))) if is_safe_integer(Some(Num(n))) && n > 0.0 => Some(Fix(n.to_int()))
    (Some("commit"), Some(Str(h))) => {
      let s = @jsjson.sanitize_str(h)
      if is_hex_str(s, 7, 40) { Some(Commit(@jscase.lower(s))) } else { None }
    }
    (Some("version"), Some(Str(v))) => {
      let s = @jsjson.sanitize_str(v)
      if build_or_none(Some(s)) is Some(_) { Some(Version(s)) } else { None }
    }
    (Some("after"), Some(Str(v))) => {
      let s = @jsjson.sanitize_str(v)
      if build_or_none(Some(s)) is Some(_) { Some(After(s)) } else { None }
    }
    _ => None
  }
}

///|
pub fn parse_auto_update_when(raw : J) -> AutoUpdateWhen? {
  guard get(Some(raw), "autoUpdateWhen") is Some(Obj(_) as w) else { return None }
  guard get(Some(w), "wait") is Some(Arr(xs)) else { return None }
  let wait : Array[WaitCondition] = []
  for x in xs {
    match parse_wait_condition(x) {
      Some(c) => wait.push(c)
      None => ()
    }
  }
  let restore_auto = get(Some(w), "restoreAuto") is Some(Bool(true))
  let for_override = get(Some(w), "forOverride") is Some(Bool(true))
  let set_at = num(get(Some(w), "setAt"))
  Some({ wait, restore_auto, for_override, set_at })
}

///|
pub fn auto_update_when_to_j(w : AutoUpdateWhen) -> J {
  let fs : Array[(String, J)] = [
    ("wait", ja(w.wait.map(wait_condition_to_j))),
    ("restoreAuto", jb(w.restore_auto)),
  ]
  if w.for_override {
    fs.push(("forOverride", jb(true)))
  }
  match w.set_at {
    Some(at) => fs.push(("setAt", jn(at)))
    None => ()
  }
  jo(fs)
}

///|
pub fn needs_included(wait : Array[WaitCondition]) -> Bool {
  wait.iter().any(c => match c {
    Pr(_) | Fix(_) | Commit(_) => true
    Version(_) | After(_) => false
  })
}

///|
fn commit_matches(target : String, candidate : String) -> Bool {
  let a = @jscase.lower(target)
  let b = @jscase.lower(candidate)
  if a.length() < 7 || b.length() < 7 {
    return false
  }
  starts_with(b, a) || starts_with(a, b)
}

///|
pub fn conditions_met(wait : Array[WaitCondition], release : J, included : ReleaseIncluded?) -> Bool {
  if wait.length() == 0 {
    return false
  }
  let build = release_build(release)
  let commit = text(get(Some(release), "commit")).unwrap_or("")
  for c in wait {
    match c {
      Version(v) =>
        match build_or_none(Some(v)) {
          Some(n) if build >= n => ()
          _ => return false
        }
      After(v) =>
        match build_or_none(Some(v)) {
          Some(n) if build > n => ()
          _ => return false
        }
      Pr(n) =>
        match included {
          Some(inc) if inc.prs.contains(n) => ()
          _ => return false
        }
      Fix(n) =>
        match included {
          Some(inc) if inc.fixes.contains(n) => ()
          _ => return false
        }
      Commit(h) => {
        let direct = commit != "" && commit_matches(h, commit)
        let in_list = match included {
          Some(inc) => inc.commits.iter().any(ic => commit_matches(h, ic))
          None => false
        }
        if !direct && !in_list {
          return false
        }
      }
    }
  }
  true
}

///|
pub fn parse_release_included(j : J) -> ReleaseIncluded? {
  guard j is Obj(_) else { return None }
  guard is_safe_integer(get(Some(j), "build")) else { return None }
  guard text(get(Some(j), "commit")) is Some(commit) else { return None }
  guard get(Some(j), "prs") is Some(Arr(pr_xs)) else { return None }
  guard get(Some(j), "fixes") is Some(Arr(fix_xs)) else { return None }
  guard get(Some(j), "commits") is Some(Arr(commit_xs)) else { return None }
  let build = num(get(Some(j), "build")).unwrap()
  let base_build = match get(Some(j), "baseBuild") {
    Some(Num(n)) if is_safe_integer(Some(Num(n))) => n
    _ => build
  }
  let base_commit = text(get(Some(j), "baseCommit")).unwrap_or(commit)
  let window_from_build = match get(Some(j), "windowFromBuild") {
    Some(Num(n)) if is_safe_integer(Some(Num(n))) => n
    _ => 0.0
  }
  let prs : Array[Int] = []
  for x in pr_xs {
    if is_safe_integer(Some(x)) {
      prs.push(num(Some(x)).unwrap().to_int())
    }
  }
  let fixes : Array[Int] = []
  for x in fix_xs {
    if is_safe_integer(Some(x)) {
      fixes.push(num(Some(x)).unwrap().to_int())
    }
  }
  let commits : Array[String] = []
  for x in commit_xs {
    match text(Some(x)) {
      Some(s) => commits.push(@jscase.lower(s))
      None => ()
    }
  }
  Some({ build, commit, base_build, base_commit, window_from_build, prs, fixes, commits })
}
