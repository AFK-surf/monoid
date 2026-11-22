// How a station's link came back as the app did: one span (`station.back`) for each station at each return from at
// least BACK_AWAY_MS away, or a change of network. It says whether the stream open at the return had to be opened again
// (the link had gone while the app was frozen), how long that took, and how long until the first event of the station's
// log came. Times and states alone: never what an event says.
import type { Span } from "../trace.ts";

/// Away less than this, the app's paths have not been silent long enough to go (3 s on every endpoint).
export const BACK_AWAY_MS = 3_000;
/// How long a return is followed. Past the station's keepalive (25 s), so a stream that still holds is heard.
export const BACK_WATCH_MS = 30_000;

export type BackEnd = "event" | "quiet" | "again";

export class Back {
  readonly #span: Span;
  readonly #now: () => number;
  readonly #at: number;
  #opened = false;
  #heard = false;
  #ended = false;

  constructor(span: Span, now: () => number, away: number, network: boolean, streamOpen: boolean) {
    this.#span = span;
    this.#now = now;
    this.#at = now();
    span.set("stillfail.back.away_ms", Math.round(away));
    span.set("stillfail.back.network", network);
    span.set("stillfail.back.stream_open", streamOpen);
  }

  #since(): number {
    return Math.round(this.#now() - this.#at);
  }

  /// A stream opened after the return (the first only).
  opened(resumed: boolean): void {
    if (this.#ended || this.#opened) return;
    this.#opened = true;
    this.#span.set("stillfail.back.opened_ms", this.#since());
    this.#span.set("stillfail.back.resumed", resumed);
  }

  /// Anything came on a stream, its keepalive too (the first only).
  heard(): void {
    if (this.#ended || this.#heard) return;
    this.#heard = true;
    this.#span.set("stillfail.back.heard_ms", this.#since());
  }

  end(how: BackEnd): void {
    if (this.#ended) return;
    this.#ended = true;
    if (how === "event") this.#span.set("stillfail.back.event_ms", this.#since());
    this.#span.set("stillfail.back.end", how);
    this.#span.end();
  }
}
