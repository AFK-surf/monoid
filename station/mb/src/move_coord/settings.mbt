// The settings module (station/src/move/settings.ts; move/AGENTS.md): an item is one setting of config.json that is a
// person's choice (`SETTINGS`), `setting:<name>`. What the other station has already is not overwritten: a setting it
// lacks it takes; one it has the same is left; a map takes the keys it lacks; another value of its own it keeps, and
// the item cannot move, saying so. What it added is kept there (`move/settings.json`), so moving back takes out that.

///|
pub let settings_that_move : Array[String] = [
  "sandboxes", "agentEnv", "askToName", "maxNudges", "warmMinutes", "maxWarmClaude", "maxConcurrentTurns", "afreshAbove", "afreshWhenCold",
  "autoArchiveDays", "autoArchiveKeep", "autoArchiveReviewed", "archivedWorkspaceDays", "slackArchiveDays", "automaticDecisions",
  "acceptAutoChats",
]

///|
/// config.json as written (sessions/config.ts): what it says now, and a change to it made soon, said as what it does
/// to the file as it is then (`{op: "set", key, value}`, `{op: "merge", key, entries}`: the keys added to the map it is,
/// or to a new one; `{op: "unmerge", key, keys}`: those keys taken out of the map it is; `{op: "delete", key}`).
pub(all) struct Config {
  raw : async () -> J
  update_soon : async (J) -> Unit
}

///|
pub(all) struct SettingsDeps {
  data : String
  config : Config
  ask : async (String, J) -> J
  disk : Disk
  say : Say
}

///|
pub struct Settings {
  priv d : SettingsDeps
  priv moved : KeptSet
  priv mut former : J
}

///|
fn move_path(data : String, name : String) -> String {
  @nodepath.join("/", [data, "move", name])
}

///|
fn read_move_json(disk : Disk, data : String, name : String) -> J {
  match (disk.read)(move_path(data, name)) {
    Some(t) => @jsjson.try_parse(t).unwrap_or(jo([]))
    None => jo([])
  }
}

///|
async fn write_move_json(disk : Disk, data : String, name : String, v : J) -> Unit {
  (disk.write)(move_path(data, name), stringify(v))
}

///|
fn simple_module(
  id : String,
  moved : KeptSet,
  plan : async (String, String, PlanReads?) -> Array[J],
  move : async (J, String, (J) -> Unit, Waits?) -> Unit,
  back : async (J, String, Waits?) -> Unit,
) -> Module {
  {
    id,
    needs: [],
    plan,
    move,
    back,
    state: async fn(item) {
      st(if moved.has(item_id(item)) { "there" } else { "here" })
    },
    usable_here: Some(async fn(_) { true }),
    usable_there: None,
    can_lend: None,
    lend: None,
    lent_for: None,
    left: None,
    is_here: None,
    abandon: None,
    ready: None,
    stop: None,
    resume: None,
  }
}

///|
pub fn Settings::new(d : SettingsDeps) -> Settings {
  {
    d,
    moved: KeptSet::new(d.disk, move_path(d.data, "settings-moved.json")),
    former: read_move_json(d.disk, d.data, "settings.json"),
  }
}

///|
async fn Settings::raw(self : Settings) -> J {
  match (self.d.config.raw)() {
    Null => jo([])
    r => r
  }
}

///|
pub fn Settings::module(self : Settings) -> Module {
  simple_module(
    "settings",
    self.moved,
    async fn(_ws, to, _reads) {
      let raw = self.raw()
      let keys = settings_that_move.filter(k => get(Some(raw), k) is Some(_))
      let mut failed = false
      let there = if to == "" || keys.length() == 0 {
        None
      } else {
        let answer = Some(
          (self.d.ask)(
            to,
            jo([
              ("method", js("move.setting.values")),
              ("key", js("agentEnv")),
              ("keys", jstrs(keys)),
            ]),
          ),
        ) catch {
          e => {
            ignore(not_answered(self.d.say, "move.setting.values", to, e))
            failed = true
            None
          }
        }
        get(answer, "values")
      }
      keys.map(k => {
        let theirs = get(there, k)
        let mine = get(Some(raw), k)
        let cannot = if failed {
          Some(unanswered(self.d.say))
        } else if !present(theirs) ||
          same(theirs, mine) ||
          (is_map(theirs) && is_map(mine)) ||
          self.moved.has("setting:\{k}") {
          None
        } else {
          Some(
            self.d.say.tr("station.move.sched.settingThere", [
              ("key", k),
              ("value", slice_to(stringify(theirs.unwrap()), 80)),
            ]),
          )
        }
        new_item("settings", "setting:\{k}", k, [], cannot?, again=failed)
      })
    },
    async fn(item, to, _progress, _arrive) {
      let key = slice_from(item_id(item), 8)
      let value = get(Some(self.raw()), key).unwrap_or(Null)
      ignore(
        (self.d.ask)(
          to,
          jo([
            ("method", js("move.setting.put")),
            ("key", js(key)),
            ("value", value),
          ]),
        ),
      )
      self.moved.add(item_id(item))
    },
    async fn(item, from, _arrive) {
      ignore(
        (self.d.ask)(
          from,
          jo([
            ("method", js("move.setting.back")),
            ("key", js(slice_from(item_id(item), 8))),
          ]),
        ),
      )
      self.moved.delete(item_id(item))
    },
  )
}

///|
async fn Settings::save(self : Settings) -> Unit {
  write_move_json(self.d.disk, self.d.data, "settings.json", self.former)
}

///|
fn key_text(v : J?) -> String {
  match v {
    None | Some(Null) => ""
    Some(Str(u)) => @jsjson.sanitize_str(u)
    Some(x) => stringify(x)
  }
}

///|
/// What another station asks of this one's settings (`move.setting.*`).
pub async fn Settings::answer(self : Settings, peer : String, request : J) -> J {
  let key = key_text(get(Some(request), "key"))
  let ok = jo([("ok", jb(true))])
  if !settings_that_move.contains(key) {
    raise Refused("not a setting that moves")
  }
  match text(get(Some(request), "method")) {
    Some("move.setting.values") => {
      let raw = self.raw()
      let asked = arr(get(Some(request), "keys"))
        .unwrap_or([])
        .filter_map(k => match text(Some(k)) {
          Some(s) if settings_that_move.contains(s) => Some(s)
          _ => None
        })
      let mut values = jo([])
      for k in asked {
        values = set(values, k, match get(Some(raw), k) {
          Some(v) => v
          None => Null
        })
      }
      jo([("values", values)])
    }
    Some("move.setting.put") => {
      let raw = self.raw()
      let mine = get(Some(raw), key)
      let value = match get(Some(request), "value") {
        Some(v) => v
        None => Null
      }
      if get(Some(self.former), key) is Some(_) {
        return ok
      }
      if !present(mine) {
        self.former = set(self.former, key, jo([("from", js(peer)), ("whole", jb(true))]))
        self.save()
        (self.d.config.update_soon)(
          jo([("op", js("set")), ("key", js(key)), ("value", value)]),
        )
        return ok
      }
      if same(mine, Some(value)) {
        return ok
      }
      if is_map(mine) && is_map(Some(value)) {
        let keys = keys_of(value).filter(k => !has_key(mine.unwrap(), k))
        if keys.length() == 0 {
          return ok
        }
        self.former = set(
          self.former,
          key,
          jo([("from", js(peer)), ("keys", jstrs(keys))]),
        )
        self.save()
        (self.d.config.update_soon)(
          jo([
            ("op", js("merge")),
            ("key", js(key)),
            ("entries", jo(keys.map(k => (k, get(Some(value), k).unwrap())))),
          ]),
        )
        return ok
      }
      raise Refused(self.d.say.tr("station.move.sched.settingHere", [("key", key)]))
    }
    Some("move.setting.back") => {
      let f = match get(Some(self.former), key) {
        Some(f) => f
        None => return ok
      }
      let op = if is_true(get(Some(f), "whole")) {
        jo([("op", js("delete")), ("key", js(key))])
      } else {
        match get(Some(f), "keys") {
          Some(ks) => jo([("op", js("unmerge")), ("key", js(key)), ("keys", ks)])
          None =>
            if is_true(get(Some(f), "had")) {
              jo([
                ("op", js("set")),
                ("key", js(key)),
                ("value", get(Some(f), "value").unwrap_or(Null)),
              ])
            } else {
              jo([("op", js("delete")), ("key", js(key))])
            }
        }
      }
      (self.d.config.update_soon)(op)
      self.former = del(self.former, key)
      self.save()
      ok
    }
    _ => raise Refused("no such setting request")
  }
}
