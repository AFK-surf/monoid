// A new profile's draft on a station, as the core's add flow has it (`profileFlow`; its page sfpages new_profile.mbt):
// opened, a plan's sign-in started and let go.

///|
/// The new-profile pages open, by station: the draft's form, the sign-in it started (none: ""), why that failed.
pub(all) struct NewProfile {
  form : String
  mut dropped : Bool
  login : @signals.Signal[String]
  mut asked : Bool
  error : @signals.Signal[String]
}

///|
let new_profiles : Map[String, NewProfile] = Map([])

///|
/// A count of drafts opened.
pub let profile_forms : Ref[Int] = Ref(0)

///|
/// The draft of a new profile's page on `station`, opened (`profile.flow.open`) as it is first made, `start` told it at
/// once (where the page begins: a provider and how, come from elsewhere); the one open there till it is left after.
pub fn new_profile_opened(core : Core, station : String, start : Array[(String, Json)]?) -> NewProfile {
  // (what is let go of as the page is left: this core's draft)
  left_core.val = Some(core)
  match new_profiles.get(station) {
    Some(n) if !n.dropped => n
    _ => {
      profile_forms.val += 1
      let n = {
        form: "mbui-profile-" + profile_forms.val.to_string(),
        dropped: false,
        login: @signals.signal(""),
        asked: false,
        error: @signals.signal(""),
      }
      new_profiles[station] = n
      act(core, tr("web-pages.addProfile.openAction"), "profile.flow.open", obj([("station", str(station)), ("form", str(n.form))]))
      match start {
        Some(input) =>
          act(
            core,
            tr("web-pages.addProfile.editAction"),
            "profile.flow.edit",
            obj([("station", str(station)), ("form", str(n.form)), ("input", obj(input))]),
          )
        None => ()
      }
      n
    }
  }
}

///|
/// The page left: its draft dropped (`profile.flow.drop`), and a sign-in it started that made no profile let go
/// (`login.drop`: nothing left behind).
fn new_profile_left(core : Core, station : String) -> Unit {
  match new_profiles.get(station) {
    Some(n) if !n.dropped => {
      n.dropped = true
      drop_login(core, station, n)
      (core.call)("profile.flow.drop", obj([("station", str(station)), ("form", str(n.form))]), answer_unread)
    }
    _ => ()
  }
}

///|
/// The sign-in a new profile's page started let go, unless it made its profile.
pub fn drop_login(core : Core, station : String, n : NewProfile) -> Unit {
  if n.login.get() != "" {
    let made = match pending_login(core, station, n.login.get()) {
      Some(l) => has(Some(l), "created")
      None => false
    }
    if !made {
      (core.call)("login.drop", obj([("station", str(station)), ("id", str(n.login.get()))]), answer_unread)
    }
    n.login.set("")
  }
  n.asked = false
}

///|
/// A sign-in under way on a station, by its id (its overview's `logins`, that part alone).
pub fn pending_login(core : Core, station : String, id : String) -> Json? {
  match station_part_in(core, workspace_of(station), station, "logins") {
    Some(Array(a)) => a.iter().find_first(fn(l) { text(Some(l), "id") == id })
    _ => None
  }
}

///|
/// A plan's sign-in started for the page (`login.new` with what it signs in to).
pub fn start_login(
  core : Core,
  station : String,
  n : NewProfile,
  runtime : String,
  access : String,
  service? : String = "",
) -> Unit {
  n.asked = true
  n.error.set("")
  let p = [("station", str(station))]
  if service != "" {
    p.push(("service", str(service)))
  } else {
    p.push(("runtime", str(runtime)))
  }
  if access != "" {
    p.push(("access", str(access)))
  }
  (core.call)("login.new", obj(p), fn(r) {
    match r {
      Ok(v) =>
        n.login.set(match v {
          String(id) => id
          _ => text(Some(v), "id")
        })
      Err(e) => n.error.set(error_text(e))
    }
  })
}

