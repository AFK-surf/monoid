// Agents asking for the vault's secrets (station/src/vault/secrets.ts, agent 用密钥): a request from a session, its
// card in the session's chat for the vault's owner, the grant or refusal the owner's app sends back (checked by the
// keeper, which alone ever holds the secret), and the commands run with a grant. Without security mode, the secrets are
// the plain library's: the same request and card, decided by the item's owner, the value read from the station. An
// agent may also ask to keep a secret (secret_save): sealed to its owner's devices, written by the app that approves it
// (or, without security mode, into the plain library here); or one only they hold, typed in on its card. A grant may be
// for commands on another station of the workspace (`runOn`). The requests and what was done with them are kept in the
// station's database (`vault_requests`, `vault_audit`), never a secret; the vaults' grants only in memory (carried over
// at a handover), the plain library's written down without their value (`vault_grants`) and taken up after a restart.
// This file: the structure, its start and its handovers; secrets_*.mbt the rest, as secrets.ts orders it.

///|
pub let carried_save_pending : String = "SELECT body FROM vault_requests WHERE ws = ? AND id = ? AND status = 'pending'"

///|
let listing_prefix : Int = 32

///|
let expired_grant_batch : Int = 32

///|
/// A request no one decided is let go after a day.
let pending_secs : Double = 86400.0

///|
/// The words of a grant's scope on its card, and what each means.
fn scope_words(s : String) -> (String, String) {
  match s {
    "once" => ("仅本次", "只给这一条命令用，下次还要再批准")
    "hour" => ("本对话 1 小时内", "1 小时内这个对话可以反复使用，不用再批准")
    _ => ("本对话直到归档", "这个对话归档或删除前都能用，最长 30 天")
  }
}

///|
let scopes : Array[String] = ["once", "hour", "chat"]

///|
/// The services a person signs in to on a card for a token of their own (secret_save `oauth`): its name and hosts.
fn oauth_of(name : String) -> (String, Array[String])? {
  match name {
    "slack" => Some(("Slack", ["slack.com"]))
    _ => None
  }
}

///|
let oauth_names : Array[String] = ["slack"]

///|
fn kind_words(kind : String) -> String {
  match kind {
    "token" => "Token"
    "login" => "登录"
    "ssh_key" => "SSH 密钥"
    "file" => "文件"
    "browser" => "登录态"
    k => k
  }
}

///|
fn how_words(mode : String, hosts : Array[String]) -> String {
  match mode {
    "proxy" => "代理（限 \{join(hosts, ", ")}）"
    "ssh" => "ssh-agent（私钥不出 station）"
    "file" => "文件（命令运行时临时写出，可读取内容）"
    "browser" => "放进这个对话的浏览器（限 \{join(hosts, ", ")}，到期取出）"
    _ => "环境变量（命令可读取明文）"
  }
}

///|
/// Whether a request in `mode` names the hosts it goes to (on its card, in its grant).
fn hosted(mode : String) -> Bool {
  mode == "proxy" || mode == "browser"
}

///|
/// The field of each kind that holds its secret.
fn secret_field(kind : String) -> String {
  match kind {
    "login" => "password"
    "ssh_key" => "private_key"
    "file" => "content"
    "browser" => "cookies"
    _ => "value"
  }
}

///|
/// The most a secret typed in may be, its fields together.
let typed_most : Int = 64 * 1024

///|
/// The fields of a secret its owner typed in, as their app sent them: words only, its secret not empty, one secret's
/// size at most; None when they are not.
fn typed_fields(kind : String, v : Json?) -> Json? {
  guard v is Some(Object(m)) else { return None }
  let mut size = 0
  for k, x in m {
    guard x is String(s) else { return None }
    size += k.length() + s.length()
  }
  let secret = gs(v, secret_field(kind)).unwrap_or("")
  if trim(secret) != "" && (kind == "file" || size <= typed_most) {
    Some(copy(v.unwrap()))
  } else {
    None
  }
}

///|
/// The words an agent is told of a decision it waits for.
pub let undecided : String = "You are told in this session when it is decided: meanwhile go on with what does not need it (answer the chat, other work); with nothing else left, end your turn need_human (about the card)."

///|
/// A conversation address as the agent sees and names it.
fn thread_address(channel : String, thread_ts : String) -> String {
  "\{channel}/\{thread_ts}"
}

///|
/// The surface of still.fail's own chats.
let stillfail_surface : String = "chat"

///|
/// What a station from before a method answers it with: as a method it does not know, or as one of its remote tasks.
fn from_before(why : String) -> Bool {
  contains(why, "unknown method") || contains(why, "task key are required") || contains(why, "unknown task")
}

///|
/// A request as the station keeps it: the contract's, where its card is, and its body as stored.
priv struct KeptRequest {
  request : Json
  mut thread : Int?
  mut card_ts : String?
  raw : String?
}

///|
/// An item an agent may ask for: of a vault (its id) or of the plain library (`plain`), whose owner decides.
pub(all) struct Listed {
  vault : String
  item : String
  owner : String?
  listing : Json
}

///|
/// A use of a secret, as the pages list them.
pub fn use_json(
  item : String,
  at : Json,
  session : String,
  chat_title : String?,
  mode : Json,
  command : Json,
  hosts : Json,
  denied : Bool,
) -> Json {
  obj([
    ("item", js(item)),
    ("at", at),
    ("session", js(session)),
    ("chatTitle", match chat_title { Some(t) => js(t); None => Json::null() }),
    ("mode", mode),
    ("command", command),
    ("hosts", hosts),
    ("denied", jb(denied)),
  ])
}

///|
/// A command sent to another station to run, waiting for how it ended.
struct Away {
  station : String
  session : String?
  workspace : String?
  done : (Json) -> Unit
  used : (() -> Json)?
}

///|
/// A workspace's saves whose fields are gone and which have no sealed copy.
struct LostSaves {
  ids : Map[String, Unit]
  mut ready : Bool
}

///|
/// A decision another connection changed meanwhile, or whose card moved.
priv suberror DecisionChanged

///|
priv suberror DecisionCardMoved

///|
/// A plain grant's record as `vault_grants` keeps it.
priv struct RestoreRow {
  ws : String
  id : String
  body : String
}

///|
pub struct Secrets {
  w : World
  db : @vault_crypto.Db
  crypto : @vault_crypto.Crypto
  vaults : VaultStore
  plain : @vault_crypto.PlainStore
  keeper : @vault_crypto.Keeper
  proxy : Proxy
  uses_index : UseIndex
  listeners : Array[(Json) -> Unit]
  mut plain_written : (Json) -> Unit
  /// The secrets agents asked to keep, by request, until decided: only in memory.
  unsaved : Map[String, Json]
  saves_by_owner : Map[String, Map[String, Map[String, Unit]]]
  save_scopes : Map[String, Array[(String, String)]]
  unscoped_saves : Map[String, Unit]
  posting_saves : Map[String, Json]
  lost_saves : Map[String, LostSaves]
  lost_scopes : Map[String, Map[String, Unit]]
  held_lost_scopes : Map[String, Map[String, Unit]]
  preparing_pending : Map[String, @effect.Deferred[Unit]]
  member_audits : Map[String, Unit]
  pending_audits : Map[String, Unit]
  mut previous_exited : Bool
  restore_pending : Map[String, (String, String)]
  mut restore_waiting : Bool
  mut restore_closed : Bool
  carried_saves : Map[String, Unit]
  mut carried_saves_waiting : Bool
  rebox_pending : Map[String, (String, String, Double)]
  mut rebox_scheduled : Bool
  away : Map[String, Away]
  runs : Incoming
  /// The timers set for retries (restore, rebox), called off as it closes.
  timers : Array[() -> Unit]
}

///|
fn Secrets::now(self : Secrets) -> Double {
  (self.w.now)()
}

///|
fn Secrets::secs(self : Secrets) -> Double {
  self.w.secs()
}

///|
/// Whether a session's chat is over: archived or gone.
fn Secrets::ended(self : Secrets, session : String) -> Bool {
  match (self.w.hub.store.get_session)(session) {
    None => true
    Some(row) => row.archived
  }
}

///|
/// The vault's requests and grants, its tables made where they are not; the plain library's grants taken up again.
pub fn Secrets::new(
  w : World,
  db : @vault_crypto.Db,
  crypto : @vault_crypto.Crypto,
  vaults : VaultStore,
  plain : @vault_crypto.PlainStore,
  proxy? : Proxy,
) -> Secrets raise {
  db.exec(requests_schema)
  initialize_pending_index(db)
  let uses_index = UseIndex::new(w, db)
  let proxy = match proxy {
    Some(p) => p
    None => Proxy::new(w.machine, w.data + "/vault", w.now)
  }
  let keeper_ref : Ref[@vault_crypto.Keeper?] = Ref(None)
  let self_ref : Ref[Secrets?] = Ref(None)
  let kept = kept_of(w, db)
  let keeper = @vault_crypto.Keeper::new(
    crypto,
    () => w.secs(),
    (ms, f) => (w.after)(ms, f),
    d={
      ended: session => match (w.hub.store.get_session)(session) {
        None => true
        Some(row) => row.archived
      },
      kept: Some(kept),
    },
  )
  keeper_ref.val = Some(keeper)
  let s : Secrets = {
    w,
    db,
    crypto,
    vaults,
    plain,
    keeper,
    proxy,
    uses_index,
    listeners: [],
    plain_written: _ => (),
    unsaved: Map([]),
    saves_by_owner: Map([]),
    save_scopes: Map([]),
    unscoped_saves: Map([]),
    posting_saves: Map([]),
    lost_saves: Map([]),
    lost_scopes: Map([]),
    held_lost_scopes: Map([]),
    preparing_pending: Map([]),
    member_audits: Map([]),
    pending_audits: Map([]),
    previous_exited: w.previous.gone is None,
    restore_pending: Map([]),
    restore_waiting: false,
    restore_closed: false,
    carried_saves: Map([]),
    carried_saves_waiting: false,
    rebox_pending: Map([]),
    rebox_scheduled: false,
    away: Map([]),
    runs: Incoming::new(w, proxy),
    timers: [],
  }
  self_ref.val = Some(s)
  if w.previous.gone is Some(gone) {
    ignore(
      @effect.runtime().fork(name="vault previous", async fn() {
        gone() catch {
          _ => return
        }
        s.previous_exited = true
      }),
    )
  }
  s.restore()
  s
}

///|
/// A plain grant's record as stored: `{request, grant, uses, until?}`.
fn stored_of(body : String) -> Json {
  parse_or_null(body)
}

///|
/// The record of a held grant, without its secret.
fn grant_without_secret(h : @vault_crypto.Held) -> Json {
  without(h.grant, "secret")
}

///|
fn is_plain(r : Json) -> Bool {
  gs(Some(r), "vault") == Some(@vault_crypto.plain_id)
}

///|
/// `stored.until ?? stored.grant.exp`.
fn until_or_exp(stored : Json) -> Double {
  match get(Some(stored), "until") {
    Some(Number(u, ..)) => u
    Some(Null) | None => gn(get(Some(stored), "grant"), "exp").unwrap_or(@double.not_a_number)
    _ => @double.not_a_number
  }
}

///|
/// Where the plain library's grants are kept across restarts (secrets.ts's keeper `kept`).
fn kept_of(w : World, db : @vault_crypto.Db) -> @vault_crypto.Kept {
  let read = (h : @vault_crypto.Held) => match
    db.get("SELECT body FROM vault_grants WHERE ws = ? AND id = ?", [
      get(Some(h.request), "ws").unwrap_or(Json::null()),
      get(Some(h.request), "id").unwrap_or(Json::null()),
    ]) {
    Some([String(b), ..]) => Some(b)
    _ => None
  }
  let same_as = (stored : Json, h : @vault_crypto.Held) => stringify(get(Some(stored), "request").unwrap_or(Json::null())) ==
    stringify(h.request) &&
    stringify(get(Some(stored), "grant").unwrap_or(Json::null())) ==
    stringify(grant_without_secret(h))
  let ws_id = (h : @vault_crypto.Held) => [
    get(Some(h.request), "ws").unwrap_or(Json::null()),
    get(Some(h.request), "id").unwrap_or(Json::null()),
  ]
  // Other connections can use, renew, or remove the same plain grant: a use or renewal never recreates a removed
  // record, and concurrent uses of a reusable grant do not overwrite each other's counts.
  let update_repeated = (h : @vault_crypto.Held, until : Double?) => {
    let attempts = (fn() -> (Double, Double?)?? raise {
      if !is_plain(h.request) {
        return None
      }
      for _ in 0..<3 {
        let row = match read(h) {
          Some(b) => b
          None => return Some(None)
        }
        let stored = stored_of(row)
        let uses = get(Some(stored), "uses")
        if !safe_int(uses) ||
          gn(Some(stored), "uses").unwrap() < 0.0 ||
          !(until_or_exp(stored) > w.secs()) ||
          !same_as(stored, h) {
          return Some(None)
        }
        let stored_until = gn(Some(stored), "until")
        let next_until = match until {
          None => stored_until
          Some(u) => Some(@cmp.maximum(until_or_exp(stored), u))
        }
        let next_uses = gn(Some(stored), "uses").unwrap() + (if until is None { 1.0 } else { 0.0 })
        let body = spread(Some(stored), [("uses", jn(next_uses))])
        match next_until {
          Some(u) => set(body, "until", jn(u))
          None => ()
        }
        if db.run("UPDATE vault_grants SET body = ? WHERE ws = ? AND id = ? AND body = ?", [
            js(stringify(body)),
            ..ws_id(h),
            js(row),
          ]) !=
          0 {
          return Some(Some((next_uses, next_until)))
        }
      }
      Some(None)
    })() catch {
      e => {
        w.warn("vault", "a grant's record could not be written", obj([("error", js(message_of(e)))]))
        Some(None)
      }
    }
    attempts
  }
  {
    // The plain library's only: a vault's secret is never written down, and its grant is gone with the process.
    save: h => {
      if !is_plain(h.request) {
        return
      }
      let fs = [("request", h.request), ("grant", grant_without_secret(h)), ("uses", jn(h.uses))]
      if h.until is Some(u) {
        fs.push(("until", jn(u)))
      }
      ignore(
        db.run(
          "INSERT INTO vault_grants (ws, id, session, body) VALUES (?, ?, ?, ?) ON CONFLICT (ws, id) DO UPDATE SET body = excluded.body",
          [..ws_id(h), get(Some(h.request), "session").unwrap_or(Json::null()), js(stringify(obj(fs)))],
        ),
      ) catch {
        e => w.warn("vault", "a grant could not be kept", obj([("error", js(message_of(e)))]))
      }
    },
    current: h => {
      if !is_plain(h.request) {
        return Unknown
      }
      let row = read(h) catch { _ => return Gone }
      match row {
        None => Gone
        Some(b) => {
          let stored = stored_of(b)
          let until = get(Some(stored), "until")
          if !safe_int(get(Some(stored), "uses")) ||
            gn(Some(stored), "uses").unwrap() < 0.0 ||
            (until is Some(_) && !safe_int(until)) ||
            !same_as(stored, h) {
            return Gone
          }
          Is(gn(Some(stored), "uses").unwrap(), gn(Some(stored), "until"))
        }
      }
    },
    // Claim a persisted one-use grant with one conditional write: the previous station may still be running.
    spend_once: h => {
      if !is_plain(h.request) {
        return None
      }
      (fn() -> Bool? raise {
        let row = match read(h) {
          Some(b) => b
          None => return Some(false)
        }
        let stored = stored_of(row)
        if gn(Some(stored), "uses") != Some(0.0) ||
          !(until_or_exp(stored) > w.secs()) ||
          !same_as(stored, h) {
          return Some(false)
        }
        let body = spread(Some(stored), [("uses", jn(1.0))])
        Some(
          db.run("UPDATE vault_grants SET body = ? WHERE ws = ? AND id = ? AND body = ?", [
            js(stringify(body)),
            ..ws_id(h),
            js(row),
          ]) !=
          0,
        )
      })() catch {
        _ => Some(false)
      }
    },
    spend_again: h => match update_repeated(h, None) {
      None => None
      Some(None) => Some(false)
      Some(Some((uses, until))) => {
        h.uses = uses - 1.0
        h.until = until
        Some(true)
      }
    },
    renew: (h, until) => match update_repeated(h, Some(until)) {
      None => RenewUnknown
      Some(None) => NotRenewed
      Some(Some((uses, u))) => {
        h.uses = uses
        RenewedTo(u.unwrap_or(until))
      }
    },
    expire: (h, now) => {
      if !is_plain(h.request) {
        return None
      }
      (fn() -> Bool? raise {
        let row = match read(h) {
          Some(b) => b
          None => return Some(false)
        }
        let stored = stored_of(row)
        if !same_as(stored, h) || until_or_exp(stored) > now {
          return Some(false)
        }
        Some(
          db.run("DELETE FROM vault_grants WHERE ws = ? AND id = ? AND body = ?", [..ws_id(h), js(row)]) != 0,
        )
      })() catch {
        _ => Some(false)
      }
    },
    forget: h => if is_plain(h.request) {
      ignore(db.run("DELETE FROM vault_grants WHERE ws = ? AND id = ?", ws_id(h))) catch {
        _ => ()
      }
    },
  }
}

// ── the plain library's grants taken up after a restart (#restore) ──

///|
/// The plain library's grants written down before a restart, held again: those not run out, whose chat goes on and
/// whose item is still given as granted, its value read again from the store.
fn Secrets::restore(self : Secrets) -> Unit raise {
  let rows = self.db
    .all("SELECT ws, id, body FROM vault_grants", [])
    .map(r => RestoreRow::{ ws: js_text(r.get(0)), id: js_text(r.get(1)), body: js_text(r.get(2)) })
  let expired : Array[(RestoreRow, Json, Double)] = []
  let restore_one = (e : (RestoreRow, Json, Double), use_now : Bool) => {
    let (row, saved, now) = e
    if !self.restore_row(row, first=saved, first_now=if use_now { Some(now) } else { None }) {
      self.restore_pending[stringify(jstrs([row.ws, row.id]))] = (row.ws, row.id)
    }
  }
  let flush = fn() raise {
    if expired.is_empty() {
      return
    }
    let batch = expired.copy()
    expired.clear()
    if batch.length() == 1 {
      restore_one(batch[0], true)
      return
    }
    // The old process may have renewed a row since the list was read: delete only the exact bodies seen.
    let pending = []
    (self.w.foreground)(true)
    (fn() raise {
      self.db.exec("SAVEPOINT vault_restore_expired")
      (fn() raise {
        for entry in batch {
          let (row, _, _) = entry
          if self.db.run("DELETE FROM vault_grants WHERE ws = ? AND id = ? AND body = ?", [
              js(row.ws),
              js(row.id),
              js(row.body),
            ]) ==
            0 {
            pending.push(entry)
          }
        }
        self.db.exec("RELEASE vault_restore_expired")
      })() catch {
        e => {
          self.db.exec("ROLLBACK TO vault_restore_expired; RELEASE vault_restore_expired") catch {
            _ => ()
          }
          raise e
        }
      }
    })() catch {
      e => {
        (self.w.foreground)(false)
        raise e
      }
    }
    (self.w.foreground)(false)
    for entry in pending {
      restore_one(entry, false)
    }
  }
  for original in rows {
    let now = self.secs()
    let saved = parse(original.body) catch {
      e => {
        flush()
        raise e
      }
    }
    let due = !(until_or_exp(saved) > now)
    let entry = (original, saved, now)
    if due {
      expired.push(entry)
      if expired.length() == expired_grant_batch {
        flush()
      }
    } else {
      let waiting = !expired.is_empty()
      flush()
      restore_one(entry, !waiting)
    }
  }
  flush()
  self.resume_restore()
}

///|
/// One saved grant held again where it still is so, else its record let go (only the exact version read): whether
/// that is settled.
fn Secrets::restore_row(self : Secrets, original : RestoreRow, first? : Json, first_now? : Double?) -> Bool raise {
  let mut row : RestoreRow? = Some(original)
  for attempt in 0..<3 {
    guard row is Some(r) else { break }
    let now = match first_now {
      Some(Some(n)) if attempt == 0 => n
      _ => self.secs()
    }
    let saved = match first {
      Some(f) if attempt == 0 => f
      _ => parse(r.body)
    }
    let request = get(Some(saved), "request").unwrap_or(Json::null())
    let grant = get(Some(saved), "grant").unwrap_or(Json::null())
    let session = gtext(Some(request), "session")
    let item_id = gtext(Some(request), "item")
    let mut checked : (String?, String, (Json, Json)??)? = None
    if until_or_exp(saved) > now && !self.ended(session) && (self.w.lock)(Some(r.ws)) is None {
      let snapshot = self.plain.item_snapshot(r.ws, item_id)
      let item = snapshot.map(x => x.0)
      let l = get(item, "listing")
      let secret = item.map(i => obj([
        ("kind", get(Some(i), "kind").unwrap_or(Json::null())),
        ("name", get(Some(i), "name").unwrap_or(Json::null())),
        ("fields", get(Some(i), "fields").unwrap_or(Json::null())),
      ]))
      let owner = gtext(item, "owner")
      let limit : (Json, Json)?? = if item is Some(_) && !has(l, "lasts") {
        Some(self.plain.lasts(r.ws, owner))
      } else {
        None
      }
      checked = Some((snapshot.map(x => x.1), owner, limit))
      let lasts = match get(l, "lasts") {
        Some(x) => Some(x)
        None =>
          match limit {
            Some(Some((x, _))) => Some(x)
            _ => None
          }
      }
      let mode = get(Some(grant), "mode")
      let still = l is Some(_) &&
        !truthy(get(item, "deleted")) &&
        strings_of(get(l, "modes")).contains(js_text(mode)) &&
        mode is Some(String(_)) &&
        @vault_crypto.allows(lasts, get(Some(grant), "scope")) &&
        strings_of(get(Some(grant), "hosts")).all(h => strings_of(get(l, "hosts")).contains(h) ||
          (!starts(h, "*.") && @vault_crypto.host_allowed(h, strings_of(get(l, "hosts"))))) &&
        secret.map(x => @vault_crypto.value_of(x)) is Some(Some(_))
      if still {
        // The list and the item's read may have raced with a deletion, renewal, or item change: all three rows
        // checked in one snapshot before the saved grant is taken.
        let current = self.db.get(
          "SELECT g.body, p.body AS item_body, l.lasts, l.at\n            FROM vault_grants g LEFT JOIN vault_plain p ON p.ws = g.ws AND p.id = ?\n            LEFT JOIN vault_plain_lasts l ON l.ws = g.ws AND l.owner = ?\n            WHERE g.ws = ? AND g.id = ?",
          [js(item_id), js(owner), js(r.ws), js(r.id)],
        )
        guard current is Some(cur) else { return true }
        let cur_body = js_text(cur.get(0))
        let cur_item = match cur.get(1) {
          Some(String(b)) => Some(b)
          _ => None
        }
        let limit_changed = match limit {
          None => false
          Some(lim) => {
            let want_lasts = match lim { Some((x, _)) => x; None => Json::null() }
            let want_at = match lim { Some((_, x)) => x; None => Json::null() }
            cur.get(2).unwrap_or(Json::null()) != want_lasts ||
            cur.get(3).unwrap_or(Json::null()) != want_at
          }
        }
        if cur_body != r.body ||
          cur_item != snapshot.map(x => x.1) ||
          limit_changed ||
          !(until_or_exp(saved) > self.secs()) ||
          self.ended(session) ||
          (self.w.lock)(Some(r.ws)) is Some(_) {
          row = Some({ ..r, body: cur_body })
          continue
        }
        let until = gn(Some(saved), "until")
        self.keeper.restore({
          request,
          grant: spread(Some(grant), [("secret", js(""))]),
          secret: secret.unwrap(),
          uses: gn(Some(saved), "uses").unwrap_or(0.0),
          until,
        })
        return true
      }
    }
    let removed = match checked {
      None =>
        self.db.run("DELETE FROM vault_grants WHERE ws = ? AND id = ? AND body = ?", [
          js(r.ws),
          js(r.id),
          js(r.body),
        ])
      Some((body, owner, limit)) => {
        let (has_limit, lasts, at) = match limit {
          None => (0, Json::null(), Json::null())
          Some(None) => (1, Json::null(), Json::null())
          Some(Some((l, a))) => (1, l, a)
        }
        self.db.run(
          "DELETE FROM vault_grants WHERE ws = ? AND id = ? AND body = ?\n          AND (SELECT body FROM vault_plain WHERE ws = ? AND id = ?) IS ?\n          AND (? = 0 OR ((SELECT lasts FROM vault_plain_lasts WHERE ws = ? AND owner = ?) IS ?\n            AND (SELECT at FROM vault_plain_lasts WHERE ws = ? AND owner = ?) IS ?))",
          [
            js(r.ws),
            js(r.id),
            js(r.body),
            js(r.ws),
            js(item_id),
            match body { Some(b) => js(b); None => Json::null() },
            ji(has_limit),
            js(r.ws),
            js(owner),
            lasts,
            js(r.ws),
            js(owner),
            at,
          ],
        )
      }
    }
    if removed != 0 {
      return true
    }
    row = match self.db.get("SELECT ws, id, body FROM vault_grants WHERE ws = ? AND id = ?", [js(r.ws), js(r.id)]) {
      Some(c) => Some({ ws: js_text(c.get(0)), id: js_text(c.get(1)), body: js_text(c.get(2)) })
      None => None
    }
  }
  row is None
}

///|
fn Secrets::resume_restore(self : Secrets) -> Unit {
  if self.restore_closed || self.restore_waiting || self.restore_pending.is_empty() {
    return
  }
  self.restore_waiting = true
  ignore(
    @effect.runtime().fork(name="vault grant recovery", async fn() {
      match self.w.previous.gone {
        Some(gone) =>
          gone() catch {
            e => {
              self.restore_waiting = false
              self.w.warn("vault", "the previous station did not finish for grant recovery", obj([
                ("error", js(message_of(e))),
              ]))
              return
            }
          }
        None => @effect.pause()
      }
      self.restore_waiting = false
      if !self.restore_closed {
        self.retry_restore()
      }
    }),
  )
}

///|
fn Secrets::retry_restore(self : Secrets) -> Unit {
  if self.restore_closed {
    return
  }
  let mut first : (String, (String, String))? = None
  for k, v in self.restore_pending {
    first = Some((k, v))
    break
  }
  guard first is Some((key, (ws, id))) else { return }
  self.restore_pending.remove(key)
  let mut delayed = false
  (fn() raise {
    if !self.keeper.has_grant(id) {
      match self.db.get("SELECT ws, id, body FROM vault_grants WHERE ws = ? AND id = ?", [js(ws), js(id)]) {
        Some(c) => {
          let row : RestoreRow = { ws: js_text(c.get(0)), id: js_text(c.get(1)), body: js_text(c.get(2)) }
          if !self.restore_row(row) {
            delayed = true
          }
        }
        None => ()
      }
    }
  })() catch {
    e => {
      delayed = true
      self.w.warn("vault", "a grant could not be recovered after handover", obj([("error", js(message_of(e)))]))
    }
  }
  if delayed {
    self.restore_pending[key] = (ws, id)
  }
  if !self.restore_pending.is_empty() {
    // timer: a retry after a failure (another writer raced the recovery)
    self.timers.push((self.w.after)(if delayed { 250.0 } else { 0.0 }, () => self.retry_restore()))
  }
}

///|
/// The use index's connection let go if nothing is asked of it: how many went.
pub fn Secrets::trim_idle(self : Secrets) -> Int {
  self.uses_index.trim_idle()
}

///|
pub fn Secrets::close(self : Secrets) -> Unit {
  self.restore_closed = true
  self.restore_pending.clear()
  self.rebox_pending.clear()
  for t in self.timers {
    t()
  }
  self.timers.clear()
  self.uses_index.close()
}

// ── the secrets waiting to be kept, by workspace and owner ──

///|
fn Secrets::scope_save(self : Secrets, id : String, ws : String, owner : String) -> Unit {
  let scopes = self.save_scopes.get(id).unwrap_or([])
  if scopes.any(s => s.0 == ws && s.1 == owner) {
    return
  }
  scopes.push((ws, owner))
  self.save_scopes[id] = scopes
  let owners = match self.saves_by_owner.get(ws) {
    Some(o) => o
    None => {
      let o = Map([])
      self.saves_by_owner[ws] = o
      o
    }
  }
  let requests = match owners.get(owner) {
    Some(r) => r
    None => {
      let r = Map([])
      owners[owner] = r
      r
    }
  }
  requests[id] = ()
}

///|
fn Secrets::mark_lost(self : Secrets, ws : String, id : String, lost : Bool) -> Unit {
  guard self.lost_saves.get(ws) is Some(state) else { return }
  if lost {
    state.ids[id] = ()
    let scopes = match self.lost_scopes.get(id) {
      Some(s) => s
      None => {
        let s = Map([])
        self.lost_scopes[id] = s
        s
      }
    }
    scopes[ws] = ()
  } else {
    state.ids.remove(id)
    if self.lost_scopes.get(id) is Some(scopes) {
      scopes.remove(ws)
      if scopes.is_empty() {
        self.lost_scopes.remove(id)
      }
    }
  }
}

///|
fn Secrets::track_pending(self : Secrets, ws : String, id : String, r : Json, pending : Bool) -> Unit {
  let rid = gtext(Some(r), "id")
  if pending &&
    self.unsaved.contains(rid) &&
    needs_held(r) &&
    !self.save_scopes.get(rid).unwrap_or([]).any(s => s.0 == ws) {
    let scopes = match self.held_lost_scopes.get(rid) {
      Some(s) => s
      None => {
        let s = Map([])
        self.held_lost_scopes[rid] = s
        s
      }
    }
    scopes[ws] = ()
  } else if self.held_lost_scopes.get(rid) is Some(scopes) {
    scopes.remove(ws)
    if scopes.is_empty() {
      self.held_lost_scopes.remove(rid)
    }
  }
  self.mark_lost(ws, id, pending && !self.recoverable(r))
}

///|
fn Secrets::forget_save(self : Secrets, id : String, settled_ws? : String) -> Unit {
  let recheck = []
  for s in self.save_scopes.get(id).unwrap_or([]) {
    if !recheck.contains(s.0) {
      recheck.push(s.0)
    }
  }
  if self.held_lost_scopes.get(id) is Some(m) {
    for ws, _ in m {
      if !recheck.contains(ws) {
        recheck.push(ws)
      }
    }
  }
  self.unsaved.remove(id)
  for ws in recheck {
    if !self.lost_saves.contains(ws) {
      continue
    }
    let kept = if Some(ws) == settled_ws {
      None
    } else {
      self.kept(ws, id) catch {
        _ => None
      }
    }
    match kept {
      Some(k) =>
        self.mark_lost(
          ws,
          id,
          gs(Some(k.request), "status") == Some("pending") && !self.recoverable(k.request),
        )
      None => self.mark_lost(ws, id, false)
    }
  }
  self.held_lost_scopes.remove(id)
  self.unscoped_saves.remove(id)
  self.carried_saves.remove(id)
  for s in self.save_scopes.get(id).unwrap_or([]) {
    let (ws, owner) = s
    if self.saves_by_owner.get(ws) is Some(owners) {
      if owners.get(owner) is Some(requests) {
        requests.remove(id)
        if requests.is_empty() {
          owners.remove(owner)
        }
      }
      if owners.is_empty() {
        self.saves_by_owner.remove(ws)
      }
    }
  }
  self.save_scopes.remove(id)
}

// ── a handover (carried, carry) ──

///|
/// What this process holds only in memory, for the next one: `{keeper, unsaved: [[id, fields, scopes?]…]}`.
pub fn Secrets::carried(self : Secrets) -> Json {
  let unsaved = []
  for id, fields in self.unsaved {
    match self.save_scopes.get(id) {
      Some(scopes) =>
        unsaved.push(
          jarr([
            js(id),
            fields,
            jarr(scopes.map(s => obj([("ws", js(s.0)), ("owner", js(s.1))]))),
          ]),
        )
      None => unsaved.push(jarr([js(id), fields]))
    }
  }
  obj([("keeper", self.keeper.carried()), ("unsaved", jarr(unsaved))])
}

///|
/// What the process before this one held (`carried`), held here too.
pub fn Secrets::carry(self : Secrets, c : Json) -> Unit {
  self.keeper.carry(get(Some(c), "keeper").unwrap_or(Json::null()))
  for entry in ga(Some(c), "unsaved").unwrap_or([]) {
    guard entry is Array(parts) && parts.length() >= 2 && parts[0] is String(id) else { continue }
    if self.unsaved.contains(id) {
      continue
    }
    self.unsaved[id] = parts[1]
    if self.lost_scopes.get(id) is Some(was_lost) {
      let carried = match self.held_lost_scopes.get(id) {
        Some(m) => m
        None => Map([])
      }
      let wss = []
      for ws, _ in was_lost {
        wss.push(ws)
      }
      for ws in wss {
        carried[ws] = ()
        self.mark_lost(ws, id, false)
      }
      self.held_lost_scopes[id] = carried
    }
    if parts.get(2) is Some(Array(scopes)) {
      for scope in scopes {
        match (gs(Some(scope), "ws"), gs(Some(scope), "owner")) {
          (Some(ws), Some(owner)) => self.scope_save(id, ws, owner)
          _ => ()
        }
      }
    }
    if !self.save_scopes.contains(id) {
      self.unscoped_saves[id] = ()
    }
    self.carried_saves[id] = ()
  }
  if !self.carried_saves.is_empty() {
    self.wait_for_carried_saves()
  }
}

///|
/// Once the old process cannot write any more, each waiting save reconciled with its owner's current certificates.
fn Secrets::wait_for_carried_saves(self : Secrets) -> Unit {
  if self.carried_saves_waiting {
    return
  }
  self.carried_saves_waiting = true
  ignore(
    @effect.runtime().fork(name="vault carried saves", async fn() {
      match self.w.previous.gone {
        Some(gone) =>
          gone() catch {
            e => {
              self.carried_saves_waiting = false
              self.w.warn("vault", "carried saves could not be taken up", obj([("error", js(message_of(e)))]))
              return
            }
          }
        None => @effect.pause()
      }
      self.carried_saves_waiting = false
      if self.restore_closed {
        return
      }
      (fn() raise {
        // Older handovers did not carry a workspace or owner; one compatibility scan recovers those scopes.
        if !self.unscoped_saves.is_empty() {
          for p in self.pending_for_recovery() {
            let (ws, id) = p
            if !self.unscoped_saves.contains(id) {
              continue
            }
            match self.kept(ws, id) {
              Some(k) =>
                if truthy(get(Some(k.request), "save")) && gs(Some(k.request), "owner") is Some(owner) {
                  self.scope_save(id, ws, owner)
                }
              None => ()
            }
          }
        }
      })() catch {
        e => {
          self.w.warn("vault", "carried saves could not be taken up", obj([("error", js(message_of(e)))]))
          return
        }
      }
      let ids = []
      for id, _ in self.carried_saves {
        ids.push(id)
      }
      for id in sorted(ids) {
        if !self.carried_saves.contains(id) {
          continue
        }
        self.carried_saves.remove(id)
        self.unscoped_saves.remove(id)
        self.reconcile_carried_save(id) catch {
          e => self.w.warn("vault", "a carried save could not be taken up", obj([("error", js(message_of(e)))]))
        }
      }
    }),
  )
}

///|
fn Secrets::seal_current_save(self : Secrets, request : Json) -> Bool raise {
  guard gs(Some(request), "owner") is Some(owner) else { return false }
  let ws = gtext(Some(request), "ws")
  guard (self.w.lock)(Some(ws)) is Some(lock) && lock.ws == ws else { return false }
  let certs = []
  for sub in lock.members_with_email(owner) {
    for cert in self.certs_of(lock, sub) {
      certs.push((cert, sub))
    }
  }
  certs.sort_by((a, b) => {
    let x = gtext(Some(a.0), "device")
    let y = gtext(Some(b.0), "device")
    if str_lt(x, y) {
      -1
    } else if str_lt(y, x) {
      1
    } else {
      0
    }
  })
  let mut changed = false
  for c in certs {
    changed = self.seal_save(request, lock, c.0, c.1, owner) || changed
  }
  changed
}

///|
fn Secrets::reconcile_carried_save(self : Secrets, id : String) -> Unit raise {
  let mut found = false
  for s in self.save_scopes.get(id).unwrap_or([]) {
    let (ws, owner) = s
    guard self.kept(ws, id) is Some(kept) else { continue }
    if gs(Some(kept.request), "status") != Some("pending") ||
      !truthy(get(Some(kept.request), "save")) ||
      gs(Some(kept.request), "owner") != Some(owner) {
      continue
    }
    found = true
    if self.seal_current_save(kept.request) {
      self.save(kept)
      self.told(kept.request)
    }
  }
  if !found && !self.posting_saves.contains(id) {
    self.forget_save(id)
    self.keeper.discard_box(id)
  }
}

///|
/// Requests to recover, in the old query's rowid order.
fn Secrets::pending_for_recovery(self : Secrets) -> Array[(String, String)] raise {
  let sql = if rebox_index_complete(self.db) { rebox_ready } else { rebox_legacy }
  self.db.all(sql, []).map(r => (js_text(r.get(0)), js_text(r.get(1))))
}

///|
/// Nothing more comes from the process before: each request still waiting whose box is not here gets a new one,
/// told to its deciders, so that it may still be granted.
pub fn Secrets::reboxed(self : Secrets) -> Unit raise {
  let resolved = []
  for p in self.pending_for_recovery() {
    let (ws, id) = p
    guard self.kept(ws, id) is Some(k) else { continue }
    if self.unsaved.contains(id) && truthy(get(Some(k.request), "save")) && gs(Some(k.request), "owner") is Some(owner) {
      self.scope_save(id, ws, owner)
      resolved.push(id)
    }
    if gs(Some(k.request), "box") == Some("") || self.keeper.waiting(id) {
      continue
    }
    set(k.request, "box", js(self.keeper.open(id)))
    self.save(k)
    self.told(k.request)
  }
  for id in resolved {
    self.unscoped_saves.remove(id)
  }
}

///|
/// Tells `f` of each request made or decided (the members' event streams).
pub fn Secrets::listen(self : Secrets, f : (Json) -> Unit) -> Unit {
  self.listeners.push(f)
}

///|
/// Tells `f` of each item of the plain library this writes itself (`renewed`).
pub fn Secrets::on_plain_written(self : Secrets, f : (Json) -> Unit) -> Unit {
  self.plain_written = f
}

///|
fn Secrets::told(self : Secrets, r : Json) -> Unit {
  for f in self.listeners {
    f(r)
  }
}

///|
fn Secrets::kept(self : Secrets, ws : String, id : String) -> KeptRequest? raise {
  match self.db.get("SELECT body, thread, card_ts FROM vault_requests WHERE ws = ? AND id = ?", [js(ws), js(id)]) {
    Some(row) => {
      let raw = js_text(row.get(0))
      Some({
        request: parse(raw),
        thread: match row.get(1) {
          Some(Number(n, ..)) => Some(n.to_int())
          _ => None
        },
        card_ts: match row.get(2) {
          Some(String(s)) => Some(s)
          _ => None
        },
        raw: Some(raw),
      })
    }
    None => None
  }
}

///|
fn opt_int(v : Int?) -> Json {
  match v {
    Some(n) => ji(n)
    None => Json::null()
  }
}

///|
fn opt_text(v : String?) -> Json {
  match v {
    Some(s) => js(s)
    None => Json::null()
  }
}

///|
fn Secrets::write(self : Secrets, k : KeptRequest) -> Unit raise {
  let r = Some(k.request)
  ignore(
    self.db.run(
      "INSERT INTO vault_requests (ws, id, session, status, body, thread, card_ts) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (ws, id) DO UPDATE SET status = excluded.status, body = excluded.body, thread = excluded.thread, card_ts = excluded.card_ts",
      [
        get(r, "ws").unwrap_or(Json::null()),
        get(r, "id").unwrap_or(Json::null()),
        get(r, "session").unwrap_or(Json::null()),
        get(r, "status").unwrap_or(Json::null()),
        js(stringify(k.request)),
        opt_int(k.thread),
        opt_text(k.card_ts),
      ],
    ),
  )
}

///|
fn Secrets::track_saved(self : Secrets, k : KeptRequest) -> Unit {
  let r = k.request
  let ws = gtext(Some(r), "ws")
  if self.lost_saves.contains(ws) {
    self.track_pending(ws, gtext(Some(r), "id"), r, gs(Some(r), "status") == Some("pending"))
  }
}

///|
fn Secrets::save(self : Secrets, k : KeptRequest) -> Unit raise {
  self.write(k)
  self.track_saved(k)
}

///|
fn Secrets::audit_(self : Secrets, r : Json, kind : String, detail : String) -> Unit raise {
  let f = (k : String) => get(Some(r), k).unwrap_or(Json::null())
  ignore(
    self.db.run(
      "INSERT INTO vault_audit (ws, at, request, vault, item, session, kind, detail) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [f("ws"), jn(self.secs()), f("id"), f("vault"), f("item"), f("session"), js(kind), js(detail)],
    ),
  )
}

///|
/// What was done with the vault's secrets in a workspace, the latest first (never a value).
pub fn Secrets::audit(self : Secrets, ws : String, vault : String, limit? : Int = 200) -> Array[Json] raise {
  self.db
  .all(
    "SELECT at, request, item, session, kind, detail FROM vault_audit WHERE ws = ? AND vault = ? ORDER BY rowid DESC LIMIT ?",
    [js(ws), js(vault), ji(limit)],
  )
  .map(row => obj([
    ("at", row.get(0).unwrap_or(Json::null())),
    ("request", row.get(1).unwrap_or(Json::null())),
    ("item", row.get(2).unwrap_or(Json::null())),
    ("session", row.get(3).unwrap_or(Json::null())),
    ("kind", row.get(4).unwrap_or(Json::null())),
    ("detail", row.get(5).unwrap_or(Json::null())),
  ]))
}

///|
/// A session's workspace and its lock (None: security mode off, the plain library's secrets then).
fn Secrets::place_of(self : Secrets, session : String) -> (String, Lock?) raise {
  guard (self.w.hub.store.get_session)(session) is Some(row) else { raise Refused("unknown session") }
  let ws = match row.ws {
    Some(w) => w
    None =>
      match (self.w.home)() {
        Some(h) => h
        None => raise Refused("this station is in no workspace")
      }
  }
  (ws, (self.w.lock)(row.ws))
}

///|
/// The person a session works for: whoever started its chat.
fn Secrets::starter(self : Secrets, session : String) -> String? {
  (self.w.hub.store.starter)(session)
}

///|
/// The person a request is for: `person` when the agent names one who wrote in this chat; else whoever started it.
fn Secrets::person_for(self : Secrets, session : String, person : String?) -> String? raise {
  let starter = self.starter(session)
  let named = match person {
    Some(p) => lower(trim(p))
    None => ""
  }
  if named == "" || Some(named) == starter {
    return starter
  }
  let people = (self.w.hub.store.participants)(session).filter(p => contains(p, "@") && !contains(p, ":"))
  if people.contains(named) {
    return Some(named)
  }
  let who = if people.length() > 0 {
    "the people who wrote in it from still.fail: \{join(people, ", ")}"
  } else {
    "no one has written in it from still.fail yet: ask them to write in this chat in the still.fail app, then name them"
  }
  raise Refused(
    "\{person.unwrap_or("")} has not written in this chat: name one of \{who}; or leave person out for whoever started it.",
  )
}

///|
/// A ready answer, or None while an old multi-chat session is prepared (Some(None): no thread).
fn Secrets::latest_thread_ready(self : Secrets, session : String) -> Thread?? {
  match (self.w.hub.prepare_latest_threads, self.w.hub.store.latest_thread_if_ready) {
    (Some(_), Some(f)) => f(session)
    _ => Some((self.w.hub.store.latest_thread)(session))
  }
}

///|
/// Whether a request still needs the fields held here to be kept.
fn needs_held(r : Json) -> Bool {
  let save = get(Some(r), "save")
  truthy(save) &&
  get(save, "typed") != Some(Json::boolean(true)) &&
  !(!is_plain(r) && ga(Some(r), "sealed").unwrap_or([]).length() > 0)
}

///|
fn Secrets::recoverable(self : Secrets, r : Json) -> Bool {
  !needs_held(r) || self.unsaved.contains(gtext(Some(r), "id"))
}

///|
fn Secrets::request_live(self : Secrets, r : Json, now : Double) -> Bool {
  let coming = match self.w.coming {
    Some(c) => c()
    None => false
  }
  let live = coming || self.recoverable(r)
  gn(Some(r), "at").unwrap_or(@double.not_a_number) + pending_secs > now && live
}
