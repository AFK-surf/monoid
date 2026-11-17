// The program `stillfail-reader --builder harness-session-hub` (station/test/mb-session-hub.test.ts): this package
// driven by the test over stdin and stdout, a JSON line each way. What it is told:
// - `{"id", "op": "words", "zh", "en", "lang"}`: the station's catalog (words.mbt), its texts as the station has them;
// - `{"id", "op": "call", "fn", "args"}`: one of this package's functions, by the TypeScript's name, its answer said
//   `{"id", "result"}` or `{"id", "error"}` (what refused it);
// - `{"id", "op": "hub", …}`: the hub's (hub_harness.mbt), on a database of the test's, on a clock of the test's.
// An argument the TypeScript was given as undefined is `{"$undefined": true}`; a result that is undefined is said so.

///|
/// An argument (None: not given, or given as undefined).
fn arg(args : Array[Json], i : Int) -> Json? {
  match args.get(i) {
    None => None
    Some(Object(m)) if m.get("$undefined") is Some(True) => None
    Some(v) => Some(v)
  }
}

///|
fn a_str(args : Array[Json], i : Int) -> String {
  match arg(args, i) {
    Some(String(s)) => s
    Some(v) => js_string(v)
    None => ""
  }
}

///|
fn a_opt_str(args : Array[Json], i : Int) -> String? {
  match arg(args, i) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn a_num(args : Array[Json], i : Int) -> Double {
  match arg(args, i) {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
fn a_arr(args : Array[Json], i : Int) -> Array[Json] {
  items(arg(args, i))
}

///|
fn a_map(args : Array[Json], i : Int) -> Map[String, Json] {
  match arg(args, i) {
    Some(Object(m)) => m
    _ => {}
  }
}

///|
/// What is said of undefined.
pub fn undefined() -> Json {
  { "$undefined": true }
}

///|
fn strs(xs : Array[String]) -> Json {
  Json::array(xs.map(Json::string))
}

///|
fn opt_json(v : Json?) -> Json {
  match v {
    Some(j) => j
    None => Json::null()
  }
}

///|
/// One of the package's pure functions, by the TypeScript's name.
fn call_pure(words : Words, name : String, x : Array[Json]) -> Json raise Refused {
  match name {
    // args.ts
    "jsString" => Json::string(js_string(arg(x, 0).unwrap_or(Json::null())))
    "jsNumber" =>
      match js_number(arg(x, 0).unwrap_or(Json::null())) {
        None => Json::null()
        Some(n) =>
          if n.is_nan() {
            Json::string("NaN")
          } else if n.is_inf() {
            Json::string(if n > 0.0 { "Infinity" } else { "-Infinity" })
          } else {
            num(n)
          }
      }
    "parseDeclared" => opt_json(parse_declared(a_str(x, 0), a_num(x, 1)))
    "stateArg" =>
      match state_arg(arg(x, 0)) {
        None => Json::null()
        Some((k, said)) => [k, Json::string(said)]
      }
    "isReason" => Json::boolean(is_reason(a_str(x, 0)))
    "needArg" => opt_str(need_arg(a_map(x, 0), arg(x, 1).unwrap_or(Json::null()), a_str(x, 2)))
    "aboutTs" => opt_str(about_ts(a_map(x, 0)))
    "firstLine" => Json::string(first_line(a_str(x, 0)))
    "optionsArg" =>
      match options_arg(arg(x, 0)) {
        None => Json::null()
        Some(o) => Json::array(o)
      }
    "cardArg" => opt_json(card_arg(arg(x, 0), arg(x, 1)))
    "optionsSaid" => Json::string(options_said(arg(x, 0).unwrap_or(Json::null())))
    "cardSaid" => Json::string(card_said(arg(x, 0).unwrap_or(Json::null())))
    "placeFigures" => Json::string(place_figures(a_str(x, 0), a_arr(x, 1)))
    "slackWithFiles" => {
      let (a, b) = slack_with_files(words, a_str(x, 0), a_arr(x, 1), a_str(x, 2))
      [Json::string(a), Json::string(b)]
    }
    "threadCommand" => opt_str(thread_command(a_str(x, 0)))
    "isSlackMethod" => Json::boolean(is_slack_method(a_str(x, 0)))
    "saidAs" => Json::string(said_as(arg(x, 0).unwrap_or(Json::null())))
    // model-choice.ts
    "candidates" =>
      Json::array(
        candidates(a_arr(x, 0), a_opt_str(x, 1), leads=arg(x, 2) is Some(True)),
      )
    "choose" =>
      choose(
        a_arr(x, 0),
        a_arr(x, 1),
        leads?=match arg(x, 2) {
          Some(Array(l)) => Some(l)
          _ => None
        },
      )
    "few" => Json::array(few(a_arr(x, 0), a_arr(x, 1), a_arr(x, 2)))
    "askWhich" => Json::string(ask_which(a_arr(x, 0), a_str(x, 1)))
    // run-change.ts, context-cap.ts
    "runShown" => {
      let names = a_map(x, 1)
      run_shown(arg(x, 0).unwrap_or(Json::null()), p => match names.get(p) {
        Some(String(n)) => Some(n)
        _ => None
      })
    }
    "runChanged" => Json::boolean(run_changed(arg(x, 0).unwrap_or(Json::null())))
    "runChangeWords" =>
      Json::string(run_change_words(words, arg(x, 0).unwrap_or(Json::null()), a_str(x, 1)))
    "contextAsked" =>
      match context_asked(words, arg(x, 0), a_str(x, 1)) {
        None => undefined()
        Some(None) => Json::null()
        Some(Some(n)) => num(n)
      }
    "checkContext" => {
      check_context(
        words,
        a_str(x, 0),
        match arg(x, 1) {
          Some(Number(n, ..)) => Some(n)
          _ => None
        },
        a_str(x, 2),
      )
      undefined()
    }
    // pool.ts
    "urgency" => urgency(arg(x, 0), a_num(x, 1))
    "cheapToLeave" => {
      let points : Map[String, Double] = Map([])
      for e in a_arr(x, 1) {
        match e {
          Array([String(k), Number(v, ..)]) => points[k] = v
          _ => ()
        }
      }
      Json::boolean(cheap_to_leave(a_arr(x, 0), points))
    }
    "signsIn" => Json::boolean(signs_in(arg(x, 0).unwrap_or(Json::null())))
    "usable" =>
      Json::boolean(
        usable(
          arg(x, 0).unwrap_or(Json::null()),
          match arg(x, 1) {
            Some(Number(n, ..)) => Some(n)
            _ => None
          },
        ),
      )
    "serves" => Json::boolean(serves(arg(x, 0).unwrap_or(Json::null()), a_opt_str(x, 1)))
    "pickProfile" => {
      // (the signals as the test fixed them: health, load and last picked by profile, and now)
      let s = arg(x, 2).unwrap_or(Json::null())
      let by = (k : String, id : String) => match field(s, k) {
        Some(Object(m)) => m.get(id)
        _ => None
      }
      let signals : PoolSignals = {
        health: id => by("health", id).unwrap_or(Json::object({})),
        load: id => match by("load", id) {
          Some(Number(n, ..)) => n.to_int()
          _ => 0
        },
        last_picked: id => match by("lastPicked", id) {
          Some(Number(n, ..)) => n
          _ => 0.0
        },
        now: () => num_of(s, "now").unwrap_or(0.0),
      }
      pick_profile(a_arr(x, 0), a_opt_str(x, 1), signals, arg(x, 3) is Some(True))
    }
    "fallbackEfforts" => strs(fallback_efforts(a_str(x, 0)))
    "reportedEfforts" =>
      match reported_efforts(a_str(x, 0), a_opt_str(x, 1), arg(x, 2)) {
        None => Json::null()
        Some(l) => strs(l)
      }
    "availableEfforts" => strs(available_efforts(a_str(x, 0), a_opt_str(x, 1), arg(x, 2)))
    "commonEfforts" =>
      strs(
        common_efforts(a_arr(x, 0).map(l => items(Some(l)).map(js_string)), a_str(x, 1)),
      )
    // config.ts and what it stands on
    "spelling" => opt_str(spelling(arg(x, 0).unwrap_or(Json::null()), a_str(x, 1)))
    "runs" => Json::boolean(runs(arg(x, 0).unwrap_or(Json::null()), a_str(x, 1)))
    "sameModel" => Json::boolean(same_model(a_str(x, 0), a_str(x, 1)))
    "allowedIn" =>
      Json::boolean(allowed_in(arg(x, 0).unwrap_or(Json::null()), a_opt_str(x, 1), a_opt_str(x, 2)))
    "billedPerUse" => Json::boolean(billed_per_use(arg(x, 0).unwrap_or(Json::null())))
    "modelName" => Json::string(model_name(a_str(x, 0)))
    "chosenSpeed" => opt_str(chosen_speed(arg(x, 0).unwrap_or(Json::null())))
    "ultrafastModel" => Json::boolean(ultrafast_model(arg(x, 0)))
    "tr" => {
      let given = a_map(x, 2)
      let pairs = []
      for k, v in given {
        pairs.push((k, v))
      }
      Json::string(words.tr(a_str(x, 1), args=pairs, lang=a_str(x, 0)))
    }
    // actor.ts: what the actors are told in the station's words
    "timed" => Json::string(timed(a_str(x, 0), a_num(x, 1)))
    "retryable" => Json::boolean(retryable(arg(x, 0).unwrap_or(Json::null())))
    "withSaid" => Json::string(with_said(a_str(x, 0), a_str(x, 1)))
    "personRef" => Json::string(person_ref(arg(x, 0).unwrap_or(Json::null())))
    "words" => words_answer(words, a_str(x, 0), x[1:].to_owned())
    _ => raise Refused("no function \{name}")
  }
}

///|
/// Runs the harness till stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let words = Ref(Words::new())
  let hubs = HubHarness::new(host)
  host.say(({ "ready": true } : Json).stringify())
  while host.line() is Some(text) {
    let line = @json.parse(text) catch { _ => continue }
    let id = field(line, "id").unwrap_or(Json::null())
    let answer : Json = match str_of(line, "op") {
      Some("words") => {
        let m = (k : String) => match field(line, k) {
          Some(Object(m)) => m
          _ => {}
        }
        words.val = Words::new(zh=m("zh"), en=m("en"), lang=str_of(line, "lang").unwrap_or("zh"))
        hubs.words = words.val
        { "id": id, "result": Json::null() }
      }
      Some("call") => {
        let name = str_of(line, "fn").unwrap_or("")
        let args = items(field(line, "args"))
        try {
          { "id": id, "result": call_pure(words.val, name, args) }
        } catch {
          Refused(m) => { "id": id, "error": Json::string(m) }
        }
      }
      Some("hub") =>
        match hubs.op(line) {
          None => continue
          Some(Object(m)) => {
            m["id"] = id
            Json::object(m)
          }
          Some(out) => { "id": id, "result": out }
        }
      _ => { "id": id, "error": "no such op" }
    }
    host.say(answer.stringify())
  }
}
