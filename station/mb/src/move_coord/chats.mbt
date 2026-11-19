// The chats module (station/src/move/chats.ts; move/AGENTS.md): an item is one chat, its session and those that share
// its still.fail home chat (replica/handover.ts `together`), by its session key. It needs the accounts its sessions
// run on, the connect it runs where, the repositories its linked worktrees hang on and the vaults it holds a grant
// of. Moved by the hand-over (replica/handover.ts, the station's: `HandoverPort`); moved back by the same the other
// way, asked of the station it is on (`move.back`, a told step). Stopped here, it is held as one being handed over is.

///|
/// The most a move back waits for the chat it brings to be shown here once the other answered it went.
pub let arrive_wait_ms : Int = 60_000

///|
/// The chats a plan reads of a workspace at a time.
pub let plan_page : Int = 200

///|
/// A chat as people call it where it has no title: its key without still.fail's own prefix.
pub fn short_key(key : String) -> String {
  if key.has_prefix("chat:") {
    slice_from(key, 5)
  } else {
    key
  }
}

///|
/// What a session's room is measured against (sizes.ts): its last activity, whether it is archived, its last job.
pub fn stamp_of(row : J?, job : String?) -> String {
  match row {
    None | Some(Null) => ""
    Some(r) => {
      let last = match get(Some(r), "lastActiveAt") {
        Some(v) => stringify(v)
        None => "undefined"
      }
      let archived = match get(Some(r), "archivedAt") {
        Some(Null) | None => ""
        Some(v) => stringify(v)
      }
      "\{last}/\{archived}/\{job.unwrap_or("")}"
    }
  }
}

///|
/// One chat's hand-over and what it reads of sessions (replica/handover.ts `Handover`, the station's).
pub(all) struct HandoverPort {
  together : async (String, Page?) -> Array[String]
  chat_of : async (String) -> String
  accounts_of : async (Array[String], Page?) -> Array[(String, J?)]
  past_left : async (Array[(String, J?)], Array[String], Page?) -> Array[String]
  /// Why chat `key` cannot go to `to` (`planning`: as a plan asks), None: it can.
  check : async (String, String, Bool, Page?) -> String?
  coming_in : async (String) -> Array[Array[String]]
  abandon : () -> Unit
  /// Chat `key` handed to `to` (`wait`: its turn waited for; its progress told; arriving stopped for what it waits).
  hand_over : async (String, String, Bool, ((J) -> Unit)?, Waits?) -> J
  arrived : async (String, Int) -> Bool
  out_of : async (String) -> J?
  coming_from : async (String) -> String?
  waits_for_turn : async (J) -> Bool
  start : async () -> Unit
  close : async () -> Unit
  settle : async () -> Unit
  /// Answered once the station process before this one is gone (refused in words past PREVIOUS_LIMIT_MS).
  loaded_within : async () -> Unit
  /// What another station asks of hand-overs (`handover.*`).
  answer : async (String, J, String?, Bytes_?) -> J
  reached : (String) -> Unit
}

///|
/// What the chats module reads of the store (store.ts).
pub(all) struct ChatsStore {
  handed_to : async (String) -> J?
  jobs_mark_of : async (Array[String]) -> Array[(String, String)]
  get_session : async (String) -> J?
}

///|
/// What holds a chat (sessions/hub.ts).
pub(all) struct ChatsHub {
  hold_chat : async (String, String, () -> String) -> Unit
  release_chat : async (String) -> Bool
  busy : (async (String) -> Bool)?
}

///|
pub(all) struct ChatsDeps {
  store : ChatsStore
  handover : HandoverPort
  hub : ChatsHub
  name : ((String) -> String)?
  keep_jobs : async (Array[String], String) -> Unit
  start_kept : async (Array[String]) -> Unit
  ask : async (String, J) -> J
  told : Told?
  here : () -> String
  kind_of : async (String) -> (String, String)?
  vaults_of : async (Array[String], String) -> Map[String, Array[String]]
  wait : (() -> Bool)?
  reads : (String) -> PlanReads
  sizes : Sizes?
  random : (Int) -> String
  say : Say
}

///|
fn uniq(xs : Array[String]) -> Array[String] {
  @jsjson.js_uniq(xs)
}

///|
pub fn chats_module(d : ChatsDeps) -> Module {
  let keys_of = async fn(item : J) -> Array[String] {
    (d.handover.together)(item_id(item), None)
  }
  {
    id: "chats",
    needs: ["accounts", "connects", "repos", "vault"],
    plan: async fn(ws, to, given) {
      let items : Array[J] = []
      let seen : Set[String] = Set::new()
      let plan = match given {
        Some(g) => g
        None => (d.reads)(ws)
      }
      let mut asked_live = 0
      let mut said_live = 0
      (plan.pages)(async fn(reads) {
        let kept : Array[(String, J, Array[String])] = []
        for row in reads.rows {
          let key = text(get(Some(row), "key")).unwrap_or("")
          if seen.contains(key) {
            continue
          }
          let rws = text(get(Some(row), "ws"))
          if rws.map(w => w.has_prefix("coming:")).unwrap_or(false) {
            continue
          }
          let keys = if rws.map(w => w.has_prefix("handed:")).unwrap_or(false) {
            [key]
          } else {
            (d.handover.together)(key, Some(reads))
          }
          for k in keys {
            seen.add(k)
          }
          kept.push((key, row, keys))
        }
        let all_keys = []
        for x in kept {
          all_keys.push_iter(x.2.iter())
        }
        let grants = (d.vaults_of)(uniq(all_keys), ws)
        let not_handed = []
        for x in kept {
          if (d.store.handed_to)(x.0) is None {
            not_handed.push(x)
          }
        }
        let jobs : Map[String, String] = {}
        if d.sizes is Some(_) {
          let ks = []
          for x in not_handed {
            ks.push_iter(x.2.iter())
          }
          for p in (d.store.jobs_mark_of)(uniq(ks)) {
            jobs[p.0] = p.1
          }
        }
        let asking = []
        for x in not_handed {
          asking.push_iter(x.2.iter())
        }
        let mut failed : Error? = None
        let there = if asking.length() == 0 || to == "" {
          None
        } else {
          Some(
            (d.ask)(
              to,
              jo([("method", js("move.chats.live")), ("keys", jstrs(asking))]),
            ),
          ) catch {
            e => {
              failed = Some(not_answered(d.say, "move.chats.live", to, e))
              None
            }
          }
        }
        let live_there : Set[String] = Set::new()
        match arr(get(there, "live")) {
          Some(a) =>
            for k in a {
              match text(Some(k)) {
                Some(s) => live_there.add(s)
                None => ()
              }
            }
          None => ()
        }
        if there is Some(_) {
          asked_live += asking.length()
          said_live += live_there.length()
        }
        let there_name = match text(get(there, "name")) {
          Some(n) if n != "" => n
          _ => slice_to(to, 12)
        }
        for x in kept {
          let (key, row, keys) = x
          let needs : Array[Need] = []
          let accounts = (d.handover.accounts_of)(keys, Some(reads))
          let left = (d.handover.past_left)(accounts, keys, Some(reads))
          for a in accounts {
            if left.contains(a.0) {
              continue
            }
            let id = account_item_id(a.0, a.1)
            if !needs.iter().any(n => n.id == id) {
              needs.push({ module: "accounts", id })
            }
          }
          for k in keys {
            let c = text(get((reads.session)(k), "connect")).unwrap_or("")
            if c == "" || c == "ember" || c == "chat" {
              continue
            }
            match (d.kind_of)(c) {
              Some((kind, mode)) =>
                if mode == "single-session" || (kind != "slack" && kind != "feishu") {
                  let id = connect_item_id(c, (d.here)())
                  if !needs.iter().any(n => n.id == id) {
                    needs.push({ module: "connects", id })
                  }
                }
              None => ()
            }
          }
          let repos = []
          for k in keys {
            match (reads.session)(k) {
              Some(Obj(_) as s) =>
                for r in (plan.worktrees)(text(get(Some(s), "workspace")).unwrap_or("")) {
                  let id = repo_item_id(r.1)
                  if !repos.contains(id) {
                    repos.push(id)
                  }
                }
              _ => ()
            }
          }
          for id in repos {
            needs.push({ module: "repos", id })
          }
          let vaults = []
          for k in keys {
            vaults.push_iter(grants.get(k).unwrap_or([]).iter())
          }
          for id in uniq(vaults) {
            needs.push({ module: "vault", id })
          }
          let handed = (d.store.handed_to)(key)
          if handed is None {
            match d.sizes {
              Some(sizes) => {
                let stamps = []
                for k in keys {
                  stamps.push((k, stamp_of((reads.session)(k), jobs.get(k))))
                }
                sizes.seen(keys[0], stamps)
              }
              None => ()
            }
          }
          let live = if handed is Some(_) {
            []
          } else {
            keys.filter(k => live_there.contains(k))
          }
          let unknown = handed is None && failed is Some(_)
          let why = if handed is Some(_) {
            None
          } else if unknown {
            Some(unanswered(d.say))
          } else if live.length() > 0 {
            Some(d.say.tr("station.move.why.liveThere", [("station", there_name)]))
          } else {
            (d.handover.check)(key, to, true, Some(reads))
          }
          let leaves = if left.length() > 0 {
            Some(d.say.tr("station.move.leavesLogins", [("names", left.join(", "))]))
          } else {
            None
          }
          let label = match text(get(Some(row), "title")) {
            Some(t) => t
            None => key
          }
          items.push(
            new_item("chats", keys[0], label, needs, cannot?=why, again=unknown, leaves?),
          )
        }
      })
      match d.sizes {
        Some(s) => s.read()
        None => ()
      }
      if asked_live > 0 {
        d.say.log(
          "info",
          "the other station asked which chats are live there",
          jo([
            ("station", js(slice_to(to, 12))),
            ("asked", ji(asked_live)),
            ("live", ji(said_live)),
          ]),
        )
      }
      for keys in (d.handover.coming_in)(ws) {
        if keys.iter().any(k => seen.contains(k)) {
          continue
        }
        for k in keys {
          seen.add(k)
        }
        let label = match text(get((d.store.get_session)(keys[0]), "title")) {
          Some(t) => t
          None => keys[0]
        }
        items.push(new_item("chats", keys[0], label, []))
      }
      items
    },
    move: async fn(item, to, progress, stopped_for) {
      let wait = match d.wait {
        Some(w) => w()
        None => true
      }
      ignore((d.handover.hand_over)(item_id(item), to, wait, Some(progress), stopped_for))
    },
    back: async fn(item, from, stopped_for) {
      let mut request = jo([
        ("method", js("move.back")),
        ("module", js("chats")),
        ("id", js(item_id(item))),
        ("to", js((d.here)())),
      ])
      match stopped_for {
        Some(w) => request = set(request, "stoppedFor", w.to_j())
        None => ()
      }
      let key = "back:\{item_id(item)}:\{(d.random)(6)}"
      match d.told {
        Some(told) => {
          let r = request
          ignore(told.asked(from, key, () => (set(r, "told", js(key)), None)))
        }
        None => ignore((d.ask)(from, request))
      }
      for k in keys_of(item) {
        if (d.handover.arrived)(k, arrive_wait_ms) {
          continue
        }
        let station = match d.name {
          Some(n) => n(from)
          None => slice_to(from, 12)
        }
        raise Said(d.say.tr("station.move.onItsWay", [("station", station)]))
      }
    },
    state: async fn(item) {
      let id = item_id(item)
      let o = (d.handover.out_of)(id)
      let bytes = (o : J) => {
        let pairs = []
        match get(Some(o), "done") {
          Some(v) => pairs.push(("done", v))
          None => ()
        }
        match get(Some(o), "total") {
          Some(v) => pairs.push(("total", v))
          None => ()
        }
        pairs.push(("unit", js("bytes")))
        jo(pairs)
      }
      match o {
        Some(o) if text(get(Some(o), "step")) == Some("gone") && !is_true(get(Some(o), "shown")) =>
          return jo([("state", js("moving")), ("progress", bytes(o))])
        _ => ()
      }
      match (d.handover.coming_from)(id) {
        Some(from) =>
          return jo([
            ("state", js("moving")),
            ("waits", js("station")),
            ("from", js(from)),
          ])
        None => ()
      }
      match (d.store.handed_to)(id) {
        Some(h) =>
          return jo([
            ("state", js("there")),
            ("at", get(Some(h), "station").unwrap_or(Null)),
          ])
        None => ()
      }
      let o = match o {
        Some(o) => o
        None => return st("here")
      }
      let progress = match get(Some(o), "placing") {
        Some(Obj(_) as p) => {
          let pairs = []
          match get(Some(p), "done") {
            Some(v) => pairs.push(("done", v))
            None => ()
          }
          match get(Some(p), "total") {
            Some(v) => pairs.push(("total", v))
            None => ()
          }
          pairs.push(("unit", js("files")))
          jo(pairs)
        }
        _ => bytes(o)
      }
      match text(get(Some(o), "step")) {
        Some("held" | "files" | "rows") => {
          let s = jo([("state", js("moving")), ("progress", progress)])
          if (d.handover.waits_for_turn)(o) {
            set(s, "waits", js("turn"))
          } else {
            s
          }
        }
        Some("failed") =>
          jo([
            ("state", js("failed")),
            ("error", js(text(get(Some(o), "error")).unwrap_or(""))),
          ])
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
    abandon: Some(() => (d.handover.abandon)()),
    ready: Some(async fn(item, _to) {
      let wait = match d.wait {
        Some(w) => w()
        None => true
      }
      if wait {
        return None
      }
      let busy = match d.hub.busy {
        Some(b) => b
        None => return None
      }
      for k in keys_of(item) {
        if busy(k) {
          let chat = match text(get((d.store.get_session)(k), "title")) {
            Some(t) => t
            None => short_key(k)
          }
          return Some(d.say.tr("station.move.why.inTurn", [("chat", chat)]))
        }
      }
      None
    }),
    stop: Some(async fn(item, waits_for) {
      let keys = keys_of(item)
      let name = (id : String) => match d.name {
        Some(n) => n(id)
        None => slice_to(id, 12)
      }
      let here = (d.here)()
      let notice = () => d.say.tr(
        match waits_for.at {
          None => "station.move.stoppedChatHere"
          Some(_) => "station.move.stoppedChat"
        },
        [
          ("here", name(here)),
          ("item", waits_for.label.unwrap_or("\{waits_for.module} \{waits_for.id}")),
          (
            "there",
            match waits_for.at {
              None => ""
              Some(a) => name(a)
            },
          ),
        ],
      )
      for k in keys {
        (d.hub.hold_chat)(
          k,
          "stopped: waits for \{waits_for.module} \{waits_for.id}, moved away",
          notice,
        )
      }
      (d.keep_jobs)(
        keys,
        "its chat waits for \{waits_for.module} \{waits_for.id}, which moved to another station",
      )
    }),
    resume: Some(async fn(item) {
      let keys = keys_of(item)
      for k in keys {
        ignore((d.hub.release_chat)(k))
      }
      (d.start_kept)(keys)
    }),
  }
}
