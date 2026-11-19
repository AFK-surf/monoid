// Unified mbui app packager CLI (`libs/mbui/scripts/mbui`).
//
//   mbui init <dir> [--name NAME] [--id APP_ID] [--mbui PATH]
//   mbui check [mbui.json] [--variant V] [--version VER] [--build N] [--app-id ID]
//   mbui icons [mbui.json] --out DIR [--platform all|mac|win|linux|android|ios|web] [--variant V]
//   mbui pack [mbui.json] --target web|mac [--variant V] [--out DIR] [--version VER]
//             [--build N] [--app-id ID] [--format app,zip,dmg]
//             [--sign-identity ID] [--notarize-profile P] [--quick]

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
  sb.write_string("  mbui init <dir> [--name NAME] [--id APP_ID] [--mbui PATH]\n")
  sb.write_string("  mbui check [mbui.json] [--variant V] [--version VER] [--build N] [--app-id ID]\n")
  sb.write_string(
    "  mbui icons [mbui.json] --out DIR [--platform all|mac|win|linux|android|ios|web] [--variant V]\n",
  )
  sb.write_string(
    "  mbui pack [mbui.json] --target web|mac [--variant V] [--out DIR] [--version VER] [--build N]\n",
  )
  sb.write_string(
    "            [--app-id ID] [--format app,zip,dmg] [--sign-identity ID] [--notarize-profile P] [--quick]\n",
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
fn run_init(args : Array[String]) -> Unit {
  let mut dir = ""
  let mut name = "My App"
  let mut app_id = "dev.example.myapp"
  let mut mbui_path = mbui_root()
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
  cmd_init(dir, name, app_id, mbui_path)
}

///|
fn run_check(args : Array[String]) -> Unit {
  let mut manifest_path = "mbui.json"
  let mut has_pos = false
  let mut variant : String? = None
  let mut version : String? = None
  let mut build : Int? = None
  let mut app_id : String? = None
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
  let (m, _) = load_manifest(manifest_path, { variant, version, build, app_id })
  @sys.out(m.summary())
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
    { variant, version: None, build: None, app_id: None },
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
  let mut target = ""
  let mut out_dir = ""
  let mut variant : String? = None
  let mut version : String? = None
  let mut build : Int? = None
  let mut app_id : String? = None
  let mut formats : Array[String] = []
  let mut sign_identity = ""
  let mut notarize_profile = ""
  let mut quick = false
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--target" => {
        target = next_arg(args, i, "--target")
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
      "--notarize-profile" => {
        notarize_profile = next_arg(args, i, "--notarize-profile")
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
  if target == "" {
    die("pack: missing required --target web|mac")
  }
  let (m, manifest_dir) = load_manifest(manifest_path, { variant, version, build, app_id })
  let abs_out = if out_dir != "" {
    @sys.abspath(out_dir)
  } else {
    @sys.join(manifest_dir, "dist")
  }
  let root = mbui_root()
  match target {
    "web" => pack_web(m, manifest_dir, root, abs_out, quick)
    "mac" => pack_mac(m, manifest_dir, root, abs_out, formats, sign_identity, notarize_profile, quick)
    _ => die("pack: unsupported --target '\{target}' (supported: web, mac)")
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
    "init" => run_init(rest)
    "check" => run_check(rest)
    "icons" => run_icons(rest)
    "pack" => run_pack(rest)
    "-h" | "--help" | "help" => @sys.out(usage())
    _ => {
      @sys.eprintln("mbui: unknown command '\{subcmd}'\n" + usage())
      @sys.exit(2)
    }
  }
}
