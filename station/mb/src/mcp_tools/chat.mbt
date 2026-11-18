// The agents' tools for their conversations (station/src/tools/chat.ts and slack.ts): chat_post, slack_api,
// chat_state, chat_leave, chat_history, chat_list, chat_read, session_send, chat_create, chat_archive, session_history.
// What they do is src/sessions/'s (conversations.ts, messages.ts, opened.ts, chat-archive.ts, others.ts, review.ts):
// asked of the hub's parts by name, the hub given by reference.

///|
/// What an agent says never ends as a station's notice does (sessions/chat.ts NOTICE_MARK).
pub let notice_mark : String = "\u{2063}"

///|
/// What a chat_post that did not post begins with (sessions/conversations.ts NOT_POSTED).
pub let not_posted : String = "Not posted:"

///|
/// The still.fail surface (store/rows.ts STILLFAIL_SURFACE).
pub let stillfail_surface : String = "chat"

///|
/// sessions/args.ts `jsString`.
pub fn js_string_of(v : JV) -> String {
  match v {
    Str(s) => s
    Null => "null"
    _ => stringify(v)
  }
}

///|
/// A chat on another station, by its link: read there (others.ts `readAfar`); None to read it here.
async fn afar(
  c : Ctx,
  hub : JV,
  key : String,
  tool : String,
  args : JV,
) -> JV? {
  let b = c.b
  match args.get("chat") {
    Some(Str(chat)) => {
      let station = b.ask("sessions/others.elsewhere", [hub, js(key), js(chat)])
      if !(station is Null) {
        return Some(
          b.ask("sessions/others.readAfar", [hub, js(key), station, js(tool), args]),
        )
      }
    }
    _ => ()
  }
  // (a chat handed from here to another station is read where it is now: replica/handover.ts)
  let ref = match args.get("chat") {
    Some(Str(chat)) => {
      let linked = b.ask("sessions/others.linkedSession", [js(chat)])
      match linked {
        Arr(items) =>
          match items.get(0) {
            Some(first) if !is_undef(first) && !(first is Null) =>
              js_string(Some(first))
            _ => trim_js(chat)
          }
        _ => trim_js(chat)
      }
    }
    _ => ""
  }
  if ref == "" {
    return None
  }
  let moved = b.ask("hub.store.handedTo", [js(ref)])
  if moved is Null {
    return None
  }
  Some(
    b.ask("sessions/others.readAfar", [
      hub,
      js(key),
      field(moved, "station"),
      js(tool),
      spread(args, [("chat", js(ref))]),
    ]),
  )
}

///|
/// `run` with `args`' files (and with `links` its text's local links) in folders macOS protects copied first
/// (conversations.ts `staged`), the copies removed after.
async fn with_staged(
  c : Ctx,
  hub : JV,
  key : String,
  args : JV,
  links : Bool,
  run : async (JV) -> JV,
) -> JV {
  let b = c.b
  // Nothing that could be in such a folder: as it was, not a moment later.
  if !truthy(Some(b.ask("sessions/conversations.mayStage", [hub, args, jbool(links)]))) {
    return run(args)
  }
  let staged = b.ask("sessions/conversations.staged", [
    hub,
    js(key),
    args,
    jbool(links),
  ])
  let done = field(staged, "done")
  let out = run(field(staged, "args")) catch {
    error => {
      ignore(b.invoke(done, []))
      raise error
    }
  }
  ignore(b.invoke(done, []))
  out
}

///|
/// What a tool's answer is as the text the agent sees.
fn said_text(v : JV) -> String {
  match v {
    Str(s) => s
    _ => js_string(Some(v))
  }
}

///|
/// The hub's tools, in the Rust station's order (slack_api, second).
pub fn chat_tools(c : Ctx, hub? : JV = jref("hub")) -> Array[Tool] {
  let b = c.b
  let conv = (name : String, args : Array[JV]) => b.ask(
    "sessions/conversations.\{name}",
    args,
  )
  [
    Tool::new(c.decl("chat_post"), (key, given, _) => {
      // (what an agent says never ends as a station's notice does)
      let args = match given.get("text") {
        Some(Str(t)) if index_of(t, notice_mark) >= 0 =>
          spread(given, [("text", js(replace_all(t, notice_mark, "")))])
        _ => given
      }
      // Its files and local links in a folder macOS protects copied first; links only where they become
      // attachments (still.fail chats).
      let stillfail = {
        let t = conv("target", [hub, js(key), field(args, "to")])
        jstr(jget(jget(Some(t), "thread"), "surface")) == Some(stillfail_surface)
      } catch {
        _ => false
      }
      // A held post sent by its id is staged again, as it was written.
      let held = conv("unheld", [hub, js(key), args])
      let said = said_text(
        with_staged(c, hub, key, field(held, "args"), stillfail, a => conv(
          "chatPost",
          [hub, js(key), a, held],
        )),
      )
      // A turn ended all_done (or final from before): whether the chat is finished is asked in the background.
      let kind = args.get("kind")
      if (kind is Some(Str("all_done")) || kind is Some(Str("final"))) &&
        !said.has_prefix(not_posted) {
        b.tell("sessions/review.suggestArchive", [hub, js(key)])
      }
      said
    }),
    ..slack_tools(c, hub~),
    Tool::new(c.decl("chat_state"), (key, args, _) => said_text(
      conv("chatState", [hub, js(key), args]),
    )),
    Tool::new(c.decl("chat_leave"), (key, args, _) => said_text(
      conv("chatLeave", [hub, js(key), args]),
    )),
    Tool::new(c.decl("chat_history"), (key, args, _) => said_text(
      conv("chatHistory", [hub, js(key), args]),
    )),
    Tool::new(c.decl("chat_list"), (key, args, signal) => said_text(
      b.ask("sessions/others.chatList", [hub, js(key), args, signal]),
    )),
    Tool::new(c.decl("chat_read"), (key, args, _) => {
      match afar(c, hub, key, "chat_read", args) {
        Some(v) => said_text(v)
        None => {
          let scope = b.ask("sessions/others.scopeOf", [hub, js(key)])
          said_text(
            b.ask("sessions/others.chatRead", [hub, js(key), args, jundef, scope]),
          )
        }
      }
    }),
    Tool::new(c.decl("session_send"), (key, args, _) => said_text(
      with_staged(c, hub, key, args, false, a => b.ask(
        "sessions/messages.sessionSend",
        [hub, js(key), a],
      )),
    )),
    Tool::new(c.decl("chat_create"), (key, args, _) => said_text(
      with_staged(c, hub, key, args, false, a => b.ask(
        "sessions/opened.chatCreate",
        [hub, js(key), a],
      )),
    )),
    Tool::new(c.decl("chat_archive"), (key, args, _) => said_text(
      b.ask("sessions/chat-archive.chatArchive", [hub, js(key), args]),
    )),
    Tool::new(c.decl("session_history"), (key, args, _) => {
      match afar(c, hub, key, "session_history", args) {
        Some(v) => said_text(v)
        None => {
          let scope = b.ask("sessions/others.scopeOf", [hub, js(key)])
          said_text(
            b.ask("sessions/others.sessionHistory", [hub, args, scope]),
          )
        }
      }
    }),
  ]
}

///|
/// slack_api (tools/slack.ts): any Slack Web API method, as the session's bot (or the bot of one of its Slack
/// conversations, `to`; the station's Slack bot, `bot`). What it does is conversations.ts `slackApi`.
pub fn slack_tools(c : Ctx, hub? : JV = jref("hub")) -> Array[Tool] {
  let b = c.b
  [
    Tool::new(c.decl("slack_api"), (key, args, _) => {
      let method = trim_js(
        match args.get("method") {
          None => ""
          Some(m) if is_undef(m) => ""
          Some(m) => js_string_of(m)
        },
      )
      let params = match args.get("params") {
        Some(Obj(_) as p) => p
        _ => jobj([])
      }
      let via = match args.get("to") {
        Some(Str(to)) if to != "" =>
          field(
            b.ask("sessions/conversations.target", [hub, js(key), js(to)]),
            "connect",
          )
        _ => Null
      }
      let bot = match args.get("bot") {
        Some(Str(bot)) if trim_js(bot) != "" => js(bot)
        _ => Null
      }
      said_text(
        b.ask("sessions/conversations.slackApi", [
          hub,
          js(key),
          js(method),
          params,
          via,
          bot,
          jbool(is_true(args.get("save_files"))),
        ]),
      )
    }),
  ]
}
