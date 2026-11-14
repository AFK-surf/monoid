// The modules whose moving is not built yet (move/AGENTS.md says what each would take): each plans one item that says
// so in words, so that a whole-station move lists it rather than leaving it out unsaid. One file for the four, as none
// has code of its own yet.
import type { Item, Module } from "./module.ts";

export function pendingModule(id: string, label: string, cannot: string): Module {
  return {
    id,
    needs: [],
    async plan(ws) {
      return [{ module: id, id: ws, label, needs: [], cannot } satisfies Item];
    },
    async move() {
      throw new Error(cannot);
    },
    async back() {
      throw new Error(cannot);
    },
    state() {
      return { state: "here" };
    },
  };
}

/// The four, with what each would take.
export const PENDING = [
  ["agent-home", "the agents' memory and people's skills", "moving an agent home on its own is not built yet (a retirement merges it, replica/agent-carry.ts): copy MEMORY.md and the skills by hand if they are needed there"],
  ["settings", "this station's settings", "moving settings (sandboxes, agentEnv) is not built yet: set them on the other station in its config.json"],
  ["repos", "the repositories chats' worktrees hang on", "nothing to move on its own: a chat's linked worktree is made again there as it moves (its remote fetched, a bundle of what no remote has)"],
  ["vault", "the secrets kept on this station", "moving secrets is not built yet: they stay here, and a chat moved asks for them again there, its owner approving"],
] as const;
