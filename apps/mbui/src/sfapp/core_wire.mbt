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
  // (a page's, a panel's or a card's own topic opened again shown at once as it was, till the core answers)
  client.show_kept_params(@sfbase.topic_shown_kept_params)
  // (a chat list's first window told the core before the list is asked, each time it is; a chat's before the chat)
  client.tells_before(@sfbase.chats_told_before)
  unsub
}

///|
/// Shared `@core` topic/lifecycle `Source` wiring used by `apps/mbui/src/stillfail/main.mbt`
/// and `apps/mbui/src/sfcoldstart`: routes topic reads, keyed lookups, waits, generations,
/// fatal state, leave/release/refresh, and default calls through the production `@core`
/// singleton (`@core.follow_topic`, `@core.keyed_of`, `@core.fatal`, `@core.call`).
pub fn core_base_source() -> Source {
  let base = @sfbase.made_source()
  {
    ..base,
    topic_read: fn(name, params) {
      let s = @core.follow_topic(name, params=@sfbase.core_topic_params(name, params))
      { value: s.value, error: s.error, version: s.version }
    },
    topic_key: fn(name, params) {
      @sfbase.wire_topic_key(name, @sfbase.core_topic_params(name, params))
    },
    topic_keyed: fn(name, params, field, keys) {
      @core.keyed_of(name, @sfbase.core_topic_params(name, params), field, keys)
    },
    topic_scope: None,
    topic_alive: fn() { true },
    topic_lease_own: None,
    waits: fn(name, params) {
      @core.follow_topic(name, params=@sfbase.core_topic_params(name, params)).waiting
    },
    generation: fn(name, params) {
      @core.client.topic_generation(name, params=@sfbase.core_topic_params(name, params))
    },
    call: fn(name, params, done) {
      if @sfbase.unread_answer(done) {
        @core.call(name, params~)
      } else {
        @core.call(name, params~, on_done=done)
      }
    },
    fatal: fn() { @core.fatal() },
    leave: fn(name, params, __reason) {
      if __reason is @sfbase.TopicLeave::Owned(__stop) {
        __stop()
        return
      }
      @core.leave_topic(name, params=@sfbase.core_topic_params(name, params))
    },
    release: fn(name, params) {
      @core.release_topic(name, params=@sfbase.core_topic_params(name, params))
    },
    refresh: fn(name, params) {
      @core.refresh_topic(name, params=@sfbase.core_topic_params(name, params))
    },
  }
}
