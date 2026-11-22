// Ends the process groups jobs of a test left, and waits until they are gone, not only signalled: the file's process
// looks for what it left as it exits (setup-env.mjs), and a group signalled a moment before was still there for it
// (check-station 135586660366: test/admit.test.ts). Called after the Jobs is shut down, so nothing new starts meanwhile;
// a group still there is signalled again (a shell that forked as it was killed).
import { groupAlive, signalGroup } from "../src/ops/group.ts";

export async function killGroups(pgids: Iterable<number | null>, timeoutMs = 5000): Promise<void> {
  const groups = [...new Set([...pgids].filter((g): g is number => g !== null))];
  const by = Date.now() + timeoutMs;
  for (let still = groups; still.length > 0 && Date.now() <= by; still = still.filter(groupAlive)) {
    for (const g of still) signalGroup(g, "SIGKILL");
    await new Promise((r) => setTimeout(r, 5));
  }
}
