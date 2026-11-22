// The accounts module (station/src/move/accounts.ts; move/AGENTS.md): an item is one account's login, known across
// the workspace by the share it is (`share:<id>`), the key it runs with (`key:<hash>`) or, a login of this station's
// own, its profile here (`own:<profile>@<station>`); this machine's own login (`machine:<id>`) cannot go. Moved by
// share/index.ts `moveProfile`; one that can be shared, taken only for what needs it, is lent, not moved (kept in
// `accounts-lent.log`); a share a move made is undone as its login comes home (`accounts-shared.json`).

///|
/// The item an account of profile `id` is (as handover.ts `accountsOf` knows it: `AccountOf`, or None).
pub fn account_item_id(id : String, a : J?) -> String {
  match a {
    Some(a) =>
      match (text(get(Some(a), "share")), text(get(Some(a), "key")), text(get(Some(a), "own"))) {
        (Some(s), _, _) => "share:\{s}"
        (None, Some(k), _) => "key:\{k}"
        (None, None, Some(o)) => "own:\{o}"
        _ => "machine:\{id}"
      }
    None => "machine:\{id}"
  }
}

///|
/// Why a profile cannot be shared with other stations (share/index.ts `shareRefusal`; None: it can).
pub fn share_refusal(p : J?) -> String? {
  if is_map(get(p, "share")) && is_true(get(get(p, "share"), "borrowed")) {
    return Some("this profile is another station's")
  }
  if text(get(get(p, "access"), "kind")) == Some("service") {
    return Some("a service profile cannot be shared with other stations yet")
  }
  let sub = text(get(get(p, "access"), "kind")) == Some("subscription")
  let runtime = text(get(p, "runtime"))
  if sub && runtime == Some("grok") {
    return Some("a SuperGrok subscription cannot be shared with other stations yet")
  }
  if sub && runtime == Some("cursor") {
    return Some("a Cursor account cannot be shared with other stations yet")
  }
  if sub && runtime == Some("devin") {
    return Some("a Devin account cannot be shared with other stations yet")
  }
  if text(get(get(p, "access"), "provider")) == Some("kimi-code") &&
    is_true(get(get(p, "access"), "login")) {
    return Some("a Kimi Code sign-in cannot be shared with other stations yet")
  }
  None
}

///|
/// A login not shared moved as a shared one, and that share undone once it is back (accounts.ts `ShareMoves`).
pub(all) struct ShareMoves {
  /// Profile `id` moved to `to`, shared first where it is not (`made` told the share's id before it is made).
  move : async (String, String, async (String) -> Unit) -> J
  unshare : async (String, Array[String]) -> Bool
  lend : (async (String, String) -> (String, Bool, Bool))?
  unlend : (async (String, String, Bool, Bool) -> Unit)?
  uses_there : (async (String, String) -> Int?)?
  handed_on : (async (String, String) -> Array[String])?
}

///|
pub(all) struct AccountsDeps {
  /// The profiles here that `ws`'s chats run on, each with what it is known by (`AccountOf`, None: the machine's).
  used : async (String) -> Array[(String, J?)]
  shared : async (String) -> Bool
  move_profile : async (String, String) -> J
  present : (async (String) -> String?)?
  ask : async (String, J) -> J
  here : () -> String
  data : String?
  profile : (async (String) -> J?)?
  share_moves : ShareMoves?
  disk : Disk
  clock : Clock
  say : Say
}

///|
/// The accounts module, and what the station asks of it beside the seam.
pub struct Accounts {
  module : Module
  came_home : async (String, String) -> Unit
  look_at : async (String, (String, Int)?) -> Unit
}

///|
pub fn accounts_module(d : AccountsDeps) -> Accounts {
  let there : Map[String, (String, Bool?)?] = {}
  let local : Map[String, String] = {}
  let moving : Set[String] = Set::new()
  let made : KeptSet? = match (d.data, d.share_moves) {
    (Some(data), Some(_)) =>
      Some(KeptSet::new(d.disk, @nodepath.join("/", [data, "move", "accounts-shared.json"])))
    _ => None
  }
  let lent : LentLog? = match (d.data, d.share_moves) {
    (Some(data), Some({ lend: Some(_), .. })) =>
      Some(
        LentLog::new(
          d.disk,
          @nodepath.join("/", [data, "move", "accounts-lent.log"]),
          @nodepath.join("/", [data, "move", "accounts-lent.json"]),
          // (mended below as the TypeScript's is, before its rewrite reads what it keeps)
          later=d.share_moves is Some({ handed_on: Some(_), .. }),
        ),
      )
    _ => None
  }
  let lent_now : Map[String, String] = {}
  let fresh : Set[String] = Set::new()
  let profile = async fn(pid : String) -> J? {
    match d.profile {
      Some(f) => f(pid)
      None => None
    }
  }
  // (what a station from before this kept lent, mended as it starts)
  let mended : @effect.Deferred[Unit] = @effect.Deferred::new()
  (d.clock.spawn)(async fn() {
    match (lent, d.share_moves) {
      (Some(lent), Some({ handed_on: Some(handed_on), .. })) => {
        (async fn() {
          for e in lent.entries() {
            let (share, l) = e
            if is_true(get(Some(l), "hostMoved")) {
              continue
            }
            for key in
              handed_on(
                text(get(Some(l), "to")).unwrap_or(""),
                text(get(Some(l), "pid")).unwrap_or(""),
              ) {
              lent.lent_for(share, "chats \{key}")
            }
          }
        })() catch {
          e =>
            d.say.log(
              "warn",
              "what is lent not mended as the station started",
              jo([("error", js(message_of(e)))]),
            )
        }
        lent.written()
      }
      _ => ()
    }
    ignore(mended.succeed(()))
  })
  let lent_to = fn(item : J) -> String? {
    match lent_now.get(item_id(item)) {
      Some(t) => Some(t)
      None =>
        if item_id(item).has_prefix("share:") {
          match lent {
            Some(l) => text(get(l.base(slice_from(item_id(item), 6)), "to"))
            None => None
          }
        } else {
          None
        }
    }
  }
  let shared_as_it_moves = async fn(pid : String) -> Bool {
    if made is None || (d.shared)(pid) {
      return false
    }
    let p = profile(pid)
    present(p) && !is_true(get(p, "machine")) && share_refusal(p) is None
  }
  let homing : Map[String, @effect.Deferred[Unit]] = {}
  let came_home = async fn(share : String, from : String) -> Unit {
    match lent {
      Some(lent) =>
        match lent.base(share) {
          Some(l) if is_true(get(Some(l), "hostMoved")) => {
            let unlend = d.share_moves.unwrap().unlend.unwrap()
            unlend(
              share,
              text(get(Some(l), "to")).unwrap_or(""),
              false,
              is_true(get(Some(l), "widened")),
            ) catch {
              e =>
                d.say.log(
                  "warn",
                  "a login lent for a move not taken back as it came home",
                  jo([("share", js(share)), ("error", js(message_of(e)))]),
                )
            }
            lent.delete(share)
            return
          }
          _ => ()
        }
      None => ()
    }
    let made = match made {
      Some(m) if m.has(share) => m
      _ => return
    }
    match homing.get(share) {
      Some(going) => return going.wait()
      None => ()
    }
    let undo : @effect.Deferred[Unit] = @effect.Deferred::new()
    homing[share] = undo
    let undone = (d.share_moves.unwrap().unshare)(share, [(d.here)(), from]) catch {
      e => {
        d.say.log(
          "warn",
          "a share a move made not undone as its login came home",
          jo([("share", js(share)), ("error", js(message_of(e)))]),
        )
        homing.remove(share)
        ignore(undo.succeed(()))
        return
      }
    }
    ignore(undone)
    let r = try Ok(made.delete(share)) catch { e => Err(e) }
    homing.remove(share)
    match r {
      Ok(_) => ignore(undo.succeed(()))
      Err(e) => {
        ignore(undo.fail(e))
        raise e
      }
    }
  }
  let module : Module = {
    id: "accounts",
    needs: [],
    plan: async fn(ws, to, _reads) {
      let items : Array[J] = []
      let asked : Array[(String, J)] = []
      let gone : Set[String] = Set::new()
      for u in (d.used)(ws) {
        let (pid, a) = u
        let id = account_item_id(pid, a)
        if items.iter().any(x => item_id(x) == id) {
          continue
        }
        if d.profile is Some(_) && !present(profile(pid)) {
          gone.add(id)
        }
        local[id] = pid
        match a {
          Some(a) => asked.push((id, a))
          None => ()
        }
        let label = match text(get(a, "name")) {
          Some(n) => n
          None => pid
        }
        items.push(
          match a {
            None =>
              new_item(
                "accounts",
                id,
                label,
                [],
                cannot=d.say.tr("station.move.sched.machineLogin", []),
              )
            Some(_) => new_item("accounts", id, label, [])
          },
        )
      }
      let asked_ids : Set[String] = Set::from_array(asked.map(p => p.0))
      let mut failed : Error? = None
      let answer = if asked.length() == 0 || to == "" {
        None
      } else {
        Some(
          (d.ask)(
            to,
            jo([("method", js("move.accounts")), ("accounts", jo(asked))]),
          ),
        ) catch {
          e => {
            failed = Some(not_answered(d.say, "move.accounts", to, e))
            None
          }
        }
      }
      if failed is Some(_) {
        for i in 0..<items.length() {
          if asked_ids.contains(item_id(items[i])) {
            items[i] = set(set(items[i], "cannot", js(unanswered(d.say))), "again", jb(true))
          }
        }
      }
      for p in asked {
        let id = p.0
        match text(get(get(answer, "here"), id)) {
          Some(pid) => {
            let hosts = match get(get(answer, "hosts"), id) {
              Some(Bool(b)) => Some(b)
              _ => None
            }
            there[id] = Some((pid, hosts))
          }
          None => there[id] = None
        }
      }
      let neither : Set[String] = Set::new()
      if to != "" && failed is None {
        for i in 0..<items.length() {
          let x = items[i]
          let share = match local.get(item_id(x)) {
            Some(pid) => get(profile(pid), "share")
            None => None
          }
          if !asked_ids.contains(item_id(x)) ||
            item_cannot(x) is Some(_) ||
            !is_true(get(share, "borrowed")) ||
            text(get(share, "host")) == Some(to) {
            continue
          }
          match there.get(item_id(x)) {
            None | Some(None) =>
              items[i] = set(x, "cannot", js(d.say.tr("station.share.moveBorrowed", [])))
            Some(Some((_, Some(false)))) => neither.add(item_id(x))
            _ => ()
          }
        }
      }
      items.filter(x => !neither.contains(item_id(x)) &&
        (!gone.contains(item_id(x)) ||
        failed is Some(_) ||
        (there.get(item_id(x)) is Some(Some(_)))))
    },
    move: async fn(item, to, _progress, _arrive) {
      let pid = match local.get(item_id(item)) {
        Some(p) => p
        None => raise Failed("account \{item_label(item)} is not on this station")
      }
      match lent {
        Some(lent) =>
          for e in lent.entries() {
            let (share, l) = e
            if text(get(Some(l), "pid")) != Some(pid) || is_true(get(Some(l), "hostMoved")) {
              continue
            }
            if is_true(get(Some(l), "made")) {
              match made {
                Some(m) => m.add(share)
                None => ()
              }
              lent.delete(share)
            } else {
              lent.set(share, set(set(l, "for", ja([])), "hostMoved", jb(true)))
            }
            match text(get(Some(l), "item")) {
              Some(i) => lent_now.remove(i)
              None => ()
            }
          }
        None => ()
      }
      moving.add(item_id(item))
      let r = try Ok({
        let answer = if shared_as_it_moves(pid) {
          let got : Ref[String?] = Ref(None)
          let made = made.unwrap()
          match
            (try Ok((d.share_moves.unwrap().move)(pid, to, async fn(s) {
              got.val = Some(s)
              made.add(s)
            })) catch { e => Err(e) }) {
            Ok(a) => a
            Err(e) => {
              match got.val {
                Some(s) =>
                  if text(get(get(profile(pid), "share"), "id")) != Some(s) {
                    made.delete(s)
                  }
                None => ()
              }
              raise e
            }
          }
        } else {
          (d.move_profile)(pid, to)
        }
        there[item_id(item)] = Some((text(get(Some(answer), "id")).unwrap_or(pid), Some(true)))
      }) catch { e => Err(e) }
      moving.remove(item_id(item))
      match r {
        Ok(_) => ()
        Err(e) => raise e
      }
    },
    back: async fn(item, from, _arrive) {
      ignore(
        (d.ask)(
          from,
          jo([
            ("method", js("move.back")),
            ("module", js("accounts")),
            ("id", js(item_id(item))),
            ("to", js((d.here)())),
          ]),
        ),
      )
      there[item_id(item)] = None
      if item_id(item).has_prefix("share:") {
        came_home(slice_from(item_id(item), 6), from)
      }
    },
    state: async fn(item) {
      if moving.contains(item_id(item)) {
        return st("moving")
      }
      match lent_to(item) {
        Some(to) => return jo([("state", js("here")), ("lentTo", js(to))])
        None => ()
      }
      match there.get(item_id(item)) {
        Some(Some((_, hosts))) if hosts != Some(false) => st("there")
        _ => st("here")
      }
    },
    usable_here: Some(async fn(item) {
      let pid = match local.get(item_id(item)) {
        Some(p) => p
        None => return false
      }
      if !(d.shared)(pid) {
        return shared_as_it_moves(pid)
      }
      let p = profile(pid)
      let allow = get(get(p, "share"), "allow")
      is_true(get(get(p, "share"), "borrowed")) ||
      (match allow {
        Some(Arr(a)) => a.iter().any(x => text(Some(x)) == Some((d.here)()))
        _ => true
      })
    }),
    usable_there: Some(async fn(item) {
      there.get(item_id(item)) is Some(Some(_)) || lent_to(item) is Some(_)
    }),
    can_lend: Some(async fn(item) {
      if lent is None || there.get(item_id(item)) is Some(Some(_)) {
        return false
      }
      let p = match local.get(item_id(item)) {
        Some(pid) => profile(pid)
        None => None
      }
      present(p) &&
      !is_true(get(p, "machine")) &&
      !is_true(get(get(p, "share"), "borrowed")) &&
      share_refusal(p) is None
    }),
    lend: Some(async fn(item, to, for_whom) {
      let pid = local.get(item_id(item))
      let (pid, lent) = match (pid, lent) {
        (Some(p), Some(l)) => (p, l)
        _ => raise Failed("account \{item_label(item)} is not on this station")
      }
      let (share, made_, widened) = (d.share_moves.unwrap().lend.unwrap())(pid, to)
      if lent.base(share) is None {
        fresh.add(share)
      }
      lent.set_base(
        share,
        jo([
          ("to", js(to)),
          ("item", js(item_id(item))),
          ("pid", js(pid)),
          ("made", jb(made_)),
          ("widened", jb(widened)),
        ]),
      )
      let names : Array[String] = []
      for n in for_whom {
        if !names.contains(n.named()) {
          names.push(n.named())
        }
      }
      for n in names {
        lent.lent_for(share, n)
      }
      lent_now[item_id(item)] = to
    }),
    lent_for: Some(async fn(item, to, for_whom) {
      mended.wait()
      let lent = match lent {
        Some(l) if item_id(item).has_prefix("share:") => l
        _ => return
      }
      let share = slice_from(item_id(item), 6)
      match lent.base(share) {
        Some(l) if text(get(Some(l), "to")) == Some(to) && !is_true(get(Some(l), "hostMoved")) => {
          let names : Array[String] = []
          for n in for_whom {
            if !names.contains(n.named()) {
              names.push(n.named())
            }
          }
          for n in names {
            lent.lent_for(share, n)
          }
        }
        _ => ()
      }
    }),
    left: Some(async fn(items) {
      let lent = match lent {
        Some(l) => l
        None => return
      }
      mended.wait()
      let shares : Array[String] = []
      for x in items {
        for s in lent.shares_for(x.named()) {
          if !shares.contains(s) {
            shares.push(s)
          }
        }
      }
      if items.length() == 0 {
        for e in lent.entries() {
          if lent.for_count(e.0) == 0 && !shares.contains(e.0) {
            shares.push(e.0)
          }
        }
      }
      for share in shares {
        let l = match lent.base(share) {
          Some(l) if !is_true(get(Some(l), "hostMoved")) => l
          _ => continue
        }
        for x in items {
          lent.unlent(share, x.named())
        }
        if lent.for_count(share) > 0 {
          continue
        }
        let to = text(get(Some(l), "to")).unwrap_or("")
        let uses = match d.share_moves.unwrap().uses_there {
          Some(u) => u(to, share) catch { _ => None }
          None => None
        }
        if uses != Some(0) && !(uses is None && fresh.contains(share)) {
          d.say.log(
            "info",
            "a login lent kept lent: the other runs chats on it, or did not say",
            jo([
              ("share", js(share)),
              ("to", js(slice_to(to, 12))),
              (
                "uses",
                match uses {
                  Some(n) => ji(n)
                  None => Null
                },
              ),
            ]),
          )
          continue
        }
        (d.share_moves.unwrap().unlend.unwrap())(
          share,
          to,
          is_true(get(Some(l), "made")),
          is_true(get(Some(l), "widened")),
        ) catch {
          e =>
            d.say.log(
              "warn",
              "a login lent for a move not taken back",
              jo([("share", js(share)), ("error", js(message_of(e)))]),
            )
        }
        lent.delete(share)
        match text(get(Some(l), "item")) {
          Some(i) => lent_now.remove(i)
          None => ()
        }
        fresh.remove(share)
      }
      if items.length() == 0 {
        fresh.clear()
      }
    }),
    is_here: Some(async fn(item) {
      match d.present {
        Some(p) => p(item_id(item)) is Some(_)
        None => false
      }
    }),
    abandon: None,
    ready: None,
    stop: None,
    resume: None,
  }
  let look_at = async fn(from : String, said : (String, Int)?) -> Unit {
    let lent = match lent {
      Some(l) => l
      None => return
    }
    mended.wait()
    for e in lent.entries() {
      let (share, l) = e
      if text(get(Some(l), "to")) != Some(from) ||
        is_true(get(Some(l), "hostMoved")) ||
        lent.for_count(share) > 0 ||
        (said is Some((s, _)) && s != share) {
        continue
      }
      let uses = match said {
        Some((_, n)) => Some(n)
        None =>
          match d.share_moves.unwrap().uses_there {
            Some(u) => u(from, share) catch { _ => None }
            None => None
          }
      }
      if uses != Some(0) {
        continue
      }
      d.say.log(
        "info",
        "a login lent taken back: nothing on the station it was lent to runs on it",
        jo([("share", js(share)), ("to", js(slice_to(from, 12)))]),
      )
      (d.share_moves.unwrap().unlend.unwrap())(
        share,
        text(get(Some(l), "to")).unwrap_or(""),
        is_true(get(Some(l), "made")),
        is_true(get(Some(l), "widened")),
      ) catch {
        e =>
          d.say.log(
            "warn",
            "a login lent for a move not taken back",
            jo([("share", js(share)), ("error", js(message_of(e)))]),
          )
      }
      lent.delete(share)
      match text(get(Some(l), "item")) {
        Some(i) => lent_now.remove(i)
        None => ()
      }
    }
  }
  { module, came_home, look_at }
}
