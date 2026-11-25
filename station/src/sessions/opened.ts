import { modelSpeed } from "../../../client/core-ts/src/model-speed.ts";
// Chats an agent opens for another (chat_create): a new session in a still.fail chat of its own, on this station or on
// another of the workspace (`session.create` there, its files and first message after it as session_send sends them).
// The chat begins with the opener's message, headed as its opening; its starter is the person who started the opener's
// chat. It is opened one of two ways (`for`, the user 2026-11-15: an agent leading others had become a blind merger of
// their reports): for that person (`person`), theirs from then on, what it asks theirs and its opener told nothing; or
// led by its opener (`me`), each time a turn of it ends all_done or need_human (or fails, or is stopped) the opener told
// (`settled`, `session.notice` from another station) with what a leader does with it, and what it asks its opener's
// to take up, in no person's 待处理 (the core's decisions.forViewer, `opener.led`) and pushed to nobody (cloud/notify.ts). Nothing is sent again by itself: a call whose answer
// was uncertain is the agent's to repeat with the same key, which gives the chat made then rather than another.
import { log } from "../ops/log.ts";
import { tr, stationLang } from "../ops/i18n.ts";
import { threadAddress } from "../agents/instructions.ts";
import type { SessionThread } from "../store/store.ts";
import { type Args, jsString } from "./args.ts";
import { attach } from "./conversations.ts";
import type { Hub } from "./hub.ts";
import { INTERNAL_CONNECT } from "./internal.ts";
import { type NewChat, newSession } from "./lifecycle.ts";
import { chatNamed, postFrom, sender } from "./messages.ts";
import { Refused } from "../jobs/remote.ts";
import { fromBefore, linkedStation, peersOf, sessionThreadOf } from "./others.ts";
import { sendable, sendAlong } from "./peer-files.ts";
import { RUNTIME_KINDS, type RuntimeKind } from "../agents/runtime.ts";
import { USED_WITHIN_MS, askWhich, candidates, choose } from "./model-choice.ts";
import { sameModel } from "./config.ts";
import { contextAsked } from "./context-cap.ts";
import { type Preset, type PresetCopy, type PresetModel, type Presets, presetCopyInput } from "./presets.ts";
import { STATION_AUTHOR } from "../store/rows.ts";
import { markNotice } from "./chat.ts";

type Json = any;

/// The method another station's agent opens a chat here by.
export const CREATE = "session.create";
/// The same with a preset (its copy in `presetCopy`): a method of its own, so a station from before refuses it rather
/// than opening the chat without the preset.
export const CREATE_PRESET = "session.create.preset";
/// Explicit speed must not be silently discarded by a station from before the three speed choices.
export const CREATE_SPEED = "session.create.speed";
export const CREATE_PRESET_TUI = "session.create.preset.tui";
export const CREATE_PRESET_SPEED = "session.create.preset.speed";
/// The method a station tells the opener of a chat how one of its turns ended.
export const NOTICE = "session.notice";

/// At most this much text in the first message (as session_send's).
const MAX_TEXT = 200_000;

const chars = (s: string) => Array.from(s).length;
const RUNTIMES = RUNTIME_KINDS;
type RuntimeName = RuntimeKind;

/// How a turn of an opened chat ended, as its opener is told.
export type Settled = "all_done" | "need_human" | "failed" | "stopped";

type Made = { session: string; link: string | null; thread: string };

/// chat_create `for`: whether the opener leads the chat (`me`) or opens it for its person (`person`).
function ledOf(args: Json): boolean {
  const f = given(args, "for");
  if (f === "me") return true;
  if (f === "person") return false;
  throw new Error(`for is required, "me" or "person": "me" for a chat you lead (a part of your work: it reports to you, what it asks is yours to decide or take to your person, and you check what it says before you tell anyone: skill stillfail-leading), "person" for a chat opened for your person (theirs from then on: you are told nothing of it)`);
}

/// A string argument, trimmed; null when left out or empty.
function given(args: Json, name: string): string | null {
  const v = args?.[name];
  if (v === undefined || v === null) return null;
  const t = jsString(v).trim();
  return t === "" ? null : t;
}

/// The key a chat is opened with: the caller's, checked.
function keyOf(args: Json): string {
  const key = given(args, "key");
  if (key === null) throw new Error("key is required: a name of your choosing for this chat (e.g. build-android); calling again with it gives the chat made then rather than another");
  if (chars(key) > 120) throw new Error("key is too long (at most 120 characters)");
  return key;
}

/// The key a chat is opened with, null where it is not one (refused as it is made, `keyOf`).
function keyOr(args: Json): string | null {
  try {
    return keyOf(args);
  } catch {
    return null;
  }
}

/// The person who started session `key`'s chat (whom a chat it opens goes to).
function starterOf(hub: Hub, key: string): string {
  let thread = null;
  try {
    thread = sessionThreadOf(hub, key).thread;
  } catch {}
  return thread?.createdBy ?? hub.store.getSession(key)?.createdBy ?? "local";
}

/// A new session in a chat of its own for an opener: its runtime, model and effort as asked; the model and effort it
/// takes after its opener's (`inherited`) are dropped where no profile here runs them. Told no effort, it runs the one
/// its starter `createdBy` uses most here with that runtime and model, dropped too where it is not run (the model's
/// own default otherwise: Codex's for gpt-6.1-terra is low, where its people run max), unless a preset's model
/// configuration is what it runs (`bound`: as the app opens one, the model's own default where the preset names none).
/// In workspace `ws` (the opener's). `more`: what else it is opened with, as the app would (its preset, Fast, context).
async function makeChat(
  hub: Hub,
  o: { runtime: RuntimeName; model: string | null; effort: string | null; inherited: boolean; title: string | null; createdBy: string; ws: string | null; bound?: boolean },
  more: Partial<Pick<NewChat, "preset" | "presetCopy" | "fast" | "speed" | "tui" | "context" | "profile" | "profiles">> = {},
) {
  const usual = o.effort === null && o.bound !== true ? usualEffort(hub, o.createdBy, o.runtime, o.model) : null;
  const options: NewChat = { ...more, runtime: o.runtime, model: o.model, effort: o.effort ?? usual, title: o.title, createdBy: o.createdBy, ws: o.ws };
  try {
    return await newSession(hub, options);
  } catch (error) {
    if (usual !== null) {
      try {
        return await newSession(hub, { ...options, effort: null });
      } catch {}
    }
    if (!o.inherited || (o.model === null && o.effort === null)) throw error;
    return await newSession(hub, { ...options, model: null, effort: null });
  }
}

/// The preset an agent names (chat_create `preset`): one this station keeps in workspace `ws` (whoever's, wherever it
/// was made: sessions/presets.ts), by its id or its name.
async function presetNamed(hub: Hub, ws: string | null, named: string): Promise<Preset> {
  const all = await hub.presets.list(ws ?? hub.workspaces()[0] ?? null);
  const lower = named.toLowerCase();
  const found = all.find((p) => p.id === named) ?? all.find((p) => p.name.toLowerCase() === lower);
  if (found) return found;
  if (all.length === 0) throw new Error(`no preset ${named}: this station has none (people make them in the app). Leave preset out to open the chat with none`);
  throw new Error(`no preset ${named} on this station; its presets: ${all.map((p) => p.name).join(", ")}`);
}

/// The stations (ids) preset `p` opens its chats on; none: any.
const presetStations = (p: { station?: string; stations?: string[] }): string[] =>
  (p.station !== undefined ? [p.station] : (p.stations ?? [])).map((s) => s.slice(s.lastIndexOf("/") + 1));

/// What a chat opened with a preset naming its model configuration `pm` runs, all of it the preset's as the app opens
/// it (core choose.ts `boundChoice`): its runtime, where the preset names none the first of workspace `ws` here that
/// runs the model.
function boundHere(hub: Hub, ws: string | null, pm: PresetModel, name: string) {
  const runtime = pm.runtime ?? candidates(hub.profilesIn(ws), null).find((c) => c.model !== null && sameModel(c.model, pm.model))?.runtime;
  if (runtime === undefined || !RUNTIMES.includes(runtime as RuntimeName)) throw new Error(`the preset ${name} runs ${pm.model}, which no account on the station it is opened on runs`);
  return {
    choice: { runtime: runtime as RuntimeName, model: pm.model, effort: pm.effort ?? null, bound: true },
    more: { ...(pm.tui ? { tui: true } : {}), ...(pm.speed ? { speed: pm.speed } : {}), fast: pm.fast ?? null, context: pm.context ?? null, profile: pm.profile ?? null, profiles: pm.profiles ?? null },
  };
}

/// Preset `p` of this station as a chat on another station is opened with (as the app gives one, core choose.ts):
/// each folder said to be where it is (`here`: this station, by its id) unless that is the chat's station `there`, and
/// what it binds the chat to with it. A folder naming this station is this station's (`presets.isHere`); another's is
/// told by its name as this station knows it.
function copyFor(presets: Presets, p: Preset, here: string, there: string): PresetCopy {
  const dirs = p.dirs.map(({ station, stationName, guides: _g, skills: _k, ...d }) => {
    if (station === undefined || presets.isHere(station)) return { ...d, elsewhere: here };
    return station.slice(station.lastIndexOf("/") + 1) === there ? d : { ...d, elsewhere: presets.nameOf(station, stationName) };
  });
  const stations = p.station !== undefined ? [p.station] : p.stations;
  return { id: p.id, name: p.name, dirs, instructions: p.instructions, ...(p.model ? { model: p.model } : {}), ...(stations && stations.length > 0 ? { stations } : {}) };
}

/// The effort `createdBy` started most of their chats here on (runtime, model) with lately (the latest of those used
/// as often), null when they named none.
function usualEffort(hub: Hub, createdBy: string, runtime: RuntimeName, model: string | null): string | null {
  return hub.store.effortsUsedBy(createdBy, runtime, model, hub.now() - USED_WITHIN_MS)[0]?.effort ?? null;
}

/// What a chat opened here runs when its opener named no model (model-choice.ts): what its starter `createdBy` uses
/// most here, of the models the profiles of workspace `ws` run (of `runtime` when given). Throws, naming them, when
/// that is not one model: the opener's agent asks the person.
function chosenHere(hub: Hub, createdBy: string, ws: string | null, runtime: RuntimeName | null): { runtime: RuntimeName; model: string | null } {
  const cands = candidates(hub.profilesIn(ws), runtime);
  if (cands.length === 0) throw new Error(runtime !== null ? `no ${runtime} profile on the station it is opened on` : "no profile on the station it is opened on");
  const c = choose(cands, hub.store.modelsUsedBy(createdBy, hub.now() - USED_WITHIN_MS), candidates(hub.profilesIn(ws), runtime, true));
  if ("ask" in c) throw new Error(askWhich(c.ask, "the station it is opened on"));
  return { runtime: c.pick.runtime as RuntimeName, model: c.pick.model };
}

/// Where a session's chat is, as an agent names it.
const addressOf = (thread: SessionThread) => threadAddress(thread.thread.channel, thread.thread.threadTs);

/// The station a chat is to be opened on, by its id or name in the roster of session `key`'s workspace; null for this
/// one.
async function stationNamed(hub: Hub, key: string, named: string | null): Promise<string | null> {
  if (named === null) return null;
  const link = hub.link(key);
  const here = link !== undefined ? linkedStation(link) : null;
  if (named === here) return null;
  const call = peersOf(hub, key);
  if (!call) throw new Error("other stations cannot be reached from this one yet: leave station out to open the chat here");
  const roster: Json = await call("", { method: "peers" });
  const stations: Json[] = Array.isArray(roster?.stations) ? roster.stations : [];
  const lower = named.toLowerCase();
  const found = stations.find((s) => s?.id === named) ?? stations.find((s) => typeof s?.name === "string" && s.name.toLowerCase() === lower);
  if (!found || typeof found.id !== "string") {
    const names = stations.map((s) => (typeof s?.name === "string" && s.name !== "" ? s.name : s?.id)).filter((n) => typeof n === "string");
    throw new Error(`no station ${named} in this workspace${names.length > 0 ? `; its stations: ${names.join(", ")}` : ""}`);
  }
  return found.id === here ? null : found.id;
}

/// What the agent is told of a chat it opened.
function opened(made: Made, station: string | null, again: boolean, led: boolean): string {
  const where = station === null ? "this station" : `station ${station}`;
  const first = again ? `This key already opened ${made.link ?? made.session} (${made.thread} on ${where}); nothing new was opened or sent.` : `Opened ${made.link ?? made.session} (${made.thread} on ${where}); its agent is ${made.session}.`;
  if (!led) return `${first} It is your person's chat now: they work with it there, what it asks goes to them and you are told nothing of it. Say where it is in your chat and do not take up or pass on its work.`;
  return `${first} You lead it: put it in your goal ledger (the direction it is of, what counts as done, the evidence it is to bring: skill stillfail-leading). Each time a turn there ends all_done or need_human (or fails), you are told here: wait for it by ending your turn waiting. What it asks is yours to decide, or to take to your person yourself. Write to its agent with session_send to its link; read it with chat_read.`;
}

/// Says in the opener's chat, for people, that it opened a chat (the station's words, like its notices).
async function sayOpened(hub: Hub, key: string, title: string, link: string | null, led: boolean) {
  const latest = hub.store.latestThread(key);
  if (!latest) return;
  const text = tr(stationLang(), led ? "station.session.opened" : "station.session.openedForPerson", { chat: chatNamed(latest.thread.surface, title, link) });
  try {
    const ts = await hub.chat(latest.connect).post({ channel: latest.thread.channel, threadTs: latest.thread.threadTs }, markNotice(text), []);
    hub.store.insertMessage({ thread: latest.thread.id, ts, authorKind: STATION_AUTHOR, author: STATION_AUTHOR, text, attachments: [] });
  } catch (error) {
    log.warn("hub", "an opened chat was not said in its opener's", { session: key, error: (error as Error).message });
  }
}

/// The retry check needs only author metadata, not each message's edited text.
async function openerSaid(hub: Hub, thread: number, author: string, agentOnly: boolean): Promise<boolean> {
  if (hub.openedChatSaid) return hub.openedChatSaid(thread, author, agentOnly);
  return hub.store.messagesBefore(thread, null, 200).some((m) => m.author === author && (!agentOnly || m.authorKind === "agent"));
}

// A retry may arrive while another call is still checking or sending the first message. Keep that whole operation in
// order for the chat, and let a later call retry after an earlier failure.
const firstMessageGates = new WeakMap<Hub, Map<number, { tail: Promise<void>; waiting: number }>>();
async function firstMessageInTurn(hub: Hub, thread: number, send: () => Promise<void>): Promise<void> {
  let gates = firstMessageGates.get(hub);
  if (!gates) firstMessageGates.set(hub, (gates = new Map()));
  let gate = gates.get(thread);
  if (!gate) gates.set(thread, (gate = { tail: Promise.resolve(), waiting: 0 }));
  gate.waiting++;
  const turn = gate.tail.then(send);
  gate.tail = turn.then(() => {}, () => {});
  try { await turn; }
  finally {
    if (--gate.waiting === 0 && gates.get(thread) === gate) gates.delete(thread);
    if (gates.size === 0) firstMessageGates.delete(hub);
  }
}

/// The chats being opened by their keys, of each hub: one asked again while it is made (a retry) waits for it, then
/// finds it made (`openedWith`), as it did while making one waited on nothing.
const opening = new WeakMap<Hub, Map<string, Promise<unknown>>>();
function oneByKey<T>(hub: Hub, id: string, f: () => Promise<T>): Promise<T> {
  let mine = opening.get(hub);
  if (mine === undefined) opening.set(hub, (mine = new Map()));
  const run = (mine.get(id) ?? Promise.resolve()).then(f, f);
  const done = run.then(() => {}, () => {});
  mine.set(id, done);
  void done.then(() => {
    if (mine.get(id) === done) mine.delete(id);
  });
  return run;
}

/// chat_create from session `key`.
export async function chatCreate(hub: Hub, key: string, args: Args): Promise<string> {
  const k = keyOr(args);
  return k === null ? chatCreateNow(hub, key, args) : oneByKey(hub, JSON.stringify(["", key, k]), () => chatCreateNow(hub, key, args));
}

async function chatCreateNow(hub: Hub, key: string, args: Args): Promise<string> {
  const row = hub.store.getSession(key);
  if (!row) throw new Error("unknown session");
  // (one opened for its person is theirs, and opens chats as theirs do)
  const openedBy = hub.store.openerOf(key);
  if (openedBy !== null && openedBy.led !== false) throw new Error("this chat was opened by another agent, and opens none itself: ask its opener (session_send) or a person to open more");
  const k = keyOf(args);
  const led = ledOf(args);
  const text = given(args, "text");
  if (text === null) throw new Error("text is required: the first message, what the new chat's agent is to do, standing on its own");
  if (chars(text) > MAX_TEXT) throw new Error(`text is too long (at most ${MAX_TEXT} characters): put the rest in a file and attach it`);
  const runtime = given(args, "runtime");
  if (runtime !== null && !RUNTIMES.includes(runtime as RuntimeName)) throw new Error(`runtime must be one of ${RUNTIMES.join(", ")}`);
  const model = given(args, "model");
  const effort = given(args, "effort");
  if (args.fast !== undefined && args.fast !== null && typeof args.fast !== "boolean") throw new Error("fast must be true or false");
  const fast = typeof args.fast === "boolean" ? args.fast : null;
  const speed = modelSpeed(args.speed);
  if (args.speed != null && speed === null) throw new Error("speed must be standard, fast or ultrafast");
  const context = contextAsked(args.context ?? undefined, stationLang()) ?? null;
  // A preset is taken as it is, as a person opening a chat with it in the app takes it (the user, 2026-11-14: 「有预设
  // 就只能直接用预设，或者设置用户也能手动指定的部分，没有特权」): where it names its model configuration nothing of it is
  // given beside it; where it names stations, the chat opens on one of them (the one, where it names one).
  const presetName = given(args, "preset");
  const preset = presetName === null ? null : await presetNamed(hub, row.ws ?? null, presetName);
  if (preset?.model && (runtime !== null || model !== null || effort !== null || fast !== null || speed !== null || context !== null)) {
    throw new Error(`the preset ${preset.name} runs ${preset.model.model} as it says (its runtime, effort, Fast and context too): leave runtime, model, effort, fast, speed and context out, or leave preset out to choose them yourself`);
  }
  const bindsTo = preset === null ? [] : presetStations(preset);
  // Without a model of its own it runs what its starter uses most where it is opened (chosen there), never its
  // opener's: the opener's model may be one that station has no profile for.
  const choice = { runtime: (runtime ?? row.runtime) as RuntimeName, model, effort, inherited: false };
  const title = given(args, "title");
  if (title !== null && chars(title) > 120) throw new Error("title is too long (at most 120 characters)");
  const paths: string[] = Array.isArray(args.files) ? args.files.map(jsString) : [];
  const files = await sendable(hub, key, paths);
  const there = await stationNamed(hub, key, given(args, "station") ?? (bindsTo.length === 1 ? bindsTo[0]! : null));
  const target = there ?? hub.station();
  if (preset !== null && bindsTo.length > 0 && target !== null && !bindsTo.includes(target)) {
    throw new Error(`the preset ${preset.name} opens its chats only on station${bindsTo.length > 1 ? "s" : ""} ${bindsTo.join(", ")}: name one of them as station`);
  }

  const createdBy = starterOf(hub, key);
  const [from, fromLink] = sender(hub, key);
  // Its first message here, with its files, unless it has come already.
  const sendHere = (child: string, thread: SessionThread) => firstMessageInTurn(hub, thread.thread.id, async () => {
    if (await openerSaid(hub, thread.thread.id, key, true)) return;
    const kept = files.length > 0 ? await attach(hub, key, files.map((f) => f.path), child) : [];
    await postFrom(hub, thread, key, from, fromLink, text, [child], kept, true);
  });

  const before = hub.store.openedWith("", key, k, there ?? "");
  if (before !== null) {
    let thread = before.child;
    if (there === null && hub.store.getSession(before.child) !== null) {
      const chat = sessionThreadOf(hub, before.child);
      await sendHere(before.child, chat);
      thread = addressOf(chat);
    }
    return opened({ session: before.child, link: before.link, thread }, there, true, before.led !== false);
  }
  if (there === null) {
    const bound = preset?.model ? boundHere(hub, row.ws ?? null, preset.model, preset.name) : null;
    const chosen = bound !== null ? bound.choice : model === null ? chosenHere(hub, createdBy, row.ws ?? null, runtime as RuntimeName | null) : choice;
    const more = { ...(preset !== null ? { preset: preset.id } : {}), fast, ...(speed ? { speed } : {}), context, ...bound?.more };
    const [child, chat] = await makeChat(hub, { ...choice, ...chosen, title, createdBy, ws: row.ws ?? null }, more);
    if (preset === null) {
      let parentThread = hub.store.latestDeliveredThread(key);
      if (parentThread === null) {
        try {
          parentThread = sessionThreadOf(hub, key).thread;
        } catch {
          parentThread = hub.store.latestThread(key)?.thread ?? null;
        }
      }
      const parentProject = parentThread?.project;
      if (parentProject !== undefined) {
        hub.store.setThreadClassification(chat.id, { project: parentProject, force: true });
      }
    }
    const link = hub.link(child) ?? null;
    hub.store.insertOpened({ childStation: "", child, parentStation: "", parent: key, key: k, title, link, openerTitle: from, led });
    const thread: SessionThread = { thread: chat, connect: INTERNAL_CONNECT };
    await sendHere(child, thread);
    await sayOpened(hub, key, title ?? text.split("\n")[0]!.slice(0, 60), link, led);
    return opened({ session: child, link, thread: addressOf(thread) }, null, false, led);
  }

  const call = peersOf(hub, key)!;
  // `choose`: the station it is opened on picks the model (`runtimeGiven`: of that runtime); one from before it runs the
  // runtime's default there.
  // With a preset, its copy (`presetCopy`), whose model configuration, where it names one, the station there runs.
  let parentProject: string | undefined;
  if (preset === null) {
    let parentThread = hub.store.latestDeliveredThread(key);
    if (parentThread === null) {
      try {
        parentThread = sessionThreadOf(hub, key).thread;
      } catch {
        parentThread = hub.store.latestThread(key)?.thread ?? null;
      }
    }
    parentProject = parentThread?.project;
  }
  const request: Json = {
    method: preset?.model?.tui ? CREATE_PRESET_TUI : preset !== null ? (speed !== null || preset.model?.speed ? CREATE_PRESET_SPEED : CREATE_PRESET) : speed !== null ? CREATE_SPEED : CREATE,
    session: key, key: k, title, ...choice, choose: model === null, runtimeGiven: runtime !== null, createdBy, from: { title: from, link: fromLink }, led,
    ...(fast !== null ? { fast } : {}),
    ...(speed !== null ? { speed } : {}),
    ...(context !== null ? { context } : {}),
    ...(parentProject !== undefined ? { project: parentProject } : {}),
    ...(preset !== null ? { presetCopy: copyFor(hub.presets, preset, hub.station() ?? "", there) } : {}),
  };
  let made: Json;
  try {
    made = await call(there, request);
  } catch (error) {
    const why = (error as Error).message;
    if (error instanceof Refused && fromBefore(why)) throw new Error(`station ${there} is not updated yet: chats cannot be opened there${preset !== null ? " with a preset" : ""}${speed !== null || preset?.model?.speed ? " at the requested speed" : ""}`);
    throw new Error(`not opened on station ${there}: ${why}. If it timed out it may have been opened: call chat_create again with the same key, which gives that chat rather than another`);
  }
  const child = typeof made?.session === "string" ? made.session : "";
  if (child === "") throw new Error(`station ${there} answered without the chat it opened`);
  const link = typeof made?.link === "string" ? made.link : null;
  const result: Made = { session: child, link, thread: typeof made?.thread === "string" ? made.thread : child };
  // Its first message, unless it already came (an earlier call with this key opened the chat and sent it).
  if (made?.said !== true) {
    try {
      const message: Json = { method: "session.message", session: key, to: child, text, from: { title: from, link: fromLink }, opened: true };
      if (files.length > 0) message.files = await sendAlong(call, there, key, child, files);
      await call(there, message);
    } catch (error) {
      throw new Error(`opened ${link ?? child} on station ${there}, but its first message was not sent: ${(error as Error).message}. Call chat_create again with the same key: it sends it once, if it has not arrived`);
    }
  }
  hub.store.insertOpened({ childStation: there, child, parentStation: "", parent: key, key: k, title, link, led });
  await sayOpened(hub, key, title ?? text.split("\n")[0]!.slice(0, 60), link, led);
  return opened(result, there, false, led);
}

/// A chat another station's session opens here (chat_create there, from station `peer`): made once per its key, in the
/// workspace it was asked in (`ws`); the answer says whether its first message has come yet.
export async function createForPeer(hub: Hub, peer: string, request: Json, ws: string | null = null): Promise<Json> {
  const [parent, k] = [typeof request?.session === "string" ? request.session : "", keyOr(request)];
  return k === null ? createForPeerNow(hub, peer, request, ws) : oneByKey(hub, JSON.stringify([peer, parent, k]), () => createForPeerNow(hub, peer, request, ws));
}

async function createForPeerNow(hub: Hub, peer: string, request: Json, ws: string | null): Promise<Json> {
  const parent = typeof request?.session === "string" ? request.session : "";
  if (parent === "") throw new Error("session is required");
  const k = keyOf(request);
  const before = hub.store.openedWith(peer, parent, k, "");
  const answer = async (child: string): Promise<Json> => {
    const thread = sessionThreadOf(hub, child);
    const said = await openerSaid(hub, thread.thread.id, `${peer}/${parent}`, false);
    return { session: child, link: hub.link(child) ?? null, thread: addressOf(thread), said };
  };
  if (before !== null && hub.store.getSession(before.child) !== null && (ws === null || hub.inWorkspace(before.child, ws))) return answer(before.child);
  if (before !== null) throw new Error(`the chat key ${k} opened here is gone (deleted, or of another workspace): use another key`);
  const runtime = typeof request?.runtime === "string" ? request.runtime : "";
  if (!RUNTIMES.includes(runtime as RuntimeName)) throw new Error(`runtime must be one of ${RUNTIMES.join(", ")}`);
  const title = given(request, "title");
  const createdBy = given(request, "createdBy") ?? `${peer}/${parent}`;
  const model = given(request, "model");
  // With a preset (CREATE_PRESET): its copy, and the model configuration it names run as it says.
  const copy = request?.method === CREATE_PRESET || request?.method === CREATE_PRESET_SPEED || request?.method === CREATE_PRESET_TUI ? presetCopyInput(request?.presetCopy) : null;
  const bound = copy?.model ? boundHere(hub, ws, copy.model, copy.name) : null;
  // Its opener named no model: what its starter uses most here (an opener from before this sends its own, inherited).
  const chosen = bound !== null ? bound.choice
    : request?.choose === true && model === null ? chosenHere(hub, createdBy, ws, request?.runtimeGiven === true ? (runtime as RuntimeName) : null)
    : { runtime: runtime as RuntimeName, model };
  const more = {
    fast: typeof request?.fast === "boolean" ? (request.fast as boolean) : null,
    speed: modelSpeed(request?.speed),
    context: contextAsked(request?.context ?? undefined, stationLang()) ?? null,
    ...(copy !== null ? { presetCopy: copy } : {}),
    ...bound?.more,
  };
  const [child, childChat] = await makeChat(hub, { effort: given(request, "effort"), ...chosen, inherited: request?.inherited === true, title, createdBy, ws }, more);
  if (copy === null && typeof request?.project === "string") {
    try {
      hub.store.setThreadClassification(childChat.id, { project: request.project, force: true });
    } catch {}
  }
  // What its opener was called (its chat's way back to it says so while that chat is not in the viewer's list).
  const openerTitle = typeof request?.from?.title === "string" && request.from.title !== "" ? (request.from.title as string) : null;
  // (a station from before `for` sends none: told and asked as before it, led)
  const led = request?.led === false ? false : request?.led === true ? true : null;
  hub.store.insertOpened({ childStation: "", child, parentStation: peer, parent, key: k, title, link: hub.link(child) ?? null, openerTitle, led });
  log.info("hub", "chat opened for another station's session", { session: child, station: peer, opener: parent });
  return answer(child);
}

/// What an opener is told of a turn of a chat it opened.
function notice(title: string, link: string | null, state: Settled, words: string | null, led: boolean | null): string {
  const chat = link !== null ? `"${title}" (${link})` : `"${title}"`;
  const said = words !== null && words !== "" ? `: ${words}` : "";
  if (led === true) {
    const ended =
      state === "need_human" ? `asks you${said}. It is yours to decide (session_send it your answer), or to take to your person in your own chat, with what you checked; no person was asked`
      : state === "failed" ? `stopped with an error${said}`
      : state === "stopped" ? "was stopped by a person"
      : `ended its turn all_done${said}`;
    return `The chat you lead, ${chat}, ${ended}. Its words are its claims: check against your goal ledger before you tell anyone, yourself in the code or data any it gives up, finds no gain in or says needs your person, and anything against your person's rules (skill stillfail-leading). Read it with chat_read; write to its agent with session_send to its link.`;
  }
  const ended =
    state === "need_human" ? `needs a person${said}. They are asked there; help if you can, or wait`
    : state === "failed" ? `stopped with an error${said}`
    : state === "stopped" ? "was stopped by a person"
    : `ended its turn all_done${said}`;
  return `The chat you opened, ${chat}, ${ended}. Read it with chat_read; write to its agent with session_send to its link.`;
}

/// A turn of session `key` ended: its opener, if an agent opened its chat, is told how (on this station or its own).
export function settled(hub: Hub, key: string, state: Settled, words: string | null) {
  const opener = hub.store.openerOf(key);
  if (opener === null) return;
  // (opened for its person: its opener is told nothing of it)
  if (opener.led === false) return;
  const [title, link] = sender(hub, key);
  if (opener.parentStation === "") {
    hub.store.setOpenedState("", key, state);
    try {
      hub.notify(opener.parent, notice(title, link, state, words, opener.led));
    } catch (error) {
      log.warn("hub", "the opener of a chat was not told", { session: key, opener: opener.parent, error: (error as Error).message });
    }
    return;
  }
  const call = peersOf(hub, key);
  const tell = async () => {
    if (!call) throw new Error("other stations cannot be reached from this one yet");
    await call(opener.parentStation, { method: NOTICE, session: key, to: opener.parent, state, words, title });
  };
  // Not sent again: said in the chat instead, where its people (and the opener, reading it) see it.
  tell().catch(async (error) => {
    log.warn("hub", "the opener of a chat on another station was not told", { session: key, station: opener.parentStation, error: (error as Error).message });
    const latest = hub.store.latestThread(key);
    if (!latest) return;
    const text = tr(stationLang(), "station.session.openerNotTold", { error: (error as Error).message });
    try {
      const ts = await hub.chat(latest.connect).post({ channel: latest.thread.channel, threadTs: latest.thread.threadTs }, markNotice(text), []);
      hub.store.insertMessage({ thread: latest.thread.id, ts, authorKind: STATION_AUTHOR, author: STATION_AUTHOR, text, attachments: [] });
    } catch {}
  });
}

/// How a turn of a chat this station's session opened on station `peer` ended (`settled` there), told in workspace `ws`
/// (the opener's; null: any).
export function noticeForPeer(hub: Hub, peer: string, request: Json, ws: string | null = null): Json {
  const child = typeof request?.session === "string" ? request.session : "";
  const parent = typeof request?.to === "string" ? request.to : "";
  if (ws !== null && !hub.inWorkspace(parent, ws)) throw new Error(`${parent} opened no chat ${child} on that station`);
  const state = request?.state;
  if (!["all_done", "need_human", "failed", "stopped"].includes(state)) throw new Error("state must be all_done, need_human, failed or stopped");
  // (or one opened here and handed to that station since: its row here still names it this station's own, '')
  const record = hub.store.openedBy(parent).find((o) => o.child === child && (o.childStation === peer || (o.childStation === "" && hub.store.handedTo(child)?.station === peer)));
  if (!record) throw new Error(`${parent} opened no chat ${child} on that station`);
  hub.store.setOpenedState(record.childStation, child, state);
  const title = given(request, "title") ?? record.title ?? child;
  hub.notify(parent, notice(title, record.link, state, given(request, "words"), record.led));
  return { told: true };
}
