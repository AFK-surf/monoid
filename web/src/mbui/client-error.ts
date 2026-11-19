// What the web host sends of an error to its core's `client.error` span (core.ts reportClientError): the text people's
// pages could carry (an address's query or fragment, a stack's files) left out, and an error repeating in a loop sent
// once a minute.

/// What of an error's text leaves the page: its first line, no address's query or fragment, at most 300 characters.
export function errorSummary(message: string): string {
  const firstLine = message.split("\n")[0] ?? "";
  const bare = firstLine.replace(/\b(https?:\/\/[^\s?#"'`<>]*)[?#][^\s"'`<>]*/g, "$1");
  return [...bare.trim()].slice(0, 300).join("");
}

/// The browser's own noise, not an error of the page's.
const NOISE = [/^ResizeObserver loop/i, /^Script error\.?$/i];

export function isNoise(text: string): boolean {
  return NOISE.some((n) => n.test(text));
}

/// When each error was last let through (by source and summary), at most `kept` of them: the oldest let go of.
export class ErrorGate {
  readonly #at = new Map<string, number>();
  readonly windowMs: number;
  readonly kept: number;
  constructor(windowMs = 60_000, kept = 64) {
    this.windowMs = windowMs;
    this.kept = kept;
  }

  /// The summary to send, or null: empty, or the same sent within the window.
  pass(source: string, message: string, now: number): string | null {
    const summary = errorSummary(message);
    if (summary === "") return null;
    const key = `${source}\u0000${summary}`;
    const was = this.#at.get(key);
    if (was !== undefined && now - was < this.windowMs) return null;
    this.#at.delete(key);
    this.#at.set(key, now);
    while (this.#at.size > this.kept) this.#at.delete(this.#at.keys().next().value as string);
    return summary;
  }

  get size(): number {
    return this.#at.size;
  }
}

/// An error's text as `name: message`, or what was thrown said as it is.
export function thrownText(thrown: unknown): string {
  if (thrown && typeof thrown === "object" && typeof (thrown as { message?: unknown }).message === "string") {
    const name = (thrown as { name?: unknown }).name;
    return `${typeof name === "string" ? name : "Error"}: ${(thrown as { message: string }).message}`;
  }
  return thrown === undefined || thrown === null ? "" : String(thrown);
}
