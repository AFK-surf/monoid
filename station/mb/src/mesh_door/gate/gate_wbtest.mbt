///|
test "route_of, reads_of, query_pairs, lower_role, build_of, and lang_of_core" {
  assert_eq(route_of("/overview?a=1"), "/overview")
  assert_eq(route_of("/events"), "/events")
  assert_true(reads_of("GET", "/overview"))
  assert_true(reads_of("GET", "/events"))
  assert_false(reads_of("POST", "/chats"))

  assert_eq(query_pairs("a=1&b=hello%20world&c="), [("a", "1"), ("b", "hello world"), ("c", "")])
  assert_eq(query_pairs(""), [])

  assert_eq(lower_role("owner", "member"), "member")
  assert_eq(lower_role("admin", "owner"), "admin")
  assert_eq(lower_role("viewer", "member"), "viewer")

  assert_eq(build_of(Some("9144")), Some(9144))
  assert_eq(build_of(Some("  ")), None)
  assert_eq(build_of(None), None)

  assert_eq(lang_of_core([("StillFail-Lang", " EN-us ")]), "en")
  assert_eq(lang_of_core([("StillFail-Lang", "zh-CN")]), "zh")
  assert_eq(lang_of_core([]), "zh")
}

///|
test "Superseded tracks connections per peer id and closes unresponsive older ones" {
  let rt = @effect.Runtime::new()
  let sup = Superseded::new()
  let closes : Array[(String, Int, String)] = []
  let mk = (id : String, name : String, answers : Bool) => {
    let closed = Ref(false)
    let done : @effect.Deferred[String] = @effect.Deferred::new()
    ({
      remote_id: () => id,
      alpn: () => "",
      via: () => None,
      paths: None,
      accept_bi: async fn() -> @door.Stream? { None },
      open_bi: async fn() -> @door.Stream { raise @door.DoorError("none") },
      answers: Some(async fn(_ms : Int) -> Bool { answers }),
      stats: None,
      close: (code, reason) => if !closed.val {
        closed.val = true
        closes.push((name, code, reason))
        ignore(done.succeed(reason))
      },
      is_closed: () => closed.val,
      closed: async fn() -> String { done.wait() },
      close_reason: None,
      handed: None,
    } : @door.Connection)
  }
  ignore(
    rt.fork(() => {
      let c1 = mk("peer-a", "c1", false)
      let c2 = mk("peer-a", "c2", true)
      sup.arrived(c1)
      sup.arrived(c2)
    }),
  )
  ignore(rt.run_ready())
  assert_eq(sup.of("peer-a"), 1)
  assert_eq(closes.length(), 1)
  assert_eq(closes[0].0, "c1")
}
