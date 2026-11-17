import assert from "node:assert/strict";
import test from "node:test";
import { exportPKCS8, generateKeyPair } from "jose";
import { apnsPushAny } from "../src/apns.ts";
import { fcmPushAny } from "../src/fcm.ts";

for (const provider of ["apns", "fcm"] as const) {
  test(`${provider}: one app's transport failure does not stop another app's push or discard its token`, async (t) => {
    const privateKey = await exportPKCS8((await generateKeyPair(provider === "apns" ? "ES256" : "RS256", { extractable: true })).privateKey);
    const apps = ["first-app", "second-app"];
    const keys = apps.map((topic) => ({ keyId: topic, teamId: "TEAM", key: privateKey, topic }));
    const accounts = apps.map((project_id) => ({ project_id, client_email: `${project_id}@example.test`, private_key: privateKey, token_uri: "https://oauth.example/token" }));
    const tried: string[] = [];
    let gone = false;
    t.mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
      if (url === "https://oauth.example/token") return Response.json({ access_token: "access", expires_in: 3600 });
      const app = provider === "apns" ? new Headers(init.headers).get("apns-topic")! : /projects\/([^/]+)\//.exec(url)![1]!;
      tried.push(app);
      if (app === apps[0]) throw new TypeError("fetch failed");
      return gone ? Response.json(provider === "apns" ? { reason: "Unregistered" } : { error: { status: "UNREGISTERED" } }, { status: provider === "apns" ? 410 : 404 }) : new Response(null, { status: 200 });
    });
    const push = (known?: string) => provider === "apns"
      ? apnsPushAny(keys, "ab".repeat(32), false, known, { title: "Ready" })
      : fcmPushAny(accounts, "device-token", known, { title: "Ready" });

    assert.deepEqual(await push(), { outcome: "sent", app: apps[1] });
    assert.deepEqual(tried, apps, "the other app is tried even when the first transport throws");

    tried.length = 0;
    assert.deepEqual(await push(apps[1]), { outcome: "sent", app: apps[1] });
    assert.deepEqual(tried, [apps[1]], "the app that took the token remains first next time");

    gone = true;
    tried.length = 0;
    assert.deepEqual(await push(), { outcome: "failed" }, "another app saying gone cannot discard a token whose own app could not be reached");
    assert.deepEqual(tried, apps);
  });
}
