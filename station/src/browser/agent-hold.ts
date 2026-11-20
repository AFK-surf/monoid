// An agent operating a tab of its chat's browser over DevTools (`Gate`): joined to `browser:<target>` in `ScreenHub` as
// `"agent: <its chat>"`, so people watching see `agent: … 正在控制` and passive views yield (`watchOnly`) without
// fighting the agent's clicks and navigations. When a person explicitly takes control (`[接管]`, `taken: true`), the
// agent's operating commands are refused until they leave. Released immediately when the session's turn ends, its
// browser closes, or after AGENT_HOLD_IDLE_MS with no operating command.
import { wall } from "../ops/fibers.ts";

export const AGENT_HOLD_IDLE_MS = 15_000;

export type AgentHoldHub = {
  people(id: string): { views: { name: string; control: boolean; agent?: boolean }[] };
  hasTakenView(id: string): boolean;
  yieldToAgent(id: string, by: string): number;
  join(id: string, watcher: { name: string; control: boolean; agent: boolean; tell(state: Record<string, unknown>): void }): () => void;
};

export type AgentHoldParts = {
  hub: AgentHoldHub;
  name: (session: string) => string;
  later?: (ms: number, f: () => void) => () => void;
};

type Held = {
  session: string;
  leave: () => void;
  cancel: () => void;
};

export class BrowserAgentHold {
  readonly #p: AgentHoldParts;
  readonly #later: (ms: number, f: () => void) => () => void;
  readonly #active = new Map<string, Held>();
  #closed = false;

  constructor(p: AgentHoldParts) {
    this.#p = p;
    this.#later = p.later ?? ((ms, f) => wall.after(ms, f));
  }

  act(session: string, target: string, method: string): string | null {
    const screenId = `browser:${target}`;
    const key = `${session}\n${target}`;
    const persons = this.#p.hub.people(screenId).views.filter((v) => v.control && !v.agent);
    if (persons.length > 0 && (this.#active.has(key) || this.#p.hub.hasTakenView(screenId))) {
      this.#releaseKey(key);
      const who = [...new Set(persons.map((v) => v.name))];
      return `${who.join(", ")} ${who.length > 1 ? "are" : "is"} controlling ${screenId} right now, so ${method} was not sent: do not fight them. Wait until they leave it or ask them in the chat.`;
    }
    if (method === "Target.closeTarget" || this.#closed) {
      this.#releaseKey(key);
      return null;
    }
    const by = this.#p.name(session);
    let entry = this.#active.get(key);
    if (!entry) {
      const leave = this.#p.hub.join(screenId, { name: by, control: true, agent: true, tell: () => {} });
      entry = { session, leave, cancel: () => {} };
      this.#active.set(key, entry);
    }
    if (persons.length > 0) this.#p.hub.yieldToAgent(screenId, by);
    entry.cancel();
    entry.cancel = this.#later(AGENT_HOLD_IDLE_MS, () => this.#releaseKey(key));
    return null;
  }

  releaseSession(session: string): void {
    for (const [key, entry] of [...this.#active]) {
      if (entry.session === session) this.#releaseKey(key);
    }
  }

  close(): void {
    this.#closed = true;
    for (const key of [...this.#active.keys()]) this.#releaseKey(key);
  }

  #releaseKey(key: string): void {
    const entry = this.#active.get(key);
    if (!entry) return;
    this.#active.delete(key);
    entry.cancel();
    entry.leave();
  }
}
