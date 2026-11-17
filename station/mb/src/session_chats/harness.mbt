// These parts asked line by line (reader `--builder harness-session-chats`), as station/test/mb-session-chats.test.ts
// asks the TypeScript's on the same cases: `{op: "fn", name, args}` a pure function, `{op: "world", name, args}` one
// that asks the station, each answered `{ok}` or `{error, kind}`. While one asks the station, the program says
// `{call, args}` and is answered `{result}` or `{threw, kind}`; asked meanwhile to run a callback it was given
// (`{cb, args}`), it answers `{cbResult}` or `{cbThrew, kind}`. `{op: "words", zh, en, product}` and
// `{op: "lang", lang}` give the station's words and language.

///|
priv struct Harness {
  host : @host.Host
  callbacks : Map[Int, async (Array[J]) -> J]
  next_cb : Ref[Int]
  words : Ref[Words]
  lang : Ref[String]
  thrown : Ref[J]
}

///|
fn threw_j(e : Error) -> J {
  jo([("error", js(thrown_message(e))), ("kind", js(thrown_kind(e)))])
}

///|
async fn Harness::wait_answer(self : Harness) -> J {
  while true {
    guard self.host.line() is Some(line) else { raise fail_("the test went away") }
    let msg = parse_js(line)
    match at(Some(msg), "cb") {
      Some(Num(id)) => {
        let args = arr_of(at(Some(msg), "args")).unwrap_or([])
        let reply = match self.callbacks.get(id.to_int()) {
          Some(f) =>
            try {
              let v = f(args)
              jo([("cbResult", v)])
            } catch {
              e => jo([("cbThrew", js(thrown_message(e))), ("kind", js(thrown_kind(e)))])
            }
          None => jo([("cbThrew", js("no callback \{id}")), ("kind", js(""))])
        }
        self.host.say(stringify(reply))
        continue
      }
      _ => ()
    }
    match at(Some(msg), "threw") {
      Some(m) => {
        self.thrown.val = at(Some(msg), "data").unwrap_or(Null)
        raise Thrown(str_of(at(Some(msg), "kind")).unwrap_or(""), str_of(Some(m)).unwrap_or(""))
      }
      None => ()
    }
    return at(Some(msg), "result").unwrap_or(Null)
  }
  Null
}

///|
fn Harness::world(self : Harness) -> World {
  {
    call: async fn(name, args) {
      self.host.say(stringify(jo([("call", js(name)), ("args", ja(args))])))
      self.wait_answer()
    },
    callback: fn(f) {
      self.next_cb.val += 1
      let id = self.next_cb.val
      self.callbacks[id] = f
      jo([("$cb", ji(id))])
    },
    words: self.words.val,
    lang: self.lang,
    thrown: self.thrown,
  }
}

///|
fn arg(args : Array[J], i : Int) -> J? {
  if i < args.length() {
    Some(args[i])
  } else {
    None
  }
}

///|
fn sarg(args : Array[J], i : Int) -> String {
  str_of(arg(args, i)).unwrap_or("")
}

///|
fn opt_s(v : String?) -> J {
  jopt(v)
}

///|
fn bytes_arg(args : Array[J], i : Int) -> Bytes {
  let xs = arr_of(arg(args, i)).unwrap_or([])
  Bytes::from_array(xs.map(x => num_of(Some(x)).unwrap_or(0.0).to_int().to_byte()))
}

///|
/// A pure function of these parts, by its TypeScript name.
fn Harness::pure(self : Harness, name : String, args : Array[J]) -> J raise Thrown {
  let words = self.words.val
  let lang = self.lang.val
  match name {
    "sizeOf" =>
      match size_of(bytes_arg(args, 0)) {
        Some((w, h)) => ja([jn(w), jn(h)])
        None => Null
      }
    "facts" =>
      match facts_of(bytes_arg(args, 0)) {
        Some(f) => f.to_j()
        None => Null
      }
    "pageOrigin" => js(page_origin(sarg(args, 0), sarg(args, 1)))
    "sessionPage" => {
      let b = arg(args, 0)
      js(
        session_page(
          { origin: str_of(at(b, "origin")).unwrap_or(""), workspace: str_of(at(b, "workspace")).unwrap_or(""), station: str_of(at(b, "station")).unwrap_or("") },
          sarg(args, 1),
          sarg(args, 2),
        ),
      )
    }
    "isInternalChannel" => jb(is_internal_channel(sarg(args, 0)))
    "chatKey" => {
      let made = arr_of(arg(args, 1)).unwrap_or([]).map(x => str_of(Some(x)).unwrap_or(""))
      js(chat_key(sarg(args, 0), made=k => made.contains(k)))
    }
    "chatWorkspace" => js(chat_workspace(sarg(args, 0), sarg(args, 1)))
    "nextTsAt" => js(next_ts_at(num_of(arg(args, 0)).unwrap_or(0.0)))
    "resetTs" => {
      reset_ts(num_of(arg(args, 0)).unwrap_or(0.0))
      Null
    }
    "internalPost" => js(internal_post(sarg(args, 0), sarg(args, 1), num_of(arg(args, 2)).unwrap_or(0.0)))
    "internalUserName" => opt_s(internal_user_name(sarg(args, 0)))
    "markNotice" => js(mark_notice(sarg(args, 0)))
    "isNotice" => jb(is_notice(sarg(args, 0)))
    "splitForSlack" => jsa(split_for_slack(sarg(args, 0), num_of(arg(args, 1)).unwrap_or(0.0).to_int()))
    "toolStatus" => js(tool_status(words, lang, sarg(args, 0)))
    "threadAddress" => js(thread_address(sarg(args, 0), sarg(args, 1)))
    "parseThreadAddress" =>
      match parse_thread_address(sarg(args, 0)) {
        Some((a, b)) => jsa([a, b])
        None => Null
      }
    "cleanTitle" => js(clean_title(sarg(args, 0)))
    "percentDecode" => js(percent_decode(sarg(args, 0)))
    "links" => ja(links(sarg(args, 0)).map(f => f.to_j()))
    _ => pure_more(self, name, args)
  }
}

///|
/// A function of these parts that asks the station, by its TypeScript name.
async fn Harness::asks(self : Harness, w : World, name : String, args : Array[J]) -> J {
  match name {
    "nameChat" => js(name_chat(w, arg(args, 0).unwrap_or(Null), sarg(args, 1)))
    "untitledChat" => opt_s(untitled_chat(w, sarg(args, 0)))
    "namedLocalPaths" =>
      ja(named_local_paths(w, sarg(args, 0)).map(p => jo([("destination", js(p.0)), ("path", js(p.1))])))
    "prepare" => {
      let paths = arr_of(arg(args, 1)).unwrap_or([]).map(x => str_of(Some(x)).unwrap_or(""))
      let text = prepare(w, sarg(args, 0), paths, sarg(args, 2))
      jo([("text", js(text)), ("paths", jsa(paths))])
    }
    "callApi" => call_api(w, sarg(args, 0), sarg(args, 1), arg(args, 2).unwrap_or(Null))
    _ => asks_more(self, w, name, args)
  }
}

///|
/// The program's harness: a case a line, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let h : Harness = { host, callbacks: {}, next_cb: Ref::new(0), words: Ref::new(Words::empty()), lang: Ref::new("zh"), thrown: Ref::new(Null) }
  while true {
    guard host.line() is Some(line) else { break }
    let answer = try {
      let c = parse_js(line)
      let args = arr_of(at(Some(c), "args")).unwrap_or([])
      let name = str_of(at(Some(c), "name")).unwrap_or("")
      let v = match str_of(at(Some(c), "op")).unwrap_or("") {
        "words" => {
          h.words.val = Words::new(
            at(Some(c), "zh").unwrap_or(Obj([])),
            at(Some(c), "en").unwrap_or(Obj([])),
            product=str_of(at(Some(c), "product")).unwrap_or("still.fail"),
          )
          J::Null
        }
        "lang" => {
          h.lang.val = str_of(at(Some(c), "lang")).unwrap_or("zh")
          J::Null
        }
        "fn" => h.pure(name, args)
        "world" => h.asks(h.world(), name, args)
        op => raise fail_("no such op: \{op}")
      }
      h.callbacks.clear()
      jo([("ok", v)])
    } catch {
      e => {
        h.callbacks.clear()
        threw_j(e)
      }
    }
    host.say(stringify(answer))
  }
}
