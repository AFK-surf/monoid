///|
test "runtime_compatible filters service profiles and backfills runtime for clients without stillfail-profile-services" {
  let overview =
    #|{"profiles":[{"id":"cc","name":"Claude","runtime":"claude","runtimes":["claude"],"access":{"kind":"subscription","key":""}},{"id":"jev","name":"Jev","runtime":null,"runtimes":[],"access":{"kind":"env","key":"k","provider":"jev"}},{"id":"gpu-1","name":"GPU","runtime":null,"service":"fake-gpu","runtimes":[],"access":{"kind":"service","key":"","service":"fake-gpu"}}],"logins":[{"id":"l1","runtime":"claude","job":null,"created":null,"error":null},{"id":"l2","runtime":null,"service":"fake-gpu","job":null,"created":null,"error":null}]}
  let answer : JsonAnswer = {
    status: 200,
    headers: [("content-type", "application/json")],
    body: overview,
  }
  let all_rts = runtime_kinds.join(",")

  // Legacy client: knows all runtimes, but no stillfail-profile-services header.
  let old_ans = runtime_compatible(
    "/overview",
    [(runtimes_header, all_rts)],
    "",
    "zh",
    answer,
  )
  let old_j = parse(old_ans.body).unwrap()
  let old_profiles = match old_j.get("profiles") {
    Some(Arr(a)) => a
    _ => []
  }
  assert_eq(old_profiles.length(), 2)
  assert_eq(text_of(old_profiles[0].get("id")), Some("cc"))
  assert_eq(text_of(old_profiles[1].get("id")), Some("jev"))
  assert_eq(text_of(old_profiles[1].get("runtime")), Some("claude"))
  let old_logins = match old_j.get("logins") {
    Some(Arr(a)) => a
    _ => []
  }
  assert_eq(old_logins.length(), 1)
  assert_eq(text_of(old_logins[0].get("id")), Some("l1"))

  // New client: sends stillfail-profile-services: 1.
  let new_ans = runtime_compatible(
    "/overview",
    [(runtimes_header, all_rts), (profile_services_header, "1")],
    "",
    "zh",
    answer,
  )
  let new_j = parse(new_ans.body).unwrap()
  let new_profiles = match new_j.get("profiles") {
    Some(Arr(a)) => a
    _ => []
  }
  assert_eq(new_profiles.length(), 3)
  assert_true(new_profiles[1].get("runtime") is Some(Null))
  assert_true(new_profiles[2].get("runtime") is Some(Null))
  assert_eq(text_of(new_profiles[2].get("service")), Some("fake-gpu"))
}
