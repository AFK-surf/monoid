// station/src/models/module.ts: the model catalog kept up to date, as a part of the station: what models can do and
// cost as still.fail cloud says (GET /v1/models, cloud/src/models.ts), told to `Catalog` for the prices and the image
// check to read. Asked for in the background, never held up for: at the start, and as the cloud says the catalog
// changed (its presence socket), naming the ETag it changed to. Revalidated with its ETag, and kept in
// model-catalog.json under the station's data: what the station says from its start until the cloud answers. Models it
// names that it did not before are told to the accounts, which check their makers' profiles again.

///|
pub struct ModelCatalog {
  priv mut etag : String?
  priv mut asking : @effect.Deferred[Unit]?
  /// Asked for again while an ask went on: asked once more after it.
  priv mut again : Bool
  priv mut writing : @effect.Deferred[Unit]?
  priv file : String
  priv origin : () -> String?
  priv get : async (Request) -> Response
  priv added : (Array[String]) -> Unit
  priv learned : () -> Unit
  priv catalog : Catalog
  priv io : Io
}

///|
/// `file`: where it is kept; `origin`: still.fail cloud's, none when the station is in no still.fail cloud; `get`: how
/// it is asked (the network's fetch); `added`: told the keys of the models a catalog the cloud sent names that the one
/// before did not (none the first time); `learned`: called after a catalog is learned from disk or the cloud. What was
/// kept is read first.
pub async fn ModelCatalog::open(
  io : Io,
  catalog : Catalog,
  file : String,
  origin : () -> String?,
  asker? : async (Request) -> Response,
  added? : (Array[String]) -> Unit = _ => (),
  learned? : () -> Unit = () => (),
) -> ModelCatalog {
  let m : ModelCatalog = {
    etag: None,
    asking: None,
    again: false,
    writing: None,
    file,
    origin,
    get: match asker {
      Some(g) => g
      None => io.fetch
    },
    added,
    learned,
    catalog,
    io,
  }
  // None kept yet, or unreadable: the station's own tables answer until the cloud does.
  let text = (io.read)(file) catch { _ => return m }
  match parse_or_none(text) {
    Some(kept) => {
      if catalog.learn(get(Some(kept), "models")) > 0 {
        (m.learned)()
      }
      if str_of(get(Some(kept), "etag")) is Some(e) {
        m.etag = Some(e)
      }
    }
    None => ()
  }
  m
}

///|
/// Asks the cloud for what changed: `etag`, the catalog it said it changed to (asked for by it, past what a cache on
/// the way kept). One ask at a time; asked again while one goes on, asked once more after it.
pub async fn ModelCatalog::refresh(self : ModelCatalog, etag? : String) -> Unit {
  if etag is Some(_) && etag == self.etag {
    if self.asking is Some(d) {
      d.wait()
    }
    return
  }
  match self.asking {
    Some(d) => {
      self.again = true
      d.wait()
    }
    None => self.start(etag).wait()
  }
}

///|
fn ModelCatalog::start(self : ModelCatalog, etag : String?) -> @effect.Deferred[Unit] {
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.asking = Some(d)
  (self.io.spawn)(async fn() {
    self.ask(etag) catch {
      error =>
        (self.io.log)("info", "models", "the model catalog was not read", { "error": Json::string(message_of(error)) })
    }
    self.asking = None
    if self.again {
      self.again = false
      ignore(self.start(None))
    }
    ignore(d.succeed(()))
  })
  d
}

///|
async fn ModelCatalog::ask(self : ModelCatalog, etag : String?) -> Unit {
  guard (self.origin)() is Some(origin) else { return }
  let headers = [("user-agent", "stillfail-station")]
  if self.etag is Some(e) {
    headers.push(("if-none-match", e))
  }
  let v = match etag {
    Some(e) => "?v=\{@url.encode_uri_component(e)}"
    None => ""
  }
  let response = (self.get)({
    url: "\{origin}/v1/models\{v}",
    method_: "GET",
    headers,
    body: None,
    timeout_ms: 30_000,
    manual: false,
  })
  if response.status == 304 {
    return
  }
  if !response.ok() {
    raise Failed("still.fail cloud answered \{response.status}")
  }
  let body = parse_json(response.body)
  let before = self.catalog.named()
  let models = get(Some(body), "models")
  let named = self.catalog.learn(models)
  let added = if before.length() == 0 {
    []
  } else {
    self.catalog.named().filter(k => !before.contains(k))
  }
  self.etag = response.header("etag")
  // One ask at a time (`refresh`), so in order.
  let w : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.writing = Some(w)
  let kept : Json = {
    "etag": opt(self.etag),
    "models": match models {
      None | Some(Null) => Json::object({})
      Some(m) => m
    },
  }
  let wrote = (self.io.write_private)(self.file, stringify(kept)) catch { e => Some(e) } noraise { _ => None }
  self.writing = None
  ignore(w.succeed(()))
  if wrote is Some(e) {
    raise e
  }
  (self.io.log)("info", "models", "the model catalog was read", { "models": Json::number(named.to_double()) })
  (self.learned)()
  if added.length() > 0 {
    (self.added)(added)
  }
}

///|
/// Once what it read of the cloud is written (the station stopping).
pub async fn ModelCatalog::written(self : ModelCatalog) -> Unit {
  if self.writing is Some(w) {
    w.wait()
  }
}

///|
/// The part as the station puts it together (`ModelsLive`): the catalog read at once in the background, and again each
/// time the cloud says it changed (`told`: a handler given what the plane said, `type` and `etag`).
pub async fn models_live(
  io : Io,
  catalog : Catalog,
  data : String,
  origin : () -> String?,
  told : ((Json) -> Unit) -> Unit,
  added : (Array[String]) -> Unit,
) -> ModelCatalog {
  let m = ModelCatalog::open(io, catalog, join([data, "model-catalog.json"]), origin, added~)
  ignore((io.after)(0L, () => (io.spawn)(async fn() { m.refresh() })))
  told(said => (io.spawn)(async fn() {
    match (get(Some(said), "type"), str_of(get(Some(said), "etag"))) {
      (Some(String("models")), Some(e)) => m.refresh(etag=e)
      (Some(String("models")), None) => m.refresh()
      _ => m.refresh()
    }
  }))
  m
}
