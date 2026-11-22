// The apps' accessibility trees on the desktop (src/screens/ui.ts, "Agents on a screen"): agent-desktop
// (vercel-labs/agent-desktop, Apache-2.0) reads an app's window as a tree of elements, each acted on by its ref through
// the accessibility API. It runs where the desktop's apps are: on macOS in still.fail Helper (its `ui` op), on Windows
// started by the station itself. Each call is one command and its one JSON envelope (`{ok, data}` or `{ok: false,
// error: {code, message, suggestion, disposition}}`); its trees are put here as text an agent reads at a glance.

///|
pub const UI_BINARY : String = "agent-desktop.exe"

///|
/// A command longer than this is ended (agent-desktop's own waits are shorter).
pub const UI_LIMIT_MS : Double = 60000

///|
/// Where agent-desktop was found, by its override (STILLFAIL_AGENT_DESKTOP): looked for again only where it was not.
let ui_found : Map[String, String] = Map::new()

///|
/// The release's agent-desktop on Windows: STILLFAIL_AGENT_DESKTOP, or beside the station's code.
pub fn ui_binary(io : Io, env : Env) -> String? {
  let key = env.get("STILLFAIL_AGENT_DESKTOP").unwrap_or("")
  match ui_found.get(key) {
    Some(kept) => return Some(kept)
    None => ()
  }
  let candidates = [env.get("STILLFAIL_AGENT_DESKTOP"), Some(pj([io.os.code_dir, UI_BINARY]))]
  let mut found = None
  for p in candidates {
    match p {
      Some(p) if p != "" && (io.fs.exists_sync)(p) => {
        found = Some(p)
        break
      }
      _ => ()
    }
  }
  match found {
    Some(f) => ui_found[key] = f
    None => ()
  }
  found
}

///|
/// An envelope from what agent-desktop printed: an error envelope when it printed none.
pub fn envelope(out : String, status : Double) -> J {
  parse(out) catch {
    _ =>
      jo([
        ("ok", jb(false)),
        ("error", jo([("code", js("INTERNAL")), ("message", js("agent-desktop printed no answer (exit status \{num_text(status)})"))])),
      ])
  }
}

///|
/// agent-desktop in still.fail Helper (macOS).
pub fn helper_ui(helper : HelperApp) -> async (Array[String]) -> J {
  async fn(args) {
    let answer = helper.request(jo([("op", js("ui")), ("args", jstrs(args))]))
    let out = match get(Some(answer), "out") {
      Some(Str(_) as s) => text(Some(s)).unwrap_or("")
      _ => ""
    }
    envelope(out, js_number_of(get(Some(answer), "status")))
  }
}

///|
/// agent-desktop started by the station (Windows).
pub fn process_ui(io : Io, binary : String) -> async (Array[String]) -> J {
  async fn(args) {
    let done : @effect.Deferred[J] = @effect.Deferred::new()
    let out = Buffer()
    let unarm : Ref[() -> Unit] = Ref(() => ())
    let child = (io.procs.spawn)(
      binary,
      args,
      { env: None, group: false, verbatim: false, stdio: ("ignore", "pipe", "ignore") },
      {
        out: b => out.write_bytes(b),
        err: _ => (),
        error: e => {
          (unarm.val)()
          ignore(done.fail(fail(e)))
        },
        close: (code, _) => {
          (unarm.val)()
          ignore(done.succeed(envelope(@utf8.decode_lossy(out.to_bytes()), code.unwrap_or(-1).to_double())))
        },
      },
    )
    unarm.val = (io.clock.after)(UI_LIMIT_MS, () => (child.kill)("SIGTERM"))
    done.wait()
  }
}

///|
/// A tree as text: a line an element, indented by depth; unnamed containers without a ref leave no line (their
/// children go one level up), nor does a text without a ref saying its parent's name again.
/// `e12 button "Save" = "…" [disabled]`; a ref is its number in the tree's snapshot.
pub fn tree_text(tree : J) -> String {
  let lines = []
  fn cut(s : String) -> String {
    if units_len(s) > 200 {
      slice_units(s, 0, 200) + "…"
    } else {
      s
    }
  }
  fn walk(n : J, depth : Int, parent : String) -> Unit {
    let ref_ = match get(Some(n), "ref_id") {
      Some(Str(u)) if u.length() > 0 => {
        let s = @jsjson.sanitize_str(u)
        let at = match s.rev_find(":") {
          Some(i) => i + 1
          None => 0
        }
        s.unsafe_substring(start=at, end=s.length())
      }
      _ => ""
    }
    let name = match get(Some(n), "name") {
      Some(Str(_) as s) => trim_js(text(Some(s)).unwrap_or(""))
      _ => ""
    }
    let children = arr(get(Some(n), "children")).unwrap_or([])
    // A value that is its name again (a text's) says nothing more.
    let value = get(Some(n), "value")
    let valued = match value {
      None | Some(Null) => false
      Some(Str(u)) if u.length() == 0 => false
      Some(v) => trim_js(js_string(v)) != name
    }
    let shown = ref_ != "" || (name != "" && (name != parent || valued || children.length() > 0)) || valued
    if shown {
      let parts = [
        ref_,
        match get(Some(n), "role") {
          None | Some(Null) => ""
          Some(r) => js_string(r)
        },
      ]
      if name != "" {
        parts.push(stringify(js(cut(name))))
      }
      if valued {
        parts.push("= " + stringify(js(cut(js_string(value.unwrap())))))
      }
      match get(Some(n), "states") {
        Some(Arr(xs)) if xs.length() > 0 =>
          parts.push("[" + xs.map(x => if x is Null { "" } else { js_string(x) }).join(", ") + "]")
        _ => ()
      }
      match get(Some(n), "children_count") {
        Some(Num(c)) if children.length() == 0 => parts.push("(\{num_text(c)} inside)")
        _ => ()
      }
      let indent = StringBuilder()
      for _ in 0..<depth {
        indent.write_string("  ")
      }
      lines.push(indent.to_string() + parts.filter(p => p != "").join(" "))
    }
    for c in children {
      walk(c, if shown { depth + 1 } else { depth }, if name != "" { name } else { parent })
    }
  }

  walk(tree, 0, "")
  lines.join("\n")
}
