// The connects module (station/src/move/connects.ts; move/AGENTS.md): an item is one connect of this station's
// (`<id>@<origin>`). One of a routed kind (Slack, Feishu) moves once the chats that came through it are there; one that
// is not routed (Comma, a single-session connect) runs its chats where it runs: they need it, so it goes first.

///|
/// A connect's item id: as the workspace knows it.
pub fn connect_item_id(id : String, here : String) -> String {
  if id.contains("@") {
    id
  } else {
    "\{id}@\{here}"
  }
}

///|
fn connect_local_of(item : String, here : String) -> String {
  if item.has_suffix("@\{here}") {
    slice(item, 0, item.length() - here.length() - 1)
  } else {
    item
  }
}

///|
/// A connect of this station's: id, name, kind, mode.
pub(all) struct OwnConnect {
  id : String
  name : String
  kind : String
  mode : String
}

///|
pub(all) struct ConnectsDeps {
  own : async (String) -> Array[OwnConnect]
  chats_of : async (String) -> Array[String]
  kind_of : (async (String) -> (String, String)?)?
  keys_of : (async (String) -> Array[String])?
  runs_on : async (String) -> String?
  move : async (String, String, Array[String]) -> Unit
  ask : async (String, J) -> J
  here : () -> String
}

///|
pub fn connects_module(d : ConnectsDeps) -> Module {
  let moved : Map[String, String] = {}
  let target = Ref("")
  {
    id: "connects",
    needs: ["chats"],
    plan: async fn(ws, to, _reads) {
      target.val = to
      let here = (d.here)()
      let items = []
      for c in (d.own)(ws) {
        let routed = (c.kind == "slack" || c.kind == "feishu") && c.mode != "single-session"
        let needs = if routed {
          (d.chats_of)(c.id).map(id => { module: "chats", id })
        } else {
          []
        }
        items.push(new_item("connects", connect_item_id(c.id, here), c.name, needs))
      }
      items
    },
    move: async fn(item, to, _progress, _arrive) {
      let local = connect_local_of(item_id(item), (d.here)())
      let kind = match d.kind_of {
        Some(k) => k(local)
        None => None
      }
      let routed = match kind {
        None => true
        Some((k, mode)) => (k == "slack" || k == "feishu") && mode != "single-session"
      }
      let awaiting = if routed {
        []
      } else {
        match d.keys_of {
          Some(f) => f(local)
          None => []
        }
      }
      (d.move)(local, to, awaiting)
      moved[item_id(item)] = to
    },
    back: async fn(item, from, _arrive) {
      ignore(
        (d.ask)(
          from,
          jo([
            ("method", js("move.back")),
            ("module", js("connects")),
            ("id", js(item_id(item))),
            ("to", js((d.here)())),
          ]),
        ),
      )
      moved.remove(item_id(item))
    },
    state: async fn(item) {
      let on = match moved.get(item_id(item)) {
        Some(s) => Some(s)
        None => (d.runs_on)(connect_local_of(item_id(item), (d.here)()))
      }
      match on {
        Some(s) if s != (d.here)() && (target.val == "" || s == target.val) =>
          st("there")
        _ => st("here")
      }
    },
    usable_here: None,
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
