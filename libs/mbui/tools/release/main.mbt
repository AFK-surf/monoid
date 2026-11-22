// Generic mbui release tool: Ed25519 keygen/sign/verify, SFDELTA1 delta generation,
// latest.json feed generation, and ordered publishing (dir / github / s3).

///|
fn say(msg : String) -> Unit {
  @sys.println_out("release: " + msg)
}

///|
fn[T] die(msg : String) -> T {
  @sys.eprintln("release: " + msg)
  @sys.exit(1)
  panic()
}

///|
fn q(s : String) -> String {
  "'" + s.replace_all(old="'", new="'\\''") + "'"
}

///|
fn next_arg(args : Array[String], i : Int, flag : String) -> String {
  if i + 1 >= args.length() {
    die("missing value for \{flag}")
  }
  args[i + 1]
}

///|
fn parse_pos_int(s : String, what : String) -> Int {
  let trimmed = s.trim().to_owned()
  if trimmed == "" {
    die("invalid \{what}: \{s}")
  }
  let mut v = 0
  for i in 0..<trimmed.length() {
    let c = trimmed.unsafe_get(i).to_int()
    if c < 48 || c > 57 {
      die("invalid \{what}: \{s}")
    }
    v = v * 10 + (c - 48)
  }
  if v <= 0 {
    die("\{what} must be positive: \{s}")
  }
  v
}

///|
fn rjson_int64(v : @rjson.Value?) -> Int64? {
  match v {
    Some(@rjson.Num(s)) => {
      let mut acc = 0L
      if s.length() == 0 {
        return None
      }
      for i in 0..<s.length() {
        let c = s.unsafe_get(i).to_int()
        if c < 48 || c > 57 {
          return None
        }
        acc = acc * 10L + (c - 48).to_int64()
      }
      Some(acc)
    }
    _ => None
  }
}

///|
fn read_seed_from_urandom() -> Result[Bytes, String] {
  match @sys.run_out("head -c 32 /dev/urandom | od -An -tx1") {
    Some(text) => {
      let sb = StringBuilder()
      for c in text {
        if (c >= '0' && c <= '9') ||
          (c >= 'a' && c <= 'f') ||
          (c >= 'A' && c <= 'F') {
          sb.write_char(c)
        }
      }
      let hex = sb.to_string()
      match hex_decode_exact(hex) {
        Some(b) if b.length() == 32 => Ok(b)
        _ => Err("failed to read 32 random bytes from /dev/urandom")
      }
    }
    None => Err("failed to invoke /dev/urandom for entropy")
  }
}

///|
fn build_signed_block(
  seed : Bytes,
  kind : String,
  version : String,
  build : Int,
  file_name : String,
  sha256 : String,
  size : Int64,
  raw : (String, Int64)?,
) -> Result[(String, String, String), String] {
  let pk = ed25519_public_key(seed)
  let kid = key_id(pk)
  let kvs : Array[(String, @rjson.Value)] = [
    ("kind", @rjson.Str(kind)),
    ("version", @rjson.Str(version)),
    ("build", @rjson.Num(build.to_string())),
    ("file", @rjson.Str(file_name)),
    ("sha256", @rjson.Str(sha256)),
    ("size", @rjson.Num(size.to_string())),
  ]
  match raw {
    Some((rsha, rsize)) =>
      kvs.push(
        (
          "raw",
          @rjson.Obj([
            ("sha256", @rjson.Str(rsha)),
            ("size", @rjson.Num(rsize.to_string())),
          ]),
        ),
      )
    None => ()
  }
  let words_json = @rjson.dumps(@rjson.Obj(kvs), compact=true)
  let words_bytes = @utf8.encode(words_json)
  let sig = ed25519_sign(seed, words_bytes)
  if !ed25519_verify(pk, words_bytes, sig) {
    return Err("internal error: generated signature failed self-verification")
  }
  Ok((kid, base64_encode(words_bytes), base64_encode(sig)))
}

///|
fn verify_json_text(
  json_text : String,
  pubkey_b64 : String,
  expected_kind : String,
) -> Result[String, String] {
  let pk = match base64_decode_exact(pubkey_b64) {
    Some(b) if b.length() == 32 => b
    _ => return Err("invalid --pubkey: expected 32-byte base64 Ed25519 public key")
  }
  let root = @rjson.parse(json_text) catch {
    _ => return Err("input is not valid JSON")
  }
  let is_feed = root.get("signed") is Some(_)
  let signed_obj = match root.get("signed") {
    Some(s) => s
    None => root
  }
  let key = match signed_obj.get("key").bind(fn(v) { v.str() }) {
    Some(s) if s != "" => s
    _ => return Err("missing signed key")
  }
  let release_b64 = match signed_obj.get("release").bind(fn(v) { v.str() }) {
    Some(s) if s != "" => s
    _ => return Err("missing signed release")
  }
  let sig_b64 = match signed_obj.get("signature").bind(fn(v) { v.str() }) {
    Some(s) if s != "" => s
    _ => return Err("missing signature")
  }
  let expected_kid = key_id(pk)
  if key != expected_kid {
    return Err("key id mismatch: signed with \{key}, pubkey is \{expected_kid}")
  }
  let words_bytes = match base64_decode_exact(release_b64) {
    Some(b) => b
    None => return Err("signed release is not valid base64")
  }
  let sig_bytes = match base64_decode_exact(sig_b64) {
    Some(b) => b
    None => return Err("signature is not valid base64")
  }
  if !ed25519_verify(pk, words_bytes, sig_bytes) {
    return Err("Ed25519 signature verification failed")
  }
  let words_text = @utf8.decode_lossy(words_bytes[:])
  let words = @rjson.parse(words_text) catch {
    _ => return Err("signed release payload is not valid JSON")
  }
  let kind = words.get("kind").bind(fn(v) { v.str() }).unwrap_or("")
  if expected_kind != "" && kind != expected_kind {
    return Err("kind mismatch: expected \{expected_kind}, got \{kind}")
  }
  let w_build = match rjson_int64(words.get("build")) {
    Some(n) if n > 0L => n
    _ => return Err("signed payload missing positive build")
  }
  let w_file = match words.get("file").bind(fn(v) { v.str() }) {
    Some(s) if s != "" => s
    _ => return Err("signed payload missing file")
  }
  let w_sha = match words.get("sha256").bind(fn(v) { v.str() }) {
    Some(s) if s.length() == 64 => s
    _ => return Err("signed payload missing 64-hex sha256")
  }
  let w_size = match rjson_int64(words.get("size")) {
    Some(n) if n > 0L => n
    _ => return Err("signed payload missing positive size")
  }
  if is_feed {
    match rjson_int64(root.get("versionCode")) {
      Some(vc) if vc == w_build => ()
      _ => return Err("feed versionCode does not match signed build")
    }
    match root.get("file").bind(fn(v) { v.str() }) {
      Some(f) if @sys.basename(f) == w_file => ()
      _ => return Err("feed file does not match signed file")
    }
    match root.get("sha256").bind(fn(v) { v.str() }) {
      Some(s) if s == w_sha => ()
      _ => return Err("feed sha256 does not match signed sha256")
    }
    match rjson_int64(root.get("size")) {
      Some(sz) if sz == w_size => ()
      _ => return Err("feed size does not match signed size")
    }
  }
  let w_ver = words.get("version").bind(fn(v) { v.str() }).unwrap_or("")
  Ok("verified \{w_file} (\{w_ver} build \{w_build}, kind \{kind}, key \{key})")
}

///|
fn build_feed_json_pure(
  file_name : String,
  data : Bytes,
  version : String,
  build : Int,
  kind : String,
  seed : Bytes?,
  raw_bytes : Bytes?,
  deltas : Array[(Int, String, Bytes)],
) -> Result[(String, Array[String]), String] {
  let sha = sha256_hex(data)
  let size = data.length().to_int64()
  let raw_info : (String, Int64)? = match raw_bytes {
    Some(rb) => Some((sha256_hex(rb), rb.length().to_int64()))
    None => None
  }
  let warnings : Array[String] = []
  let deltas_arr : Array[@rjson.Value] = []
  for item in deltas {
    let (from_build, dname, db) = item
    let dsize = db.length().to_int64()
    if dsize <= 0L || dsize >= size {
      warnings.push(
        "skipping delta \{dname} (size \{dsize} >= full size \{size})",
      )
      continue
    }
    deltas_arr.push(
      @rjson.Obj([
        ("from", @rjson.Num(from_build.to_string())),
        ("file", @rjson.Str(dname)),
        ("sha256", @rjson.Str(sha256_hex(db))),
        ("size", @rjson.Num(dsize.to_string())),
      ]),
    )
  }
  let kvs : Array[(String, @rjson.Value)] = [
    ("version", @rjson.Str(version)),
    ("versionCode", @rjson.Num(build.to_string())),
    ("file", @rjson.Str(file_name)),
    ("sha256", @rjson.Str(sha)),
    ("size", @rjson.Num(size.to_string())),
  ]
  match raw_info {
    Some((rsha, rsize)) =>
      kvs.push(
        (
          "raw",
          @rjson.Obj([
            ("sha256", @rjson.Str(rsha)),
            ("size", @rjson.Num(rsize.to_string())),
          ]),
        ),
      )
    None => ()
  }
  if deltas_arr.length() > 0 {
    kvs.push(("deltas", @rjson.Arr(deltas_arr)))
  }
  match seed {
    Some(s) => {
      let effective_kind = if kind != "" { kind } else { "app" }
      let (kid, rel_b64, sig_b64) = match build_signed_block(
        s, effective_kind, version, build, file_name, sha, size, raw_info,
      ) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      kvs.push(
        (
          "signed",
          @rjson.Obj([
            ("key", @rjson.Str(kid)),
            ("release", @rjson.Str(rel_b64)),
            ("signature", @rjson.Str(sig_b64)),
          ]),
        ),
      )
    }
    None => ()
  }
  Ok((@rjson.dumps(@rjson.Obj(kvs), indent=2) + "\n", warnings))
}

///|
fn build_feed_json(
  artifact_path : String,
  version : String,
  build : Int,
  kind : String,
  key_path : String,
  raw_path : String,
  delta_specs : Array[(Int, String)],
) -> Result[(String, Array[String]), String] {
  let data = match @sys.read_bytes(artifact_path) {
    Some(b) => b
    None => return Err("cannot read artifact: \{artifact_path}")
  }
  let raw_bytes : Bytes? = if raw_path != "" {
    match @sys.read_bytes(raw_path) {
      Some(rb) => Some(rb)
      None => return Err("cannot read raw artifact: \{raw_path}")
    }
  } else {
    None
  }
  let deltas : Array[(Int, String, Bytes)] = []
  for spec in delta_specs {
    let (from_build, dpath) = spec
    let db = match @sys.read_bytes(dpath) {
      Some(b) => b
      None => return Err("cannot read delta file: \{dpath}")
    }
    deltas.push((from_build, @sys.basename(dpath), db))
  }
  let seed : Bytes? = if key_path != "" {
    let key_text = match @sys.read_text(key_path) {
      Some(t) => t
      None => return Err("cannot read signing key: \{key_path}")
    }
    match decode_private_key(key_text) {
      Ok(s) => Some(s)
      Err(e) => return Err(e)
    }
  } else {
    None
  }
  build_feed_json_pure(
    @sys.basename(artifact_path),
    data,
    version,
    build,
    kind,
    seed,
    raw_bytes,
    deltas,
  )
}

///|
/// Pure ordering: all non-feed files sorted lexicographically, followed by `latest.json` last.
fn ordered_publish_names(names : Array[String]) -> Array[String] {
  let sorted = names.copy()
  sorted.sort_by(fn(a, b) { @rjson.str_cmp(a, b) })
  let out : Array[String] = []
  let mut has_feed = false
  for name in sorted {
    if name == "latest.json" {
      has_feed = true
    } else {
      out.push(name)
    }
  }
  if has_feed {
    out.push("latest.json")
  }
  out
}

///|
fn join_path_pure(a : String, b : String) -> String {
  if b.has_prefix("/") || a == "" {
    b
  } else if a.has_suffix("/") {
    a + b
  } else {
    a + "/" + b
  }
}

///|
fn plan_publish_commands(
  dir : String,
  files : Array[String],
  provider : String,
  target : String,
  tag : String,
  endpoint : String,
) -> Result[Array[String], String] {
  let log : Array[String] = []
  match provider {
    "dir" => {
      for name in files {
        let src = join_path_pure(dir, name)
        let dst = join_path_pure(target, name)
        log.push("copy \{src} -> \{dst}")
      }
      Ok(log)
    }
    "github" => {
      let effective_tag = if tag != "" { tag } else { target }
      let repo_flag = if tag != "" && target != "" {
        " --repo " + q(target)
      } else {
        ""
      }
      for name in files {
        let src = join_path_pure(dir, name)
        log.push(
          "gh release upload " +
          q(effective_tag) +
          " " +
          q(src) +
          " --clobber" +
          repo_flag,
        )
      }
      Ok(log)
    }
    "s3" => {
      let mut dst_base = target
      while dst_base.has_suffix("/") {
        dst_base = dst_base.exact_view(end=dst_base.length() - 1).to_owned()
      }
      let ep_flag = if endpoint != "" {
        " --endpoint-url " + q(endpoint)
      } else {
        ""
      }
      for name in files {
        let src = join_path_pure(dir, name)
        let dst = dst_base + "/" + name
        let cache = if name == "latest.json" {
          "no-cache, no-store, must-revalidate"
        } else {
          "public, max-age=31536000, immutable"
        }
        log.push(
          "aws s3 cp " +
          q(src) +
          " " +
          q(dst) +
          " --cache-control " +
          q(cache) +
          ep_flag,
        )
      }
      Ok(log)
    }
    _ => Err("unsupported provider: \{provider} (expected dir, github, or s3)")
  }
}

///|
/// Return the ordered list of files in `dir` to publish: all artifacts/deltas first (sorted),
/// then `latest.json` strictly last.
fn ordered_publish_files(dir : String) -> Array[String] {
  let raw = @sys.list_dir(dir)
  let regular : Array[String] = []
  for name in raw {
    if @sys.is_file(@sys.join(dir, name)) {
      regular.push(name)
    }
  }
  ordered_publish_names(regular)
}

///|
fn run_publish_impl(
  dir : String,
  provider : String,
  target : String,
  tag : String,
  endpoint : String,
  dry_run : Bool,
) -> Result[Array[String], String] {
  if !@sys.is_dir(dir) {
    return Err("release directory does not exist: \{dir}")
  }
  let files = ordered_publish_files(dir)
  if files.length() == 0 {
    return Err("release directory contains no files: \{dir}")
  }
  let steps = match plan_publish_commands(dir, files, provider, target, tag, endpoint) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  if dry_run {
    return Ok(steps)
  }
  match provider {
    "dir" => {
      @sys.makedirs(target)
      for name in files {
        let src = @sys.join(dir, name)
        let dst = @sys.join(target, name)
        match @sys.read_bytes(src) {
          Some(bytes) =>
            if !@sys.write_bytes(dst, bytes) {
              return Err("failed to write \{dst}")
            }
          None => return Err("failed to read \{src}")
        }
      }
      Ok(steps)
    }
    "github" | "s3" => {
      for cmd in steps {
        match @sys.run_out(cmd + " 2>&1") {
          Some(_) => ()
          None => return Err("\{provider} upload failed: \{cmd}")
        }
      }
      Ok(steps)
    }
    _ => Err("unsupported provider: \{provider}")
  }
}

///|
fn usage() -> String {
  let sb = StringBuilder()
  sb.write_string("usage:\n")
  sb.write_string("  release keygen --out <priv.pem> [--seed-hex HEX]\n")
  sb.write_string(
    "  release sign <file> --key <priv.pem> --kind <kind> --version <ver> --build <N> [--raw <raw_file>] [--out <file.sig>]\n",
  )
  sb.write_string(
    "  release verify <latest.json|file.sig> --pubkey <b64> [--kind <kind>]\n",
  )
  sb.write_string(
    "  release delta --old-dir <dir> --new <target_file> --out <out.delta>\n",
  )
  sb.write_string(
    "  release feed --file <artifact> --version <ver> --build <N> [--kind <kind>] [--key <priv.pem>] [--raw <raw_file>] [--delta <from>:<delta_file> ...] --out-dir <dir>\n",
  )
  sb.write_string(
    "  release publish --dir <release-dir> --provider dir|github|s3 --target <dest> [--tag <tag>] [--endpoint <url>] [--dry-run]\n",
  )
  sb.to_string()
}

///|
fn cmd_keygen(args : Array[String]) -> Unit {
  let mut out_path = ""
  let mut seed_hex = ""
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--out" => {
        out_path = next_arg(args, i, "--out")
        i += 2
      }
      "--seed-hex" => {
        seed_hex = next_arg(args, i, "--seed-hex")
        i += 2
      }
      other => die("unknown flag for keygen: \{other}")
    }
  }
  if out_path == "" {
    die("keygen requires --out <priv.pem>")
  }
  let seed = if seed_hex != "" {
    match hex_decode_exact(seed_hex) {
      Some(b) if b.length() == 32 => b
      _ => die("--seed-hex must be 64 hex characters (32 bytes)")
    }
  } else {
    match read_seed_from_urandom() {
      Ok(b) => b
      Err(e) => die(e)
    }
  }
  let parent = @sys.dirname(out_path)
  if parent != "" {
    @sys.makedirs(parent)
  }
  let pem = encode_pkcs8_pem(seed)
  if !@sys.write_text(out_path, pem) {
    die("failed to write private key to \{out_path}")
  }
  let _ = @sys.run_out("chmod 600 " + q(out_path))
  let pk = ed25519_public_key(seed)
  let pk_b64 = base64_encode(pk)
  let kid = key_id(pk)
  @sys.println_out("\{pk_b64}  (id \{kid})")
}

///|
fn cmd_sign(args : Array[String]) -> Unit {
  let mut file = ""
  let mut key_path = ""
  let mut kind = ""
  let mut version = ""
  let mut build_str = ""
  let mut raw_path = ""
  let mut out_path = ""
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--key" => {
        key_path = next_arg(args, i, "--key")
        i += 2
      }
      "--kind" => {
        kind = next_arg(args, i, "--kind")
        i += 2
      }
      "--version" => {
        version = next_arg(args, i, "--version")
        i += 2
      }
      "--build" => {
        build_str = next_arg(args, i, "--build")
        i += 2
      }
      "--raw" => {
        raw_path = next_arg(args, i, "--raw")
        i += 2
      }
      "--out" => {
        out_path = next_arg(args, i, "--out")
        i += 2
      }
      other =>
        if other.has_prefix("-") {
          die("unknown flag for sign: \{other}")
        } else if file == "" {
          file = other
          i += 1
        } else {
          die("unexpected argument for sign: \{other}")
        }
    }
  }
  if file == "" || key_path == "" || kind == "" || version == "" || build_str == "" {
    die(
      "sign requires <file> --key <priv.pem> --kind <kind> --version <ver> --build <N>",
    )
  }
  let build = parse_pos_int(build_str, "build")
  let data = match @sys.read_bytes(file) {
    Some(b) => b
    None => die("cannot read file: \{file}")
  }
  let key_text = match @sys.read_text(key_path) {
    Some(t) => t
    None => die("cannot read key: \{key_path}")
  }
  let seed = match decode_private_key(key_text) {
    Ok(s) => s
    Err(e) => die(e)
  }
  let raw_info : (String, Int64)? = if raw_path != "" {
    match @sys.read_bytes(raw_path) {
      Some(rb) => Some((sha256_hex(rb), rb.length().to_int64()))
      None => die("cannot read raw file: \{raw_path}")
    }
  } else {
    None
  }
  let (kid, rel_b64, sig_b64) = match build_signed_block(
    seed,
    kind,
    version,
    build,
    @sys.basename(file),
    sha256_hex(data),
    data.length().to_int64(),
    raw_info,
  ) {
    Ok(v) => v
    Err(e) => die(e)
  }
  let sig_json = @rjson.dumps(
      @rjson.Obj([
        ("version", @rjson.Str(version)),
        ("build", @rjson.Num(build.to_string())),
        ("key", @rjson.Str(kid)),
        ("release", @rjson.Str(rel_b64)),
        ("signature", @rjson.Str(sig_b64)),
      ]),
      compact=true,
    ) +
    "\n"
  let target = if out_path != "" { out_path } else { file + ".sig" }
  let parent = @sys.dirname(target)
  if parent != "" {
    @sys.makedirs(parent)
  }
  if !@sys.write_text(target, sig_json) {
    die("failed to write signature to \{target}")
  }
  say("\{target}: signed by \{kid}")
}

///|
fn cmd_verify(args : Array[String]) -> Unit {
  let mut file = ""
  let mut pubkey = ""
  let mut kind = ""
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--pubkey" => {
        pubkey = next_arg(args, i, "--pubkey")
        i += 2
      }
      "--kind" => {
        kind = next_arg(args, i, "--kind")
        i += 2
      }
      other =>
        if other.has_prefix("-") {
          die("unknown flag for verify: \{other}")
        } else if file == "" {
          file = other
          i += 1
        } else {
          die("unexpected argument for verify: \{other}")
        }
    }
  }
  if file == "" || pubkey == "" {
    die("verify requires <latest.json|file.sig> --pubkey <b64>")
  }
  let text = match @sys.read_text(file) {
    Some(t) => t
    None => die("cannot read file: \{file}")
  }
  match verify_json_text(text, pubkey, kind) {
    Ok(msg) => say(msg)
    Err(e) => die(e)
  }
}

///|
fn cmd_delta(args : Array[String]) -> Unit {
  let mut old_dir = ""
  let mut new_file = ""
  let mut out_path = ""
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--old-dir" => {
        old_dir = next_arg(args, i, "--old-dir")
        i += 2
      }
      "--new" => {
        new_file = next_arg(args, i, "--new")
        i += 2
      }
      "--out" => {
        out_path = next_arg(args, i, "--out")
        i += 2
      }
      other => die("unknown flag for delta: \{other}")
    }
  }
  if old_dir == "" || new_file == "" || out_path == "" {
    die("delta requires --old-dir <dir> --new <target_file> --out <out.delta>")
  }
  if !@sys.is_dir(old_dir) {
    die("old directory does not exist: \{old_dir}")
  }
  let rels = collect_rel_files(old_dir)
  let old_files : Array[(String, Bytes)] = []
  for rel in rels {
    let full = @sys.join(old_dir, rel)
    match @sys.read_bytes(full) {
      Some(b) => old_files.push((rel, b))
      None => die("cannot read old file: \{full}")
    }
  }
  let new_bytes = match @sys.read_bytes(new_file) {
    Some(b) => b
    None => die("cannot read new file: \{new_file}")
  }
  let delta = match encode_sfdelta1(old_files, new_bytes) {
    Ok(d) => d
    Err(e) => die(e)
  }
  let parent = @sys.dirname(out_path)
  if parent != "" {
    @sys.makedirs(parent)
  }
  if !@sys.write_bytes(out_path, delta) {
    die("failed to write delta to \{out_path}")
  }
  let pct = if new_bytes.length() > 0 {
    delta.length() * 100 / new_bytes.length()
  } else {
    0
  }
  say(
    "\{out_path}: \{delta.length()} bytes (\{pct}% of \{new_bytes.length()} bytes, \{old_files.length()} old files)",
  )
}

///|
fn cmd_feed(args : Array[String]) -> Unit {
  let mut file = ""
  let mut version = ""
  let mut build_str = ""
  let mut kind = ""
  let mut key_path = ""
  let mut raw_path = ""
  let mut out_dir = ""
  let deltas : Array[(Int, String)] = []
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--file" => {
        file = next_arg(args, i, "--file")
        i += 2
      }
      "--version" => {
        version = next_arg(args, i, "--version")
        i += 2
      }
      "--build" => {
        build_str = next_arg(args, i, "--build")
        i += 2
      }
      "--kind" => {
        kind = next_arg(args, i, "--kind")
        i += 2
      }
      "--key" => {
        key_path = next_arg(args, i, "--key")
        i += 2
      }
      "--raw" => {
        raw_path = next_arg(args, i, "--raw")
        i += 2
      }
      "--delta" => {
        let spec = next_arg(args, i, "--delta")
        match spec.find(":") {
          Some(idx) => {
            let from_s = spec.exact_view(end=idx).to_owned()
            let dpath = spec.exact_view(start=idx + 1).to_owned()
            deltas.push((parse_pos_int(from_s, "delta from build"), dpath))
          }
          None => die("--delta must be <from>:<delta_file>, got: \{spec}")
        }
        i += 2
      }
      "--out-dir" => {
        out_dir = next_arg(args, i, "--out-dir")
        i += 2
      }
      other => die("unknown flag for feed: \{other}")
    }
  }
  if file == "" || version == "" || build_str == "" || out_dir == "" {
    die(
      "feed requires --file <artifact> --version <ver> --build <N> --out-dir <dir>",
    )
  }
  let build = parse_pos_int(build_str, "build")
  let (feed_json, warnings) = match build_feed_json(
    file, version, build, kind, key_path, raw_path, deltas,
  ) {
    Ok(v) => v
    Err(e) => die(e)
  }
  for w in warnings {
    @sys.eprintln("release: warning: " + w)
  }
  @sys.makedirs(out_dir)
  let out_path = @sys.join(out_dir, "latest.json")
  if !@sys.write_text(out_path, feed_json) {
    die("failed to write \{out_path}")
  }
  say("wrote \{out_path}")
}

///|
fn cmd_publish(args : Array[String]) -> Unit {
  let mut dir = ""
  let mut provider = ""
  let mut target = ""
  let mut tag = ""
  let mut endpoint = ""
  let mut dry_run = false
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--dir" => {
        dir = next_arg(args, i, "--dir")
        i += 2
      }
      "--provider" => {
        provider = next_arg(args, i, "--provider")
        i += 2
      }
      "--target" => {
        target = next_arg(args, i, "--target")
        i += 2
      }
      "--tag" => {
        tag = next_arg(args, i, "--tag")
        i += 2
      }
      "--endpoint" => {
        endpoint = next_arg(args, i, "--endpoint")
        i += 2
      }
      "--dry-run" => {
        dry_run = true
        i += 1
      }
      other => die("unknown flag for publish: \{other}")
    }
  }
  if dir == "" || provider == "" || target == "" {
    die("publish requires --dir <release-dir> --provider dir|github|s3 --target <dest>")
  }
  match run_publish_impl(dir, provider, target, tag, endpoint, dry_run) {
    Ok(steps) =>
      for step in steps {
        say(if dry_run { "[dry-run] " + step } else { step })
      }
    Err(e) => die(e)
  }
}

///|
fn main {
  let argv = @env.args()
  if argv.length() < 2 {
    @sys.eprintln(usage())
    @sys.exit(2)
  }
  let sub = argv[1]
  let rest : Array[String] = []
  for i in 2..<argv.length() {
    rest.push(argv[i])
  }
  match sub {
    "keygen" => cmd_keygen(rest)
    "sign" => cmd_sign(rest)
    "verify" => cmd_verify(rest)
    "delta" => cmd_delta(rest)
    "feed" => cmd_feed(rest)
    "publish" => cmd_publish(rest)
    "-h" | "--help" | "help" => @sys.out(usage())
    _ => {
      @sys.eprintln("release: unknown command: \{sub}\n" + usage())
      @sys.exit(2)
    }
  }
}
