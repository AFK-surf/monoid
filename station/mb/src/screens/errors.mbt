// What fails here, as the TypeScript throws it: a refusal for a person (hub.ts `ScreenRefused`: a status, its words'
// key and what fills them, the access that says why), and any other Error with what it carries (`Object.assign(new
// Error(message), fields)`: a helper's refusal, its `code`).

///|
/// A source that cannot be opened now, and why, in words a person reads (`key` of client/i18n's station part); its
/// message the English of them.
pub(all) suberror ScreenRefused {
  ScreenRefused(status~ : Int, key~ : String, args~ : J, access~ : ScreenAccess?, message~ : String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for ScreenRefused with output(self, logger) {
  match self {
    ScreenRefused(message~, ..) => logger.write_string(message)
  }
}

///|
/// An Error and what it carries besides its message (null: nothing).
pub(all) suberror Failed {
  Failed(String, J)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for Failed with output(self, logger) {
  match self {
    Failed(m, _) => logger.write_string(m)
  }
}

///|
fn fail(message : String) -> Failed {
  Failed(message, Null)
}

///|
/// `new ScreenRefused(status, key, args, access)`.
fn Io::refused(self : Io, status : Int, key : String, args? : J = jo([]), access? : ScreenAccess? = None) -> ScreenRefused {
  ScreenRefused(status~, key~, args~, access~, message=self.tr("en", key, args~))
}

///|
/// What an error says (`(error as Error).message`).
pub fn message_of(e : Error) -> String {
  match e {
    ScreenRefused(message~, ..) => message
    Failed(m, _) => m
    ExecFailed(message~, ..) => message
    FsFailed(m, _) => m
    GrantRefused(key) => key
    _ => e.to_string()
  }
}

///|
/// A field an error carries (`(error as X).code`…).
fn field_of(e : Error, k : String) -> J? {
  match e {
    Failed(_, fields) => get(Some(fields), k)
    ExecFailed(code~, signal~, ..) =>
      match k {
        "code" => Some(code)
        "signal" => signal.map(js)
        _ => None
      }
    FsFailed(_, code) => if k == "code" { Some(js(code)) } else { None }
    _ => None
  }
}

///|
/// An error as a test is told it: its kind, its message and what it carries.
pub fn error_j(e : Error) -> J {
  match e {
    ScreenRefused(status~, key~, args~, access~, message~) =>
      jsome([
        ("kind", Some(js("ScreenRefused"))),
        ("message", Some(js(message))),
        ("status", Some(ji(status))),
        ("key", Some(js(key))),
        ("args", Some(args)),
        ("access", access.map(a => a.to_j())),
      ])
    GrantRefused(key) => jo([("kind", js("GrantRefused")), ("message", js(key)), ("key", js(key))])
    e =>
      jsome([
        ("kind", Some(js("Error"))),
        ("message", Some(js(message_of(e)))),
        ("code", text(field_of(e, "code")).map(js)),
      ])
  }
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for GrantRefused with output(self, logger) {
  match self {
    GrantRefused(key) => logger.write_string(key)
  }
}
