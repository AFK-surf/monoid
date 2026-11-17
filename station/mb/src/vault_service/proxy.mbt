// The keeper's proxy (station/src/vault/proxy.ts, 三种用法 › 代理): a command run with a grant gets HTTPS_PROXY pointing
// here, with credentials that name its run, and the grant's placeholder (`stillfail-secret:<grant>`) where its token
// goes. HTTPS to one of the grant's hosts is opened here (with a certificate of the keeper's CA, which the command is
// told to trust) so the placeholder in the request's headers can be replaced with the secret on its way out; nothing
// else of the request or the answer is touched. HTTPS to any other host is passed through as it is, unopened. Plain
// HTTP is refused. What is decided is here; the sockets and TLS are the machine's (machine.mbt `proxy_listen`).

///|
/// What stands for a grant's secret in what a command sends.
pub fn placeholder(grant : String) -> String {
  "stillfail-secret:" + grant
}

///|
/// A command's run through the proxy (proxy.ts `Run`).
pub(all) struct ProxyRun {
  hosts : Array[String]
  placeholder : String
  value : String
  used : (String) -> Unit
  allowed : () -> Bool
}

///|
let ca_name : String = "still.fail station vault"

///|
/// Leaf certificates are made again a day before the week they are good for runs out.
let leaf_ms : Double = 6.0 * 86400000.0

///|
let hop : Array[String] = [
  "proxy-authorization", "proxy-connection", "connection", "keep-alive", "te", "trailer",
  "transfer-encoding", "upgrade",
]

///|
/// Whether `s` is base64 as `/^[A-Za-z0-9+/=]+$/` has it.
fn base64_chars(s : String) -> Bool {
  if s == "" {
    return false
  }
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    if !((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 43 || c == 47 || c == 61) {
      return false
    }
  }
  true
}

///|
/// `/^(Basic\s+)(…)$/i`: the prefix with its spaces and what follows, where `text` is so.
fn basic_parts(text : String) -> (String, String)? {
  if text.length() < 6 || lower(slice(text, 0, b=5)) != "basic" {
    return None
  }
  let mut i = 5
  while i < text.length() && js_space(text.code_unit_at(i).to_int()) {
    i += 1
  }
  if i == 5 {
    return None
  }
  Some((slice(text, 0, b=i), slice(text, i)))
}

///|
/// `text` with the placeholder replaced by the value, also inside an `Authorization: Basic` pair.
pub fn swap(text : String, placeholder : String, value : String) -> String {
  if basic_parts(text) is Some((prefix, b)) && base64_chars(b) {
    let pair = utf8_text(@vault_crypto.unb64(b))
    if contains(pair, placeholder) {
      return prefix + @vault_crypto.b64(utf8_of(replace_all(pair, placeholder, value)))
    }
  }
  replace_all(text, placeholder, value)
}

///|
/// The keeper's proxy: its runs by token, its CA, its leaf certificates by host.
pub struct Proxy {
  machine : Machine
  dir : String
  now : () -> Double
  runs : Map[String, (Int, ProxyRun)]
  by_number : Map[Int, ProxyRun]
  mut next_run : Int
  leaves : Map[String, (String, Double)]
  mut ca : (Bytes, KeyRef)?
  mut port : Int
  mut listening : Bool
  /// What waits for a start under way: a second start meanwhile waits for the same port.
  mut starting : @effect.Deferred[Int]?
}

///|
/// `dir`: where the CA is kept (made there the first time); `now`: milliseconds.
pub fn Proxy::new(machine : Machine, dir : String, now : () -> Double) -> Proxy {
  {
    machine,
    dir,
    now,
    runs: Map([]),
    by_number: Map([]),
    next_run: 0,
    leaves: Map([]),
    ca: None,
    port: 0,
    listening: false,
    starting: None,
  }
}

///|
/// The CA bundle a command is told to trust: the usual roots and the keeper's CA.
pub fn Proxy::bundle(self : Proxy) -> String {
  self.dir + "/ca-bundle.pem"
}

///|
/// The PEM of a certificate's DER (begun, its base64 in lines of 64, ended).
pub fn pem(der : Bytes, label? : String = "CERTIFICATE") -> String {
  let b = @vault_crypto.b64(der)
  let out = StringBuilder()
  out.write_string("-----BEGIN \{label}-----\n")
  let mut i = 0
  while i < b.length() {
    out.write_string(slice(b, i, b=(i + 64).min(b.length())))
    out.write_char('\n')
    i += 64
  }
  out.write_string("-----END \{label}-----\n")
  out.to_string()
}

///|
/// A certificate's DER from its PEM (`cert.replace(/-----[^-]+-----|\s+/g, "")` read as base64).
fn der_of_pem(text : String) -> Bytes {
  let b = StringBuilder()
  let n = text.length()
  let mut i = 0
  while i < n {
    if i + 5 <= n && slice(text, i, b=i + 5) == "-----" {
      // a run of 5 dashes, then non-dashes, then 5 dashes
      let mut j = i + 5
      while j < n && text.code_unit_at(j) != '-' {
        j += 1
      }
      if j > i + 5 && j + 5 <= n && slice(text, j, b=j + 5) == "-----" {
        i = j + 5
        continue
      }
    }
    let c = text.code_unit_at(i).to_int()
    if !js_space(c) {
      b.write_char(c.unsafe_to_char())
    }
    i += 1
  }
  @vault_crypto.unb64(b.to_string())
}

///|
/// The CA, read from `dir` or made there the first time, and the bundle written beside it.
async fn Proxy::load_ca(self : Proxy) -> (Bytes, KeyRef) {
  if self.ca is Some(ca) {
    return ca
  }
  (self.machine.mkdir)(self.dir, 0o700)
  let key_path = self.dir + "/ca.key"
  let cert_path = self.dir + "/ca.pem"
  let key = (self.machine.read_file)(key_path)
  let cert = (self.machine.read_file)(cert_path)
  let ca = match (key, cert) {
    (Some(k), Some(c)) =>
      match (self.machine.key_of_pem)(utf8_text(k)) {
        Some(kr) => (der_of_pem(utf8_text(c)), kr)
        None => raise Failure("the vault's CA key is unreadable")
      }
    _ => {
      let made = make_ca(self.machine, (self.now)(), ca_name)
      (self.machine.write_file)(key_path, utf8_of((self.machine.key_pem)(made.1)), 0o600)
      (self.machine.chmod)(key_path, 0o600)
      (self.machine.write_file)(cert_path, utf8_of(pem(made.0)), 0o644)
      made
    }
  }
  (self.machine.write_file)(
    self.bundle(),
    utf8_of(join([..(self.machine.roots)(), pem(ca.0)], "\n")),
    0o644,
  )
  self.ca = Some(ca)
  ca
}

///|
/// Listens on 127.0.0.1 (any free port); the port.
pub async fn Proxy::start(self : Proxy) -> Int {
  if self.listening {
    return self.port
  }
  match self.starting {
    Some(d) => return d.wait()
    None => ()
  }
  let d : @effect.Deferred[Int] = @effect.Deferred::new()
  self.starting = Some(d)
  let port = (async fn() -> Int raise {
    ignore(self.load_ca())
    (self.machine.proxy_listen)(async fn(c) { self.connect(c) }, async fn(f) { self.forward(f) })
  })() catch {
    e => {
      self.starting = None
      ignore(d.fail(e))
      raise e
    }
  }
  self.port = port
  self.listening = true
  self.starting = None
  ignore(d.succeed(port))
  port
}

///|
pub fn Proxy::close(self : Proxy) -> Unit {
  if self.listening {
    (self.machine.proxy_close)()
  }
  self.listening = false
}

///|
/// Lets `run` through: the proxy URL a command uses (its credentials name the run), and a function that ends it.
pub fn Proxy::admit(self : Proxy, run : ProxyRun) -> (String, () -> Unit) {
  let token = @vault_crypto.b64url((self.machine.random)(24))
  self.next_run += 1
  let n = self.next_run
  self.runs[token] = (n, run)
  self.by_number[n] = run
  (
    "http://run:\{token}@127.0.0.1:\{self.port}",
    () => {
      self.runs.remove(token)
      self.by_number.remove(n)
    },
  )
}

///|
/// The run a CONNECT's credentials name, if any.
fn Proxy::run_of(self : Proxy, authorization : String?) -> (Int, ProxyRun)? {
  let given = match authorization {
    Some(a) =>
      match basic_parts(a) {
        Some((_, b)) if b != "" => b
        _ => return None
      }
    None => return None
  }
  let pair = utf8_text(@vault_crypto.unb64(given))
  let at = match pair.find(":") {
    Some(i) => i + 1
    None => 0
  }
  let token = slice(pair, at)
  self.runs.get(token)
}

///|
/// `/^\[?([^\]]+?)\]?:(\d+)$/` of a CONNECT's target: its host and port.
fn target_of(url : String) -> (String, Int)? {
  let n = url.length()
  // the last ':' followed by digits to the end
  let mut c = n - 1
  while c >= 0 && url.code_unit_at(c) >= '0' && url.code_unit_at(c) <= '9' {
    c -= 1
  }
  if c < 0 || c == n - 1 || url.code_unit_at(c) != ':' {
    return None
  }
  let port = slice(url, c + 1)
  let mut host = slice(url, 0, b=c)
  if starts(host, "[") {
    host = slice(host, 1)
  }
  if ends(host, "]") {
    host = slice(host, 0, b=host.length() - 1)
  }
  if host == "" || contains(host, "]") {
    return None
  }
  let p = match digits_int(port) {
    Some(p) => p
    None => return None
  }
  Some((host, p))
}

///|
/// What is done with a CONNECT (proxy.ts `#connect`).
pub async fn Proxy::connect(self : Proxy, c : ConnectAsk) -> ConnectDecision noraise {
  let run = self.run_of(c.authorization)
  let target = target_of(c.url)
  match (run, target) {
    (None, _) => Refuse("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
    (_, None) => Refuse("HTTP/1.1 400 Bad Request\r\n\r\n")
    (Some((n, r)), Some((h, port))) => {
      let host = lower(h)
      if !@vault_crypto.host_allowed(host, r.hosts) {
        return Tunnel(host, port)
      }
      let context = self.leaf(host) catch {
        _ => return Refuse("HTTP/1.1 502 Bad Gateway\r\n\r\n")
      }
      Open(host, port, context, n)
    }
  }
}

///|
/// One request inside an opened HTTPS connection: sent on with the placeholder swapped in its headers.
pub async fn Proxy::forward(self : Proxy, f : ForwardAsk) -> ForwardDecision noraise {
  let run = match self.by_number.get(f.run) {
    Some(r) => r
    None => return Forbid(403, "grant expired")
  }
  if !(run.allowed)() {
    return Forbid(403, "grant expired")
  }
  let headers = []
  let mut swapped = false
  for h in f.headers {
    if hop.contains(h.0) {
      continue
    }
    let values = h.1.map(v => {
      let s = swap(v, run.placeholder, run.value)
      if s != v {
        swapped = true
      }
      s
    })
    if h.0 != "host" {
      headers.push((h.0, values))
    } else {
      headers.push((h.0, values))
    }
  }
  let host_value = if f.port == 443 { f.host } else { "\{f.host}:\{f.port}" }
  let mut set_host = false
  for i, h in headers {
    if h.0 == "host" {
      headers[i] = ("host", [host_value])
      set_host = true
    }
  }
  if !set_host {
    headers.push(("host", [host_value]))
  }
  if swapped {
    (run.used)(f.host)
  }
  Forward(headers)
}

///|
/// The TLS context shown for `host`, its certificate made when there is none or it is about to run out.
async fn Proxy::leaf(self : Proxy, host : String) -> String {
  let now = (self.now)()
  match self.leaves.get(host) {
    Some((context, made)) if now - made < leaf_ms => return context
    _ => ()
  }
  let ca = match self.ca {
    Some(ca) => ca
    None => raise Failure("the proxy's CA is not read yet")
  }
  let made = make_leaf(self.machine, ca, ca_name, host, now)
  let context = (self.machine.tls_context)(
    (self.machine.key_pem)(made.1),
    pem(made.0) + pem(ca.0),
  )
  self.leaves[host] = (context, now)
  context
}
