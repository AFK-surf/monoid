// What the routes ask of the station's parts (the store, the hub, the readers, the accounts, the connects, the drive,
// config.json, the machine's files...): each a call by its name, `<part>.<method>` as station/src/api names the part
// and its method, with its arguments as JSON (a part named by reference `{"$ref": name}`, bytes `{"$bytes": base64}`,
// JavaScript's undefined `{"$undef": 1}`, a callback `{"$fn": name}`). A part that refuses throws: `Thrown` says its
// kind (the class station/src throws: Refused, Refusal, HttpError, NoPreset, ...) and what it carries (`message`, a
// `status`, and the rest). Phase 2 to 4 mount each part behind this one seam: a route is never written again for it.

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
/// The station's parts, as the routes ask them.
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

///|
/// A call whose answer is not used.
pub async fn Backend::tell(
  self : Backend,
  name : String,
  args : Array[JV],
) -> Unit {
  ignore((self.call)(name, args))
}

///|
/// A part by reference.
pub fn jref(name : String) -> JV {
  jobj([("$ref", js(name))])
}

///|
/// An answer that is undefined or null (`?? fallback`).
pub fn nullish(v : JV) -> Bool {
  v is Null || is_undef(v)
}

///|
/// The name a part's reference names.
pub fn ref_of(v : JV) -> String? {
  if v is Obj(_) {
    jstr(v.get("$ref"))
  } else {
    None
  }
}

///|
pub fn jbytes(b : Bytes) -> JV {
  jobj([("$bytes", js(@base64.encode(b)))])
}

///|
/// The bytes an answer carries (`{"$bytes": base64}`), or a string's UTF-8.
pub fn bytes_of(v : JV) -> Bytes? {
  match v {
    Obj(_) =>
      match jstr(v.get("$bytes")) {
        Some(b) => Some(@base64.decode(b)) catch { _ => None }
        None => None
      }
    Str(u) => Some(utf8(u))
    _ => None
  }
}

///|
/// What a thrown error says (`(e as Error).message`).
pub fn message_of(e : Error) -> String {
  match e {
    Thrown(_, said) => js_string(jget(Some(said), "message"))
    Refused(_, m) => m
    Moved(m, _) => m
    _ => e.to_string()
  }
}

///|
/// Whether it was thrown as `kind` by a part.
pub fn thrown_as(e : Error, kind : String) -> JV? {
  match e {
    Thrown(k, said) if k == kind => Some(said)
    _ => None
  }
}

///|
pub fn status_of(said : JV) -> Int32 {
  match jnumber(said.get("status")) {
    Some(n) => n.to_int()
    None => 500
  }
}
