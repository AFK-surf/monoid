// replace.ts: local station replacement helpers for MoonBit `stillfail-station update --replace-*`.

///|
fn multi_flag(args : Array[String], name : String) -> Array[String] {
  let out : Array[String] = []
  let mut i = 0
  while i + 1 < args.length() {
    if args[i] == name {
      out.push(args[i + 1])
    }
    i += 1
  }
  out
}

///|
/// Sends `{ wait }` to a running station via <run>/wait-ask + SIGHUP, or writes config.json directly when stopped
/// (or when `direct` is set, or when an older running station does not consume wait-ask).
pub async fn set_wait_config(
  w : World,
  data : String,
  wait : Array[WaitCondition]?,
  wait_ms : Double,
  direct? : Bool = false,
  app? : String? = None,
) -> Unit {
  let run_dir = pjoin([data, "run"])
  w.mkdir(run_dir)
  if !direct {
    let said = read_json(w, pjoin([run_dir, "station.json"]))
    let pid = match get(said, "pid") {
      Some(Num(p)) if is_safe_integer(Some(Num(p))) && p > 0.0 => Some(p)
      _ => None
    }
    let takes = match pid {
      None => false
      Some(p) =>
        get(said, "channel") is Some(Num(1.0)) &&
        alive(w, p) &&
        w.call("platform.isLauncher", [jn(p)]) is Bool(true)
    }
    if takes {
      let pid = pid.unwrap()
      let ask_path = pjoin([run_dir, wait_ask])
      let answer = pjoin([run_dir, wait_answer])
      w.rm(answer)
      let payload = match wait {
        None => jo([("wait", Null)])
        Some(conds) => jo([("wait", ja(conds.map(wait_condition_to_j)))])
      }
      write_whole(w, ask_path, "\{stringify(payload)}\n")
      ignore(w.call("platform.askLauncher", [jn(pid), js("hup")])) catch {
        e => {
          w.rm(ask_path)
          raise fail(
            tr(station_lang(), "station.cli.signalFailed", args=jo([("pid", jn(pid)), ("error", js(message_of(e)))])),
          )
        }
      }
      match answer_in(w, answer, wait_ms) {
        Some(t) => {
          w.rm(answer)
          let t = trim(t)
          if starts_with(t, "ok") {
            return
          }
          raise fail(if starts_with(t, "error ") { slice(t, 6) } else { t })
        }
        None => ()
      }
      // If wait-ask is still on disk after timeout, the running station is an older release that does not
      // handle wait-ask: clean up and fall back to writing config.json directly.
      if w.exists(ask_path) {
        w.rm(ask_path)
      } else {
        raise fail(tr(station_lang(), "station.cli.noAnswer"))
      }
    }
  }
  let ov = read_override(w, app.unwrap_or(pjoin([data, "app"])))
  ignore(w.call("ConfigFile.new", [js(data)]))
  let raw = w.call("ConfigFile.raw", [js(data)])
  let existing = parse_auto_update_when(raw)
  let mut next = raw
  match wait {
    None =>
      match existing {
        None => ()
        Some(ex) => {
          next = del(next, "autoUpdateWhen")
          if ov is None && ex.restore_auto {
            next = set(next, "autoUpdate", jb(true))
          }
        }
      }
    Some(conds) => {
      let restore_auto = match existing {
        Some(ex) => ex.restore_auto
        None => get(Some(raw), "autoUpdate") is Some(Bool(true))
      }
      let aw : AutoUpdateWhen = {
        wait: conds,
        restore_auto,
        for_override: ov is Some(_),
        set_at: Some((w.clock.now)()),
      }
      next = set(next, "autoUpdate", jb(false))
      next = set(next, "autoUpdateWhen", auto_update_when_to_j(aw))
    }
  }
  ignore(w.call("ConfigFile.update", [js(data), next]))
}

///|
async fn copy_tree(w : World, from : String, to : String) -> Unit {
  let st = w.lstat(from)
  if st.symlink {
    let target = w.readlink(from)
    w.symlink(target, to)
    return
  }
  if st.dir {
    w.mkdir(to)
    for name in w.readdir(from) {
      copy_tree(w, pjoin([from, name]), pjoin([to, name]))
    }
    return
  }
  w.write_bytes(to, w.read_bytes(from))
}

///|
async fn validate_bundle(w : World, dir : String) -> Unit {
  let has_bin = w.exists(pjoin([dir, "bin", "stillfail"])) || w.exists(pjoin([dir, "bin", "stillfail.ps1"]))
  let has_station = w.exists(pjoin([dir, "station", "main.js"])) ||
    w.exists(pjoin([dir, "station", "stillfail-reader"])) ||
    w.exists(pjoin([dir, "station", "stillfail-reader.exe"]))
  if !has_bin || !has_station {
    raise fail("invalid station bundle in \{dir} (missing bin/stillfail or station runtime)")
  }
}

///|
pub async fn replace_subcommand(w : World, args : Array[String], data : String) -> Int {
  try {
    if args.contains("--replace-prepare") {
      let app = flag(args, "--app").unwrap_or(pjoin([data, "app"]))
      guard flag(args, "--stage") is Some(stage) && stage != "" else { return 2 }
      let source = flag(args, "--source")
      let dist = flag(args, "--dist")
      let main_f = flag(args, "--main")
      let reader_f = flag(args, "--reader")
      let note = flag(args, "--note")
      let is_overlay = dist is Some(_) || main_f is Some(_) || reader_f is Some(_)
      if source is Some(_) && is_overlay {
        raise fail("cannot combine <source> bundle with --dist/--main/--reader overlay")
      }
      if source is None && !is_overlay {
        raise fail("give a bundle <source> or one of --dist, --main, --reader")
      }
      let existing_ov = read_override(w, app)
      let (base_version, base_build, base_commit) = match existing_ov {
        Some(o) => (o.base_version, o.base_build, o.base_commit)
        None => {
          let v = station_version_soon(w, app)
          let b = build_or_none(v)
          let c = match w.read_text_or_null(pjoin([app, "VERSION"])) {
            Some(t) if trim(t) != "" => Some(trim(t))
            _ => None
          }
          (v, b, c)
        }
      }
      w.rm_quiet(stage, recursive=true)
      match source {
        Some(src) => {
          let st = w.stat(src)
          let bundle_dir = if st.dir {
            let nested = pjoin([src, "stillfail"])
            if w.exists(pjoin([nested, "bin"])) || w.exists(pjoin([nested, "station"])) {
              nested
            } else {
              src
            }
          } else {
            let tmp = text(Some(w.call("os.tmpdir", []))).unwrap_or("/tmp")
            let scratch = pjoin([tmp, "stillfail-replace-extract-\{own_pid.val}"])
            w.rm_quiet(scratch, recursive=true)
            w.mkdir(scratch)
            let (ok, out) = if ends_with(src, ".tar.gz") || ends_with(src, ".tgz") {
              run(w, "tar", ["-xzf", src, "-C", scratch], [], 120000.0)
            } else if ends_with(src, ".zip") {
              run(w, "unzip", ["-q", src, "-d", scratch], [], 120000.0)
            } else {
              raise fail("unsupported bundle format: \{src}")
            }
            if !ok {
              w.rm_quiet(scratch, recursive=true)
              raise fail("failed to extract \{src}: \{out}")
            }
            let nested = pjoin([scratch, "stillfail"])
            if w.exists(nested) { nested } else { scratch }
          }
          validate_bundle(w, bundle_dir)
          copy_tree(w, bundle_dir, stage)
          if !w.exists(pjoin([stage, "CHANNEL"])) && w.exists(pjoin([app, "CHANNEL"])) {
            w.write_bytes(pjoin([stage, "CHANNEL"]), w.read_bytes(pjoin([app, "CHANNEL"])))
          }
          if w.exists(pjoin([stage, "NODE_VERSION"])) && !w.exists(pjoin([stage, "node"])) {
            let nv = trim(w.read_text_or_null(pjoin([stage, "NODE_VERSION"])).unwrap_or(""))
            let nd = pjoin([data, "node", "v\{nv}"])
            if nv != "" && w.exists(nd) {
              w.symlink(nd, pjoin([stage, "node"]))
            } else if w.exists(pjoin([app, "node"])) {
              copy_tree(w, pjoin([app, "node"]), pjoin([stage, "node"]))
            }
          }
        }
        None => {
          if !w.exists(app) {
            raise fail("installed app not found at \{app}")
          }
          copy_tree(w, app, stage)
          w.mkdir(pjoin([stage, "station"]))
          match dist {
            Some(d) => copy_tree(w, d, pjoin([stage, "station"]))
            None => ()
          }
          match main_f {
            Some(m) => w.write_bytes(pjoin([stage, "station", "main.js"]), w.read_bytes(m))
            None => ()
          }
          match reader_f {
            Some(r) => {
              let rname = if machine.val.installer_ext == "ps1" { "stillfail-reader.exe" } else { "stillfail-reader" }
              w.write_bytes(pjoin([stage, "station", rname]), w.read_bytes(r))
            }
            None => ()
          }
          validate_bundle(w, stage)
        }
      }
      let kind = if is_overlay { "overlay" } else { "bundle" }
      let fields : Array[(String, J)] = [
        ("baseVersion", jopt(base_version)),
        ("baseBuild", match base_build { Some(b) => jn(b); None => Null }),
        ("baseCommit", jopt(base_commit)),
        ("kind", js(kind)),
        ("replacedAt", jn((w.clock.now)())),
      ]
      match note {
        Some(n) if trim(n) != "" => fields.push(("note", js(trim(n))))
        _ => ()
      }
      w.write_file(pjoin([stage, "OVERRIDE"]), "\{stringify(jo(fields))}\n")
      w.now("console.log", [js("kind=\{kind}")])
      match base_version {
        Some(v) => w.now("console.log", [js("baseVersion=\{v}")])
        None => ()
      }
      return 0
    }
    if args.contains("--replace-wait") {
      let clear = args.contains("--clear")
      let hold = args.contains("--hold")
      let direct = args.contains("--direct")
      let app = flag(args, "--app")
      let specs = multi_flag(args, "--until")
      if clear && (specs.length() > 0 || hold) {
        raise fail("--clear cannot be combined with --until or --hold")
      }
      if clear {
        set_wait_config(w, data, None, 2000.0, direct~, app~)
      } else if specs.length() > 0 {
        let parsed : Array[WaitCondition] = []
        for s in specs {
          parsed.push(parse_wait_spec(s))
        }
        set_wait_config(w, data, Some(parsed), 2000.0, direct~, app~)
      } else if hold {
        set_wait_config(w, data, Some([]), 2000.0, direct~, app~)
      } else {
        return 2
      }
      return 0
    }
    if args.contains("--replace-status") {
      let app = flag(args, "--app").unwrap_or(pjoin([data, "app"]))
      let lang = station_lang()
      let ov = read_override(w, app)
      let raw = read_json(w, config_path(data)).unwrap_or(jo([]))
      let when = parse_auto_update_when(raw)
      let has_backup = w.exists(pjoin([data, "app.before-replace"]))
      let lines : Array[String] = []
      match ov {
        Some(o) => {
          lines.push(tr(lang, "station.cli.status.override", args=jo([("kind", js(o.kind)), ("base", js(o.base_version.unwrap_or("?")))])))
          match o.note {
            Some(n) => lines.push(tr(lang, "station.cli.status.overrideNote", args=jo([("note", js(n))])))
            None => ()
          }
        }
        None => lines.push(tr(lang, "station.cli.replace.none"))
      }
      match when {
        Some(aw) if aw.wait.length() > 0 =>
          lines.push(tr(lang, "station.cli.status.autoWhen", args=jo([("conditions", js(aw.wait.map(format_wait_condition).join(", ")))])))
        _ =>
          if ov is Some(_) || (when is Some(aw) && aw.wait.length() == 0) {
            lines.push(tr(lang, "station.cli.status.autoHeld"))
          }
      }
      if has_backup {
        lines.push(tr(lang, "station.cli.replace.backup", args=jo([("path", js(pjoin([data, "app.before-replace"])))])))
      }
      w.now("console.log", [js(lines.join("\n"))])
      return 0
    }
    if args.contains("--replace-reconcile-revert") {
      let raw = read_json(w, config_path(data)).unwrap_or(jo([]))
      match parse_auto_update_when(raw) {
        Some(aw) if aw.for_override => set_wait_config(w, data, None, 2000.0)
        _ => ()
      }
      return 0
    }
    2
  } catch {
    e => {
      w.now("console.error", [js("Error: \{message_of(e)}")])
      1
    }
  }
}
