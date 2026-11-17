// The model a chat an agent opens runs when its agent names none (station/src/sessions/model-choice.ts): the one the
// person it goes to has opened most chats with on this station, of those a profile here runs for its workspace. The
// most used one has to lead clearly, used at least twice as often as any other; when another is close to it (or none
// was used, and the profiles lead with more than one), nobody guesses: the agent is told them, to ask (差距不大就要问).
// A candidate is `{runtime, model}` (model null: the runtime's default), as JSON; a use `{runtime, model, n}`.

///|
/// What is counted: the starter's chats over this long.
pub let used_within_ms : Double = 30.0 * 86_400_000.0

///|
/// The most models a person is offered before they type anything.
pub let few_most : Int = 12

///|
fn cand(runtime : String, model : String?) -> Json {
  { "runtime": Json::string(runtime), "model": opt_str(model) }
}

///|
fn model_of(c : Json) -> String? {
  str_of(c, "model")
}

///|
fn runtime_of(c : Json) -> String {
  str_of(c, "runtime").unwrap_or("")
}

///|
/// Whether two candidates are one: one runtime, and one model (or both its default).
fn alike(o : Json, c : Json) -> Bool {
  runtime_of(o) == runtime_of(c) &&
  (match (model_of(o), model_of(c)) {
    (Some(a), Some(b)) => same_model(a, b)
    (None, None) => true
    _ => false
  })
}

///|
/// `candidates`: the models the profiles run, each once (in their order), of `runtime` when given; with `leads`, only
/// the one each runs first.
pub fn candidates(profiles : Array[Json], runtime : String?, leads? : Bool = false) -> Array[Json] {
  let out : Array[Json] = []
  for p in profiles {
    let runs_ = if leads {
      match str_of(p, "model") {
        Some(m) => [m]
        None =>
          match field(p, "model") {
            // (`p.model ?? p.models[0]`: a model set but not a string is kept as it is, as JavaScript would)
            Some(Null) | None => profile_models(p)[:@cmp.minimum(1, profile_models(p).length())].to_owned()
            Some(_) => []
          }
      }
    } else {
      profile_models(p)
    }
    for r in profile_runtimes(p) {
      match runtime {
        Some(want) if r != want => continue
        _ => ()
      }
      let cs = if runs_.length() > 0 {
        runs_.map(m => cand(r, Some(m)))
      } else {
        [cand(r, None)]
      }
      for c in cs {
        if !out.iter().any(o => alike(o, c)) {
          out.push(c)
        }
      }
    }
  }
  out
}

///|
/// `counted`: the candidate a chat that ran (runtime, model) counts for: the one with its model, else its runtime's
/// default.
fn counted(cands : Array[Json], u : Json) -> Int {
  let named = match model_of(u) {
    None => -1
    Some(m) =>
      match
        cands.search_by(c => runtime_of(c) == runtime_of(u) &&
          (match model_of(c) {
            Some(cm) => same_model(cm, m)
            None => false
          })) {
        Some(i) => i
        None => -1
      }
  }
  if named >= 0 {
    named
  } else {
    cands.search_by(c => runtime_of(c) == runtime_of(u) && model_of(c) is None).unwrap_or(-1)
  }
}

///|
/// `choose`: `{pick}` the one to run (used at least twice as often as any other), else `{ask: [{candidate, n}]}` the
/// most used and those close to it, most used first; none used: `leads`, the one, else all of them asked about.
pub fn choose(cands : Array[Json], used : Array[Json], leads? : Array[Json]) -> Json {
  let leads = leads.unwrap_or(cands)
  if cands.length() == 1 {
    return { "pick": cands[0] }
  }
  let n = Array::make(cands.length(), 0.0)
  for u in used {
    let i = counted(cands, u)
    if i >= 0 {
      n[i] = n[i] + num_of(u, "n").unwrap_or(0.0)
    }
  }
  let mut most = 0.0
  for x in n {
    most = if x > most { x } else { most }
  }
  if most == 0.0 {
    return if leads.length() == 1 {
      { "pick": leads[0] }
    } else {
      { "ask": Json::array(leads.map(c => { "candidate": c, "n": num(0.0) })) }
    }
  }
  let close = []
  for i, c in cands {
    if n[i] * 2.0 > most {
      close.push((c, n[i]))
    }
  }
  if close.length() == 1 {
    return { "pick": close[0].0 }
  }
  // (a stable sort, most used first)
  let sorted = stable_sort(close, (a, b) => {
    let d = b.1 - a.1
    if d > 0.0 {
      1
    } else if d < 0.0 {
      -1
    } else {
      0
    }
  })
  { "ask": Json::array(sorted.map(c => { "candidate": c.0, "n": num(c.1) })) }
}

///|
/// A stable sort by `cmp` (JavaScript's Array.prototype.sort).
pub fn[T] stable_sort(xs : Array[T], cmp : (T, T) -> Int) -> Array[T] {
  let out = xs.copy()
  // insertion sort: stable, and these lists are short
  for i in 1..<out.length() {
    let x = out[i]
    let mut j = i - 1
    while j >= 0 && cmp(out[j], x) > 0 {
      out[j + 1] = out[j]
      j -= 1
    }
    out[j + 1] = x
  }
  out
}

///|
/// `few`: of `all` (the models a person may pick for a new chat, the one it runs unless told otherwise first), the few
/// they are offered before they type anything: all where they are `few_most` or fewer; else its first, those they
/// started chats on lately (the most used first), then those config.json names, each once, `few_most` at most.
pub fn few(all : Array[Json], used : Array[Json], named : Array[Json]) -> Array[Json] {
  if all.length() <= few_most {
    return all
  }
  let at = (c : Json) => all.search_by(o => alike(o, c)).unwrap_or(-1)
  let n = Array::make(all.length(), 0.0)
  for u in used {
    let i = at(u)
    if i >= 0 {
      n[i] = n[i] + num_of(u, "n").unwrap_or(0.0)
    }
  }
  let idx = []
  for i in 0..<all.length() {
    if n[i] > 0.0 {
      idx.push(i)
    }
  }
  let most = stable_sort(idx, (a, b) => {
    let d = n[b] - n[a]
    if d > 0.0 {
      1
    } else if d < 0.0 {
      -1
    } else {
      a - b
    }
  })
  let order = [0] + most + named.map(at).filter(i => i >= 0)
  let seen : Array[Int] = []
  for i in order {
    if !seen.contains(i) {
      seen.push(i)
    }
  }
  seen[:@cmp.minimum(few_most, seen.length())].to_owned().map(i => all[i])
}

///|
/// `askWhich`: why no chat was opened, for the agent: the models to ask the person about.
pub fn ask_which(ask : Array[Json], where_ : String) -> String {
  let named = ask.map(a => {
    let c = field(a, "candidate").unwrap_or(Json::null())
    let n = num_of(a, "n").unwrap_or(0.0)
    let model = match model_of(c) {
      Some(m) => m
      None => "\{runtime_of(c)}'s default"
    }
    let count = if n == 0.0 {
      "not used"
    } else {
      "\{js_number_text(n)} chat\{if n == 1.0 { "" } else { "s" }}"
    }
    "\{model} (runtime \{runtime_of(c)}, \{count} in 30 days)"
  })
  "no model given, and no one model is clearly the most used by the person this chat goes to on \{where_} (the most used must be used at least twice as often as any other): \{named.join("; ")}. Ask them which (in your chat, an options card fits), then call chat_create again with that model and its runtime, and the same key"
}
