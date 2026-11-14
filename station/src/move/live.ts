// Migrations as a part of the station (move/AGENTS.md): made of what the composition root gives (parts.ts), the
// workspace's connects once they are made, `handover.*` and `move.*` answered, station_move given, its card chosen.
import { Effect, Layer } from "effect";
import { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { ControlPlane, Events, Key, Parts, Paths, Peers, Store } from "../services.ts";
import { Agents } from "../sessions/agents.ts";
import { chatCards } from "../replica/retire-asks.ts";
import { gitHere, gitRun } from "../replica/retire.ts";
import { MoveAsks, moveTools } from "../tools/move.ts";
import { Moves } from "./station.ts";

type Json = any;

export const MovesLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const { data } = yield* Paths;
    const store = yield* Store;
    const bus = yield* Peers;
    const cloud = (yield* ControlPlane).state;
    const events = yield* Events;
    const parts = yield* Parts;
    const key = yield* Key;
    const agents = yield* Agents;
    const fibers = yield* Effect.acquireRelease(Effect.sync(() => new Fibers("move")), (f) => Effect.promise(() => f.close()));
    const roster = (ws: string) => {
      const m = cloud.membership(ws);
      if (m === null || !cloud.peersCurrent) return null;
      return m.peers.flatMap((p: Json) => (typeof p?.id === "string" ? [{ id: p.id as string, name: typeof p.name === "string" ? p.name : "", tasks: p.mode === "tasks" }] : []));
    };
    const hub = agents.hub;
    const wc = () => agents.workspaceConnects;
    const moves = new Moves({
      data, store, fibers, roster,
      here: () => key.id,
      home: () => cloud.home(),
      ask: (station, request) => bus.ask(station, request),
      hub: {
        holdChat: (k, why) => hub.holdChat(k, why),
        releaseChat: (k) => hub.releaseChat(k),
        wakeChat: (k) => hub.wakeChat(k),
        busy: (k) => hub.busy(k),
        turnEnded: (k) => hub.turnEnded(k),
        drained: (c, ch, ts) => hub.drained(c, ch, ts),
        wsOf: (k) => hub.wsOf(k),
      },
      connects: {
        route: (id, ch, ts, to) => wc()!.route(id, ch, ts, to),
        describedFor: (id) => wc()?.describedFor(id) ?? null,
        learnOf: (known, station, d) => wc()?.learnOf(known, station, d),
        kindOf: (id) => wc()?.kindOf(id) ?? null,
        own: () => wc()?.ownIds() ?? [],
        ownIn: (ws) => wc()?.ownKinds(ws) ?? [],
        runsOn: (id) => wc()?.runsOn(id) ?? null,
        move: (id, to) => wc()!.move(id, to, null),
      },
      jobs: {
        up: (keys, ws) => store.jobsUp()
          .filter((j) => !j.sessionKey.startsWith("remote:") && (keys !== null ? keys.includes(j.sessionKey) : ws === undefined || hub.ofWorkspace(j.sessionKey, ws)))
          .map((j) => ({ id: j.id, session: j.sessionKey, name: j.name, command: j.command, cwd: j.cwd, port: j.port, watch: j.watch })),
        stop: async (id) => void (await agents.jobs.stop(id)),
        start: (j) => void agents.jobs.start(j.session, j.name, j.command, j.cwd ?? store.getSession(j.session)?.workspace ?? data, j.port ?? null, j.watch === true),
        stopNamed: async (session, name) => {
          for (const j of store.jobsUp().filter((x) => x.sessionKey === session && x.name === name)) await agents.jobs.stop(j.id);
        },
      },
      profiles: () => (Array.isArray(agents.config.raw()?.profiles) ? agents.config.raw().profiles : []),
      moveProfile: (id, to) => agents.sharing.moveProfile(id, to),
      sessionsIn: (ws, after, limit) => store.sessionsOfWs(cloud.home() === ws ? null : ws, cloud.home(), after, limit),
      reposDir: hub.reposDir(),
      git: gitRun,
      hasGit: gitHere,
      changed: () => events.overviewChanged(),
    });
    yield* Effect.addFinalizer(() => Effect.promise(() => moves.close()));
    const inWorkspace = (peer: string) => cloud.memberships().some((m) => m.peers.some((p: Json) => p?.id === peer));
    const answers = moves.answers(inWorkspace);
    bus.on("handover.", answers);
    bus.on("move.", answers);
    const asks = new MoveAsks({
      data, scheduler: moves.scheduler,
      here: () => key.id,
      wsOf: (session) => hub.wsOf(session),
      roster,
      cards: chatCards(hub as Json),
      notify: (session, text) => hub.notify(session, text),
    });
    parts.cardChoice("move", { may: (viewer, card, at) => asks.may(viewer, card, at), chosen: (viewer, card, option, at) => asks.chosen(viewer, card, option, at) });
    parts.tools(moveTools(asks));
    bus.whenAttached(() => void moves.start().catch((e) => log.warn("move", "the migrations did not go on", { error: (e as Error).message })));
  }),
);
