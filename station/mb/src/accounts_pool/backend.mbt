// What the accounts ask of what is not theirs (the store, config.json, the sign-ins, the machine's logins, the hub,
// the shared profiles, the codex driver, the network, the files, the words of the parts not yet in MoonBit): each a
// call by its name, `<part>.<method>`, with its arguments as JSON (JavaScript's undefined `{"$undef": 1}`), as
// station/mb/src/api_routes/backend.mbt asks the station's parts. A part that refuses throws: `Thrown` says its kind
// (the class it threw: Refusal, RenewRefused, Error, TimeoutError, ...) and what it carries (`message`, `status`,
// `code`, and the rest).

///|
pub(all) suberror Thrown {
  Thrown(String, JV)
}

///|
pub impl Show for Thrown with fn output(self, logger) {
  match self {
    Thrown(kind, said) =>
      logger.write_string("\{kind}: \{js_string(jget(Some(said), "message"))}")
  }
}

///|
/// A refusal the pages are given (api/request.ts `Refused`, which accounts/index.ts throws as `Refusal`): its status
/// and words.
pub fn refusal(status : Int, message : String) -> Thrown {
  Thrown("Refusal", jobj([("status", jint(status)), ("message", js(message))]))
}

///|
/// An Error with these words.
pub fn plain_error(message : String) -> Thrown {
  Thrown("Error", jobj([("message", js(message))]))
}

///|
/// A subscription account has reached its configured active-session concurrency cap.
pub fn account_cap_error(
  profile : String,
  profile_id : String,
  active : Int,
  cap : Int,
  protection? : Bool = false,
) -> Thrown {
  Thrown(
    "AccountCapError",
    jobj([
      ("sessionCap", jbool(true)),
      ("profile", js(profile)),
      ("profileId", js(profile_id)),
      ("active", jint(active)),
      ("cap", jint(cap)),
      ("protection", jbool(protection)),
      ("message", js("account \{profile} reached concurrency cap (\{active}/\{cap})")),
    ]),
  )
}

///|
/// The words of a failure, as `(e as Error).message` says them.
pub fn message_of(e : Error) -> String {
  match e {
    Thrown(_, said) => js_string(jget(Some(said), "message"))
    _ => e.to_string()
  }
}

///|
/// The kind of a failure (`e instanceof RenewRefused`...).
pub fn kind_of(e : Error) -> String {
  match e {
    Thrown(kind, _) => kind
    _ => "Error"
  }
}

///|
/// An argument that may be undefined.
pub fn arg(v : JV?) -> JV {
  match v {
    Some(x) => x
    None => jundef
  }
}

///|
/// The station's parts as the accounts ask them: direct handles for the stores and host, plus `call` for the rest.
pub struct Backend {
  call : async (String, Array[JV]) -> JV
  store : @store_sessions.Store
  threads : @store_threads.Store?
  flush_threads : () -> Unit
  host : @host.Host
  sep : String
}

///|
pub fn Backend::new(
  call : async (String, Array[JV]) -> JV,
  store : @store_sessions.Store,
  threads : @store_threads.Store?,
  flush_threads : () -> Unit,
  host : @host.Host,
  sep? : String = "/",
) -> Backend {
  { call, store, threads, flush_threads, host, sep }
}

///|
/// A call of the part `name`, its answer.
pub async fn Backend::ask(
  self : Backend,
  name : String,
  args : Array[JV],
) -> JV {
  (self.call)(name, args)
}

///|
fn jv_to_json(v : JV) -> Json {
  if is_undef(v) { return Json::null() }
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => Json::number(n)
    Str(s) => Json::string(s)
    Arr(xs) => Json::array(xs.map(jv_to_json))
    Obj(kvs) => {
      let m : Map[String, Json] = Map([])
      for kv in kvs {
        if !is_undef(kv.1) { m[kv.0] = jv_to_json(kv.1) }
      }
      Json::object(m)
    }
  }
}

///|
fn json_to_jv(v : Json) -> JV { @jsjson.jval_of_json(v) }

///|
fn wrap_err(e : Error) -> Thrown {
  match e {
    Thrown(_, _) as t => t
    @store_sessions.StoreError(m, _) => plain_error(m)
    @store_threads.StoreError(m) => plain_error(m)
    _ => plain_error(e.to_string())
  }
}

///|
fn[T] Backend::with_store(self : Backend, f : (@store_sessions.Store) -> T raise) -> T raise {
  f(self.store) catch { e => raise wrap_err(e) }
}

///|
fn Backend::with_threads(self : Backend, f : (@store_threads.Store) -> Json raise) -> JV raise {
  guard self.threads is Some(t) else { raise plain_error("threads store unavailable") }
  t.set_now(@host.epoch_ms().to_double())
  errdefer (self.flush_threads)()
  let v = f(t) catch { e => raise wrap_err(e) }
  (self.flush_threads)()
  json_to_jv(v)
}
