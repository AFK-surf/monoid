// The group connects as a part of the agents' side (connects/part.ts says what every platform's connects are there): a
// group connect as the overview shows it and the pages edit it, and its route that adds one.
import { Effect, Layer } from "effect";
import { groupEntry, groupRoutes } from "../api/routes/group.ts";
import { connectsPart } from "../connects/part.ts";
import { Agents } from "../sessions/agents.ts";
import { Parts, Paths, StationConfig } from "../services.ts";
import { makeGroup } from "./index.ts";

export const GroupLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const { data } = yield* Paths;
    const config = yield* StationConfig;
    const parts = yield* Parts;
    const agents = yield* Agents;
    yield* connectsPart(makeGroup, { kind: "group", shown: (g, c) => g.shown(c), entry: groupEntry });
    // (the overview says a station has the group connect, which the pages offer only then)
    parts.overview("group", () => true);
    parts.routes(
      groupRoutes({
        config, data,
        hub: () => agents.hub,
        overview: (viewer, lang) => agents.overview(viewer, lang),
        place: () => agents.place(),
        heldBy: agents.heldBy,
      }),
    );
  }),
);
