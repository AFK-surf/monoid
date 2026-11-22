// Admin CLI (`stillfail admin …`): 1:1 native MoonBit port of `bin/admin-cli.ts`.
// Talks to still.fail cloud's `/v1/admin/*` endpoints with an Admin API key (`sfa_…`),
// natively supporting HTTPS_PROXY CONNECT tunnels + custom CA bundles (`secret_run` proxy mode).

///|
let admin_usage : String =
  #|Usage: stillfail admin [options] <command> ...
  #|
  #|Options:
  #|  --origin <url>    Cloud origin (default: STILLFAIL_ADMIN_ORIGIN / STILLFAIL_ORIGIN / cloud.json)
  #|  --key <key>       Admin API key (default: STILLFAIL_ADMIN_KEY / STILLFAIL_SECRET)
  #|  --json            Print raw JSON response
  #|  -h, --help        Show help
  #|
  #|Commands:
  #|  whoami
  #|  users list [--query <q>] [--filter <f>]
  #|  users get <sub-or-email>
  #|  users beta <sub-or-email> on|off
  #|  users may-create <sub-or-email> on|off
  #|  users block <sub-or-email> on|off
  #|  pending set <email> [--beta on|off] [--may-create on|off]
  #|  pending remove <email>
  #|  workspaces list [--query <q>]
  #|  workspaces get <id>
  #|  workspaces create <name> --owner <email> [--owner <email>...] [--members <n>] [--stations <n>]
  #|  workspaces limits <id> (--members <n> [--stations <n>] | --reset)
  #|  workspaces add-owners <id> <email...>
  #|  workspaces remove-added <id> <email>
  #|  workspaces enroll <id> <station-name>
  #|  workspaces delete <id> --yes
  #|  codes list [--filter all|open|used|expired|revoked]
  #|  codes create [--note <text>] [--days <n>] [--beta]
  #|  codes revoke <code>
  #|  feedback list [--status <s|all>] [--area <a>] [--query <q>]
  #|  feedback get <id-or-FB-n>
  #|  feedback status <id-or-FB-n> <new|triaged|fixed|wontfix>
  #|  feedback reply <id-or-FB-n> <text>
  #|  relays list
  #|  relays stats
  #|  relays put <url> <name> [--target <relay-url>]
  #|  relays rename <url> <name> [--target <relay-url>]
  #|  relays remove <url>
  #|  relays token <name> [--url <url>] [--target <relay-url>]
  #|  relays token-revoke <id>
  #|  relays mesh-token <name>
  #|  relays mesh-remove <node>
  #|  audit [--kind <k>] [--limit <n>]
  #|

///|
let admin_request_timeout_ms : Int = 30000

///|
let admin_day_sec : Double = 86400.0

///|
priv suberror AdminCliError {
  AdminCliError(String, Int)
}

///|
impl Show for AdminCliError with output(self, logger) {
  match self {
    AdminCliError(m, _) => logger.write_string(m)
  }
}

///|
priv struct AdminArgs {
  json : Bool
  help : Bool
  origin : String?
  key : String?
  data : String?
  rest : Array[String]
}

///|
priv struct AdminFlags {
  pos : Array[String]
  flags : Map[String, String]
  multi : Map[String, Array[String]]
  bools : Array[String]
}

///|
fn admin_is_no_proxy(hostname : String, no_proxy : String?) -> Bool {
  guard no_proxy is Some(raw_np) && raw_np != "" else { return false }
  let host = hostname.to_lower()
  for raw in raw_np.split(",") {
    let entry = raw.trim().to_owned().to_lower()
    if entry == "" {
      continue
    }
    if entry == "*" {
      return true
    }
    let clean = if entry.has_prefix(".") { entry[1:].to_owned() } else { entry }
    if host == clean || host.has_suffix("." + clean) {
      return true
    }
  }
  false
}

///|
fn admin_url_hostname(url : String) -> String {
  let after_scheme = match url.find("://") {
    Some(i) => url[i + 3:].to_owned()
    None => url
  }
  let mut end = after_scheme.length()
  for sep_ch in ["/", "?", "#"] {
    match after_scheme.find(sep_ch) {
      Some(i) if i < end => end = i
      _ => ()
    }
  }
  let authority = after_scheme[:end].to_owned()
  let hostport = match authority.rev_find("@") {
    Some(i) => authority[i + 1:].to_owned()
    None => authority
  }
  if hostport.has_prefix("[") {
    match hostport.find("]") {
      Some(i) => hostport[1:i].to_owned()
      None => hostport
    }
  } else {
    match hostport.find(":") {
      Some(i) => hostport[:i].to_owned()
      None => hostport
    }
  }
}

///|
fn admin_load_ca() -> String? {
  let candidates : Array[String] = []
  for name in ["SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"] {
    match env_get(name) {
      Some(p) => {
        let trimmed = p.trim().to_owned()
        if trimmed != "" && !candidates.contains(p) {
          candidates.push(p)
        }
      }
      None => ()
    }
  }
  if candidates.length() == 0 {
    return None
  }
  let extra : Array[String] = []
  for p in candidates {
    match read_text(p) {
      Some(pem) if pem != "" => extra.push(pem)
      _ => ()
    }
  }
  if extra.length() == 0 {
    None
  } else {
    Some(extra.join("\n"))
  }
}

///|
fn admin_basename(p : String) -> String {
  let mut s = p
  while s.length() > 1 && (s.has_suffix("/") || s.has_suffix("\\")) {
    s = s[:s.length() - 1].to_owned()
  }
  let i1 = s.rev_find("/")
  let i2 = s.rev_find("\\")
  let idx = match (i1, i2) {
    (Some(a), Some(b)) => Some(if a > b { a } else { b })
    (Some(a), None) => Some(a)
    (None, Some(b)) => Some(b)
    (None, None) => None
  }
  match idx {
    Some(i) => s[i + 1:].to_owned()
    None => s
  }
}

///|
fn admin_strip_trailing_slashes(s : String) -> String {
  let mut out = s
  while out.has_suffix("/") {
    out = out[:out.length() - 1].to_owned()
  }
  out
}

///|
fn admin_resolve_origin(explicit : String?, data_flag : String?, cmd_name : String) -> String {
  let from_env = match explicit {
    Some(s) if s != "" => Some(s)
    _ =>
      match env_get("STILLFAIL_ADMIN_ORIGIN") {
        Some(s) if s != "" => Some(s)
        _ =>
          match env_get("STILLFAIL_ORIGIN") {
            Some(s) if s != "" => Some(s)
            _ => None
          }
      }
  }
  if from_env is Some(o) {
    return admin_strip_trailing_slashes(o)
  }
  let is_monoid = cmd_name == "monoid"
  let d = match data_flag {
    Some(s) if s != "" => s
    _ =>
      match env_get("STILLFAIL_DATA") {
        Some(s) if s != "" => s
        _ => path([homedir(), if is_monoid { ".monoid" } else { ".stillfail" }])
      }
  }
  match read_json(path([d, "mesh", "cloud.json"])) {
    Some({ "origin": String(o), .. }) if o.has_prefix("http://") || o.has_prefix("https://") =>
      return admin_strip_trailing_slashes(o)
    _ => ()
  }
  if is_monoid { "https://app.monoid.build" } else { "https://app.still.fail" }
}

///|
fn admin_parse_bool(value : String?, label : String) -> Bool raise AdminCliError {
  match value {
    Some("on") | Some("true") => true
    Some("off") | Some("false") => false
    _ => raise AdminCliError("expected on|off for \{label}", 2)
  }
}

///|
fn admin_parse_int_opt(value : String?, label : String) -> Int raise AdminCliError {
  let raw = value.unwrap_or("")
  if raw == "" {
    raise AdminCliError("invalid integer for \{label}: \{raw}", 2)
  }
  let mut acc : Int64 = 0L
  for i = 0; i < raw.length(); i = i + 1 {
    let c = raw.code_unit_at(i).to_int()
    if c < '0'.to_int() || c > '9'.to_int() {
      raise AdminCliError("invalid integer for \{label}: \{raw}", 2)
    }
    acc = acc * 10L + (c - '0'.to_int()).to_int64()
    if acc > 2147483647L {
      raise AdminCliError("invalid integer for \{label}: \{raw}", 2)
    }
  }
  if acc < 1L {
    raise AdminCliError("invalid integer for \{label}: \{raw}", 2)
  }
  acc.to_int()
}

///|
fn admin_fmt_time(sec : Json) -> String {
  match sec {
    Number(n, ..) if !n.is_nan() && !n.is_inf() && n > 0.0 => {
      let iso = iso_time(n * 1000.0).replace_all(old="T", new=" ")
      let prefix = if iso.length() >= 16 { iso[:16].to_owned() } else { iso }
      prefix + "Z"
    }
    _ => "-"
  }
}

///|
fn admin_encode_uri_component(s : String) -> String {
  let bytes = @utf8.encode(s)
  let buf = @buffer.Buffer()
  let hex = "0123456789ABCDEF"
  for i = 0; i < bytes.length(); i = i + 1 {
    let b = bytes[i].to_int()
    let safe = (b >= 'A'.to_int() && b <= 'Z'.to_int()) ||
      (b >= 'a'.to_int() && b <= 'z'.to_int()) ||
      (b >= '0'.to_int() && b <= '9'.to_int()) ||
      b == '-'.to_int() ||
      b == '_'.to_int() ||
      b == '.'.to_int() ||
      b == '!'.to_int() ||
      b == '~'.to_int() ||
      b == '*'.to_int() ||
      b == '\''.to_int() ||
      b == '('.to_int() ||
      b == ')'.to_int()
    if safe {
      buf.write_byte(bytes[i])
    } else {
      buf.write_byte(b'%')
      buf.write_byte(hex.code_unit_at((b >> 4) & 0xF).to_byte())
      buf.write_byte(hex.code_unit_at(b & 0xF).to_byte())
    }
  }
  @utf8.decode_lossy(buf.to_bytes())
}

///|
fn admin_is_ulid(s : String) -> Bool {
  if s.length() != 26 {
    return false
  }
  for i = 0; i < 26; i = i + 1 {
    let c = s.code_unit_at(i).to_int()
    if !((c >= '0'.to_int() && c <= '9'.to_int()) || (c >= 'A'.to_int() && c <= 'Z'.to_int())) {
      return false
    }
  }
  true
}

///|
fn admin_parse_args(argv : Array[String]) -> AdminArgs raise AdminCliError {
  let mut json = false
  let mut help = false
  let mut origin : String? = None
  let mut key : String? = None
  let mut data : String? = None
  let rest : Array[String] = []
  let mut i = 0
  while i < argv.length() {
    let a = argv[i]
    if a == "--json" {
      json = true
    } else if a == "-h" || a == "--help" {
      help = true
    } else if a == "--origin" {
      i += 1
      if i >= argv.length() || argv[i] == "" {
        raise AdminCliError("--origin requires a value", 2)
      }
      origin = Some(argv[i])
    } else if a == "--key" {
      i += 1
      if i >= argv.length() || argv[i] == "" {
        raise AdminCliError("--key requires a value", 2)
      }
      key = Some(argv[i])
    } else if a == "--data" {
      i += 1
      if i >= argv.length() || argv[i] == "" {
        raise AdminCliError("--data requires a value", 2)
      }
      data = Some(argv[i])
    } else {
      rest.push(a)
    }
    i += 1
  }
  let trimmed = if rest.length() > 0 && rest[0] == "admin" {
    rest[1:].to_owned()
  } else {
    rest
  }
  { json, help, origin, key, data, rest: trimmed }
}

///|
fn admin_take_flags(
  args : Array[String],
  value_flags : Array[String],
  bool_flags : Array[String],
  multi_flags? : Array[String] = [],
) -> AdminFlags raise AdminCliError {
  let pos : Array[String] = []
  let flags : Map[String, String] = Map([])
  let multi : Map[String, Array[String]] = Map([])
  let bools : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    if bool_flags.contains(a) {
      if !bools.contains(a) {
        bools.push(a)
      }
    } else if multi_flags.contains(a) {
      i += 1
      if i >= args.length() {
        raise AdminCliError("\{a} requires a value", 2)
      }
      let list = multi.get(a).unwrap_or([])
      list.push(args[i])
      multi[a] = list
    } else if value_flags.contains(a) {
      i += 1
      if i >= args.length() {
        raise AdminCliError("\{a} requires a value", 2)
      }
      flags[a] = args[i]
    } else if a.has_prefix("-") {
      raise AdminCliError("unknown option: \{a}", 2)
    } else {
      pos.push(a)
    }
    i += 1
  }
  { pos, flags, multi, bools }
}

///|
fn admin_jstr(v : Json) -> String {
  match v {
    String(s) => s
    Number(n, ..) => js_number_text(n)
    True => "true"
    False => "false"
    Null => "null"
    other => other.stringify()
  }
}

///|
fn admin_jtruthy(v : Json) -> Bool {
  match v {
    Null | False => false
    True => true
    Number(n, ..) => n != 0.0 && !n.is_nan()
    String(s) => s != ""
    Array(_) | Object(_) => true
  }
}

///|
fn admin_str_or_dash(v : Json) -> String {
  match v {
    Null => "-"
    String("") => "-"
    other => admin_jstr(other)
  }
}

///|
fn admin_nullish_or_dash(v : Json) -> String {
  match v {
    Null => "-"
    other => admin_jstr(other)
  }
}

///|
fn admin_out_json(v : Json) -> Unit {
  out_write(jpretty(v) + "\n")
}

///|
async fn admin_call(
  host : @host.Host,
  origin : String,
  api_key : String,
  ca_pem : String?,
  method_ : String,
  req_path : String,
  body? : Json,
) -> Json raise AdminCliError {
  let url = origin + req_path
  let headers : Array[(String, String)] = [
    ("Authorization", "Bearer " + api_key),
    ("Accept", "application/json"),
  ]
  let payload : Bytes? = match body {
    Some(b) => {
      headers.push(("Content-Type", "application/json"))
      Some(@utf8.encode(b.stringify()))
    }
    None => None
  }
  let proxy : String? = if origin.has_prefix("https://") {
    let proxy_url = match env_get("HTTPS_PROXY") {
      Some(s) if s != "" => Some(s)
      _ =>
        match env_get("https_proxy") {
          Some(s) if s != "" => Some(s)
          _ => None
        }
    }
    let no_proxy = match env_get("NO_PROXY") {
      Some(s) if s != "" => Some(s)
      _ => env_get("no_proxy")
    }
    match proxy_url {
      Some(p) if !admin_is_no_proxy(admin_url_hostname(url), no_proxy) => Some(p)
      _ => None
    }
  } else {
    None
  }
  let res = host.fetch(
    url,
    method_=method_,
    headers~,
    body?=payload,
    timeout_ms=admin_request_timeout_ms,
    proxy?=proxy,
    ca_pem?=ca_pem,
  ) catch {
    e => raise AdminCliError("\{e}", 1)
  }
  let text = res.text()
  let data : Json = if text.trim().to_owned() != "" {
    @json.parse(text) catch {
      _ => { "raw": Json::string(text) }
    }
  } else {
    Json::null()
  }
  if res.status < 200 || res.status >= 300 {
    let err_code = match data {
      Object(m) =>
        match m.get("error") {
          Some(v) => admin_jstr(v)
          None => "http_\{res.status}"
        }
      _ => "http_\{res.status}"
    }
    let detail = match data {
      Object(m) =>
        match m.get("reason") {
          Some(v) => " (\{admin_jstr(v)})"
          None => ""
        }
      _ => ""
    }
    raise AdminCliError("request failed (\{res.status}): \{err_code}\{detail}", 1)
  }
  data
}

///|
async fn admin_resolve_user(
  host : @host.Host,
  origin : String,
  api_key : String,
  ca_pem : String?,
  user_ref : String,
) -> Json raise AdminCliError {
  let data = admin_call(host, origin, api_key, ca_pem, "GET", "/v1/admin/users")
  let lower = user_ref.to_lower()
  for u in jitems(jfield(data, "users")) {
    if jtext_or_empty(u, "sub") == user_ref || jtext_or_empty(u, "email").to_lower() == lower {
      return u
    }
  }
  raise AdminCliError("user not found: \{user_ref}", 1)
}

///|
async fn admin_resolve_feedback_id(
  host : @host.Host,
  origin : String,
  api_key : String,
  ca_pem : String?,
  fb_ref : String,
) -> String raise AdminCliError {
  if admin_is_ulid(fb_ref) {
    return fb_ref
  }
  let data = admin_call(
    host,
    origin,
    api_key,
    ca_pem,
    "GET",
    "/v1/admin/feedback/" + admin_encode_uri_component(fb_ref),
  )
  jtext_or_empty(jfield(data, "item"), "id")
}

///|
fn admin_redact(msg : String, api_key : String) -> String {
  if api_key == "" {
    msg
  } else {
    msg.replace_all(old=api_key, new="[redacted]")
  }
}

///|
fn admin_code_state(c : Json, now : Double) -> String {
  if admin_jtruthy(jfield(c, "used_at")) || admin_jtruthy(jfield(c, "used_by")) {
    return "used"
  }
  if admin_jtruthy(jfield(c, "revoked_at")) {
    return "revoked"
  }
  match jnum_of(c, "expires_at") {
    Some(exp) if exp <= now => "expired"
    _ => "open"
  }
}

///|
async fn run_admin_cli(host : @host.Host, argv0 : String, args : Array[String]) -> Int {
  let parsed = admin_parse_args(args) catch {
    AdminCliError(msg, code) => {
      err_write(msg + "\n")
      return code
    }
  }
  if parsed.help || parsed.rest.length() == 0 {
    out_write(admin_usage)
    return 0
  }
  let api_key = match parsed.key {
    Some(s) if s != "" => s
    _ =>
      match env_get("STILLFAIL_ADMIN_KEY") {
        Some(s) if s != "" => s
        _ =>
          match env_get("STILLFAIL_SECRET") {
            Some(s) if s != "" => s
            _ => ""
          }
      }
  }
  if api_key == "" {
    err_write("error: missing Admin API key (set STILLFAIL_ADMIN_KEY, STILLFAIL_SECRET, or --key)\n")
    return 1
  }
  let cmd_raw = match env_get("STILLFAIL_CMD") {
    Some(s) if s != "" => s
    _ => if argv0 != "" { argv0 } else { "stillfail" }
  }
  let cmd_name = admin_basename(cmd_raw)
  let origin = admin_resolve_origin(parsed.origin, parsed.data, cmd_name)
  let ca_pem = admin_load_ca()

  let group = parsed.rest[0]
  let sub : String? = if parsed.rest.length() > 1 { Some(parsed.rest[1]) } else { None }
  let sub_args : Array[String] = if parsed.rest.length() > 2 { parsed.rest[2:].to_owned() } else { [] }

  try {
    if group == "whoami" {
      let data = admin_call(host, origin, api_key, ca_pem, "GET", "/v1/admin/me")
      if parsed.json {
        admin_out_json(data)
      } else {
        let email = jtext_or_empty(data, "email")
        match jfield(data, "key") {
          Object(_) as k =>
            out_write("\{email} (key: \{jtext_or_empty(k, "name")} \{jtext_or_empty(k, "prefix")}…)\n")
          _ => out_write("\{email}\n")
        }
      }
      return 0
    }

    if group == "users" {
      match sub {
        Some("list") => {
          let f = admin_take_flags(sub_args, ["--query", "--filter"], [])
          let data = admin_call(host, origin, api_key, ca_pem, "GET", "/v1/admin/users")
          let q = f.flags.get("--query").unwrap_or("").to_lower()
          let filter = f.flags.get("--filter").unwrap_or("all")
          let now = (wall_ms() / 1000L).to_double()
          if filter == "pending" {
            let mut pending = jitems(jfield(data, "pending"))
            if q != "" {
              pending = pending.filter(p => jtext_or_empty(p, "email").to_lower().contains(q))
            }
            if parsed.json {
              admin_out_json({ "users": Json::array([]), "pending": Json::array(pending) })
            } else {
              for p in pending {
                let tags : Array[String] = []
                if admin_jtruthy(jfield(p, "beta")) {
                  tags.push("beta")
                }
                if admin_jtruthy(jfield(p, "may_create")) {
                  tags.push("standard")
                }
                let tag_str = if tags.length() > 0 { tags.join(",") } else { "none" }
                out_write("pending\t\{jtext_or_empty(p, "email")}\t[\{tag_str}]\tadded:\{admin_fmt_time(jfield(p, "added_at"))}\n")
              }
            }
            return 0
          }
          let mut users = jitems(jfield(data, "users"))
          if q != "" {
            users = users.filter(u => "\{jtext_or_empty(u, "name")} \{jtext_or_empty(u, "email")} \{jtext_or_empty(u, "sub")}".to_lower().contains(q))
          }
          if filter == "active" {
            users = users.filter(u => match jnum_of(u, "last_seen") {
              Some(ls) => now - ls < 7.0 * admin_day_sec
              None => false
            })
          } else if filter == "new" {
            users = users.filter(u => match jnum_of(u, "created_at") {
              Some(ca) => now - ca < 7.0 * admin_day_sec
              None => false
            })
          } else if filter == "dormant" {
            users = users.filter(u => match jnum_of(u, "last_seen") {
              Some(ls) => now - ls > 30.0 * admin_day_sec
              None => true
            })
          } else if filter == "beta" {
            users = users.filter(u => admin_jtruthy(jfield(u, "beta")))
          } else if filter == "blocked" {
            users = users.filter(u => admin_jtruthy(jfield(u, "blocked")))
          } else if filter == "creators" {
            users = users.filter(u => admin_jtruthy(jfield(u, "may_create")))
          } else if filter == "stuck" {
            users = users.filter(u => !admin_jtruthy(jfield(u, "admission")))
          }
          if parsed.json {
            admin_out_json({ "users": Json::array(users), "pending": jfield(data, "pending") })
          } else {
            for u in users {
              let tags : Array[String] = []
              let plan = jtext_or_empty(u, "plan")
              if plan != "" {
                tags.push(plan)
              }
              if admin_jtruthy(jfield(u, "beta")) {
                tags.push("beta")
              }
              if admin_jtruthy(jfield(u, "blocked")) {
                tags.push("blocked")
              }
              let name = admin_str_or_dash(jfield(u, "name"))
              out_write("\{jtext_or_empty(u, "sub")}\t\{jtext_or_empty(u, "email")}\t\{name}\t[\{tags.join(",")}]\tseen:\{admin_fmt_time(jfield(u, "last_seen"))}\n")
            }
          }
          return 0
        }
        Some("get") => {
          guard sub_args.length() > 0 && sub_args[0] != "" else {
            raise AdminCliError("usage: users get <sub-or-email>", 2)
          }
          let u = admin_resolve_user(host, origin, api_key, ca_pem, sub_args[0])
          if parsed.json {
            admin_out_json(u)
          } else {
            let email = jtext_or_empty(u, "email")
            let usub = jtext_or_empty(u, "sub")
            let name = admin_str_or_dash(jfield(u, "name"))
            let plan = admin_nullish_or_dash(jfield(u, "plan"))
            let beta = if admin_jtruthy(jfield(u, "beta")) { "true" } else { "false" }
            let blocked = if admin_jtruthy(jfield(u, "blocked")) { "true" } else { "false" }
            out_write("\{email} (\{usub})\nname: \{name}\nplan: \{plan}\nbeta: \{beta}\nblocked: \{blocked}\n")
          }
          return 0
        }
        Some("beta" | "may-create" | "block" as action) => {
          guard sub_args.length() >= 2 && sub_args[0] != "" && sub_args[1] != "" else {
            raise AdminCliError("usage: users \{action} <sub-or-email> on|off", 2)
          }
          let on = admin_parse_bool(Some(sub_args[1]), action)
          let u = admin_resolve_user(host, origin, api_key, ca_pem, sub_args[0])
          let usub = jtext_or_empty(u, "sub")
          let data = admin_call(
            host,
            origin,
            api_key,
            ca_pem,
            "POST",
            "/v1/admin/users/" + admin_encode_uri_component(usub) + "/" + action,
            body={ "on": Json::boolean(on) },
          )
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("\{jtext_or_empty(u, "email")}: \{action}=\{if on { "on" } else { "off" }}\n")
          }
          return 0
        }
        other => raise AdminCliError("unknown users subcommand: \{other.unwrap_or("")}", 2)
      }
    }

    if group == "pending" {
      match sub {
        Some("set") => {
          let f = admin_take_flags(sub_args, ["--beta", "--may-create"], [])
          guard f.pos.length() > 0 && f.pos[0] != "" else {
            raise AdminCliError("usage: pending set <email> [--beta on|off] [--may-create on|off]", 2)
          }
          let email = f.pos[0]
          let body : Map[String, Json] = { "email": Json::string(email) }
          if f.flags.contains("--beta") {
            body["beta"] = Json::boolean(admin_parse_bool(f.flags.get("--beta"), "--beta"))
          }
          if f.flags.contains("--may-create") {
            body["may_create"] = Json::boolean(admin_parse_bool(f.flags.get("--may-create"), "--may-create"))
          }
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/pending", body=Json::object(body))
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("updated pending rights for \{email}\n")
          }
          return 0
        }
        Some("remove") => {
          guard sub_args.length() > 0 && sub_args[0] != "" else {
            raise AdminCliError("usage: pending remove <email>", 2)
          }
          let email = sub_args[0]
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/pending/remove", body={ "email": Json::string(email) })
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("removed pending rights for \{email}\n")
          }
          return 0
        }
        other => raise AdminCliError("unknown pending subcommand: \{other.unwrap_or("")}", 2)
      }
    }

    if group == "workspaces" {
      match sub {
        Some("list") => {
          let f = admin_take_flags(sub_args, ["--query"], [])
          let data = admin_call(host, origin, api_key, ca_pem, "GET", "/v1/admin/workspaces")
          let q = f.flags.get("--query").unwrap_or("").to_lower()
          let all = jitems(jfield(data, "workspaces"))
          let list = if q != "" {
            all.filter(w => "\{jtext_or_empty(w, "name")} \{jtext_or_empty(w, "id")}".to_lower().contains(q))
          } else {
            all
          }
          if parsed.json {
            admin_out_json({ "workspaces": Json::array(list) })
          } else {
            for w in list {
              let id = jtext_or_empty(w, "id")
              let name = jtext_or_empty(w, "name")
              let plan = admin_nullish_or_dash(jfield(w, "plan"))
              let members = jitems(jfield(w, "members")).length()
              let stations = jitems(jfield(w, "stations")).length()
              out_write("\{id}\t\{name}\tplan:\{plan}\tmembers:\{members}\tstations:\{stations}\n")
            }
          }
          return 0
        }
        Some("get") => {
          guard sub_args.length() > 0 && sub_args[0] != "" else {
            raise AdminCliError("usage: workspaces get <id>", 2)
          }
          let id = sub_args[0]
          let data = admin_call(host, origin, api_key, ca_pem, "GET", "/v1/admin/workspaces")
          let mut found : Json? = None
          for x in jitems(jfield(data, "workspaces")) {
            if jtext_or_empty(x, "id") == id {
              found = Some(x)
              break
            }
          }
          guard found is Some(w) else {
            raise AdminCliError("workspace not found: \{id}", 1)
          }
          if parsed.json {
            admin_out_json(w)
          } else {
            let name = jtext_or_empty(w, "name")
            let plan = admin_nullish_or_dash(jfield(w, "plan"))
            let members = jitems(jfield(w, "members")).length()
            let seats = admin_nullish_or_dash(jfield(w, "seats"))
            let stations = jitems(jfield(w, "stations")).length()
            out_write("\{name} (\{id})\nplan: \{plan}\nmembers: \{members}/\{seats}\nstations: \{stations}\n")
          }
          return 0
        }
        Some("create") => {
          let f = admin_take_flags(sub_args, ["--members", "--stations"], [], multi_flags=["--owner"])
          let name = if f.pos.length() > 0 { f.pos[0] } else { "" }
          let owners = f.multi.get("--owner").unwrap_or([])
          if name == "" || owners.length() == 0 {
            raise AdminCliError("usage: workspaces create <name> --owner <email> [--owner <email>...] [--members <n>] [--stations <n>]", 2)
          }
          let members = if f.flags.contains("--members") { admin_parse_int_opt(f.flags.get("--members"), "--members") } else { 20 }
          let stations = if f.flags.contains("--stations") { admin_parse_int_opt(f.flags.get("--stations"), "--stations") } else { 64 }
          let body : Json = {
            "name": Json::string(name),
            "owners": Json::array(owners.map(Json::string)),
            "members": Json::number(members.to_double()),
            "stations": Json::number(stations.to_double()),
          }
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/workspaces", body~)
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("created workspace \{jtext_or_empty(data, "id")} (\{name})\n")
          }
          return 0
        }
        Some("limits") => {
          let f = admin_take_flags(sub_args, ["--members", "--stations"], ["--reset"])
          guard f.pos.length() > 0 && f.pos[0] != "" else {
            raise AdminCliError("usage: workspaces limits <id> (--members <n> [--stations <n>] | --reset)", 2)
          }
          let id = f.pos[0]
          let body : Json = if f.bools.contains("--reset") {
            { "reset": Json::boolean(true) }
          } else if f.flags.contains("--members") {
            let members = admin_parse_int_opt(f.flags.get("--members"), "--members")
            let stations = if f.flags.contains("--stations") { admin_parse_int_opt(f.flags.get("--stations"), "--stations") } else { 64 }
            { "members": Json::number(members.to_double()), "stations": Json::number(stations.to_double()) }
          } else {
            raise AdminCliError("specify --members <n> or --reset", 2)
          }
          let data = admin_call(
            host,
            origin,
            api_key,
            ca_pem,
            "POST",
            "/v1/admin/workspaces/" + admin_encode_uri_component(id) + "/limits",
            body~,
          )
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("updated limits for \{id}\n")
          }
          return 0
        }
        Some("add-owners") => {
          guard sub_args.length() >= 2 && sub_args[0] != "" else {
            raise AdminCliError("usage: workspaces add-owners <id> <email...>", 2)
          }
          let id = sub_args[0]
          let emails = sub_args[1:].to_owned()
          let data = admin_call(
            host,
            origin,
            api_key,
            ca_pem,
            "POST",
            "/v1/admin/workspaces/" + admin_encode_uri_component(id) + "/owners",
            body={ "emails": Json::array(emails.map(Json::string)) },
          )
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("added owners to \{id}: \{emails.join(", ")}\n")
          }
          return 0
        }
        Some("remove-added") => {
          guard sub_args.length() >= 2 && sub_args[0] != "" && sub_args[1] != "" else {
            raise AdminCliError("usage: workspaces remove-added <id> <email>", 2)
          }
          let id = sub_args[0]
          let email = sub_args[1]
          let data = admin_call(
            host,
            origin,
            api_key,
            ca_pem,
            "POST",
            "/v1/admin/workspaces/" + admin_encode_uri_component(id) + "/added/remove",
            body={ "email": Json::string(email) },
          )
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("removed pending owner \{email} from \{id}\n")
          }
          return 0
        }
        Some("enroll") => {
          guard sub_args.length() >= 2 && sub_args[0] != "" && sub_args[1] != "" else {
            raise AdminCliError("usage: workspaces enroll <id> <station-name>", 2)
          }
          let id = sub_args[0]
          let name = sub_args[1]
          let data = admin_call(
            host,
            origin,
            api_key,
            ca_pem,
            "POST",
            "/v1/admin/workspaces/" + admin_encode_uri_component(id) + "/enrollments",
            body={ "name": Json::string(name) },
          )
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("\{jtext_or_empty(data, "install")}\n")
          }
          return 0
        }
        Some("delete") => {
          let f = admin_take_flags(sub_args, [], ["--yes"])
          guard f.pos.length() > 0 && f.pos[0] != "" else {
            raise AdminCliError("usage: workspaces delete <id> --yes", 2)
          }
          let id = f.pos[0]
          if !f.bools.contains("--yes") {
            raise AdminCliError("refusing to delete workspace without --yes", 2)
          }
          let data = admin_call(
            host,
            origin,
            api_key,
            ca_pem,
            "POST",
            "/v1/admin/workspaces/" + admin_encode_uri_component(id) + "/delete",
            body=Json::object({}),
          )
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("deleted workspace \{id}\n")
          }
          return 0
        }
        other => raise AdminCliError("unknown workspaces subcommand: \{other.unwrap_or("")}", 2)
      }
    }

    if group == "codes" {
      match sub {
        Some("list") => {
          let f = admin_take_flags(sub_args, ["--filter"], [])
          let data = admin_call(host, origin, api_key, ca_pem, "GET", "/v1/admin/invite-codes")
          let filter = f.flags.get("--filter").unwrap_or("all")
          let now = (wall_ms() / 1000L).to_double()
          let codes = jitems(jfield(data, "codes")).filter(c => filter == "all" || admin_code_state(c, now) == filter)
          if parsed.json {
            admin_out_json({ "codes": Json::array(codes) })
          } else {
            for c in codes {
              let st = admin_code_state(c, now)
              let beta_part = if admin_jtruthy(jfield(c, "beta")) { "beta\t" } else { "" }
              let note = admin_str_or_dash(jfield(c, "note"))
              out_write("\{jtext_or_empty(c, "code")}\t\{st}\t\{beta_part}\{note}\texp:\{admin_fmt_time(jfield(c, "expires_at"))}\n")
            }
          }
          return 0
        }
        Some("create") => {
          let f = admin_take_flags(sub_args, ["--note", "--days"], ["--beta"])
          let body : Map[String, Json] = Map([])
          if f.flags.get("--note") is Some(note) {
            body["note"] = Json::string(note)
          }
          if f.flags.contains("--days") {
            body["days"] = Json::number(admin_parse_int_opt(f.flags.get("--days"), "--days").to_double())
          }
          if f.bools.contains("--beta") {
            body["beta"] = Json::boolean(true)
          }
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/invite-codes", body=Json::object(body))
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("\{jtext_or_empty(data, "code")}\t\{jtext_or_empty(data, "url")}\n")
          }
          return 0
        }
        Some("revoke") => {
          guard sub_args.length() > 0 && sub_args[0] != "" else {
            raise AdminCliError("usage: codes revoke <code>", 2)
          }
          let code = sub_args[0]
          let data = admin_call(
            host,
            origin,
            api_key,
            ca_pem,
            "POST",
            "/v1/admin/invite-codes/" + admin_encode_uri_component(code) + "/revoke",
            body=Json::object({}),
          )
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("revoked code \{code}\n")
          }
          return 0
        }
        other => raise AdminCliError("unknown codes subcommand: \{other.unwrap_or("")}", 2)
      }
    }

    if group == "feedback" {
      match sub {
        Some("list") => {
          let f = admin_take_flags(sub_args, ["--status", "--area", "--query"], [])
          let data = admin_call(host, origin, api_key, ca_pem, "GET", "/v1/admin/feedback")
          let status = f.flags.get("--status").unwrap_or("all")
          let area = f.flags.get("--area")
          let q = f.flags.get("--query").unwrap_or("").to_lower()
          let mut list = jitems(jfield(data, "feedback"))
          if status != "all" {
            list = list.filter(x => jtext_or_empty(x, "status") == status)
          }
          if area is Some(a) && a != "" {
            list = list.filter(x => jtext_or_empty(x, "area") == a)
          }
          if q != "" {
            list = list.filter(x => "fb-\{admin_jstr(jfield(x, "number"))} \{jtext_or_empty(x, "title")} \{jtext_or_empty(x, "body")} \{jtext_or_empty(x, "reporter")}".to_lower().contains(q))
          }
          if parsed.json {
            admin_out_json({ "feedback": Json::array(list) })
          } else {
            for x in list {
              out_write("FB-\{admin_jstr(jfield(x, "number"))}\t[\{jtext_or_empty(x, "status")}]\t\{jtext_or_empty(x, "area")}\t\{jtext_or_empty(x, "title")}\n")
            }
          }
          return 0
        }
        Some("get") => {
          guard sub_args.length() > 0 && sub_args[0] != "" else {
            raise AdminCliError("usage: feedback get <id-or-FB-n>", 2)
          }
          let data = admin_call(
            host,
            origin,
            api_key,
            ca_pem,
            "GET",
            "/v1/admin/feedback/" + admin_encode_uri_component(sub_args[0]),
          )
          if parsed.json {
            admin_out_json(data)
          } else {
            let item = jfield(data, "item")
            out_write("FB-\{admin_jstr(jfield(item, "number"))} [\{jtext_or_empty(item, "status")}] \{jtext_or_empty(item, "title")}\n\n\{jtext_or_empty(item, "body")}\n")
          }
          return 0
        }
        Some("status") => {
          guard sub_args.length() >= 2 && sub_args[0] != "" && sub_args[1] != "" else {
            raise AdminCliError("usage: feedback status <id-or-FB-n> <new|triaged|fixed|wontfix>", 2)
          }
          let fb_ref = sub_args[0]
          let status = sub_args[1]
          let id = admin_resolve_feedback_id(host, origin, api_key, ca_pem, fb_ref)
          let data = admin_call(
            host,
            origin,
            api_key,
            ca_pem,
            "POST",
            "/v1/admin/feedback/" + admin_encode_uri_component(id) + "/status",
            body={ "status": Json::string(status) },
          )
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("\{fb_ref}: status=\{status}\n")
          }
          return 0
        }
        Some("reply") => {
          let fb_ref = if sub_args.length() > 0 { sub_args[0] } else { "" }
          let text = if sub_args.length() > 1 { sub_args[1:].to_owned().join(" ") } else { "" }
          if fb_ref == "" || text == "" {
            raise AdminCliError("usage: feedback reply <id-or-FB-n> <text>", 2)
          }
          let id = admin_resolve_feedback_id(host, origin, api_key, ca_pem, fb_ref)
          let data = admin_call(
            host,
            origin,
            api_key,
            ca_pem,
            "POST",
            "/v1/admin/feedback/" + admin_encode_uri_component(id) + "/reply",
            body={ "text": Json::string(text) },
          )
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("replied to \{fb_ref}\n")
          }
          return 0
        }
        other => raise AdminCliError("unknown feedback subcommand: \{other.unwrap_or("")}", 2)
      }
    }

    if group == "relays" {
      match sub {
        Some("list") => {
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/relays/list", body=Json::object({}))
          if parsed.json {
            admin_out_json(data)
          } else {
            for r in jitems(jfield(data, "relays")) {
              let target = jtext_or_empty(r, "target")
              let suffix = if target != "" { "\t-> " + target } else { "" }
              out_write("\{jtext_or_empty(r, "name")}\t\{jtext_or_empty(r, "url")}\{suffix}\n")
            }
          }
          return 0
        }
        Some("stats") => {
          let data = admin_call(host, origin, api_key, ca_pem, "GET", "/v1/admin/relays")
          admin_out_json(data)
          return 0
        }
        Some("put") => {
          let f = admin_take_flags(sub_args, ["--target"], [])
          guard f.pos.length() >= 2 && f.pos[0] != "" && f.pos[1] != "" else {
            raise AdminCliError("usage: relays put <url> <name> [--target <relay-url>]", 2)
          }
          let url = f.pos[0]
          let name = f.pos[1]
          let body : Map[String, Json] = { "url": Json::string(url), "name": Json::string(name) }
          if f.flags.get("--target") is Some(t) {
            body["target"] = Json::string(t)
          }
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/relays/put", body=Json::object(body))
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("put relay \{name} (\{url})\n")
          }
          return 0
        }
        Some("rename") => {
          let f = admin_take_flags(sub_args, ["--target"], [])
          guard f.pos.length() >= 2 && f.pos[0] != "" && f.pos[1] != "" else {
            raise AdminCliError("usage: relays rename <url> <name> [--target <relay-url>]", 2)
          }
          let url = f.pos[0]
          let name = f.pos[1]
          let mut target = f.flags.get("--target")
          if target is None {
            let listed = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/relays/list", body=Json::object({}))
            for r in jitems(jfield(listed, "relays")) {
              if jtext_or_empty(r, "url") == url {
                let existing = jtext_or_empty(r, "target")
                if existing != "" {
                  target = Some(existing)
                }
                break
              }
            }
          }
          let body : Map[String, Json] = { "url": Json::string(url), "name": Json::string(name) }
          if target is Some(t) && t != "" {
            body["target"] = Json::string(t)
          }
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/relays/put", body=Json::object(body))
          if parsed.json {
            admin_out_json(data)
          } else {
            let suffix = match target {
              Some(t) if t != "" => " (target: " + t + ")"
              _ => ""
            }
            out_write("renamed relay \{url} -> \{name}\{suffix}\n")
          }
          return 0
        }
        Some("remove") => {
          guard sub_args.length() > 0 && sub_args[0] != "" else {
            raise AdminCliError("usage: relays remove <url>", 2)
          }
          let url = sub_args[0]
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/relays/remove", body={ "url": Json::string(url) })
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("removed relay \{url}\n")
          }
          return 0
        }
        Some("token") => {
          let f = admin_take_flags(sub_args, ["--url", "--target"], [])
          guard f.pos.length() > 0 && f.pos[0] != "" else {
            raise AdminCliError("usage: relays token <name> [--url <url>] [--target <relay-url>]", 2)
          }
          let name = f.pos[0]
          let body : Map[String, Json] = { "name": Json::string(name) }
          if f.flags.get("--url") is Some(u) {
            body["url"] = Json::string(u)
          }
          if f.flags.get("--target") is Some(t) {
            body["target"] = Json::string(t)
          }
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/relays/token", body=Json::object(body))
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("\{jtext_or_empty(data, "command")}\n")
          }
          return 0
        }
        Some("token-revoke") => {
          guard sub_args.length() > 0 && sub_args[0] != "" else {
            raise AdminCliError("usage: relays token-revoke <id>", 2)
          }
          let id = sub_args[0]
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/relays/token/revoke", body={ "id": Json::string(id) })
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("revoked relay token \{id}\n")
          }
          return 0
        }
        Some("mesh-token") => {
          guard sub_args.length() > 0 && sub_args[0] != "" else {
            raise AdminCliError("usage: relays mesh-token <name>", 2)
          }
          let name = sub_args[0]
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/relays/mesh-token", body={ "name": Json::string(name) })
          admin_out_json(data)
          return 0
        }
        Some("mesh-remove") => {
          guard sub_args.length() > 0 && sub_args[0] != "" else {
            raise AdminCliError("usage: relays mesh-remove <node>", 2)
          }
          let node = sub_args[0]
          let data = admin_call(host, origin, api_key, ca_pem, "POST", "/v1/admin/relays/mesh-remove", body={ "node": Json::string(node) })
          if parsed.json {
            admin_out_json(data)
          } else {
            out_write("removed mesh relay \{node}\n")
          }
          return 0
        }
        other => raise AdminCliError("unknown relays subcommand: \{other.unwrap_or("")}", 2)
      }
    }

    if group == "audit" {
      let rest_audit : Array[String] = match sub {
        Some(s) => {
          let out = [s]
          for a in sub_args {
            out.push(a)
          }
          out
        }
        None => sub_args
      }
      let f = admin_take_flags(rest_audit, ["--kind", "--limit"], [])
      let data = admin_call(host, origin, api_key, ca_pem, "GET", "/v1/admin/audit")
      let kind = f.flags.get("--kind")
      let limit = if f.flags.contains("--limit") { admin_parse_int_opt(f.flags.get("--limit"), "--limit") } else { 50 }
      let mut list = jitems(jfield(data, "audit"))
      if kind is Some(k) && k != "" {
        list = list.filter(e => {
          let a = jtext_or_empty(e, "action")
          if k == "users" {
            a.has_prefix("user.") || a.has_prefix("pending.")
          } else if k == "workspaces" {
            a.has_prefix("workspace.")
          } else if k == "codes" {
            a.has_prefix("code.")
          } else if k == "feedback" {
            a.has_prefix("feedback.")
          } else if k == "relays" {
            a.has_prefix("relay.")
          } else if k == "keys" {
            a.has_prefix("key.")
          } else {
            a.has_prefix(k + ".") || a == k
          }
        })
      }
      if list.length() > limit {
        list = list[:limit].to_owned()
      }
      if parsed.json {
        admin_out_json({ "audit": Json::array(list) })
      } else {
        for e in list {
          let detail = if admin_jtruthy(jfield(e, "detail")) { "\t" + admin_jstr(jfield(e, "detail")) } else { "" }
          out_write("\{admin_fmt_time(jfield(e, "created_at"))}\t\{jtext_or_empty(e, "actor")}\t\{jtext_or_empty(e, "action")}\t\{jtext_or_empty(e, "target")}\{detail}\n")
        }
      }
      return 0
    }

    raise AdminCliError("unknown command: \{group}", 2)
  } catch {
    AdminCliError(msg, code) => {
      err_write("error: \{admin_redact(msg, api_key)}\n")
      code
    }
  }
}
