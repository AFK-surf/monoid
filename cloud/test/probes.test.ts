import assert from "node:assert/strict";
import test from "node:test";
import { endpointOf, LOCATIONS, probeRelays, SETTLE_MS } from "../src/probes.ts";

// Globalping as the probes see it: a measurement made for each relay, its results read once the probes had time.
function fakeGlobalping(fail: string[] = []) {
  const made: { target: string; port: number; locations: unknown }[] = [];
  const fetch = async (input: string, init?: RequestInit): Promise<Response> => {
    if (init?.method === "POST") {
      const body = JSON.parse(String(init.body));
      made.push({ target: body.target, port: body.measurementOptions.port, locations: body.locations });
      if (fail.includes(body.target)) return new Response("{}", { status: 429 });
      return Response.json({ id: `m-${body.target}`, probesCount: 2 }, { status: 202 });
    }
    const target = input.split("/m-")[1]!;
    const probe = (city: string, network: string, asn: number) => ({ country: "CN", state: null, city, asn, network, region: "Eastern Asia" });
    return Response.json({
      id: `m-${target}`,
      status: "finished",
      results: [
        { probe: probe("Guangzhou", "Chinanet Backbone", 4134), result: { status: "finished", stats: { min: 11.2, avg: target === "47.76.247.168" ? 138.6 : 11.8, max: 12.9, loss: 0 } } },
        { probe: probe("Wuhan", "CHINA UNICOM China169 Backbone", 4837), result: { status: "failed", stats: { loss: 100 } } },
      ],
    });
  };
  return { made, fetch };
}

// 2026-10-30, by hand: Guangzhou's China Telecom reached Hong Kong's relay in 139 ms and Shenzhen's in 12. The relays are
// probed from the same probes (the first measurement's), each probe's result a line of its relay; a probe that got no
// answer says so, with no round trip.
test("the relays are probed from the same probes in China's networks", async () => {
  const g = fakeGlobalping();
  const waited: number[] = [];
  const found = await probeRelays(["https://app.still.fail", "https://47.76.247.168", "https://120.24.233.158"], g.fetch, async (ms) => void waited.push(ms));
  assert.deepEqual(g.made, [
    { target: "app.still.fail", port: 443, locations: LOCATIONS },
    { target: "47.76.247.168", port: 443, locations: "m-app.still.fail" },
    { target: "120.24.233.158", port: 443, locations: "m-app.still.fail" },
  ]);
  assert.deepEqual(waited, [SETTLE_MS]);
  assert.deepEqual([...found.keys()], ["https://app.still.fail", "https://47.76.247.168", "https://120.24.233.158"]);
  assert.deepEqual(found.get("https://47.76.247.168"), [
    { probe_country: "CN", probe_region: "", probe_city: "Guangzhou", probe_asn: 4134, probe_network: "Chinanet Backbone", status: "finished", rtt_avg: 138.6, rtt_min: 11.2, rtt_max: 12.9, loss: 0 },
    { probe_country: "CN", probe_region: "", probe_city: "Wuhan", probe_asn: 4837, probe_network: "CHINA UNICOM China169 Backbone", status: "failed", loss: 100 },
  ]);
});

// Globalping refusing one (its hourly allowance used up): that relay has no lines, the others theirs; none made, nothing
// waited for.
test("a relay whose measurement was refused has no lines", async () => {
  const g = fakeGlobalping(["app.still.fail"]);
  const found = await probeRelays(["https://app.still.fail", "https://120.24.233.158"], g.fetch, async () => {});
  assert.deepEqual(g.made.map((m) => m.locations), [LOCATIONS, LOCATIONS]);
  assert.deepEqual([...found.keys()], ["https://120.24.233.158"]);
  const none = fakeGlobalping(["app.still.fail"]);
  let waited = false;
  assert.equal((await probeRelays(["https://app.still.fail"], none.fetch, async () => void (waited = true))).size, 0);
  assert.equal(waited, false);
});

// Relays on the list listen on 24444 and 8445: each is probed on the port its URL names (443 there was whatever else the
// machine serves), an IPv6 one by its bare address, from the first measurement's probes; what is no relay's URL is
// skipped, asked of nobody.
test("each relay is probed on the port it listens on", async () => {
  const g = fakeGlobalping();
  const relays = ["https://app.monoid.build", "https://216.152.148.168:24444", "https://relay.pvg.office.afk.surf:8445", "https://[2001:db8::1]:8445", "http://192.0.2.7", "not a url", "ftp://192.0.2.8:21", "https://192.0.2.9:0"];
  const found = await probeRelays(relays, g.fetch, async () => {});
  assert.deepEqual(g.made, [
    { target: "app.monoid.build", port: 443, locations: LOCATIONS },
    { target: "216.152.148.168", port: 24444, locations: "m-app.monoid.build" },
    { target: "relay.pvg.office.afk.surf", port: 8445, locations: "m-app.monoid.build" },
    { target: "2001:db8::1", port: 8445, locations: "m-app.monoid.build" },
    { target: "192.0.2.7", port: 80, locations: "m-app.monoid.build" },
  ]);
  assert.deepEqual([...found.keys()], relays.slice(0, 5));
  assert.deepEqual(endpointOf("https://147.93.128.125:24444"), { target: "147.93.128.125", port: 24444 });
  assert.equal(endpointOf("https://:443"), null);
});
