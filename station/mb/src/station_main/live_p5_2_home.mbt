// The agents' side (P5-2): the agents' home as a part of the station (agenthome/module.ts `AgentHomeLive`): the station's
// own skills written into each workspace's home, what stations before this one linked into the profiles' homes taken
// away, and every home's transcripts put in each runtime's one shared place; at the start and again whenever the
// config changes, one round at a time.

///|
/// Where the station's own skills are (agent-home.ts `skillsSource`): a release's (`<app>/station/dist/skills`,
/// `<app>/station/skills`), else the checkout's (`station/src/skills`) above the program.
fn skills_source(app : String, argv0 : String) -> String? {
  let s = sep()
  let candidates = [path([app, "station", "dist", "skills"]), path([app, "station", "skills"]), path([app, "skills"])]
  let mut dir = @nodepath.dirname(s, attempt(() => @drive.realpath(argv0)).unwrap_or(argv0))
  for _ in 0..<6 {
    candidates.push(path([dir, "station", "src", "skills"]))
    candidates.push(path([dir, "src", "skills"]))
    dir = @nodepath.dirname(s, dir)
  }
  candidates.iter().find_first(c => attempt(() => @drive.stat(path([c, "stillfail-chats.md"]))) is Ok(_))
}

///|
/// One round of keeping the agents' home (`keep`, `transcripts`).
async fn P52::keep_agent_home(self : P52) -> Unit {
  let raw = (self.bus.config_raw.val)()
  let storage = self.storage()
  let home = self.agent_home()
  let profiles = self.profiles().map(p => ({
    id: jtext(p, "id").unwrap_or(""),
    runtimes: @session_hub.profile_runtimes(p),
    home: jtext(p, "home").unwrap_or(""),
  } : @session_storage.ProfileHome))
  // (stillfail-feedback goes with feedback_send on the stable channel of still.fail cloud; stillfail-move where
  // moving is on here)
  let feedback = station_channel(raw, self.bus.app) == "stable" &&
    (match (self.bus.cloud_state.val)() {
      Some(st) => jtext(st, "origin").unwrap_or("").contains("still.fail")
      None => false
    })
  let move_on = station_feature("stationMove", raw, self.bus.app)
  let site = match env_get("STILLFAIL_SITE_SKILLS") {
    Some(d) if d != "" => Some(d)
    _ => None
  }
  match skills_source(self.bus.app, self.bus.argv0) {
    Some(source) => {
      let homes = self.files.agent_homes(home) catch { _ => [home] }
      for h in homes {
        storage.write_builtin_skills(h, feedback, source, site, move=move_on) catch {
          e => slice_log("warn", "agent_home", "the agents' home not kept", { "error": jstr(said_of(e)) })
        }
      }
    }
    None => slice_log("warn", "agent_home", "the station's own skills are not there to write", Json::object({}))
  }
  self.files.unlink_agent_home(home, profiles) catch {
    e => slice_log("warn", "agent_home", "the agents' home not kept", { "error": jstr(said_of(e)) })
  }
  storage.link_transcripts(self.data, profiles) catch {
    e => slice_log("warn", "agent_home", "the shared transcripts not linked", { "error": jstr(said_of(e)) })
  }
}

///|
/// The agents' home kept at the start and at each change of the config, one round at a time (a change while one runs
/// makes one more after it).
fn P52::agent_home_live(self : P52) -> Unit {
  let running = Ref(false)
  let again = Ref(false)
  let round = async fn() {
    if running.val {
      again.val = true
      return
    }
    running.val = true
    while true {
      again.val = false
      self.keep_agent_home()
      if !again.val || self.closed {
        break
      }
    }
    running.val = false
  }
  ignore(self.host.rt.fork_daemon("agents' home", on_error=e => @host.note("agents' home failed: \{e}"), round))
  ignore((self.bus.config_listen.val)(_ => ignore(self.host.rt.fork_daemon("agents' home", on_error=e => @host.note("agents' home failed: \{e}"), round))))
}
