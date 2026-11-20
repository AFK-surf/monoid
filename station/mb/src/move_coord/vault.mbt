// The vault module (station/src/move/vault.ts; move/AGENTS.md): an item is one owner's secrets kept on this station
// (`vault:<email>@<ws>`): their plain library's items and the vaults they own with their items (ciphertext only).
// Moved: the other station holds them too, sent a page at a time (`move.vault.put`). Moved back: the other lets go of
// exactly what this move put there (`move/vaults.json` there), never what it had. Grants are not moved.

///|
let vault_page : Int = 200

///|
pub fn vault_item_id(owner : String) -> String {
  "vault:\{owner}"
}

///|
/// The plain library (vault/plain.ts) and the vaults (vault/store.ts) of this station.
pub(all) struct VaultStores {
  plain_items : async (String, String) -> Array[J]
  plain_item : async (String, String) -> J?
  plain_put : async (J) -> Unit
  plain_forget : async (String, String) -> Unit
  vaults : async (String) -> Array[J]
  vault : async (String, String) -> J?
  items : async (String, String) -> Array[J]
  item : async (String, String, String) -> J?
  put_vault : async (J) -> Unit
  put_item : async (J) -> Unit
  forget_item : async (String, String, String) -> Unit
  forget_vault : async (String, String) -> Unit
}

///|
pub(all) struct VaultDeps {
  data : String
  owners : async (String) -> Array[String]
  stores : VaultStores
  ask : async (String, J) -> J
  disk : Disk
}

///|
pub struct Vault {
  priv d : VaultDeps
  priv moved : KeptSet
  priv mut put : J
}

///|
pub fn Vault::new(d : VaultDeps) -> Vault {
  {
    d,
    moved: KeptSet::new(d.disk, move_path(d.data, "vault-moved.json")),
    put: read_move_json(d.disk, d.data, "vaults.json"),
  }
}

///|
fn vault_of(item : J) -> (String, String) {
  let rest = slice_from(item_id(item), 6)
  let at = last_index_of(rest, "@")
  if at < 0 {
    (slice(rest, 0, rest.length() - 1), rest)
  } else {
    (slice(rest, 0, at), slice_from(rest, at + 1))
  }
}

///|
fn pages(items : Array[J]) -> Array[Array[J]] {
  let out = []
  let mut i = 0
  while i < items.length() || i == 0 {
    let end = if i + vault_page > items.length() { items.length() } else { i + vault_page }
    out.push(if i < end { items[i:end].to_array() } else { [] })
    i += vault_page
  }
  out
}

///|
pub fn Vault::module(self : Vault) -> Module {
  simple_module(
    "vault",
    self.moved,
    async fn(ws, _to, _reads) {
      (self.d.owners)(ws).map(owner => new_item(
        "vault",
        "\{vault_item_id(owner)}@\{ws}",
        "\{owner}'s secrets",
        [],
      ))
    },
    async fn(item, to, _progress, _arrive) {
      let (owner, ws) = vault_of(item)
      let plain = (self.d.stores.plain_items)(ws, owner)
      for page in pages(plain) {
        ignore(
          (self.d.ask)(
            to,
            jo([
              ("method", js("move.vault.put")),
              ("workspace", js(ws)),
              ("ws", js(ws)),
              ("owner", js(owner)),
              ("plain", ja(page)),
            ]),
          ),
        )
      }
      for v in (self.d.stores.vaults)(ws) {
        if text(get(Some(v), "owner")) != Some(owner) {
          continue
        }
        let items = (self.d.stores.items)(ws, text(get(Some(v), "id")).unwrap_or(""))
        for page in pages(items) {
          ignore(
            (self.d.ask)(
              to,
              jo([
                ("method", js("move.vault.put")),
                ("workspace", js(ws)),
                ("ws", js(ws)),
                ("owner", js(owner)),
                ("vault", v),
                ("items", ja(page)),
              ]),
            ),
          )
        }
      }
      self.moved.add(item_id(item))
    },
    async fn(item, from, _arrive) {
      let (owner, ws) = vault_of(item)
      ignore(
        (self.d.ask)(
          from,
          jo([
            ("method", js("move.vault.back")),
            ("workspace", js(ws)),
            ("ws", js(ws)),
            ("owner", js(owner)),
          ]),
        ),
      )
      self.moved.delete(item_id(item))
    },
  )
}

///|
async fn Vault::save(self : Vault) -> Unit {
  write_move_json(self.d.disk, self.d.data, "vaults.json", self.put)
}

///|
fn first_page(xs : Array[J]) -> Array[J] {
  if xs.length() > vault_page {
    xs[0:vault_page].to_array()
  } else {
    xs
  }
}

///|
/// What another station asks of this one's vaults (`move.vault.*`).
pub async fn Vault::answer(self : Vault, request : J) -> J {
  let ws = text(get(Some(request), "ws")).unwrap_or("")
  let owner = text(get(Some(request), "owner")).unwrap_or("")
  if ws == "" || owner == "" {
    raise Refused("no owner named")
  }
  let key = "\{ws}\u{0}\{owner}"
  if get(Some(self.put), key) is None {
    self.put = set(
      self.put,
      key,
      jo([("plain", ja([])), ("vaults", ja([])), ("items", ja([]))]),
    )
  }
  let put_of = () => get(Some(self.put), key).unwrap()
  let list = (k : String) => arr(get(Some(put_of()), k)).unwrap_or([])
  let push = (k : String, v : J) => {
    let l = list(k).copy()
    l.push(v)
    self.put = set(self.put, key, set(put_of(), k, ja(l)))
  }
  let ok = jo([("ok", jb(true))])
  match text(get(Some(request), "method")) {
    Some("move.vault.put") => {
      for i in first_page(arr(get(Some(request), "plain")).unwrap_or([])) {
        if text(get(Some(i), "ws")) != Some(ws) || text(get(Some(i), "owner")) != Some(owner) {
          continue
        }
        let id = text(get(Some(i), "id")).unwrap_or("")
        let had = (self.d.stores.plain_item)(ws, id)
        match had {
          Some(h) =>
            match (num(get(Some(h), "version")), num(get(Some(i), "version"))) {
              (Some(a), Some(b)) if a >= b => continue
              _ => ()
            }
          None => ()
        }
        if had is None && !list("plain").iter().any(x => text(Some(x)) == Some(id)) {
          push("plain", js(id))
        }
        (self.d.stores.plain_put)(i)
      }
      match get(Some(request), "vault") {
        Some(Obj(_) as v) if text(get(Some(v), "ws")) == Some(ws) &&
          text(get(Some(v), "owner")) == Some(owner) => {
          let vid = text(get(Some(v), "id")).unwrap_or("")
          match (self.d.stores.vault)(ws, vid) {
            None => {
              if !list("vaults").iter().any(x => text(Some(x)) == Some(vid)) {
                push("vaults", js(vid))
              }
              (self.d.stores.put_vault)(v)
            }
            Some(had) =>
              if num(get(Some(had), "seq")).unwrap_or(0.0) < num(get(Some(v), "seq")).unwrap_or(0.0) {
                (self.d.stores.put_vault)(v)
              }
          }
          for i in first_page(arr(get(Some(request), "items")).unwrap_or([])) {
            if text(get(Some(i), "ws")) != Some(ws) || text(get(Some(i), "vault")) != Some(vid) {
              continue
            }
            let iid = text(get(Some(i), "id")).unwrap_or("")
            let was = (self.d.stores.item)(ws, vid, iid)
            match was {
              Some(w) if num(get(Some(w), "version")).unwrap_or(0.0) >=
                num(get(Some(i), "version")).unwrap_or(0.0) => continue
              _ => ()
            }
            if was is None &&
              !list("items").iter().any(x => same(Some(x), Some(jstrs([vid, iid])))) {
              push("items", jstrs([vid, iid]))
            }
            (self.d.stores.put_item)(i)
          }
        }
        _ => ()
      }
      self.save()
      ok
    }
    Some("move.vault.back") => {
      for id in list("plain") {
        (self.d.stores.plain_forget)(ws, text(Some(id)).unwrap_or(""))
      }
      for p in list("items") {
        let a = arr(Some(p)).unwrap_or([])
        (self.d.stores.forget_item)(
          ws,
          text(a.get(0)).unwrap_or(""),
          text(a.get(1)).unwrap_or(""),
        )
      }
      for id in list("vaults") {
        (self.d.stores.forget_vault)(ws, text(Some(id)).unwrap_or(""))
      }
      self.put = del(self.put, key)
      self.save()
      ok
    }
    _ => raise Refused("no such vault request")
  }
}
