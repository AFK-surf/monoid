// The rest of the harness's functions, by module (harness.mbt).

///|
fn strs(v : J?) -> Array[String] {
  arr_of(v).unwrap_or([]).map(x => str_of(Some(x)).unwrap_or(""))
}

///|
fn opt_str(v : J?) -> String? {
  str_of(v)
}

///|
fn opt_bool(v : J?) -> Bool? {
  match v {
    Some(Bool(b)) => Some(b)
    _ => None
  }
}

///|
fn pure_more(h : Harness, name : String, args : Array[J]) -> J raise Thrown {
  let words = h.words.val
  let lang = h.lang.val
  let a = (i : Int) => arg(args, i).unwrap_or(Null)
  match name {
    "allowedIn" => jb(allowed_in(a(0), opt_str(arg(args, 1)), opt_str(arg(args, 2))))
    "profilesFor" => ja(profiles_for(a(0), a(1), opt_str(arg(args, 2))))
    "runtimeTitle" => js(runtime_title(sarg(args, 0)))
    "runtimeKind" => jopt(runtime_kind(arg(args, 0)))
    "ccText" => js(cc_text(words, lang, sarg(args, 0), sarg(args, 1)))
    "chatNamed" => js(chat_named(sarg(args, 0), sarg(args, 1), opt_str(arg(args, 2))))
    "header" =>
      js(message_header(words, lang, sarg(args, 0), sarg(args, 1), opt_str(arg(args, 2)), a(3) is Bool(true), opt_bool(arg(args, 4))))
    "acceptsCompletion" => jb(accepts_completion(a(0), num_of(arg(args, 1)).unwrap_or(0.0)))
    "completionQuestion" => completion_question()
    "request" => decision_request(a(0), a(1), a(2))
    "parse" => decision_parse(a(0), a(1), a(2))
    "decisionPriority" => ji(decision_priority(sarg(args, 0)))
    "sortByDecisionPriority" => {
      let xs = strs(arg(args, 0))
      xs.sort_by(by_decision_priority)
      jsa(xs)
    }
    "codexConfig" =>
      match codex_config(sarg(args, 0)) {
        Some(c) => c
        None => J::Null
      }
    "transport" => decision_transport(a(0), sarg(args, 1))
    "presetRefusal" => jopt(preset_refusal(words, a(0), opt_str(arg(args, 1)), a(2), sarg(args, 3)))
    "originIn" => jopt(origin_in(sarg(args, 0)))
    "repoName" => js(repo_name(sarg(args, 0)))
    "presetInstructions" => js(preset_instructions(a(0)))
    "presetCopyInput" => preset_copy_input(a(0))
    "canonical" => js(canonical(a(0)))
    "newerRecord" => newer_record(a(0), a(1))
    "goneKept" => ja(gone_kept(arr_of(arg(args, 0)).unwrap_or([])))
    "recordsKept" => {
      let pairs = match a(0) {
        Obj(fs) => fs.map(f => (@jsjson.sanitize_str(f.0), f.1))
        _ => []
      }
      jo(records_kept(pairs))
    }
    "modelOf" =>
      match model_of(arg(args, 0)) {
        Some(m) => m
        None => J::Null
      }
    "stationsOf" => jo(station_fields(stations_of(arg(args, 0))))
    "recordOf" => record_of(a(0))
    "theirs" => jb(presets_theirs(a(0), a(1)))
    "notice" => js(opened_notice(sarg(args, 0), opt_str(arg(args, 1)), sarg(args, 2), opt_str(arg(args, 3)), opt_bool(arg(args, 4))))
    "declaredStr" => js(declared_str(a(0)))
    "saidAs" => js(said_as(a(0)))
    "aboutTs" => jopt(about_ts(a(0)))
    "jsNumber" =>
      match js_number(a(0)) {
        Some(d) => if d.is_nan() { js("NaN") } else if d.is_inf() { js(if d > 0.0 { "Infinity" } else { "-Infinity" }) } else { jn(d) }
        None => J::Null
      }
    "jsString" => js(js_string(a(0)))
    "postBlockThreads" => ja(post_block_threads(arr_of(arg(args, 0)).unwrap_or([])).map(p => ja([p.0, jn(p.1)])))
    "postBlockAnswered" => jb(post_block_answered(a(0) is Bool(true), num_of(arg(args, 1)), num_of(arg(args, 2)).unwrap_or(0.0)))
    "facts" =>
      match facts_of(bytes_arg(args, 0)) {
        Some(f) => f.to_j()
        None => J::Null
      }
    _ => raise fail_("no such function: \{name}")
  }
}

///|
fn opt_j(v : J?) -> J {
  match v {
    Some(x) => x
    None => J::Null
  }
}

///|
fn who_arg(v : J?) -> J? {
  match v {
    Some(Obj(_) as o) => Some(o)
    _ => None
  }
}

///|
/// The index of the harness, kept across asks (as a station keeps one).
let repo_index : Ref[RepoIndex] = Ref::new(RepoIndex::new())

///|
async fn asks_more(h : Harness, w : World, name : String, args : Array[J]) -> J {
  ignore(h)
  let a = (i : Int) => arg(args, i).unwrap_or(Null)
  match name {
    "hubConfig" => {
      let found = a(2)
      hub_config(w, a(0), sarg(args, 1), id => match at(Some(found), id) {
        Some(Arr(xs)) => Some(xs.map(x => str_of(Some(x)).unwrap_or("")))
        _ => None
      })
    }
    "spelling" => jopt(spelling(w, a(0), sarg(args, 1)))
    "runs" => jb(runs(w, a(0), sarg(args, 1)))
    "sameModel" => jb(same_model(w, sarg(args, 0), sarg(args, 1)))
    "cc" => {
      cc(w, a(0), sarg(args, 1), sarg(args, 2), sarg(args, 3), a(4), arr_of(arg(args, 5)).unwrap_or([]))
      J::Null
    }
    "cardPlace" =>
      match card_place(w, sarg(args, 0), a(1), a(2)) {
        Some(v) => v
        None => J::Null
      }
    "recordPostedCard" | "postCard" => {
      // args: session, thread, text, card, posted (record only), occupied kind or null, needed answers or null
      let base = if name == "postCard" { 0 } else { 1 }
      let occupied_kind = str_of(arg(args, 4 + base))
      let occupied = match occupied_kind {
        Some(k) => Some(fn(why : String) -> Error { Thrown(k, why) })
        None => None
      }
      let needed_seq = arr_of(arg(args, 5 + base))
      let needed = match needed_seq {
        Some(seq) => {
          let i = Ref::new(0)
          Some(async fn() -> Bool {
            let v = seq.get(i.val).unwrap_or(Bool(true))
            i.val += 1
            v is Bool(true)
          })
        }
        None => None
      }
      if name == "postCard" {
        post_card(w, sarg(args, 0), a(1), sarg(args, 2), a(3), occupied, needed)
      } else {
        record_posted_card(w, sarg(args, 0), a(1), sarg(args, 2), a(3), a(4), occupied, needed, message_identity(w, sarg(args, 0)))
      }
    }
    "senderTitleIfReady" =>
      match sender_title_if_ready(w, sarg(args, 0)) {
        Some(v) => v
        None => J::Null
      }
    "sender" => {
      let (t, l) = sender(w, sarg(args, 0))
      ja([js(t), jopt(l)])
    }
    "sessionSend" => js(session_send(w, sarg(args, 0), a(1)))
    "fromPeer" => from_peer(w, sarg(args, 0), a(1), opt_str(arg(args, 2)))
    "postFrom" =>
      js(post_from(w, a(0), sarg(args, 1), sarg(args, 2), opt_str(arg(args, 3)), sarg(args, 4), strs(arg(args, 5)), a(6), a(7) is Bool(true)))
    "target" => target(w, sarg(args, 0), arg(args, 1))
    "mayStage" => jb(may_stage(w, a(0), a(1) is Bool(true)))
    "staged" => {
      let (next, copies) = staged(w, sarg(args, 0), a(1), a(2) is Bool(true))
      if a(3) is Bool(true) {
        staged_done(w, copies)
      }
      jo([("args", next)])
    }
    "attach" => attach(w, sarg(args, 0), strs(arg(args, 1)), match str_of(arg(args, 2)) { Some(x) => x; None => sarg(args, 0) })
    "chatPost" => {
      let held = unheld(w, sarg(args, 0), a(1))
      js(chat_post(w, sarg(args, 0), held.args, held))
    }
    "unheld" => {
      let held = unheld(w, sarg(args, 0), a(1))
      jo([("id", jopt(held.id)), ("args", held.args)])
    }
    "chatState" => js(chat_state(w, sarg(args, 0), a(1)))
    "chatLeave" => js(chat_leave(w, sarg(args, 0), a(1)))
    "chatHistory" => js(chat_history(w, sarg(args, 0), a(1)))
    "threadHistory" => {
      let seen = []
      let text = thread_history(w, sarg(args, 0), a(1), sarg(args, 2), sarg(args, 3), a(4), Some(seen))
      jo([("text", js(text)), ("seen", ja(seen))])
    }
    "slackConnectOf" => js(slack_connect_of(w, sarg(args, 0), opt_str(arg(args, 1))))
    "slackApi" =>
      js(slack_api(w, sarg(args, 0), sarg(args, 1), a(2), opt_str(arg(args, 3)), opt_str(arg(args, 4)), a(5) is Bool(true)))
    "policyWs" => policy_ws(w, a(0))
    "policyStamp" => policy_stamp(w, sarg(args, 0))
    "review" => {
      review(w, sarg(args, 0))
      J::Null
    }
    "undecided" => jsa(undecided(w))
    "startReview" =>
      match start_review(w) {
        Some(n) => jn(n)
        None => J::Null
      }
    "reviewUndecidedOnce" => {
      review_undecided_once(w)
      J::Null
    }
    "validate" => {
      validate_decision(w, a(0))
      J::Null
    }
    "decide" => decide(w, a(0), a(1), a(2))
    "connection" => opt_j(decision_connection(w, a(0)))
    "fingerprint" => js(fingerprint(w, a(0)))
    "resolvedModel" => opt_j(resolved_model(w, a(0), a(1), a(2)))
    "discover" => discover(w, a(0), a(1))
    "readPresetsFile" => {
      let f = read_presets_file(w, sarg(args, 0), sarg(args, 1))
      jo([("presets", ja(f.presets)), ("gone", ja(f.gone))])
    }
    "presetInput" => preset_input(w, a(0))
    "originOf" => jopt(origin_of(w, sarg(args, 0)))
    "presets.list" => ja(presets_list(w, a(0)))
    "presets.listed" => ja(presets_listed(w, a(0)))
    "presets.get" => presets_get(w, a(0), sarg(args, 1))
    "presets.add" => presets_add(w, a(0), a(1), sarg(args, 2), str_of(arg(args, 3)).unwrap_or(""))
    "presets.put" => presets_put(w, a(0), sarg(args, 1), a(2), who_arg(arg(args, 3)))
    "presets.delete" => {
      presets_delete(w, a(0), sarg(args, 1), who_arg(arg(args, 2)))
      J::Null
    }
    "presets.record" => presets_record(w, a(0), a(1))
    "presets.kept" => ja(presets_kept(w, a(0), a(1)))
    "presets.others" => ja(presets_others(w, a(0), a(1)))
    "presets.carry" => presets_carry(w, a(0), a(1), arr_of(arg(args, 2)).unwrap_or([]))
    "presets.keepFor" => presets_keep_for(w, sarg(args, 0), a(1), sarg(args, 2))
    "presets.isHere" => jb(presets_is_here(w, sarg(args, 0)))
    "presets.nameOf" => js(presets_name_of(w, sarg(args, 0), opt_str(arg(args, 1))))
    "keepCopy" => keep_copy(w, sarg(args, 0), a(1))
    "presetCopyOf" => preset_copy_of(w, sarg(args, 0))
    "shortPath" => js(short_path(w, sarg(args, 0)))
    "candidates" => {
      let here = strs(arg(args, 3))
      ja(candidates(w, sarg(args, 0), arr_of(arg(args, 1)).unwrap_or([]), arr_of(arg(args, 2)).unwrap_or([]), async fn(s) { here.contains(s) }))
    }
    "repoIcon" => jopt(repo_icon(w, sarg(args, 0)))
    "repoIndex.reset" => {
      repo_index.val = RepoIndex::new()
      J::Null
    }
    "repoIndex.repos" => {
      let (repos, due) = repo_index.val.repos(w)
      jo([("repos", ja(repos)), ("due", jb(due))])
    }
    "repoIndex.walk" => {
      repo_index.val.walk(w)
      J::Null
    }
    "chatCreate" => js(chat_create(w, sarg(args, 0), a(1)))
    "createForPeer" => create_for_peer(w, sarg(args, 0), a(1), a(2))
    "settled" => {
      settled(w, sarg(args, 0), sarg(args, 1), opt_str(arg(args, 2)))
      J::Null
    }
    "noticeForPeer" => notice_for_peer(w, sarg(args, 0), a(1), a(2))
    "titleCompletion" => opt_j(title_completion(w, a(0), opt_str(arg(args, 1)), sarg(args, 2)))
    "completeTitle" => js(complete_title(w, a(0), sarg(args, 1), sarg(args, 2)))
    "regenerateTitle" => js(regenerate_title(w, a(0), arr_of(arg(args, 1)).unwrap_or([])))
    "suggestArchive" => {
      suggest_archive(w, sarg(args, 0))
      J::Null
    }
    _ => raise fail_("no such function: \{name}")
  }
}
