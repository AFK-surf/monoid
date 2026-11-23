// What a machine is changes only when two agree (presence.ts `applyFrame`): what was asked of the machine itself
// (`rig_pending`, `full_pending`), kept an hour, and the plane listing it so as that same person's. Neither alone.

///|
fn mode_cloud(extra : Map[String, Json]) -> (StateCloud, PlaneCloud, Ref[Int]) {
  let m : Map[String, Json] = {
    "origin": "https://app.still.fail",
    "station": Json::string("aa".repeat(32)),
    "workspace": "w1",
    "workspace_name": "W1",
    "name": "here",
    "relay_url": "https://relay.example",
    "relay_urls": ["https://relay.example"],
    "grant_keys": {},
    "peers": [],
    "revocations": [],
  }
  for k, v in extra {
    m[k] = v
  }
  let c = StateCloud::new(Some(Json::object(m)))
  let gone = Ref(0)
  let p = PlaneCloud::new(c, () => 100_000L, rig_grants_gone=() => gone.val += 1)
  (c, p, gone)
}

///|
fn listed(owner : String?) -> Json {
  match owner {
    Some(o) => { "type": "state", "peers": [], "rig": { "owner": Json::string(o) } }
    None => { "type": "state", "peers": [], "rig": Json::null() }
  }
}

///|
fn has(c : StateCloud, k : String) -> Bool {
  c.state.unwrap().get(k) is Some(_)
}

///|
let pending_self : Json = {
  "owner": "u1",
  "owner_email": "u1@x",
  "owner_name": "U1",
  "person": Json::string("cd".repeat(32)),
}

///|
test "whole to tasks: asked of the machine and listed so by the plane as the same person's" {
  let pending = object_copy(pending_self)
  pending["at"] = Json::number(99_990.0)
  let (c, p, _) = mode_cloud({ "rig_pending": Json::object(pending) })
  apply_frame(p, listed(None), _ => ())
  assert_false(has(c, "rig_due"))
  apply_frame(p, listed(Some("u2")), _ => ())
  assert_false(has(c, "rig_due"))
  apply_frame(p, listed(Some("u1")), _ => ())
  assert_true(has(c, "rig_due"))
}

///|
test "whole to tasks: allowed in multi-workspace (mixed mode), not once the hour is over" {
  let pending = object_copy(pending_self)
  pending["at"] = Json::number(99_990.0)
  let (c, p, _) = mode_cloud({ "rig_pending": Json::object(pending) })
  let joined : Json = {
    "type": "state",
    "peers": [],
    "rig": { "owner": "u1" },
    "workspaces": [{ "workspace": "w2" }],
  }
  apply_frame(p, joined, _ => ())
  assert_true(has(c, "rig_due"))
  let old = object_copy(pending_self)
  old["at"] = Json::number((100_000 - 3601).to_double())
  let (c2, p2, _) = mode_cloud({ "rig_pending": Json::object(old) })
  apply_frame(p2, listed(Some("u1")), _ => ())
  assert_false(has(c2, "rig_due"))
  assert_false(has(c2, "rig_pending"))
  // (exactly an hour is still in time)
  let edge = object_copy(pending_self)
  edge["at"] = Json::number((100_000 - 3600).to_double())
  let (c3, p3, _) = mode_cloud({ "rig_pending": Json::object(edge) })
  apply_frame(p3, listed(Some("u1")), _ => ())
  assert_true(has(c3, "rig_due"))
}

///|
test "the plane's word alone makes no rig, and a rig's own word alone makes it no station" {
  let (c, p, _) = mode_cloud({})
  apply_frame(p, listed(Some("u1")), _ => ())
  assert_false(has(c, "rig_due"))
  assert_false(has(c, "rig"))
  let rig_self = pending_self
  let (c2, p2, gone) = mode_cloud({ "rig": rig_self })
  apply_frame(p2, listed(None), _ => ())
  assert_true(has(c2, "rig"))
  assert_eq(gone.val, 0)
}

///|
test "tasks to whole: its person signed it and the plane lists it whole; its grants go and same-frame rigs are kept" {
  let (c, p, gone) = mode_cloud({
    "rig": pending_self,
    "full_pending": { "at": 99_000 },
  })
  apply_frame(p, listed(Some("u1")), _ => ())
  assert_true(has(c, "rig"))
  assert_true(has(c, "full_pending"))
  let peer_rig : Json = { "id": Json::string("dd".repeat(32)), "owner": "u1", "name": "other" }
  apply_frame(p, { "type": "state", "peers": [], "rig": Json::null(), "rigs": [peer_rig] }, _ => ())
  assert_false(has(c, "rig"))
  assert_false(has(c, "full_pending"))
  assert_true(has(c, "rigs"))
  assert_eq(gone.val, 1)
  let (c2, p2, gone2) = mode_cloud({
    "rig": pending_self,
    "full_pending": { "at": 90_000 },
  })
  apply_frame(p2, listed(None), _ => ())
  assert_true(has(c2, "rig"))
  assert_false(has(c2, "full_pending"))
  assert_eq(gone2.val, 0)
}

///|
test "skipped rig workspace: never admitted as full before local RigSelf, replayed once written" {
  let (c, p, _) = mode_cloud({})
  let peer : Json = { "id": Json::string("bb".repeat(32)), "name": "peer", "ips": ["127.0.0.1:41641"] }
  let frame : Json = {
    "type": "state",
    "peers": [],
    "workspaces": [{
      "workspace": "w2",
      "workspace_name": "W2",
      "name": "here",
      "peers": [peer],
      "rig": { "owner": "u1" },
    }],
  }
  apply_frame(p, frame, _ => ())
  // Not admitted as full workspace!
  assert_false(has(c, "joined"))
  assert_eq(p.skipped_rig_ws, ["w2"])
  // Once local join writes RigSelf for w2, replay restores it with peers
  c.update(st => {
    st["joined"] = Json::array([{
      "workspace": "w2",
      "workspace_name": "W2",
      "name": "here",
      "peers": [],
      "revocations": [],
      "rig": pending_self,
    }])
  })
  assert_true(replay_skipped_rig_frame(p, _ => ()))
  let joined = c.state.unwrap().get("joined").unwrap().stringify()
  assert_true(joined.contains("bb".repeat(32)))
  assert_true(joined.contains("\"rig\""))
  assert_eq(p.skipped_rig_ws, [])
}

///|
test "a rig keeps no rigs of its workspace's, a station keeps the plane's" {
  let rigs : Json = [
    { "id": Json::string("bb".repeat(32)), "owner": "u1", "name": "r" },
    { "id": "not hex", "owner": "u1" },
  ]
  let (c, p, _) = mode_cloud({})
  apply_frame(p, { "type": "state", "peers": [], "rigs": rigs }, _ => ())
  assert_eq(
    c.state.unwrap().get("rigs").map(r => r.stringify()),
    Some(
      "[{\"id\":\"\{"bb".repeat(32)}\",\"name\":\"r\",\"owner\":\"u1\",\"owner_email\":\"\",\"owner_name\":\"\"}]",
    ),
  )
  let (c2, p2, _) = mode_cloud({ "rig": pending_self })
  apply_frame(p2, { "type": "state", "peers": [], "rigs": rigs }, _ => ())
  assert_false(has(c2, "rigs"))
}

///|
test "a revocation of a joined workspace goes there, of one it is not in nowhere" {
  let (c, p, _) = mode_cloud({
    "joined": [{ "workspace": "w2", "peers": [], "revocations": [] }],
  })
  apply_frame(p, { "type": "revoke", "kind": "device", "id": "d1", "at": 5 }, _ => ())
  apply_frame(p, { "type": "revoke", "kind": "device", "id": "d1", "at": 6 }, _ => ())
  apply_frame(
    p,
    { "type": "revoke", "kind": "device", "id": "d2", "at": 7, "workspace": "w2" },
    _ => (),
  )
  apply_frame(
    p,
    { "type": "revoke", "kind": "device", "id": "d3", "at": 7, "workspace": "w9" },
    _ => (),
  )
  let st = c.state.unwrap()
  assert_eq(
    st.get("revocations").map(r => r.stringify()),
    Some("[{\"kind\":\"device\",\"id\":\"d1\",\"at\":6}]"),
  )
  assert_true(st.get("joined").unwrap().stringify().contains("d2"))
  assert_false(Json::object(st).stringify().contains("d3"))
}

///|
test "the frames' heads of the locks: a plane from before says none, one that keeps one its seq" {
  let (_, p, _) = mode_cloud({})
  apply_frame(p, { "type": "state", "peers": [] }, _ => ())
  assert_eq(p.plane_lock_seq, None)
  apply_frame(p, { "type": "state", "peers": [], "lock": Json::null() }, _ => ())
  assert_eq(p.plane_lock_seq, Some(-1))
  apply_frame(
    p,
    { "type": "state", "peers": [], "lock": { "seq": 4, "hash": "h4" } },
    _ => (),
  )
  assert_eq(p.plane_lock_seq, Some(4))
  assert_eq(p.plane_lock_hashes.get(""), Some("h4"))
}

///|
test "what else the plane tells is told apart from its state" {
  let told = []
  assert_true(cloud_said({ "type": "release" }, s => told.push(s.to_json().stringify())))
  assert_true(
    cloud_said({ "type": "models", "etag": "e1" }, s => told.push(s.to_json().stringify())),
  )
  assert_true(
    cloud_said({ "type": "models", "etag": 3 }, s => told.push(s.to_json().stringify())),
  )
  assert_false(cloud_said({ "type": "state" }, _ => ()))
  assert_eq(told, [
    "{\"type\":\"release\"}", "{\"type\":\"models\",\"etag\":\"e1\"}", "{\"type\":\"models\"}",
  ])
}
