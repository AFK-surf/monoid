// browser: the chat's own Chrome (src/browser/browsers.ts), for its agent to drive over its DevTools with its own
// client (chrome-devtools-mcp, Playwright). Its profile keeps the sign-ins made in it, this chat's alone: no other
// chat's agent reaches them, and they go when the chat is archived. A person can see and drive its tabs from their app
// (the `screen` tool gives the link), which is how an agent asks for a sign-in or a captcha. The session reaches it at
// its own address on the door (browser/proxy.ts).
import type { BrowserStatus } from "./browser.ts";
import { sessionPath } from "./proxy.ts";
import type { TabInfo } from "./tabs.ts";
import type { Tool } from "../tools/mcp.ts";
import { type FarviewConfig, type FarviewTab, type FarviewTabs, farviewHowTo } from "./farview.ts";

export const BROWSER = {
  name: "browser",
  description:
    "This chat's own browser (Chrome, or Farview where the station has it), its sign-ins this chat's alone until it is archived. action endpoint (default) starts it and says how to drive it; tabs lists its tabs; status says whether it runs; stop closes it (sign-ins stay). Skill stillfail-browser. Sign in to a site with `sign_in` on its sign-in page; a captcha or consent: give a person the tab with `screen`.",
  inputSchema: {
    type: "object",
    properties: {
      action: { type: "string", enum: ["endpoint", "tabs", "status", "stop", "open", "close"], description: "Default endpoint. open, close: Farview's." },
      tab: { type: "string", description: "Farview tab id (default: first)." },
      url: { type: "string" },
      engine: { type: "string", enum: ["chrome", "farview"], description: "This chat's browser from now on." },
    },
    additionalProperties: false,
  },
};

/// This session's address of the browser (browser/proxy.ts), from the door's MCP URL; null without one (Chrome's own).
export function sessionWs(doorUrl: string | null, session: string): string | null {
  return doorUrl === null ? null : `${doorUrl.replace(/^http:/, "ws:").replace(/\/mcp$/, "")}${sessionPath(session)}`;
}

/// What `endpoint` tells the agent: where (`ws`, this session's address), how to connect, and how to share it.
export function howTo(s: BrowserStatus, ws: string | null): string {
  const at = ws ?? s.http;
  return [
    `This chat's browser runs (${s.binary || "Chrome"}${s.headless ? ", headless" : ""}).`,
    `DevTools for this chat: ${at}`,
    "",
    "Connect with your own client at this address:",
    ws !== null
      ? `- chrome-devtools-mcp: \`npx -y chrome-devtools-mcp@latest --wsEndpoint ${ws}\``
      : `- chrome-devtools-mcp: \`npx -y chrome-devtools-mcp@latest --browserUrl ${s.http}\``,
    `- Playwright: \`const browser = await chromium.connectOverCDP("${at}"); const page = await browser.contexts()[0].newPage();\` — the default context holds the sign-ins; a new context has none.`,
    "",
    "It is this chat's alone: its sign-ins are the ones made in it (none of another chat's). Close the tabs you are done with.",
    "Never launch another Chrome for work that needs a login: this one keeps them.",
    "To be signed in to a site, open its sign-in page here and call `sign_in {site, reason}`: it asks for the sign-in the vault keeps, or has the person sign in from a card with their own password manager. Never ask for a password in the chat.",
    "When a page needs a person for anything else (a captcha, a consent), give them that tab with the `screen` tool (a link to see and drive it from their app), ask in the chat (need_human), and end your turn; carry on when they say it is done.",
    ws !== null
      ? "If the connection drops (the browser was restarted or closed after a long idle, the station restarted), connect again to the same address: it starts the browser if needed."
      : "If the connection drops (the browser was restarted or closed after a long idle), call browser again: the address usually stays the same.",
  ].join("\n");
}

const tabsText = (tabs: TabInfo[]): string =>
  tabs.length === 0 ? "No tabs open (or the browser is not running)." : tabs.map((t) => `- ${t.id} ${t.title ? `${JSON.stringify(t.title)} ` : ""}${t.url}${t.attached ? " (a client is attached)" : ""}`).join("\n");

/// What the tool asks of the browsers (browsers.ts Browsers): each session's chat's.
export type ToolBrowsers = {
  endpoint(session: string): Promise<BrowserStatus>;
  tabs(session: string): TabInfo[];
  status(session: string): BrowserStatus;
  stop(session: string): Promise<void>;
};

/// `doorUrl`: the agents' door's MCP URL once it is open (parts.ts `doorUrl`), where each session is given its address.
/// `farview`: the chats' Farview (farview.ts), used in place of Chrome for the chats it is the browser of (`activeFor`).
export function browserTools(browser: ToolBrowsers, doorUrl: () => string | null = () => null, farview: FarviewTabs | null = null): Tool[] {
  return [
    {
      ...BROWSER,
      async run(session, args) {
        const action = typeof args.action === "string" ? args.action : "endpoint";
        if (args.engine === "chrome" || args.engine === "farview") {
          if (farview === null || farview.active() === null) throw new Error("This station has no Farview (config.json `browser.farview` is false, or no release for this system): this chat's browser is Chrome.");
          await farview.choose(session, args.engine);
          // (Farview chosen: the chat's Chrome closed, as choosing Chrome ends its Farview; its sign-ins stay)
          if (args.engine === "farview") await browser.stop(session);
        }
        const fv = farview?.active() ?? null;
        if (farview !== null && fv !== null && farview.activeFor(session)) {
          return farviewRun(farview, fv, session, action, typeof args.tab === "string" ? args.tab : "", typeof args.url === "string" ? args.url : "");
        }
        switch (action) {
          case "endpoint":
            return howTo(await browser.endpoint(session), sessionWs(doorUrl(), session));
          case "tabs":
            return tabsText(browser.tabs(session));
          case "status": {
            const s = browser.status(session);
            return s.running
              ? `Running: ${sessionWs(doorUrl(), session) ?? s.http}, ${s.tabs} tab(s), ${s.viewing} view(s) by people${s.headless ? ", headless" : ""}.`
              : "Not running: `browser` (action endpoint) starts it.";
          }
          case "stop":
            await browser.stop(session);
            return "This chat's browser is closed (its profile and sign-ins stay).";
          case "open":
          case "close":
            throw new Error(`${action} is Farview's: in Chrome, open and close tabs over its DevTools (action endpoint)`);
          default:
            throw new Error(`unknown action ${action}: endpoint, tabs, status or stop`);
        }
      },
    },
  ];
}

const farviewTabsText = (tabs: FarviewTab[]): string =>
  tabs.length === 0
    ? "No tabs open (or the browser is not running): `browser` (action endpoint) starts it."
    : tabs.map((t) => `- ${t.id} ${t.title ? `${JSON.stringify(t.title)} ` : ""}${t.url} (agent port ${t.agent})`).join("\n");

async function farviewRun(farview: FarviewTabs, config: FarviewConfig, session: string, action: string, tab: string, url: string): Promise<string> {
  switch (action) {
    case "endpoint": {
      await farview.endpoint(session);
      if (tab !== "" && farview.agentPort(session, tab) === null) throw new Error(`no such tab in this chat's browser: ${tab}`);
      return farviewHowTo(config, farview.tabs(session));
    }
    case "tabs":
      return farviewTabsText(farview.tabs(session));
    case "open": {
      await farview.endpoint(session);
      const t = await farview.open(session, url);
      return `Opened ${t.id} on ${url || "about:blank"}. Drive it with: \`${config.agent} 127.0.0.1 ${t.agent} <step>...\``;
    }
    case "close":
      if (tab === "") throw new Error("close: say which tab (`tab`, an id from tabs)");
      await farview.closeTab(session, tab);
      return `Closed ${tab}.`;
    case "status": {
      const s = farview.status(session);
      if (!s.running) return "Not running: `browser` (action endpoint) starts it.";
      const port = farview.agentPort(session, tab);
      return `Running: Farview, ${s.tabs} tab(s)${port === null ? "" : `, agent port ${port}`}, ${s.viewing} view(s) by people.`;
    }
    case "stop":
      await farview.stop(session);
      return "This chat's browser is closed (its cookies and storage stay).";
    default:
      throw new Error(`unknown action ${action}: endpoint, tabs, open, close, status or stop`);
  }
}
