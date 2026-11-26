// The agents' `login` tool (agent 的 login 工具): a command failed for want of a login, or a person
// asked for one, and the agent runs the tool's own login command on this station. The agent drives the command's
// terminal (用户定: CLI 的交互由 agent 操作): it reads the screen and answers its prompts (Y/n, menus, a host to pick) itself;
// a person does only the step that needs them, in their own browser (a code to enter, a page to sign in on), reached by a
// login card or the link. What the agent is told never holds the page's address or the code (each shown as <link>, <code>):
// it has no use for them, and so never posts them to Slack or a chat. Nothing types a secret: a prompt read without echo is
// refused.
import type { Logins, Login, Starter } from "./index.ts";
import { COLS, type Screen } from "./run.ts";
import { urlContinuation } from "../ops/command-output.ts";
import type { Tool } from "../tools/mcp.ts";


/// How long a call waits for the command to settle (go quiet: what it waits on is then known), at most.
const START_WAIT_MS = 15_000;
const INPUT_WAIT_MS = 5_000;
/// The keys the agent may send, as it names them, and as the terminal does.
const KEYS: Record<string, "Enter" | "Backspace" | "Up" | "Down" | "Left" | "Right" | "Tab" | "Ctrl-C"> = {
  enter: "Enter", backspace: "Backspace", up: "Up", down: "Down", left: "Left", right: "Right", tab: "Tab", "ctrl-c": "Ctrl-C",
};

export const LOGIN = {
  name: "login",
  description:
    "Log this station in to a command-line tool, when a command fails because it is not logged in (401, an expired token) or a person asks for it. command: the tool's own login command, with its browser or device-code option where it has one (skill stillfail-login says which, and what to avoid). You drive the command: each answer shows its screen and what to do next. Never type a password or token (a prompt that asks for one is refused), and take the answers that leave the OS keychain alone: nobody here can answer its dialog. The login is machine-wide: every chat's agent on this station uses it.",
  inputSchema: {
    "type": "object",
    "properties": {
      "command": {
        "description": "Start: the tool's own login command, as a line (gh auth login) or words.",
        "anyOf": [{ "type": "string" }, { "type": "array", "items": { "type": "string" } }]
      },
      "byCode": {
        "description": "With command, for a loopback login: the same tool's login whose page gives a code to paste back (skill stillfail-login). A person who cannot take the callback (a web page) switches to it from the card.",
        "anyOf": [{ "type": "string" }, { "type": "array", "items": { "type": "string" } }]
      },
      "id": {
        "type": "string",
        "description": "A login's id (start answers it): how it stands, its screen; with input, key or cancel, act on it."
      },
      "input": {
        "type": "string",
        "description": "With id: text typed at its prompt (a key, e.g. enter, follows only if given)."
      },
      "key": {
        "type": "string",
        "enum": ["enter", "up", "down", "left", "right", "tab", "backspace", "ctrl-c"],
        "description": "With id: a key pressed (after input, if both)."
      },
      "cancel": {
        "type": "boolean",
        "description": "With id: end that login."
      },
      "paste": {
        "type": "boolean",
        "description": "With id: true when its page hands out a code to paste back here (\"enter the verification code\"): the card gets a field for the person; you never type it. false takes it away. Only after a page to open; never for a password or token."
      },
      "station": {
        "type": "string",
        "description": "Another station of the workspace, by name or id: the command runs there; give it with id too. Left out: this station."
      }
    },
    "additionalProperties": false
  },
};

export type LoginToolDeps = {
  logins: () => Logins | undefined;
  /// A login on another station of the workspace (`station`, by its name or id): what that station answers its agent's
  /// call with (logins/module.ts asks it over the station transport).
  remote?: (station: string, session: string, args: Record<string, unknown>) => Promise<string>;
  /// Who a session's login is for: its chat's starter and workspace, its chat and title.
  starter: (session: string) => Starter;
  /// The link that opens a login in a person's client (null outside a workspace with pages).
  link: (session: string, id: string) => string | null;
};

/// A login's text with its page's address and code hidden (the agent has no use for them).
function hidden(login: Login, text: string): string {
  const out = text.replace(/https?:\/\/\S+/g, "<link>");
  return login.code ? out.split(login.code).join("<code>") : out;
}

/// The screen as its agent reads it: the lines with something on them (the last 30), the page's address and the code
/// hidden, the line the cursor is on marked. A line the terminal wrapped (`wrapped`) and a link the program broke over
/// lines itself (`urlContinuation`) are put together first: hidden whole, no part of the page's address is left to read.
export function screenFor(screen: Screen | null, login: Login): string {
  if (screen === null) return "";
  type Line = { text: string; rawEnd: string; cursor: boolean };
  const wrapped: Line[] = [];
  screen.rows.forEach((row, y) => {
    const here = y === screen.cursor.y && screen.live;
    const prev = wrapped.at(-1);
    if (prev !== undefined && screen.wrapped?.[y] === true) {
      prev.text += row;
      prev.rawEnd = row;
      prev.cursor ||= here;
    } else wrapped.push({ text: row, rawEnd: row, cursor: here });
  });
  const logical: Line[] = [];
  for (let i = 0; i < wrapped.length; i++) {
    const line = { ...wrapped[i]! };
    let wrapWidth: number | null = null;
    while (i + 1 < wrapped.length) {
      const trimmed = line.text.trimEnd();
      const next = wrapped[i + 1]!;
      const width = urlContinuation(line.rawEnd, trimmed, next.text, COLS, wrapWidth);
      if (width === null) break;
      line.text = trimmed + next.text.trimStart();
      line.rawEnd = next.rawEnd;
      line.cursor ||= next.cursor;
      wrapWidth = width;
      i++;
    }
    logical.push(line);
  }
  const lines = logical.map((line) => {
    const shown = hidden(login, line.text).trimEnd();
    return line.cursor ? `${shown}▏` : shown;
  });
  let end = lines.length;
  while (end > 0 && lines[end - 1]!.trim() === "") end--;
  const shown = lines.slice(0, end).filter((l, i, all) => l.trim() !== "" || (i > 0 && all[i - 1]!.trim() !== ""));
  return shown.slice(-30).join("\n");
}

/// Where a login runs, as its agent is told: this station, or another of the workspace (its key, for the card, and its
/// name).
export type Where = { station: string; name: string } | null;
const placeOf = (where: Where) => (where ? `on ${where.name}` : "on this station");
const cardOf = (login: Login, where: Where) => JSON.stringify({ type: "login", login: login.id, ...(where ? { station: where.station } : {}) }).replaceAll(",", ", ").replaceAll(":", ": ");

/// What the agent is told of a login: how it stands, its screen, and what to do next.
export function told(logins: Logins, login: Login, link: string | null, where: Where = null): string {
  const state = {
    id: login.id,
    command: login.command.join(" "),
    state: login.state,
    ...(login.step ? { step: login.step } : {}),
    ...(login.waiting ? { waiting: true } : {}),
    ...(login.paste ? { paste: true } : {}),
    ...(link ? { link } : {}),
  };
  // What is posted for the person's browser step: its card; for one started again from its card, nothing more (that
  // card follows it).
  const post = login.from !== undefined
    ? `its card in the chat (of login ${login.from}) follows this login already: do not post another card for it; chat_post a line telling who should log in that its card is ready again, and end need_human. You get a station notice when it ends.`
    : `chat_post with card ${cardOf(login, where)} (card.assignee: who should log in) and a sentence saying who should log in to what ${placeOf(where)} and why, without the link in still.fail chats (the card opens the page); in Slack or Feishu, include the link${link ? ` ${link}` : ""} in the text with that same card; end need_human. You get a station notice when it ends.`;
  const screen = screenFor(logins.screen(login.id), login);
  const active = login.endedAt === undefined;
  const next = !active
    ? login.state === "done" ? "It finished (its command exited 0)." : login.state === "cancelled" ? "It was cancelled." : `It failed${login.timedOut ? " (out of time)" : ""}${login.error ? `: ${hidden(login, login.error)}` : "."}`
    : logins.screen(login.id)?.echo === false && login.waiting
      ? "It asks for a secret (read without echo): do not type it, nothing is sent to such a prompt. Cancel it, and use the tool's browser or device-code login, or tell the person it cannot be logged in this way."
      : login.state === "verifying"
        ? "What came back (the code the person entered, or the browser's callback) is being checked: you get a station notice when it ends."
      : login.paste
        ? `The person's browser step is ready: they open the page and enter what it gives (a code) in the login card's field, which types it here; do not answer its prompt yourself. ${post}`
      : login.waiting
        ? `It waits on the prompt above: answer it with login {id${where ? ", station" : ""}, input and/or key} (the tool's default, usually key enter, or what the task needs)${login.step === "open" ? `, unless it asks for what the page it gave hands out (a code to paste back): then do not answer it; login {id${where ? ", station" : ""}, paste: true} gives the login card a field for the person, and post the card as below` : ""}. If you truly cannot decide, ask the person in the chat.`
        : login.step === "device" || login.step === "loopback" || login.step === "open"
          ? `The person's browser step is ready${login.step === "open" ? ` (if the screen says the page gives a code to paste back here, first login {id${where ? ", station" : ""}, paste: true}: the card gets a field for it; never type it yourself)` : ""}: ${post}`
          : `It is still working: look again with login {id${where ? ", station" : ""}}.`;
  const shown = where ? { ...state, station: where.station, stationName: where.name } : state;
  return `${JSON.stringify(shown, null, 2)}\n\nScreen:\n${screen === "" ? "(nothing yet)" : screen}\n\n${next}`;
}

/// A call of the tool acted on this station's logins: started, looked at, answered or cancelled; what its agent is told.
/// `starter`: who a new one is for; `link`: a login's link in a person's client; `where`: told the agent when it is on
/// another station than its own; `mine`: whether the caller may act on a login (one of another station's agents may only
/// on those it started).
export async function act(logins: Logins, args: Record<string, unknown>, o: { starter: () => Starter; link: (id: string) => string | null; where?: Where; mine?: (id: string) => boolean }): Promise<string> {
  const where = o.where ?? null;
  if (typeof args.id === "string" && args.id !== "") {
    const id = args.id;
    if (logins.get(id) === null || (o.mine && !o.mine(id))) throw new Error(`no login ${id}`);
    if (args.cancel === true) logins.cancel(id);
    else if (typeof args.paste === "boolean") logins.paste(id, args.paste);
    else if (typeof args.input === "string" || typeof args.key === "string") {
      const key = typeof args.key === "string" ? KEYS[args.key.toLowerCase()] : undefined;
      if (typeof args.key === "string" && key === undefined) throw new Error(`key: one of ${Object.keys(KEYS).join(", ")}`);
      const waits = logins.settle(id, INPUT_WAIT_MS);
      if (typeof args.input === "string" && args.input !== "") logins.input(id, { text: args.input });
      if (key !== undefined) logins.input(id, { key });
      await waits;
    }
    const login = logins.get(id)!;
    return told(logins, login, o.link(id), where);
  }
  const command = typeof args.command === "string" || Array.isArray(args.command) ? (args.command as string | string[]) : null;
  if (command === null) throw new Error("command: the tool's own login command (e.g. gh auth login); or id to see or act on one");
  const byCode = typeof args.byCode === "string" || Array.isArray(args.byCode) ? (args.byCode as string | string[]) : undefined;
  const started = await logins.start(command, o.starter(), byCode === undefined ? {} : { byCode });
  const login = (await logins.settle(started.id, START_WAIT_MS)) ?? started;
  return told(logins, login, o.link(login.id), where);
}

export function loginTools(deps: LoginToolDeps): Tool[] {
  return [
    {
      ...LOGIN,
      run: async (session: string, args: Record<string, unknown>) => {
        if (typeof args.station === "string" && args.station.trim() !== "") {
          if (!deps.remote) throw new Error("logging in another station is not there yet: log in on this station");
          return deps.remote(args.station.trim(), session, args);
        }
        const logins = deps.logins();
        if (logins === undefined) throw new Error("the station is starting: try again in a moment");
        return act(logins, args, { starter: () => deps.starter(session), link: (id) => deps.link(session, id) });
      },
    },
  ];
}

/// What a session that started a login, or posted its card, is told when it ends.
export function endedNotice(login: Login, link: string | null, where: Where = null): string {
  const which = `${login.command.join(" ")} (login ${login.id})`;
  const how =
    login.state === "done" ? "finished (its command exited 0). Carry on with what needed it, and check it works"
    : login.state === "cancelled" ? "was cancelled. Ask whether it is still wanted before starting another"
    : `failed${login.error ? `: ${hidden(login, login.error.split("\n").slice(-9).join(" / "))}` : ""}. Start it again if it is still needed`;
  return `The login ${placeOf(where)} you started or posted a card for, ${which}, ${how}.${login.state === "done" ? "" : link ? ` (Its link was ${link}.)` : ""} Its card was closed.`;
}

/// What the agent a login is for is told as a person starts it again from its card (`from` the one that failed): to
/// drive the new one as it would one it started, its card in the chat already following it.
export function againNotice(from: Login, login: Login, by: { email: string; name: string }, where: Where = null, byCode = false): string {
  const who = by.name || by.email || "A person";
  if (byCode) return `${who}, on a device that cannot take its callback, switched the login ${placeOf(where)} ${from.command.join(" ")} (login ${from.id}) to its code-pasting login from its card: it is login ${login.id} now (${login.command.join(" ")}), and login ${from.id} was cancelled. Drive it as one you started: answer what it asks with login {id: "${login.id}"${where ? ", station" : ""}}, look at it first. Its card in the chat follows the new login already and gets the field for the code once its page shows: do not post another card for it, and do not type the code yourself; when it reaches the person's browser step, tell them in a line that the card is ready again and end need_human. You get a station notice when it ends.`;
  return `${who} started the login ${placeOf(where)} ${from.command.join(" ")} (login ${from.id}, which ${from.timedOut ? "ran out of time" : "failed"}) again from its card: it is login ${login.id} now. Drive it as one you started: answer what it asks with login {id: "${login.id}"${where ? ", station" : ""}}, look at it first. Its card in the chat follows the new login already: do not post another card for it; when it reaches the person's browser step, tell them in a line that the card is ready again and end need_human. You get a station notice when it ends.`;
}

/// What its agent is told when, after its person's browser step, the command asks something again.
export function promptNotice(logins: Logins, login: Login, link: string | null, where: Where = null): string {
  return `The login ${placeOf(where)} you started, ${login.command.join(" ")} (login ${login.id}), asks something again:\n\n${told(logins, login, link, where)}`;
}

