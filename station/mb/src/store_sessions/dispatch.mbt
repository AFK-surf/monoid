// Named dispatch for `Store` (store.ts method names), used by station_main's live store bridge.

///|
fn arg(args : Array[Json], i : Int32) -> Json? {
  if i < args.length() {
    Some(args[i])
  } else {
    None
  }
}

///|
fn a(args : Array[Json], i : Int32) -> Json {
  nullish(arg(args, i))
}

///|
fn s(args : Array[Json], i : Int32) -> String {
  js_string(a(args, i))
}

///|
fn d(args : Array[Json], i : Int32) -> Double {
  num_of(a(args, i)).unwrap_or(0.0)
}

///|
fn b(args : Array[Json], i : Int32) -> Bool {
  truthy(a(args, i))
}

///|
fn texts(args : Array[Json], i : Int32) -> Array[String] {
  arr(a(args, i)).map(js_string)
}

///|
fn unit(_ : Unit) -> Json {
  undefined()
}

///|
/// One call of the store's, by its TypeScript name.
pub fn Store::call(self : Store, name : String, x : Array[Json]) -> Json raise {
  match name {
    "notify" => unit(self.notify(s(x, 0)))
    // ── sessions ──
    "getSession" => self.get_session(s(x, 0))
    "sessionWs" => self.session_ws(s(x, 0))
    "sessionKeyByToken" => self.session_key_by_token(s(x, 0))
    "setSessionContextBefore" =>
      unit(self.set_session_context_before(s(x, 0), a(x, 1)))
    "setTitle" => unit(self.set_title(s(x, 0), a(x, 1)))
    "noteCompacted" => unit(self.note_compacted(s(x, 0)))
    "setRuntimeSessionId" => unit(self.set_runtime_session_id(s(x, 0), a(x, 1)))
    "setSessionUsage" => unit(self.set_session_usage(s(x, 0), a(x, 1), b(x, 2)))
    "modelStars" => self.model_stars(a(x, 0), a(x, 1))
    "putModelStars" => unit(self.put_model_stars(a(x, 0), a(x, 1), a(x, 2)))
    "sessionUsage" => self.session_usage(s(x, 0))
    // ── runtime sessions ──
    "runtimeSessions" => Json::array(self.runtime_sessions(s(x, 0)))
    "transcriptReferenced" =>
      jbool(self.transcript_referenced(a(x, 0), a(x, 1), a(x, 2)))
    "sessionPathsPage" =>
      Json::array(
        self.session_paths_page(
          a(x, 0),
          match arg(x, 1) {
            Some(Number(n, ..)) => n.to_int()
            _ => 200
          },
        ),
      )
    "setRunning" => unit(self.set_running(s(x, 0), b(x, 1)))
    "setThreadTitle" => unit(self.set_thread_title(a(x, 0), a(x, 1)))
    "homeChat" => self.home_chat(a(x, 0))
    // ── hand-overs ──
    "chatThreads" =>
      Json::array(
        self.chat_threads(
          texts(x, 0),
          a(x, 1),
          num_of(a(x, 2)).unwrap_or(500.0).to_int(),
        ),
      )
    "chatPage" =>
      Json::array(
        self.chat_page(
          s(x, 0),
          a(x, 1),
          a(x, 2),
          num_of(a(x, 3)).unwrap_or(500.0).to_int(),
          texts(x, 4),
        ),
      )
    "importCtx" => self.import_ctx(a(x, 0))
    "forgetImport" => unit(self.forget_import(a(x, 0)))
    "dropImport" => unit(self.drop_import(a(x, 0)))
    "showChat" => unit(self.show_chat(texts(x, 0), a(x, 1)))
    "notGone" => strings(self.not_gone(texts(x, 0), a(x, 1)))
    "goneTo" => unit(self.gone_to(texts(x, 0), a(x, 1), a(x, 2)))
    "shownThere" => unit(self.shown_there(texts(x, 0), a(x, 1)))
    "deliveredThere" => unit(self.delivered_there(texts(x, 0)))
    "liveOf" => Json::array(self.live_of(texts(x, 0)))
    "handedTo" => self.handed_to(s(x, 0))
    "handedChats" => Json::array(self.handed_chats(a(x, 0), a(x, 1)))
    "setMovedNote" => unit(self.set_moved_note(s(x, 0), a(x, 1)))
    "sessionsOfConnect" =>
      Json::array(
        self.sessions_of_connect(a(x, 0), a(x, 1), or_else(a(x, 2), jstr(""))),
      )
    "binding" => self.binding(a(x, 0))
    "setBinding" => unit(self.set_binding(a(x, 0), a(x, 1)))
    // ── identities and turns ──
    "setSlackIdentity" =>
      unit(self.set_slack_identity(a(x, 0), a(x, 1), b(x, 2)))
    "startTurnFor" =>
      unit(self.start_turn_for(a(x, 0), a(x, 1), a(x, 2), a(x, 3)))
    "setWaitFor" => unit(self.set_wait_for(a(x, 0), a(x, 1), b(x, 2)))
    "setAbout" => unit(self.set_about(a(x, 0), a(x, 1)))
    "setNeed" => unit(self.set_need(a(x, 0), a(x, 1)))
    "declareTurn" => unit(self.declare_turn(a(x, 0), a(x, 1), a(x, 2)))
    "endTurn" =>
      unit(self.end_turn(a(x, 0), a(x, 1), a(x, 2), a(x, 3), a(x, 4)))
    "endCutOff" => ints(self.end_cut_off(a(x, 0)))
    "stopWait" => jbool(self.stop_wait(a(x, 0), b(x, 1)))
    "forgetWait" => unit(self.forget_wait(a(x, 0)))
    "lastTurn" => self.last_turn(a(x, 0))
    "slackStop" => self.slack_stop(a(x, 0), a(x, 1), a(x, 2), a(x, 3))
    "rememberSlackStop" =>
      unit(
        self.remember_slack_stop(
          a(x, 0),
          a(x, 1),
          a(x, 2),
          a(x, 3),
          a(x, 4),
          a(x, 5),
        ),
      )
    "listTurns" => Json::array(self.list_turns(a(x, 0)))
    "failedTurnsNear" =>
      Json::array(self.failed_turns_near(a(x, 0), a(x, 1), a(x, 2), a(x, 3)))
    // ── processes, jobs, widgets ──
    "forgetProcess" => unit(self.forget_process(a(x, 0)))
    "jobEnded" => unit(self.job_ended(a(x, 0), a(x, 1), a(x, 2)))
    "getJob" => self.get_job(a(x, 0))
    "jobByToken" => self.job_by_token(a(x, 0))
    "jobsUp" => Json::array(self.jobs_up())
    "jobsUpOf" => Json::array(self.jobs_up_of(arr(a(x, 0))))
    "liveSessionsOn" => Json::array(self.live_sessions_on(a(x, 0), a(x, 1)))
    "jobsMarkOf" => self.jobs_mark_of(arr(a(x, 0)))
    "jobAtPort" => self.job_at_port(a(x, 0))
    "remoteQueueJobs" => Json::array(self.remote_queue_jobs())
    "runningJobsAtLeast" => jbool(self.running_jobs_at_least(a(x, 0), d(x, 1)))
    "addJobNotice" => unit(self.add_job_notice(a(x, 0), a(x, 1)))
    "jobNotices" => Json::array(self.job_notices(a(x, 0), a(x, 1)))
    "putWidgetState" =>
      unit(self.put_widget_state(a(x, 0), a(x, 1), a(x, 2), a(x, 3)))
    "markWidgetModelsTold" =>
      unit(self.mark_widget_models_told(a(x, 0), arr(a(x, 1))))
    // ── usage ──
    "usageChanged" => unit(self.usage_changed(arr(a(x, 0)), arg(x, 1), b(x, 2)))
    "firstText" => self.first_text(a(x, 0))
    other => raise store_error("no call \{other}")
  }
}
