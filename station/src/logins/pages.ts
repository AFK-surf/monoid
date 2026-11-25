// A login's page in the station's own browser (在 station 的浏览器中登录): a person who would
// rather not do a login's browser step on their own device (or whose device cannot: a web page takes no loopback
// callback) has the station open the page in a tab of its browser, and drives that tab from their app (a screen,
//). The page is the one the login command opened: one that comes back to a loopback port comes
// back to the command on this machine, with nothing to relay or paste. The tab is the login's, by a key of its own
// (`machine:<id>`, `profile:<id>`): kept while the login goes on (a person who went back finds it again), closed as it
// ends; a person closing it themselves is heard, and the login told again.
import type { OpenTabOptions } from "../browser/browser.ts";
export type { OpenTabOptions };
import { log } from "../ops/log.ts";

/// What of the station's browser the logins use (browser/browser.ts StationBrowser).
export type PagesBrowser = {
  available(): boolean;
  openTab(url: string, options?: OpenTabOptions): Promise<string>;
  hasTab(targetId: string): boolean;
  closeTab(targetId: string): Promise<void>;
  /// Where a tab is now (its address changing is told as the screens' change).
  tabUrl?(targetId: string): string | null;
};

/// The screen a tab of the station's browser is (browser/tabs.ts).
export const tabScreen = (targetId: string) => `browser:${targetId}`;

export class LoginPages {
  readonly #browser: PagesBrowser;
  /// The tab open for each login, by its key.
  readonly #tabs = new Map<string, string>();
  /// The workspace that owns each open login tab (null = home workspace).
  readonly #workspaces = new Map<string, string | null>();
  readonly #listeners = new Set<(key: string) => void>();
  /// Tabs being opened, by key: asked again meanwhile, the same one (only within the same workspace).
  readonly #opening = new Map<string, { workspace: string | null; promise: Promise<string> }>();
  /// Where each login's tab was last seen, by key: a change of it is told (the page a sign-in comes back to).
  readonly #urls = new Map<string, string | null>();

  /// `watch`: hears each time the station's screens change (a tab came or went).
  constructor(browser: PagesBrowser, watch: (changed: () => void) => () => void) {
    this.#browser = browser;
    watch(() => {
      for (const [key, id] of [...this.#tabs]) {
        if (this.#browser.hasTab(id)) {
          const url = this.#browser.tabUrl?.(id) ?? null;
          if (url === (this.#urls.get(key) ?? null)) continue;
          this.#urls.set(key, url);
          this.#tell(key);
          continue;
        }
        this.#tabs.delete(key);
        this.#workspaces.delete(key);
        this.#urls.delete(key);
        this.#tell(key);
      }
    });
  }

  /// Hears the key of each login whose tab came or went.
  changes(listener: (key: string) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  /// Whether a page can be opened here: the station has a browser.
  can(): boolean {
    return this.#browser.available();
  }

  /// Where the tab open for `key` is now, if one is.
  urlOf(key: string): string | null {
    const id = this.#tabs.get(key);
    return id !== undefined && this.#browser.hasTab(id) ? (this.#browser.tabUrl?.(id) ?? null) : null;
  }

  /// The screen of the tab open for `key`, if one is.
  screenOf(key: string): string | null {
    const id = this.#tabs.get(key);
    return id !== undefined && this.#browser.hasTab(id) ? tabScreen(id) : null;
  }

  /// The tab for `key`: the one open (in a window of its own, so seen as it is: browser.ts openTab), else a new one at
  /// `url`. Its screen. Refuses cross-workspace reuse when a live tab for `key` belongs to another workspace.
  async open(key: string, url: string, options?: OpenTabOptions): Promise<string> {
    const ws = options?.workspace ?? null;
    const had = this.#tabs.get(key);
    if (had !== undefined && this.#browser.hasTab(had)) {
      if (this.#workspaces.has(key) && this.#workspaces.get(key) !== ws) {
        throw new Error("this login page is already open in another workspace");
      }
      return tabScreen(had);
    }
    const pending = this.#opening.get(key);
    if (pending) {
      if (pending.workspace !== ws) {
        throw new Error("this login page is already opening in another workspace");
      }
      return pending.promise;
    }
    const openOpts: OpenTabOptions | undefined = options ? { ...options, workspace: ws } : undefined;
    const promise = (async () => {
      const id = openOpts ? await this.#browser.openTab(url, openOpts) : await this.#browser.openTab(url);
      this.#tabs.set(key, id);
      this.#workspaces.set(key, ws);
      this.#urls.set(key, this.#browser.tabUrl?.(id) ?? null);
      log.info("logins", "a login's page opened in the station's browser", { login: key });
      this.#tell(key);
      return tabScreen(id);
    })().finally(() => this.#opening.delete(key));
    this.#opening.set(key, { workspace: ws, promise });
    return promise;
  }

  /// The login ended: its tab closed.
  close(key: string): void {
    const id = this.#tabs.get(key);
    if (id === undefined) return;
    this.#tabs.delete(key);
    this.#workspaces.delete(key);
    this.#urls.delete(key);
    void this.#browser.closeTab(id);
    this.#tell(key);
  }

  #tell(key: string) {
    for (const l of this.#listeners) {
      try {
        l(key);
      } catch (e) {
        log.warn("logins", "a listener failed", { error: (e as Error).message });
      }
    }
  }
}
