// What the station asks of the memory's program (`--builder memory`, station/src/share/memory-mb.ts): a line of JSON
// an ask, `{id, op, …}`, answered `{id, …}` (or `{id, error}`), one at a time. Content goes as hex both ways, so that
// what is no text (or no UTF-8) arrives as it is.

///|
fn hex_field(j : Json, key : String) -> Bytes raise {
  match str_field(j, key) {
    Some(h) => @hex.decode(h)
    None => raise Failed("no \{key}")
  }
}

///|
fn text_field(j : Json, key : String) -> String raise {
  text_of(hex_field(j, key))
}

///|
fn hex_json(s : String) -> Json {
  Json::string(@hex.encode(@utf8.encode(s)))
}

///|
fn need_str(j : Json, key : String) -> String raise {
  match str_field(j, key) {
    Some(s) => s
    None => raise Failed("no \{key}")
  }
}

///|
fn object_field(j : Json, key : String) -> Map[String, Json] {
  match field(j, key) {
    Some(Object(o)) => o
    _ => Map([])
  }
}

///|
fn lines_field(j : Json, key : String) -> Array[String] {
  strs_field(j, key)
}

///|
/// The version contents an ask brings (`given`, hash → hex) and those kept in its blobs.
fn contents(blobs : Blobs, ask : Json) -> async (String) -> Bytes? {
  let given = object_field(ask, "given")
  async fn(hash : String) -> Bytes? {
    if hash == "" {
      return None
    }
    match given.get(hash) {
      Some(String(hex)) => Some(@hex.decode(hex)) catch { _ => None }
      _ => blobs.content(hash)
    }
  }
}

///|
/// The answer to one ask (its `id` put on by the caller).
pub async fn answer(host : @host.Host, ask : Json, sep : String) -> Json {
  let op = str_field(ask, "op").unwrap_or("")
  let blobs = Blobs::new(host, str_field(ask, "blobs").unwrap_or(""), sep)
  match op {
    "scan" => {
      let kept : Map[String, String] = Map([])
      for path, h in object_field(ask, "kept") {
        if h is String(s) {
          kept[path] = s
        }
      }
      scan(blobs, {
        dir: need_str(ask, "dir"),
        kept,
        builtin: strs_field(ask, "builtin"),
        skipped: strs_field(ask, "skipped"),
        file_most: num_field(ask, "fileMost").unwrap_or(0),
        skill_most: num_field(ask, "skillMost").unwrap_or(0),
        skill_files: num_field(ask, "skillFiles").unwrap_or(0).to_int(),
      })
    }
    "decide" => {
      guard field(ask, "theirs") is Some(t) && rec_of(t) is Some(theirs) else {
        raise Failed("no record")
      }
      let mine = match field(ask, "mine") {
        Some(m) => rec_of(m)
        None => None
      }
      let names = object_field(ask, "names")
      let name_of = fn(station : String) -> String {
        match names.get(station) {
          Some(String(name)) => name
          _ => station
        }
      }
      let content = contents(blobs, ask)
      let outcome = decide(
        need_str(ask, "path"),
        mine,
        theirs,
        content,
        async fn(bytes) { blobs.keep(bytes) },
        name_of,
        num_field(ask, "prevMost").unwrap_or(16).to_int(),
      )
      match outcome {
        Keep => { "kind": "keep" }
        // (and whether its content is here, brought or kept, to be written)
        Take => { "kind": "take", "content": Json::boolean(content(theirs.hash) is Some(_)) }
        Merge(rec, beside) =>
          {
            "kind": "merge",
            "rec": rec_json(rec),
            "beside": match beside {
              Some((path, r)) => { "path": Json::string(path), "rec": rec_json(r) }
              None => Json::null()
            },
          }
      }
    }
    "have" => {
      let out = []
      for h in strs_field(ask, "hashes") {
        out.push(Json::boolean(blobs.has(h)))
      }
      { "have": Json::array(out) }
    }
    "hash" =>
      match hash_of(host, need_str(ask, "path")) {
        Some(h) => { "hash": Json::string(h) }
        None => { "hash": Json::null() }
      }
    "asides" => {
      // memory.ts `#mend`: the skills kept apart, `<base>-<tag>` whose front matter names it so and says `[<station>]`
      // of that tag.
      let out : Array[Json] = []
      let skills = match field(ask, "skills") {
        Some(Array(xs)) => xs
        _ => []
      }
      for s in skills {
        guard str_field(s, "skill") is Some(skill) &&
          str_field(s, "hash") is Some(hash) &&
          str_field(s, "author") is Some(author) else {
          continue
        }
        guard blobs.content(hash) is Some(bytes) else { continue }
        let text = text_of(bytes)
        guard aside_of(text, skill) is Some(said) else { continue }
        let tag = station_tag(said)
        if !skill.has_suffix("-\{tag}") || skill.length() == tag.length() + 1 {
          continue
        }
        out.push(
          Json::object({
            "skill": Json::string(skill),
            "base": Json::string(skill.unsafe_substring(start=0, end=skill.length() - tag.length() - 1)),
            "tag": Json::string(tag),
            "author": Json::string(station_tag(author)),
            "body": Json::string(body_of(text)),
          }),
        )
      }
      { "asides": Json::array(out) }
    }
    "alikeKept" => {
      let content = contents(blobs, ask)
      match (content(str_field(ask, "a").unwrap_or("")), content(str_field(ask, "b").unwrap_or(""))) {
        (Some(a), Some(b)) => { "alike": Json::boolean(alike(text_of(a), text_of(b))) }
        _ => { "alike": Json::null() }
      }
    }
    "tags" => {
      let out = []
      for name in strs_field(ask, "names") {
        out.push(Json::string(station_tag(name)))
      }
      { "tags": Json::array(out) }
    }
    // What the tests hold to the TypeScript of before (station/test/mb-memory-merge.test.ts), each function alone.
    "isText" => { "value": Json::boolean(is_text(hex_field(ask, "bytes"))) }
    "matches" =>
      match matches(lines_field(ask, "a"), lines_field(ask, "b")) {
        Some(pairs) =>
          {
            "value": Json::array(
              pairs.map(fn(p) { Json::array([Json::number(p.0.to_double()), Json::number(p.1.to_double())]) }),
            ),
          }
        None => { "value": Json::null() }
      }
    "merge3" =>
      match merge3(text_field(ask, "base"), text_field(ask, "newer"), text_field(ask, "older")) {
        Some(t) => { "value": hex_json(t) }
        None => { "value": Json::null() }
      }
    "union" =>
      {
        "value": hex_json(
          union_lines(
            text_field(ask, "newer"),
            text_field(ask, "older"),
            str_field(ask, "newerName"),
            str_field(ask, "olderName"),
          ),
        ),
      }
    "alike" => { "value": Json::boolean(alike(text_field(ask, "a"), text_field(ask, "b"))) }
    "conflictPath" =>
      { "value": Json::string(conflict_path(need_str(ask, "path"), need_str(ask, "station"))) }
    _ => raise Failed("unknown memory op \{op}")
  }
}
