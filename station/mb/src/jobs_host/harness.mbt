// The package's harness (reader `--builder harness-jobs-host`): a case a line, answered a line each, until stdin
// ends, for station/test/mb-jobs-host.test.ts to compare with the TypeScript it replaces. A case is `{op, …}`,
// answered `{ok}` or `{error}`.

///|
fn list_of(v : Json?) -> Array[Json] {
  match v {
    Some(Array(a)) => a
    _ => []
  }
}

///|
fn or_null(v : Json?) -> Json {
  v.unwrap_or(Json::null())
}

///|
fn some_json(v : Json?) -> Json? {
  match v {
    Some(Null) | None => None
    Some(x) => Some(x)
  }
}

///|
fn str_opt(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn gpu_list(g : Array[Gpu]) -> Json {
  Json::array(g.map(x => x.to_json()))
}

///|
fn opt_gpus(g : Array[Gpu]?) -> Json {
  match g {
    Some(x) => gpu_list(x)
    None => Json::null()
  }
}

///|
/// A command's printing as a case says it: {out}, null (failed), "absent".
fn ran_from(v : Json?) -> Ran {
  match v {
    Some(Object(_) as o) =>
      match field(o, "out") {
        Some(String(s)) => Out(s)
        _ => Failed
      }
    Some(String("absent")) | None => Absent
    _ => Failed
  }
}

///|
fn header_pairs(v : Json?) -> Array[(String, String)] {
  list_of(v).filter_map(p => match p {
    [String(k), String(x)] => Some((k, x))
    _ => None
  })
}

///|
fn header_json(ps : Array[(String, String)]) -> Json {
  Json::array(ps.map(p => Json::array([jstr(p.0), jstr(p.1)])))
}

///|
fn base64_of(v : Json?) -> Bytes {
  match v {
    Some(String(s)) => @base64.decode(s) catch { _ => b"" }
    _ => b""
  }
}

///|
fn pure_case(op : String, c : Json) -> Json? raise {
  let t = (k : String) => text(c, k)
  let r : Json = match op {
    "gpu.apple" => apple_gpu(t("text")).map(g => g.to_json()).unwrap_or(Json::null())
    "gpu.nvidia" => gpu_list(nvidia_gpus(t("text")))
    "gpu.windows" => gpu_list(windows_amd_gpus(t("text")))
    "gpu.mac" =>
      Json::array(
        mac_discrete_gpus(t("text")).map(v => obj([("vendor", jstr(v.vendor)), ("gpu", v.gpu.to_json())])),
      )
    "gpu.pci" => {
      let m : Map[String, Json] = Map([])
      for k, v in pci_names(t("text")) {
        m[k] = jstr(v)
      }
      Json::object(m)
    }
    "gpu.amd" => jbool(amd_integrated(str_opt(field(c, "id"))))
    "load.summary" => jstr(summary(or_null(field(c, "load"))))
    "load.detailed" => detailed(or_null(field(c, "described")))
    "links.text" => jstr(html_text(t("text")))
    "links.public" => jbool(is_public(t("address")))
    "links.ip" => jint(ip_kind(t("address")))
    "links.head" =>
      match @cloud_net.parse_url(t("base")) {
        Some(b) => head_of(t("html"), b)
        None => raise HostError("bad base")
      }
    "links.oembed" =>
      match @cloud_net.parse_url(t("url")) {
        Some(u) =>
          match oembed_of(u) {
            Some(s) => jstr(s)
            None => Json::null()
          }
        None => raise HostError("bad url")
      }
    "links.resolve" =>
      match @cloud_net.parse_url(t("base")) {
        Some(b) =>
          match resolve_url(t("ref"), b) {
            Some(u) => jstr(u.href())
            None => Json::null()
          }
        None => raise HostError("bad base")
      }
    "links.time" =>
      match iso_time(t("text")) {
        Some(x) => jnum(x)
        None => Json::null()
      }
    "preview.target" =>
      match preview_target(t("path")) {
        Some((p, path)) => Json::array([jint(p), jstr(path)])
        None => Json::null()
      }
    "preview.frame" =>
      jstr(@base64.encode(frame(num(field(c, "kind")).unwrap_or(0.0).to_int(), base64_of(field(c, "payload")))))
    "dirsync.blob" => jstr(blob_id(base64_of(field(c, "content"))))
    "remote.hash" => jstr(remote_hash(or_null(field(c, "value"))))
    "remote.budget" => jnum(remote_budget(num(field(c, "total"))))
    "remote.base64" => jstr(@base64.encode(from_base64(t("data"))))
    "remote.describe" =>
      describe_answer(t("version"), t("os"), t("arch"), some_json(field(c, "load")), some_json(field(c, "more")))
    "remote.named" =>
      jstr(station_named(t("named"), list_of(field(c, "sandboxes")).map(js_text), some_json(field(c, "roster"))))
    "remote.workspace" => jstr(task_workspace(or_null(field(c, "state")), str_opt(field(c, "own"))))
    "remote.targets" => or_null(targets_of(field(c, "record"), t("workspace")))
    "remote.recordUse" =>
      or_null(record_used(some_json(field(c, "had")), t("workspace"), t("session"), t("station")))
    "remote.closing" => or_null(record_closing(field(c, "had"), num(field(c, "since")).unwrap_or(0.0)))
    "remote.portable" => jstr(portable_component(t("name")))
    "jobs.json" => job_json(or_null(field(c, "job")))
    "jobs.named" => jstr(job_named(t("id"), t("name"), num(field(c, "port"))))
    "jobs.moved" =>
      jstr(moved_said(t("why"), str_opt(field(c, "id")), t("name"), num(field(c, "port")), str_opt(field(c, "error"))))
    "jobs.shownName" => jstr(shown_name(t("name"), t("command")))
    "jobs.exitCode" =>
      match exit_code_of(t("text")) {
        Some(x) => jnum(x)
        None => Json::null()
      }
    "jobs.claims" => held_claims(str_opt(field(c, "text")))
    "jobs.fileId" =>
      match job_file_id(t("name"), t("sub")) {
        Some(x) => jstr(x)
        None => Json::null()
      }
    "jobs.lines" => Json::array(rust_lines(t("text")).map(jstr))
    "jobs.constants" =>
      obj([("wrapper", jstr(wrapper)), ("command", jstr(job_command)), ("name", jstr(job_command_name))])
    _ => return None
  }
  Some(r)
}

///|
/// The harness's cases, by `op`: each answered `{ok}` or `{error}`.
pub async fn harness_case(host : @host.Host, c : Json) -> Json {
  let op = text(c, "op")
  try {
    match pure_case(op, c) {
      Some(v) => { "ok": v }
      None => { "ok": io_case(host, op, c) }
    }
  } catch {
    e => { "error": jstr(peer_words(e)) }
  }
}

///|
/// The program's harness: a case a line, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  while true {
    guard host.line() is Some(line) else { break }
    let answer = match (try { Some(@json.parse(line)) } catch { _ => None }) {
      Some(c) => harness_case(host, c)
      None => { "error": jstr("not JSON") }
    }
    host.say(answer.stringify())
  }
}
