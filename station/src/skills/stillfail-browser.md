---
name: stillfail-browser
description: Use the station's own browser (this chat's own environment in it: Chrome, or Farview) for web work that needs a login or should look like a person's browser (sites, dashboards, consoles, anything behind a sign-in), ask a person to sign in or solve a captcha in it, and keep and reuse sign-ins through the vault.
---

# The station's browser

Each chat has a browser of its own on the station, its tabs, cookies and storage this chat's alone, gone when the chat
is archived; no other chat sees them, and you see nothing of another chat's. Get it with the `browser` tool (it starts
it if needed); what it answers says which of two engines this chat has:

- **Chrome** (a real Google Chrome with no window, this chat's environment in it, kept in memory only): the tool gives
  this chat's address of it, `ws://127.0.0.1:<port>/browser/<…>`. Drive it there with your own client:
  - chrome-devtools-mcp: `npx -y chrome-devtools-mcp@latest --wsEndpoint <that address>`
  - Playwright: `chromium.connectOverCDP("<that address>")`, then `browser.contexts()[0].newPage()` (the default
    context is this chat's environment).
  Through that address you reach this chat's environment only: what touches another chat's tabs or the browser as a
  whole is refused.
- **Farview** (a browser whose pages run on this station and draw on people's devices; its profile kept on disk until
  the chat is archived): no DevTools address, so Playwright and chrome-devtools-mcp do not drive it. The tool gives
  each tab's agent port; drive it with `agent.exe 127.0.0.1 <port> <step>...` (the path is in the tool's answer), each
  step printing the page's address, title and an outline after it: `look`, `go:<address>`, `click:<selector>`,
  `fill:<selector>=<words>`, `submit:<selector>`, `key:<key>[@<selector>]`, `back`, `forward`, `reload`, `wait:<ms>`,
  `shot:<file.png>`, `eval:<js>` (its result as JSON), `upload:<selector>=<file>[,<file>...]` (files chosen for a file
  input as a person would) and `downloads` (what the page saved, in its tab's `downloads/`). `browser` action `open`
  (with `url`) opens another tab, `close` (with `tab`) closes one, `tabs` lists them; a page's new window is a tab too.

A station gives Chrome unless its config says Farview; `browser {engine: "farview"}` or `{engine: "chrome"}`
switches this chat's browser from then on (the other's tabs end; each keeps its own sign-ins).
People see this chat's tabs in their app either way, and may close or drive them there.

Rules:

- Use it, not a Chrome or Chromium you launch yourself, for anything behind a login: sites often refuse to sign in an
  automated one, and the vault's sign-ins go only into this one.
- `sign_in`, `screen` and `computer` work the same on both engines.
- Close the tabs you are done with.
- `browser` with action `tabs` lists this chat's tabs; `stop` closes this chat's environment (its tabs and the
  cookies in it; sign-ins still granted go in again when you next ask).
- When your connection drops (the browser was restarted, the station restarted), connect again to the same address.
  A browser restarted gives this chat a new environment: sign-ins made in it by hand are gone, sign-ins still granted
  from the vault go in again.

## Sign-ins: one call, `sign_in`

To be signed in to a site in this chat's browser, open its sign-in page here and call `sign_in {site, reason}`. It
is the one way to ask:

- The vault keeps a sign-in for the site (kind `browser`: its cookies, and its passkeys): it is asked for, as
  `secret_use` does (a card the person approves); granted, it is put into this chat's browser for as long as the grant
  lasts, then taken out again (the site's newer cookies kept in the vault). You never get the cookies.
- None kept: a card asks the person to sign in. Their app fills the page from their own password manager (1Password,
  the system's autofill) and the station types it in, step by step (account, password, one-time code), and sends it;
  where only they can go on (a captcha, a code sent by mail), the card gives them the tab's screen. You never see what
  they typed. You are told in your session when the page has left its sign-in: look whether it is signed in, then call
  `sign_in {site, done: true, name, about}` (it is kept in their vault if they chose so on the card, with no other card;
  other chats then ask for it instead of signing in again; `name` and `about` as skill stillfail-vault says, so that they
  know what it is: 路由器后台登录态（经家里那台 Mac 转发到 127.0.0.1:8443）, not 127.0.0.1 登录态), or `sign_in {site, stuck: "what is left"}` in their language.
- It does not wait: go on with what does not need it, else end your turn need_human (about the card). Do not post the
  tab's screen for a sign-in yourself, and never ask for a password or a code in the chat.
- The vault's sign-in ran out (the site asks you to sign in although it was granted): sign in with the site's passkey if
  it offers one (below: the browser signs it), else `sign_in {site, again: true}`.
- Passkeys: both engines have a platform authenticator of their own (each tab of this chat's Chrome, and Farview's
  profile), so a site asking for a passkey already stored in that sign-in signs with it automatically, with no prompt,
  and one the site makes is kept with the sign-in. Never register a new passkey on a person's account unless they
  explicitly ask you to add one.
- A sign-in made before each chat had its own environment is still in the station's own profile: `secret_save {…,
  kind: "browser", browser: "station"}` reads it from there.

## Its tabs as screens (the `computer` tool)

The `computer` tool takes screenshots of a screen of the station and clicks, drags, scrolls, types and presses keys
on it, in the screenshot's pixels: a tab of this browser (`browser:<targetId>`, from `screen`) or the machine's display
(`desktop`). For web pages prefer DevTools (Playwright, chrome-devtools-mcp): they read and act on the page itself and
are faster and surer. Use `computer` for native apps on the desktop, and for what DevTools cannot reach (a browser
dialog, a canvas). A person watching sees you work; while one is driving the screen your input by coordinates is
refused, with the device they hold it from, so wait or ask them. When you are stuck, hand over as below.

On the desktop prefer an app's accessibility tree to screenshots: `computer {action: "tree", app}` (no app: the apps
running) gives its window as text, an element a line with its ref (e12). `click`, `type`, `set` (replace a field's
value) and `scroll` with `ref` then act on that element without the pointer or the focus, also behind other windows
and while a person drives the screen; `key` with `app` sends keys to that app; each answers with the app's tree again.
A big window: `tree` with `skeleton: true` first, then `tree` with `ref` for one part. Screenshots are for what has no
tree (a canvas, a game, a picture); each says its size and how it maps to the screen, and every action returns a fresh
one unless `screenshot: false`. An iOS Simulator booted here is a screen too (`simulator:<udid>`), touched where you
click.

## When a person is needed

A captcha or a consent that only a person may give (a sign-in: `sign_in`, above): do not try to get around it. Leave
the page on that step, give the tab to a person with the `screen` tool (a link that opens the tab in their still.fail
app, where they see it and type into it; post it on a line of its own and people see the screen's card), ask in the
chat with need_human ("solve the captcha"), and end your turn.
When they say it is done, carry on in the same tab.

Never ask for passwords or codes in the chat, and never type someone's credentials you were not given for that
purpose.
