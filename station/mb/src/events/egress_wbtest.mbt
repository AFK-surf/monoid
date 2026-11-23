// Where the machine's traffic leaves for the internet (host.mbt `egress_of`, `Host::sample`), as
// station/test/egress.test.ts holds the TypeScript's.

///|
let trace : String = "fl=29f\nh=www.cloudflare.com\nip=203.0.113.7\nts=1795373061.8\nvisit_scheme=https\ncolo=SEA\nloc=US\ntls=TLSv1.3\n"

///|
fn egress_said(trace : String) -> String {
  match egress_of(trace) {
    Some(e) => stringify(e)
    None => "none"
  }
}

///|
test "a trace says the country and data centre it was seen from; no country, nothing" {
  assert_eq(egress_said(trace), "{\"country\":\"US\",\"colo\":\"SEA\"}")
  assert_eq(egress_said("loc=jp\ncolo=\n"), "{\"country\":\"JP\",\"colo\":null}")
  assert_eq(egress_said("loc=HK\r\ncolo=hkg\r\n"), "{\"country\":\"HK\",\"colo\":\"HKG\"}")
  assert_eq(egress_said("colo=SEA\n"), "none")
  assert_eq(egress_said("loc=XX\ncolo=SEA\n"), "none")
  assert_eq(egress_said("loc=T1\n"), "none")
  assert_eq(egress_said("<html>blocked</html>"), "none")
}

///|
fn sample_deps(seen : Ref[J?], test_host : Bool) -> HostDeps {
  {
    test_host: () => test_host,
    now: () => 1000.0,
    after: (_, _) => () => (),
    cpu_ticks: k => k(None),
    sample: k => k(jo([("osName", js("Linux")), ("cpuModel", js("c")), ("uptimeSec", jn(1.0))])),
    statfs: (_, k) => k(None),
    hostname: () => "h",
    parallelism: () => 1,
    loadavg: () => [0.0, 0.0, 0.0],
    arch: "x64",
    os: () => "linux",
    gpus_read: k => k(Some(ja([]))),
    gpus_cached: None,
    egress: () => seen.val,
  }
}

///|
fn sampled(host : Host) -> J {
  let out : Ref[J?] = { val: None }
  host.sample(v => out.val = Some(v))
  out.val.unwrap()
}

///|
test "the machine's sample says where it leaves once it is known, and nothing of it before" {
  let seen : Ref[J?] = { val: None }
  let host = Host::new(sample_deps(seen, false), "/tmp")
  assert_true(sampled(host).get("egress") is None)
  seen.val = egress_of("loc=CN\ncolo=SHA\n")
  // (the machine's own reading is kept ten seconds; where it leaves is said as it is now)
  assert_eq(stringify(sampled(host).get("egress").unwrap()), "{\"country\":\"CN\",\"colo\":\"SHA\"}")
}

///|
test "the recording station's fixed sample says nothing of where it leaves" {
  let seen : Ref[J?] = { val: egress_of(trace) }
  let host = Host::new(sample_deps(seen, true), "/tmp")
  assert_true(sampled(host).get("egress") is None)
}
