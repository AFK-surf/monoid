// The program's harness (reader `--builder harness-agent-runtimes`): a case a line, answered a line each, until stdin
// ends — what station/test/mb-agent-runtimes.test.ts gives this and the TypeScript alike: a function called (`call`),
// a session taken through steps (`session`), a driver's process started and its session opened (`open`), what reads
// or writes the disk (`io`), the agents' home's rounds (`agentHome`).

///|
fn arg(args : Array[J], i : Int) -> J? {
  match args.get(i) {
    Some(v) => Some(v)
    None => None
  }
}

///|
fn sarg(args : Array[J], i : Int) -> String {
  said(arg(args, i))
}

///|
/// A string or undefined (null too).
fn oarg(args : Array[J], i : Int) -> String? {
  str_of(arg(args, i))
}

///|
fn strings(v : J?) -> Array[String] {
  arr(v).map(x => said(Some(x)))
}

///|
fn pairs(v : J?) -> Array[(String, String)] {
  arr(v).map(p => (said(get_i(Some(p), 0)), said(get_i(Some(p), 1))))
}

///|
fn get_i(v : J?, i : Int) -> J? {
  match v {
    Some(Arr(items)) => items.get(i)
    _ => None
  }
}

///|
fn opt_json(v : String?) -> J {
  match v {
    Some(s) => js(s)
    None => Null
  }
}

///|
fn via_of(v : J?) -> Via {
  { provider: str_of(get(v, "provider")), endpoint: str_of(get(v, "endpoint")), protocol: str_of(get(v, "protocol")) }
}

///|
fn Via::json(self : Via) -> J {
  let f = Fields::new()
  for e in [("provider", self.provider), ("endpoint", self.endpoint), ("protocol", self.protocol)] {
    if e.1 is Some(v) {
      f.set_str(e.0, v)
    }
  }
  f.json()
}

///|
fn Source::json(self : Source) -> J {
  let f = Fields::of([
    ("id", js(self.id)),
    ("name", js(self.name)),
    ("endpointRequired", Bool(self.endpoint_required)),
    ("protocols", arr_of(self.protocols)),
    ("keyOptional", Bool(self.key_optional)),
    ("auth", js(self.auth)),
    ("sessionHeader", Bool(self.session_header)),
  ])
  for e in [("chat", self.chat), ("responses", self.responses), ("anthropic", self.anthropic), ("decision", self.decision)] {
    if e.1 is Some(v) {
      f.set_str(e.0, v)
    }
  }
  f.json()
}

///|
fn endpoints_of(v : J?) -> Endpoints {
  {
    chat: str_of(get(v, "chat")),
    responses: str_of(get(v, "responses")),
    anthropic: str_of(get(v, "anthropic")),
    decision: str_of(get(v, "decision")),
  }
}

///|
fn sandbox_of_json(v : J?) -> Sandbox {
  { name: said(get(v, "name")), target: said(get(v, "target")), size: str_of(get(v, "size")), identity: str_of(get(v, "identity")) }
}

///|
fn facts_of(v : J?) -> ModelFacts? {
  match present(v) {
    None => None
    Some(_) => Some({ context: num_of(get(v, "context")), output: num_of(get(v, "output")), sees_images: is_true(get(v, "seesImages")) })
  }
}

///|
fn fields_of(v : J?) -> Fields {
  Fields::of(fields(v))
}

///|
fn result_json(r : Result[J, String]) -> J {
  match r {
    Ok(v) => obj([("ok", v)])
    Err(e) => obj([("error", js(e))])
  }
}

///|
/// A function of the TypeScript's, called with `args` as its JSON gives them.
fn call(name : String, args : Array[J]) -> J {
  let a = (i : Int) => arg(args, i)
  let s = (i : Int) => sarg(args, i)
  let o = (i : Int) => oarg(args, i)
  match name {
    // instructions.ts
    "sessionInstructions" =>
      js(session_instructions(s(0), o(1), s(2), s(3), s(4), site=o(5).unwrap_or(""), station=o(6).unwrap_or(""), move=!(a(7) is Some(Bool(false)))))
    "siteInstructionsOf" => js(site_instructions_of(o(0)))
    "overgrown" => js(overgrown(pairs(a(0))))
    "nameUntitled" => js(name_untitled(s(0)))
    "resumeLost" => js(resume_lost(s(0), strings(a(1)), terminal=o(2)))
    "afresh" => js(afresh(s(0), strings(a(1))))
    "longChat" => js(long_chat(num_of(a(0)).unwrap_or(0.0), strings(a(1))))
    "cleared" => js(cleared(s(0), strings(a(1))))
    "backgroundStopped" => js(background_stopped(arr(a(0)), strings(a(1))))
    "waitOver" => js(wait_over(num_of(a(0)).unwrap_or(0.0)))
    "continuedHere" => js(continued_here(s(0)))
    "threadAddress" => js(thread_address(s(0), s(1)))
    "parseThreadAddress" =>
      match parse_thread_address(s(0)) {
        Some((c, ts)) => arr_of([c, ts])
        None => Null
      }
    "messageForAgent" => js(message_for_agent(a(0).unwrap_or(Null)))
    "formatInbound" => {
      let posts : Map[Int, String] = {}
      for p in arr(a(4)) {
        posts[num_of(get_i(Some(p), 0)).unwrap_or(-1.0).to_int()] = said(get_i(Some(p), 1))
      }
      let cards : Map[Int, CardChange] = {}
      for c in arr(a(5)) {
        let change = get_i(Some(c), 1)
        cards[num_of(get_i(Some(c), 0)).unwrap_or(-1.0).to_int()] = {
          ended_author: said(get(get(change, "ended"), "author")),
          ended_ts: said(get(get(change, "ended"), "ts")),
          current_ts: match present(get(change, "current")) {
            Some(cur) => Some(said(get(Some(cur), "ts")))
            None => None
          },
          special: str_of(get(change, "special")),
        }
      }
      js(
        format_inbound(
          arr(a(0)),
          arr(a(1)).map(x => num_of(Some(x)).unwrap_or(0.0)),
          pairs(a(2)),
          pairs(a(3)),
          posts~,
          cards~,
          self_key=o(6).unwrap_or(""),
        ),
      )
    }
    "formatCardChoices" => js(format_card_choices(arr(a(0)), pairs(a(1)), num_of(a(2)).unwrap_or(0.0)))
    "formatWidgetModels" => js(format_widget_models(arr(a(0))))
    "formatHistory" => {
      let cards : Map[Double, HistoryCard] = {}
      for c in arr(a(5)) {
        let found = get_i(Some(c), 1)
        cards[num_of(get_i(Some(c), 0)).unwrap_or(-1.0)] = {
          card: get(found, "card"),
          pending: is_true(get(found, "pending")),
          chose: match get(found, "chose") {
            Some(ch) => Some((said(get(Some(ch), "by")), get(Some(ch), "option").unwrap_or(Null)))
            None => None
          },
        }
      }
      js(format_history(arr(a(0)), s(1), s(2), s(3), pairs(a(4)), cards~))
    }
    "texts" =>
      obj([
        ("NUDGE", js(nudge)),
        ("RESUME_AFTER_RESTART", js(resume_after_restart)),
        ("GO_ON_AFTER_AUTH", js(go_on_after_auth)),
        ("GO_ON_AFTER_CODEX_UPDATE", js(go_on_after_codex_update)),
        ("GO_ON_AFTER_SPENT", js(go_on_after_spent)),
        ("GO_ON_AFTER_OVERLOADED", js(go_on_after_overloaded)),
        ("GO_ON_AFTER_FAILED", js(go_on_after_failed)),
        ("GO_ON_AFTER_UNANSWERED", js(go_on_after_unanswered)),
        ("GO_ON_AFTER_REFILL", js(go_on_after_refill)),
        ("TOOLS_LOST", js(tools_lost)),
        ("UNDECIDED", js(undecided)),
        ("BACKGROUND_STOPPED_WAITING", js(background_stopped_waiting)),
        ("SITE_INSTRUCTIONS_MAX", int(site_instructions_max)),
        ("MEMORY_MOST", int(memory_most)),
        ("SKILL_MOST", int(skill_most)),
        ("LINE_MOST", int(line_most)),
        ("LONG_CHAT", int(long_chat_from)),
        ("REWRITTEN", int(rewritten)),
        ("NOTES", Arr(notes.map(n => Arr([int(n.0), js(n.1)])))),
        ("latest", int(latest())),
        ("STUB", js(keychain_stub)),
        ("CLAUDE_TOKEN_MARGIN_MS", num(claude_token_margin_ms)),
        ("SANDBOX", js(sandbox_prefix)),
        ("CONNECTION_LOST", js(connection_lost)),
        ("LOST_EXIT", int(lost_exit)),
        ("CONFIG", devin_config()),
        ("LEVELS", arr_of(devin_levels)),
        ("HERMES_MODEL_LIMIT", int(hermes_model_limit)),
        ("FAST_RUNTIMES", arr_of(fast_runtimes)),
        ("OPENCODE", js(opencode)),
        ("OPENCODE_SMALL", js(opencode_small)),
        ("DSH_KEY", js(dsh_key)),
        ("PI_KEY", js(pi_key)),
        ("KIMI_CODE", js(kimi_code)),
        ("SOURCES", Arr(sources.map(x => x.json()))),
      ])
    // migrations.ts
    "untold" => js(untold(num_of(a(0)).unwrap_or(0.0), s(1)))
    // providers.ts
    "find" =>
      match find(s(0)) {
        Some(x) => x.json()
        None => Null
      }
    "legacy" => opt_json(legacy(s(0)))
    "groupOf" => js(group_of(s(0)))
    "cleanEndpoint" => opt_json(clean_endpoint(s(0)))
    "anthropicRoot" => js(anthropic_root(s(0)))
    "endpoints" =>
      match find(s(0)) {
        Some(src) =>
          match endpoints(src, o(1), o(2)) {
            Some(at) => at.json()
            None => Null
          }
        None => Null
      }
    "runtimesOf" => arr_of(runtimes_of(endpoints_of(a(0))))
    // profiles.ts
    "accessKind" => js(access_kind(a(0).unwrap_or(Null)))
    "billedPerUse" => Bool(billed_per_use(a(0).unwrap_or(Null)))
    "kimiSignedIn" => Bool(kimi_signed_in(a(0).unwrap_or(Null)))
    "keyFile" => opt_json(key_file(a(0).unwrap_or(Null)))
    "profileModel" => opt_json(profile_model(a(0).unwrap_or(Null)))
    "isMachine" => Bool(is_machine(a(0).unwrap_or(Null)))
    "profileFast" => Bool(profile_fast(a(0).unwrap_or(Null)))
    "takesFast" => Bool(takes_fast(a(0).unwrap_or(Null)))
    "fastNeedsCredits" => Bool(fast_needs_credits(a(0).unwrap_or(Null)))
    "profileVia" => profile_via(a(0).unwrap_or(Null)).json()
    "apiSource" =>
      match api_source(via_of(a(0))) {
        Some((src, at)) => Arr([src.json(), at.json()])
        None => Null
      }
    "accessEnv" => access_env(s(0), s(1), s(2), o(3), via_of(a(4))).json()
    "codexOverrides" => Arr(codex_overrides(s(0), o(1), via_of(a(2))).map(e => arr_of([e.0, e.1])))
    "dshRoute" =>
      match dsh_route(a(0).unwrap_or(Null)) {
        Some(r) => r.json()
        None => Null
      }
    "piRoute" =>
      match pi_route(a(0).unwrap_or(Null)) {
        Some(r) => r.json()
        None => Null
      }
    "profileRuntimes" => arr_of(profile_runtimes(a(0).unwrap_or(Null)))
    "profileEnv" => profile_env(a(0).unwrap_or(Null), s(1)).json()
    "expandRoute" => expand_route(fields_of(a(0)), s(1)).json()
    "runtimeKind" => opt_json(runtime_kind(a(0)))
    "runtimeLabel" => js(runtime_label(s(0)))
    // sandbox.ts, sandbox-name.ts
    "sandboxesOf" => Arr(sandboxes_of(a(0)).map(x => x.json()))
    "checkSandboxes" => opt_json(check_sandboxes(a(0)))
    "sandboxDescribed" => sandbox_described(sandbox_of_json(a(0)))
    "identityOf" => js(identity_of(s(0)))
    "sandboxOf" => js(sandbox_of(sandbox_of_json(a(0)), s(1)))
    "sandboxName" => js(sandbox_name(s(0)))
    "keyPart" => js(key_part(s(0)))
    "sandboxCommand" => {
      let place = a(2)
      js(
        sandbox_command(
          s(0),
          sandbox_of_json(a(1)),
          { sandbox: said(get(place, "sandbox")), session: said(get(place, "session")), back: strings(get(place, "back")) },
          s(3),
          s(4),
          arr(a(5)).map(x => num_of(Some(x)).unwrap_or(0.0)),
          s(6),
          s(7),
          s(8),
        ),
      )
    }
    // no-keychain.ts, machine-logins.ts
    "keychainItem" => js(keychain_item(s(0)))
    "stubDir" => js(stub_dir(s(0), num_of(a(1)).unwrap_or(0.0).to_int()))
    "credentialsPath" => {
      let env = fields_of(a(0))
      credentials_path(env, is_true(a(1)), s(2), s(3))
      env.json()
    }
    "loginOfKeychain" => opt_json(login_of_keychain(is_true(a(0)), s(1)))
    "parseClaudeCredentials" =>
      match parse_claude_credentials(s(0)) {
        Some(tk) => tk.json()
        None => Null
      }
    "claudeCredentialsFile" => js(claude_credentials_file(fields_of(a(0)), windows=is_true(a(1))))
    "codexHome" => js(codex_home(fields_of(a(0)), windows=is_true(a(1))))
    "codexAuthFile" => js(codex_auth_file(fields_of(a(0)), windows=is_true(a(1))))
    "keychainRead" => {
      let ended = match present(a(0)) {
        Some(e) => Some((num_of(get(Some(e), "code")).unwrap_or(0.0).to_int(), said(get(Some(e), "out"))))
        None => None
      }
      match keychain_read_of(ended) {
        Found(text) => obj([("kind", js("found")), ("text", js(text))])
        Missing => obj([("kind", js("missing"))])
        Unreadable => obj([("kind", js("unreadable"))])
      }
    }
    "claudeCredentialsOf" => {
      let k = a(1)
      let read = if is_s(get(k, "kind"), "found") {
        Found(said(get(k, "text")))
      } else if is_s(get(k, "kind"), "missing") {
        Missing
      } else {
        Unreadable
      }
      match claude_credentials_of(is_true(a(0)), read, o(2)) {
        Some(tk) => tk.json()
        None => Null
      }
    }
    "machineClaudeToken" => {
      let found = match present(a(0)) {
        Some(f) => parse_claude_credentials(stringify(obj([("claudeAiOauth", f)])))
        None => None
      }
      match machine_claude_token_of(found, num_of(a(1)).unwrap_or(0.0)) {
        Ok(tk) => obj([("ok", tk.json())])
        Err(e) => obj([("error", js(e))])
      }
    }
    // repo-rules.ts
    "hookNode" => {
      let has = strings(a(1))
      js(hook_node(s(0), p => has.contains(p), s(2)))
    }
    "hookCommand" => js(hook_command(s(0), s(1), strings(a(2))))
    "agyHookCommand" => js(agy_hook_command(s(0), s(1), s(2)))
    "peerHttpBase" => js(peer_http_base(s(0)))
    // rules-folder.ts, cursor.ts, devin.ts
    "rulesFolderDir" => js(rules_folder_dir(s(0), s(1)))
    "cursorRule" => js(cursor_rule(s(0)))
    "devinRules" => js(devin_rules(s(0)))
    "devinRule" => js(devin_rule(s(0)))
    // dsh.ts
    "dshSetup" => {
      let route = match present(a(0)) {
        None => None
        Some(r) =>
          if is_s(get(Some(r), "kind"), "deepseek") {
            Some(Deepseek)
          } else {
            Some(
              Pi({
                name: said(get(Some(r), "name")),
                api: said(get(Some(r), "api")),
                base_url: said(get(Some(r), "baseURL")),
                headers: match get(Some(r), "headers") {
                  Some(h) => Some(fields_of(Some(h)))
                  None => None
                },
              }),
            )
          }
      }
      result_json(dsh_setup(route, o(1), o(2), s(3), s(4), s(5), s(6), s(7), facts_of(a(8))))
    }
    "patchText" => js(patch_text(a(0).unwrap_or(Arr([]))))
    "dshClassifyFailure" => js(@dsh.classify_failure(s(0), s(1)))
    "dshOutcomeOf" => @dsh.outcome_of(a(0))
    "cursorClassifyFailure" => js(@claude.failure_of(s(0) + " " + s(1)))
    "cursorOutcomeOf" => @cursor.outcome_of(a(0))
    "cursorKeyOf" => opt_json(cursor_key_of(o(0)))
    "cursorSdkPrefix" => js(cursor_sdk_prefix(s(0)))
    // pi.ts
    "piProvider" => {
      let r = a(0)
      let route : PiRoute = {
        name: said(get(r, "name")),
        api: said(get(r, "api")),
        base_url: said(get(r, "baseURL")),
        headers: match get(r, "headers") {
          Some(h) => Some(fields_of(Some(h)))
          None => None
        },
      }
      pi_provider(route, s(1), o(2), s(3), facts_of(a(4)))
    }
    "piSetup" => {
      let route : PiRoute? = match present(a(0)) {
        None => None
        Some(r) =>
          Some({
            name: said(get(Some(r), "name")),
            api: said(get(Some(r), "api")),
            base_url: said(get(Some(r), "baseURL")),
            headers: match get(Some(r), "headers") {
              Some(h) => Some(fields_of(Some(h)))
              None => None
            },
          })
      }
      match pi_setup(route, o(1), Options::of(a(2).unwrap_or(obj([]))), s(3), o(4), s(5), facts_of(a(6))) {
        Ok((argv, setup)) => obj([("ok", obj([("args", arr_of(argv)), ("setup", setup)]))])
        Err(e) => obj([("error", js(e))])
      }
    }
    "piSessionFile" => js(pi_session_file(s(0), s(1)))
    // devin.ts
    "devinKeyOf" => opt_json(devin_key_of(o(0)))
    "splitDevinFusion" =>
      match split_devin_fusion(s(0)) {
        Some(f) => {
          let x = Fields::of([("lead", js(f.lead))])
          if f.effort is Some(e) {
            x.set_str("effort", e)
          }
          x.set_str("side", f.side)
          x.json()
        }
        None => Null
      }
    "devinFusionBase" => {
      let (m, e) = devin_fusion_base(s(0))
      let x = Fields::of([("model", js(m))])
      if e is Some(level) {
        x.set_str("effort", level)
      }
      x.json()
    }
    "variant" => js(devin_variant(s(0), o(1)))
    "expandDevinFusion" => arr_of(expand_devin_fusion(a(0)))
    "devinCatalog" => devin_catalog(a(0))
    "callOf" => devin_call_of(a(0))
    "devinArgs" => arr_of(devin_args(s(0), o(1), o(2)))
    "devinEnv" => devin_env(Options::of(a(0).unwrap_or(obj([]))), fields_of(a(1))).json()
    "devinOutcomeOf" => acp_outcome_of("devin", a(0).unwrap_or(Null))
    "devinClassifyFailure" => js(@claude.failure_of(s(0)))
    // grok.ts
    "grokEffort" => opt_json(grok_effort(o(0)))
    "usageLine" => opt_json(grok_usage_line(a(0), num_of(a(1)).unwrap_or(0.0), a(2).unwrap_or(Null)))
    "grokRules" => js(grok_rules(s(0)))
    "grokArgs" => arr_of(grok_args(o(0), o(1)))
    "grokEnv" => grok_env(Options::of(a(0).unwrap_or(obj([]))), fields_of(a(1))).json()
    "grokClassifyFailure" => js(@acp.classify("grok", s(0)))
    "grokOutcomeOf" => acp_outcome_of("grok", a(0).unwrap_or(Null))
    // hermes.ts
    "hermesCatalog" => arr_of(hermes_catalog(a(0), a(1).unwrap_or(obj([]))))
    "configuredHome" => result_json(configured_home(o(0), s(1), s(2)).map(js))
    "hermesHeaderHome" => result_json(hermes_header_home(s(0), s(1), s(2)).map(js))
    "hermesNewHome" => result_json(hermes_new_home(Options::of(a(0).unwrap_or(obj([]))), s(1)).map(js))
    "hermesVersionRefusal" => opt_json(hermes_version_refusal(a(0)))
    "hermesOutcomeOf" => acp_outcome_of("hermes", a(0).unwrap_or(Null))
    // acp.ts
    "rpc" => js(rpc(s(0), s(1), a(2).unwrap_or(Null)))
    "mcpServers" => mcp_servers(s(0), s(1))
    "errorText" => js(error_text(a(0).unwrap_or(Null)))
    "lastOfTurn" => last_of_turn(s(0), is_true(a(1)), s(2)).unwrap_or(Null)
    // agenthome/module.ts
    "agentHomeFeedback" => Bool(agent_home_feedback(s(0), a(1)))
    "hermesModelsOptions" => {
      let o2 = hermes_models_options(a(0).unwrap_or(obj([])), s(1))
      obj([("key", js(o2.key)), ("cwd", js(o2.cwd)), ("instructions", js(o2.instructions)), ("mcpToken", js(o2.mcp_token)), ("mcpUrl", js(o2.mcp_url)), ("route", js(o2.route))])
    }
    "hermesModelsAgain" => Bool(hermes_models_again(s(0), num_of(a(1)).unwrap_or(0.0), num_of(a(2)).unwrap_or(0.0), is_true(a(3))))
    "hostingOf" => hosting_of(s(0))
    other => obj([("error", js("no such function: \{other}"))])
  }
}

///|
/// The agents' home's rounds through `events` ("change", "flush", "ended", "close").
fn agent_home_case(events : Array[String]) -> J {
  let h = AgentHome::new()
  for e in events {
    match e {
      "change" => h.changed()
      "flush" => h.flush()
      "ended" => h.ended()
      _ => h.close()
    }
  }
  obj([("rounds", int(h.rounds)), ("trace", arr_of(h.trace)), ("running", Bool(h.running))])
}

///|
/// A session of the case's kind made as the driver makes it (`how`: "new", "handed", "crashed").
enum Taken {
  B(Bridged)
  A(Acp)
}

///|
fn Taken::own(self : Taken) -> Own {
  match self {
    B(b) => b.own
    A(a) => a.own
  }
}

///|
async fn session_of(host : @host.Host, c : J?) -> Taken {
  let kind = said(get(c, "kind"))
  let how = said(get(c, "how"))
  let runner = said(get(c, "runner"))
  let options = Options::of(get(c, "options").unwrap_or(obj([])))
  let taken = if kind == "dsh" || kind == "cursor" || kind == "pi" {
    match how {
      "handed" => B(Bridged::handed_over(kind, get(c, "snapshot").unwrap_or(obj([])), runner))
      "crashed" =>
        B(
          Bridged::crashed(
            kind,
            get(c, "replayed").unwrap_or(obj([])),
            options.resume,
            options.mcp_url,
            runner,
            model=options.chosen_model(),
          ),
        )
      _ => {
        let turn = match get(c, "turn") {
          Some(Obj(_) as tn) => fields_of(Some(tn))
          _ => idle_turn(kind)
        }
        let s = Bridged::new(kind, said(get(c, "sessionId")), turn, get(c, "live").unwrap_or(Null), runner, model=str_of(get(c, "model")))
        s.own.tools_url = str_of(get(c, "tools"))
        B(s)
      }
    }
  } else {
    let user_home = said(get(c, "userHome"))
    let new_home = if kind == "hermes" {
      match hermes_new_home(options, user_home) {
        Ok(h) => h
        Err(_) => ""
      }
    } else {
      ""
    }
    let fresh = Acp::new(kind, options.chosen_model(), instructions=options.instructions, profile=options.profile, new_home~, runner~)
    fresh.own.uuids.push_iter(strings(get(c, "uuids")).iter())
    fresh.own.now = num_of(get(c, "now")).unwrap_or(0.0)
    match how {
      "handed" => A(fresh.handed(get(c, "snapshot").unwrap_or(obj([])), runner))
      "crashed" => {
        // (the driver's: the options' or the profile's model as it is given there, over what the session made of it)
        if options.chosen_model() is Some(m) {
          fresh.model = Some(m)
        }
        let replayed = get(c, "replayed").unwrap_or(obj([]))
        let id = match get(Some(replayed), "session") {
          Some(Str(x)) if x.length() > 0 => t(x)
          _ => options.resume.unwrap_or("")
        }
        let last = if kind == "devin" {
          last_of_turn_in(host, join([devin_home(options.home()), devin_sessions]), id, "usage")
        } else {
          None
        }
        fresh.replayed(replayed, options.resume, options.mcp_url, last_usage=last)
        A(fresh)
      }
      _ => {
        fresh.own.tools_url = str_of(get(c, "tools"))
        A(fresh)
      }
    }
  }
  let own = taken.own()
  if kind == "dsh" || kind == "cursor" || kind == "pi" {
    own.uuids.push_iter(strings(get(c, "uuids")).iter())
    own.now = num_of(get(c, "now")).unwrap_or(0.0)
  }
  taken
}

///|
/// What the session's trace says it kept (a transcript's lines, Grok Build's usage), written where the TypeScript
/// writes them: `kept` the transcript's directory, `home` the profile's.
async fn write_kept(host : @host.Host, trace : Array[J], kept : String?, home : String) -> Array[J] {
  let rest = []
  for e in trace {
    match (get(Some(e), "keep"), get(Some(e), "grokUsage")) {
      (Some(k), _) =>
        if kept is Some(dir) {
          // (not made: a line kept where its folder is not is not kept, as the TypeScript's)
          append_file(host, join([dir, "\{said(get_i(Some(k), 0))}.jsonl"]), said(get_i(Some(k), 1))) catch {
            _ => ()
          }
        }
      (_, Some(g)) => grok_keep_usage(host, home, said(get_i(Some(g), 0)), said(get_i(Some(g), 1)))
      _ => rest.push(e)
    }
  }
  rest
}

///|
/// A session through `steps`: each step's trace.
async fn session_case(host : @host.Host, c : J?) -> J {
  let taken = session_of(host, c)
  let own = taken.own()
  let options = Options::of(get(c, "options").unwrap_or(obj([])))
  let kept = match taken {
    A(a) =>
      match a.transcript {
        Some(_) =>
          Some(
            join([
              if a.flavor == "devin" {
                devin_home(options.home())
              } else {
                hermes_home(options.home())
              },
              "sessions",
            ]),
          )
        None => None
      }
    B(_) => None
  }
  let traces : Array[J] = []
  // What the session was made with is said in the first step's trace (a crash's usages read again, kept or not).
  own.trace.clear()
  for step in arr(get(c, "steps")) {
    let st = Some(step)
    let op = said(get(st, "op"))
    let done = (v : J) => own.note("resolved", Arr([js(op), v]))
    let result = (v : J) => own.note("result", v)
    let refused = (why : String?) => match why {
      Some(w) => own.note("rejected", Arr([js(op), js(w)]))
      None => done(Null)
    }
    match op {
      "heard" =>
        match taken {
          B(b) => b.heard_hosted(get(st, "heard"))
          A(a) => a.heard_hosted(get(st, "heard"))
        }
      "prompt" =>
        refused(
          match taken {
            B(b) => b.prompt(said(get(st, "text")))
            A(a) => a.prompt(said(get(st, "text")))
          },
        )
      "steer" => {
        let r = match taken {
          B(b) => b.steer(said(get(st, "text")))
          A(a) => a.steer(said(get(st, "text")))
        }
        own.settle()
        if r is Some(v) {
          done(Bool(v))
        }
      }
      "takeover" =>
        match taken {
          A(a) => result(Bool(a.prompt_takeover(said(get(st, "text")))))
          B(_) => ()
        }
      "abort" => {
        match taken {
          B(b) => b.abort()
          A(a) => a.abort()
        }
        done(Null)
      }
      "exited" => {
        match taken {
          B(b) => b.exited(said(get(st, "said")), said(get(st, "stderr")))
          A(a) => a.exited(said(get(st, "said")), said(get(st, "stderr")))
        }
        own.settle()
      }
      "snapshot" => {
        own.frozen = present(get(st, "frozen"))
        result(
          match taken {
            B(b) => b.snapshot()
            A(a) => a.snapshot()
          },
        )
      }
      "retune" => {
        let o2 = Options::of(get(st, "options").unwrap_or(obj([])))
        result(
          Bool(
            match taken {
              B(b) => b.retune(o2.chosen_model())
              A(a) => a.retune(o2.chosen_model(), o2.effort)
            },
          ),
        )
      }
      "attached" =>
        match taken {
          A(a) => a.attached()
          B(_) => ()
        }
      "named" =>
        match taken {
          A(a) =>
            match a.named(said(get(st, "id"))) {
              Some(why) => own.note("threw", js(why))
              None => result(Null)
            }
          B(b) => {
            b.own.session_id = said(get(st, "id"))
            result(Null)
          }
        }
      "opened" =>
        match taken {
          A(a) => a.open(get(st, "result"))
          B(_) => ()
        }
      "began" =>
        match taken {
          A(a) => a.began(said(get(st, "cwd")))
          B(_) => ()
        }
      "dispose" => {
        own.dispose()
        own.settle()
        done(Null)
      }
      "detach" => own.detach()
      "busy" =>
        result(
          Bool(
            match taken {
              B(b) => b.busy()
              A(a) => a.busy()
            },
          ),
        )
      "id" => result(js(own.session_id))
      "models" =>
        match taken {
          A(a) => result(arr_of(a.available_models))
          B(_) => ()
        }
      _ => own.note("unknown", js(op))
    }
    own.settle()
    own.writing = false
    let trace = write_kept(host, own.trace.copy(), kept, options.home())
    own.trace.clear()
    traces.push(Arr(trace))
  }
  obj([("steps", Arr(traces))])
}

///|
/// A driver's process started (the files it writes, its command line and environment) and its session opened on the
/// answers the case gives each request.
async fn open_case(host : @host.Host, c : J?) -> J {
  let kind = said(get(c, "kind"))
  let options = Options::of(get(c, "options").unwrap_or(obj([])))
  let base = fields_of(get(c, "base"))
  let command = said(get(c, "command"))
  let facts = facts_of(get(c, "facts"))
  let answers = get(c, "answers")
  let answer = (method : String) => get(answers, method)
  let runner = said(get(c, "runner"))
  let start = try {
    match kind {
      "dsh" => dsh_start(host, options, base, command, said(get(c, "bridge")), facts)
      "cursor" =>
        cursor_start(host, options, base, said(get(c, "node")), said(get(c, "bridge")), str_of(get(c, "sdk")), said(get(c, "data")))
      "pi" => pi_start(host, options, base, command, said(get(c, "bridge")), said(get(c, "id")), facts)
      "devin" => devin_start(host, options, base, command)
      "grok" => grok_start(host, options, base, command)
      _ => hermes_start(host, options, base, command, said(get(c, "userHome")), str_of(get(c, "keychainDir")))
    }
  } catch {
    FsError(why) => return obj([("refused", js(why))])
    e => return obj([("refused", js("\{e}"))])
  }
  if kind == "dsh" || kind == "cursor" || kind == "pi" {
    let id = if kind == "pi" { said(get(c, "id")) } else { "" }
    let s = Bridged::new(kind, id, idle_turn(kind), Null, runner, model=if kind == "cursor" { options.chosen_model() } else { None })
    s.own.tools_url = Some(options.mcp_url)
    s.own.uuids.push_iter(strings(get(c, "uuids")).iter())
    let told = obj([("turn", s.own.turn_now())])
    let failed = s.begin(start, answer, no_tools=said(get(c, "noTools")))
    return obj([
      ("start", start.json()),
      ("told", told),
      ("trace", Arr(s.own.trace)),
      ("failed", opt_json(failed)),
      ("id", js(s.own.session_id)),
      ("tools", tools_json(s.own.tools_url)),
    ])
  }
  let user_home = said(get(c, "userHome"))
  let new_home = if kind == "hermes" {
    match hermes_new_home(options, user_home) {
      Ok(h) => h
      Err(_) => ""
    }
  } else {
    ""
  }
  let s = Acp::new(kind, options.chosen_model(), instructions=options.instructions, profile=options.profile, new_home~, runner~)
  s.own.uuids.push_iter(strings(get(c, "uuids")).iter())
  s.own.now = num_of(get(c, "now")).unwrap_or(0.0)
  let key = if kind == "devin" { devin_key(host, options.home()) } else { None }
  let told = obj([("turn", s.own.turn_now())])
  let failed = s.begin({ options, start, probe: is_true(get(c, "probe")), devin_key: key }, answer)
  let kept = match s.transcript {
    Some(_) => Some(join([if kind == "devin" { devin_home(options.home()) } else { hermes_home(options.home()) }, "sessions"]))
    None => None
  }
  let trace = write_kept(host, s.own.trace, kept, options.home())
  obj([
    ("start", start.json()),
    ("told", told),
    ("trace", Arr(trace)),
    ("failed", opt_json(failed)),
    ("id", js(s.own.session_id)),
    ("tools", tools_json(s.own.tools_url)),
    ("model", s.model_json()),
    ("models", arr_of(s.available_models)),
  ])
}

///|
/// What reads or writes the disk.
async fn io_case(host : @host.Host, c : J?) -> J {
  let args = arr(get(c, "args"))
  let s = (i : Int) => sarg(args, i)
  let o = (i : Int) => oarg(args, i)
  try {
    let v : J = match said(get(c, "fn")) {
      "readMemory" => js(read_memory(host, s(0)))
      "readSiteInstructions" => js(read_site_instructions(host, o(0)))
      "rulesFolder" => js(rules_folder(host, s(0), s(1), s(2), s(3), s(4), skills?=o(5)))
      "stubDirSoon" => js(stub_dir_soon(host, s(0), num_of(arg(args, 1)).unwrap_or(0.0).to_int(), s(2)))
      "dshSessionDir" => opt_json(dsh_session_dir(host, s(0), s(1)))
      "grokSessionAt" => opt_json(grok_session_at(host, s(0), s(1)))
      "cursorFindSdk" => opt_json(cursor_find_sdk(host, s(0)))
      "cursorSdkVersion" => opt_json(cursor_sdk_version(host, s(0)))
      "cursorKey" => opt_json(cursor_key_of(read_text(host, join([cursor_home(s(0)), "auth.json"]))))
      "devinKey" => opt_json(devin_key(host, s(0)))
      "lastOfTurnIn" => last_of_turn_in(host, s(0), s(1), s(2)).unwrap_or(Null)
      "hermesSessionHome" => js(hermes_session_home(host, Options::of(arg(args, 0).unwrap_or(obj([]))), s(1), s(2)))
      "linkCodexAuthSoon" => {
        link_codex_auth_soon(host, s(0), fields_of(arg(args, 1)))
        Null
      }
      "ensureIdentity" => {
        ensure_identity(host, s(0))
        Null
      }
      "machineClaudeToken" =>
        match machine_claude_token(host, fields_of(arg(args, 0)), is_true(arg(args, 1)), num_of(arg(args, 2)).unwrap_or(0.0)) {
          Ok(tk) => obj([("ok", tk.json())])
          Err(e) => obj([("error", js(e))])
        }
      "takeBack" => {
        take_back(host, s(0), is_true(arg(args, 1)))
        Null
      }
      other => return obj([("error", js("no such io: \{other}"))])
    }
    obj([("ok", v)])
  } catch {
    FsError(why) => obj([("refused", js(why))])
    e => obj([("refused", js("\{e}"))])
  }
}

///|
pub async fn harness_case(host : @host.Host, c : J) -> J {
  let x = Some(c)
  match said(get(x, "op")) {
    "call" => obj([("ok", call(said(get(x, "fn")), arr(get(x, "args"))))])
    "agentHome" => obj([("ok", agent_home_case(strings(get(x, "events"))))])
    "session" => obj([("ok", session_case(host, x))])
    "open" => obj([("ok", open_case(host, x))])
    "io" => io_case(host, x)
    op => obj([("error", js("no such case: \{op}"))])
  }
}

///|
/// The program's harness: a case a line, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  while true {
    guard host.line() is Some(line) else { break }
    let answer = match parse(line) {
      Some(c) => harness_case(host, c) catch { e => obj([("error", js("\{e}"))]) }
      None => obj([("error", js("not JSON"))])
    }
    host.say(stringify(answer))
  }
}
