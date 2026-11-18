---
name: stillfail-apps
description: Create, change, version and roll back still.fail station apps (named .mbui widgets or .wasm mini-programs kept on the station, with their own shared document store and a model to ask), and post them in chats. Use when people want a small app or tool that lasts, is shared across chats and devices, keeps data, or should be updated in place.
---

# Station apps

A station app is a `.mbui` widget (JSON, optionally with an embedded wasm controller) or a standalone `.wasm`
mini-program, written exactly as skill `stillfail-viz` says, but **named and kept on the station** of your chat:

- one app can be shown in many chats and on every device, and you change it in place (everyone showing it reloads);
- each app has its own **document store** (collections of JSON documents) that every chat and device showing it
  shares; a change is pushed to every open widget;
- its widget can ask **the model of the chat it is shown in** for a text completion; the station asks it with that
  chat's profile, its key or its login (the widget never sees either).

Apps belong to the chat's workspace on this station. Use an app when something should last, be shared, keep data or be
updated later; use a plain attached `.mbui` (skill `stillfail-viz`) for a one-off figure.

## Make one

1. Write the file in your working directory: `todo.mbui` (or `game.wasm`). Bind a `.mbui` to its app with a top-level
   `"app": "<id>"` (the id you save it under; leave it out or make it equal, anything else is refused). A standalone
   `.wasm` is bound by its link.
2. Save it: `app_save {id: "todo", title: "待办", file: "todo.mbui", note: "first version"}`. The id is
   `^[a-z0-9][a-z0-9-]{0,39}$`. `note` is required: one line saying what this version changes. The answer gives its
   `rev` and the link to post.
3. Post it in the chat with a link on its own line: `[待办](sf-app:todo)`. The chat loads the station's **current**
   version of `todo` and follows it as it changes. `[待办 v2](sf-app:todo@2)` pins version 2. You can still attach the
   file instead (`chat_post files=[…]`), as for any widget; it is then bound by its `"app"` field.
   Apps are an experimental feature of the still.fail app: a person sees one inline and uses it only with
   设置 › 实验性功能 › 站点应用 on, on their device; otherwise its link shows as a plain link. Say so when you post
   one to someone who may not have turned it on.

## Change it: versions

- Every `app_save` makes a new, immutable version (`rev` 1, 2, 3…) and makes it current. Nothing is overwritten.
- Before changing an app someone else may have changed, read it and save on top of what you read: `app_versions {id}`
  says the newest `rev`; save with `base_rev: <that rev>`. If the app moved on meanwhile, the save is refused (409)
  instead of overwriting the other change: fetch the newer version's file
  (`app_versions {id, rev: N, to: "todo.mbui"}`) and redo your change on it.
- `app_versions {id}`: every version (rev, note, by, when, size, sha256, schema) and the history of which was current;
  `app_versions {id, rev, to}` also writes version `rev`'s file to path `to` (to read or start from it).
- Roll back: `app_publish {id, rev: 3, note: "back to 3: 4 broke the list"}` makes version 3 current again (recorded
  as its own step; the versions stay as they are). `app_publish` with the newest rev goes forward again.
- Keep the old file around only if useful; the station keeps every version whole.

## Its data

- Documents: `collection` and `doc` ids `^[A-Za-z0-9_.-]{1,64}$`, each document any JSON value up to 64 KiB, at most
  1000 documents a collection and 100 collections an app. They are shared by all versions of the app.
- From your tools: `app_data {id, op: "list", collection}`, `{op: "get", collection, doc}`,
  `{op: "set", collection, doc, data, base?}` (`base`: the document's rev you read, 0 for new; refused if it changed),
  `{op: "delete", collection, doc}`. Every write is pushed to open widgets.
- **Schema**: when a version reads its data in a new shape, give it `"schema": <int>` at the top of the `.mbui` (or
  `schema` in `app_save`). The station keeps the highest schema made current and refuses to make current a version with
  a lower one (it would misread newer documents) unless you pass `force: true`. Each document records the schema it was
  written under. Raise the schema only when the shape changes, and migrate old documents with `app_data` if needed.

## What its widget can do

A bound widget's data and model calls go to the station that holds the chat.

### Wasm host imports (module `mbui` or `env`)

All are asynchronous. Each returns a request id (i32 ≥ 1, or 0 when the widget is not bound to an app); the answer
arrives later as a call of your exported `mbui_event`, its input JSON (read with `input_len` / `input_copy`):

- `db_list(coll_ptr, coll_len) -> i32` → `{"type":"app","req":N,"ok":true,"op":"docs","docs":[{"id":"…","data":…,"rev":1,…}]}`
- `db_put(coll_ptr, coll_len, id_ptr, id_len, json_ptr, json_len) -> i32` (the document as JSON)
- `db_delete(coll_ptr, coll_len, id_ptr, id_len) -> i32`
- `llm(json_ptr, json_len) -> i32`, the JSON `{"system"?: "…", "prompt": "…", "max_tokens"?: N}` →
  `{"type":"app","req":N,"ok":true,"op":"llm","text":"…"}`
- a failure: `{"type":"app","req":N,"ok":false,"error":"…"}` (the error says what to do; show it)
- a change pushed by the station (another device, chat or agent wrote): `{"type":"app-doc","collection":"…","id":"…","deleted":false}`;
  list the collection again to show it.

### Declarative `.mbui` (no wasm)

- A `button` with `"llm": {"prompt": "Summarise {notes}", "into": "summary"}` asks the chat's model and puts the answer
  text in `state.summary`; `{key}` in the prompt is replaced by `state[key]`.

### The model

It is the chat's own profile, with the chat's model (else the profile's). These can answer:

- a Claude Code or Codex profile, a subscription's login or a key: one text-only turn of that runtime, with no tools,
  no files and nothing kept after it (slower than a key's provider: seconds to start);
- a DeepSeek Harness profile with a key whose provider speaks chat completions: asked over HTTP.

Any other profile gets an error saying so; show the app in a chat on one of these. Prompts up to 32 KiB; answers up to
4096 tokens (512 by default) from a key's provider, where `max_tokens` holds, and of a bounded length from Claude Code
or Codex, where it does not. 60 s at most, 4 at once in a workspace; keep them short.

## Rules

- Say in `note` what changed, every time; people roll back by it.
- Never put secrets in an app or its documents: every member of the workspace can read them.
- An app is the workspace's: change one someone else made only when asked, with `base_rev`.
