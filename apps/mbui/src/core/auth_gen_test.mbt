// Adversarial tests for PR-B2s on real `@core.Client`:
// - Sealing in-flight `o.keeping` across authGen/vaultGen boundaries (`take` & `show_kept_of`)
// - Monotonic non-regression guard on out-of-order `{auth}` and stale `conn`/`authGen`/`vaultGen` messages
// - Single-vault expiry (V1 locked, V2 & non-vault untouched) + explicit `vaultAll` lock
// - `Client::restarted()` clearing sensitive/vault subs and cross-generation active subs on `{auth}` sync
// - Unconditional `sensitive` ceiling + `station`/`profiles` sanitized SWR first frame

///|
fn auth_client() -> (@core.Client, Array[Json]) {
  let sent : Array[Json] = []
  let c = @core.Client::new(fn(s) { sent.push(@json.parse(s) catch { _ => Json::null() }) })
  c.sensitive(fn(name, params) {
    match name {
      "vaults" | "vaultItems" | "vaultUses" | "accounts" | "lock" | "machineLogins" => true
      "stationPart" =>
        match params {
          Object(m) =>
            match m.get("part") {
              Some(String("logins")) | Some(String("machineLogins")) => true
              _ => false
            }
          _ => false
        }
      _ => false
    }
  })
  c.keep(fn(name, params) {
    match name {
      "chats" | "profiles" | "workspace" => 64
      "station" | "chatJobs" => 16
      "stationPart" =>
        match params {
          Object(m) =>
            match m.get("part") {
              Some(String("profiles")) | Some(String("updates")) | Some(String("copies")) => 24
              _ => 0
            }
          _ => 0
        }
      _ => 0
    }
  })
  c.show_kept_params(fn(name, params) {
    match name {
      "station" | "chatJobs" => true
      "stationPart" =>
        match params {
          Object(m) =>
            match m.get("part") {
              Some(String("profiles")) | Some(String("updates")) | Some(String("copies")) => true
              _ => false
            }
          _ => false
        }
      _ => false
    }
  })
  c.sanitize_kept(fn(name, v) {
    match (name, v) {
      ("profiles", Object(m)) => {
        let out : Map[String, Json] = Map([])
        for k, val in m {
          if k != "machineLogins" && k != "manages" {
            out[k] = val
          }
        }
        Json::object(out)
      }
      ("station", Object(m)) => {
        let out : Map[String, Json] = Map([])
        for k, val in m {
          if k == "overview" {
            match val {
              Object(ov) => {
                let clean : Map[String, Json] = Map([])
                for ok, oval in ov {
                  if ok != "machineLogins" && ok != "logins" {
                    clean[ok] = oval
                  }
                }
                out[k] = Json::object(clean)
              }
              _ => out[k] = val
            }
          } else if k != "machineLogins" && k != "manages" {
            out[k] = val
          }
        }
        Json::object(out)
      }
      _ => v
    }
  })
  (c, sent)
}

///|
test "PR-B2s: in-flight o.keeping is sealed on auth boundary and late messages never resurrect old marker" {
  let (c, sent) = auth_client()
  // Initial auth snapshot: conn=1, global=1
  assert_true(c.receive("{\"auth\":{\"conn\":1,\"global\":1}}"))
  assert_eq(c.conn_id(), 1L)
  assert_eq(c.auth_gen_of(workspace="wsA"), 1)

  // Subscribe to station in wsA, receive OLD_MARKER, then unsubscribe (enters o.keeping before {id, v} arrives)
  let s1 = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  assert_true(c.receive("{\"id\":1,\"value\":{\"station\":\"wsA/st1\",\"name\":\"OLD_MARKER\"},\"conn\":1,\"authGen\":1}"))
  c.unsubscribe(s1)

  // Auth boundary fires on wsA (role downgrade / member removal) while o.keeping is still in flight!
  assert_true(c.receive("{\"auth\":{\"conn\":1,\"global\":1,\"workspace\":\"wsA\",\"authGen\":2}}"))
  assert_eq(c.auth_gen_of(workspace="wsA"), 2)

  // Late messages for old o.keeping id=1 arrive out-of-order: value, delta, {id, v} — ALL must be rejected!
  assert_true(c.receive("{\"id\":1,\"value\":{\"station\":\"wsA/st1\",\"name\":\"OLD_LATE_VALUE\"},\"conn\":1,\"authGen\":1}"))
  assert_true(c.receive("{\"id\":1,\"v\":\"k:old\",\"conn\":1,\"authGen\":1}"))

  // Re-subscribing to station in wsA must show placeholder (None), NEVER OLD_MARKER or OLD_LATE_VALUE!
  let s2 = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  assert_true(s2.value is None, msg="sealed o.keeping must not show stale value on resubscribe")
  let asked = sent[sent.length() - 1].stringify()
  assert_true(!asked.contains("have"), msg="resubscribe after auth boundary must not send old have token")

  // Stale authGen=1 message arriving for new sub s2 is ALSO rejected; stale {auth} regression ignored!
  assert_true(c.receive("{\"auth\":{\"conn\":1,\"global\":1,\"workspace\":\"wsA\",\"authGen\":1}}"))
  assert_eq(c.auth_gen_of(workspace="wsA"), 2)
  assert_true(c.receive("{\"id\":2,\"value\":{\"station\":\"wsA/st1\",\"name\":\"OLD_MARKER_STALE_GEN\"},\"conn\":1,\"authGen\":1}"))
  assert_true(s2.value is None, msg="stale authGen message must be dropped")

  // Fresh authorized authGen=2 value arrives and is visible!
  assert_true(c.receive("{\"id\":2,\"value\":{\"station\":\"wsA/st1\",\"name\":\"NEW_AUTHORIZED\"},\"conn\":1,\"authGen\":2}"))
  assert_true(s2.value.unwrap().stringify().contains("NEW_AUTHORIZED"))

  // Late callback with old conn=0 or old authGen=1 after new value arrived must NOT overwrite NEW_AUTHORIZED!
  assert_true(c.receive("{\"id\":2,\"value\":{\"station\":\"wsA/st1\",\"name\":\"OLD_AFTER_NEW\"},\"conn\":1,\"authGen\":1}"))
  assert_true(s2.value.unwrap().stringify().contains("NEW_AUTHORIZED"))
  assert_false(s2.value.unwrap().stringify().contains("OLD_"))
}

///|
test "PR-B2s: single-vault lock clears V1 and blocks late V1 unlocked value while V2 and non-vault stay intact" {
  let (c, _) = auth_client()
  assert_true(c.receive("{\"auth\":{\"conn\":1,\"global\":1,\"vaultGlobal\":1}}"))

  let v1 = c.subscribe("vaultItems", params={ "workspace": "wsA", "vault": "v1" })
  let v2 = c.subscribe("vaultItems", params={ "workspace": "wsA", "vault": "v2" })
  let vaults_ws = c.subscribe("vaults", params={ "workspace": "wsA" })
  let chats_ws = c.subscribe("chats", params={ "scope": "wsA" })

  assert_true(c.receive("{\"id\":1,\"value\":{\"vault\":\"v1\",\"open\":true,\"secret\":\"V1_SECRET\"},\"conn\":1,\"authGen\":1,\"vaultGen\":1}"))
  assert_true(c.receive("{\"id\":2,\"value\":{\"vault\":\"v2\",\"open\":true,\"secret\":\"V2_SECRET\"},\"conn\":1,\"authGen\":1,\"vaultGen\":1}"))
  assert_true(c.receive("{\"id\":3,\"value\":{\"vaults\":[{\"id\":\"v1\",\"open\":true}]},\"conn\":1,\"authGen\":1,\"vaultGen\":1}"))
  assert_true(c.receive("{\"id\":4,\"value\":{\"items\":[\"CHAT_OK\"]},\"conn\":1,\"authGen\":1}"))

  // Missing required wire identity fields (conn/authGen/vaultGen) on a handshaked connection are rejected!
  assert_true(c.receive("{\"id\":1,\"value\":{\"vault\":\"v1\",\"open\":true,\"secret\":\"NO_VAULT_GEN\"},\"conn\":1,\"authGen\":1}"))
  assert_false(v1.value.unwrap().stringify().contains("NO_VAULT_GEN"))

  // V1 expires -> vaultGen advances ONLY for wsA/v1 (and wsA vaults aggregate)
  assert_true(c.receive("{\"auth\":{\"conn\":1,\"global\":1,\"workspace\":\"wsA\",\"vault\":\"v1\",\"vaultGen\":2}}"))
  assert_true(v1.value is None, msg="V1 must be cleared immediately on V1 timeout")
  assert_true(vaults_ws.value is None, msg="wsA vaults aggregate must be cleared on V1 timeout")
  assert_true(v2.value.unwrap().stringify().contains("V2_SECRET"), msg="V2 must stay untouched on V1 timeout")
  assert_true(chats_ws.value.unwrap().stringify().contains("CHAT_OK"), msg="non-vault chats must stay untouched")

  // Late unlocked V1 payload from before lock (vaultGen=1) arrives AFTER lock -> dropped!
  assert_true(c.receive("{\"id\":1,\"value\":{\"vault\":\"v1\",\"open\":true,\"secret\":\"V1_LATE_SECRET\"},\"conn\":1,\"authGen\":1,\"vaultGen\":1}"))
  assert_true(v1.value is None, msg="late pre-lock V1 payload must be rejected")

  // Fresh locked V1 payload (vaultGen=2) arrives and is visible!
  assert_true(c.receive("{\"id\":1,\"value\":{\"vault\":\"v1\",\"open\":false,\"items\":[]},\"conn\":1,\"authGen\":1,\"vaultGen\":2}"))
  assert_true(v1.value.unwrap().stringify().contains("\"open\":false"))

  // Local mask_scope(VaultAll) masks V2 immediately and blocks old vaultGen=1 packets until vaultGen=3 arrives!
  c.mask_scope(@core.AuthScope::VaultAll) |> ignore
  assert_true(v2.value is None, msg="local mask_scope(VaultAll) must mask V2 immediately")
  assert_true(c.receive("{\"id\":2,\"value\":{\"vault\":\"v2\",\"open\":true,\"secret\":\"V2_OLD_AFTER_MASK\"},\"conn\":1,\"authGen\":1,\"vaultGen\":1}"))
  assert_true(v2.value is None, msg="masked V2 must drop packets from masked vaultGen=1")

  // Explicit vault.lock (`vaultAll: true`) advances vaultGen=3, clears mask, and accepts locked value
  assert_true(c.receive("{\"auth\":{\"conn\":1,\"global\":1,\"vaultAll\":true,\"vaultGen\":3}}"))
  assert_true(v1.value is None)
  assert_true(v2.value is None, msg="explicit vault.lock must clear V2")
  assert_true(chats_ws.value.unwrap().stringify().contains("CHAT_OK"), msg="explicit vault.lock must not clear non-vault chats")
  assert_true(c.receive("{\"id\":2,\"value\":{\"vault\":\"v2\",\"open\":false,\"items\":[]},\"conn\":1,\"authGen\":1,\"vaultGen\":3}"))
  assert_true(v2.value.unwrap().stringify().contains("\"open\":false"))
}

///|
test "PR-B2s: first handshake preserves active subs, Client::restarted waits for auth sync, and protected writes attach auth" {
  let (c, sent) = auth_client()
  // Subscribe BEFORE first {auth} snapshot arrives
  let chats_s = c.subscribe("chats", params={ "scope": "wsA" })
  let vaults_s = c.subscribe("vaults", params={ "workspace": "wsA" })
  assert_true(c.receive("{\"id\":1,\"value\":{\"items\":[\"EARLY_CHAT\"]}}"))
  // First handshake records baseline conn=1/global=1/vaultGlobal=1; untrusted pre-handshake value on
  // chats_s is cleared and re-asked under conn=1 rather than silently stamped as authenticated!
  let sent_before_hs = sent.length()
  assert_true(c.receive("{\"auth\":{\"conn\":1,\"global\":1,\"vaultGlobal\":1,\"scopes\":{},\"vaults\":{}}}"))
  assert_true(chats_s.value is None, msg="first handshake must clear untrusted pre-handshake value")
  assert_true(sent.length() > sent_before_hs, msg="first handshake must re-ask cleared pre-handshake sub")
  assert_true(c.receive("{\"id\":1,\"value\":{\"items\":[\"HANDSHAKED_CHAT\"]},\"conn\":1,\"authGen\":1}"))
  assert_true(chats_s.value.unwrap().stringify().contains("HANDSHAKED_CHAT"))
  assert_true(c.receive("{\"id\":2,\"value\":{\"vaults\":[{\"id\":\"v1\"}]},\"conn\":1,\"authGen\":1,\"vaultGen\":1}"))

  // Every non-client.* RPC (including auth.signOut, job.stop, composer.text new:wsA, vault.putItem) attaches `auth`!
  c.call("auth.signOut", params={ "account": "acct-1" }) |> ignore
  assert_true(sent[sent.length() - 1].stringify().contains("\"auth\""))
  c.call("job.stop", params={ "station": "wsA/st1", "job": "j1" }) |> ignore
  assert_true(sent[sent.length() - 1].stringify().contains("\"workspace\":\"wsA\""))
  c.call("composer.text", params={ "key": "new:wsA", "text": "hi" }) |> ignore
  assert_true(sent[sent.length() - 1].stringify().contains("\"workspace\":\"wsA\""))
  c.call("vault.putItem", params={ "workspace": "wsA", "vault": "v1", "plain": {} }) |> ignore
  let rpc = sent[sent.length() - 1].stringify()
  assert_true(rpc.contains("\"auth\""), msg="protected write RPC must attach auth")
  assert_true(rpc.contains("\"conn\":1"))
  assert_true(rpc.contains("\"authGen\":1"))
  assert_true(rpc.contains("\"vaultGen\":1"))

  // Pending vault.open call invalidated on vault lock -> UI callback gets Err(auth_stale), late Ok plaintext NEVER delivered!
  let open_got : Ref[String] = Ref("")
  let open_id = c.call("vault.open", params={ "workspace": "wsA", "vault": "v1", "item": "i1" }, on_done=fn(r) {
    match r {
      Ok(v) => open_got.val = "OK:" + v.stringify()
      Err(e) => open_got.val = "ERR:" + e.stringify()
    }
  })
  c.mask_scope(@core.AuthScope::VaultAll) |> ignore
  assert_true(open_got.val.contains("auth_stale"), msg="pending vault.open must fail auth_stale immediately on vault lock")
  let before_late = open_got.val
  assert_true(c.receive("{\"id\":" + open_id.to_string() + ",\"ok\":{\"plain\":\"TOP_SECRET_PLAIN\"},\"conn\":1,\"authGen\":1,\"vaultGen\":1}"))
  assert_eq(open_got.val, before_late, msg="late vault.open ok plaintext must never invoke callback after lock")
  assert_false(open_got.val.contains("TOP_SECRET_PLAIN"))

  // Bump old Core to high global=5 before crash/restart
  assert_true(c.receive("{\"auth\":{\"conn\":1,\"global\":5}}"))
  assert_true(c.receive("{\"id\":1,\"value\":{\"items\":[\"HIGH_GEN_CHAT\"]},\"conn\":1,\"authGen\":5}"))

  let restart_notified : Ref[Int] = Ref(0)
  let _ = c.on_auth_boundary(fn(_) { restart_notified.val += 1 })
  let sent_before_restart = sent.length()
  c.restarted()
  assert_true(c.awaiting_auth_sync())
  assert_true(restart_notified.val >= 1, msg="restarted() must synchronously notify auth_listeners to clear Source caches")
  assert_true(vaults_s.value is None, msg="sensitive/vault sub cleared immediately on restarted")
  assert_true(chats_s.value is None, msg="ALL non-device-global active subs cleared immediately on restarted")
  assert_eq(sent.length(), sent_before_restart, msg="restarted must wait for full {auth} snapshot before re-asking subs")

  // Incremental auth boundary AND stale full snapshot (`conn <= old_conn`) from old Core during restart are ignored!
  assert_true(c.receive("{\"auth\":{\"conn\":1,\"global\":6}}"))
  assert_true(c.awaiting_auth_sync(), msg="incremental boundary must not end awaiting_auth_sync")
  assert_true(c.receive("{\"auth\":{\"conn\":1,\"global\":1,\"vaultGlobal\":1,\"scopes\":{},\"vaults\":{}}}"))
  assert_true(c.awaiting_auth_sync(), msg="stale full snapshot with conn <= old_conn must be rejected on restart")

  // Fresh Core restarts with conn=2 and fresh generations global=1, vaultGlobal=1 (lower than old Core's 5!)
  // Client replaces generations wholesale and resumes normal delivery!
  assert_true(c.receive("{\"auth\":{\"conn\":2,\"global\":1,\"vaultGlobal\":1,\"scopes\":{},\"vaults\":{}}}"))
  assert_false(c.awaiting_auth_sync())
  assert_eq(c.conn_id(), 2L)
  assert_eq(c.auth_gen_of(workspace="wsA"), 1, msg="restart snapshot must replace old Core global=5 with new Core global=1")
  assert_true(sent.length() > sent_before_restart, msg="active subs re-asked after full {auth} snapshot")

  // New Core's authGen=1 value arrives and is accepted (no stall against old Core's 5)!
  assert_true(c.receive("{\"id\":1,\"value\":{\"items\":[\"NEW_CORE_CHAT\"]},\"conn\":2,\"authGen\":1}"))
  assert_true(chats_s.value.unwrap().stringify().contains("NEW_CORE_CHAT"))

  // Write calls (`vault.lock`, `auth.signOut`, `chat.send`) must NEVER be converted to `auth_stale` on boundary!
  let send_got : Ref[String] = Ref("")
  let send_id = c.call("chat.send", params={ "station": "wsA/s1", "text": "hello" }, on_done=fn(r) {
    match r {
      Ok(v) => send_got.val = "ok:" + v.stringify()
      Err(e) => send_got.val = "err:" + e.stringify()
    }
  })
  let lock_got : Ref[String] = Ref("")
  let lock_id = c.call("vault.lock", params={ "workspace": "wsA" }, on_done=fn(r) {
    match r {
      Ok(v) => lock_got.val = "ok:" + v.stringify()
      Err(e) => lock_got.val = "err:" + e.stringify()
    }
  })
  // Self-triggered vaultAll boundary arrives BEFORE vault.lock's ok reply: neither write is failed!
  assert_true(c.receive("{\"auth\":{\"conn\":2,\"global\":1,\"vaultAll\":true,\"vaultGen\":2}}"))
  assert_eq(lock_got.val, "", msg="vault.lock must not self-fail on its own boundary")
  assert_eq(send_got.val, "", msg="in-flight chat.send must not fail on boundary")
  assert_true(c.receive("{\"id\":" + lock_id.to_string() + ",\"ok\":{\"locked\":true},\"conn\":2,\"authGen\":1}"))
  assert_true(c.receive("{\"id\":" + send_id.to_string() + ",\"ok\":{\"sent\":true},\"conn\":2,\"authGen\":1}"))
  assert_true(lock_got.val.has_prefix("ok:"), msg="vault.lock ok reply must succeed")
  assert_true(send_got.val.has_prefix("ok:"), msg="chat.send ok reply must succeed")

  // Scope-level mask_scope(Global) blocks NEW subs (including vault topics!) and outgoing non-control calls,
  // while allowing control calls (`auth.deleteAccount`) and cleanly restoring on undo() when deleteAccount fails!
  let undo_global = c.mask_scope(@core.AuthScope::Global)
  let new_sub = c.subscribe("chats", params={ "scope": "wsB" })
  let new_vault_sub = c.subscribe("vaultItems", params={ "workspace": "wsB", "vault": "v1" })
  assert_true(c.receive("{\"id\":" + new_sub.id.to_string() + ",\"value\":{\"items\":[\"MASKED_OLD\"]},\"conn\":2,\"authGen\":1}"))
  assert_true(c.receive("{\"id\":" + new_vault_sub.id.to_string() + ",\"value\":{\"items\":[\"MASKED_VAULT\"]},\"conn\":2,\"authGen\":1,\"vaultGen\":2}"))
  assert_true(new_sub.value is None, msg="scope-level mask must block packets of masked gen even on newly created Sub")
  assert_true(new_vault_sub.value is None, msg="Global mask must also block vault topics")
  let blocked_got : Ref[String] = Ref("")
  c.call("chat.send", params={ "station": "wsB/s1", "text": "blocked" }, on_done=fn(r) {
    match r {
      Ok(_) => blocked_got.val = "ok"
      Err(e) => blocked_got.val = e.stringify()
    }
  }) |> ignore
  assert_true(blocked_got.val.contains("auth_stale"), msg="non-control call under active mask must be blocked")
  // Control call `auth.deleteAccount` fails offline -> undo_global() unmasks & re-asks active subs!
  let sent_before_undo = sent.length()
  undo_global()
  assert_true(sent.length() > sent_before_undo, msg="undo handle must re-ask active subs so UI recovers from failed deleteAccount")
  assert_true(c.receive("{\"id\":" + new_sub.id.to_string() + ",\"value\":{\"items\":[\"RECOVERED_AFTER_UNDO\"]},\"conn\":2,\"authGen\":1}"))
  assert_true(new_sub.value.unwrap().stringify().contains("RECOVERED_AFTER_UNDO"))

  // High-watermark mask_scope(Global) & mask_scope(VaultAll):
  // Even after wsB bumped to authGen=4 (while global=1) and v1 bumped to vaultGen=5 (while vaultGlobal=2),
  // mask_scope(Global) and mask_scope(VaultAll) MUST cover those high-watermark generations!
  assert_true(c.receive("{\"auth\":{\"conn\":2,\"global\":1,\"aggregate\":4,\"workspace\":\"wsB\",\"authGen\":4}}"))
  assert_true(c.receive("{\"auth\":{\"conn\":2,\"global\":1,\"workspace\":\"wsB\",\"vault\":\"v1\",\"vaultGen\":5}}"))
  let undo_high_g = c.mask_scope(@core.AuthScope::Global)
  assert_true(c.receive("{\"id\":" + new_sub.id.to_string() + ",\"value\":{\"items\":[\"LEAKED_HIGH_WS\"]},\"conn\":2,\"authGen\":4}"))
  assert_true(new_sub.value is None, msg="Global mask must cover already-bumped workspace authGen=4")
  undo_high_g()
  let undo_high_v = c.mask_scope(@core.AuthScope::VaultAll)
  assert_true(c.receive("{\"id\":" + new_vault_sub.id.to_string() + ",\"value\":{\"items\":[\"LEAKED_HIGH_VAULT\"]},\"conn\":2,\"authGen\":4,\"vaultGen\":5}"))
  assert_true(new_vault_sub.value is None, msg="VaultAll mask must cover already-bumped vaultGen=5")
  undo_high_v()

  // View-bound call (`terminal.input` with only `view`) is blocked by Workspace(wsB) mask once `terminal.view` bound it,
  // and stale stream progress sends `{ cancel: true }` to Core and fails with `auth_stale`!
  let stream_err : Ref[String] = Ref("")
  let tv_id = c.stream("terminal.view", params={ "station": "wsB/s1", "terminal": "t1", "view": "tv1" }, on_value=fn(_, _) {  }, on_done=fn(r) {
    match r {
      Err(e) => stream_err.val = e.stringify()
      Ok(_) => stream_err.val = "ok"
    }
  })
  let undo_ws = c.mask_scope(@core.AuthScope::Workspace("wsB"))
  let ti_got : Ref[String] = Ref("")
  c.call("terminal.input", params={ "view": "tv1", "text": "ls" }, on_done=fn(r) {
    match r {
      Err(e) => ti_got.val = e.stringify()
      Ok(_) => ti_got.val = "ok"
    }
  }) |> ignore
  assert_true(ti_got.val.contains("auth_stale"), msg="Workspace mask must block view-only terminal.input")
  assert_true(stream_err.val.contains("auth_stale"), msg="Workspace mask must invalidate active terminal.view stream")
  assert_true(sent.iter().any(fn(j) { j.stringify().contains("\"cancel\":true") && j.stringify().contains("\"id\":" + tv_id.to_string()) }), msg="invalidated stream must send { cancel: true } to Core")
  undo_ws()

  // Single-vault lock on v1 must NOT interrupt in-flight `vault.open` with explicit `vault: "v2"`.
  let v2_open_got : Ref[String] = Ref("")
  let v2_id = c.call("vault.open", params={ "workspace": "wsB", "vault": "v2", "item": "i2" }, on_done=fn(r) {
    match r {
      Ok(v) => v2_open_got.val = "ok:" + v.stringify()
      Err(e) => v2_open_got.val = "err:" + e.stringify()
    }
  })
  assert_true(c.receive("{\"auth\":{\"conn\":2,\"global\":1,\"workspace\":\"wsB\",\"vault\":\"v1\",\"vaultGen\":6}}"))
  assert_eq(v2_open_got.val, "", msg="locking v1 must NOT interrupt in-flight vault.open for v2")
  assert_true(c.receive("{\"id\":" + v2_id.to_string() + ",\"ok\":{\"plain\":{\"kind\":\"token\"}},\"conn\":2,\"authGen\":4,\"vaultGen\":2}"))
  assert_true(v2_open_got.val.has_prefix("ok:"), msg="v2 vault.open must complete cleanly after v1 lock")
}

///|
test "PR-B2s: unconditional sensitive ceiling and station sanitized SWR first frame" {
  let (c, sent) = auth_client()
  // Sensitive topics never send keep=true on unsubscribe
  let vs = c.subscribe("vaults", params={ "workspace": "wsA" })
  assert_true(c.receive("{\"id\":1,\"value\":{\"vaults\":[]}}"))
  c.unsubscribe(vs)
  assert_false(sent[sent.length() - 1].stringify().contains("keep"), msg="vaults must never send keep:true")

  let sp_logins = c.subscribe("stationPart", params={ "scope": "wsA", "station": "wsA/st1", "part": "logins" })
  assert_true(c.receive("{\"id\":2,\"value\":[{\"id\":\"l1\"}]}"))
  c.unsubscribe(sp_logins)
  assert_false(sent[sent.length() - 1].stringify().contains("keep"), msg="stationPart(logins) must never send keep:true")

  // station: kept value and first-frame SWR strip overview.machineLogins & overview.logins
  let st = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  assert_true(c.receive("{\"id\":3,\"value\":{\"station\":\"wsA/st1\",\"name\":\"Box\",\"overview\":{\"counts\":{\"running\":1},\"machineLogins\":[{\"id\":\"ml1\"}],\"logins\":[{\"id\":\"l1\"}]}}}"))
  c.unsubscribe(st)
  assert_true(c.receive("{\"id\":3,\"v\":\"k:st1\"}"))

  let st2 = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  let first_frame = st2.value.unwrap().stringify()
  assert_eq(st2.version, -2, msg="station shows sanitized SWR immediately on first frame")
  assert_true(first_frame.contains("\"name\":\"Box\""))
  assert_false(first_frame.contains("machineLogins"), msg="station first-frame SWR must contain 0 machineLogins")
  assert_false(first_frame.contains("\"logins\""), msg="station first-frame SWR must contain 0 logins")
}

///|
test "first_handshake completes on incremental boundary and subsequent full syncAuth snapshot merges missing scopes" {
  let (c, sent) = auth_client()
  // Pre-handshake subscription receives an untrusted value before any {auth} arrives
  let s = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  assert_true(c.receive("{\"id\":1,\"value\":{\"station\":\"wsA/st1\",\"name\":\"PRE\"}}"))
  assert_true(s.value is Some(_))
  let sent_before = sent.length()

  // Suppose an incremental workspace boundary arrives first (e.g. while UI just attached to coreAhead)
  assert_true(c.receive("{\"auth\":{\"conn\":100,\"global\":1,\"aggregate\":2,\"workspace\":\"wsB\",\"authGen\":2}}"))
  assert_eq(c.conn_id(), 100L)
  assert_eq(c.auth_gen_of(workspace="wsB"), 2)
  assert_true(s.value is None, msg="first_handshake on incremental boundary must still clear pre-handshake sub values")
  assert_true(sent.length() > sent_before, msg="first_handshake on incremental boundary must re-ask pre-handshake subs")

  // A protected read call started for wsA in the window between the incremental boundary and the
  // first full syncAuth snapshot must NOT be spuriously failed with auth_stale when wsA's baseline arrives.
  let read_got : Ref[String] = Ref("")
  let read_id = c.call("drive.list", params={ "station": "wsA/st1", "path": "/" }, on_done=fn(r) {
    match r {
      Ok(v) => read_got.val = "ok:" + v.stringify()
      Err(e) => read_got.val = "err:" + e.stringify()
    }
  })

  // Full snapshot from client.syncAuth arrives right after on same conn=100, bringing wsA's missed bump (authGen=3)
  assert_true(
    c.receive(
      "{\"auth\":{\"conn\":100,\"global\":1,\"aggregate\":3,\"vaultGlobal\":1,\"scopes\":{\"wsA\":3,\"wsB\":2},\"vaults\":{}}}",
    ),
  )
  assert_eq(c.conn_id(), 100L)
  assert_eq(c.auth_gen_of(workspace="wsA"), 3, msg="syncAuth snapshot must populate workspace authGen missed before attach")
  assert_eq(c.auth_gen_of(workspace="wsB"), 2)
  assert_eq(read_got.val, "", msg="first full syncAuth baseline for wsA (prev==0) must not spuriously fail pending read")
  assert_true(c.receive("{\"id\":" + read_id.to_string() + ",\"ok\":{\"entries\":[]},\"conn\":100,\"authGen\":3}"))
  assert_true(read_got.val.has_prefix("ok:"), msg="pending read completes normally once core answers")
}

///|
test "auth_stale stream invalidation sends cancel before on_done synchronously reopens" {
  let (c, sent) = auth_client()
  assert_true(
    c.receive(
      "{\"auth\":{\"conn\":10,\"global\":1,\"aggregate\":1,\"vaultGlobal\":1,\"scopes\":{\"wsA\":1},\"vaults\":{}}}",
    ),
  )

  // Case 1: auth boundary invalidation (`invalidate_scope_inner`) sends cancel BEFORE on_done's synchronous reopen.
  let reopened1 : Ref[Int] = Ref(0)
  let id1 = c.stream(
    "screen.view",
    params={ "station": "wsA/st1", "screen": "desktop", "view": "v1" },
    on_value=fn(_, _) {  },
    on_done=fn(r) {
      if r is Err(_) {
        reopened1.val = c.stream(
          "screen.view",
          params={ "station": "wsA/st1", "screen": "desktop", "view": "v2" },
          on_value=fn(_, _) {  },
          on_done=fn(_) {  },
        )
      }
    },
  )
  let before1 = sent.length()
  assert_true(
    c.receive(
      "{\"auth\":{\"conn\":10,\"global\":1,\"aggregate\":2,\"workspace\":\"wsA\",\"authGen\":2}}",
    ),
  )
  assert_true(reopened1.val > 0, msg="on_done should synchronously reopen stream")
  let mut cancel1_idx = -1
  let mut reopen1_idx = -1
  for i = before1; i < sent.length(); i = i + 1 {
    let s = sent[i].stringify()
    if cancel1_idx < 0 && s.contains("\"cancel\":true") && s.contains("\"id\":" + id1.to_string()) {
      cancel1_idx = i
    }
    if reopen1_idx < 0 && s.contains("\"call\":\"screen.view\"") && s.contains("\"id\":" + reopened1.val.to_string()) {
      reopen1_idx = i
    }
  }
  assert_true(cancel1_idx >= 0 && reopen1_idx >= 0 && cancel1_idx < reopen1_idx, msg="cancel must be sent before synchronous reopen on auth boundary")

  // Case 2: stale progress frame in `Client::take` sends cancel BEFORE on_done's synchronous reopen.
  let reopened2 : Ref[Int] = Ref(0)
  let id2 = c.stream(
    "screen.view",
    params={ "station": "wsA/st1", "screen": "desktop", "view": "v3" },
    on_value=fn(_, _) {  },
    on_done=fn(r) {
      if r is Err(_) {
        reopened2.val = c.stream(
          "screen.view",
          params={ "station": "wsA/st1", "screen": "desktop", "view": "v4" },
          on_value=fn(_, _) {  },
          on_done=fn(_) {  },
        )
      }
    },
  )
  let before2 = sent.length()
  // Progress with mismatched authGen=1 while current wsA authGen=2 triggers stale stream rejection.
  assert_true(c.receive("{\"id\":" + id2.to_string() + ",\"value\":{\"state\":{\"phase\":\"live\"}},\"conn\":10,\"authGen\":1}"))
  assert_true(reopened2.val > 0, msg="on_done should synchronously reopen stream on stale progress")
  let mut cancel2_idx = -1
  let mut reopen2_idx = -1
  for i = before2; i < sent.length(); i = i + 1 {
    let s = sent[i].stringify()
    if cancel2_idx < 0 && s.contains("\"cancel\":true") && s.contains("\"id\":" + id2.to_string()) {
      cancel2_idx = i
    }
    if reopen2_idx < 0 && s.contains("\"call\":\"screen.view\"") && s.contains("\"id\":" + reopened2.val.to_string()) {
      reopen2_idx = i
    }
  }
  assert_true(cancel2_idx >= 0 && reopen2_idx >= 0 && cancel2_idx < reopen2_idx, msg="cancel must be sent before synchronous reopen on stale progress")
}
