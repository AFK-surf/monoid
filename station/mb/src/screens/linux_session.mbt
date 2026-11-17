// A station can start before its user's desktop and inherit an old DISPLAY (src/screens/linux-session.ts). Look up
// that same user's active graphical session when logind is available; never borrow another user's session or X11
// credentials.

///|
pub(all) struct Session {
  id : String
  uid : Int
  type_ : String
  active : Bool
  remote : Bool
  display : String?
}

///|
pub fn Session::to_j(self : Session) -> J {
  jsome([
    ("id", Some(js(self.id))),
    ("uid", Some(ji(self.uid))),
    ("type", Some(js(self.type_))),
    ("active", Some(jb(self.active))),
    ("remote", Some(jb(self.remote))),
    ("display", self.display.map(js)),
  ])
}

///|
/// `KEY=value` lines as an object (a name said again, its last value).
fn fields_of(t : String) -> Map[String, String] {
  let out : Map[String, String] = Map::new()
  for l in t.split("\n") {
    let line = l.to_string()
    match line.find("=") {
      Some(i) if i > 0 => out[line.unsafe_substring(start=0, end=i)] = line.unsafe_substring(start=i + 1, end=line.length())
      _ => ()
    }
  }
  out
}

///|
pub fn graphical_session(id : String, uid : Int, t : String) -> Session? {
  let p = fields_of(t)
  let user = js_number(p.get("User").unwrap_or("undefined"))
  let kind = p.get("Type")
  if user != uid.to_double() || p.get("Class") != Some("user") || (kind != Some("x11") && kind != Some("wayland")) {
    return None
  }
  Some({
    id,
    uid,
    type_: kind.unwrap(),
    active: p.get("Active") == Some("yes"),
    remote: p.get("Remote") == Some("yes"),
    display: match p.get("Display") {
      Some(d) if d != "" => Some(d)
      _ => None
    },
  })
}

///|
/// A line of `loginctl list-sessions` as `/^\s*(\S+)\s+(\d+)\s+/` reads it: its session and its user.
fn session_line(line : String) -> (String, String)? {
  let r = Reader::new(line, 0)
  r.spaces()
  let start = r.at
  while r.peek() is Some(c) && !is_js_space(c) {
    r.at += 1
  }
  if r.at == start {
    return None
  }
  let id = String::from_array(r.s[start:r.at])
  if !r.spaces1() {
    return None
  }
  guard r.digits() is Some(uid) else { return None }
  if !r.spaces1() {
    return None
  }
  Some((id, uid))
}

///|
/// The program environment selected by logind. A lack of an active graphical session leaves its inherited environment
/// intact.
pub async fn desktop_environment(io : Io, base : Env) -> Env {
  guard io.os.uid is Some(uid) else { return base.copy() }
  let run = async fn(file : String, args : Array[String], env : Env, max : Double?) -> String {
    (io.procs.exec)(file, args, ExecOptions::new(env=Some(env), timeout=Some(2000.0), max_buffer=max))
  }
  let there = async fn(path : String) { (io.fs.access)(path, 0) }
  try {
    let list = run("loginctl", ["list-sessions", "--no-legend", "--no-pager"], base, Some(256000.0))
    let ids = []
    for l in list.split("\n") {
      match session_line(l.to_string()) {
        Some((id, u)) if js_number(u) == uid.to_double() => ids.push(id)
        _ => ()
      }
    }
    let ids = if ids.length() > 20 { ids[0:20].to_array() } else { ids }
    let found = @effect.all(
      ids.map(id => async fn() {
        let said = run("loginctl", ["show-session", id, "--no-pager", "--property=User,Type,Class,Active,Remote,Display"], base, None) catch {
          _ => return None
        }
        graphical_session(id, uid, said)
      }),
    )
    let sessions = found.filter_map(s => s).filter(s => s.active)
    // (stable: local before remote)
    let locals = sessions.filter(s => !s.remote)
    let remote = sessions.filter(s => s.remote)
    let sorted = locals + remote
    guard sorted.length() > 0 else { return base.copy() }
    let session = sorted[0]
    let env = base.copy()
    env.set("XDG_SESSION_TYPE", session.type_)
    let runtime = "/run/user/\{uid}"
    if there(pj([runtime, "bus"])) {
      env.set("XDG_RUNTIME_DIR", runtime)
      env.set("DBUS_SESSION_BUS_ADDRESS", "unix:path=\{pj([runtime, "bus"])}")
    }
    if session.type_ == "wayland" {
      // The portal backend uses the desktop activation environment, not the station's inherited Wayland socket.
      env.delete("DISPLAY")
      env.delete("XAUTHORITY")
      try {
        let values = fields_of(run("systemctl", ["--user", "show-environment"], env, Some(256000.0)))
        match values.get("WAYLAND_DISPLAY") {
          Some(w) if w != "" => env.set("WAYLAND_DISPLAY", w)
          _ => ()
        }
      } catch {
        _ => ()
      }
      if env.truthy("WAYLAND_DISPLAY") is None {
        env.set("WAYLAND_DISPLAY", "wayland-0")
      }
      return env
    }
    env.delete("WAYLAND_DISPLAY")
    let take_session = () => match session.display {
      Some(d) if env.get("DISPLAY") != Some(d) => {
        env.set("DISPLAY", d)
        env.delete("XAUTHORITY")
      }
      _ => ()
    }
    // GNOME normally exports these into the user's systemd activation environment after login.
    try {
      let values = fields_of(run("systemctl", ["--user", "show-environment"], env, Some(256000.0)))
      match values.get("DISPLAY") {
        Some(d) if d != "" && (session.display is None || Some(d) == session.display) => {
          if env.get("DISPLAY") != Some(d) {
            env.delete("XAUTHORITY")
          }
          env.set("DISPLAY", d)
          match values.get("XAUTHORITY") {
            Some(x) if x != "" => env.set("XAUTHORITY", x)
            _ => ()
          }
        }
        _ => take_session()
      }
    } catch {
      _ => take_session()
    }
    if env.truthy("XAUTHORITY") is None {
      let candidates = [Some(pj([runtime, "gdm/Xauthority"])), base.truthy("HOME").map(h => pj([h, ".Xauthority"]))]
      for c in candidates {
        match c {
          Some(c) if c != "" && there(c) => {
            env.set("XAUTHORITY", c)
            break
          }
          _ => ()
        }
      }
    }
    env
  } catch {
    _ => base.copy()
  }
}
