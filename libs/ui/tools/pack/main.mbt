// Unified mbui app packager CLI (`libs/ui/scripts/ui`).
//
//   mbui version
//   mbui init <dir> [--name NAME] [--id APP_ID] [--mbui PATH] [--ui PATH]
//   mbui check [mbui.json] [--variant V] [--version VER] [--build N] [--app-id ID] [--runtime native|wasm] [--env K=V ...]
//   mbui meta [mbui.json] [--variant V] [--version VER] [--build N] [--app-id ID] [--runtime native|wasm] [--env K=V ...] [--format sh|json]
//   mbui icons [mbui.json] --out DIR [--platform all|mac|win|linux|android|ios|web] [--variant V]
//   mbui pack [mbui.json] --target <t1,t2,...> [--variant V] [--out DIR] [--version VER] [--build N]
//             [--app-id ID] [--runtime native|wasm] [--runtime-dir DIR] [--wasm-aot] [--format ...] [--env K=V ...]
//             [--sign-identity ID] [--keychain PATH] [--notarize-profile P] [--web-no-compress]
//             [--keystore PATH] [--key-alias A] [--ks-pass SPEC] [--key-pass SPEC] [--v3-signing] [--verify-cert SHA256]
//             [--win-cert PFX] [--win-cert-pass PASS] [--win-timestamp URL]
//             [--ios-sdk iphonesimulator|iphoneos] [--ios-profile MOBILEPROVISION] [--quick]
//   mbui repack [mbui.json] --target android --in IN.apk --out OUT.apk [--variant V] [--version VER]
//               [--build N] [--app-id ID] [--env K=V ...] [signing flags...]
//   mbui publish [mbui.json] [--variant V] [--version VER] [--build N] [--app-id ID] [release flags...]

///|
fn say(msg : String) -> Unit {
  @sys.println_out("mbui: " + msg)
}

///|
fn die(msg : String) -> Unit {
  @sys.eprintln("mbui: " + msg)
  @sys.exit(1)
}

///|
fn q(s : String) -> String {
  "'" + s.replace_all(old="'", new="'\\''") + "'"
}

///|
fn sub(s : String, a : Int, b : Int) -> String {
  s.exact_view(start=a, end=b).to_owned()
}

///|
fn try_sh(cmd : String) -> String? {
  @sys.run_out(cmd + " 2>&1")
}

///|
fn sh(cmd : String, what : String) -> String {
  match try_sh(cmd) {
    Some(out) => out
    None => {
      let said = @sys.run_out("(" + cmd + ") 2>&1; true").unwrap_or("")
      @sys.eprintln(said)
      die("\{what} failed: " + sub(cmd, 0, @cmp.minimum(cmd.length(), 200)))
      ""
    }
  }
}

///|
fn usage() -> String {
  let sb = StringBuilder()
  sb.write_string("usage:\n")
  sb.write_string("  mbui version\n")
  sb.write_string("  mbui init <dir> [--name NAME] [--id APP_ID] [--mbui PATH] [--ui PATH]\n")
  sb.write_string(
    "  mbui check [mbui.json] [--variant V] [--version VER] [--build N] [--app-id ID] [--runtime native|wasm] [--env K=V ...]\n",
  )
  sb.write_string(
    "  mbui meta [mbui.json] [--variant V] [--version VER] [--build N] [--app-id ID] [--runtime native|wasm] [--env K=V ...] [--format sh|json]\n",
  )
  sb.write_string(
    "  mbui icons [mbui.json] --out DIR [--platform all|mac|win|linux|android|ios|web] [--variant V]\n",
  )
  sb.write_string(
    "  mbui pack [mbui.json] --target <t1,t2,...> [--variant V] [--out DIR] [--version VER] [--build N]\n",
  )
  sb.write_string(
    "            [--app-id ID] [--runtime native|wasm] [--runtime-dir DIR] [--wasm-aot] [--format ...] [--env K=V ...]\n",
  )
  sb.write_string(
    "            [--sign-identity ID] [--keychain PATH] [--notarize-profile P] [--web-no-compress]\n",
  )
  sb.write_string(
    "            [--ios-sdk iphonesimulator|iphoneos] [--ios-profile P]\n",
  )
  sb.write_string(
    "            [--keystore PATH] [--key-alias A] [--ks-pass SPEC] [--key-pass SPEC] [--v3-signing] [--verify-cert SHA]\n",
  )
  sb.write_string(
    "            [--win-cert PFX] [--win-cert-pass PASS] [--win-timestamp URL] [--quick]\n",
  )
  sb.write_string(
    "  mbui repack [mbui.json] --target android --in IN.apk --out OUT.apk [--variant V] [--version VER] [--build N] [--app-id ID] [--env K=V ...] [signing...]\n",
  )
  sb.write_string(
    "  mbui publish [mbui.json] [--variant V] [--version VER] [--build N] [--app-id ID] [release args...]\n",
  )
  sb.to_string()
}

///|
fn mbui_root() -> String {
  match @sys.getenv("MBUI_HOME") {
    Some(d) if d != "" => @sys.dirname(@sys.abspath(d))
    _ => @sys.cwd()
  }
}

///|
fn load_manifest(path : String, overrides : CliOverrides) -> (Manifest, String) {
  let full = @sys.abspath(path)
  let text = match @sys.read_text(full) {
    Some(t) => t
    None => {
      die("cannot read manifest: \{full}")
      ""
    }
  }
  let m = match parse_manifest(text, overrides) {
    Ok(m) => m
    Err(e) => {
      die("\{full}: \{e}")
      panic()
    }
  }
  (m, @sys.dirname(full))
}

///|
fn next_arg(args : Array[String], i : Int, flag : String) -> String {
  if i + 1 >= args.length() {
    die("missing value for \{flag}")
  }
  args[i + 1]
}

///|
fn run_version() -> Unit {
  let mod_path = @sys.join(mbui_root(), "moon.mod")
  @sys.out(format_version_from_mod(@sys.read_text(mod_path)))
}

///|
fn run_init(args : Array[String]) -> Unit {
  let mut dir = ""
  let mut name = "My App"
  let mut app_id = "dev.example.myapp"
  let mut mbui_path = mbui_root()
  let mut ui_path : String? = None
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--name" => {
        name = next_arg(args, i, "--name")
        i += 2
      }
      "--id" | "--app-id" => {
        app_id = next_arg(args, i, args[i])
        i += 2
      }
      "--mbui" => {
        mbui_path = next_arg(args, i, "--mbui")
        i += 2
      }
      "--ui" => {
        ui_path = Some(next_arg(args, i, "--ui"))
        i += 2
      }
      a if a.has_prefix("-") => die("init: unknown flag \{a}")
      a => {
        if dir != "" {
          die("init: unexpected positional argument '\{a}'")
        }
        dir = a
        i += 1
      }
    }
  }
  if dir == "" {
    die("init: missing <dir>\n" + usage())
  }
  cmd_init(dir, name, app_id, mbui_path, ui_path)
}

///|
fn run_check(args : Array[String]) -> Unit {
  let mut manifest_path = "mbui.json"
  let mut has_pos = false
  let mut variant : String? = None
  let mut version : String? = None
  let mut build : Int? = None
  let mut app_id : String? = None
  let mut runtime : String? = None
  let env : Array[(String, String)] = []
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--variant" => {
        variant = Some(next_arg(args, i, "--variant"))
        i += 2
      }
      "--version" => {
        version = Some(next_arg(args, i, "--version"))
        i += 2
      }
      "--build" => {
        let raw = next_arg(args, i, "--build")
        match parse_int_str(raw) {
          Some(n) => build = Some(n)
          None => die("invalid --build integer: \{raw}")
        }
        i += 2
      }
      "--app-id" => {
        app_id = Some(next_arg(args, i, "--app-id"))
        i += 2
      }
      "--runtime" => {
        runtime = Some(next_arg(args, i, "--runtime"))
        i += 2
      }
      "--env" => {
        let raw = next_arg(args, i, "--env")
        match parse_env_override(raw) {
          Ok(kv) => env.push(kv)
          Err(e) => die("check: \{e}")
        }
        i += 2
      }
      a if a.has_prefix("-") => die("check: unknown flag \{a}")
      a => {
        if has_pos {
          die("check: unexpected positional argument '\{a}'")
        }
        manifest_path = a
        has_pos = true
        i += 1
      }
    }
  }
  let (m, _) = load_manifest(manifest_path, { variant, version, build, app_id, runtime, env })
  @sys.out(m.summary())
}

///|
fn run_meta(args : Array[String]) -> Unit {
  let mut manifest_path = "mbui.json"
  let mut has_pos = false
  let mut variant : String? = None
  let mut version : String? = None
  let mut build : Int? = None
  let mut app_id : String? = None
  let mut runtime : String? = None
  let env : Array[(String, String)] = []
  let mut format = "json"
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--variant" => {
        variant = Some(next_arg(args, i, "--variant"))
        i += 2
      }
      "--version" => {
        version = Some(next_arg(args, i, "--version"))
        i += 2
      }
      "--build" => {
        let raw = next_arg(args, i, "--build")
        match parse_int_str(raw) {
          Some(n) => build = Some(n)
          None => die("invalid --build integer: \{raw}")
        }
        i += 2
      }
      "--app-id" => {
        app_id = Some(next_arg(args, i, "--app-id"))
        i += 2
      }
      "--runtime" => {
        runtime = Some(next_arg(args, i, "--runtime"))
        i += 2
      }
      "--env" => {
        let raw = next_arg(args, i, "--env")
        match parse_env_override(raw) {
          Ok(kv) => env.push(kv)
          Err(e) => die("meta: \{e}")
        }
        i += 2
      }
      "--format" => {
        format = next_arg(args, i, "--format")
        i += 2
      }
      a if a.has_prefix("-") => die("meta: unknown flag \{a}")
      a => {
        if has_pos {
          die("meta: unexpected positional argument '\{a}'")
        }
        manifest_path = a
        has_pos = true
        i += 1
      }
    }
  }
  let (m, manifest_dir) = load_manifest(
    manifest_path,
    { variant, version, build, app_id, runtime, env },
  )
  match format {
    "json" => @sys.out(render_meta_json(m, manifest_dir))
    "sh" => @sys.out(render_meta_sh(m, manifest_dir))
    _ => die("meta: unsupported --format '\{format}' (expected json or sh)")
  }
}

///|
fn run_icons(args : Array[String]) -> Unit {
  let mut manifest_path = "mbui.json"
  let mut has_pos = false
  let mut out_dir = ""
  let mut platform = "all"
  let mut variant : String? = None
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--out" => {
        out_dir = next_arg(args, i, "--out")
        i += 2
      }
      "--platform" => {
        platform = next_arg(args, i, "--platform")
        i += 2
      }
      "--variant" => {
        variant = Some(next_arg(args, i, "--variant"))
        i += 2
      }
      a if a.has_prefix("-") => die("icons: unknown flag \{a}")
      a => {
        if has_pos {
          die("icons: unexpected positional argument '\{a}'")
        }
        manifest_path = a
        has_pos = true
        i += 1
      }
    }
  }
  if out_dir == "" {
    die("icons: missing required --out DIR")
  }
  let (m, manifest_dir) = load_manifest(
    manifest_path,
    { variant, version: None, build: None, app_id: None, runtime: None, env: [] },
  )
  let abs_out = @sys.abspath(out_dir)
  match generate_icons(m, manifest_dir, abs_out, platform) {
    Ok(files) => {
      for f in files {
        @sys.println_out(f)
      }
      say("generated \{files.length()} icon file(s) in \{abs_out}")
    }
    Err(e) => die("icons: \{e}")
  }
}

///|
fn run_pack(args : Array[String]) -> Unit {
  let mut manifest_path = "mbui.json"
  let mut has_pos = false
  let mut target_raw = ""
  let mut out_dir = ""
  let mut variant : String? = None
  let mut version : String? = None
  let mut build : Int? = None
  let mut app_id : String? = None
  let mut runtime : String? = None
  let env : Array[(String, String)] = []
  let mut formats : Array[String] = []
  let mut runtime_dir = ""
  let mut wasm_aot = false
  let mut quick = false
  let mut web_no_compress = false
  let mut sign_identity = ""
  let mut keychain = ""
  let mut notarize_profile = ""
  let mut keystore = ""
  let mut key_alias = ""
  let mut ks_pass = ""
  let mut key_pass = ""
  let mut v3_signing = false
  let mut verify_cert = ""
  let mut debuggable : Bool? = None
  let mut win_cert = ""
  let mut win_cert_pass = ""
  let mut win_timestamp = ""
  let mut ios_sdk = "iphonesimulator"
  let mut ios_profile = ""
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--target" => {
        target_raw = next_arg(args, i, "--target")
        i += 2
      }
      "--out" => {
        out_dir = next_arg(args, i, "--out")
        i += 2
      }
      "--variant" => {
        variant = Some(next_arg(args, i, "--variant"))
        i += 2
      }
      "--version" => {
        version = Some(next_arg(args, i, "--version"))
        i += 2
      }
      "--build" => {
        let raw = next_arg(args, i, "--build")
        match parse_int_str(raw) {
          Some(n) => build = Some(n)
          None => die("invalid --build integer: \{raw}")
        }
        i += 2
      }
      "--app-id" => {
        app_id = Some(next_arg(args, i, "--app-id"))
        i += 2
      }
      "--runtime" => {
        runtime = Some(next_arg(args, i, "--runtime"))
        i += 2
      }
      "--env" => {
        let raw = next_arg(args, i, "--env")
        match parse_env_override(raw) {
          Ok(kv) => env.push(kv)
          Err(e) => die("pack: \{e}")
        }
        i += 2
      }
      "--runtime-dir" => {
        runtime_dir = next_arg(args, i, "--runtime-dir")
        i += 2
      }
      "--wasm-aot" => {
        wasm_aot = true
        i += 1
      }
      "--web-no-compress" => {
        web_no_compress = true
        i += 1
      }
      "--format" => {
        let raw = next_arg(args, i, "--format")
        formats = raw
          .split(",")
          .map(fn(s) { s.trim(chars=" \t").to_owned() })
          .filter(fn(s) { s.length() > 0 })
          .to_array()
        i += 2
      }
      "--sign-identity" => {
        sign_identity = next_arg(args, i, "--sign-identity")
        i += 2
      }
      "--keychain" => {
        keychain = next_arg(args, i, "--keychain")
        i += 2
      }
      "--notarize-profile" => {
        notarize_profile = next_arg(args, i, "--notarize-profile")
        i += 2
      }
      "--keystore" => {
        keystore = next_arg(args, i, "--keystore")
        i += 2
      }
      "--key-alias" => {
        key_alias = next_arg(args, i, "--key-alias")
        i += 2
      }
      "--ks-pass" => {
        ks_pass = next_arg(args, i, "--ks-pass")
        i += 2
      }
      "--key-pass" => {
        key_pass = next_arg(args, i, "--key-pass")
        i += 2
      }
      "--v3-signing" => {
        v3_signing = true
        i += 1
      }
      "--verify-cert" => {
        verify_cert = next_arg(args, i, "--verify-cert")
        i += 2
      }
      "--debuggable" => {
        let raw = next_arg(args, i, "--debuggable")
        match raw {
          "true" => debuggable = Some(true)
          "false" => debuggable = Some(false)
          _ => die("invalid --debuggable value '\{raw}' (expected true or false)")
        }
        i += 2
      }
      "--win-cert" => {
        win_cert = next_arg(args, i, "--win-cert")
        i += 2
      }
      "--win-cert-pass" => {
        win_cert_pass = next_arg(args, i, "--win-cert-pass")
        i += 2
      }
      "--win-timestamp" => {
        win_timestamp = next_arg(args, i, "--win-timestamp")
        i += 2
      }
      "--ios-sdk" => {
        ios_sdk = next_arg(args, i, "--ios-sdk")
        i += 2
      }
      "--ios-profile" => {
        ios_profile = next_arg(args, i, "--ios-profile")
        i += 2
      }
      "--quick" => {
        quick = true
        i += 1
      }
      a if a.has_prefix("-") => die("pack: unknown flag \{a}")
      a => {
        if has_pos {
          die("pack: unexpected positional argument '\{a}'")
        }
        manifest_path = a
        has_pos = true
        i += 1
      }
    }
  }
  if target_raw == "" {
    die("pack: missing required --target <t1,t2,...> (web, mac, win, linux, android, ios)")
  }
  let targets = match parse_targets(target_raw) {
    Ok(ts) => ts
    Err(e) => {
      die("pack: \{e}")
      []
    }
  }
  let (m, manifest_dir) = load_manifest(
    manifest_path,
    { variant, version, build, app_id, runtime, env },
  )
  let abs_out = if out_dir != "" {
    @sys.abspath(out_dir)
  } else {
    @sys.join(manifest_dir, "dist")
  }
  let root = mbui_root()
  let opts : PackOptions = {
    formats,
    runtime_dir,
    wasm_aot,
    quick,
    web_no_compress,
    sign_identity,
    keychain,
    notarize_profile,
    keystore,
    key_alias,
    ks_pass,
    key_pass,
    v3_signing,
    verify_cert,
    debuggable,
    win_cert,
    win_cert_pass,
    win_timestamp,
    ios_sdk,
    ios_profile,
  }
  for t in targets {
    match t {
      "web" => pack_web(m, manifest_dir, root, abs_out, opts)
      "mac" => pack_mac(m, manifest_dir, root, abs_out, opts)
      "win" => pack_win(m, manifest_dir, root, abs_out, opts)
      "linux" => pack_linux(m, manifest_dir, root, abs_out, opts)
      "android" => pack_android(m, manifest_dir, root, abs_out, opts)
      "ios" => pack_ios(m, manifest_dir, root, abs_out, opts)
      _ => die("pack: unsupported target '\{t}'")
    }
  }
}

///|
fn run_repack(args : Array[String]) -> Unit {
  let mut manifest_path = "mbui.json"
  let mut has_pos = false
  let mut target = ""
  let mut in_path = ""
  let mut out_path = ""
  let mut variant : String? = None
  let mut version : String? = None
  let mut build : Int? = None
  let mut app_id : String? = None
  let env : Array[(String, String)] = []
  let mut keystore = ""
  let mut key_alias = ""
  let mut ks_pass = ""
  let mut key_pass = ""
  let mut v3_signing = false
  let mut verify_cert = ""
  let mut debuggable : Bool? = None
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--target" => {
        target = next_arg(args, i, "--target")
        i += 2
      }
      "--in" => {
        in_path = next_arg(args, i, "--in")
        i += 2
      }
      "--out" => {
        out_path = next_arg(args, i, "--out")
        i += 2
      }
      "--variant" => {
        variant = Some(next_arg(args, i, "--variant"))
        i += 2
      }
      "--version" => {
        version = Some(next_arg(args, i, "--version"))
        i += 2
      }
      "--build" => {
        let raw = next_arg(args, i, "--build")
        match parse_int_str(raw) {
          Some(n) => build = Some(n)
          None => die("invalid --build integer: \{raw}")
        }
        i += 2
      }
      "--app-id" => {
        app_id = Some(next_arg(args, i, "--app-id"))
        i += 2
      }
      "--env" => {
        let raw = next_arg(args, i, "--env")
        match parse_env_override(raw) {
          Ok(kv) => env.push(kv)
          Err(e) => die("repack: \{e}")
        }
        i += 2
      }
      "--keystore" => {
        keystore = next_arg(args, i, "--keystore")
        i += 2
      }
      "--key-alias" => {
        key_alias = next_arg(args, i, "--key-alias")
        i += 2
      }
      "--ks-pass" => {
        ks_pass = next_arg(args, i, "--ks-pass")
        i += 2
      }
      "--key-pass" => {
        key_pass = next_arg(args, i, "--key-pass")
        i += 2
      }
      "--v3-signing" => {
        v3_signing = true
        i += 1
      }
      "--verify-cert" => {
        verify_cert = next_arg(args, i, "--verify-cert")
        i += 2
      }
      "--debuggable" => {
        let raw = next_arg(args, i, "--debuggable")
        match raw {
          "true" => debuggable = Some(true)
          "false" => debuggable = Some(false)
          _ => die("invalid --debuggable value '\{raw}' (expected true or false)")
        }
        i += 2
      }
      a if a.has_prefix("-") => die("repack: unknown flag \{a}")
      a => {
        if has_pos {
          die("repack: unexpected positional argument '\{a}'")
        }
        manifest_path = a
        has_pos = true
        i += 1
      }
    }
  }
  if target != "android" {
    die("repack: --target android is required (got '\{target}')")
  }
  if in_path == "" {
    die("repack: missing required --in <IN.apk>")
  }
  if out_path == "" {
    die("repack: missing required --out <OUT.apk>")
  }
  let (m, _) = load_manifest(
    manifest_path,
    { variant, version, build, app_id, runtime: None, env },
  )
  let opts : PackOptions = {
    ..PackOptions::default(),
    keystore,
    key_alias,
    ks_pass,
    key_pass,
    v3_signing,
    verify_cert,
    debuggable,
  }
  repack_android(m, mbui_root(), in_path, out_path, opts)
}

///|
/// Build CLI argument array for `libs/ui/scripts/release`:
/// - First element is always a valid subcommand (`keygen|sign|verify|delta|feed|publish`),
///   defaulting to `"publish"` when omitted.
/// - Only `"feed"` and `"sign"` auto-fill missing `--version`, `--build`, and `--kind <m.app_id>`.
/// - Never injects `--app-id`, and never injects `--version`/`--build`/`--kind` into
///   `publish`, `keygen`, `verify`, or `delta`.
pub fn build_publish_args(m : Manifest, passthrough : Array[String]) -> Array[String] {
  let is_known_sub = fn(s : String) -> Bool {
    s == "keygen" || s == "sign" || s == "verify" || s == "delta" || s == "feed" || s == "publish"
  }
  let (subcmd, rest) = if passthrough.length() > 0 && is_known_sub(passthrough[0]) {
    let tail : Array[String] = []
    for i in 1..<passthrough.length() {
      tail.push(passthrough[i])
    }
    (passthrough[0], tail)
  } else {
    ("publish", passthrough)
  }
  let out : Array[String] = [subcmd]
  if subcmd == "feed" || subcmd == "sign" {
    if !rest.contains("--version") {
      out.push("--version")
      out.push(m.version)
    }
    if !rest.contains("--build") {
      out.push("--build")
      out.push(m.build.to_string())
    }
    if !rest.contains("--kind") {
      out.push("--kind")
      out.push(m.app_id)
    }
  }
  for a in rest {
    out.push(a)
  }
  out
}

///|
fn run_publish(args : Array[String]) -> Unit {
  let mut manifest_path = "mbui.json"
  let mut has_pos = false
  let mut variant : String? = None
  let mut version : String? = None
  let mut build : Int? = None
  let mut app_id : String? = None
  let passthrough : Array[String] = []
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--variant" => {
        variant = Some(next_arg(args, i, "--variant"))
        i += 2
      }
      "--version" => {
        version = Some(next_arg(args, i, "--version"))
        i += 2
      }
      "--build" => {
        let raw = next_arg(args, i, "--build")
        match parse_int_str(raw) {
          Some(n) => build = Some(n)
          None => die("invalid --build integer: \{raw}")
        }
        i += 2
      }
      "--app-id" => {
        app_id = Some(next_arg(args, i, "--app-id"))
        i += 2
      }
      a if !a.has_prefix("-") && !has_pos && a.has_suffix(".json") => {
        manifest_path = a
        has_pos = true
        i += 1
      }
      a => {
        passthrough.push(a)
        i += 1
      }
    }
  }
  let root = mbui_root()
  let release_script = @sys.join(root, "scripts/release")
  if !@sys.is_file(release_script) {
    die("publish: release tool not found at \{release_script}")
  }
  let (m, _) = load_manifest(
    manifest_path,
    { variant, version, build, app_id, runtime: None, env: [] },
  )
  let fwd = build_publish_args(m, passthrough)
  let quoted = fwd.map(q).join(" ")
  say("publishing \{m.app_id} \{m.version} (build \{m.build})...")
  let out = sh("sh " + q(release_script) + " " + quoted, "scripts/release")
  if out != "" {
    @sys.out(out)
  }
}

///|
fn main {
  let all = @env.args()
  if all.length() < 2 {
    @sys.eprintln(usage())
    @sys.exit(2)
  }
  let subcmd = all[1]
  let rest : Array[String] = []
  for i in 2..<all.length() {
    rest.push(all[i])
  }
  match subcmd {
    "version" | "--version" | "-V" => run_version()
    "init" => run_init(rest)
    "check" => run_check(rest)
    "meta" => run_meta(rest)
    "icons" => run_icons(rest)
    "pack" => run_pack(rest)
    "repack" => run_repack(rest)
    "publish" => run_publish(rest)
    "-h" | "--help" | "help" => @sys.out(usage())
    _ => {
      @sys.eprintln("mbui: unknown command '\{subcmd}'\n" + usage())
      @sys.exit(2)
    }
  }
}
