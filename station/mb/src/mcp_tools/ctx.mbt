// What every tool is made with: the seam to the station's parts, the words of the station's catalog (client/i18n's
// station part, as ops/i18n.ts `tr` says them), and what the station is (its language, the runtimes it knows, the
// machine's system and architecture as Node names them).

///|
pub(all) struct Consts {
  /// agents/runtime.ts RUNTIME_KINDS
  runtime_kinds : Array[String]
  /// ops/i18n.ts stationLang()
  station_lang : String
  /// platform.os
  os : String
  /// process.arch
  arch : String
}

///|
pub struct Ctx {
  b : ToolsBackend
  words : @api_routes.Words
  consts : Consts
}

///|
pub fn Ctx::new(
  b : ToolsBackend,
  words : @api_routes.Words,
  consts : Consts,
) -> Ctx {
  { b, words, consts }
}

///|
/// tr(lang, key, args).
pub fn Ctx::tr(
  self : Ctx,
  lang : String,
  key : String,
  args? : Array[(String, String)] = [],
) -> String {
  self.words.tr(lang, key, args~)
}

///|
/// A tool's declaration (declared.mbt), parsed.
pub fn Ctx::decl(self : Ctx, name : String) -> JV {
  let text = match name {
    "chat_post" => decl_chat_post
    "slack_api" => decl_slack_api
    "chat_state" => decl_chat_state
    "chat_leave" => decl_chat_leave
    "chat_history" => decl_chat_history
    "chat_list" => decl_chat_list
    "chat_read" => decl_chat_read
    "session_send" => decl_session_send
    "chat_create" => decl_chat_create
    "chat_archive" => decl_chat_archive
    "chat_configure" => decl_chat_configure
    "session_history" => decl_session_history
    "archive_policy" => decl_archive_policy
    "station_list" => decl_station_list
    "station_task" => decl_station_task
    "station_file" => decl_station_file
    "workspace_limit" => decl_workspace_limit
    "job_start" => decl_job_start
    "job_list" => decl_job_list
    "job_log" => decl_job_log
    "job_stop" => decl_job_stop
    "screen" => decl_screen
    "permissions" => decl_permissions
    "computer" => decl_computer
    "peer_forward" => decl_peer_forward
    "relays" => decl_relays
    "feedback_send" => decl_feedback_send
    "feedback_reply" => decl_feedback_reply
    "station_move" => decl_station_move
    "station_retire" => decl_station_retire
    "device_list" => decl_device_list
    "device_use" => decl_device_use
    "station_use" => decl_station_use
    "skill_read" => decl_skill_read
    "search" => decl_search
    _ => "{}"
  }
  let v = try_parse(text).unwrap_or(jobj([]))
  if name == "chat_create" || name == "chat_configure" {
    put_runtimes(v, self.consts.runtime_kinds)
  } else {
    v
  }
}

///|
fn put_runtimes(v : JV, kinds : Array[String]) -> JV {
  match v {
    Str("$RUNTIME_KINDS") => jstrs(kinds)
    Arr(a) => Arr(a.map(x => put_runtimes(x, kinds)))
    Obj(f) => Obj(f.map(p => (p.0, put_runtimes(p.1, kinds))))
    x => x
  }
}
