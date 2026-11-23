// Project scaffolding: `mbui init <dir> [--name NAME] [--id APP_ID] [--mbui PATH] [--ui PATH]`.

///|
pub let cli_version : String = "0.1.0"

///|
pub struct UiLibRef {
  path : String
  name : String
  version : String
  import_pkg : String
}

///|
/// Parse a top-level `key = "value"` field from a `moon.mod` file.
pub fn parse_moon_mod_field(text : String, key : String) -> String? {
  for line_view in text.split("\n") {
    let line = line_view.to_owned().trim(chars=" \t\r").to_owned()
    if line.length() == 0 || line.has_prefix("//") {
      continue
    }
    match line.find("=") {
      Some(eq_idx) => {
        let k = line.exact_view(end=eq_idx).to_owned().trim(chars=" \t").to_owned()
        if k != key {
          continue
        }
        let rest = line.exact_view(start=eq_idx + 1).to_owned().trim(chars=" \t").to_owned()
        if rest.length() >= 2 && rest.has_prefix("\"") && rest.has_suffix("\"") {
          return Some(rest.exact_view(start=1, end=rest.length() - 1).to_owned())
        }
      }
      None => ()
    }
  }
  None
}

///|
/// Format the output of `mbui version` from the mbui root's `moon.mod` text.
pub fn format_version_from_mod(mod_text : String?) -> String {
  let mod_name = match mod_text {
    Some(t) => parse_moon_mod_field(t, "name").unwrap_or("ui")
    None => "ui"
  }
  let mod_ver = match mod_text {
    Some(t) => parse_moon_mod_field(t, "version").unwrap_or(cli_version)
    None => cli_version
  }
  "mbui (ui.monoid) cli \{cli_version}\nmodule: \{mod_name}@\{mod_ver}\n"
}

///|
/// Return true when a `moon.pkg` declares `"is-main": true`.
pub fn pkg_is_main(text : String) -> Bool {
  for line_view in text.split("\n") {
    let line = line_view.to_owned().trim(chars=" \t\r").to_owned()
    if line.has_prefix("//") {
      continue
    }
    match line.find("\"is-main\"") {
      Some(idx) => {
        let rest = line.exact_view(start=idx + 9).to_owned().trim(chars=" \t:").to_owned()
        if rest.has_prefix("true") {
          return true
        }
      }
      None => ()
    }
  }
  false
}

///|
fn is_aux_ui_subpkg(sub : String) -> Bool {
  sub == "shots" || sub == "gallery" || sub == "demo" || sub == "pages"
}

///|
/// Pick the primary library subpackage from `(subdir_name, is_main)` entries.
/// Skips `is-main` executables and prefers non-auxiliary packages over
/// `shots`/`gallery`/`demo`/`pages`.
pub fn pick_ui_subpkg(name : String, candidates : Array[(String, Bool)]) -> String {
  let non_main : Array[String] = []
  for item in candidates {
    if !item.1 {
      non_main.push(item.0)
    }
  }
  for sub in non_main {
    if !is_aux_ui_subpkg(sub) {
      return "\{name}/\{sub}"
    }
  }
  if non_main.length() > 0 {
    "\{name}/\{non_main[0]}"
  } else {
    name
  }
}

///|
/// Resolve `--ui <path>` by reading its `moon.mod` and discovering an import package path.
pub fn resolve_ui_lib(ui_path : String) -> Result[UiLibRef, String] {
  let abs_ui = @sys.abspath(ui_path)
  let mod_path = @sys.join(abs_ui, "moon.mod")
  let mod_text = match @sys.read_text(mod_path) {
    Some(t) => t
    None => return Err("cannot read UI library moon.mod at \{mod_path}")
  }
  let name = match parse_moon_mod_field(mod_text, "name") {
    Some(n) if n.length() > 0 => n
    _ => return Err("missing 'name' in \{mod_path}")
  }
  let version = parse_moon_mod_field(mod_text, "version").unwrap_or("0.1.0")
  let src_dir_rel = parse_moon_mod_field(mod_text, "source").unwrap_or("src")
  let src_dir = @sys.join(abs_ui, src_dir_rel)
  let import_pkg = if @sys.is_file(@sys.join(src_dir, "moon.pkg")) {
    name
  } else {
    let candidates : Array[(String, Bool)] = []
    if @sys.is_dir(src_dir) {
      let entries = @sys.list_dir(src_dir)
      entries.sort_by(fn(a, b) { @rjson.str_cmp(a, b) })
      for e in entries {
        let p = @sys.join(src_dir, e)
        let pkg_file = @sys.join(p, "moon.pkg")
        if @sys.is_dir(p) && @sys.is_file(pkg_file) {
          let is_main = match @sys.read_text(pkg_file) {
            Some(t) => pkg_is_main(t)
            None => false
          }
          candidates.push((e, is_main))
        }
      }
    }
    pick_ui_subpkg(name, candidates)
  }
  Ok({ path: abs_ui, name, version, import_pkg })
}

///|
fn derive_mod_name(app_id : String, name : String) -> String {
  let base = match app_id.rev_find(".") {
    Some(i) if i + 1 < app_id.length() => app_id.exact_view(start=i + 1).to_owned()
    _ => name
  }
  let sb = StringBuilder()
  for c in base {
    if c >= 'a' && c <= 'z' {
      sb.write_char(c)
    } else if c >= 'A' && c <= 'Z' {
      sb.write_char(Int::unsafe_to_char(c.to_int() + 32))
    } else if c >= '0' && c <= '9' {
      if sb.to_string().length() > 0 {
        sb.write_char(c)
      }
    } else if c == '_' || c == '-' || c == ' ' {
      if sb.to_string().length() > 0 {
        sb.write_char('_')
      }
    }
  }
  let s = sb.to_string().trim(chars="_").to_owned()
  if s.length() == 0 {
    "my_app"
  } else {
    s
  }
}

///|
fn escape_mbt_string(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    match c {
      '\\' => sb.write_string("\\\\")
      '"' => sb.write_string("\\\"")
      '\n' => sb.write_string("\\n")
      '\r' => sb.write_string("\\r")
      '\t' => sb.write_string("\\t")
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
pub fn render_init_moon_mod(
  mod_name : String,
  mbui_ver : String,
  ui_lib : UiLibRef?,
) -> String {
  let mod_sb = StringBuilder()
  mod_sb.write_string("name = \"\{mod_name}\"\n\n")
  mod_sb.write_string("version = \"0.1.0\"\n\n")
  mod_sb.write_string("source = \"src\"\n\n")
  mod_sb.write_string("preferred_target = \"native\"\n\n")
  mod_sb.write_string("warnings = \"@a-33-79-29\"\n\n")
  mod_sb.write_string("import {\n")
  mod_sb.write_string("  \"ui@\{mbui_ver}\",\n")
  match ui_lib {
    Some(ui) => mod_sb.write_string("  \"\{escape_mbt_string(ui.name)}@\{escape_mbt_string(ui.version)}\",\n")
    None => ()
  }
  mod_sb.write_string("}\n")
  mod_sb.to_string()
}

///|
pub fn render_init_moon_work(mbui_path : String, ui_lib : UiLibRef?) -> String {
  let work_sb = StringBuilder()
  work_sb.write_string("members = [\n")
  work_sb.write_string("  \".\",\n")
  work_sb.write_string("  \"\{escape_mbt_string(mbui_path)}\",\n")
  match ui_lib {
    Some(ui) => work_sb.write_string("  \"\{escape_mbt_string(ui.path)}\",\n")
    None => ()
  }
  work_sb.write_string("]\n")
  work_sb.to_string()
}

///|
pub fn render_init_app_pkg(ui_lib : UiLibRef?) -> String {
  let sb = StringBuilder()
  sb.write_string("import {\n")
  sb.write_string("  \"ui/host\",\n")
  sb.write_string("  \"ui/ui\",\n")
  sb.write_string("  \"ui/view\",\n")
  sb.write_string("  \"ui/wasmrt\",\n")
  match ui_lib {
    Some(ui) =>
      sb.write_string("  // Uncomment to use components from \{ui.name}:\n  // \"\{escape_mbt_string(ui.import_pkg)}\",\n")
    None => ()
  }
  sb.write_string("}\n\n")
  sb.write_string("options(\n")
  sb.write_string("  \"is-main\": true,\n")
  sb.write_string("  targets: { \"wasm_shell.mbt\": [ \"wasm\" ] },\n")
  sb.write_string("  link: {\n")
  sb.write_string("    \"js\": { \"format\": \"iife\" },\n")
  sb.write_string("    \"wasm\": { \"exports\": [\"mbw_string\", \"mbw_bytes\"], \"export-memory-name\": \"memory\" },\n")
  sb.write_string("    // macOS native link flags; mbui pack / linux.sh / win.sh rewrite or strip this for other OSes.\n")
  sb.write_string("    \"native\": {\n")
  sb.write_string(
    "      \"cc-link-flags\": \"-framework Cocoa -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics -framework ImageIO -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework WebKit\",\n",
  )
  sb.write_string("    },\n")
  sb.write_string("  },\n")
  sb.write_string(")\n")
  sb.to_string()
}

///|
pub fn render_init_main_mbt(name : String, ui_lib : UiLibRef?) -> String {
  let escaped_name = escape_mbt_string(name)
  let main_sb = StringBuilder()
  match ui_lib {
    Some(ui) =>
      main_sb.write_string(
        "// UI library wired in moon.mod & moon.work: \{ui.name}@\{ui.version} (import \"\{ui.import_pkg}\" in src/app/moon.pkg)\n\n",
      )
    None => ()
  }
  main_sb.write_string("///|\n")
  main_sb.write_string("fn main {\n")
  main_sb.write_string("  @ui.run_tree(\"\{escaped_name}\", fn(root) {\n")
  main_sb.write_string("    root\n")
  main_sb.write_string("    .grow(@view.Is(1.0))\n")
  main_sb.write_string("    .ground(@view.Is(0xF5F3EFFFL))\n")
  main_sb.write_string("    .pad(@view.Is(24.0))\n")
  main_sb.write_string("    .box(fn(card) {\n")
  main_sb.write_string("      card.words(@view.Is(\"Hello, \{escaped_name}!\"), ink=0x24272BFFL) |> ignore\n")
  main_sb.write_string("    })\n")
  main_sb.write_string("    |> ignore\n")
  main_sb.write_string("  })\n")
  main_sb.write_string("}\n")
  main_sb.to_string()
}

///|
pub fn render_init_next_steps(dir : String) -> String {
  let sb = StringBuilder()
  sb.write_string("Next steps:\n")
  sb.write_string("  cd \{dir}\n")
  sb.write_string("  moon check --target native\n")
  sb.write_string("  moon check --target js\n")
  sb.write_string("  mbui check mbui.json\n")
  sb.write_string("  mbui pack mbui.json --target web --out dist\n")
  sb.to_string()
}

///|
pub fn cmd_init(
  dir : String,
  name : String,
  app_id : String,
  mbui_path : String,
  ui_path : String?,
) -> Unit {
  if !is_valid_app_id(app_id) {
    die("invalid --id '\{app_id}': expected reverse-DNS identifier like dev.example.demo")
  }
  if name.trim(chars=" \t\r\n").length() == 0 {
    die("--name must not be empty")
  }
  let ui_lib : UiLibRef? = match ui_path {
    Some(p) =>
      match resolve_ui_lib(p) {
        Ok(u) => Some(u)
        Err(e) => {
          die("init --ui: \{e}")
          None
        }
      }
    None => None
  }
  let abs_mbui = @sys.abspath(mbui_path)
  let mbui_ver = match @sys.read_text(@sys.join(abs_mbui, "moon.mod")) {
    Some(t) => parse_moon_mod_field(t, "version").unwrap_or("0.1.0")
    None => "0.1.0"
  }
  let target = @sys.abspath(dir)
  @sys.makedirs(target)
  @sys.makedirs(@sys.join(target, "assets"))
  @sys.makedirs(@sys.join(target, "src/app"))

  let mod_name = derive_mod_name(app_id, name)
  let executable = derive_executable(name)

  // moon.mod
  match write_file_text(@sys.join(target, "moon.mod"), render_init_moon_mod(mod_name, mbui_ver, ui_lib)) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  // moon.work
  match write_file_text(@sys.join(target, "moon.work"), render_init_moon_work(abs_mbui, ui_lib)) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  // mbui.json
  let manifest_json : @rjson.Value = Obj([
    ("appId", Str(app_id)),
    ("name", Str(name)),
    ("executable", Str(executable)),
    ("version", Str("0.1.0")),
    ("build", Num("1")),
    ("entry", Str("src/app")),
    ("icon", Str("assets/icon.png")),
    (
      "web",
      Obj([
        ("title", Str(name)),
        ("themeColorLight", Str("#F5F3EF")),
        ("themeColorDark", Str("#1F2023")),
        ("brotli", Bool(true)),
        ("pwa", Bool(false)),
      ]),
    ),
    (
      "macos",
      Obj([
        ("minVersion", Str("13.0")),
        ("formats", Arr([Str("app"), Str("zip")])),
      ]),
    ),
  ])
  match
    write_file_text(
      @sys.join(target, "mbui.json"),
      @rjson.dumps(manifest_json, indent=2, ensure_ascii=false) + "\n",
    ) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  // assets/icon.png (256x256 placeholder PNG in pure MoonBit)
  let icon_pic = make_placeholder_icon(256)
  match write_file_bytes(@sys.join(target, "assets/icon.png"), @png.encode_png(icon_pic)) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  // src/app/moon.pkg
  match write_file_text(@sys.join(target, "src/app/moon.pkg"), render_init_app_pkg(ui_lib)) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  // src/app/wasm_shell.mbt (exported helpers for mbui's prebuilt Wasm runtime shell)
  let wasm_shell_src =
    #|///|
    #|pub fn mbw_string(n : Int) -> String {
    #|  @wasmrt.new_string(n)
    #|}
    #|
    #|///|
    #|pub fn mbw_bytes(n : Int) -> Bytes {
    #|  @wasmrt.new_bytes(n)
    #|}
    #|
  match write_file_text(@sys.join(target, "src/app/wasm_shell.mbt"), wasm_shell_src) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  // src/app/main.mbt
  match write_file_text(@sys.join(target, "src/app/main.mbt"), render_init_main_mbt(name, ui_lib)) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  say("initialized project '\{name}' (\{app_id}) at \{target}")
  @sys.out(render_init_next_steps(dir))
}
