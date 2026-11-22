// Where the machine's traffic leaves for the internet (api/egress.ts): read of Cloudflare's trace, kept across a look
// that fails, and said beside the machine's sample (Host.sample).
import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { EgressLook, egressOf } from "../src/api/egress.ts";
import { Host } from "../src/api/host.ts";

const TRACE = "fl=29f\nh=www.cloudflare.com\nip=203.0.113.7\nts=1795373061.8\nvisit_scheme=https\ncolo=SEA\nloc=US\ntls=TLSv1.3\n";

test("a trace says the country and data centre it was seen from; no country, nothing", () => {
  assert.deepEqual(egressOf(TRACE), { country: "US", colo: "SEA" });
  assert.deepEqual(egressOf("loc=jp\ncolo=\n"), { country: "JP", colo: null });
  assert.equal(egressOf("colo=SEA\n"), null);
  assert.equal(egressOf("loc=XX\ncolo=SEA\n"), null);
  assert.equal(egressOf("loc=T1\n"), null);
  assert.equal(egressOf("<html>blocked</html>"), null);
});

test("a look that fails keeps what the last one saw", async () => {
  let answer: () => Promise<string> = async () => TRACE;
  const look = new EgressLook(() => answer());
  assert.equal(look.now(), null);
  await look.look();
  assert.deepEqual(look.now(), { country: "US", colo: "SEA" });
  answer = async () => {
    throw new Error("offline");
  };
  await look.look();
  assert.deepEqual(look.now(), { country: "US", colo: "SEA" });
  answer = async () => "loc=HK\ncolo=HKG\n";
  await look.look();
  assert.deepEqual(look.now(), { country: "HK", colo: "HKG" });
});

test("the machine's sample says where it leaves once it is known, and nothing of it before", async () => {
  const info = async () => ({ info: { hostname: "h", checkedAt: 1 }, seen: null, needsTicks: false });
  let seen: { country: string; colo: string | null } | null = null;
  const host = new Host(tmpdir(), { read: async () => null }, info, { now: () => seen, follow: () => () => {} });
  assert.equal("egress" in (await host.sample()), false);
  seen = { country: "CN", colo: "SHA" };
  // (the machine's own reading is kept ten seconds; where it leaves is said as it is now)
  assert.deepEqual((await host.sample()).egress, { country: "CN", colo: "SHA" });
});
