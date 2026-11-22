// station/src/ops/i18n.ts (with client/i18n/brand.ts), model-name.ts, agent-env.ts: the words people read, a model as
// people call it, the variables the agents are started with.

// ── i18n.ts ──────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// A catalog's word: one text, or one by `n` (`one`, `other`).
pub(all) enum Word {
  One(String)
  Plural(String?, String?)
}

///|
/// client/i18n/catalog's station part, both languages (its files' JSON: `{key: text | {one?, other}}`).
pub struct Catalog {
  zh : Map[String, Word]
  en : Map[String, Word]
}

///|
fn words_of(j : Json) -> Map[String, Word] {
  let out : Map[String, Word] = Map([])
  match j {
    Object(m) =>
      for k, v in m {
        match v {
          String(s) => out[k] = One(s)
          Object(_) => out[k] = Plural(str_field(v, "one"), str_field(v, "other"))
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
pub fn Catalog::from_json(zh : Json, en : Json) -> Catalog {
  { zh: words_of(zh), en: words_of(en) }
}

///|
/// i18n.ts `langOf`: Chinese for Chinese, English for any other; Chinese when nothing is said.
pub fn lang_of(locale : String?) -> String {
  let l = lower(js_trim(locale.unwrap_or("")))
  if l == "" || starts(l, "zh") {
    "zh"
  } else {
    "en"
  }
}

///|
/// brand.ts `Product`: still.fail's, or another's (monoid's) name.
pub(all) struct Product {
  name : String
  test_host : String
  id : String
  reverse : String
}

///|
pub let stillfail_product : Product = { name: "still.fail", test_host: "youdid.wtf", id: "stillfail", reverse: "fail.still" }

///|
let monoid_product : Product = { name: "monoid", test_host: "monoid.zone", id: "monoid", reverse: "build.monoid" }

///|
/// brand.ts `productOf`: the product whose cloud is at `origin` (a URL, or a bare host).
pub fn product_of(origin : String) -> Product {
  let host = match @cloud_net.parse_url(origin) {
    Some(u) => u.hostname()
    None => origin
  }
  for zone in ["monoid.build", "monoid.zone"] {
    if host == zone || ends(host, "." + zone) {
      return monoid_product
    }
  }
  stillfail_product
}

///|
/// brand.ts `branded`: still.fail's name standing alone (`/(?<![\w./@-])still\.fail(?![\w-]|\.\w)/g`) made the product's.
pub fn branded(text : String, product : Product) -> String {
  if product.name == stillfail_product.name || !has(text, "still.fail") {
    return text
  }
  let b = StringBuilder()
  let n = text.length()
  let mut i = 0
  while i < n {
    if starts(sub(text, i, n), "still.fail") {
      let before_ok = i == 0 || {
        let c = cu(text, i - 1)
        !(is_word(c) || c == 46 || c == 47 || c == 64 || c == 45)
      }
      let e = i + 10
      let after_ok = if e >= n {
        true
      } else {
        let c = cu(text, e)
        !(is_word(c) || c == 45) && !(c == 46 && e + 1 < n && is_word(cu(text, e + 1)))
      }
      if before_ok && after_ok {
        b.write_string(product.name)
        i = e
        continue
      }
    }
    b.write_char(Int::unsafe_to_char(cu(text, i)))
    i += 1
  }
  b.to_string()
}

///|
/// `String(v)` of an argument as the case gives it.
fn arg_text(v : Json) -> String {
  @jsjson.json_js_str(Some(v))
}

///|
/// i18n.ts `fill`: `{name}` filled; one not given, and a `{` that opens no name, left as they are.
fn fill(text : String, args : Map[String, Json]) -> String {
  if args.is_empty() || !has(text, "{") {
    return text
  }
  let b = StringBuilder()
  let n = text.length()
  let mut i = 0
  while i < n {
    if cu(text, i) == 123 {
      let mut e = i + 1
      while e < n && is_word(cu(text, e)) {
        e += 1
      }
      if e < n && cu(text, e) == 125 {
        let name = sub(text, i + 1, e)
        match args.get(name) {
          Some(v) => {
            b.write_string(arg_text(v))
            i = e + 1
            continue
          }
          None => ()
        }
      }
    }
    b.write_char(Int::unsafe_to_char(cu(text, i)))
    i += 1
  }
  b.to_string()
}

///|
/// i18n.ts `tr`: a key's words in `lang` (Chinese where it lacks them; the key where neither has it), branded for
/// `product`, `{name}` filled.
pub fn tr(
  catalog : Catalog,
  lang : String,
  key : String,
  args : Map[String, Json],
  product? : Product = stillfail_product,
) -> String {
  let found = match (if lang == "en" { catalog.en.get(key) } else { catalog.zh.get(key) }) {
    Some(w) => Some(w)
    None => catalog.zh.get(key)
  }
  let text = match found {
    Some(One(s)) => s
    Some(Plural(one, other)) => {
      let pick = match args.get("n") {
        Some(n) if js_trim(arg_text(n)) == "1" => one
        _ => other
      }
      match pick {
        Some(t) => t
        None => other.unwrap_or(key)
      }
    }
    None => key
  }
  fill(branded(text, product), args)
}

// ── model-name.ts ────────────────────────────────────────────────────────────────────────────────────────────────

///|
let claude_families : Array[String] = ["fable", "opus", "sonnet", "haiku"]

///|
fn brand_word(w : String) -> String? {
  match w {
    "deepseek" => Some("DeepSeek")
    "minimax" => Some("MiniMax")
    "qwq" => Some("QwQ")
    "glm" => Some("GLM")
    "gpt" => Some("GPT")
    "swe" => Some("SWE")
    "oss" => Some("OSS")
    "moonshot" => Some("Moonshot")
    "devstral" => Some("Devstral")
    "codestral" => Some("Codestral")
    "llama" => Some("Llama")
    "ernie" => Some("ERNIE")
    "vl" => Some("VL")
    "r1" => Some("R1")
    "it" => Some("IT")
    _ => None
  }
}

///|
/// `/^[0-9]+(\.[0-9]+)?[bmk]$/`.
fn size_word(w : String) -> Bool {
  let n = w.length()
  if n < 2 {
    return false
  }
  let last = cu(w, n - 1)
  if last != 98 && last != 109 && last != 107 {
    return false
  }
  let body = sub(w, 0, n - 1)
  let dot = index_of(body, ".")
  if dot < 0 {
    digits(body)
  } else {
    digits(sub(body, 0, dot)) && digits(sub(body, dot + 1, body.length()))
  }
}

///|
/// model-name.ts `word`.
fn model_word(w : String) -> String {
  match brand_word(w) {
    Some(b) => b
    None =>
      if size_word(w) {
        upper(w)
      } else if w == "" {
        ""
      } else {
        // `w[0].toUpperCase()`: the first code unit.
        js_upper_first(w)
      }
  }
}

///|
/// `w[0]!.toUpperCase() + w.slice(1)`: the first UTF-16 unit upper cased as JavaScript does for what model ids hold.
fn js_upper_first(w : String) -> String {
  let c = cu(w, 0)
  let up = if is_lower(c) {
    ch(c - 32)
  } else if c >= 0xe0 && c <= 0xfe && c != 0xf7 {
    ch(c - 32)
  } else if c == 0xb5 {
    "\u{39c}"
  } else if c == 0xdf {
    "SS"
  } else if c == 0xff {
    "\u{178}"
  } else if c >= 0x3b1 && c <= 0x3c9 && c != 0x3c2 {
    ch(c - 32)
  } else if c >= 0x430 && c <= 0x44f {
    ch(c - 32)
  } else {
    ch(c)
  }
  up + sub(w, 1, w.length())
}

///|
fn joined_words(words : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for w in words {
    match out.last() {
      Some(last) if last != "" &&
        is_digit(cu(last, last.length() - 1)) &&
        digits(w) &&
        w.length() <= 2 => out[out.length() - 1] = last + "." + w
      _ => out.push(w)
    }
  }
  out
}

///|
fn effort_short(l : String) -> String? {
  match l {
    "low" => Some("低")
    "medium" => Some("中")
    "high" => Some("高")
    "xhigh" => Some("超高")
    "max" => Some("最高")
    _ => None
  }
}

///|
let devin_name_levels : Array[String] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

///|
fn level_suffix(s : String) -> String? {
  for l in devin_name_levels {
    if ends(s, "-" + l) && s.length() > l.length() + 1 {
      return Some(l)
    }
  }
  None
}

///|
let known_families : Array[String] = [
  "gpt", "glm", "codex", "deepseek", "qwen", "qwq", "gemini", "gemma", "kimi", "moonshot", "minimax", "grok", "mistral",
  "devstral", "codestral", "llama", "doubao", "hunyuan", "ernie", "nemotron", "muse", "adaptive",
]

///|
/// model-name.ts `namedModel`.
fn named_model(base : String) -> String? {
  if starts(base, "fusion-") {
    let split_at = index_of(base, "-sidekick-")
    if split_at > 7 {
      let lead_raw = sub(base, 7, split_at)
      let side_raw = sub(base, split_at + 10, base.length())
      if side_raw != "" {
        let lead_effort = level_suffix(lead_raw)
        let lead_base = match lead_effort {
          Some(l) => sub(lead_raw, 0, lead_raw.length() - l.length() - 1)
          None => lead_raw
        }
        let side_effort = level_suffix(side_raw)
        let side_base = match side_effort {
          Some(l) => sub(side_raw, 0, side_raw.length() - l.length() - 1)
          None => side_raw
        }
        let lead = named_model(lead_base).unwrap_or(lead_base)
        let side = named_model(side_base).unwrap_or(side_base)
        return match side_effort {
          Some(l) => {
            let lvl = match effort_short(l) {
              Some(s) => s
              None => model_word(l)
            }
            Some("\{lead} + \{side} (\{lvl})")
          }
          None => Some("\{lead} + \{side}")
        }
      }
    }
  }
  let words = split_on(base, "-").filter(w => w != "")
  guard words.get(0) is Some(first) else { return None }
  if first == "claude" || claude_families.contains(first) {
    let family = match words.search_by(w => claude_families.contains(w)) {
      Some(i) => words[i]
      None => return None
    }
    let version = words.filter(digits)
    let rest = words.filter(w => w != "claude" && w != family && !digits(w)).map(model_word)
    let parts = [model_word(family)]
    if version.length() > 0 {
      parts.push(version.join("."))
    }
    parts.push_iter(rest.iter())
    return Some(parts.join(" "))
  }
  let parts = joined_words(words)
  let dashed = if ["gpt", "glm", "swe"].contains(first) { Some(model_word(first)) } else { None }
  match (dashed, parts.get(1)) {
    (Some(d), Some(p1)) => {
      let second = brand_word(p1).unwrap_or(p1)
      return Some([d + "-" + second, ..parts[2:].to_owned().map(model_word)].join(" "))
    }
    _ => ()
  }
  let o_series = first.length() > 1 && starts(first, "o") && digits(sub(first, 1, first.length()))
  let mut e = first.length()
  while e > 0 && (is_digit(cu(first, e - 1)) || cu(first, e - 1) == 46) {
    e -= 1
  }
  let family = sub(first, 0, e)
  if !o_series && !known_families.contains(family) {
    return None
  }
  let out = []
  for i, w in parts {
    out.push(if i == 0 && o_series { w } else { model_word(w) })
  }
  Some(out.join(" "))
}

///|
/// model-name.ts `modelName`.
pub fn model_name(id : String) -> String {
  let k = @readops.model_key(id)
  let at = index_of(k, "[")
  let (base, context) = if at >= 0 {
    let mut c = sub(k, at + 1, k.length())
    while ends(c, "]") {
      c = sub(c, 0, c.length() - 1)
    }
    (sub(k, 0, at), upper(c))
  } else {
    (k, "")
  }
  match named_model(base) {
    None => js_trim(id)
    Some(named) => if context == "" { named } else { named + " " + context }
  }
}

///|
/// model-name.ts `makerOf`.
pub fn maker_of(model : String) -> String? {
  let low = lower(model)
  let sidekick = index_of(low, "-sidekick-")
  let m = if starts(low, "fusion-") && sidekick > 0 { sub(low, 7, sidekick) } else { low }
  let has_any = (ws : Array[String]) => ws.iter().any(w => has(m, w))
  if has_any(["claude", "opus", "sonnet", "haiku", "fable"]) {
    return Some("anthropic")
  }
  if has_any(["gpt", "codex", "openai"]) || (starts(m, "o") && m.length() > 1 && is_digit(cu(m, 1))) {
    return Some("openai")
  }
  if has_any(["deepseek"]) {
    return Some("deepseek")
  }
  if has_any(["qwen", "qwq"]) {
    return Some("qwen")
  }
  if has_any(["glm", "zhipu"]) {
    return Some("zhipu")
  }
  if has_any(["gemini", "gemma"]) {
    return Some("gemini")
  }
  if has_any(["kimi", "moonshot"]) {
    return Some("kimi")
  }
  if has_any(["minimax", "abab"]) {
    return Some("minimax")
  }
  if has_any(["grok"]) {
    return Some("xai")
  }
  if has_any(["swe-"]) || m == "adaptive" {
    return Some("devin")
  }
  None
}

// ── agent-env.ts ─────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let most_vars : Int = 64

///|
pub let most_value : Int = 4096

///|
/// agent-env.ts `ENV_NAME`: `/^[A-Za-z_][A-Za-z0-9_]*$/`.
pub fn env_name(name : String) -> Bool {
  name != "" && (is_alpha(cu(name, 0)) || cu(name, 0) == 95) && all_units(name, is_word)
}

///|
/// agent-env.ts `agentEnv`: config.json's `agentEnv`, those of a name a shell takes.
pub fn agent_env(raw : Json) -> Array[(String, String)] {
  match raw {
    Object(_) =>
      match field(raw, "agentEnv") {
        Some(Object(m)) => {
          let out = []
          for k, v in m {
            match v {
              String(s) if env_name(k) => out.push((k, s))
              _ => ()
            }
          }
          out
        }
        _ => []
      }
    _ => []
  }
}

///|
/// agent-env.ts `checkAgentEnv`: what is wrong with config.json's `agentEnv` (None: nothing).
pub fn check_agent_env(set : Json?) -> String? {
  match set {
    None | Some(Null) => None
    Some(Object(m)) => {
      if m.length() > most_vars {
        return Some("agentEnv: at most \{most_vars} variables")
      }
      for key, value in m {
        if !env_name(key) {
          return Some("agentEnv: invalid environment variable name \{key}")
        }
        match value {
          String(v) =>
            if v.length() > most_value || any_unit(v, c => c == 0 || c == 10 || c == 13) {
              return Some("agentEnv.\{key}: one line of at most \{most_value} characters")
            }
          _ => return Some("agentEnv.\{key}: a string")
        }
      }
      None
    }
    Some(_) => Some("agentEnv: a map of variables to their values")
  }
}

///|
/// agent-env.ts `maskValue`.
pub fn mask_value(value : String) -> String {
  if value == "" {
    return ""
  }
  let chars = value.iter().collect()
  if chars.length() <= 8 {
    return "••••"
  }
  String::from_array(chars[0:5]) + "…" + String::from_array(chars[chars.length() - 4:])
}

///|
/// agent-env.ts `secretValue`.
pub fn secret_value(key : String, value : String) -> Bool {
  let k = upper(key)
  if ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH"].iter().any(w => has(k, w)) {
    return true
  }
  // `/^[a-z][a-z0-9+.-]*:\/\/[^/@]*:[^/@]*@/i`
  let n = value.length()
  if n == 0 || !is_alpha(cu(value, 0)) {
    return false
  }
  let mut i = 1
  while i < n && (is_alnum(cu(value, i)) || cu(value, i) == 43 || cu(value, i) == 46 || cu(value, i) == 45) {
    i += 1
  }
  if !starts(sub(value, i, n), "://") {
    return false
  }
  i += 3
  let mut e = i
  while e < n && cu(value, e) != 47 && cu(value, e) != 64 {
    e += 1
  }
  // `[^/@]*:[^/@]*@`: a colon among them and an `@` after.
  e < n && cu(value, e) == 64 && has(sub(value, i, e), ":")
}

///|
/// agent-env.ts `EnvLineError` or the variables.
pub fn parse_env_text(text : String, kept : Array[(String, String)]) -> Json {
  let env : Array[(String, String)] = []
  let lines = split_lines(text)
  for i, raw in lines {
    let mut line = js_trim(raw)
    if line == "" || starts(line, "#") {
      continue
    }
    if starts(line, "export") && line.length() > 6 && js_space(cu(line, 6)) {
      line = js_trim_start(sub(line, 6, line.length()))
    }
    let at = index_of(line, "=")
    if at <= 0 {
      return { "line": ji(i + 1), "why": "notPair" }
    }
    let name = js_trim(sub(line, 0, at))
    if !env_name(name) {
      return { "line": ji(i + 1), "why": "badName", "name": js(name) }
    }
    let mut value = js_trim(sub(line, at + 1, line.length()))
    if value.length() >= 2 &&
      (cu(value, 0) == 34 || cu(value, 0) == 39) &&
      cu(value, value.length() - 1) == cu(value, 0) {
      value = sub(value, 1, value.length() - 1)
    }
    if value.length() > most_value {
      return { "line": ji(i + 1), "why": "tooLong", "name": js(name) }
    }
    let v = match env_get(kept, name) {
      Some(before) if secret_value(name, before) && value == mask_value(before) => before
      _ => value
    }
    env_set(env, name, v)
  }
  if env.length() > most_vars {
    return { "line": ji(0), "why": "tooMany" }
  }
  env_json(env)
}

///|
/// `env[name] || env[name.toLowerCase()] || undefined`.
fn either(env : Array[(String, String)], name : String) -> String? {
  match env_truthy(env, name) {
    Some(v) => Some(v)
    None => env_truthy(env, lower(name))
  }
}

///|
/// agent-env.ts `keepLocal`: this machine left out of a proxy, in both cases of NO_PROXY.
pub fn keep_local(env : Array[(String, String)]) -> Array[(String, String)] {
  if !["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"].iter().any(p => either(env, p) is Some(_)) {
    return env
  }
  let named = split_on(either(env, "NO_PROXY").unwrap_or(""), ",").map(js_trim).filter(h => h != "")
  if named.contains("*") {
    return env
  }
  let kept = [..named, ..["localhost", "127.0.0.1", "::1"].filter(h => !named.contains(h))].join(",")
  let out = env.copy()
  env_set(out, "NO_PROXY", kept)
  env_set(out, "no_proxy", kept)
  out
}

///|
/// agent-env.ts `startEnv`: the station's own environment, `agentEnv` over it, less `scrubbed` and the station's
/// internal variables (`STATION_INTERNAL`); this machine kept out of a proxy.
pub fn start_env(
  own : Array[(String, String)],
  raw : Json,
  scrubbed : Array[String],
) -> Array[(String, String)] {
  let env = own.copy()
  for p in agent_env(raw) {
    env_set(env, p.0, p.1)
  }
  keep_local(env.filter(p => !scrubbed.contains(p.0) && p.0 != "STILLFAIL_MESH_FRONT"))
}

///|
/// agent-env.ts `proxyAgent`'s variables: what goes to Node's own proxying, None without a proxy.
pub fn proxy_env(env : Array[(String, String)]) -> Array[(String, String)]? {
  let out : Array[(String, String)] = []
  for name in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY"] {
    match either(env, name) {
      Some(v) => out.push((name, v))
      None => ()
    }
  }
  if env_get(out, "HTTPS_PROXY") is None {
    match env_get(out, "ALL_PROXY") {
      Some(a) => out.push(("HTTPS_PROXY", a))
      None => ()
    }
  }
  if env_get(out, "HTTPS_PROXY") is None {
    None
  } else {
    Some(out)
  }
}
