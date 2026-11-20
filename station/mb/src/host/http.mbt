// The shell's HTTP (client/shell's `fetch`) as this program asks it: the one place it is asked by name. A fetch given
// up before its answer (its deadline here passed, its fiber interrupted) is given up at the shell too (`fetch.cancel`):
// left there, its request and its connection went on until the other side or the network gave up.

///|
/// What a fetch's deadline here says where it passed first (as AbortSignal.timeout's abort does).
pub let fetch_timed_out : String = "The operation was aborted due to timeout"

///|
/// A fetch's deadline passed before its answer came (the shell's request given up).
pub suberror FetchTimeout

///|
pub impl Show for FetchTimeout with output(_, logger) {
  logger.write_string(fetch_timed_out)
}

///|
/// An answer to a fetch: its status, its headers (named as the shell gives them, lower case), its body, and whether
/// it is another URL's than the one asked (`redirected`: a redirect followed, `redirect="follow"`).
pub struct FetchResponse {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
  redirected : Bool
}

///|
/// Its body as text (what is not UTF-8 as U+FFFD).
pub fn FetchResponse::text(self : FetchResponse) -> String {
  @utf8.decode_lossy(self.body)
}

///|
/// Its first header named `name`, in any case.
pub fn FetchResponse::header(self : FetchResponse, name : String) -> String? {
  let name = name.to_lower()
  for h in self.headers {
    if h.0.to_lower() == name {
      return Some(h.1)
    }
  }
  None
}

///|
fn response_of(said : Json, bytes : Bytes?) -> FetchResponse {
  let status = match said {
    { "status": Number(n, ..), .. } => n.to_int()
    _ => 0
  }
  let headers = match said {
    { "headers": Array(xs), .. } =>
      xs.filter_map(x => match x {
        Array([String(k), String(v), ..]) => Some((k, v))
        _ => None
      })
    _ => []
  }
  let redirected = said is { "redirected": True, .. }
  { status, headers, body: bytes.unwrap_or(b""), redirected }
}

///|
/// A fetch over `call` (the shell's `fetch`: its arguments, its body, told the call's id as it is asked), given up by
/// `cancel` where it ends by an error before its answer (interrupted, its deadline passed); `timeout_ms`, its deadline.
async fn fetch_by(
  call : async (Json, Bytes?, (Int64) -> Unit) -> (Json, Bytes?),
  cancel : (Int64) -> Unit,
  args : Json,
  body : Bytes?,
  timeout_ms : Int?,
) -> FetchResponse {
  let once = async fn() {
    let id : Ref[Int64?] = { val: None }
    // (a call the shell failed is gone there already: cancelling it then is a no-op)
    errdefer (if id.val is Some(i) { cancel(i) })
    let (said, bytes) = call(args, body, i => id.val = Some(i))
    response_of(said, bytes)
  }
  match timeout_ms {
    None => once()
    Some(ms) =>
      match @effect.timeout(ms, once) {
        Some(r) => r
        None => raise FetchTimeout
      }
  }
}

///|
/// Gives up the shell's call `id` (a fetch, a dial) where it is still going: what that fails with is let go.
pub fn Host::cancel_fetch(self : Host, id : Int64) -> Unit {
  ignore(self.shell_sync("fetch.cancel", { "id": Json::number(id.to_double()) })) catch {
    _ => ()
  }
}

///|
/// An HTTP request by the shell: `entry`, the host and port its TCP goes to (TLS's name and HTTP's Host the URL's
/// own); `head_ms`, how long the shell waits for its answer's head, `stall_ms` how long its body may stay silent
/// (neither: as long as this waits); `timeout_ms`, the deadline here for the whole answer (`FetchTimeout` once it
/// passes); `redirect`, `"follow"` for redirects followed (up to ten; else, `"manual"` or none, a 3xx is the answer);
/// `called`, told the shell's call id as it is asked (what `Host::cancel_fetch` takes). Given up by its
/// deadline or an interruption, it is given up at the shell too, its connection with it. The shell's own failure is
/// raised as it says it (`@wire.ShellError`).
pub async fn Host::fetch(
  self : Host,
  url : String,
  method_? : String = "GET",
  headers? : Array[(String, String)] = [],
  body? : Bytes,
  entry? : (String, Int),
  head_ms? : Int,
  stall_ms? : Int,
  timeout_ms? : Int,
  redirect? : String,
  called? : (Int64) -> Unit,
) -> FetchResponse {
  let args : Map[String, Json] = {
    "url": Json::string(url),
    "method": Json::string(method_),
    "headers": Json::array(headers.map(h => Json::array([Json::string(h.0), Json::string(h.1)]))),
  }
  if entry is Some((host, port)) {
    args["entry"] = { "host": Json::string(host), "port": Json::number(port.to_double()) }
  }
  if head_ms is Some(ms) {
    args["timeoutMs"] = Json::number(ms.to_double())
  }
  if stall_ms is Some(ms) {
    args["stallMs"] = Json::number(ms.to_double())
  }
  if redirect is Some(r) {
    args["redirect"] = Json::string(r)
  }
  fetch_by(
    async fn(args, body, told) {
      self.shell("fetch", args, bytes?=body, called=id => {
        told(id)
        if called is Some(f) {
          f(id)
        }
      })
    },
    id => self.cancel_fetch(id),
    Json::object(args),
    body,
    timeout_ms,
  )
}
