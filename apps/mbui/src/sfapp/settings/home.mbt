// The settings' pages from the gear, by route, and what this device chose of how still.fail shows (AppearanceScreen):
// its theme, its prefs as chosen here a moment ago. The settings' list itself (the gear's page on a small screen, the
// sidebar beside these pages on a wider one) is sfpages' (settings_list.mbt), drawn by the frame's setting_route.

///|
/// What a page of the settings is drawn in (and the desktop's own pages', src/sfdesk): its core, where it
/// stands, the sheet a fixture's mode puts up over it.
pub fn frame(core : Core, here : Here, root? : Bool = false, top? : Double = 0.0) -> Unit {
  frame_core.val = Some(core)
  at_root.val = root
  root_top.val = if root { top } else { 0.0 }
  left_core.val = Some(core)
  fixture_sheet(core, here)
}

///|
/// What was chosen here before the core's prefs say it (prefs.set on its way): by the pref's name.
let chosen : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
/// A pref as the core keeps it (the `prefs` topic), or as it was chosen here a moment ago.
pub fn pref(core : Core, name : String) -> String {
  pref_from((core.topic)("prefs", Map([])).get().value, name)
}

///|
/// The same preference before a workspace exists, as the core's topic and a choice already made here say it.
pub fn pref_from(prefs : Json?, name : String) -> String {
  let kept = text(prefs, name)
  match chosen.get(name) {
    Some(v) => {
      // the core has it now: what it keeps from here on (another device may change it)
      if v == kept {
        chosen.remove(name)
      }
      v
    }
    None => kept
  }
}

///|
/// A pref set (prefs.set), shown as chosen at once; "" takes it away (null: the default).
pub fn set_pref(core : Core, name : String, value : String) -> Unit {
  set_pref_with(core.call, core.say, name, value)
}

///|
/// Set a preference through the core's call and toast, also when no workspace has been opened yet.
pub fn set_pref_with(
  call : (String, Json, (Result[Json, Json]) -> Unit) -> Unit,
  say : (String) -> Unit,
  name : String,
  value : String,
) -> Unit {
  chosen[name] = value
  call(
    "prefs.set",
    obj([(name, if value == "" { Json::null() } else { str(value) })]),
    fn(r) {
      match r {
        Ok(_) => ()
        Err(e) => {
          chosen.remove(name)
          say(fill("android-misc.act.failed", [("what", tr("android-settings.appearance.title")), ("error", error_text(e))]))
        }
      }
    },
  )
}

///|
/// The theme chosen on this device: "system", "light" or "dark" (the prefs' `appearance`; the system's when none),
/// as chosen here before the core has it.
pub fn appearance(prefs : Json?) -> String {
  let kept = text(prefs, "appearance")
  let v = match chosen.get("appearance") {
    Some(v) => {
      if v == kept {
        chosen.remove("appearance")
      }
      v
    }
    None => kept
  }
  match v {
    "light" | "dark" => v
    _ => "system"
  }
}

///|
/// Whether the app is drawn dark: the theme chosen, or the system's (`system_dark`) when it follows it.
pub fn dark(prefs : Json?, system_dark : Bool) -> Bool {
  match appearance(prefs) {
    "dark" => true
    "light" => false
    _ => system_dark
  }
}

///|
/// still.fail's terms or privacy policy on the web (the app speaks Chinese: no /en).
pub fn legal_url(page : String) -> String {
  "https://still.fail/" + page
}

///|
/// Notifications as switched here, until the core has answered (AppState.useNotify's `notify` meanwhile).
pub let notify_switched : @signals.Signal[Bool?] = @signals.signal(None)

///|
/// Notifications turned on or off on this device (AppState.useNotify): turned on, the system
/// asked to allow them too; the core keeps it (`notify.set`), taking this device's pushes off the accounts when off,
/// and the push registration follows what it answers (Push.sync). Not done: said in a toast, the switch back.
pub fn use_notify(core : Core, on : Bool) -> Unit {
  if on {
    (core.notify_ask)()
  }
  notify_switched.set(Some(on))
  (core.call)("notify.set", obj([("on", Json::boolean(on))]), fn(r) {
    notify_switched.set(None)
    match r {
      Ok(v) =>
        (core.push_sync)(
          match field(Some(v), "push") {
            Some(True) => Some(true)
            Some(False) => Some(false)
            _ => None
          },
        )
      Err(e) => {
        (core.say)(
          fill(
            if on {
              "android-misc.notify.onFailed"
            } else {
              "android-misc.notify.offFailed"
            },
            [("error", error_text(e))],
          ),
        )
        (core.push_sync)(None)
      }
    }
  })
}

///|
/// This build's version, as the version row says it after the app's name (SettingsHome.kt Version: its versionName,
/// 0.1.<build>): the build where the host knows it (Android's version code), the line alone where it does not.
pub fn build_version() -> String {
  let v = @ui.app_version()
  if v > 0 {
    "0.1." + v.to_string()
  } else {
    "0.1"
  }
}
