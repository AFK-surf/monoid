// Backup targets configuration (station/src/replica/backup-config.ts): config.json `backup` parsing, validation,
// update semantics (preserving omitted secrets, CSPRNG key generation on new S3 targets), and sanitized views.

///|
pub let default_backup_prefix : String = "stillfail-backup"

///|
pub let default_backup_region : String = "auto"

///|
pub(all) struct S3TargetConfig {
  id : String
  name : String
  endpoint : String
  region : String
  bucket : String
  prefix : String
  force_path_style : Bool
  access_key_id : String
  secret_access_key : String
  encryption_key : String
  include_transcripts : Bool
}

///|
pub(all) struct BackupConfig {
  mode : String // "auto" | "manual"
  stations : Array[String]
  accept_others : Bool
  s3 : Array[S3TargetConfig]
}

///|
pub fn BackupConfig::default() -> BackupConfig {
  { mode: "auto", stations: [], accept_others: true, s3: [] }
}

///|
pub(all) struct BackupPeerView {
  station : String
  name : String
  accept_others : Bool
  online : Bool
}

///|
pub(all) struct S3TargetStatus {
  to : Double
  at : Double?
  error : String?
  reason : String?
}

///|
/// `/^[a-z0-9_-]{1,32}$/`.
pub fn is_s3_id(s : String) -> Bool {
  s.length() >= 1 &&
  s.length() <= 32 &&
  all_of(s, c => is_digit(c) || (c >= 'a' && c <= 'z') || c == '_' || c == '-')
}

///|
/// `/^[0-9a-f]{64}$/`.
pub fn is_enc_key(s : String) -> Bool {
  is_station(s)
}

///|
/// `/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/` without `..`.
pub fn is_s3_bucket(s : String) -> Bool {
  let n = s.length()
  if n < 3 || n > 63 || s.contains("..") {
    return false
  }
  let is_alnum = (c : Int) => is_digit(c) || (c >= 'a' && c <= 'z')
  if !is_alnum(s.unsafe_charcode_at(0)) || !is_alnum(s.unsafe_charcode_at(n - 1)) {
    return false
  }
  all_of(s, c => is_alnum(c) || c == '.' || c == '-')
}

///|
fn strip_slashes(s : String) -> String {
  let mut a = 0
  let mut b = s.length()
  while a < b && s.unsafe_charcode_at(a) == '/' {
    a += 1
  }
  while b > a && s.unsafe_charcode_at(b - 1) == '/' {
    b -= 1
  }
  s.unsafe_substring(start=a, end=b)
}

///|
fn strip_trailing_slashes(s : String) -> String {
  let mut b = s.length()
  while b > 0 && s.unsafe_charcode_at(b - 1) == '/' {
    b -= 1
  }
  s.unsafe_substring(start=0, end=b)
}

///|
pub fn normalize_prefix(v : J?) -> String raise {
  match v {
    None | Some(Null) => default_backup_prefix
    Some(Str(s)) => strip_slashes(@jsjson.sanitize_str(s).trim().to_string())
    _ => raise failed("s3.prefix must be a string")
  }
}

///|
/// Validates an S3 endpoint URL: https:// always allowed, http:// only for 127.0.0.1 / localhost / [::1].
pub fn validate_endpoint(v : J?) -> String raise {
  let raw = match str_of(v) {
    Some(s) => s.trim().to_string()
    None => ""
  }
  if raw == "" {
    raise failed("s3.endpoint is required")
  }
  if raw.contains("?") || raw.contains("#") {
    raise failed("s3.endpoint must not contain query or fragment")
  }
  let (is_https, rest) = if raw.has_prefix("https://") {
    (true, raw.unsafe_substring(start=8, end=raw.length()))
  } else if raw.has_prefix("http://") {
    (false, raw.unsafe_substring(start=7, end=raw.length()))
  } else {
    raise failed("s3.endpoint must use https:// (http:// is allowed only for loopback)")
  }
  let authority = match rest.find("/") {
    Some(i) => rest.unsafe_substring(start=0, end=i)
    None => rest
  }
  if authority == "" {
    raise failed("s3.endpoint must be a valid URL")
  }
  let host = if authority.has_prefix("[") {
    match authority.find("]") {
      Some(i) => authority.unsafe_substring(start=0, end=i + 1).to_lower()
      None => raise failed("s3.endpoint must be a valid URL")
    }
  } else {
    match authority.find(":") {
      Some(i) => authority.unsafe_substring(start=0, end=i).to_lower()
      None => authority.to_lower()
    }
  }
  let loopback = host == "127.0.0.1" || host == "localhost" || host == "[::1]"
  if !is_https && !loopback {
    raise failed("s3.endpoint must use https:// (http:// is allowed only for loopback)")
  }
  strip_trailing_slashes(raw)
}

///|
pub fn validate_bucket(v : J?) -> String raise {
  match str_of(v) {
    Some(s) if is_s3_bucket(s) => s
    _ => raise failed("s3.bucket must be a valid S3 bucket name (3-63 lowercase letters, digits, dots, or hyphens)")
  }
}

///|
/// `ops/agent-env.ts` `maskValue`: first 5 and last 4 characters, or `••••` if <= 8 chars.
pub fn mask_value(value : String) -> String {
  if value == "" {
    return ""
  }
  let chars = value.to_array()
  if chars.length() <= 8 {
    return "••••"
  }
  let buf = StringBuilder::new()
  for i in 0..<5 {
    buf.write_char(chars[i])
  }
  buf.write_char('…')
  for i in (chars.length() - 4)..<chars.length() {
    buf.write_char(chars[i])
  }
  buf.to_string()
}

///|
/// First 8 lowercase hex chars of SHA-256(keyBytes).
pub fn key_fingerprint(encryption_key : String) -> String {
  if !is_enc_key(encryption_key) {
    return ""
  }
  match @hash.hex_decode(encryption_key) {
    Some(bytes) => @hash.sha256_hex(bytes[:]).unsafe_substring(start=0, end=8)
    None => ""
  }
}

///|
pub fn normalize_s3_target(raw : J, index : Int) -> S3TargetConfig raise {
  guard raw is Obj(_) else { raise failed("backup.s3[\{index}] must be an object") }
  let id = match str_at(raw, "id") {
    Some(s) if is_s3_id(s) => s
    _ => raise failed("backup.s3[\{index}].id must match /^[a-z0-9_-]{1,32}$/")
  }
  let name = match str_at(raw, "name") {
    Some(s) => s.trim().to_string()
    None => ""
  }
  if name == "" {
    raise failed("backup.s3[\{index}].name is required")
  }
  let endpoint = validate_endpoint(at(raw, "endpoint"))
  let region = match at(raw, "region") {
    None | Some(Null) => default_backup_region
    Some(Str(s)) => {
      let t = @jsjson.sanitize_str(s).trim().to_string()
      if t == "" { default_backup_region } else { t }
    }
    _ => raise failed("backup.s3[\{index}].region must be a string")
  }
  let bucket = validate_bucket(at(raw, "bucket"))
  let prefix = normalize_prefix(at(raw, "prefix"))
  let force_path_style = match at(raw, "forcePathStyle") {
    None | Some(Null) => true
    Some(Bool(b)) => b
    _ => raise failed("backup.s3[\{index}].forcePathStyle must be a boolean")
  }
  let access_key_id = match str_at(raw, "accessKeyId") {
    Some(s) => s.trim().to_string()
    None => ""
  }
  if access_key_id == "" {
    raise failed("backup.s3[\{index}].accessKeyId is required")
  }
  let secret_access_key = str_at(raw, "secretAccessKey").unwrap_or("")
  if secret_access_key == "" {
    raise failed("backup.s3[\{index}].secretAccessKey is required")
  }
  let encryption_key = str_at(raw, "encryptionKey").unwrap_or("")
  if !is_enc_key(encryption_key) {
    raise failed("backup.s3[\{index}].encryptionKey must be a 64-character lowercase hex string")
  }
  let include_transcripts = match at(raw, "includeTranscripts") {
    None | Some(Null) => true
    Some(Bool(b)) => b
    _ => raise failed("backup.s3[\{index}].includeTranscripts must be a boolean")
  }
  {
    id,
    name,
    endpoint,
    region,
    bucket,
    prefix,
    force_path_style,
    access_key_id,
    secret_access_key,
    encryption_key,
    include_transcripts,
  }
}

///|
pub fn check_backup_config(raw : J?) -> Unit raise {
  match raw {
    None | Some(Null) => return
    Some(Obj(_) as b) => {
      match at(b, "stations") {
        None | Some(Null) => ()
        Some(Str(s)) if @jsjson.sanitize_str(s) == "auto" => ()
        Some(Arr(xs)) =>
          for x in xs {
            match str_of(Some(x)) {
              Some(id) if is_station(id) => ()
              _ => raise failed("backup.stations must be \"auto\" or an array of station ids")
            }
          }
        _ => raise failed("backup.stations must be \"auto\" or an array of station ids")
      }
      match at(b, "acceptOthers") {
        None | Some(Null) | Some(Bool(_)) => ()
        _ => raise failed("backup.acceptOthers must be a boolean")
      }
      match at(b, "s3") {
        None | Some(Null) => ()
        Some(Arr(xs)) => {
          let seen : Map[String, Bool] = {}
          for i, item in xs {
            let t = normalize_s3_target(item, i)
            if seen.contains(t.id) {
              raise failed("backup.s3: duplicate target id \{t.id}")
            }
            seen[t.id] = true
          }
        }
        _ => raise failed("backup.s3 must be an array")
      }
    }
    _ => raise failed("backup must be an object")
  }
}

///|
pub fn read_backup_config(raw_config : J) -> BackupConfig {
  guard at(raw_config, "backup") is Some(Obj(_) as b) else { return BackupConfig::default() }
  let (mode, stations) = match at(b, "stations") {
    Some(Arr(xs)) => {
      let ids = uniq(xs.filter_map(x => str_of(Some(x))).filter(is_station))
      ("manual", ids)
    }
    _ => ("auto", [])
  }
  let accept_others = match at(b, "acceptOthers") {
    Some(Bool(false)) => false
    _ => true
  }
  let s3 : Array[S3TargetConfig] = []
  let seen : Map[String, Bool] = {}
  match at(b, "s3") {
    Some(Arr(xs)) =>
      for i, item in xs {
        let t = try Some(normalize_s3_target(item, i)) catch { _ => None }
        match t {
          Some(target) if !seen.contains(target.id) => {
            seen[target.id] = true
            s3.push(target)
          }
          _ => ()
        }
      }
    _ => ()
  }
  { mode, stations, accept_others, s3 }
}

///|
pub fn S3TargetConfig::to_json(self : S3TargetConfig) -> J {
  jo([
    ("id", js(self.id)),
    ("name", js(self.name)),
    ("endpoint", js(self.endpoint)),
    ("region", js(self.region)),
    ("bucket", js(self.bucket)),
    ("prefix", js(self.prefix)),
    ("forcePathStyle", jb(self.force_path_style)),
    ("accessKeyId", js(self.access_key_id)),
    ("secretAccessKey", js(self.secret_access_key)),
    ("encryptionKey", js(self.encryption_key)),
    ("includeTranscripts", jb(self.include_transcripts)),
  ])
}

///|
/// Applies a `PUT /copies/settings` payload onto the existing backup config.
/// Returns `(backup_json, generated_keys)`.
pub fn apply_backup_update(
  existing_raw_config : J,
  input : J,
  rand_hex : (Int) -> String,
) -> (J, Array[(String, String)]) raise {
  guard input is Obj(_) else { raise failed("request body must be an object") }
  let cur = read_backup_config(existing_raw_config)
  let existing_s3 : Map[String, S3TargetConfig] = {}
  for t in cur.s3 {
    existing_s3[t.id] = t
  }

  let mut mode = cur.mode
  let mut stations = cur.stations
  match at(input, "mode") {
    None | Some(Null) => ()
    Some(Str(m)) => {
      let s = @jsjson.sanitize_str(m)
      if s != "auto" && s != "manual" {
        raise failed("mode must be \"auto\" or \"manual\"")
      }
      mode = s
    }
    _ => raise failed("mode must be \"auto\" or \"manual\"")
  }
  match at(input, "stations") {
    None | Some(Null) => ()
    Some(Arr(xs)) => {
      let next : Array[String] = []
      for x in xs {
        match str_of(Some(x)) {
          Some(id) if is_station(id) => next.push(id)
          _ => raise failed("invalid station id")
        }
      }
      stations = uniq(next)
      if at(input, "mode") is None {
        mode = "manual"
      }
    }
    _ => raise failed("stations must be an array of station ids")
  }

  let mut accept_others = cur.accept_others
  match at(input, "acceptOthers") {
    None | Some(Null) => ()
    Some(Bool(b)) => accept_others = b
    _ => raise failed("acceptOthers must be a boolean")
  }

  let generated_keys : Array[(String, String)] = []
  let mut s3 = cur.s3
  match at(input, "s3") {
    None | Some(Null) => ()
    Some(Arr(xs)) => {
      let next_s3 : Array[S3TargetConfig] = []
      let seen : Map[String, Bool] = {}
      for i, item in xs {
        guard item is Obj(_) else { raise failed("s3[\{i}] must be an object") }
        let raw_id = str_at(item, "id").unwrap_or("").trim().to_string()
        let id = if raw_id == "" {
          let mut cand = rand_hex(4)
          while seen.contains(cand) || existing_s3.contains(cand) {
            cand = rand_hex(4)
          }
          cand
        } else if is_s3_id(raw_id) {
          raw_id
        } else {
          raise failed("s3[\{i}].id must match /^[a-z0-9_-]{1,32}$/")
        }
        if seen.contains(id) {
          raise failed("duplicate s3 target id: \{id}")
        }
        seen[id] = true

        let prev = existing_s3.get(id)
        let raw_access_key = str_at(item, "accessKeyId").unwrap_or("").trim().to_string()
        let access_key_id = if raw_access_key != "" {
          raw_access_key
        } else {
          match prev {
            Some(p) => p.access_key_id
            None => ""
          }
        }
        let raw_secret = str_at(item, "secretAccessKey").unwrap_or("")
        let secret_access_key = if raw_secret != "" {
          raw_secret
        } else {
          match prev {
            Some(p) => p.secret_access_key
            None => ""
          }
        }
        let raw_key = str_at(item, "encryptionKey").unwrap_or("").trim().to_string()
        let encryption_key = if raw_key != "" {
          raw_key
        } else {
          match prev {
            Some(p) => p.encryption_key
            None => {
              let k = rand_hex(32)
              generated_keys.push((id, k))
              k
            }
          }
        }
        let merged_item = jo([
          ("id", js(id)),
          ("name", at(item, "name").unwrap_or(Null)),
          ("endpoint", at(item, "endpoint").unwrap_or(Null)),
          ("region", at(item, "region").unwrap_or(Null)),
          ("bucket", at(item, "bucket").unwrap_or(Null)),
          ("prefix", at(item, "prefix").unwrap_or(Null)),
          ("forcePathStyle", at(item, "forcePathStyle").unwrap_or(Null)),
          ("accessKeyId", js(access_key_id)),
          ("secretAccessKey", js(secret_access_key)),
          ("encryptionKey", js(encryption_key)),
          ("includeTranscripts", at(item, "includeTranscripts").unwrap_or(Null)),
        ])
        next_s3.push(normalize_s3_target(merged_item, i))
      }
      s3 = next_s3
    }
    _ => raise failed("s3 must be an array")
  }

  let backup = jo([
    ("stations", if mode == "manual" { jstrs(stations) } else { js("auto") }),
    ("acceptOthers", jb(accept_others)),
    ("s3", ja(s3.map(t => t.to_json()))),
  ])
  (backup, generated_keys)
}

///|
/// Pure target selection for `Copies::targets`: manual mode returns configured station ids in roster (excluding `here`);
/// auto mode picks up to `copies_kept` reachable peers in rendezvous order, skipping peers with `accept_others == false`.
pub fn select_backup_targets(
  ws : String,
  here : String,
  roster_ids : Array[String],
  cfg : BackupConfig,
  peer_accepts : Map[String, Bool],
  has_error : (String) -> Bool,
) -> Array[String] {
  if cfg.mode == "manual" {
    return cfg.stations.filter(s => s != here && roster_ids.contains(s))
  }
  let out : Array[String] = []
  let mut reached = 0
  for s in ranked(ws, here, roster_ids) {
    if peer_accepts.get(s) == Some(false) {
      continue
    }
    out.push(s)
    if !has_error(s) {
      reached += 1
    }
    if reached >= copies_kept {
      break
    }
  }
  out
}

///|
/// Builds the sanitized view for `overview.copies.backup` and `GET /copies/settings`.
pub fn backup_view_json(
  cfg : BackupConfig,
  peers : Array[BackupPeerView],
  s3_status : (String) -> S3TargetStatus,
) -> J {
  jo([
    ("mode", js(cfg.mode)),
    ("stations", jstrs(if cfg.mode == "manual" { cfg.stations } else { [] })),
    ("acceptOthers", jb(cfg.accept_others)),
    (
      "peers",
      ja(
        peers.map(p => jo([
          ("station", js(p.station)),
          ("name", js(p.name)),
          ("acceptOthers", jb(p.accept_others)),
          ("online", jb(p.online)),
        ])),
      ),
    ),
    (
      "s3",
      ja(
        cfg.s3.map(t => {
          let st = s3_status(t.id)
          jo([
            ("id", js(t.id)),
            ("name", js(t.name)),
            ("endpoint", js(t.endpoint)),
            ("region", js(t.region)),
            ("bucket", js(t.bucket)),
            ("prefix", js(t.prefix)),
            ("forcePathStyle", jb(t.force_path_style)),
            ("accessKeyMask", js(mask_value(t.access_key_id))),
            ("keyFingerprint", js(key_fingerprint(t.encryption_key))),
            ("includeTranscripts", jb(t.include_transcripts)),
            ("to", jn(st.to)),
            ("at", match st.at { Some(a) => jn(a); None => Null }),
            ("error", jopt(st.error)),
            ("reason", jopt(st.reason)),
          ])
        }),
      ),
    ),
  ])
}
