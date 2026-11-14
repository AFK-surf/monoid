---
name: stillfail-move
description: Move chats, accounts, jobs and connects to another still.fail station of the workspace one item at a time, or a whole station (迁移聊天/迁走整台 station), and back, with station_move. Read before plan, move or back.
---

# Move to another station with station_move

A move is made of items, each of one module, each moved and moved back on its own while both stations keep working:

- `accounts`: one account's login (`share:<id>`, `key:<hash>`, `own:<id>@<station>`). A shared one stays usable here
  (this station borrows it). One that is not shared, or cannot be (Grok, Cursor, Devin, Antigravity, Kimi sign-ins), is
  gone from here: the chats here that run on it are **stopped** (held, nothing lost: what is said to them waits) until
  they move too or the account comes back. This machine's own login (`machine:`) never moves: sign in there with the
  login tool.
- `chats`: one chat, by its session key (those sharing a still.fail chat go together). It needs its accounts there.
  Moving it pauses it for seconds: its turn is waited for, it is held, its files and rows go, the other station shows
  it, its Slack or Feishu threads are re-pointed there. Nothing is posted in the chat or its threads; its agent is told
  once there, as its next turn starts. A failure before the switch leaves it working here as before.
- `jobs`: one job or service a chat had running. Stopped as its chat is held, started there once the chat is there
  (moving one chat moves its jobs right after). A job runs on one station at a time.
- `connects`: one Slack or Feishu connect, once the chats that came through it are there. Comma and single-session
  connects cannot move yet (plan says why).
- `agent-home`, `settings`, `repos`, `vault`: not built as modules yet; plan lists each with what to do instead.

How to go about it:

1. `plan {to}`: read every item, what it needs, what cannot move and why, and what moving an item alone would stop here.
   Tell the person what you found before moving anything big.
2. One chat (try an unimportant one first on real stations): `move {to, module: "chats", item: "<session key>"}`. An
   account it needs that is not there yet is named in the answer: move it first (`withNeeds: true` does it in order).
3. A batch: one `move` per item, or `withNeeds`. A whole station: `move {to, all: true}` posts a card in this chat that
   an owner or admin confirms in the still.fail app; then every item moves in order, those that cannot are listed with
   why, and it stops at the first failure and says which. Connects and logins go last by their needs.
4. `status {to}` says where each stands (`stopped` items name what they wait for).
5. `back {to: <the station it is on>, module, item}` moves it back here; an item something there still needs is
   refused, naming it: move that back first, or ask with `all`.

A station moved whole is still in the workspace afterwards: taking it out is the person's own step in the app.
