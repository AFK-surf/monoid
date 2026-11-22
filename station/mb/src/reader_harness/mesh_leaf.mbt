// Line-delimited bidirectional JSON harness (`--builder harness-leaf`) for client/core-ts/side/ browser leaf
// tests (`mesh-leaf-browser.ts`, `relay-load-browser.ts`) and unit tests: drives real `@cloud_lock`, `@gate.serve`,
// and `@mesh_scopes` (`workspace_scope`, `ScopeSync`, `Leaves`) while bridging native Rust iroh endpoints/streams
// held in Node.

///|
priv struct LeafBridgedConn {
  coming : @effect.Queue[@door.Stream?]
  closed_def : @effect.Deferred[String]
  is_closed : Ref[Bool]
}

///|
priv struct LeafBridgedStream {
  chunks : @effect.Queue[Bytes?]
  stopped_def : @effect.Deferred[Int?]
  eof : Ref[Bool]
}

///|
priv struct LeafStationInstance {
  station_id : String
  db : @sql.Db
  sync : @mesh_scopes.ScopeSync
  members : @gate.Members
  own_descriptors : Map[String, Json]
  scope_listen_cb : Ref[((Array[Json]) -> Unit)?]
  revisions : Map[String, Int64]
  last_peer_json : Map[String, String]
}

///|
fn ml_scopes_crypto(host : @host.Host, sign : (String) -> String raise) -> @mesh_scopes.Crypto {
  {
    verify: (key, message, signature) => (try {
      Ok(
        host.shell_sync("crypto.verify", {
          "alg": "Ed25519",
          "key": Json::string(key),
          "signature": Json::string(signature),
          "message": Json::string(@mesh_scopes.hex_of(message)),
        }),
      )
    } catch {
      e => Err(e)
    }) is Ok(True),
    sign,
    sha256: bytes => @cloud_lock.sha256_hex_bytes(bytes[:]),
    random: n => match (try { Ok(host.shell_sync("crypto.random", { "bytes": Json::number(n.to_double()) })) } catch { e => Err(e) }) {
      Ok(String(h)) => @cloud_lock.hex_bytes(h)
      _ => Bytes::make(n, b'\x00')
    },
  }
}

///|
fn ml_sign_announcement(
  host : @host.Host,
  scope : String,
  descriptor : Json,
  secret_key_hex : String,
  revision : Int64,
) -> Json raise {
  let key = @cloud_lock.StationKey::new(host, @cloud_lock.hex_bytes(secret_key_hex))
  let body = (
    {
      "scope": Json::string(scope),
      "node": Json::string(key.id),
      "revision": @mesh_scopes.int_json(revision),
      "descriptor": descriptor,
    } : Json
  ).stringify()
  let signature = key.sign(@mesh_scopes.announcement_domain + body)
  { "body": Json::string(body), "signature": Json::string(signature) }
}

///|
fn ml_init_mesh_db(host : @host.Host) -> @sql.Db raise {
  let db = @sql.Db::create(host, ":memory:", wait=5000)
  db.exec(
    $|CREATE TABLE IF NOT EXISTS mesh_relay_tokens (
    $|  hash TEXT PRIMARY KEY, scope TEXT NOT NULL, name TEXT NOT NULL,
    $|  made_by TEXT NOT NULL, expires INTEGER NOT NULL
    $|);
    $|CREATE TABLE IF NOT EXISTS mesh_relay_registrations (
    $|  scope TEXT NOT NULL, node TEXT NOT NULL, issuer TEXT NOT NULL,
    $|  generation INTEGER NOT NULL, name TEXT NOT NULL, made_by TEXT NOT NULL,
    $|  revoked INTEGER NOT NULL DEFAULT 0,
    $|  PRIMARY KEY(scope, node)
    $|);
    $|CREATE TABLE IF NOT EXISTS mesh_announcements (
    $|  scope TEXT NOT NULL, node TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL, signature TEXT NOT NULL,
    $|  PRIMARY KEY(scope, node)
    $|);
    $|CREATE TABLE IF NOT EXISTS mesh_relay_records (
    $|  scope TEXT NOT NULL, node TEXT NOT NULL, issuer TEXT NOT NULL, generation INTEGER NOT NULL,
    $|  body TEXT NOT NULL, signature TEXT NOT NULL, PRIMARY KEY(scope, node)
    $|);
  )
  db
}

///|
fn ml_read_mesh_db(db : @sql.Db, args : Json) -> Json raise {
  let kind = sn_str(args, "kind")
  let scope = sn_str(args, "scope")
  if kind == "announcements" {
    let out : Array[Json] = []
    for node in sn_params(args, "nodes") {
      if node is String(n) {
        for row in db.all("SELECT body, signature FROM mesh_announcements WHERE scope = ?1 AND node = ?2", [Json::string(scope), Json::string(n)]) {
          out.push(
            Json::object({
              "body": row.get("body").unwrap_or(Json::string("")),
              "signature": row.get("signature").unwrap_or(Json::string("")),
            }),
          )
        }
      }
    }
    Json::array(out)
  } else if kind == "relayRecords" {
    let rows = db.all("SELECT body, signature FROM mesh_relay_records WHERE scope = ?1", [Json::string(scope)])
    Json::array(
      rows.map(row => Json::object({
        "body": row.get("body").unwrap_or(Json::string("")),
        "signature": row.get("signature").unwrap_or(Json::string("")),
      })),
    )
  } else {
    Json::array([])
  }
}

///|
fn ml_noop_packer() -> @door.Packer {
  {
    whole: async fn(bytes : Bytes, _level : Int) -> Bytes { bytes },
    stream: async fn() -> @door.Packing {
      {
        push: async fn(piece : Bytes) -> Bytes { piece },
        finish: async fn() -> Bytes { b"" },
        close: () => (),
      }
    },
  }
}

///|
async fn ml_sync_records(
  host : @host.Host,
  st : LeafStationInstance,
  scope : String,
  entries : Array[Json],
) -> Unit {
  let peer_announcements : Array[Json] = []
  for entry in entries {
    let descriptor = sn_at(entry, "descriptor").unwrap_or(Json::null())
    let secret_hex = sn_str(entry, "secretKey")
    let key = @cloud_lock.StationKey::new(host, @cloud_lock.hex_bytes(secret_hex))
    if key.id == st.station_id {
      let desc_str = descriptor.stringify()
      let prev = st.own_descriptors.get(scope).map(d => d.stringify())
      if prev != Some(desc_str) {
        st.own_descriptors[scope] = descriptor
        match st.scope_listen_cb.val {
          Some(cb) => cb([{ "scope": Json::string(scope), "descriptor": descriptor }])
          None => ()
        }
      }
    } else {
      let k = "\{scope}:\{key.id}"
      let desc_str = descriptor.stringify()
      if st.last_peer_json.get(k) != Some(desc_str) {
        let rev = st.revisions.get(k).unwrap_or(0L) + 1L
        st.revisions[k] = rev
        st.last_peer_json[k] = desc_str
        peer_announcements.push(ml_sign_announcement(host, scope, descriptor, secret_hex, rev))
      }
    }
  }
  if peer_announcements.length() > 0 {
    st.sync.directory.take(scope, peer_announcements)
  }
}

///|
async fn harness_leaf(host : @host.Host) -> Unit {
  let lock_crypto = @cloud_lock.Crypto::of_host(host)
  let base_scopes_crypto = ml_scopes_crypto(host, _ => fail("no station key for signing"))
  let disk : @cloud_lock.Disk = { host, }
  let now_ms : Ref[Double] = Ref(@host.epoch_ms().to_double())
  let clock_override : Ref[Bool] = Ref(false)

  let stations : Map[Int, LeafStationInstance] = Map([])
  let mut next_station = 0
  let conns : Map[Int, LeafBridgedConn] = Map([])
  let streams : Map[Int, LeafBridgedStream] = Map([])
  let stream_refs : Array[(Int, @door.Stream)] = []
  let pending_cbs : Map[Int, @effect.Deferred[Result[Json, String]]] = Map([])
  let next_cb : Ref[Int] = Ref(0)

  let cb_call = async fn(fields : Map[String, Json]) -> Json {
    next_cb.val += 1
    let cid = next_cb.val
    let d : @effect.Deferred[Result[Json, String]] = @effect.Deferred::new()
    pending_cbs[cid] = d
    fields["cb"] = Json::number(cid.to_double())
    host.say(Json::object(fields).stringify())
    match d.wait() {
      Ok(v) => v
      Err(m) => raise @door.WireError(m)
    }
  }

  let make_stream = fn(sth : Int) -> @door.Stream {
    let st : LeafBridgedStream = {
      chunks: @effect.Queue::unbounded(),
      stopped_def: @effect.Deferred::new(),
      eof: Ref(false),
    }
    streams[sth] = st
    let s : @door.Stream = {
      read: async fn() -> Bytes? {
        if st.eof.val {
          return None
        }
        match st.chunks.take() {
          Some(b) => Some(b)
          None => {
            st.eof.val = true
            None
          }
        }
      },
      write: async fn(bytes : Bytes) -> Unit {
        ignore(
          cb_call({
            "kind": Json::string("stream.write"),
            "stream": Json::number(sth.to_double()),
            "b64": Json::string(@codec.base64_encode(bytes[:])),
          }),
        )
      },
      finish: async fn() -> Unit {
        ignore(
          cb_call({
            "kind": Json::string("stream.finish"),
            "stream": Json::number(sth.to_double()),
          }),
        )
      },
      stopped: async fn() -> Int? { st.stopped_def.wait() },
      reset: async fn(code : Int) -> Unit {
        ignore(
          cb_call({
            "kind": Json::string("stream.reset"),
            "stream": Json::number(sth.to_double()),
            "code": Json::number(code.to_double()),
          }),
        )
      },
      media_datagrams: None,
    }
    stream_refs.push((sth, s))
    s
  }

  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    if !clock_override.val {
      now_ms.val = @host.epoch_ms().to_double()
    }
    let ask = @json.parse(line) catch { _ => Json::null() }

    // 1. Reply to a MoonBit -> Node callback
    if sn_at(ask, "reply") is Some(Number(n, ..)) {
      let cid = n.to_int()
      if pending_cbs.get(cid) is Some(d) {
        pending_cbs.remove(cid)
        match sn_at(ask, "error") {
          Some(String(e)) => ignore(d.succeed(Err(e)))
          _ => ignore(d.succeed(Ok(sn_at(ask, "ok").unwrap_or(Json::null()))))
        }
      }
      continue
    }

    // 2. Push events from Node (conn/stream lifecycle)
    if sn_at(ask, "event") is Some(String(ev)) {
      match ev {
        "conn.open" => {
          let sh = sn_int(ask, "station", -1)
          let ch = sn_int(ask, "conn", -1)
          let remote_id = sn_str(ask, "remoteId")
          if stations.get(sh) is Some(st) {
            let bc : LeafBridgedConn = {
              coming: @effect.Queue::unbounded(),
              closed_def: @effect.Deferred::new(),
              is_closed: Ref(false),
            }
            conns[ch] = bc
            let conn : @door.Connection = {
              remote_id: () => remote_id,
              alpn: () => @gate.alpn,
              via: () => None,
              paths: None,
              accept_bi: async fn() -> @door.Stream? { bc.coming.take() },
              open_bi: async fn() -> @door.Stream { raise @door.WireError("open_bi unsupported in harness-leaf") },
              answers: None,
              stats: None,
              close: (code, reason) => {
                if !bc.is_closed.val {
                  bc.is_closed.val = true
                  ignore(bc.closed_def.succeed(reason))
                  ignore(host.rt.fork_quiet(() => bc.coming.offer(None)))
                  host.say(
                    Json::object({
                      "event": Json::string("conn.close"),
                      "conn": Json::number(ch.to_double()),
                      "code": Json::number(code.to_double()),
                      "reason": Json::string(reason),
                    }).stringify(),
                  )
                }
              },
              is_closed: () => bc.is_closed.val,
              closed: async fn() -> String { bc.closed_def.wait() },
              close_reason: None,
              handed: Some(ch),
            }
            ignore(
              host.rt.fork_daemon("harness-leaf serve", on_error=_ => (), async fn() {
                let err = try {
                  @gate.serve(st.members, conn)
                  None
                } catch {
                  e => Some(@door.message_of(e))
                }
                conns.remove(ch)
                let msg : Map[String, Json] = {
                  "event": Json::string("conn.ended"),
                  "conn": Json::number(ch.to_double()),
                }
                if err is Some(e) {
                  msg["error"] = Json::string(e)
                }
                host.say(Json::object(msg).stringify())
              }),
            )
          }
        }
        "conn.closed" => {
          let ch = sn_int(ask, "conn", -1)
          let reason = sn_str(ask, "reason")
          if conns.get(ch) is Some(bc) {
            if !bc.is_closed.val {
              bc.is_closed.val = true
              ignore(bc.closed_def.succeed(reason))
              bc.coming.offer(None)
            }
          }
        }
        "stream.open" => {
          let ch = sn_int(ask, "conn", -1)
          let sth = sn_int(ask, "stream", -1)
          if conns.get(ch) is Some(bc) {
            bc.coming.offer(Some(make_stream(sth)))
          }
        }
        "stream.data" => {
          let sth = sn_int(ask, "stream", -1)
          if streams.get(sth) is Some(st) {
            if @codec.base64_decode(sn_str(ask, "b64")) is Some(bytes) {
              st.chunks.offer(Some(bytes))
            }
          }
        }
        "stream.eof" => {
          let sth = sn_int(ask, "stream", -1)
          if streams.get(sth) is Some(st) {
            st.chunks.offer(None)
          }
        }
        "stream.stopped" => {
          let sth = sn_int(ask, "stream", -1)
          if streams.get(sth) is Some(st) {
            let code = match sn_at(ask, "code") {
              Some(Number(n, ..)) => Some(n.to_int())
              _ => None
            }
            ignore(st.stopped_def.succeed(code))
            streams.remove(sth)
            match stream_refs.search_by(pair => pair.0 == sth) {
              Some(idx) => ignore(stream_refs.remove(idx))
              None => ()
            }
          }
        }
        _ => ()
      }
      continue
    }

    // 3. Request/Response RPC from Node
    let id = sn_at(ask, "id").unwrap_or(Json::null())
    let op = sn_str(ask, "op")
    if sn_at(ask, "nowMs") is Some(Number(n, ..)) {
      clock_override.val = true
      now_ms.val = n
    }
    let reply : Result[Json, String] = try {
      match op {
        "workspaceScope" => {
          let origin = sn_str(ask, "origin")
          let workspace = sn_str(ask, "workspace")
          Ok(Json::string(@mesh_scopes.workspace_scope(base_scopes_crypto, origin, workspace)))
        }
        "createStation" => {
          let data = sn_str(ask, "data")
          let station_id = sn_str(ask, "stationId")
          let secret_hex = sn_str(ask, "secretKey")
          let station_key = @cloud_lock.StationKey::new(host, @cloud_lock.hex_bytes(secret_hex))
          let fields = match sn_at(ask, "state") {
            Some(Object(m)) => m.copy()
            _ => Map([])
          }
          @cloud_lock.write_state(disk, data, { fields, })
          let cloud = @cloud_lock.Cloud::new(host, data, lock_crypto, () => lk_now_secs(now_ms))
          let builds = @cloud_lock.DeviceBuilds::new(None, lk_now_secs(now_ms))
          let keeper = lk_make_keeper(host, cloud, lock_crypto, builds, now_ms)
          let db = ml_init_mesh_db(host)
          let state_cloud = @cloud_net.StateCloud::new(Some(Json::object(fields)))
          let cloud_view : @cloud_net.CloudView = { ..state_cloud.view(), peers_current: () => true }
          let ways = @cloud_net.Ways::new(
            cloud_view,
            @cloud_net.Kept::memory().0,
            () => lk_now_secs(now_ms).to_int64(),
          )
          let scopes_crypto = ml_scopes_crypto(host, text => station_key.sign(text))
          let own_descriptors : Map[String, Json] = Map([])
          let configured_defs : Map[String, @effect.Deferred[Unit]] = Map([])
          let scope_listen_cb : Ref[((Array[Json]) -> Unit)?] = Ref(None)
          let records_by_scope : Array[(String, Array[Json])] = []
          match sn_at(ask, "records") {
            Some(Object(rm)) =>
              for scope, list in rm {
                if list is Array(entries) {
                  records_by_scope.push((scope, entries))
                  configured_defs[scope] = @effect.Deferred::new()
                  for entry in entries {
                    let sk = sn_str(entry, "secretKey")
                    let k = @cloud_lock.StationKey::new(host, @cloud_lock.hex_bytes(sk))
                    if k.id == station_id {
                      own_descriptors[scope] = sn_at(entry, "descriptor").unwrap_or(Json::null())
                    }
                  }
                }
              }
            _ => ()
          }
          let mesh_endpoint : @mesh_scopes.MeshEndpoint = {
            configure: async fn(config : Json) -> Json {
              let scope = @mesh_scopes.text(@mesh_scopes.field(config, "scope")).unwrap_or("")
              match own_descriptors.get(scope) {
                Some(desc) => {
                  if configured_defs.get(scope) is Some(d) {
                    ignore(d.succeed(()))
                  }
                  desc
                }
                None => fail("missing own descriptor for scope \{scope}")
              }
            },
            remove: async fn(_scope : String) -> Unit { () },
            listen: cb => {
              scope_listen_cb.val = Some(cb)
              () => scope_listen_cb.val = None
            },
          }
          let sync = @mesh_scopes.ScopeSync::new(
            mesh_endpoint,
            db,
            scopes_crypto,
            station_id,
            {
              cloud: cloud_view,
              ways,
              call: async fn(_peer, _ws, _req) { fail("unknown method") },
              read: async fn(args) { ml_read_mesh_db(db, args) },
              after: @cloud_net.After::effect(host.rt).after,
              now: () => now_ms.val,
              log: msg => @host.note("harness-leaf: \{msg}"),
              info: (_, _) => (),
            },
            host.rt,
          )
          // Wait deterministically for ScopeSync's initial roster -> configure -> reconcile to finish.
          for _, d in configured_defs {
            d.wait()
          }
          sync.directory.reconcile()

          next_station += 1
          let sh = next_station
          let leaves = @mesh_scopes.Leaves::new(
            {
              id: station_id,
              attach: async fn(handed : Int?, req : Json) -> Json {
                cb_call({
                  "kind": Json::string("leaf.attach"),
                  "station": Json::number(sh.to_double()),
                  "conn": match handed {
                    Some(c) => Json::number(c.to_double())
                    None => Json::null()
                  },
                  "req": req,
                })
              },
              detach: async fn(req : Json) -> Unit {
                ignore(
                  cb_call({
                    "kind": Json::string("leaf.detach"),
                    "station": Json::number(sh.to_double()),
                    "req": req,
                  }),
                )
              },
            },
            sync,
          )
          let custom_paths : Set[String] = Set::new()
          for p in sn_params(ask, "customPaths") {
            if p is String(s) {
              custom_paths.add(s)
            }
          }
          let watch_headers : Array[String] = []
          for h in sn_params(ask, "watchHeaders") {
            if h is String(s) {
              watch_headers.push(s)
            }
          }
          let members : @gate.Members = {
            keeper,
            packer: ml_noop_packer(),
            up: () => true,
            admin: async fn(_ask) -> @door.Answer {
              { status: 404, headers: [("content-type", "application/json")], body: @door.Body::Whole(@utf8.encode("{\"error\":\"not found\"}")) }
            },
            remember_name: (_, _) => (),
            streams: Some(head => {
              if watch_headers.length() > 0 {
                if sn_at(head, "headers") is Some(Object(hm)) {
                  if watch_headers.iter().any(h => hm.contains(h)) {
                    host.say(
                      Json::object({
                        "event": Json::string("stream.head"),
                        "station": Json::number(sh.to_double()),
                        "head": head,
                      }).stringify(),
                    )
                  }
                }
              }
              let path = sn_str(head, "path")
              if custom_paths.contains(path) {
                Some(async fn(m_ask : @gate.MemberAsk) -> Unit {
                  let ch = m_ask.conn.handed.unwrap_or(-1)
                  let sth = match stream_refs.iter().find_first(pair => physical_equal(pair.1, m_ask.stream)) {
                    Some(pair) => pair.0
                    None => -1
                  }
                  ignore(
                    cb_call({
                      "kind": Json::string("stream.custom"),
                      "station": Json::number(sh.to_double()),
                      "conn": Json::number(ch.to_double()),
                      "stream": Json::number(sth.to_double()),
                      "head": m_ask.head,
                    }),
                  )
                })
              } else {
                None
              }
            }),
            screens: None,
            socket: None,
            traces: None,
            lan: () => [],
            tailnet: () => [],
            connected: () => (),
            served: None,
            lang_of: _ => "en",
            update_words: _ => "update app",
            leaves: Some({
              authenticated: (conn, ws, exp) => leaves.authenticated(conn, ws, exp),
              view: ws => {
                host.say(
                  Json::object({
                    "event": Json::string("leaf.view"),
                    "station": Json::number(sh.to_double()),
                    "workspace": Json::string(ws),
                  }).stringify(),
                )
                leaves.view(ws)
              },
              follow: async fn(conn, ws, stream) { leaves.follow(conn, ws, stream) },
              attach: async fn(conn, ws, raw, target) { leaves.attach(conn, ws, raw, target) },
            }),
          }
          let inst : LeafStationInstance = {
            station_id,
            db,
            sync,
            members,
            own_descriptors,
            scope_listen_cb,
            revisions: Map([]),
            last_peer_json: Map([]),
          }
          stations[sh] = inst
          for pair in records_by_scope {
            ml_sync_records(host, inst, pair.0, pair.1)
          }
          Ok(Json::object({ "handle": Json::number(sh.to_double()) }))
        }
        "updateRecords" => {
          let sh = sn_int(ask, "handle", -1)
          guard stations.get(sh) is Some(st) else { fail("no leaf station handle \{sh}") }
          let scope = sn_str(ask, "scope")
          ml_sync_records(host, st, scope, sn_params(ask, "records"))
          Ok(Json::boolean(true))
        }
        "closeStation" => {
          let sh = sn_int(ask, "handle", -1)
          if stations.get(sh) is Some(st) {
            st.sync.close()
            st.db.close()
            stations.remove(sh)
          }
          Ok(Json::boolean(true))
        }
        _ => Err("unknown op \{op}")
      }
    } catch {
      e => Err(lk_err_words(e))
    }
    match reply {
      Ok(v) => host.say(Json::object({ "id": id, "ok": v }).stringify())
      Err(m) => host.say(Json::object({ "id": id, "error": Json::string(m) }).stringify())
    }
  }
  for _, st in stations {
    st.sync.close()
    st.db.close()
  }
  stations.clear()
}
