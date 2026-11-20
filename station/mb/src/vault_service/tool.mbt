// The agents' tools for the vault's secrets (station/src/vault/tool.ts): sign_in, secret_list, secret_use,
// secret_save, secret_describe, secret_delete, secret_cancel, secret_reask and secret_run. The value of a secret is
// never what a tool gives back. Their declarations are tools_declared.mbt's; what each does is here.

///|
/// A tool as the station's MCP endpoint serves it: its declaration and what it does with a session's call.
pub struct Tool {
  name : String
  description : String
  input_schema : Json
  run : async (String, Json, Signal?) -> String
}

///|
fn arg_text(args : Json, key : String) -> String {
  gs(Some(args), key).unwrap_or("")
}

///|
fn person_of(args : Json) -> String? {
  let p = trim(arg_text(args, "person"))
  if p != "" {
    Some(p)
  } else {
    None
  }
}

///|
fn strings_arg(v : Json?) -> Array[String]? {
  match v {
    Some(Array(_)) => Some(strings_of(v))
    _ => None
  }
}

///|
fn vault_words(status : String) -> String {
  match status {
    "on" => "Their vault is on: secret_save keeps a credential in it once they approve."
    "plain" =>
      "The workspace has no security mode: secret_save keeps a credential in their library on this station, unencrypted, once they approve."
    "off" =>
      "Their vault is not turned on: secret_save's card offers them to turn it on in the still.fail app, then keeps the credential."
    _ => "No one started this chat who could keep a credential (secret_save is refused)."
  }
}

///|
/// What each tool does, by its name.
fn tool_run(
  secrets : Secrets,
  session_dir : (String) -> String?,
  join_path : (String, String) -> String,
  sign_ins : SignIns?,
  name : String,
) -> async (String, Json, Signal?) -> String {
  match name {
    "sign_in" =>
      async fn(key, args, signal) {
        let opt = (k : String) => match gs(Some(args), k) {
          Some(v) if v != "" => Some(v)
          _ => None
        }
        sign_ins
        .unwrap()
        .ask(
          key,
          {
            site: arg_text(args, "site"),
            reason: opt("reason"),
            tab: opt("tab"),
            again: get(Some(args), "again") == Some(Json::boolean(true)),
            reask: get(Some(args), "reask") == Some(Json::boolean(true)),
            done: get(Some(args), "done") == Some(Json::boolean(true)),
            stuck: gs(Some(args), "stuck"),
            name: if trim(arg_text(args, "name")) != "" { Some(arg_text(args, "name")) } else { None },
            about: if trim(arg_text(args, "about")) != "" { Some(arg_text(args, "about")) } else { None },
          },
          signal?,
        )
      }
    "secret_list" =>
      async fn(key, args, _) {
        let person = person_of(args)
        let items = secrets
          .listings(key, person?)
          .map(l => {
            let fs = [("item", js(l.item)), ("name", get(Some(l.listing), "name").unwrap_or(Json::null()))]
            if truthy(get(Some(l.listing), "about")) {
              fs.push(("about", get(Some(l.listing), "about").unwrap()))
            }
            fs.push(("kind", get(Some(l.listing), "kind").unwrap_or(Json::null())))
            fs.push(("modes", get(Some(l.listing), "modes").unwrap_or(Json::null())))
            fs.push(("hosts", get(Some(l.listing), "hosts").unwrap_or(Json::null())))
            if truthy(get(Some(l.listing), "env")) {
              fs.push(("env", get(Some(l.listing), "env").unwrap()))
            }
            if l.vault_name is Some(vn) {
              fs.push(("vaultName", js(vn)))
            }
            if l.scope is Some(sc) {
              fs.push(("scope", js(sc)))
            }
            obj(fs)
          })
        let held = secrets
          .held(key)
          .map(h => {
            let fs = [
              ("grant", get(Some(h.request), "id").unwrap_or(Json::null())),
              ("item", get(Some(h.request), "item").unwrap_or(Json::null())),
              ("mode", get(Some(h.grant), "mode").unwrap_or(Json::null())),
              ("hosts", get(Some(h.grant), "hosts").unwrap_or(Json::null())),
              ("scope", get(Some(h.grant), "scope").unwrap_or(Json::null())),
              (
                "until",
                js(iso(match h.until { Some(u) => u; None => gn(Some(h.grant), "exp").unwrap_or(0.0) })),
              ),
            ]
            if truthy(get(Some(h.grant), "timeout")) {
              fs.push(("timeout", get(Some(h.grant), "timeout").unwrap()))
            }
            if gs(Some(h.grant), "mode") == Some("proxy") {
              fs.push(("placeholder", js(placeholder(gtext(Some(h.request), "id")))))
            }
            if truthy(get(Some(h.request), "runOn")) {
              fs.push(("station", get(get(Some(h.request), "runOn"), "name").unwrap_or(Json::null())))
            }
            if @vault_crypto.account_of(h.secret) is Some(u) {
              fs.push(("username", js(u)))
            }
            obj(fs)
          })
        let vault = vault_words(secrets.status(key, person?))
        if items.is_empty() && held.is_empty() {
          return "No secrets may be asked for here: this station holds none of the vault's items open to agents for \{person.unwrap_or("whoever started this chat")}. One kept on another station of the workspace reaches this one once a device of its owner's still.fail app has been online with both. \{vault}"
        }
        stringify_pretty(obj([("secrets", jarr(items)), ("grants", jarr(held)), ("vault", js(vault))]))
      }
    "secret_use" =>
      async fn(key, args, _) {
        let opt = (k : String) => match gs(Some(args), k) {
          Some(v) if v != "" => Some(v)
          _ => None
        }
        secrets.ask(key, {
          item: arg_text(args, "item"),
          reason: arg_text(args, "reason"),
          command: opt("command"),
          mode: opt("mode"),
          hosts: match get(Some(args), "hosts") {
            Some(Array(_) as hs) => Some(strings_of(Some(hs)).map(h => lower(trim(h))))
            _ => None
          },
          station: if trim(arg_text(args, "station")) != "" { Some(trim(arg_text(args, "station"))) } else { None },
          timeout: match get(Some(args), "timeout") {
            Some(Object(_) as t) => Some(t)
            Some(Array(_) as t) => Some(t)
            _ => None
          },
          person: person_of(args),
        })
      }
    "secret_save" =>
      async fn(key, args, _) {
        guard session_dir(key) is Some(home) else { raise Failure("unknown session") }
        let opt = (k : String) => match gs(Some(args), k) {
          Some(v) if v != "" => Some(v)
          _ => None
        }
        if trim(arg_text(args, "about")) == "" {
          raise Failure("about is required: what it is for and how it is used, for whoever uses it next")
        }
        secrets.save_secret(key, {
          name: arg_text(args, "name"),
          about: Some(arg_text(args, "about")),
          kind: arg_text(args, "kind"),
          reason: arg_text(args, "reason"),
          value: opt("value"),
          command: opt("command"),
          path: opt("path"),
          filename: opt("filename"),
          username: opt("username"),
          public_key: opt("public_key"),
          env: if trim(arg_text(args, "env")) != "" { Some(trim(arg_text(args, "env"))) } else { None },
          modes: strings_arg(get(Some(args), "modes")),
          hosts: strings_arg(get(Some(args), "hosts")),
          station: if trim(arg_text(args, "station")) != "" { Some(trim(arg_text(args, "station"))) } else { None },
          browser: match gs(Some(args), "browser") {
            Some("chat") => Some("chat")
            Some("station") => Some("station")
            _ => None
          },
          oauth: opt("oauth"),
          scope: match gs(Some(args), "scope") {
            Some("personal") => Some("personal")
            Some("workspace") => Some("workspace")
            _ => None
          },
          person: person_of(args),
          cwd: home,
          quiet: None,
        })
      }
    "secret_describe" =>
      async fn(key, args, _) {
        secrets.describe(
          key,
          arg_text(args, "item"),
          name?=gs(Some(args), "name"),
          about?=gs(Some(args), "about"),
          arg_text(args, "reason"),
          person?=person_of(args),
        )
      }
    "secret_delete" =>
      async fn(key, args, _) {
        secrets.remove(key, arg_text(args, "item"), arg_text(args, "reason"), person?=person_of(args))
      }
    "secret_cancel" => async fn(key, args, _) { secrets.cancel(key, arg_text(args, "request")) }
    "secret_reask" =>
      async fn(key, args, signal) { secrets.reask(key, arg_text(args, "request"), signal?) }
    _ =>
      async fn(key, args, _) {
        guard session_dir(key) is Some(home) else { raise Failure("unknown session") }
        let given = trim(arg_text(args, "cwd"))
        let seconds = match get(Some(args), "timeout_seconds") {
          Some(Number(n, ..)) if n == n.floor() && !n.is_inf() => Some(n)
          _ => None
        }
        secrets.run(key, {
          grant: trim(arg_text(args, "grant")),
          command: arg_text(args, "command"),
          cwd: if given == "" { home } else { join_path(home, given) },
          under: Some(given),
          env: if arg_text(args, "env") != "" { Some(trim(arg_text(args, "env"))) } else { None },
          station: if trim(arg_text(args, "station")) != "" { Some(trim(arg_text(args, "station"))) } else { None },
          timeout_ms: seconds.map(s => s * 1000.0),
        })
      }
  }
}

///|
/// The vault's tools: `session_dir` a session's workspace directory, `join_path` the platform's `path.join`.
pub fn vault_tools(
  secrets : Secrets,
  session_dir : (String) -> String?,
  join_path : (String, String) -> String,
  sign_ins? : SignIns,
) -> Array[Tool] {
  let declared = match parse_or_null(tools_declared) {
    Array(a) => a
    _ => []
  }
  let out = []
  for t in declared {
    let name = gtext(Some(t), "name")
    if name == "sign_in" && sign_ins is None {
      continue
    }
    out.push({
      name,
      description: gtext(Some(t), "description"),
      input_schema: get(Some(t), "inputSchema").unwrap_or(Json::null()),
      run: tool_run(secrets, session_dir, join_path, sign_ins, name),
    })
  }
  out
}

///|
/// `JSON.stringify(v, null, 2)`.
fn stringify_pretty(v : Json) -> String {
  let b = StringBuilder()
  pretty_into(b, v, 0)
  b.to_string()
}

///|
fn pretty_into(b : StringBuilder, v : Json, depth : Int) -> Unit {
  let pad = (n : Int) => for _ in 0..<(n * 2) {
    b.write_char(' ')
  }
  match v {
    Array(a) if a.length() > 0 => {
      b.write_string("[\n")
      for i, x in a {
        pad(depth + 1)
        pretty_into(b, x, depth + 1)
        if i < a.length() - 1 {
          b.write_char(',')
        }
        b.write_char('\n')
      }
      pad(depth)
      b.write_char(']')
    }
    Object(m) if m.length() > 0 => {
      b.write_string("{\n")
      let mut i = 0
      for k, x in m {
        pad(depth + 1)
        b.write_string(stringify(Json::string(k)))
        b.write_string(": ")
        pretty_into(b, x, depth + 1)
        if i < m.length() - 1 {
          b.write_char(',')
        }
        b.write_char('\n')
        i += 1
      }
      pad(depth)
      b.write_char('}')
    }
    x => b.write_string(stringify(x))
  }
}
