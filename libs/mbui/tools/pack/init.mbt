// Project scaffolding: `mbui init <dir> [--name NAME] [--id APP_ID] [--mbui PATH]`.

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
pub fn cmd_init(
  dir : String,
  name : String,
  app_id : String,
  mbui_path : String,
) -> Unit {
  if !is_valid_app_id(app_id) {
    die("invalid --id '\{app_id}': expected reverse-DNS identifier like dev.example.demo")
  }
  if name.trim(chars=" \t\r\n").length() == 0 {
    die("--name must not be empty")
  }
  let target = @sys.abspath(dir)
  @sys.makedirs(target)
  @sys.makedirs(@sys.join(target, "assets"))
  @sys.makedirs(@sys.join(target, "src/app"))

  let mod_name = derive_mod_name(app_id, name)
  let executable = derive_executable(name)

  // moon.mod
  let mod_sb = StringBuilder()
  mod_sb.write_string("name = \"\{mod_name}\"\n\n")
  mod_sb.write_string("version = \"0.1.0\"\n\n")
  mod_sb.write_string("source = \"src\"\n\n")
  mod_sb.write_string("preferred_target = \"native\"\n\n")
  mod_sb.write_string("warnings = \"@a-33-79-29\"\n\n")
  mod_sb.write_string("import {\n")
  mod_sb.write_string("  \"mbui@0.1.0\",\n")
  mod_sb.write_string("}\n")
  match write_file_text(@sys.join(target, "moon.mod"), mod_sb.to_string()) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  // moon.work
  let work_sb = StringBuilder()
  work_sb.write_string("members = [\n")
  work_sb.write_string("  \".\",\n")
  work_sb.write_string("  \"\{escape_mbt_string(mbui_path)}\",\n")
  work_sb.write_string("]\n")
  match write_file_text(@sys.join(target, "moon.work"), work_sb.to_string()) {
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
  let app_pkg =
    #|import {
    #|  "mbui/host",
    #|  "mbui/ui",
    #|  "mbui/view",
    #|}
    #|
    #|options(
    #|  "is-main": true,
    #|  link: {
    #|    "js": { "format": "iife" },
    #|    "native": {
    #|      "cc-link-flags": "-framework Cocoa -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics -framework ImageIO -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework WebKit",
    #|    },
    #|  },
    #|)
    #|
  match write_file_text(@sys.join(target, "src/app/moon.pkg"), app_pkg) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  // src/app/main.mbt
  let escaped_name = escape_mbt_string(name)
  let main_sb = StringBuilder()
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
  match write_file_text(@sys.join(target, "src/app/main.mbt"), main_sb.to_string()) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  say("initialized project '\{name}' (\{app_id}) at \{target}")
}
