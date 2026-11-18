// Internal mesh control reads, never exposed as device routes. Each lookup uses
// the composite primary key and returns at most one row per requested identity.
///|
pub fn mesh_control_read(db : @sql.Db, args : Json) -> Json raise {
  let scope = args.value("scope").unwrap_or(Json::null())
  match args.value("kind") {
    Some(String("announcements")) => {
      let nodes = match args.value("nodes") {
        Some(Array(nodes)) if nodes.length() <= 256 => nodes
        _ => return Json::null()
      }
      let out : Array[Json] = []
      for node in nodes {
        let rows = db.all("SELECT body,signature FROM mesh_announcements WHERE scope=?1 AND node=?2", [scope, node])
        if rows.get(0) is Some(row) { out.push(Json::object(row)) }
      }
      Json::array(out)
    }
    Some(String("relayRecords")) => {
      let rows = db.all("SELECT body,signature FROM mesh_relay_records WHERE scope=?1 ORDER BY node LIMIT 257", [scope])
      Json::array(rows.map(row => Json::object(row)))
    }
    Some(String("registration")) => {
      let rows = db.all("SELECT scope,node,issuer,generation,name,made_by,revoked FROM mesh_relay_registrations WHERE scope=?1 AND node=?2 AND issuer=?3 AND revoked=0", [scope, args.value("node").unwrap_or(Json::null()), args.value("issuer").unwrap_or(Json::null())])
      match rows.get(0) { Some(row) => Json::object(row); None => Json::null() }
    }
    _ => Json::null()
  }
}
