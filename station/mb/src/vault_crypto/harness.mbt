// The package asked line by line (reader `--builder harness-vault-crypto`), for station/test/mb-vault-crypto.test.ts to
// hold it to the TypeScript it is the MoonBit of (station/src/vault/crypto.ts, keeper.ts, plain.ts, schema-install.ts):
// a line of JSON an ask, `{id, op, …}`, answered `{id, value}` or `{id, error}`. One keeper, on a clock and timers the
// asks move (`clock`), its durable store's answers scripted (`kept.answer`) and what it was told of logged (`kept.log`).

///|
fn at(ask : Json, k : String) -> Json? {
  match ask {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
fn text(ask : Json, k : String) -> String raise Refused {
  match at(ask, k) {
    Some(String(s)) => s
    _ => raise Refused("no \{k}")
  }
}

///|
fn bytes_at(ask : Json, k : String) -> Bytes raise Refused {
  unhex(text(ask, k))
}

///|
fn why(w : String?) -> Json {
  match w {
    Some(w) => Json::string(w)
    None => Json::null()
  }
}

///|
fn n(v : Double) -> Json {
  Json::number(v)
}

///|
priv struct Timer {
  due : Double
  seq : Int
  f : () -> Unit
  mut alive : Bool
}

///|
/// The harness's state: its clock (ms), timers, the keeper and what its store was told.
priv struct World {
  c : Crypto
  mut now_ms : Double
  timers : Array[Timer]
  mut seq : Int
  mut keeper : Keeper?
  answers : Map[String, Json]
  log : Array[Json]
  ended : Map[String, Unit]
  prepared : Map[Int, () -> String?]
  mut next_prepared : Int
  mut plain : PlainStore?
  mut db : Db?
}

///|
fn World::after(self : World, ms : Double, f : () -> Unit) -> () -> Unit {
  self.seq += 1
  let t = { due: self.now_ms + ms, seq: self.seq, f, alive: true }
  self.timers.push(t)
  () => t.alive = false
}

///|
/// The clock moved to `ms`, every timer due by then run in turn (those they set too).
fn World::advance(self : World, ms : Double) -> Unit {
  self.now_ms = ms
  while true {
    let mut next : Timer? = None
    for t in self.timers {
      if t.alive && t.due <= ms {
        match next {
          Some(x) if x.due < t.due || (x.due == t.due && x.seq < t.seq) => ()
          _ => next = Some(t)
        }
      }
    }
    match next {
      Some(t) => {
        t.alive = false
        (t.f)()
      }
      None => break
    }
  }
  let alive = self.timers.filter(t => t.alive)
  self.timers.clear()
  self.timers.push_iter(alive.iter())
}

///|
fn World::told(self : World, call : String, h : Held, extra? : Json) -> Unit {
  let m : Map[String, Json] = { "call": Json::string(call), "id": Json::string(request_id(h)), "uses": n(h.uses) }
  if h.until is Some(u) {
    m["until"] = n(u)
  }
  if extra is Some(e) {
    m["at"] = e
  }
  self.log.push(Json::object(m))
}

///|
fn World::answer(self : World, name : String) -> Json {
  self.answers.get(name).unwrap_or(Json::null())
}

///|
fn World::kept(self : World) -> Kept {
  let flag = fn(v : Json) -> Bool? {
    match v {
      True => Some(true)
      False => Some(false)
      _ => None
    }
  }
  {
    save: h => self.told("save", h),
    forget: h => self.told("forget", h),
    spend_once: h => {
      self.told("spendOnce", h)
      flag(self.answer("spendOnce"))
    },
    spend_again: h => {
      self.told("spendAgain", h)
      flag(self.answer("spendAgain"))
    },
    renew: (h, until) => {
      self.told("renew", h, extra=n(until))
      match self.answer("renew") {
        Number(u, ..) => RenewedTo(u)
        False => NotRenewed
        _ => RenewUnknown
      }
    },
    current: h => {
      self.told("current", h)
      match self.answer("current") {
        False => Gone
        Object(o) =>
          Is(
            match o.get("uses") {
              Some(Number(u, ..)) => u
              _ => 0.0
            },
            match o.get("until") {
              Some(Number(u, ..)) => Some(u)
              _ => None
            },
          )
        _ => Unknown
      }
    },
    expire: (h, now) => {
      self.told("expire", h, extra=n(now))
      flag(self.answer("expire"))
    },
  }
}

///|
fn World::keeper(self : World) -> Keeper raise Refused {
  match self.keeper {
    Some(k) => k
    None => raise Refused("no keeper: keeper.new first")
  }
}

///|
fn World::plain(self : World) -> PlainStore raise Refused {
  match self.plain {
    Some(p) => p
    None => raise Refused("no plain store: plain.open first")
  }
}

///|
fn World::db(self : World) -> Db raise Refused {
  match self.db {
    Some(d) => d
    None => raise Refused("no database: db.open first")
  }
}

///|
fn usable_json(r : Result[Held, String]) -> Json {
  match r {
    Ok(h) => Json::object({ "held": h.to_json() })
    Err(w) => Json::object({ "why": Json::string(w) })
  }
}

///|
fn World::keeper_op(self : World, op : String, ask : Json) -> Json raise {
  let k = self.keeper()
  let lock = fn() { lock_view(at(ask, "lock").unwrap_or(Json::null())) }
  let rec = fn(key : String) { at(ask, key).unwrap_or(Json::null()) }
  match op {
    "keeper.open" => Json::string(k.open(text(ask, "request")))
    "keeper.accept" => why(k.accept(lock(), rec("vault"), rec("item"), rec("req"), rec("grant")))
    "keeper.prepare" =>
      match k.prepare_accept(lock(), rec("vault"), rec("item"), rec("req"), rec("grant")) {
        Refusal(w) => Json::object({ "why": Json::string(w) })
        Ready(take) => {
          self.next_prepared += 1
          self.prepared[self.next_prepared] = take
          Json::object({ "ready": n(self.next_prepared.to_double()) })
        }
      }
    "keeper.take" => {
      let token = match at(ask, "token") {
        Some(Number(t, ..)) => t.to_int()
        _ => -1
      }
      guard self.prepared.get(token) is Some(take) else { raise Refused("no such preparation") }
      why(take())
    }
    "keeper.hold" => why(k.hold(rec("req"), rec("d"), rec("secret")))
    "keeper.restore" => {
      guard Held::from_json(rec("held")) is Some(h) else { raise Refused("not a held grant") }
      k.restore(h)
      Json::null()
    }
    "keeper.carried" => k.carried()
    "keeper.carry" => {
      k.carry(rec("carried"))
      Json::null()
    }
    "keeper.usable" => usable_json(k.usable(text(ask, "session"), text(ask, "request")))
    "keeper.active" => Json::boolean(k.active(text(ask, "session"), text(ask, "request")))
    "keeper.spend" => Json::boolean(k.spend(text(ask, "request")))
    "keeper.renew" => {
      k.renew(text(ask, "session"), text(ask, "request"))
      Json::null()
    }
    "keeper.drop" => {
      k.drop(text(ask, "request"))
      Json::null()
    }
    "keeper.discardBox" => {
      k.discard_box(text(ask, "request"))
      Json::null()
    }
    "keeper.holds" => Json::boolean(k.holds(text(ask, "session")))
    "keeper.hasGrant" => Json::boolean(k.has_grant(text(ask, "request")))
    "keeper.end" => {
      k.end(text(ask, "session"))
      Json::null()
    }
    "keeper.held" => Json::array(k.held(text(ask, "session")).map(h => h.to_json()))
    "keeper.waiting" => Json::boolean(k.waiting(text(ask, "request")))
    // an ask made in a transaction that then fails: what it changed of the request is put back
    "keeper.rollback" => {
      let inner = rec("inner")
      let inner_op = text(inner, "op")
      let said = k.rollback_on_error(text(ask, "request"), () => {
        let v = self.keeper_op(inner_op, inner)
        raise Refused("rolled back after \{stringify(v)}")
      }) catch {
        e => e.to_string()
      }
      Json::string(said)
    }
    _ => raise Refused("no op \{op}")
  }
}

///|
fn World::ask(self : World, ask : Json) -> Json raise {
  let c = self.c
  let op = text(ask, "op")
  let rec = fn(key : String) { at(ask, key).unwrap_or(Json::null()) }
  let opt = fn(key : String) {
    match at(ask, key) {
      None | Some(Null) => None
      v => v
    }
  }
  let flag = fn(key : String) { at(ask, key) is Some(True) }
  match op {
    // the formats
    "boxPublic" => Json::string(box_public(c, bytes_at(ask, "priv")))
    "newBoxPair" => {
      let (pub_, sk) = new_box_pair(c)
      Json::object({ "pub": Json::string(pub_), "priv": Json::string(hex(sk)) })
    }
    "sealWith" => Json::string(seal_with(c, text(ask, "pub"), bytes_at(ask, "plain"), text(ask, "context"), bytes_at(ask, "eph")))
    "seal" => Json::string(seal(c, text(ask, "pub"), bytes_at(ask, "plain"), text(ask, "context")))
    "openSeal" => Json::string(hex(open_seal(c, bytes_at(ask, "priv"), text(ask, "sealed"), text(ask, "context"))))
    "encryptWith" => Json::string(encrypt_with(c, bytes_at(ask, "key"), bytes_at(ask, "plain"), text(ask, "context"), bytes_at(ask, "nonce")))
    "decrypt" => Json::string(hex(decrypt(c, bytes_at(ask, "key"), text(ask, "ct"), text(ask, "context"))))
    "recoveryPair" => {
      let (pub_, sk) = recovery_pair(c, bytes_at(ask, "entropy"))
      Json::object({ "pub": Json::string(pub_), "priv": Json::string(hex(sk)) })
    }
    "boxBytes" =>
      match box_bytes(text(ask, "pub")) {
        Some(b) => Json::string(hex(b))
        None => Json::null()
      }
    "contexts" => {
      let num = fn(key : String) {
        match at(ask, key) {
          Some(Number(x, ..)) => x.to_int64()
          _ => 0L
        }
      }
      let ws = text(ask, "ws")
      Json::object({
        "key": Json::string(key_context(ws, text(ask, "vault"), num("epoch"))),
        "item": Json::string(item_context(ws, text(ask, "vault"), text(ask, "item"), num("version"), num("epoch"))),
        "grant": Json::string(grant_context(ws, text(ask, "request"))),
        "save": Json::string(save_context(ws, text(ask, "request"))),
      })
    }
    "allows" => Json::boolean(allows(opt("lasts"), at(ask, "scope")))
    "signedBytes" => Json::string(hex(signed_bytes(c, rec("o"), text(ask, "tag"))))
    "signedOk" => Json::boolean(signed_ok(c, rec("o"), text(ask, "tag")))
    "sign" => sign_ed25519(c, rec("o"), text(ask, "tag"), bytes_at(ask, "seed"))
    // the rules
    "certOk" => why(cert_ok(c, lock_view(rec("lock")), opt("cert"), ever=flag("ever")))
    "vaultOk" => why(vault_ok(c, lock_view(rec("lock")), opt("prev"), rec("next"), copy=flag("copy")))
    "itemOk" => why(item_ok(c, lock_view(rec("lock")), rec("vault"), opt("prev"), rec("next"), copy=flag("copy")))
    "signerOf" =>
      match signer_of(lock_view(rec("lock")), text(ask, "key")) {
        Some((sub, device)) => Json::object({ "sub": Json::string(sub), "device": Json::string(device) })
        None => Json::null()
      }
    "browserListingOk" => why(browser_listing_ok(rec("l")))
    "vaultSupersedes" => Json::boolean(vault_supersedes(rec("a"), rec("b")))
    "itemSupersedes" => Json::boolean(item_supersedes(rec("a"), rec("b")))
    // the keeper's pure parts
    "hostAllowed" => {
      let ps : Array[String] = []
      if at(ask, "patterns") is Some(Array(xs)) {
        for x in xs {
          if x is String(s) {
            ps.push(s)
          }
        }
      }
      Json::boolean(host_allowed(text(ask, "host"), ps))
    }
    "valueOf" => why(value_of(rec("secret")))
    "accountOf" => why(account_of(rec("secret")))
    // the keeper, its clock and its store
    "keeper.new" => {
      self.now_ms = match at(ask, "now") {
        Some(Number(x, ..)) => x * 1000.0
        _ => 0.0
      }
      self.timers.clear()
      self.log.clear()
      self.answers.clear()
      self.ended.clear()
      let deps = {
        ended: s => self.ended.contains(s),
        kept: if flag("kept") { Some(self.kept()) } else { None },
      }
      self.keeper = Some(Keeper::new(c, () => self.now_ms / 1000.0, (ms, f) => self.after(ms, f), d=deps))
      Json::null()
    }
    "clock" => {
      self.advance(
        match at(ask, "now") {
          Some(Number(x, ..)) => x * 1000.0
          _ => self.now_ms
        },
      )
      Json::number(self.timers.length().to_double())
    }
    "kept.answer" => {
      if at(ask, "answers") is Some(Object(m)) {
        for k, v in m {
          self.answers[k] = v
        }
      }
      Json::null()
    }
    "kept.log" => {
      let out = Json::array(self.log.copy())
      self.log.clear()
      out
    }
    "ended" => {
      self.ended.clear()
      if at(ask, "sessions") is Some(Array(xs)) {
        for x in xs {
          if x is String(s) {
            self.ended[s] = ()
          }
        }
      }
      Json::null()
    }
    // the plain library
    "plainOk" => why(plain_ok(opt("prev"), rec("next"), text(ask, "owner")))
    "fileOk" => why(file_ok(rec("fields")))
    "shown" => shown(rec("item"))
    "db.open" => {
      let db = Db::attach(c, text(ask, "path"))
      self.db = Some(db)
      Json::null()
    }
    "db.exec" => {
      self.db().exec(text(ask, "sql"))
      Json::null()
    }
    "db.all" => Json::array(self.db().all(text(ask, "sql"), []).map(Json::array))
    "db.inTransaction" => Json::boolean(self.db().in_transaction())
    "plain.open" => {
      self.plain = Some(PlainStore::new(self.db()))
      Json::null()
    }
    "plain.items" => Json::array(self.plain().items(text(ask, "ws"), text(ask, "owner")))
    "plain.firstItems" =>
      Json::array(
        self
        .plain()
        .first_items(
          text(ask, "ws"),
          text(ask, "owner"),
          match at(ask, "limit") {
            Some(Number(l, ..)) => l.to_int()
            _ => 0
          },
        )
        .map(x => Json::object({ "id": Json::string(x.0), "value": x.1 })),
      )
    "plain.itemsAfter" => Json::array(self.plain().items_after(text(ask, "ws"), text(ask, "owner"), text(ask, "item")))
    "plain.item" => self.plain().item(text(ask, "ws"), text(ask, "item")).unwrap_or(Json::null())
    "plain.itemSnapshot" =>
      snapshot_json(self.plain().item_snapshot(text(ask, "ws"), text(ask, "item")))
    "plain.lasts" =>
      match self.plain().lasts(text(ask, "ws"), text(ask, "owner")) {
        Some((lasts, at_)) => Json::object({ "lasts": lasts, "at": at_ })
        None => Json::null()
      }
    "plain.setLasts" => why(self.plain().set_lasts(text(ask, "ws"), text(ask, "owner"), at(ask, "lasts"), at(ask, "at")))
    "plain.forget" => {
      self.plain().forget(text(ask, "ws"), text(ask, "item"))
      Json::null()
    }
    "plain.put" => {
      self.plain().put(rec("item"))
      Json::null()
    }
    "schema.install" => {
      let rows : Array[String] = []
      if at(ask, "rows") is Some(Array(xs)) {
        for x in xs {
          if x is String(s) {
            rows.push(s)
          }
        }
      }
      install_schema(self.db(), text(ask, "name"), text(ask, "schema"), rows~)
      Json::null()
    }
    _ => self.keeper_op(op, ask)
  }
}

///|
/// Answers the asks on stdin, one a line, until it ends.
pub async fn harness(host : @host.Host) -> Unit {
  let world : World = {
    c: Crypto::of_host(host),
    now_ms: 0.0,
    timers: [],
    seq: 0,
    keeper: None,
    answers: Map([]),
    log: [],
    ended: Map([]),
    prepared: Map([]),
    next_prepared: 0,
    plain: None,
    db: None,
  }
  while host.line() is Some(line) {
    let ask = parse_js(line) catch { _ => Json::null() }
    let id = at(ask, "id").unwrap_or(Json::null())
    let answer = try world.ask(ask) catch {
      e => Json::object({ "id": id, "error": Json::string(e.to_string()) })
    } noraise {
      v => Json::object({ "id": id, "value": v })
    }
    host.say(stringify(answer))
  }
}
