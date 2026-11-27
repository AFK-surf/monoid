///|
/// Production Core client wiring shared by `apps/mbui/src/stillfail/main.mbt` and
/// `apps/mbui/src/sfcoldstart`: topic sensitivity policies, kept-value sanitization,
/// auth-boundary cache invalidation, and kept/prefetch hooks.
pub fn wire_core_client(client : @core.Client, src : Source) -> () -> Unit {
  client.sensitive(@sfbase.topic_policy_sensitive)
  client.device_global(@sfbase.topic_policy_device_global)
  client.sanitize_kept(@sfbase.sanitize_kept_json)
  let unsub = client.on_auth_boundary(fn(scope) {
    match scope {
      Global | VaultAll => (@sfbase.clear_vault_secrets.val)("", "")
      Workspace(ws) => (@sfbase.clear_vault_secrets.val)(ws, "")
      Vault(ws, v) => (@sfbase.clear_vault_secrets.val)(ws, v)
      VaultWorkspace(_) => ()
    }
    @sfbase.invalidate_auth_scope(src, fn(name, params) {
      @core.topic_matches_scope_params(name, params, scope)
    })
  })
  @core.auth_stale_message.val = fn() { @sf.t("core-misc.auth.stale") }
  @sfbase.mask_vault_all.val = fn() { client.mask_scope(@core.AuthScope::VaultAll) }
  @sfbase.mask_global.val = fn() { client.mask_scope(@core.AuthScope::Global) }
  client.keep(@sfbase.topic_kept, most=fn() { @sfbase.kept_most_by(true) })
  client.show_kept_params(@sfbase.topic_shown_kept_params)
  client.tells_before(@sfbase.chats_told_before)
  unsub
}

///|
/// Current high-level app boot/auth state name for smoke verification.
pub fn app_state_name(src : Source) -> String {
  match app_is(src) {
    Starting => "Starting"
    SignedOut => "SignedOut"
    SignedIn => "SignedIn"
    Failed => "Failed"
  }
}
