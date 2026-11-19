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
/// The station's parts as the accounts ask them.
pub struct Backend {
  call : async (String, Array[JV]) -> JV
}

///|
pub fn Backend::new(call : async (String, Array[JV]) -> JV) -> Backend {
  { call, }
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
