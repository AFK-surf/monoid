// Every route, in the order the station's admin API tries them (admin.ts): the platform's, the agents' side's
// (`agentsRoutes`), then the station's parts' in the order they are made.

///|
fn Admin::all_routes(self : Admin) -> Array[Route] {
  let platform = self.chats_routes() +
    self.usage_routes() +
    self.sessions_routes() +
    self.events_routes() +
    self.marks_routes() +
    self.hub_routes() +
    (if self.setup.has("config") {
      self.network_routes() + self.tools_routes()
    } else {
      []
    }) +
    (if self.setup.has("cloud") && self.setup.data is Some(_) {
      self.workspaces_routes()
    } else {
      []
    }) +
    (if self.setup.has("config") && self.setup.data is Some(_) {
      self.drive_routes()
    } else {
      []
    }) +
    (if self.setup.has("grants") { self.permissions_routes() } else { [] }) +
    self.screens_routes()
  let agents = if self.setup.has("agents") {
    (if self.setup.has("agents.config") { self.connect_routes() } else { [] }) +
    self.updates_routes() +
    (if self.setup.has("agents.config") { self.agent_env_routes() } else { [] }) +
    self.presets_routes() +
    self.stars_routes() +
    self.board_routes() +
    (if self.setup.has("agents.config") {
      self.context_routes() + self.diagnostics_routes()
    } else {
      []
    }) +
    (if self.setup.has("agents.xshare") { self.xshare_routes() } else { [] }) +
    (if self.setup.has("agents.accounts") {
      self.accounts_routes()
    } else {
      []
    }) +
    self.overview_routes()
  } else {
    []
  }
  let parts = if self.setup.has("parts") {
    self.usage_part_routes() +
    self.resource_routes() +
    (if self.setup.has("search") { self.search_routes() } else { [] }) +
    self.links_routes() +
    (if self.setup.has("logins") { self.logins_routes() } else { [] }) +
    self.vault_routes() +
    self.vault_requests_routes() +
    (if self.setup.has("vault") { self.signins_routes() } else { [] }) +
    self.comma_routes() +
    self.feishu_routes() +
    self.group_routes() +
    (if self.setup.has("slack") { self.slack_routes() } else { [] }) +
    (if self.setup.has("copies") { self.copies_routes() } else { [] }) +
    (if self.setup.has("transfers") { self.transfers_routes() } else { [] })
  } else {
    []
  }
  platform + agents + parts
}

///|
/// What the station is as the composition root makes it (`Setup`), from outside this package.
pub fn Setup::new(
  words : Words,
  build : String,
  runtime_kinds : Array[String],
  dev : Bool,
  data : String?,
  grant_key : Bytes,
  station_lang : String,
  absent : Array[String],
) -> Setup {
  { words, build, runtime_kinds, dev, data, grant_key, station_lang, absent }
}

///|
/// A request as the composition root makes it (a member's on the mesh, the machine's own on its door).
pub fn Request::new(
  verb : String,
  path : String,
  query : Array[(String, String)],
  search : String?,
  headers : Array[(String, String)],
  body : Bytes,
  viewer : JV,
  lang : String,
  background? : Bool = false,
  signal? : Signal,
) -> Request {
  { verb, path, query, search, headers, body, viewer, lang, background, signal }
}
