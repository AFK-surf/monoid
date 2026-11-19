// The station's control plane (station/src/cloud/plane.ts): what it is told by, and tells, whoever keeps its workspace.
// One shape for every provider: the presence socket, notices, traces and the log, where its releases are and which
// member credentials it takes. still.fail's requests go by its transport (an entry where one is named), every other
// provider's by themselves; each is signed with the station's key over its body's hash (signed.ts).

///|
pub(all) struct HttpRequest {
  url : String
  http_method : String
  headers : Headers
  body : String?
  timeout_ms : Int
}

///|
pub(all) struct HttpResponse {
  status : Int
  body : String
}

///|
/// How HTTP is asked: by itself, or on a TLS socket a dial made (an entry's).
pub(all) struct Http {
  fetch : async (HttpRequest) -> HttpResponse
  over : async (HttpRequest, TlsSocket) -> HttpResponse
}

///|
/// The sockets an entry's dials made, kept for the next request: a request's cancellation never owns a dial, whose
/// socket comes here whoever waited for it.
pub struct Pool {
  priv idle : Array[TlsSocket]
}

///|
pub fn Pool::new() -> Pool {
  { idle: [] }
}

///|
/// A request through the transport: still.fail's canonical origin with an entry named goes on a socket of the pool's
/// (one dialed with `http_budget` where none is idle), every other by itself.
pub async fn CloudTransport::fetch(
  self : CloudTransport,
  http : Http,
  pool : Pool,
  req : HttpRequest,
) -> HttpResponse {
  if self.closed {
    raise NetError("cloud transport closed")
  }
  if !self.eligible(req.url) {
    return (http.fetch)(req)
  }
  let socket = match pool.idle.pop() {
    Some(s) => s
    None => {
      let got : @effect.Deferred[TlsSocket] = @effect.Deferred::new()
      let gave_up = Ref(false)
      ignore(
        self.dial(http_budget, r => match r {
          Ok(s) =>
            // (the one who asked gone: kept for the next)
            if gave_up.val || !got.succeed(s) {
              pool.idle.push(s)
            }
          Err(e) => ignore(got.fail(NetError(failure_text(e))))
        }),
      )
      // A request's cancellation never owns the dial: what it makes is the pool's once nobody waits for it.
      let taken = Ref(false)
      defer {
        if !taken.val {
          gave_up.val = true
          match (try got.poll() catch { _ => None }) {
            Some(s) => pool.idle.push(s)
            None => ()
          }
        }
      }
      let s = got.wait()
      taken.val = true
      s
    }
  }
  let answer = (http.over)(req, socket)
  pool.idle.push(socket)
  answer
}

///|
/// What a station posts to its control plane signed with its key: the body's sha256 under
/// "<tag>:<origin>:<station>:<ts>:<digest>", in the x-stillfail-* headers; the answer's JSON (None for none).
pub async fn signed_post(
  state : CloudView,
  sign : (String) -> String,
  now_secs : Int64,
  path : String,
  tag : String,
  value : Json,
  name : String,
  request : async (HttpRequest) -> HttpResponse,
) -> Json? {
  guard (state.station)() is Some(station) else {
    raise NetError("this station is not in \{name}")
  }
  let origin = (state.origin)().unwrap_or("")
  let body = value.stringify()
  let ts = now_secs
  let signature = sign("\{tag}:\{origin}:\{station}:\{ts}:\{@hash.sha256_utf8_hex(body)}")
  let headers = Headers::new()
  headers.set("content-type", "application/json")
  headers.set("x-stillfail-station", station)
  headers.set("x-stillfail-ts", ts.to_string())
  headers.set("x-stillfail-signature", signature)
  let response = request({
    url: origin + path,
    http_method: "POST",
    headers,
    body: Some(body),
    timeout_ms: 30_000,
  })
  if response.status < 200 || response.status > 299 {
    raise NetError("\{name} answered \{response.status}: \{response.body}")
  }
  if response.body == "" {
    None
  } else {
    Some(@json.parse(response.body))
  }
}

///|
/// The traces' body (traces.ts `otlpBody`).
pub fn otlp_body(station : String, spans : Array[Json]) -> String {
  let attribute = (key : String, value : String) => Json::object({
    "key": Json::string(key),
    "value": { "stringValue": Json::string(value) },
  })
  let body : Json = {
    "resourceSpans": [
      {
        "resource": {
          "attributes": [
            attribute("service.name", "stillfail-mesh"),
            attribute("stillfail.station", station),
          ],
        },
        "scopeSpans": [
          { "scope": { "name": "stillfail-mesh" }, "spans": Json::array(spans) },
        ],
      },
    ],
  }
  body.stringify()
}

///|
/// The control plane, as the station's parts see it.
pub struct ControlPlane {
  state : CloudView
  /// The provider fixed, or None: as cloud.json says, read anew at each use.
  priv fixed : Provider?
  priv provider_now : () -> Provider
  priv sign : (String) -> String
  priv now_secs : () -> Int64
  priv transport : CloudTransport
  priv http : Http
  priv pool : Pool
  priv listeners : Array[(String, (CloudSaid) -> Unit)]
}

///|
pub fn ControlPlane::new(
  state : CloudView,
  provider_now : () -> Provider,
  sign : (String) -> String,
  now_secs : () -> Int64,
  transport : CloudTransport,
  http : Http,
  provider? : Provider,
) -> ControlPlane {
  {
    state,
    fixed: provider,
    provider_now,
    sign,
    now_secs,
    transport,
    http,
    pool: Pool::new(),
    listeners: [],
  }
}

///|
/// The provider spoken to now.
pub fn ControlPlane::spec(self : ControlPlane) -> ProviderSpec {
  spec_of(
    match self.fixed {
      Some(p) => p
      None => (self.provider_now)()
    },
  )
}

///|
/// What the provider tells besides its state, as it does: each listener of its kind told, one that fails leaving the
/// others told.
pub fn ControlPlane::said(self : ControlPlane, event : CloudSaid) -> Unit {
  let kind = match event {
    Release => "release"
    Models(_) => "models"
  }
  for l in self.listeners {
    if l.0 == kind {
      (l.1)(event)
    }
  }
}

///|
pub fn ControlPlane::told(
  self : ControlPlane,
  kind : String,
  f : (CloudSaid) -> Unit,
) -> Unit {
  self.listeners.push((kind, f))
}

///|
async fn ControlPlane::request(
  self : ControlPlane,
  plane : ProviderSpec,
  req : HttpRequest,
) -> HttpResponse {
  if plane.provider is Stillfail {
    self.transport.fetch(self.http, self.pool, req)
  } else {
    (self.http.fetch)(req)
  }
}

///|
/// A batch of notices (at most 50) for people's devices; `workspace`: a joined one's, None the home one's.
pub async fn ControlPlane::notify(
  self : ControlPlane,
  notices : Array[Json],
  workspace? : String,
) -> Unit {
  let plane = self.spec()
  let value : Json = match workspace {
    None => { "notices": Json::array(notices) }
    Some(ws) => { "notices": Json::array(notices), "workspace": Json::string(ws) }
  }
  ignore(
    signed_post(
      self.state,
      self.sign,
      (self.now_secs)(),
      plane.notify_path,
      plane.notify_tag,
      value,
      plane.name,
      req => self.request(plane, req),
    ),
  )
}

///|
/// A batch of telemetry posted where the provider says (`logs`: the log's path, else the traces'), signed like the
/// presence socket over its body's hash; dropped where it takes none.
async fn ControlPlane::telemetry(
  self : ControlPlane,
  logs : Bool,
  made : (String) -> String,
) -> Unit {
  let plane = self.spec()
  guard plane.telemetry is Some(t) else { return }
  let to = if logs { t.logs } else { Some(t.path) }
  guard to is Some(to) else { return }
  guard (self.state.station)() is Some(station) else { return }
  let origin = (self.state.origin)().unwrap_or("")
  let body = made(station)
  let ts = (self.now_secs)()
  let digest = @hash.sha256_utf8_hex(body)
  let headers = signed_headers(t.prefixes, station, ts, prefix => (self.sign)(
    "\{prefix}-station-telemetry-v1:\{origin}:\{station}:\{ts}:\{digest}",
  ))
  let all = Headers::new()
  all.set("content-type", "application/json")
  for kv in headers.pairs {
    all.set(kv.0, kv.1)
  }
  let response = self.request(plane, {
    url: origin + to,
    http_method: "POST",
    headers: all,
    body: Some(body),
    timeout_ms: 30_000,
  })
  if response.status < 200 || response.status > 299 {
    raise NetError("\{plane.name} answered \{response.status}")
  }
}

///|
/// A batch of the mesh's spans.
pub async fn ControlPlane::traces(self : ControlPlane, spans : Array[Json]) -> Unit {
  self.telemetry(false, station => otlp_body(station, spans))
}

///|
/// A batch of the station's log (OTLP JSON).
pub async fn ControlPlane::logs(self : ControlPlane, body : String) -> Unit {
  self.telemetry(true, _ => body)
}

///|
/// Where the station's releases and installer are, while in a workspace.
pub fn ControlPlane::release_base(self : ControlPlane) -> String? {
  match (self.state.origin)() {
    Some(o) if o != "" => Some(self.spec().release_base(o))
    _ => None
  }
}

///|
/// Which member credentials the station takes now.
pub fn ControlPlane::credential(self : ControlPlane) -> Accepted {
  self.spec().credential
}

///|
/// A body posted to the control plane at `path`, signed under `tag` (signed.ts `signedPost`, the feedback's): its
/// answer's JSON, None for none.
pub async fn ControlPlane::signed(self : ControlPlane, path : String, tag : String, value : Json) -> Json? {
  let plane = self.spec()
  signed_post(self.state, self.sign, (self.now_secs)(), path, tag, value, plane.name, req => self.request(plane, req))
}

///|
/// The SHA-256 of `text`'s UTF-8, hex (key.ts `sha256hex`): `@hash.sha256_utf8_hex`'s, kept here for what calls it by
/// this package.
pub fn sha256_hex(text : String) -> String {
  @hash.sha256_utf8_hex(text)
}
