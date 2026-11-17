// What a station tells its members' devices of the locks on their event streams (station/src/mesh/lock-events.ts):
// `lock`, the head of a workspace's lock moved (`{workspace, head}`, to that workspace's members), also each time the
// state in force of a moved workspace changes (its `force` word); and `person`, a person's own lock's did (`{genesis,
// length}`, to that person's devices). What the station keeps is given (`LockSource`), so this is the same whoever
// keeps it.

///|
/// What the tells read of the locks kept (the TypeScript's `Cloud` and `PersonChains`).
pub(all) struct LockSource {
  /// The workspaces the station is in: each one's id and whether it is its home.
  memberships : () -> Array[(String, Bool)]
  /// The head of a workspace's lock (None: the home's), as `lockHead` says it (`{seq, hash}`), None where it keeps none.
  head : (String?) -> Json?
  /// The state in force's word of a workspace (`Cloud.forceWord`).
  force_word : (String?) -> String
  /// Calls the function given each time the cloud's state changes; gives what stops it.
  listen_cloud : (() -> Unit) -> () -> Unit
  /// Calls the function given with a person's log's genesis each time it changes; gives what stops it.
  listen_chains : ((String) -> Unit) -> () -> Unit
  /// The active chain of a person's log kept, by its genesis.
  kept : (String) -> Array[Json]?
}

///|
/// A tell: the event, its data, what it is told once of (`of`) and to whom (`{workspace}` or `{subs}`).
pub type Tell = (String, Json, String, Json) -> Unit

///|
/// The person a person log is of (person-chains.ts `subOf`): its genesis's `ws`, `person:<sub>`.
pub fn sub_of(chain : Array[Json]) -> String? {
  guard chain.length() > 0 && field(chain[0], "ws") is Some(String(ws)) && ws.has_prefix("person:") else {
    return None
  }
  Some(ws.clamped_view(start="person:".length()).to_owned())
}

///|
fn head_word(head : Json?, force : String) -> String {
  match head {
    None | Some(Null) => ""
    Some(h) => {
      let part = (v : Json?) => match v {
        Some(Number(n, ..)) => js_num(n)
        Some(String(s)) => s
        Some(True) => "true"
        Some(False) => "false"
        Some(Null) => "null"
        None => "undefined"
        Some(other) => js_stringify(other)
      }
      "\{part(field(h, "seq"))}:\{part(field(h, "hash"))}:\{force}"
    }
  }
}

///|
/// Tells each change of a lock this station keeps, from now on (`tellLocks`); gives what stops it.
pub fn tell_locks(source : LockSource, tell : Tell) -> () -> Unit {
  let last : Map[String, String] = Map([])
  let look = () => {
    for m in (source.memberships)() {
      let (workspace, home) = m
      let ws = if home { None } else { Some(workspace) }
      let head = (source.head)(ws)
      let now = head_word(head, (source.force_word)(ws))
      let was = last.get(workspace)
      last[workspace] = now
      if was is Some(w) && w != now {
        tell(
          "lock",
          jobj([("workspace", jstr(workspace)), ("head", head.unwrap_or(Json::null()))]),
          "lock\u{0}\{workspace}",
          jobj([("workspace", jstr(workspace))]),
        )
      }
    }
  }
  look()
  let unlisten_cloud = (source.listen_cloud)(look)
  let unlisten_chains = (source.listen_chains)(genesis => {
    guard (source.kept)(genesis) is Some(chain) && sub_of(chain) is Some(sub) else { return }
    tell(
      "person",
      jobj([("genesis", jstr(genesis)), ("length", jnum(chain.length().to_double()))]),
      "person\u{0}\{genesis}",
      jobj([("subs", Json::array([jstr(sub)]))]),
    )
  })
  () => {
    unlisten_cloud()
    unlisten_chains()
  }
}
