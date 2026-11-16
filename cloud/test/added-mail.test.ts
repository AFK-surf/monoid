// Someone added to a workspace (POST /v1/workspaces/:id/members) is told so by mail (mail.ts `sendAdded`): in it at
// once, or once they first sign in with that email; once a day at most, what could not be sent said to the app.
import assert from "node:assert/strict";
import test from "node:test";
import type { MailMessage } from "../src/mail.ts";
import { harness } from "./harness.ts";

type H = Awaited<ReturnType<typeof harness>>;
type As = ReturnType<H["as"]>;

const create = async (owner: As, name: string) => ((await (await owner("POST", "/v1/workspaces", { name })).json()) as { id: string }).id;
const add = async (owner: As, workspace: string, emails: string[], lang?: string) => {
  const answer = await owner("POST", `/v1/workspaces/${workspace}/members`, { role: "member", emails, ...(lang ? { lang } : {}) });
  assert.equal(answer.status, 200);
  return (await answer.json()) as { joined: string[]; added: string[]; already: string[]; unmailed: string[]; mail?: unknown };
};
const to = (h: H, email: string) => h.mails.filter((m) => m.to === email);
const waiting = async (h: H) => ((await (await h.object("DIRECTORY", "primary")).moveExport()).added_mail_retries as { email: string }[]).map((m) => m.email).sort();

test("each one added is mailed: who added them, to what, and how they get in; one already a member is not", async () => {
  const h = await harness({ mail: true });
  try {
    const alice = h.as(await h.login("alice"));
    await h.login("bob");
    const team = await create(alice, "Team");
    const made = await add(alice, team, ["bob@example.test", "carol@example.test", "alice@example.test"]);
    assert.deepEqual([made.joined, made.added, made.already, made.unmailed], [["bob@example.test"], ["carol@example.test"], ["alice@example.test"], []]);
    assert.equal(made.mail, undefined, "what the Directory handed the API to send stays there");

    const [bob] = to(h, "bob@example.test") as [MailMessage];
    const [carol] = to(h, "carol@example.test") as [MailMessage];
    assert.equal(to(h, "alice@example.test").length, 0);
    assert.equal(h.mails.length, 2);
    assert.match(bob.subject, /alice.*「Team」/);
    assert.match(bob.text, /打开 still\.fail 就能看到/, "in it already: open the app");
    assert.match(carol.text, /用 carol@example\.test 登录 still\.fail，就会自动加入/, "not signed up: sign in with that email");
    assert.match(carol.html, new RegExp(`href="${h.origin.replace(/[.]/g, "\\.")}"`), "a link to this cloud, no token");
    assert.deepEqual(carol.from, { email: "noreply@relay.example", name: "still.fail" });

    // In the language the app asked in.
    await add(alice, team, ["dave@example.test"], "en");
    assert.match(to(h, "dave@example.test")[0]!.subject, /alice invited you to “Team”/);
  } finally {
    await h.close();
  }
});

test("on monoid's cloud the mail says monoid and links there", async () => {
  const h = await harness({ mail: true, origin: "https://app.monoid.build" });
  try {
    const alice = h.as(await h.login("alice"));
    await add(alice, await create(alice, "Team"), ["carol@example.test"]);
    const [carol] = to(h, "carol@example.test") as [MailMessage];
    assert.match(carol.text, /登录 monoid，就会自动加入/);
    assert.doesNotMatch(carol.text + carol.subject + carol.html, /still\.fail/);
    assert.match(carol.html, /href="https:\/\/app\.monoid\.build"/);
    assert.equal((carol.from as { name: string }).name, "monoid");
  } finally {
    await h.close();
  }
});

test("taken out and added again the same day, nobody is mailed twice; a mail that could not go is said and tried again", async () => {
  let refuse = "frank@example.test";
  const h = await harness({ mail: (m) => (m.to === refuse ? "E_RATE_LIMIT_EXCEEDED" : true) });
  try {
    const alice = h.as(await h.login("alice"));
    const team = await create(alice, "Team");
    await add(alice, team, ["carol@example.test"]);
    assert.equal((await alice("DELETE", `/v1/workspaces/${team}/added/carol@example.test`)).status, 200);
    assert.deepEqual((await add(alice, team, ["carol@example.test"])).unmailed, []);
    assert.equal(to(h, "carol@example.test").length, 1, "once a day");
    // Another workspace is another mail.
    await add(alice, await create(alice, "Lab"), ["carol@example.test"]);
    assert.equal(to(h, "carol@example.test").length, 2);

    const first = await add(alice, team, ["frank@example.test"]);
    assert.deepEqual([first.added, first.unmailed], [["frank@example.test"], ["frank@example.test"]], "added all the same, the mail said not sent");
    refuse = "";
    assert.deepEqual((await add(alice, team, ["frank@example.test"])).unmailed, []);
    assert.equal(to(h, "frank@example.test").length, 1, "added again, it is sent");
  } finally {
    await h.close();
  }
});

test("a cloud with no mail adds as before and says nothing unsent", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const made = await add(alice, await create(alice, "Team"), ["carol@example.test"]);
    assert.deepEqual([made.added, made.unmailed], [["carol@example.test"], []]);
    assert.equal(h.mails.length, 0);
  } finally {
    await h.close();
  }
});

test("adding an existing account again resends a notification that failed, without mailing other existing members", async () => {
  let refuse = true;
  const h = await harness({ mail: (m) => m.to === "bob@example.test" && refuse ? "E_RATE_LIMIT_EXCEEDED" : true });
  try {
    const alice = h.as(await h.login("alice"));
    await h.login("bob");
    const team = await create(alice, "Team");
    const first = await add(alice, team, ["bob@example.test"]);
    assert.deepEqual([first.joined, first.unmailed], [["bob@example.test"], ["bob@example.test"]]);
    assert.equal(to(h, "bob@example.test").length, 0);
    refuse = false;
    const again = await add(alice, team, ["bob@example.test", "alice@example.test"]);
    assert.deepEqual([again.already, again.unmailed], [["bob@example.test", "alice@example.test"], []]);
    assert.equal(to(h, "bob@example.test").length, 1, "the failed notification is sent when the member is added again");
    assert.equal(to(h, "alice@example.test").length, 0, "an existing member whose notification did not fail is not mailed");
    await add(alice, team, ["bob@example.test"]);
    assert.equal(to(h, "bob@example.test").length, 1, "a successful retry still counts toward the daily limit");
  } finally {
    await h.close();
  }
});

for (const elapsed of [86400, 86401]) test(`a failed member notification is retried after ${elapsed} seconds and unrelated mail cleanup`, async () => {
  let refuse = true;
  const h = await harness({ mail: (m) => m.to === "bob@example.test" && refuse ? "E_RATE_LIMIT_EXCEEDED" : true });
  try {
    const tokens = await h.login("alice");
    let alice = h.as(tokens);
    await h.login("bob");
    const team = await create(alice, "Team");
    const other = await create(alice, "Other");
    assert.deepEqual((await add(alice, team, ["bob@example.test"])).unmailed, ["bob@example.test"]);
    await add(alice, other, ["carol@example.test"]);
    const dir = await h.object("DIRECTORY", "primary");
    assert.equal(await dir.advanceClock(elapsed), h.now() + elapsed);
    // The same clock also expires the old access token: refresh it through the real endpoint.
    const refreshed = await h.fetch("/v1/auth/refresh", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${tokens.refresh_token}` }, body: JSON.stringify({ request_id: "01J0000000000000000000000A" }) });
    assert.equal(refreshed.status, 200);
    alice = h.as(await refreshed.json() as typeof tokens);
    await add(alice, other, ["dave@example.test"]);
    assert.equal(((await dir.moveExport()).added_mails as { email: string }[]).some((m) => m.email === "carol@example.test"), false, "an unrelated add really expired the old successful mail record");
    refuse = false;
    assert.deepEqual((await add(alice, team, ["bob@example.test"])).unmailed, []);
    assert.equal(to(h, "bob@example.test").length, 1, "a day-old failure is still a real retry, not a silent success");
    await add(alice, team, ["bob@example.test"]);
    assert.equal(to(h, "bob@example.test").length, 1, "the successful retry is not sent twice");
  } finally {
    await h.close();
  }
});

test("a pending recipient who signs in keeps their failed mail; a successful retry uses the normal daily slot", async () => {
  let refuse = true;
  const h = await harness({ mail: () => !refuse });
  try {
    const alice = h.as(await h.login("alice"));
    const team = await create(alice, "Team");
    assert.deepEqual((await add(alice, team, ["bob@example.test"])).added, ["bob@example.test"]);
    const bob = await h.login("bob");
    assert.deepEqual(await waiting(h), ["bob@example.test"], "signing in changes the relation, not whether the notification was sent");
    refuse = false;
    await add(alice, team, ["bob@example.test"]);
    assert.equal(to(h, "bob@example.test").length, 1);
    assert.deepEqual(await waiting(h), [], "success clears the pending failure");
    assert.equal((await alice("DELETE", `/v1/workspaces/${team}/members/${bob.subject}`)).status, 200);
    await add(alice, team, ["bob@example.test"]);
    assert.equal(to(h, "bob@example.test").length, 1, "taking out and adding again cannot bypass the successful retry's limit");
    await (await h.object("DIRECTORY", "primary")).ageAddedMail(team, "bob@example.test", 86400);
    assert.equal((await alice("DELETE", `/v1/workspaces/${team}/members/${bob.subject}`)).status, 200);
    await add(alice, team, ["bob@example.test"]);
    assert.equal(to(h, "bob@example.test").length, 2, "the successful daily slot expires at 24 hours as before");
  } finally {
    await h.close();
  }
});

test("removing a member, an added email or their workspace clears its failed notification", async () => {
  const h = await harness({ mail: () => false });
  try {
    const alice = h.as(await h.login("alice"));
    const bob = await h.login("bob");
    const team = await create(alice, "Team");
    await add(alice, team, ["bob@example.test", "carol@example.test"]);
    assert.deepEqual(await waiting(h), ["bob@example.test", "carol@example.test"]);
    assert.equal((await alice("DELETE", `/v1/workspaces/${team}/members/${bob.subject}`)).status, 200);
    assert.deepEqual(await waiting(h), ["carol@example.test"]);
    assert.equal((await alice("DELETE", `/v1/workspaces/${team}/added/carol@example.test`)).status, 200);
    assert.deepEqual(await waiting(h), []);
    await add(alice, team, ["bob@example.test", "carol@example.test"]);
    assert.deepEqual(await waiting(h), ["bob@example.test", "carol@example.test"]);
    assert.equal((await alice("DELETE", `/v1/workspaces/${team}`)).status, 200);
    assert.deepEqual(await waiting(h), []);
  } finally {
    await h.close();
  }
});

test("deleting an account clears its failed workspace notifications", async () => {
  const h = await harness({ mail: () => false });
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));
    await add(alice, await create(alice, "Team"), ["bob@example.test"]);
    assert.deepEqual(await waiting(h), ["bob@example.test"]);
    assert.equal((await bob("DELETE", "/v1/me")).status, 200);
    assert.deepEqual(await waiting(h), []);
  } finally {
    await h.close();
  }
});

test("a send that fails after its recipient was removed leaves no pending notification", async () => {
  let failSend!: (result: boolean) => void;
  let sending!: () => void;
  const begun = new Promise<void>((resolve) => { sending = resolve; });
  const result = new Promise<boolean>((resolve) => { failSend = resolve; });
  const h = await harness({ mail: () => { sending(); return result; } });
  try {
    const alice = h.as(await h.login("alice"));
    const bob = await h.login("bob");
    const team = await create(alice, "Team");
    const added = add(alice, team, ["bob@example.test"]);
    await begun;
    assert.equal((await alice("DELETE", `/v1/workspaces/${team}/members/${bob.subject}`)).status, 200);
    failSend(false);
    assert.deepEqual((await added).unmailed, ["bob@example.test"]);
    assert.deepEqual(await waiting(h), [], "the delayed failure must not recreate a removed relation's retry");
  } finally {
    failSend(false);
    await h.close();
  }
});

test("an older API can add and report failure, but only an API reporting success claims the pending retries", async () => {
  const h = await harness({ mail: true });
  try {
    const owner = await h.login("alice");
    await h.login("bob");
    const alice = h.as(owner);
    const team = await create(alice, "Team");
    const dir = await h.object("DIRECTORY", "primary");
    const emails = ["bob@example.test", "carol@example.test"];
    const first = await dir.addMembers(owner.subject, team, "member", emails);
    assert.deepEqual(first.mail.to.map((m: { email: string }) => m.email), emails, "the old four-argument call still gets both first notifications");
    await dir.mailFailed(team, emails);
    assert.deepEqual(await waiting(h), emails, "the old two-argument failure report remains accepted");
    const oldRetry = await dir.addMembers(owner.subject, team, "member", [...emails, "dave@example.test"]);
    assert.deepEqual(oldRetry.already, ["bob@example.test"]);
    assert.deepEqual(oldRetry.added, ["carol@example.test", "dave@example.test"]);
    assert.deepEqual(oldRetry.mail.to.map((m: { email: string }) => m.email), ["dave@example.test"], "neither a member retry nor a pending-email retry goes to an API that cannot clear it on success");
    await add(alice, team, emails);
    assert.deepEqual(h.mails.map((m) => m.to), emails, "the new API's optional argument lets it send both retries");
    assert.deepEqual(await waiting(h), [], "the new API's optional successes clear both retries");
  } finally {
    await h.close();
  }
});

test("changing a member's email clears the failed notification to their previous address", async () => {
  const h = await harness({ mail: () => false });
  try {
    const alice = h.as(await h.login("alice"));
    const bob = await h.login("bob");
    await add(alice, await create(alice, "Team"), ["bob@example.test"]);
    assert.deepEqual(await waiting(h), ["bob@example.test"]);
    await (await h.object("DIRECTORY", "primary")).upsertUser({ sub: bob.subject, email: "new-bob@example.test", name: bob.name, picture: "" });
    assert.deepEqual(await waiting(h), [], "the old address no longer belongs to a member or pending recipient");
  } finally {
    await h.close();
  }
});

