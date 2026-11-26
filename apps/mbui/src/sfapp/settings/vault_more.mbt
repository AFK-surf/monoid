// What the vault's pages and dialogs share (Vault.kt; the pages are src/sfpages vault.mbt and vault_item.mbt, the
// dialogs vault_dialogs.mbt): its calls and how they failed (`vault.*`), the recovery words shown the once, an item
// opened while its page is up (`vault.open`; what it holds never kept, never logged: stillfail/main.mbt `logged`), an
// item written (`vault.putItem`: its params, the hosts it is given to, what is wrong with it).

///|
/// The fields each kind of item holds, in the editor's order; those not secret.
fn vault_fields(kind : String) -> Array[String] {
  match kind {
    "token" => ["value"]
    "ssh_key" => ["private_key", "public_key"]
    "login" => ["username", "password", "totp"]
    "file" => ["content", "filename"]
    "browser" => ["cookies"]
    _ => []
  }
}

///|
/// The most a file kept may be, its bytes (the core's and the station's).
pub let file_most : Int = 64 * 1024

///|
/// Asks the system's picker for a file to be kept: `got` its bytes in base64 and its name once answered; one bigger
/// than a file kept may be said so, and not taken.
pub fn pick_vault_file(core : Core, got : (String, String) -> Unit) -> Unit {
  @ui.pick(Files, on_got=fn(files) {
    match files.get(0) {
      Some(f) if f.bytes.length() > file_most || f.held != 0 => (core.say)(tr("android-settings.vault.fileTooBig"))
      Some(f) => got(@codec.base64(f.bytes), f.name)
      None => ()
    }
  })
  |> ignore
}

///|
/// A file's size in words, from its base64: 820 B, 12 KB.
pub fn file_size(content : String) -> String {
  let pad = if content.has_suffix("==") {
    2
  } else if content.has_suffix("=") {
    1
  } else {
    0
  }
  let n = content.length() * 3 / 4 - pad
  if n < 1024 {
    "\{n} B"
  } else {
    "\{(n + 512) / 1024} KB"
  }
}

///|
/// What a vault call's failure says (vaultSaid): nothing when the person turned the system's prompt down
/// (`user_cancelled`), that another device wrote first (`vault_conflict`), else why.
pub fn vault_said(e : Json) -> String? {
  match text(Some(e), "code") {
    "user_cancelled" => None
    "vault_conflict" => Some(tr("android-settings.vault.conflict"))
    _ => Some(error_text(e))
  }
}

///|
/// A vault call (`vault.<name>` on the workspace), as act is for others (vaultAct): `done` said once through, a
/// failure said (a write made elsewhere first said as such; the prompt turned down, nothing).
pub fn vault_act(
  core : Core,
  ws : String,
  name : String,
  params : Array[(String, Json)],
  what : String,
  done? : String = "",
  then? : (Json) -> Unit = fn(_) {  },
  failed? : (Json) -> Unit = fn(_) {  },
) -> Unit {
  let p = [("workspace", str(ws))]
  for x in params {
    p.push(x)
  }
  if name == "lock" {
    vault_lock_bump_all()
  }
  (core.call)("vault." + name, obj(p), fn(r) {
    match r {
      Ok(v) => {
        if done != "" {
          (core.say)(done)
        }
        then(v)
      }
      Err(e) => {
        failed(e)
        match vault_said(e) {
          Some(why) =>
            (core.say)(
              if text(Some(e), "code") == "vault_conflict" {
                why
              } else {
                fill(
                  if text(Some(e), "code") == "unconfirmed" {
                    "android-misc.act.unconfirmed"
                  } else {
                    "android-misc.act.failed"
                  },
                  [("what", what), ("error", why)],
                )
              },
            )
          None => ()
        }
      }
    }
  })
}

///|
/// The recovery words `vault.setup` gave, by workspace, until the person says they have written them down: in memory
/// only, never kept (the core gives them only the once).
pub let recovery_words : Map[String, Array[String]] = Map([])

///|
/// recovery_words changed (given, written down): what shows them reads `recovery_words_turned`, so that a page kept
/// across frames is built again as they come or go (they are no signal of their own: 已抄写 left them up until
/// something else built the page, a minute on, as the end-to-end flow on Android found).
pub let recovery_words_turned : @signals.Signal[Int] = @signals.signal(0)

///|
pub fn recovery_words_changed() -> Unit {
  recovery_words_turned.set(recovery_words_turned.untracked() + 1)
}

///|
/// Authoritative context snapshot for a `VaultItem` page instance.
#derive(Eq)
pub(all) struct VaultScope {
  account : String
  workspace : String
  vault : String
  item : String
  vault_gen : Int
  stay_id : Int
}

///|
/// Per-instance state of a `VaultItem` page: its plaintext (`plain`, `fields`), in-flight `vault.open` identity
/// (`pending_id`, `in_flight`, `opening`), field reveal/visibility state (`reveal`, `shown`), scope snapshot (`scope`),
/// and invalidation hook (`on_invalidate` closes the instance's dialogs and clears input focus).
priv struct VaultInstance {
  mut scope : VaultScope
  mut pending_id : Int
  mut in_flight : Int?
  mut alive : Bool
  plain : @signals.Signal[Json?]
  fields : @signals.Signal[Array[Json]]
  opening : @signals.Signal[Bool]
  reveal_field : @signals.Signal[String?]
  shown : @sf.LiveMap[String, Bool]
  on_invalidate : () -> Unit
}

///|
priv struct VaultInstances {
  mut next_id : Int
  mut next_pending : Int
  mut all_lock_gen : Int
  instances : Map[Int, VaultInstance]
  /// Workspace-level lock generation.
  ws_gen : Map[String, Int]
  /// Per-(workspace, vault) lock generation (bumped when that single vault locks).
  vault_gen : Map[String, Int]
}

///|
let vault_instances : VaultInstances = {
  next_id: 1,
  next_pending: 1,
  all_lock_gen: 0,
  instances: {},
  ws_gen: {},
  vault_gen: {},
}

///|
fn next_vault_pending() -> Int {
  let pid = vault_instances.next_pending
  vault_instances.next_pending = pid + 1
  pid
}

///|
fn vault_gen_key(ws : String, vault : String) -> String {
  ws + "\u{0000}" + vault
}

///|
/// Current monotonic lock generation for `(ws, vault)`.
pub fn vault_gen_of(ws : String, vault : String) -> Int {
  vault_instances.all_lock_gen +
  vault_instances.ws_gen.get(ws).unwrap_or(0) +
  vault_instances.vault_gen.get(vault_gen_key(ws, vault)).unwrap_or(0)
}

///|
fn vault_batched(f : () -> Unit) -> Unit {
  @signals.start_batch()
  f()
  @signals.end_batch()
}

///|
fn invalidate_vault_instance(inst : VaultInstance) -> Unit {
  inst.pending_id = next_vault_pending()
  inst.in_flight = None
  vault_batched(fn() {
    inst.opening.set(false)
    inst.plain.set(None)
    inst.fields.set([])
    inst.reveal_field.set(None)
    inst.shown.clear()
  })
  (inst.on_invalidate)()
}

///|
/// Registers a new `VaultItem` page instance and returns its unique `page_instance_id`.
pub fn vault_instance_new(scope : VaultScope, on_invalidate? : () -> Unit = fn() {  }) -> Int {
  let id = vault_instances.next_id
  vault_instances.next_id = id + 1
  vault_instances.instances[id] = {
    scope,
    pending_id: next_vault_pending(),
    in_flight: None,
    alive: true,
    plain: @signals.signal(None),
    fields: @signals.signal([]),
    opening: @signals.signal(false),
    reveal_field: @signals.signal(None),
    shown: @sf.LiveMap::new(),
    on_invalidate,
  }
  id
}

///|
/// Invalidates a `VaultItem` page instance (e.g., covered in stack or leaving stack): clears its plaintext, field
/// visibility, and in-flight state, advances its `pending_id` so any in-flight `vault.open` callback is rejected even
/// if the same page instance is later resumed, and runs `on_invalidate` to close its dialogs and drop input focus.
pub fn vault_instance_invalidate(instance_id : Int) -> Unit {
  match vault_instances.instances.get(instance_id) {
    Some(inst) if inst.alive => invalidate_vault_instance(inst)
    _ => ()
  }
}

///|
/// Updates a `VaultItem` page instance's authoritative scope; if account, workspace, vault, item, or `vault_gen`
/// changed, invalidates the instance immediately.
pub fn vault_instance_sync_scope(instance_id : Int, scope : VaultScope) -> Unit {
  match vault_instances.instances.get(instance_id) {
    Some(inst) if inst.alive =>
      if inst.scope != scope {
        inst.scope = scope
        invalidate_vault_instance(inst)
      }
    _ => ()
  }
}

///|
/// Permanently disposes a `VaultItem` page instance when its view node is destroyed.
pub fn vault_instance_dispose(instance_id : Int) -> Unit {
  match vault_instances.instances.get(instance_id) {
    Some(inst) => {
      if inst.alive {
        inst.alive = false
        invalidate_vault_instance(inst)
      }
      vault_instances.instances.remove(instance_id)
    }
    None => ()
  }
}

///|
/// Advances lock generation for workspace `ws` (or a single `vault` inside `ws`) and immediately invalidates all
/// matching live `VaultItem` instances so plaintext/visibility clear at once and any in-flight `vault.open` callbacks
/// are rejected.
pub fn vault_lock_bump(ws : String, vault? : String = "") -> Unit {
  if vault == "" {
    vault_instances.ws_gen[ws] = vault_instances.ws_gen.get(ws).unwrap_or(0) + 1
  } else {
    let k = vault_gen_key(ws, vault)
    vault_instances.vault_gen[k] = vault_instances.vault_gen.get(k).unwrap_or(0) + 1
  }
  let affected : Array[VaultInstance] = []
  for _, inst in vault_instances.instances {
    if inst.alive && inst.scope.workspace == ws && (vault == "" || inst.scope.vault == vault) {
      affected.push(inst)
    }
  }
  for inst in affected {
    let next_gen = vault_gen_of(inst.scope.workspace, inst.scope.vault)
    inst.scope = { ..inst.scope, vault_gen: next_gen }
    invalidate_vault_instance(inst)
  }
}

///|
/// Advances global lock generation across all workspaces (matching core's explicit `vault.lock` which clears all
/// in-memory vault keys across workspaces) and immediately invalidates every live `VaultItem` instance.
pub fn vault_lock_bump_all() -> Unit {
  vault_instances.all_lock_gen = vault_instances.all_lock_gen + 1
  let affected : Array[VaultInstance] = []
  for _, inst in vault_instances.instances {
    if inst.alive {
      affected.push(inst)
    }
  }
  for inst in affected {
    let next_gen = vault_gen_of(inst.scope.workspace, inst.scope.vault)
    inst.scope = { ..inst.scope, vault_gen: next_gen }
    invalidate_vault_instance(inst)
  }
}

///|
fn vault_instances_reset() -> Unit {
  // Keep next_id, next_pending, and all_lock_gen monotonic across resets so stale callbacks never collide.
  vault_instances.instances.clear()
  vault_instances.ws_gen.clear()
  vault_instances.vault_gen.clear()
}

///|
/// Opens an item (`vault.open`: the system's prompt first where its vault is locked here) for a specific `VaultItem`
/// page instance, then invokes `then` with its plaintext. The async callback strictly verifies
/// `(page_instance_id, pending_id, account, workspace, vault_gen)` and `active()` before mutating any state.
pub fn open_item(
  instance_id : Int,
  core : Core,
  scope_now : () -> VaultScope,
  active : () -> Bool,
  then : (Json) -> Unit,
  reveal? : String = "",
) -> Unit {
  guard vault_instances.instances.get(instance_id) is Some(inst) else { return }
  guard inst.alive && @signals.untracked(active) else { return }
  let captured = @signals.untracked(scope_now)
  if inst.scope != captured {
    inst.scope = captured
    invalidate_vault_instance(inst)
  }
  if inst.in_flight is Some(_) {
    return
  }
  let pid = next_vault_pending()
  inst.pending_id = pid
  inst.in_flight = Some(pid)
  inst.opening.set(true)
  if reveal != "" {
    inst.reveal_field.set(Some(reveal))
    inst.shown.set(reveal, true)
  } else {
    inst.reveal_field.set(None)
  }
  (core.call)("vault.open", obj([("workspace", str(captured.workspace)), ("item", str(captured.item))]), fn(r) {
    guard vault_instances.instances.get(instance_id) is Some(cur) else { return }
    guard cur.alive && @signals.untracked(active) else { return }
    guard cur.in_flight == Some(pid) && cur.pending_id == pid else { return }
    let live_scope = @signals.untracked(scope_now)
    guard cur.scope == captured && live_scope == captured else { return }
    guard vault_gen_of(captured.workspace, captured.vault) == captured.vault_gen else { return }
    cur.in_flight = None
    match r {
      Ok(v) =>
        match field(Some(v), "plain") {
          Some(Object(_) as p) => {
            // Update fields and plain atomically in one batch so VaultItem's fs.pick never renders an empty
            // opened-fields frame between setting plain and fields (which would bounce following rows).
            vault_batched(fn() {
              cur.opening.set(false)
              cur.reveal_field.set(None)
              cur.fields.set(items(Some(v), "shown"))
              cur.plain.set(Some(p))
            })
            then(p)
          }
          _ =>
            vault_batched(fn() {
              cur.opening.set(false)
              cur.reveal_field.set(None)
            })
        }
      Err(e) => {
        vault_batched(fn() {
          cur.opening.set(false)
          cur.reveal_field.set(None)
          if reveal != "" {
            cur.shown.remove(reveal)
          }
        })
        match vault_said(e) {
          Some(why) =>
            (core.say)(fill("android-misc.act.failed", [("what", tr("android-settings.vault.openWhat")), ("error", why)]))
          None => ()
        }
      }
    }
  })
}

///|
/// Whether `instance_id` is still alive and remains on navigation `stay_id` (used to guard delayed `core.pop()` after
/// async delete).
pub fn vault_instance_alive_stay(instance_id : Int, stay_id : Int) -> Bool {
  match vault_instances.instances.get(instance_id) {
    Some(inst) => inst.alive && inst.scope.stay_id == stay_id
    None => false
  }
}

///|
/// Plaintext opened for `instance_id`, if any.
pub fn opened_plain(instance_id : Int) -> Json? {
  match vault_instances.instances.get(instance_id) {
    Some(inst) if inst.alive => inst.plain.get()
    _ => None
  }
}

///|
/// Shown fields (`vault.open`'s `shown`) for `instance_id`.
pub fn opened_fields(instance_id : Int) -> Array[Json] {
  match vault_instances.instances.get(instance_id) {
    Some(inst) if inst.alive => inst.fields.get()
    _ => []
  }
}

///|
/// Whether `instance_id` currently has an in-flight `vault.open`.
pub fn item_opening(instance_id : Int) -> Bool {
  match vault_instances.instances.get(instance_id) {
    Some(inst) if inst.alive => inst.opening.get()
    _ => false
  }
}

///|
/// The field whose eye is currently opening `instance_id` (None when not opening via a field's eye).
pub fn item_reveal(instance_id : Int) -> String? {
  match vault_instances.instances.get(instance_id) {
    Some(inst) if inst.alive => inst.reveal_field.get()
    _ => None
  }
}

///|
/// Whether `field_key` is currently unmasked in `instance_id`.
pub fn item_field_shown(instance_id : Int, field_key : String) -> Bool {
  match vault_instances.instances.get(instance_id) {
    Some(inst) if inst.alive => inst.shown.get(field_key).unwrap_or(false)
    _ => false
  }
}

///|
/// Sets whether `field_key` is unmasked in `instance_id`.
pub fn item_field_set_shown(instance_id : Int, field_key : String, shown : Bool) -> Unit {
  match vault_instances.instances.get(instance_id) {
    Some(inst) if inst.alive => inst.shown.set(field_key, shown)
    _ => ()
  }
}

///|
pub let vault_serial : Ref[Int] = Ref(0)

///|
/// What `vault.putItem` is given for an item: the vault, the item's id where it is one already, what
/// it holds (`words`: its fields' words by name, as typed; `about`, what it is for, its notes), and, where agents may
/// ask for it, how (`mode`, its hosts, its variable), its longest grant (`lasts`: "default" its vault's) and its about.
pub fn vault_put_params(
  vault : String,
  row : Json?,
  was : Json?,
  k : String,
  words : Map[String, String],
  agent : Bool,
  mode : String,
  lasts : String,
) -> Array[(String, Json)] {
  let got = fn(f : String) { words.get(f).unwrap_or("").trim(chars=" \n").to_owned() }
  let name = words.get("name").unwrap_or("").trim(chars=" ").to_owned()
  // (an editor without the field keeps the notes it had)
  let about = match words.get("about") {
    Some(a) => a.trim(chars=" \n").to_owned()
    None => text(was, "notes")
  }
  let fields : Array[(String, Json)] = []
  for f in vault_fields(k) {
    // a private key as pasted (its last line break is part of it); the rest without the spaces around them
    let v = if f == "private_key" || f == "content" { words.get(f).unwrap_or("") } else { got(f) }
    if v.trim(chars=" \n") != "" {
      fields.push((f, str(v)))
    }
  }
  let plain_item = obj([
    ("kind", str(k)),
    ("name", str(name)),
    ("fields", obj(fields)),
    ("domains", Json::array(strings(was, "domains").map(str))),
    ("notes", str(about)),
  ])
  let params = [("vault", str(vault)), ("plain", plain_item)]
  match row {
    Some(r) => params.push(("id", str(text(Some(r), "id"))))
    None => ()
  }
  if agent {
    let modes = match k {
      "ssh_key" => ["ssh"]
      "file" => ["file"]
      "browser" => ["browser"]
      _ => [mode]
    }
    let listing = [
      ("name", str(name)),
      ("kind", str(k)),
      ("modes", Json::array(modes.map(str))),
      ("hosts", Json::array((if modes == ["proxy"] || modes == ["browser"] { vault_hosts(words) } else { [] }).map(str))),
    ]
    let env = got("env")
    if env != "" && k != "ssh_key" && k != "browser" {
      listing.push(("env", str(env)))
    }
    // its own longest grant (none: its vault's)
    if lasts != "default" {
      listing.push(("lasts", str(lasts)))
    }
    if about != "" {
      listing.push(("about", str(about)))
    }
    params.push(("listing", obj(listing)))
  }
  params
}

///|
/// The hosts typed (`words`' hosts: by commas, spaces or lines).
pub fn vault_hosts(words : Map[String, String]) -> Array[String] {
  let out : Array[String] = []
  for h in words.get("hosts").unwrap_or("").replace_all(old=",", new=" ").replace_all(old="\n", new=" ").split(" ") {
    if h != "" {
      out.push(h.to_owned())
    }
  }
  out
}

///|
/// Whether an item's words can be saved: its name, what its kind needs, and the hosts where a
/// proxy gives it; the problem's name, or "" none.
pub fn vault_problem(k : String, words : Map[String, String], agent : Bool, mode : String) -> String {
  let got = fn(f : String) { words.get(f).unwrap_or("").trim(chars=" \n").to_owned() }
  let filled_in = match k {
    "token" => got("value") != ""
    "ssh_key" => got("private_key") != ""
    "file" => got("content") != ""
    "browser" => got("cookies") != ""
    _ => got("username") != "" || got("password") != ""
  }
  if got("name") == "" {
    "name"
  } else if !filled_in {
    "fields"
  } else if agent && ((mode == "proxy" && k != "ssh_key" && k != "file") || k == "browser") && vault_hosts(words).length() == 0 {
    "hosts"
  } else {
    ""
  }
}
