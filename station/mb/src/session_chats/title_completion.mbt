// A text-only completion for a keyed DeepSeek Harness profile whose provider speaks chat completions (station/src/
// sessions/title-completion.ts): the profile's own endpoint and key, never tools. A profile's route and environment are
// the agents' parts' (`dep.dshRoute`, `dep.profileEnv`, `dep.expandRoute`), a URL the platform's (`dep.parseUrl`).

///|
let dsh_key : String = "STILLFAIL_DSH_KEY"

///|
/// The completion a profile gives a title, or None.
pub async fn title_completion(w : World, profile : J, model : String?, session : String) -> J? {
  let runtimes = arr_of(at(Some(profile), "runtimes")).unwrap_or([])
  if !runtimes.iter().any(r => str_of(Some(r)) == Some("dsh")) {
    return None
  }
  let route = w.dep("dshRoute", [profile])
  if route is Null {
    return None
  }
  let kind = str_of(at(Some(route), "kind")).unwrap_or("")
  if kind == "pi" && str_of(at(Some(route), "api")) != Some("openai-completions") {
    return None
  }
  let chosen = match model {
    Some(m) if m != "" =>
      match spelling(w, profile, m) {
        Some(s) => Some(s)
        None => Some(m)
      }
    _ =>
      match str_of(at(Some(profile), "model")) {
        Some(m) => Some(m)
        None => if kind == "deepseek" { Some("deepseek-v4-flash") } else { None }
      }
  }
  guard chosen is Some(chosen) && chosen != "" else { return None }
  let env = w.dep("profileEnv", [profile, js("dsh")])
  let key = if kind == "deepseek" { at(Some(env), "DEEPSEEK_API_KEY") } else { at(Some(env), dsh_key) }
  let base = if kind == "deepseek" { js("https://api.deepseek.com") } else { at(Some(route), "baseURL").unwrap_or(Null) }
  let url = w.dep("parseUrl", [base])
  if url is Null {
    return None
  }
  let hostname = str_of(at(Some(url), "hostname")).unwrap_or("")
  let protocol = str_of(at(Some(url), "protocol")).unwrap_or("")
  let local = hostname == "localhost" || hostname == "127.0.0.1" || hostname == "[::1]"
  let empty = (k : String) => str_of(at(Some(url), k)).unwrap_or("") == ""
  if !(protocol == "https:" || (protocol == "http:" && local)) || !empty("username") || !empty("password") || !empty("search") || !empty("hash") {
    return None
  }
  let headers = if kind == "pi" {
    w.dep("expandRoute", [match at(Some(route), "headers") { Some(Obj(_) as h) => h; _ => J::Obj([]) }, js(session)])
  } else {
    J::Obj([])
  }
  let mut href = str_of(at(Some(url), "href")).unwrap_or("")
  while ends(href, "/") {
    href = slice(href, 0, b=href.length() - 1)
  }
  let key_text = match key {
    Some(Str(u)) => if @jsjson.sanitize_str(u) == "none" { "" } else { @jsjson.sanitize_str(u) }
    _ => ""
  }
  Some(jo([("endpoint", js("\{href}/chat/completions")), ("key", js(key_text)), ("model", js(chosen)), ("headers", headers)]))
}

///|
/// Asks the completion for a title: what it answers, or what refused.
pub async fn complete_title(w : World, config : J, instructions : String, input : String) -> String {
  let mut headers = spread(match at(Some(config), "headers") { Some(Obj(_) as h) => h; _ => J::Obj([]) }, jo([("content-type", js("application/json"))]))
  let key = str_of(at(Some(config), "key")).unwrap_or("")
  if key != "" {
    headers = set_field(headers, "authorization", js("Bearer \{key}"))
  }
  let body = stringify(
    jo([
      ("model", at(Some(config), "model").unwrap_or(Null)),
      ("stream", jb(false)),
      ("max_tokens", ji(128)),
      (
        "messages",
        ja([
          jo([("role", js("system")), ("content", js(instructions))]),
          jo([("role", js("user")), ("content", js(input))]),
        ]),
      ),
    ]),
  )
  let response = w.ask("net.fetch", [
    at(Some(config), "endpoint").unwrap_or(Null),
    jo([("method", js("POST")), ("headers", headers), ("body", js(body)), ("redirect", js("manual"))]),
  ])
  if !(at(Some(response), "ok") is Some(Bool(true))) {
    raise fail_("title completion failed")
  }
  let buf = StringBuilder::new()
  let mut size = 0
  for c in arr_of(at(Some(response), "chunks")).unwrap_or([]) {
    let t = str_of(Some(c)).unwrap_or("")
    size += byte_length(t)
    if size > 256000 {
      raise fail_("title completion too large")
    }
    buf.write_string(t)
  }
  let answer = parse_js(buf.to_string())
  let message = at(at_i(at(Some(answer), "choices"), 0), "message")
  let text = str_of(at(message, "content"))
  let tools = match at(message, "tool_calls") {
    Some(Arr(xs)) => xs.length() > 0
    Some(Str(u)) => u.length() > 0
    _ => false
  }
  match text {
    Some(t) if !tools => t
    _ => raise fail_("title completion missing")
  }
}
