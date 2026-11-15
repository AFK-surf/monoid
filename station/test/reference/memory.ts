// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with; what the station itself still runs of it is station/src/read/memory.ts's.
//
// The agents' memory, for the pages to show (GET /memory; the agents write it): the global one, and the shared skills
// (projects' memories among them). admin/mod.rs's route over agent_home.rs `agent_home_paths` and `list_skills`. A
// workspace the station joined has its own: <agent home>/workspaces/<ws>.
import { joined, readJson, agentHome } from "../../src/read/memory.ts";

export * from "../../src/read/memory.ts";
export { joined, readJson, agentHome };

/// The agents' home of the station whose data is in `dataDir`: their shared memory and skills.
export function agentHomeOf(dataDir: string): string {
  return agentHome(readJson(joined(dataDir, "config.json")), dataDir);
}
