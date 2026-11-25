// The station's one MoonBit program for its sessions (station/mb's reader `--sessions`): the agents' output read
// (mb-agents.ts `AgentsHost`) and the sessions' actors (sessions/mb-actor.ts `ActorsProgram`) in one process, so that
// what the one says the other can take in itself. Each part uses it (`use`) and lets it go (`release`); it ends once
// none uses it. What it says goes to the part it is of: the actors' lines say where the program stands (`active`), the
// agents' never.
import { sep } from "node:path";
import { log } from "../ops/log.ts";
import { MbProcess, mbReaderBinary } from "../read/mb-reader.ts";

type Json = any;

export type ProgramUser = {
  /// What the program said of this part.
  said(said: Json): void;
  /// The program ended (`code`), not asked to.
  exited(code: number): void;
  /// Of the actors (their lines), or of the agents.
  actors: boolean;
};

export class SessionsProgram {
  readonly #data: string;
  readonly #proc: MbProcess;
  readonly #users = new Set<ProgramUser>();
  readonly #held = new Set<ProgramUser>();
  #ended = false;

  private constructor(data: string) {
    this.#data = data;
    this.#proc = new MbProcess(mbReaderBinary()!, ["--sessions", "1", "--data", data, "--sep", sep]);
    // (held on to by the station's process only while a part of it has something going: `hold`)
    this.#proc.ref(false);
    // One not started (ENFILE, EMFILE) or gone is told here, its end then by "exit": unheard, it ends the station (D80).
    this.#proc.on("error", (error: Error) => log.warn("agents", "the sessions program failed", { error: error.message }));
    this.#proc.on("message", (said: Json) => {
      if (said?.ready === true) return;
      const actors = said !== null && typeof said === "object" && "active" in said;
      for (const user of this.#users) if (user.actors === actors) user.said(said);
    });
    this.#proc.on("exit", (code: number) => {
      const asked = this.#ended;
      this.#end();
      if (!asked) for (const user of [...this.#users]) user.exited(code);
    });
  }

  static readonly #shared = new Map<string, SessionsProgram>();

  /// The program of `data`'s sessions, where it is built (null: none here); started for its first user. `actors`: for
  /// a hub's actors, which one program holds one hub's of: a hub there while another's still runs (a test's station
  /// taken up in the same process) has one of its own.
  static of(data: string, actors = false): SessionsProgram | null {
    if (mbReaderBinary() === null) return null;
    let program = SessionsProgram.#shared.get(data);
    if (program !== undefined && !program.#ended && actors && [...program.#users].some((u) => u.actors)) return new SessionsProgram(data);
    if (program === undefined || program.#ended) SessionsProgram.#shared.set(data, (program = new SessionsProgram(data)));
    return program;
  }

  use(user: ProgramUser) {
    this.#users.add(user);
  }

  /// `user` lets it go: it ends once none uses it.
  async release(user: ProgramUser) {
    this.#users.delete(user);
    this.hold(user, false);
    if (this.#users.size > 0 || this.#ended) return;
    this.#end();
    await this.#proc.terminate();
  }

  post(message: Json) {
    if (!this.#ended) this.#proc.postMessage(message);
  }

  /// Whether the station's process waits on it for `user`: while one of its parts has something going.
  hold(user: ProgramUser, on: boolean) {
    const was = this.#held.size > 0;
    if (on) this.#held.add(user);
    else this.#held.delete(user);
    const now = this.#held.size > 0;
    if (now !== was && !this.#ended) this.#proc.ref(now);
  }

  /// Ends it at once (the station's process ends).
  kill() {
    this.#proc.kill();
  }

  get ended() {
    return this.#ended;
  }

  #end() {
    if (this.#ended) return;
    this.#ended = true;
    if (SessionsProgram.#shared.get(this.#data) === this) SessionsProgram.#shared.delete(this.#data);
  }
}
