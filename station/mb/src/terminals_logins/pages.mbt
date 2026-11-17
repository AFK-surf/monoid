// station/src/logins/pages.ts: a login's page in the station's own browser (在 station 的浏览器中登录): a person who
// would rather not do a login's browser step on their own device (or whose device cannot: a web page takes no
// loopback callback) has the station open the page in a tab of its browser, and drives that tab from their app (a
// screen). The page is the one the login command opened: one that comes back to a loopback port comes back to the
// command on this machine, with nothing to relay or paste. The tab is the login's, by a key of its own
// (`machine:<id>`, `profile:<id>`): kept while the login goes on (a person who went back finds it again), closed as it
// ends; a person closing it themselves is heard, and the login told again.

///|
/// What of the station's browser the logins use (browser/browser.ts StationBrowser).
pub(all) struct PagesBrowser {
  available : () -> Bool
  /// openTab(url, options?): its target's id.
  open_tab : async (String, J?) -> String
  has_tab : (String) -> Bool
  /// closeTab(id), not waited for.
  close_tab : (String) -> Unit
  /// Where a tab is now (None: the browser cannot say, as one without `tabUrl`).
  tab_url : ((String) -> String?)?
}

///|
/// The screen a tab of the station's browser is (browser/tabs.ts).
pub fn tab_screen(target : String) -> String {
  "browser:" + target
}

///|
pub struct LoginPages {
  priv browser : PagesBrowser
  /// The tab open for each login, by its key.
  priv tabs : Map[String, String]
  priv listeners : Listeners[(String) -> Unit]
  /// Tabs being opened, by key: asked again meanwhile, the same one.
  priv opening : Map[String, @effect.Deferred[Result[String, Error]]]
  /// Where each login's tab was last seen, by key: a change of it is told (the page a sign-in comes back to).
  priv urls : Map[String, String?]
  priv log : (String, J) -> Unit
}

///|
/// `watch`: hears each time the station's screens change (a tab came or went).
pub fn LoginPages::new(
  browser : PagesBrowser,
  watch : (() -> Unit) -> Unit,
  log : (String, J) -> Unit,
) -> LoginPages {
  let pages : LoginPages = {
    browser,
    tabs: {},
    listeners: Listeners::new(),
    opening: {},
    urls: {},
    log,
  }
  watch(() => {
    let tabs = pages.tabs.iter().collect()
    for kv in tabs {
      let (key, id) = kv
      if (pages.browser.has_tab)(id) {
        let url = pages.url_now(id)
        if url == pages.urls.get(key).unwrap_or(None) {
          continue
        }
        pages.urls[key] = url
        pages.tell(key)
        continue
      }
      pages.tabs.remove(key)
      pages.urls.remove(key)
      pages.tell(key)
    }
  })
  pages
}

///|
fn LoginPages::url_now(self : LoginPages, id : String) -> String? {
  match self.browser.tab_url {
    Some(f) => f(id)
    None => None
  }
}

///|
/// Hears the key of each login whose tab came or went.
pub fn LoginPages::changes(self : LoginPages, listener : (String) -> Unit) -> () -> Unit {
  let id = self.listeners.add(listener)
  () => self.listeners.delete(id)
}

///|
/// Whether a page can be opened here: the station has a browser.
pub fn LoginPages::can(self : LoginPages) -> Bool {
  (self.browser.available)()
}

///|
/// Where the tab open for `key` is now, if one is.
pub fn LoginPages::url_of(self : LoginPages, key : String) -> String? {
  match self.tabs.get(key) {
    Some(id) if (self.browser.has_tab)(id) => self.url_now(id)
    _ => None
  }
}

///|
/// The screen of the tab open for `key`, if one is.
pub fn LoginPages::screen_of(self : LoginPages, key : String) -> String? {
  match self.tabs.get(key) {
    Some(id) if (self.browser.has_tab)(id) => Some(tab_screen(id))
    _ => None
  }
}

///|
/// The tab for `key`: the one open, else a new one at `url`. Its screen.
pub async fn LoginPages::open(self : LoginPages, key : String, url : String, options? : J) -> String {
  match self.tabs.get(key) {
    Some(had) if (self.browser.has_tab)(had) => return tab_screen(had)
    _ => ()
  }
  match self.opening.get(key) {
    Some(pending) =>
      match pending.wait() {
        Ok(s) => return s
        Err(e) => raise e
      }
    None => ()
  }
  let opening : @effect.Deferred[Result[String, Error]] = @effect.Deferred::new()
  self.opening[key] = opening
  let result = try {
    let id = (self.browser.open_tab)(url, options)
    self.tabs[key] = id
    self.urls[key] = self.url_now(id)
    (self.log)("a login's page opened in the station's browser", jo([("login", js(key))]))
    self.tell(key)
    Ok(tab_screen(id))
  } catch {
    e => Err(e)
  }
  self.opening.remove(key)
  opening.succeed(result) |> ignore
  match result {
    Ok(s) => s
    Err(e) => raise e
  }
}

///|
/// The login ended: its tab closed.
pub fn LoginPages::close(self : LoginPages, key : String) -> Unit {
  guard self.tabs.get(key) is Some(id) else { return }
  self.tabs.remove(key)
  self.urls.remove(key)
  (self.browser.close_tab)(id)
  self.tell(key)
}

///|
fn LoginPages::tell(self : LoginPages, key : String) -> Unit {
  self.listeners.each(l => l(key))
}
