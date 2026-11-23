// The workspaces' mesh directory and the relays' door, as mesh.ts makes them (mesh/scope-sync.ts,
// enrollment-door.ts; the package station/mb src/mesh_scopes): the directory where the endpoint keeps scopes (the
// front's), kept level with the other stations over the peer bus (`meshScopes.exchange`, `meshRelays.exchange`,
// `meshRelays.revoke`), and the relays tool's list, enrollment and revocation (agents.ts `meshList`, `enroll`,
// `revoke`) answered through the bus's `cloud_call`.

///|
/// The shell's Ed25519 and digests, the station's key signing.
fn p51_scopes_crypto(bus : LiveBus) -> @mesh_scopes.Crypto {
  let host = bus.host
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
    sign: text => bus.key.sign(text),
    sha256: bytes => match (try { Ok(host.shell_sync("crypto.sha256", { "data": Json::string(@mesh_scopes.hex_of(bytes)) })) } catch { e => Err(e) }) {
      Ok(String(h)) => h
      _ => ""
    },
    random: n => match (try { Ok(host.shell_sync("crypto.random", { "bytes": Json::number(n.to_double()) })) } catch { e => Err(e) }) {
      Ok(String(h)) => unhex_lenient(h)
      _ => Bytes::make(n, b'\x00')
    },
  }
}

///|
/// The directory made where the endpoint keeps scopes, its peers' requests answered, the relays tool's asks answered
/// (till `stops` is run, as the mesh it was made for ends); the door the relays' connections are served by.
fn P51::mesh_scopes(
  self : P51,
  m : MeshLive,
  endpoint : Endpoint,
  plane : Plane,
  call : @gate.StationCall,
  stops : Array[() -> Unit],
) -> @mesh_scopes.EnrollmentDoor {
  let bus = self.bus
  let crypto = p51_scopes_crypto(bus)
  let read = async fn(args : Json) -> Json { @readops.mesh_control_read(bus.db, args) }
  let now = () => wall_ms().to_double()
  let full_cloud : @cloud_net.CloudView = {
    ..plane.ways.cloud,
    memberships: () => (plane.ways.cloud.memberships)().filter(ms => !(plane.ways.cloud.rig_in)(ms.workspace)),
    membership: ws => if (plane.ways.cloud.rig_in)(ws) { None } else { (plane.ways.cloud.membership)(ws) },
  }
  m.scopes = match endpoint.mesh {
    Some(ops) =>
      Some(
        @mesh_scopes.ScopeSync::new(
          ops.scopes,
          bus.db,
          crypto,
          bus.key.id,
          {
            cloud: full_cloud,
            ways: plane.ways,
            call: async fn(peer, ws, request) { (call.call)(peer, Some(ws), request, None).0 },
            read,
            after: @cloud_net.After::effect(bus.host.rt).after,
            now,
            log: words => p51_log("WARN", "mesh", words),
            info: (words, fields) => p51_log("INFO", "mesh", words, fields~),
          },
          bus.host.rt,
        ),
      )
    None => None
  }
  // (the directory's own requests: membership of the workspace, never a rig's grant, answers them)
  m.peers.on(["meshScopes.exchange", "meshRelays.exchange", "meshRelays.revoke"], async fn(peer, request, _bytes, ws) {
    match m.scopes {
      Some(sync) => (sync.answer(peer, ws, request), None)
      None => raise @gate.PeerRefused("no such method: the mesh directory is not available on this station")
    }
  })
  let enrollment = @mesh_scopes.Enrollment::new(bus.db, bus.key.id, now, crypto) catch {
    e => abort("the station's key is no mesh identity: \{e}")
  }
  let allowed = (scope : String) => match (plane.ways.cloud.origin)() {
    Some(o) =>
      (full_cloud.memberships)().iter().any(ms => @mesh_scopes.workspace_scope(crypto, o, ms.workspace) == scope)
    None => false
  }
  // The relays tool's asks (agents.ts `meshList`, `revoke`, `enroll`), the rest the plane's.
  let before = bus.cloud_call.val
  bus.cloud_call.val = async fn(op, arg) {
    let ws = @mesh_scopes.text(@mesh_scopes.field(arg, "workspace")).unwrap_or("")
    match op {
      "meshList" =>
        match m.scopes {
          Some(sync) => Json::array(sync.relays(ws) catch { _ => [] })
          None => Json::array([])
        }
      "meshRevoke" =>
        match m.scopes {
          Some(sync) => sync.revoke(ws, @mesh_scopes.text(@mesh_scopes.field(arg, "node")).unwrap_or(""))
          None => fail("native mesh relay control is not available on this station")
        }
      "meshEnroll" => {
        guard m.scopes is Some(_) else { fail("native mesh relay enrollment is not available on this station") }
        guard (plane.ways.cloud.origin)() is Some(origin) && (plane.ways.cloud.membership)(ws) is Some(_) else {
          fail("this station is not in the relay's workspace")
        }
        let issued = enrollment.issue(
          @mesh_scopes.workspace_scope(crypto, origin, ws),
          @mesh_scopes.text(@mesh_scopes.field(arg, "name")).unwrap_or(""),
          @mesh_scopes.text(@mesh_scopes.field(arg, "by")).unwrap_or(""),
        )
        match issued {
          Object(o) => {
            let out = o.copy()
            out["endpoint"] = @cloud_net.station_addr(plane.ways, bus.key.id, workspace=ws).to_json()
            Json::object(out)
          }
          other => other
        }
      }
      _ => before(op, arg)
    }
  }
  stops.push(() => bus.cloud_call.val = before)
  @mesh_scopes.EnrollmentDoor::new({
    enrollment,
    allowed,
    read: async fn(scope, node) {
      read({ "kind": "registration", "scope": Json::string(scope), "node": Json::string(node), "issuer": Json::string(bus.key.id) })
    },
    registered: async fn(signed) {
      let body = @json.parse(@mesh_scopes.text(@mesh_scopes.field(signed, "body")).unwrap_or(""))
      ignore(
        @mesh_scopes.take_relay_record(
          bus.db,
          crypto,
          signed,
          @mesh_scopes.text(@mesh_scopes.field(body, "scope")).unwrap_or(""),
          Set::from_array([bus.key.id]),
        ),
      )
      if m.scopes is Some(sync) { sync.registration(signed) }
    },
    sync: m.scopes,
    crypto,
  })
}
