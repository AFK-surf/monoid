// A program's chat page is ordered by the last message in each workspace, an index the MoonBit builder makes when it is
// first requested (test/reference/backfill/outflow-index.ts, the steps it replaced). These are a viewer's scopes in it.
import type { InWorkspace } from "./rows.ts";

export const outflowChatScopes = (viewer: InWorkspace) => viewer.home === false ? ["W" + viewer.workspace] : ["H", "W" + viewer.workspace];
