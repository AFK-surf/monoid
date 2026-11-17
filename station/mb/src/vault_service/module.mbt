// The vault as a part of the station (station/src/vault/module.ts `VaultLive`, write-gate.ts): its store in the
// station's database, the agents' requests for its secrets and the grants they hold, sign-ins from a card, its tools,
// its events (`vault-request`, `vault-plain`), its requests of the other stations (`vault.`), and what goes over to the
// next process at a handover. The station's program in Phase 4 makes one `Vault` and gives it what it asks
// (`World`, `VaultDeps`); its routes are station/api_routes's `vault.mbt`, which asks this by its `pub` methods.

///|
/// Writes on a new station do not finish before a previous station's unconditional writes have stopped
/// (write-gate.ts): the launcher normally stops it within 30 seconds; a standalone one is not waited for past 40.
let handover_wait_ms : Double = 40000.0

///|
pub struct WriteGate {
  mut ready : Bool
  mut closed : Bool
  waiting : @effect.Deferred[Bool]
  mut cancel : () -> Unit
}

///|
pub fn WriteGate::new(previous : (async () -> Unit)?, after : (Double, () -> Unit) -> () -> Unit) -> WriteGate {
  let g : WriteGate = {
    ready: previous is None,
    closed: false,
    waiting: @effect.Deferred::new(),
    cancel: () => (),
  }
  if previous is Some(gone) {
    g.cancel = after(handover_wait_ms, () => ignore(g.waiting.succeed(false)))
    ignore(
      @effect.runtime().fork(name="vault write gate", async fn() {
        gone() catch {
          _ => {
            (g.cancel)()
            ignore(g.waiting.succeed(false))
            return
          }
        }
        if g.closed {
          return
        }
        g.ready = true
        (g.cancel)()
        ignore(g.waiting.succeed(true))
      }),
    )
  }
  g
}

///|
/// Whether a write may go on now: Some(false) closed, None the usual path (the previous station exited), else what
/// waits for it.
pub fn WriteGate::wait(self : WriteGate) -> @effect.Deferred[Bool]?? {
  if self.closed {
    return Some(None)
  }
  if self.ready {
    None
  } else {
    Some(Some(self.waiting))
  }
}

///|
pub fn WriteGate::close(self : WriteGate) -> Unit {
  self.closed = true
  (self.cancel)()
  ignore(self.waiting.succeed(false))
}

///|
/// What the vault's part tells and asks besides the World (module.ts's events, browsers, pages).
pub(all) struct VaultDeps {
  /// An event told the members' streams: its kind, what it says, its key, whom it is for.
  tell : (String, Json, String, Json) -> Unit
  /// The browser's sign-in form and tabs for a chat (signin.ts's `browser`).
  tabs : (String) -> Array[(String, String)]
  look : async (String, String) -> Json
  drive : async (String, String, String, Json, Map[String, Unit]) -> Json
  /// The link that opens a tab's screen in the app, where the station has pages.
  screen_link : (String) -> String?
  /// A session's workspace (its store's `sessionWs`, else the home's).
  session_ws : (String) -> String?
  /// A session's workspace directory.
  session_dir : (String) -> String?
  /// The platform's `path.join`.
  join_path : (String, String) -> String
  /// A new sign-in's id (signin.ts `id`; none: its own, `g_` and the time and some random letters).
  signin_id : (() -> String)?
  /// The browsers' contexts taken up with their passkeys again, once nothing more comes (`browsers.passkeysAgain()`).
  passkeys_again_all : () -> Unit
}

///|
/// Whether `domain` is one of `sites` (each with its subdomains): browser/signins.ts `ofSites`.
pub fn of_sites(domain : String, sites : Array[String]) -> Bool {
  let d0 = lower(domain)
  let d = if starts(d0, ".") { slice(d0, 1) } else { d0 }
  sites.any(s => d == s || ends(d, ".\{s}"))
}

///|
fn covers(hosts : Array[String], site : String) -> Bool {
  of_sites(site, hosts) || hosts.any(h => of_sites(h, [site]))
}

///|
pub struct Vault {
  vaults : VaultStore
  secrets : Secrets
  sign_ins : SignIns
  writes : WriteGate
  tools : Array[Tool]
  mut coming : Bool
  deps : VaultDeps
  came_ref : Ref[(() -> Unit)?]
}

///|
/// The vault's part made: its store, requests, sign-ins and tools, its listeners set.
pub fn Vault::new(w : World, db : @vault_crypto.Db, crypto : @vault_crypto.Crypto, deps : VaultDeps) -> Vault raise {
  let vaults = VaultStore::new(db)
  let coming = Ref(true)
  let w = { ..w, coming: Some(() => coming.val) }
  let writes = WriteGate::new(w.previous.gone, w.after)
  let secrets = Secrets::new(w, db, crypto, vaults, @vault_crypto.PlainStore::new(db))
  let secrets_ref = secrets
  let sign_in_deps : SignInDeps = {
    tabs: deps.tabs,
    look: deps.look,
    drive: deps.drive,
    listed: (session, site) => {
      for l in secrets_ref.listings(session) {
        if gs(Some(l.listing), "kind") == Some("browser") && covers(strings_of(get(Some(l.listing), "hosts")), site) {
          return Some(l.item)
        }
      }
      None
    },
    held: (session, site) => {
      for h in secrets_ref.held(session) {
        if gs(Some(h.grant), "mode") == Some("browser") && covers(strings_of(get(Some(h.grant), "hosts")), site) {
          let hosts = join(strings_of(get(Some(h.grant), "hosts")), ", ")
          return Some(
            "A sign-in to \{hosts} is granted to this chat already (grant \{gtext(Some(h.request), "id")}, until \{iso(gn(Some(h.grant), "exp").unwrap_or(0.0))}): it is in this chat's browser.",
          )
        }
      }
      None
    },
    use_: (session, item, reason) => secrets_ref.ask(session, {
      item,
      mode: Some("browser"),
      reason,
      command: None,
      hosts: None,
      station: None,
      timeout: None,
      person: None,
    }),
    keep: (session, site, reason, made, name, about) => {
      let on = secrets_ref.status(session)
      secrets_ref.save_secret(session, {
        name: name.unwrap_or("\{site} 登录态"),
        about,
        kind: "browser",
        hosts: Some([site]),
        reason,
        cwd: "",
        quiet: if on == "on" || on == "plain" { Some(made) } else { None },
        value: None,
        command: None,
        path: None,
        username: None,
        public_key: None,
        filename: None,
        modes: None,
        env: None,
        station: None,
        browser: None,
        person: None,
        oauth: None,
      })
    },
    screen_link: deps.screen_link,
    workspace: session => match (deps.session_ws)(session) {
      Some(x) => Some(x)
      None => (w.home)()
    },
    id: deps.signin_id,
  }
  let sign_ins = SignIns::new(w, db, sign_in_deps)
  secrets.listen(r => sign_ins.heard(r) catch {
    e => w.warn("signin", "a sign-in's keeping could not be told", obj([("error", js(message_of(e)))]))
  })
  secrets.on_plain_written(i => (deps.tell)(
    "vault-plain",
    @vault_crypto.shown(i),
    "vault-plain\u{0}\{gtext(Some(i), "id")}",
    obj([("workspace", get(Some(i), "ws").unwrap_or(Json::null())), ("email", get(Some(i), "owner").unwrap_or(Json::null()))]),
  ))
  secrets.listen(r => match secrets.tells(r) {
    Some(to) => (deps.tell)("vault-request", r, "vault-request\u{0}\{gtext(Some(r), "id")}", to)
    None => ()
  })
  let v : Vault = {
    vaults,
    secrets,
    sign_ins,
    writes,
    tools: vault_tools(secrets, deps.session_dir, deps.join_path, sign_ins~),
    coming: true,
    deps,
    came_ref: Ref(None),
  }
  // Once nothing more comes, the requests still waiting whose boxes did not come (a restart) get new ones.
  let came = () => {
    if !coming.val {
      return
    }
    coming.val = false
    v.coming = false
    secrets.reboxed() catch {
      e => w.warn("vault", "the requests waiting could not be given new boxes", obj([("error", js(message_of(e)))]))
    }
    // (the grants carried over or restored: their passkeys into the contexts taken up)
    (deps.passkeys_again_all)()
  }
  v.came_ref.val = Some(came)
  match w.previous.gone {
    None => came()
    Some(gone) =>
      ignore(
        @effect.runtime().fork(name="vault came", async fn() {
          gone() catch {
            _ => ()
          }
          came()
        }),
      )
  }
  v
}

///|
/// What this process holds only in memory, for the next one (a handover: `parts.carry("vault", …)`).
pub fn Vault::carried(self : Vault) -> Json {
  self.secrets.carried()
}

///|
/// What the process before held, held here; nothing more comes from it then.
pub fn Vault::carry(self : Vault, what : Json) -> Unit {
  self.secrets.carry(what)
  match self.came_ref.val {
    Some(came) => came()
    None => ()
  }
}

///|
/// A request of another station (`vault.`), in its workspace (none: the home's).
pub async fn Vault::heard(self : Vault, w : World, peer : String, workspace : String?, request : Json) -> Json {
  let ws = match workspace {
    Some(x) => x
    None => (w.home)().unwrap_or("")
  }
  self.secrets.heard(peer, ws, request)
}

///|
/// A session's chat changed (the store's `session`, `sessionRemoved`).
pub fn Vault::session_changed(self : Vault, key : String) -> Unit {
  self.secrets.session_changed(key)
  self.sign_ins.session_changed(key) catch {
    _ => ()
  }
}

///|
/// The station closing: what waits let go.
pub fn Vault::close(self : Vault) -> Unit {
  self.writes.close()
  self.secrets.close()
  self.sign_ins.close()
}
