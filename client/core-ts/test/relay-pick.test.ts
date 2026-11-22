// What a chat's relay picker shows (src/relay-pick.ts, `chat.relayView`): every bot's places once each and in what
// order, a Slack message's link typed instead, and who replies in the place picked.
import assert from "node:assert/strict";
import { test } from "node:test";
import { MENTIONS, arrange, mentionQuery, mentionView, readConnects, readPeople, relayBot, relayVia, relayView, slackLink, type RelayConnect, type RelayPlace } from "../src/relay-pick.ts";
import { parseCall } from "../src/core/calls.ts";
import { tr } from "../src/i18n.ts";
import { answers, call, cloudCore } from "./helpers.ts";

// deno-lint-ignore no-explicit-any
type J = any;

const zh = (k: string, a?: Record<string, string | number>) => tr("zh", k, a);
const channel = (name: string, used?: number): RelayPlace => (used === undefined ? { id: name, name, kind: "channel" } : { id: name, name, kind: "channel", used });
const bot = (id: string, places: RelayPlace[], more: Partial<RelayConnect> = {}): RelayConnect => ({ id, kind: "slack", name: id, team: "AFK", places, ...more });

test("the_bot_gone_on_through_is_the_one_picked_else_the_chats_own_else_the_first", () => {
  const cs = [bot("a", []), bot("b", [], { preferred: true })];
  assert.equal(relayBot(cs, null)?.id, "b");
  assert.equal(relayBot(cs, "a")?.id, "a");
  assert.equal(relayBot([bot("a", []), bot("c", [])], null)?.id, "a");
  assert.equal(relayBot([], null), null);
});

test("places_relayed_to_before_come_first_then_by_name_and_of_many_only_the_recent_ones", () => {
  const few = [channel("ops"), channel("dev", 5), channel("art")];
  assert.deepEqual(arrange([bot("a", few)], "", false).rows.map((r) => r.place.name), ["dev", "art", "ops"]);
  const many = [...Array(9).keys()].map((i) => channel(`c${i}`, i < 6 ? i : undefined));
  const shown = arrange([bot("a", many)], "", false);
  assert.equal(shown.recent, true);
  assert.equal(shown.total, 9);
  assert.deepEqual(shown.rows.map((r) => r.place.name), ["c5", "c4", "c3", "c2", "c1"]);
  assert.equal(arrange([bot("a", many)], "", true).rows.length, 9, "all asked for");
  // Typed: those starting with it first, out of all of them.
  assert.deepEqual(arrange([bot("a", [channel("release"), channel("pre-release", 3), channel("ops")])], "rel", false).rows.map((r) => r.place.name), ["release", "pre-release"]);
});

test("a_slack_messages_link_typed_is_its_thread", () => {
  const link = "https://afk.slack.com/archives/C0123ABC/p1792828521435000";
  assert.equal(slackLink(` ${link} `), link);
  assert.equal(slackLink("https://afk.slack.com/archives/C0123ABC"), null);
  assert.equal(slackLink("release"), null);
});

test("the_view_lists_every_bots_places_once_each_the_workspace_at_its_end_among_several", () => {
  const cs = [
    bot("a", [channel("dev"), { id: "g", name: "设计组", kind: "group" }, { id: "p", name: "core", kind: "channel", private: true }]),
    bot("b", [channel("dev", 7)], { preferred: true }),
    bot("c", [], { team: "Cue", error: "token revoked" }),
  ];
  const v = relayView(cs, "", false, null, zh);
  assert.deepEqual(v.bots, [], "the bot is a step after the place");
  // #dev once, though two bots are in it, relayed to before by b: first; its replier the chat's own (b)
  assert.deepEqual(v.rows.map((r) => [r.name, r.connect, r.aside]), [["#dev", "b", "AFK"], ["🔒 #core", "a", "AFK"], ["设计组", "a", zh("web-main.relay.kind.group")]]);
  assert.equal(v.rows[0]!.note, zh("web-main.relay.kind.channel"), "what relaying there does, said once it is picked");
  assert.deepEqual([v.empty, v.unread], [null, ["token revoked"]]);
  assert.equal(relayView(cs, "zzz", false, null, zh).empty, "noMatch");
  assert.equal(relayView([bot("a", [])], "", false, null, zh).empty, "noPlaces");
  assert.equal(relayView([bot("a", [channel("dev")])], "", false, null, zh).rows[0]!.aside, null, "one workspace: none said");
});

test("public_channels_no_bot_is_in_are_offered_where_a_bot_may_join_them_after_the_rest", () => {
  const cs = [bot("a", [channel("dev")]), bot("b", [], { joins: true, open: [channel("general"), channel("dev")] })];
  const v = relayView(cs, "", false, null, zh);
  assert.deepEqual(v.rows.map((r) => [r.name, r.connect, r.aside]), [["#dev", "a", null], ["#general", "b", zh("web-main.relay.unjoined")]]);
  assert.deepEqual(relayView([bot("a", [channel("dev")]), bot("b", [], { open: [channel("general")] })], "", false, null, zh).rows.length, 1, "none may join: not offered");
});

test("who_replies_in_the_place_picked_and_where_each_bot_of_its_workspace_stands_there", () => {
  const priv: RelayPlace = { id: "p", name: "core", kind: "channel", private: true };
  const cs = [
    bot("a", [channel("dev"), priv]),
    bot("b", [], { joins: true, open: [channel("dev")], preferred: true }),
    bot("c", []),
    bot("d", [channel("dev")], { team: "Cue" }),
  ];
  const dev = relayView(cs, "", false, null, zh).rows.find((r) => r.name === "#dev" && r.connect !== "d")!.key;
  // The chat's own (b) is not in it: one that is replies, unless b is picked, which joins it as it relays
  assert.deepEqual(relayVia(cs, dev, null), {
    bot: "a",
    joins: false,
    bots: [
      { id: "a", label: "a", state: "in" },
      { id: "b", label: "b", state: "join" },
      { id: "c", label: "c", state: "out" },
    ],
  });
  assert.deepEqual([relayVia(cs, dev, "b")!.bot, relayVia(cs, dev, "b")!.joins], ["b", true]);
  assert.equal(relayVia(cs, dev, "c")!.bot, "a", "one that cannot reply there is not taken");
  // A private channel: only a person there can invite a bot
  const core = relayView(cs, "", false, null, zh).rows.find((r) => r.name === "🔒 #core")!.key;
  assert.deepEqual(relayVia(cs, core, null)!.bots.map((x) => [x.id, x.state, x.invite ?? null]), [["a", "in", null], ["b", "invite", "/invite @b"], ["c", "invite", "/invite @c"]]);
  // Asked with the place picked, the view says it
  assert.equal(relayView(cs, "", false, "b", zh, dev).via?.bot, "b");
  assert.equal(relayVia(cs, "nowhere", null), null);
});

test("a_group_connects_spaces_are_offered_each_a_new_topic_its_bot_in_them_or_not", () => {
  const space = (id: string, name: string, used?: number): RelayPlace => ({ id, name, kind: "space", ...(used === undefined ? {} : { used }) });
  const cs = [
    bot("s", [channel("dev")]),
    bot("g1", [space("s_a", "Team", 3), space("s_b", "设计")], { kind: "group", team: null, teamId: "anchor-1" }),
    bot("g2", [space("s_a", "Team")], { kind: "group", team: null, teamId: "anchor-1", preferred: true }),
  ];
  const v = relayView(cs, "", false, null, zh);
  // Team once though both bots of that anchor are in it, relayed to before: first; its replier the chat's own (g2)
  assert.deepEqual(v.rows.map((r) => [r.name, r.connect, r.kind, r.note, r.aside]), [
    ["Team", "g2", "group", zh("web-main.relay.kind.space"), zh("web-main.relay.kind.space")],
    ["#dev", "s", "slack", zh("web-main.relay.kind.channel"), "AFK"],
    ["设计", "g1", "group", zh("web-main.relay.kind.space"), zh("web-main.relay.kind.space")],
  ]);
  assert.equal(tr("en", "web-main.relay.kind.space"), "Group space · new topic");
  // Who replies there: the bots of that anchor alone, in it or not (none joins a space, none is invited)
  const design = v.rows.find((r) => r.name === "设计")!.key;
  assert.deepEqual(relayVia(cs, design, "g2"), { bot: "g1", joins: false, bots: [{ id: "g1", label: "g1", state: "in" }, { id: "g2", label: "g2", state: "out" }] });
  // As the station answers it, given back by a client: its kind and its spaces kept
  const read = readConnects([{ id: "g", kind: "group", name: "Claude", team: null, teamId: "anchor-1", places: [{ id: "s_a", name: "Team", kind: "space", used: 5 }, { id: "x", name: "?", kind: "nope" }] }]);
  assert.deepEqual(read, [{ id: "g", kind: "group", name: "Claude", team: null, teamId: "anchor-1", places: [{ id: "s_a", name: "Team", kind: "space", used: 5 }, { id: "x", name: "?", kind: "channel" }] }]);
});

test("a_client_asks_the_core_what_the_picker_shows", async () => {
  const connects = [bot("a", [channel("dev")])];
  assert.deepEqual(parseCall("chat.relayView", { connects, query: "d" }), { kind: "relayView", connects: readConnects(connects), query: "d", all: false, bot: null, place: null });
  const { host, core } = await cloudCore();
  const ui = core.connect();
  call(core, ui, 1, "chat.relayView", { connects, query: "", all: false });
  await host.settle();
  const v = (answers(host.takeEmitted(), 1) as J).ok;
  assert.deepEqual(v.rows.map((r: J) => r.name), ["#dev"]);
  assert.equal(v.bot, "a");
});

test("an_at_in_the_note_offers_the_people_there_and_picking_one_writes_their_name", () => {
  const people = [{ id: "U1", name: "pengxiao", aka: "Peng Xiao" }, { id: "U2", name: "ann" }, { id: "U3", name: "张三" }, { id: "U4", name: "xiaoming" }];
  assert.deepEqual(mentionQuery("hi @pe"), { at: 3, query: "pe" });
  assert.equal(mentionQuery("mail a@b"), null, "an @ in a word is not one");
  assert.equal(mentionQuery("@ann\nlook"), null, "nor one on a line before");
  assert.equal(mentionView(people, "look").query, null);
  // Their name or other name has it, those starting with it first, then by name.
  assert.deepEqual(mentionView(people, "@xiao").rows.map((p) => p.id), ["U4", "U1"]);
  assert.deepEqual(mentionView(people, "@Peng X").rows.map((p) => p.id), ["U1"]);
  assert.deepEqual(mentionView(people, "@").rows.map((p) => p.id), ["U2", "U1", "U4", "U3"]);
  assert.equal(mentionView(Array.from({ length: 9 }, (_, i) => ({ id: `U${i}`, name: `p${i}` })), "@p").rows.length, MENTIONS);
  // Picked: the note with their name in place of what was typed, and nothing is offered for it any more.
  const picked = mentionView(people, "请 @张").rows[0]!;
  assert.equal(picked.note, "请 @张三 ");
  assert.deepEqual(mentionView(people, picked.note).rows, []);
  assert.deepEqual(readPeople([{ id: "U1", name: "a", aka: "", picture: "p" }, { id: "", name: "b" }, "x"]), [{ id: "U1", name: "a", picture: "p" }]);
});

test("a_client_asks_the_core_whom_the_note_can_mention", async () => {
  const people = [{ id: "U1", name: "ann" }];
  assert.deepEqual(parseCall("chat.relayMentions", { people, note: "@a" }), { kind: "relayMentions", people, note: "@a" });
  const { host, core } = await cloudCore();
  const ui = core.connect();
  call(core, ui, 1, "chat.relayMentions", { people, note: "hi @a" });
  await host.settle();
  assert.deepEqual((answers(host.takeEmitted(), 1) as J).ok, { query: "a", at: 3, rows: [{ id: "U1", name: "ann", note: "hi @ann " }] });
});
