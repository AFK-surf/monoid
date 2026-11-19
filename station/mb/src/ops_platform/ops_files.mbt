// station/src/ops/files.ts and log.ts: where the data directory is, the command line's words, the ports a listener
// tries, a log line as the station writes it.

///|
/// files.ts `dataDir`: `--data`, else $STILLFAIL_DATA, else ~/.stillfail.
pub fn data_dir(args : Array[String], env_data : String?, home : String) -> String {
  match args.search_by(a => a == "--data") {
    Some(i) =>
      match args.get(i + 1) {
        Some(d) if d != "" => return d
        _ => ()
      }
    None => ()
  }
  match env_data {
    Some(d) if d != "" => d
    _ => posix_join([home, ".stillfail"])
  }
}

///|
/// files.ts `ownData`: whether `data` is the machine's own data directory.
pub fn own_data(p : Plat, data : String, home : String, join : (Array[String]) -> String) -> Bool {
  path_key(p, clean_path(p, join([home, ".stillfail"]))) == path_key(p, clean_path(p, data))
}

///|
/// files.ts `rememberedMcpPort`: from run/mcp.json's text.
pub fn remembered_mcp_port(text : String?) -> Double? {
  guard text is Some(t) else { return None }
  match js_parse(t) {
    Some(Object(_) as j) =>
      match num_field(j, "port") {
        Some(p) if is_integer(p) && p > 0.0 && p < 65536.0 => Some(p)
        _ => None
      }
    _ => None
  }
}

///|
/// files.ts `portsToTry`.
pub fn ports_to_try(named : Double?, remembered : Double?, usual : Double, own : Bool) -> Array[Double] {
  match named {
    Some(n) => return [n]
    None => ()
  }
  let out = []
  for p in [remembered, if own { Some(usual) } else { None }, Some(0.0)] {
    match p {
      Some(v) if !out.contains(v) => out.push(v)
      _ => ()
    }
  }
  out
}

///|
/// files.ts `isFlag`: `/^--[a-z][a-z-]{0,23}$/`.
fn is_flag(a : String) -> Bool {
  a.length() >= 3 &&
  a.length() <= 26 &&
  starts(a, "--") &&
  is_lower(cu(a, 2)) &&
  all_units(sub(a, 3, a.length()), c => is_lower(c) || c == 45)
}

///|
/// files.ts `positionals`.
pub fn positionals(args : Array[String], valued : Array[String]) -> Array[String] {
  let out = []
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    if a == "--" {
      out.push_iter(args[i + 1:].iter())
      break
    }
    if !is_flag(a) {
      out.push(a)
    } else if valued.contains(a) {
      i += 1
    }
    i += 1
  }
  out
}

///|
/// files.ts `unreadableDirMessage`: the words for an agent's directory the station may not list.
pub fn unreadable_dir_message(
  catalog : Catalog,
  lang : String,
  dir : String,
  argv : Array[String],
  folder_permissions : Bool,
  join : (Array[String]) -> String,
) -> String {
  if !folder_permissions {
    return tr(catalog, lang, "station.session.cwdDenied", { "cwd": js(dir) })
  }
  let app = flag(argv, "--app")
  let program = match app {
    Some(a) if a != "" && !argv.contains("--with-parent") => join([a, "mesh", "target", "release", "stillfail-station"])
    _ => "still.fail"
  }
  tr(catalog, lang, "station.session.cwdDeniedMac", { "cwd": js(dir), "program": js(program) })
}

///|
/// files.ts `nowSecs`.
pub fn now_secs(now : Double) -> Double {
  (now / 1000.0).floor()
}

///|
/// json-file.ts `InvalidJsonFile`'s words.
pub fn invalid_json_message(catalog : Catalog, lang : String, path : String, program : String) -> String {
  tr(catalog, lang, "station.files.invalidJson", { "path": js(path), "program": js(program) })
}

// ── log.ts ───────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// `new Date(ms).toISOString()`.
pub fn iso_time(ms : Double) -> String {
  @time.format_iso_ms(ms.floor().to_int64())
}

///|
/// log.ts `line`: what goes to stderr, its fields in their order.
pub fn log_line(now : Double, level : String, at : String, message : String, fields : Json?) -> String {
  let rest = match fields {
    Some(Object(m)) => {
      let b = StringBuilder()
      for k, v in m {
        b.write_string(" " + k + "=")
        b.write_string(
          match v {
            String(s) => s
            _ => js_stringify(v)
          },
        )
      }
      b.to_string()
    }
    _ => ""
  }
  "\{iso_time(now)} \{level.pad_start(5, ' ')} \{at}: \{message}\{rest}\n"
}

///|
/// log.ts `errorLine`: what the error reports hear of an error line: its message with its fields but `error`, and its
/// `error`.
pub fn error_heard(message : String, fields : Json?) -> (String, String?) {
  let others = []
  let mut error : String? = None
  match fields {
    Some(Object(m)) =>
      for k, v in m {
        if k == "error" {
          error = Some(arg_text(v))
          continue
        }
        others.push(
          k +
          "=" +
          (match v {
            String(s) => s
            _ => js_stringify(v)
          }),
        )
      }
    _ => ()
  }
  (if others.is_empty() { message } else { message + " (" + others.join(", ") + ")" }, error)
}
