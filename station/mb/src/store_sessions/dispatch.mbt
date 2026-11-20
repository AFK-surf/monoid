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
fn lists(pairs : Array[(String, Array[String])]) -> Json {
  entries(pairs.map(p => (p.0, strings(p.1))))
}

///|
/// A page's calls (`[method, key?]` each), answered in turn.
fn page_ops(page : SessionPage, ops : Array[Json]) -> Json raise {
  let out = []
  for op in ops {
    let o = arr(op)
    let key = if o.length() > 1 { js_string(o[1]) } else { "" }
    out.push(
      match js_string(o[0]) {
        "keys" => strings(page.keys)
        "rows" => Json::array(page.rows())
        "session" => page.session(key)
        "homeMembers" =>
          match page.home_members(key) {
            Some(list) => strings(list)
            None => Json::null()
          }
        "ranOn" => strings(page.ran_on(key))
        other => raise store_error("no page call \{other}")
      },
    )
  }
  Json::array(out)
}

///|
/// One call of the store's, by its TypeScript name.
pub fn Store::call(self : Store, name : String, x : Array[Json]) -> Json raise {
  let db = self.db
  match name {
    "told" => unit(self.told(arr(a(x, 0))))
    "notify" => unit(self.notify(s(x, 0)))
    // ── sessions ──
    "getSession" => self.get_session(s(x, 0))
    "sessionsOf" => Json::array(self.sessions_of(texts(x, 0)))
    "sessionWs" => self.session_ws(s(x, 0))
    "sessionKeyByToken" => self.session_key_by_token(s(x, 0))
    "sessionByToken" => self.session_by_token(s(x, 0))
    "archivedSessions" => self.archived_sessions(a(x, 0), a(x, 1))
    "lastArchivedSession" => self.last_archived_session()
    "nextArchivedAt" => self.next_archived_at(a(x, 0))
    "listSessions" => Json::array(self.list_sessions())
    "liveSessions" => Json::array(self.live_sessions())
    "recoveryWaits" => self.recovery_waits()
    "awakeWait" => self.awake_wait(d(x, 0), d(x, 1))
    "runningSessions" => Json::array(self.running_sessions())
    "sessionsInUse" => Json::array(self.sessions_in_use())
    "sessionCounts" => self.session_counts(a(x, 0))
    "overviewSessionCounts" =>
      self.overview_session_counts(a(x, 0), arr(a(x, 1)))
    "anyRunning" => jbool(self.any_running())
    "setSessionsWs" => unit(self.set_sessions_ws(a(x, 0), a(x, 1)))
    "insertSession" => unit(self.insert_session(a(x, 0)))
    "setSessionProfile" =>
      unit(self.set_session_profile(s(x, 0), a(x, 1), b(x, 2), arg(x, 3)))
    "setSessionRuntime" =>
      unit(
        self.set_session_runtime(
          s(x, 0),
          a(x, 1),
          a(x, 2),
          b(x, 3),
          a(x, 4),
          a(x, 5),
          arg(x, 6),
          a(x, 7),
          arg(x, 8),
        ),
      )
    "setSessionModel" => unit(self.set_session_model(s(x, 0), a(x, 1), a(x, 2)))
    "setSessionFast" => unit(self.set_session_fast(s(x, 0), arg(x, 1)))
    "setSessionContext" => unit(self.set_session_context(s(x, 0), a(x, 1)))
    "setSessionContextBefore" =>
      unit(self.set_session_context_before(s(x, 0), a(x, 1)))
    "setSessionAfresh" => unit(self.set_session_afresh(s(x, 0), arg(x, 1)))
    "setSessionTui" => unit(self.set_session_tui(s(x, 0), a(x, 1) == Json::boolean(true)))
    "setSessionSpeed" => unit(self.set_session_speed(s(x, 0), a(x, 1)))
    "codexSessionSpeed" => self.codex_session_speed(s(x, 0))
    "codexSessionFast" => self.codex_session_fast(s(x, 0))
    "setTitle" => unit(self.set_title(s(x, 0), a(x, 1)))
    "noteCompacted" => unit(self.note_compacted(s(x, 0)))
    "setRuntimeSessionId" => unit(self.set_runtime_session_id(s(x, 0), a(x, 1)))
    "conversationSince" => self.conversation_since(s(x, 0))
    "setTranscriptLength" => unit(self.set_transcript_length(s(x, 0), a(x, 1)))
    "setTranscriptLengths" =>
      unit(
        self.set_transcript_lengths(
          arr(a(x, 0)).map(p => (js_string(arr(p)[0]), arr(p)[1])),
        ),
      )
    "setSessionUsage" => unit(self.set_session_usage(s(x, 0), a(x, 1), b(x, 2)))
    "deviceBuilds" => Json::array(self.device_builds())
    "putDeviceBuild" => unit(self.put_device_build(a(x, 0), a(x, 1), a(x, 2)))
    "modelStars" => self.model_stars(a(x, 0), a(x, 1))
    "putModelStars" => unit(self.put_model_stars(a(x, 0), a(x, 1), a(x, 2)))
    "deviceBuildsSince" => self.device_builds_since(a(x, 0))
    "sessionUsage" => self.session_usage(s(x, 0))
    "sessionKeys" => Json::array(self.session_keys())
    "ranIn" => unit(self.ran_in(s(x, 0), a(x, 1), a(x, 2)))
    "followProfiles" => {
      let map : Map[String, String] = Map([])
      for p in arr(a(x, 1)) {
        map[js_string(arr(p)[0])] = js_string(arr(p)[1])
      }
      jbool(self.follow_profiles(s(x, 0), map))
    }
    "ranOn" => self.ran_on(s(x, 0), a(x, 1))
    // ── shares ──
    "chatShare" => self.chat_share(a(x, 0))
    "chatShares" => self.chat_shares()
    "refreshChatShareIndex" => jbool(self.refresh_chat_share_index())
    "chatShareLapsed" => jbool(self.chat_share_lapsed(a(x, 0), a(x, 1)))
    "lapsedShareWorkspaces" => self.lapsed_share_workspaces(a(x, 0))
    "usedChatShare" => unit(self.used_chat_share(a(x, 0), arr(a(x, 1))))
    "lapseChatShares" => self.lapse_chat_shares(d(x, 0))
    "setChatShare" =>
      unit(self.set_chat_share(a(x, 0), arr(a(x, 1)), b(x, 2), a(x, 3)))
    // ── opened ──
    "insertOpened" => unit(self.insert_opened(a(x, 0)))
    "openedWith" => self.opened_with(a(x, 0), a(x, 1), a(x, 2), a(x, 3))
    "effortsUsedBy" =>
      Json::array(self.efforts_used_by(a(x, 0), a(x, 1), a(x, 2), a(x, 3)))
    "openerOf" => self.opener_of(a(x, 0))
    "modelsUsedBy" => Json::array(self.models_used_by(a(x, 0), a(x, 1)))
    "openedBy" => Json::array(self.opened_by(a(x, 0)))
    "setOpenedState" => unit(self.set_opened_state(a(x, 0), a(x, 1), a(x, 2)))
    // ── runtime sessions ──
    "sessionOfRuntime" => self.session_of_runtime(a(x, 0), a(x, 1))
    "runtimeSessions" => Json::array(self.runtime_sessions(s(x, 0)))
    "runtimeSessionSources" =>
      Json::array(self.runtime_session_sources(s(x, 0), arg(x, 1)))
    "runtimeSessionSource" => self.runtime_session_source(s(x, 0), s(x, 1))
    "transcriptInUse" =>
      jbool(self.transcript_in_use(a(x, 0), a(x, 1), a(x, 2)))
    "setRunning" => unit(self.set_running(s(x, 0), b(x, 1)))
    "touch" => unit(self.touch(s(x, 0)))
    "setArchived" => unit(self.set_archived(s(x, 0), b(x, 1), s(x, 2)))
    "manuallyArchived" => jbool(self.manually_archived(a(x, 0)))
    "setThreadHidden" => unit(self.set_thread_hidden(a(x, 0), b(x, 1), s(x, 2)))
    "setThreadTitle" => unit(self.set_thread_title(a(x, 0), a(x, 1)))
    "retitled" => unit(self.retitled(a(x, 0)))
    "titleRevision" => ints(self.title_revision(a(x, 0)))
    "setGeneratedTitle" => unit(self.set_generated_title(a(x, 0), a(x, 1)))
    "autoTitle" => self.auto_title(a(x, 0))
    "setAutoTitle" => unit(self.set_auto_title(a(x, 0), a(x, 1), b(x, 2)))
    "peopleSaidAfter" => self.people_said_after(a(x, 0), a(x, 1), d(x, 2))
    "postAfter" => self.post_after(s(x, 0), a(x, 1), a(x, 2))
    "postsAfter" => self.posts_after(s(x, 0), arr(a(x, 1)))
    "lastReadAt" => self.last_read_at(a(x, 0))
    "homeChat" => self.home_chat(a(x, 0))
    "chatsOfTheirOwn" => Json::array(self.chats_of_their_own())
    "deleteSession" => unit(self.delete_session(s(x, 0)))
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
    "importRows" =>
      unit(self.import_rows(a(x, 0), s(x, 1), arr(a(x, 2)), arg(x, 3)))
    "importCtx" => self.import_ctx(a(x, 0))
    "forgetImport" => unit(self.forget_import(a(x, 0)))
    "dropImport" => unit(self.drop_import(a(x, 0)))
    "showChat" => unit(self.show_chat(texts(x, 0), a(x, 1)))
    "notGone" => strings(self.not_gone(texts(x, 0), a(x, 1)))
    "handOff" => unit(self.hand_off(texts(x, 0), a(x, 1), a(x, 2), a(x, 3)))
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
    "sessionsOfWs" =>
      Json::array(
        self.sessions_of_ws(a(x, 0), a(x, 1), a(x, 2), d(x, 3).to_int()),
      )
    "sessionPageOfWs" =>
      page_ops(
        self.session_page_of_ws(a(x, 0), a(x, 1), a(x, 2), d(x, 3).to_int()),
        arr(a(x, 4)),
      )
    "sessionPage" =>
      page_ops(
        self.session_page(
          texts(x, 0),
          match a(x, 1) {
            Array(rows) => Some(rows)
            _ => None
          },
        ),
        arr(a(x, 2)),
      )
    "stillfailHomes" => lists(self.stillfail_homes(texts(x, 0)))
    "ranOnOf" => lists(self.ran_on_of(texts(x, 0)))
    "dropConnectThreadStation" =>
      unit(self.drop_connect_thread_station(a(x, 0), a(x, 1), a(x, 2)))
    "binding" => self.binding(a(x, 0))
    "setBinding" => unit(self.set_binding(a(x, 0), a(x, 1)))
    "listBindings" => self.list_bindings()
    "preparedSessionBound" => jbool(self.prepared_session_bound(a(x, 0)))
    // ── the hand-overs' own (store/handover.ts) ──
    "handover.afterOf" => after_of(s(x, 0), a(x, 1))
    "handover.surfaceHere" => jstr(surface_here(s(x, 0), a(x, 1)))
    "handover.newCtx" => new_ctx(a(x, 0))
    "handover.putUsage" => {
      let r = obj(a(x, 0)).copy()
      jbool(put_usage(db, r))
    }
    "handover.handedWithUsage" =>
      Json::array(
        handed_with_usage(
          db,
          a(x, 0),
          a(x, 1),
          num_of(a(x, 2)).unwrap_or(10.0).to_int(),
        ),
      )
    "handover.handedStations" => Json::array(handed_stations(db))
    "handover.threadRefs" => Json::array(thread_refs(db, a(x, 0), arr(a(x, 1))))
    "handover.threadOfRef" => thread_of_ref(db, a(x, 0), a(x, 1), a(x, 2))
    "handover.hasUsage" => jbool(has_usage(db, a(x, 0)))
    "handover.importHandedUsage" =>
      import_handed_usage(db, a(x, 0), self.in_tx())
    // ── identities and turns ──
    "slackIdentities" => Json::array(self.slack_identities(a(x, 0)))
    "setSlackIdentity" =>
      unit(self.set_slack_identity(a(x, 0), a(x, 1), b(x, 2)))
    "hasTurns" => jbool(self.has_turns(a(x, 0)))
    "startTurn" => unit(self.start_turn(a(x, 0), a(x, 1), a(x, 2)))
    "startTurnFor" =>
      unit(self.start_turn_for(a(x, 0), a(x, 1), a(x, 2), a(x, 3)))
    "setWaitFor" => unit(self.set_wait_for(a(x, 0), a(x, 1), b(x, 2)))
    "setAbout" => unit(self.set_about(a(x, 0), a(x, 1)))
    "toldNotes" => self.told_notes(a(x, 0))
    "setToldNotes" => unit(self.set_told_notes(a(x, 0), a(x, 1)))
    "setNeed" => unit(self.set_need(a(x, 0), a(x, 1)))
    "declareTurn" => unit(self.declare_turn(a(x, 0), a(x, 1), a(x, 2)))
    "endTurn" =>
      unit(self.end_turn(a(x, 0), a(x, 1), a(x, 2), a(x, 3), a(x, 4)))
    "endCutOff" => ints(self.end_cut_off(a(x, 0)))
    "stopWait" => jbool(self.stop_wait(a(x, 0), b(x, 1)))
    "forgetWait" => unit(self.forget_wait(a(x, 0)))
    "latestTurn" => self.latest_turn(a(x, 0))
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
    "lastTurnsOf" => self.last_turns_of(texts(x, 0))
    "waitingForPeople" => Json::array(self.waiting_for_people(a(x, 0), a(x, 1)))
    "workOf" => self.work_of(a(x, 0))
    "statsOf" => self.stats_of(texts(x, 0))
    "sessionStats" => self.session_stats(a(x, 0))
    // ── profiles, processes, jobs, widgets ──
    "profileStatus" => self.profile_status()
    "setProfileCheck" => unit(self.set_profile_check(a(x, 0), a(x, 1)))
    "setProfileQuota" => unit(self.set_profile_quota(a(x, 0), a(x, 1)))
    "profileHours" => self.profile_hours(d(x, 0))
    "forgetProfileHours" => unit(self.forget_profile_hours(a(x, 0)))
    "recordProcess" =>
      unit(self.record_process(a(x, 0), a(x, 1), a(x, 2), a(x, 3)))
    "forgetProcess" => unit(self.forget_process(a(x, 0)))
    "noteRemoteRun" => unit(self.note_remote_run(a(x, 0), a(x, 1), d(x, 2)))
    "insertJob" => unit(self.insert_job(a(x, 0)))
    "jobStarted" => unit(self.job_started(a(x, 0), a(x, 1), b(x, 2)))
    "jobEnded" => unit(self.job_ended(a(x, 0), a(x, 1), a(x, 2)))
    "getJob" => self.get_job(a(x, 0))
    "jobByToken" => self.job_by_token(a(x, 0))
    "jobsUp" => Json::array(self.jobs_up())
    "jobsUpOf" => Json::array(self.jobs_up_of(arr(a(x, 0))))
    "liveSessionsOn" => Json::array(self.live_sessions_on(a(x, 0), a(x, 1)))
    "jobsMarkOf" => self.jobs_mark_of(arr(a(x, 0)))
    "jobAtPort" => self.job_at_port(a(x, 0))
    "listJobs" => Json::array(self.list_jobs(a(x, 0)))
    "jobsRunning" => Json::array(self.jobs_running())
    "remoteQueueJobs" => Json::array(self.remote_queue_jobs())
    "awakeJobs" => Json::array(self.awake_jobs())
    "runningJobsAtLeast" => jbool(self.running_jobs_at_least(a(x, 0), d(x, 1)))
    "runningJobSessions" => Json::array(self.running_job_sessions(arr(a(x, 0))))
    "runningWaitJobIds" => Json::array(self.running_wait_job_ids(a(x, 0)))
    "upJobIds" => Json::array(self.up_job_ids(a(x, 0), b(x, 1)))
    "sessionHasUpJob" => self.session_has_up_job(a(x, 0))
    "runningJobs" => self.running_jobs()
    "addJobNotice" => unit(self.add_job_notice(a(x, 0), a(x, 1)))
    "clearEndedJobs" => Json::array(self.clear_ended_jobs(a(x, 0)))
    "jobNotices" => Json::array(self.job_notices(a(x, 0), a(x, 1)))
    "listProcesses" => Json::array(self.list_processes())
    "processByGroup" => self.process_by_group(a(x, 0))
    "putWidgetState" =>
      unit(self.put_widget_state(a(x, 0), a(x, 1), a(x, 2), a(x, 3)))
    "widgetState" => self.widget_state(a(x, 0), a(x, 1))
    "untoldWidgetModels" => Json::array(self.untold_widget_models(a(x, 0)))
    "markWidgetModelsTold" =>
      unit(self.mark_widget_models_told(a(x, 0), arr(a(x, 1))))
    // ── usage ──
    "usageCounter" => self.usage_counter()
    "advanceUsageCounter" => unit(self.advance_usage_counter(a(x, 0)))
    "usageCounterFile" => self.usage_counter_file(a(x, 0))
    "beginUsageCounterFile" =>
      self.begin_usage_counter_file(a(x, 0), a(x, 1), a(x, 2), b(x, 3))
    "usageFiles" => self.usage_files()
    "usageFile" => self.usage_file(a(x, 0))
    "recordUsage" =>
      ints(self.record_usage(a(x, 0), a(x, 1), s(x, 2), arr(a(x, 3)), a(x, 4)))
    "recordUsageAll" =>
      Json::array(self.record_usage_all(arr(a(x, 0))).map(ints))
    "lastContexts" => Json::array(self.last_contexts(s(x, 0), d(x, 1).to_int()))
    "recentlyCompacted" => jbool(self.recently_compacted(s(x, 0)))
    "savedCompactContext" => self.saved_compact_context(s(x, 0))
    "compactionPoints" => self.compaction_points(a(x, 0))
    "compactionsReady" => jbool(self.compactions_ready())
    "usageChanged" => unit(self.usage_changed(arr(a(x, 0)), arg(x, 1), b(x, 2)))
    "usageActiveSessions" => Json::array(self.usage_active_sessions(a(x, 0)))
    "usageTurns" => Json::array(self.usage_turns(a(x, 0), a(x, 1), d(x, 2)))
    "usageGroups" => Json::array(self.usage_groups(d(x, 0), d(x, 1), d(x, 2)))
    "usageOfSession" => Json::array(self.usage_of_session(s(x, 0)))
    "usageThreads" => Json::array(self.usage_threads(arr(a(x, 0))))
    "usageSince" => self.usage_since()
    "firstText" => self.first_text(a(x, 0))
    other => raise store_error("no call \{other}")
  }
}
