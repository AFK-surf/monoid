// What of station/src/read/ the readers (station/readops, station/history) do not answer already: the names books
// and connects' places (slack-known.ts), the views' config and authors' names (views.ts), the machine's transcripts
// (machine.ts), a job's log (jobs.ts), where a Codex rollout is (transcript-soon.ts), where a transcript's reading is
// kept (transcripts.ts), what a session spent (usage.ts) and the store's own reads (store.ts) that are not readops'.
// (runtime-view.ts is station/events' `runtime_view`.)

// ── slack-known.ts ───────────────────────────────────────────────────────────────────────────────────────────────

///|
/// slack-known.ts `Team`: a connect's place and the book its names are in.
pub(all) struct Team {
  id : String
  name : String
  book : String
}

///|
fn team_json(t : Team) -> Json {
  { "id": js(t.id), "name": js(t.name), "book": js(t.book) }
}

///|
fn str_in(j : Json?, path : Array[String]) -> String? {
  let mut at = j
  for p in path {
    at = match at {
      Some(Object(_) as o) => field(o, p)
      _ => None
    }
  }
  match at {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// slack-known.ts `configTeams`.
pub fn config_teams(raw : Json) -> Array[(String, Team)] {
  let out : Array[(String, Team)] = []
  let set = (k : String, t : Team) => match out.search_by(p => p.0 == k) {
    Some(i) => out[i] = (k, t)
    None => out.push((k, t))
  }
  let connects = match field(raw, "connects") {
    Some(Array(a)) => a
    _ => []
  }
  for c in connects {
    guard field(c, "id") is Some(String(id)) else { continue }
    match field(c, "kind") {
      Some(String("feishu")) => {
        set(id, { id, name: str_in(Some(c), ["feishu", "tenant", "name"]).unwrap_or(""), book: "feishu" })
        continue
      }
      Some(String("comma")) => {
        set(id, { id, name: "", book: "comma" })
        continue
      }
      Some(String("group")) => {
        set(id, { id, name: "", book: "group" })
        continue
      }
      _ => ()
    }
    match str_in(Some(c), ["slack", "team", "id"]) {
      Some(team) if team != "" => set(id, { id: team, name: str_in(Some(c), ["slack", "team", "name"]).unwrap_or(""), book: "slack" })
      _ => ()
    }
  }
  out
}

///|
/// slack-known.ts `remoteTeams`.
pub fn remote_teams(raw : Json) -> Array[(String, Team)] {
  let out : Array[(String, Team)] = []
  match raw {
    Object(m) =>
      for id, r in m {
        let d = field(r, "described")
        match str_in(d, ["kind"]) {
          Some("feishu") => out.push((id, { id, name: str_in(d, ["identity", "team"]).unwrap_or(""), book: "feishu" }))
          Some("slack") =>
            match str_in(d, ["team"]) {
              Some(team) if team != "" =>
                out.push((id, { id: team, name: str_in(d, ["identity", "team"]).unwrap_or(""), book: "slack" }))
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// slack-known.ts `teamIn`: a connect's place, `<connect>@<station>` by the connect of that name.
pub fn team_in(all : Array[(String, Team)], connect : String) -> Team? {
  match all.search_by(p => p.0 == connect) {
    Some(k) => Some(all[k].1)
    None => {
      let at = index_of(connect, "@")
      if at > 0 {
        let c = sub(connect, 0, at)
        match all.search_by(p => p.0 == c) {
          Some(k) => Some(all[k].1)
          None => None
        }
      } else {
        None
      }
    }
  }
}

///|
/// keys.ts `personKey`.
pub fn person_key(place : String, user : String) -> String {
  "u:" + place + ":" + user
}

///|
/// slack-known.ts `personIn`: a person as a names book has them.
pub fn person_in(book : Json, team : Team?, user : String) -> Json {
  let key = person_key(
    match team {
      Some(t) => t.id
      None => "?"
    },
    user,
  )
  let person = match book {
    Object(m) =>
      match m.get(key) {
        Some(Object(_) as e) => field(e, "person")
        _ => None
      }
    _ => None
  }
  match person {
    Some(Object(_) as p) =>
      match field(p, "name") {
        Some(String(name)) =>
          {
            "name": js(name),
            "email": js(match field(p, "email") { Some(String(e)) => e; _ => "" }),
            "picture": js(match field(p, "picture") { Some(String(e)) => e; _ => "" }),
          }
        _ => Json::null()
      }
    _ => Json::null()
  }
}

///|
/// slack-known.ts `KnownNames.teams`: this station's own over other stations'.
pub fn all_teams(config : Json, remote : Json) -> Array[(String, Team)] {
  let own = config_teams(config)
  let rem = remote_teams(remote)
  if rem.is_empty() {
    return own
  }
  let out = rem.copy()
  for p in own {
    match out.search_by(x => x.0 == p.0) {
      Some(k) => out[k] = p
      None => out.push(p)
    }
  }
  out
}

///|
/// slack-known.ts `KnownNames.person`: by the connect's place, in its book.
pub fn known_person(config : Json, remote : Json, books : Json, connect : String, user : String) -> Json {
  let team = team_in(all_teams(config, remote), connect)
  let book = match team {
    Some(t) => t.book
    None => "slack"
  }
  person_in(field(books, book).unwrap_or(Json::null()), team, user)
}

// ── views.ts ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// views.ts `configOf`: the connects (each its name: its bot's, else its id) and whether done chats are reviewed.
pub fn views_config(raw : Json) -> Json {
  let connects = match field(raw, "connects") {
    Some(Array(a)) => a
    _ => []
  }
  let out : Array[Json] = []
  for c in connects {
    guard field(c, "id") is Some(String(id)) else { continue }
    let bot = match str_in(Some(c), ["slack", "botName"]) {
      Some(b) if b != "" => b
      _ => id
    }
    out.push({ "id": js(id), "name": js(bot) })
  }
  let reviews = match field(raw, "automaticDecisions") {
    Some(Object(_) as a) =>
      match field(a, "completion") {
        Some(Object(_) as c) => field(c, "enabled") is Some(True)
        _ => false
      }
    _ => false
  }
  { "connects": Json::array(out), "reviews": jb(reviews) }
}

///|
/// views.ts `authorNames`' rule: an author's name, by their kind. `station`: the station's own; an agent by the
/// connect it posts through (`via`, a member's connect not still.fail's), else its session's, by the connects' names,
/// else its session's title; on still.fail's surface a person by the names known (`local`: the page's admin);
/// elsewhere by their connect's book (the first member's connect not still.fail's).
pub fn author_name(
  kind : String,
  author : String,
  surface : String?,
  members : Array[(String, String)],
  session_connect : String?,
  session_title : String?,
  connects : Array[(String, String)],
  names : Array[(String, String)],
  admin : String?,
  person : (String, String) -> Json,
) -> (String?, String?) {
  // (rows.ts STATION_AUTHOR: the station itself)
  if kind == "station" {
    return (Some("still.fail"), None)
  }
  if kind == "agent" {
    let via = match members.search_by(m => m.0 == author) {
      Some(k) => Some(members[k].1)
      None => None
    }
    let connect = match via {
      Some(v) if v != "chat" => Some(v)
      _ => session_connect
    }
    let named = match connect {
      Some(c) =>
        match connects.search_by(x => x.0 == c) {
          Some(k) => Some(connects[k].1)
          None => None
        }
      None => None
    }
    return (
      match named {
        Some(n) => Some(n)
        None => session_title
      },
      None,
    )
  }
  if surface == Some("chat") {
    return (if author == "local" { admin } else { Some(env_get(names, author).unwrap_or(author)) }, None)
  }
  let connect = match members.search_by(m => m.1 != "chat") {
    Some(k) => Some(members[k].1)
    None => None
  }
  let p = match connect {
    Some(c) => person(c, author)
    None => Json::null()
  }
  let name = match field(p, "name") {
    Some(String(n)) if n != "" => Some(n)
    _ => None
  }
  let picture = match field(p, "picture") {
    Some(String(x)) if x != "" => Some(x)
    _ => None
  }
  (name, picture)
}

// ── machine.ts ───────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let rollout_depth : Int = 8

///|
pub let rollout_entries : Int = 100000

///|
/// machine.ts `roots`: Claude Code's projects and Codex's sessions.
pub fn machine_roots(home : String?, codex_home : String?) -> (String, String) {
  let h = home.unwrap_or(".")
  let codex = match codex_home {
    Some(c) if c != "" => c
    _ => posix_join([h, ".codex"])
  }
  (posix_join([h, ".claude", "projects"]), posix_join([codex, "sessions"]))
}

///|
/// machine.ts `extension`.
pub fn extension(name : String) -> String? {
  let dot = last_index_of(name, ".")
  if dot > 0 {
    Some(sub(name, dot + 1, name.length()))
  } else {
    None
  }
}

///|
/// machine.ts `rolloutOf`.
pub fn rollout_of(path : String, id : String) -> Bool {
  let name = posix_basename(path)
  ends(name, "-" + id + ".jsonl") || has(name, "-" + id + "_")
}

///|
/// machine.ts `transcriptOf`: where the machine keeps a session's transcript, None where none.
pub fn transcript_of(fs : Fs, claude : String, codex : String, runtime : String, id : String) -> String? raise {
  if id == "" || !all_units(id, c => is_alnum(c) || c == 45) {
    return None
  }
  if runtime == "claude" {
    // In the file system's order (as opendir gives them).
    let names = match fs.call("fs.readdir", { "path": js(claude), "disk": true }) {
      Array(a) => a.filter_map(x => match x { String(s) => Some(s); _ => None })
      _ => return None
    }
    let mut left = rollout_entries
    for n in names {
      if left <= 0 {
        break
      }
      left -= 1
      let path = posix_join([claude, n, id + ".jsonl"])
      if fs.kind(path) == Some("file") {
        return Some(path)
      }
    }
    return None
  }
  let mine = []
  let o = { ..WalkOptions::default(() => 0.0), max_depth: rollout_depth, max_entries: rollout_entries, follow_root: true }
  ignore(
    walk_bounded(
      fs,
      [codex],
      e => {
        if e.file && e.depth > 0 && starts(e.name, "rollout-") && extension(e.name) == Some("jsonl") && rollout_of(e.path, id) {
          mine.push(e.path)
        }
        Go
      },
      o,
    ),
  )
  let mut latest : (Double, String)? = None
  for path in mine {
    match fs.meta_ms(path) {
      Some((_, Some(ms), false)) => {
        match latest {
          Some((l, _)) if !(ms > l) => ()
          _ => latest = Some((ms, path))
        }
      }
      _ => ()
    }
  }
  latest.map(l => l.1)
}

// ── jobs.ts ──────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// jobs.ts `outputAt`: when a log last grew (ms), where it has anything in it.
pub fn output_at(fs : Fs, path : String) -> Double? raise {
  match fs.meta_ms(path) {
    Some((size, Some(at), _)) if size > 0.0 => Some(at)
    _ => None
  }
}

///|
/// jobs.ts `rustLines`: str::lines.
pub fn rust_lines(text : String) -> Array[String] {
  if text == "" {
    return []
  }
  let parts = split_on(text, "\n")
  let ended = parts[parts.length() - 1] == ""
  if ended {
    parts.pop() |> ignore
  }
  let n = parts.length()
  parts.mapi((i, l) => if (i < n - 1 || ended) && ends(l, "\r") { sub(l, 0, l.length() - 1) } else { l })
}

///|
/// jobs.ts `tail`: the last `lines` lines of a log (its last 64 KiB), on into `<log>.1` where it was cut lately.
pub fn log_tail(fs : Fs, path : String, lines : Int) -> String raise {
  let tail_lines = (p : String) => match fs.call("fs.tail", { "path": js(p), "bytes": ji(65536) }) {
    String(t) => rust_lines(t)
    _ => []
  }
  let now = tail_lines(path)
  if now.length() >= lines {
    return now[now.length() - lines:].to_owned().join("\n")
  }
  let before = tail_lines(path + ".1")
  let all = [..before, ..now]
  all[@cmp.maximum(0, all.length() - lines):].to_owned().join("\n")
}

// ── transcript-soon.ts and transcripts.ts ────────────────────────────────────────────────────────────────────────

///|
/// transcript-soon.ts `rolloutUnder`: the Codex rollout of `id` under `dir` (its `.zst`'s `.jsonl` path once put away).
pub fn rollout_under(fs : Fs, dir : String, id : String) -> String? raise {
  let mut found : String? = None
  let o = {
    ..WalkOptions::default(() => 0.0),
    follow_root: true,
    follow_links: true,
    same_device: false,
    max_depth: rollout_depth,
    max_entries: rollout_entries,
  }
  ignore(
    walk_bounded(
      fs,
      [dir],
      e => {
        if e.depth == 0 || e.directory || !starts(e.name, "rollout-") {
          return Go
        }
        if ends(e.name, id + ".jsonl") {
          found = Some(e.path)
        } else if ends(e.name, id + ".jsonl.zst") {
          found = Some(sub(e.path, 0, e.path.length() - 4))
        } else {
          return Go
        }
        Stop
      },
      o,
    ),
  )
  found
}

///|
/// transcript-soon.ts `answer`: a `Looking`'s question answered (`there`, `file`, `names`, `real`, `rollout`).
pub fn look_answer(fs : Fs, look : Json) -> Json raise {
  let path = str_or(look, "path", "")
  match str_or(look, "ask", "") {
    "there" => jb(fs.lstat(path) is Some(_) || fs.kind(path) is Some(_))
    "file" => jb(fs.kind(path) == Some("file"))
    "names" =>
      match fs.names(path) {
        Some(n) => jstrs(n)
        None => Json::null()
      }
    "real" => opt_s(fs.realpath(path))
    "rollout" => opt_s(rollout_under(fs, path, str_or(look, "id", "")))
    _ => Json::null()
  }
}

///|
/// transcripts.ts `marksDir`.
pub fn transcript_marks_dir(data : String) -> String {
  posix_join([data, "transcript-marks"])
}

///|
/// transcripts.ts `fileOf`: a transcript's reading's file (the SHA-1 of its path).
pub fn transcript_mark_file(dir : String, path : String) -> String {
  posix_join([dir, sha1_hex(@utf8.encode(path)) + ".json"])
}

///|
/// transcripts.ts `forgetMarksSoon`: what is kept of these transcripts' readings let go.
pub fn forget_marks(fs : Fs, dir : String, paths : Array[String]) -> Unit raise {
  for p in paths {
    fs.remove(transcript_mark_file(dir, p))
  }
}

///|
/// SHA-1, hex.
pub using @hash {sha1_hex}

// ── usage.ts ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
let price_list : Array[(String, Double, Double, Double)] = [
  ("gpt-6-astra", 10.0, 50.0, 1.0),
  ("gpt-6.1-sol", 2.0, 10.0, 0.1),
  ("gpt-6.1-terra", 1.0, 5.0, 0.05),
  ("gpt-6-sol", 2.0, 10.0, 0.2),
  ("gpt-6-luna", 0.1, 0.5, 0.01),
  ("gpt-5.6-sol", 4.0, 20.0, 0.4),
  ("claude-fable-5-2", 8.0, 40.0, 0.2),
  ("claude-fable-5-1", 10.0, 50.0, 0.25),
  ("claude-mythos-5-1", 10.0, 50.0, 0.25),
  ("claude-fable-5", 10.0, 50.0, 1.0),
  ("claude-mythos-5", 10.0, 50.0, 1.0),
  ("claude-opus-5-5", 4.0, 20.0, 0.2),
  ("claude-opus-5", 5.0, 25.0, 0.5),
  ("claude-opus-4-8", 5.0, 25.0, 0.5),
  ("claude-opus-4-7", 5.0, 25.0, 0.5),
  ("claude-opus-4-6", 5.0, 25.0, 0.5),
  ("claude-opus-4-5", 5.0, 25.0, 0.5),
  ("claude-sonnet-5-5", 2.0, 10.0, 0.1),
  ("claude-sonnet-5", 2.0, 10.0, 0.2),
  ("claude-sonnet-4-6", 3.0, 15.0, 0.3),
  ("claude-sonnet-4-5", 3.0, 15.0, 0.3),
  ("claude-haiku-4-5", 1.0, 5.0, 0.1),
]

///|
/// catalog.ts `facts`: what the model catalog (readops' `model_catalog`, learned as the pool gives it) says of a model.
fn model_facts(model : String) -> Json? {
  let key = @readops.model_key(model)
  let at = index_of(key, "[")
  let bare = if at >= 0 { sub(key, 0, at) } else { key }
  match @readops.model_catalog.val.get(bare) {
    Some(f) => Some(f)
    None =>
      match @readops.split_agy_tier(bare) {
        Some(m) => @readops.model_catalog.val.get(m)
        None => None
      }
  }
}

///|
/// usage.ts `price`: a model's prices (input, output, cache read), the catalog's, else the station's table's.
pub fn model_price(model : String) -> (Double, Double, Double)? {
  match model_facts(model) {
    Some(f) =>
      match field(f, "cost") {
        Some(Object(_) as told) =>
          match (num_field(told, "input"), num_field(told, "output")) {
            (Some(i), Some(o)) => return Some((i, o, num_field(told, "cacheRead").unwrap_or(i)))
            _ => ()
          }
        _ => ()
      }
    None => ()
  }
  let name = @readops.model_key(model)
  let listed = (candidate : String) => {
    for p in price_list {
      if candidate == p.0 || (starts(candidate, p.0) && starts(sub(candidate, p.0.length(), candidate.length()), "[")) {
        return Some((p.1, p.2, p.3))
      }
    }
    None
  }
  match listed(name) {
    Some(p) => return Some(p)
    None => ()
  }
  let at = index_of(name, "[")
  let bare = if at >= 0 { sub(name, 0, at) } else { name }
  match @readops.split_agy_tier(bare) {
    None => None
    Some(m) => listed(if at >= 0 { m + sub(name, at, name.length()) } else { m })
  }
}

///|
/// usage.ts `cost`: what a group's calls would cost, dollars (None: no model, or none priced).
pub fn usage_cost(g : Json) -> Double? {
  guard field(g, "model") is Some(String(model)) else { return None }
  guard model_price(model) is Some((input, output, cache_read)) else { return None }
  let n = (k : String) => num_field(g, k).unwrap_or(0.0)
  let tokens = n("input") * input +
    n("cacheWrite") * input * 1.25 +
    n("cacheWriteLong") * input * 2.0 +
    n("cacheRead") * cache_read +
    n("output") * output
  Some(tokens / 1.0e6 * (if field(g, "fast") is Some(True) { 2.0 } else { 1.0 }))
}

///|
/// usage.ts `sessionUsage`.
pub fn session_usage(groups : Array[Json]) -> Json {
  let mut calls = 0.0
  let mut input = 0.0
  let mut cached = 0.0
  let mut output = 0.0
  let mut cost = 0.0
  let mut unpriced = 0.0
  for g in groups {
    let n = (k : String) => num_field(g, k).unwrap_or(0.0)
    calls += n("calls")
    input += n("input") + n("cacheRead") + n("cacheWrite") + n("cacheWriteLong")
    cached += n("cacheRead")
    output += n("output")
    match usage_cost(g) {
      None => unpriced += n("calls")
      Some(c) => cost += c
    }
  }
  {
    "modelCalls": jn(calls),
    "inputTokens": jn(input),
    "cachedTokens": jn(cached),
    "outputTokens": jn(output),
    "cost": jn(cost),
    "unpricedCalls": jn(unpriced),
  }
}

///|
/// usage.ts `usageNow`: a session's usage now, from its groups, its last contexts (oldest first), where its conversation
/// began and what was saved of a compacted context; None before a call of it is recorded.
pub fn usage_now(groups : Array[Json], contexts : Array[Json], since : Double?, saved : Json?) -> Json {
  let counted = session_usage(groups)
  if num_field(counted, "modelCalls") == Some(0.0) {
    return Json::null()
  }
  let out : Map[String, Json] = match counted {
    Object(m) => m
    _ => Map([])
  }
  let latest = contexts.last()
  out["model"] = match latest {
    Some(l) => field(l, "model").unwrap_or(Json::null())
    None => Json::null()
  }
  out["contextWindow"] = match latest {
    Some(l) => field(l, "window").unwrap_or(Json::null())
    None => Json::null()
  }
  let calls = match since {
    None => []
    Some(s) => contexts.filter(c => num_field(c, "at").unwrap_or(0.0) >= s)
  }
  match calls.last() {
    Some(last) => {
      match field(last, "context") {
        Some(Number(c, ..)) => out["contextTokens"] = jn(c)
        _ => ()
      }
      out["lastCallAt"] = field(last, "at").unwrap_or(Json::null())
      let wrote = {
        let mut w : Json? = None
        for c in calls {
          if num_field(c, "cacheWrite").unwrap_or(0.0) + num_field(c, "cacheWriteLong").unwrap_or(0.0) > 0.0 {
            w = Some(c)
          }
        }
        w
      }
      match wrote {
        Some(w) => {
          let long = num_field(w, "cacheWriteLong").unwrap_or(0.0) > 0.0
          out["cacheMs"] = jn(if long { 3600000.0 } else { 300000.0 })
          let p = match field(last, "model") {
            Some(String(m)) => model_price(m)
            _ => None
          }
          match (p, field(last, "context")) {
            (Some((input, _, _)), Some(Number(c, ..))) =>
              out["rereadCost"] = jn(
                c * input * (if long { 2.0 } else { 1.25 }) / 1.0e6 *
                (if field(last, "fast") is Some(True) { 2.0 } else { 1.0 }),
              )
            _ => ()
          }
        }
        None => ()
      }
    }
    None => ()
  }
  match (saved, since) {
    (Some(Object(_) as s), Some(since)) => {
      let at = num_field(s, "lastCallAt").unwrap_or(0.0)
      let later = match latest {
        None => true
        Some(l) => at > num_field(l, "at").unwrap_or(0.0)
      }
      if at >= since && later {
        out["model"] = field(s, "model").unwrap_or(Json::null())
        out["contextWindow"] = field(s, "contextWindow").unwrap_or(Json::null())
        out["lastCallAt"] = jn(at)
        for name in ["contextTokens", "cacheMs", "rereadCost"] {
          match field(s, name) {
            Some(v) => out[name] = v
            None => out.remove(name)
          }
        }
      }
    }
    _ => ()
  }
  Json::object(out)
}
