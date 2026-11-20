// A person's message in a still.fail chat copied to Slack and Feishu threads its agents are in (station/src/sessions/
// cc.ts): those ticked in the composer's 抄送 menu, where each thread's bot says who wrote it on still.fail and what.
// The station's words there, not delivered to the agent; one that did not go is said in the chat.

///|
/// station/store/rows.ts STATION_AUTHOR.
pub let station_author : String = "station"

///|
/// What the bot says there: who said it on still.fail, then their words as they wrote them.
pub fn cc_text(words : Words, lang : String, who : String, said : String) -> String {
  let head = words.tr(lang, "station.cc.said", args=[("who", who)])
  if said == "" {
    head
  } else {
    "\{head}\n\n\{said}"
  }
}

///|
fn thread_ref(row : J?) -> J {
  jo([("channel", at(row, "channel").unwrap_or(Null)), ("threadTs", at(row, "threadTs").unwrap_or(Null))])
}

///|
/// A message as the store keeps it (`insertMessage`'s argument).
fn message_j(thread : J, ts : J, author_kind : String, author : String, text : String, attachments : J?) -> J {
  let fs = [("thread", thread), ("ts", ts), ("authorKind", js(author_kind)), ("author", js(author)), ("text", js(text))]
  if attachments is Some(a) {
    fs.push(("attachments", a))
  }
  jo(fs)
}

///|
async fn say_failure(w : World, thread : J, place : String, error : String) -> Unit {
  try {
    let chat = w.with_threads_j(t => t.get_thread(thread.to_json()))
    let here = at_i(Some(w.store_thread_sessions(thread)), 0)
    if chat is Null || here is None {
      return
    }
    let note = w.tr("station.cc.failed", args=[("place", place), ("error", error)])
    let ts = w.chat(str_of(at(here, "connect")).unwrap_or(""), "post", [thread_ref(Some(chat)), js(mark_notice(note)), ja([])])
    w.store_insert_message(message_j(thread, ts, station_author, station_author, note, Some(ja([])))) |> ignore
  } catch {
    again =>
      w.log("warn", "hub", "a copy's failure was not said in its chat", jo([("thread", thread), ("error", js(thrown_message(again)))]))
  }
}

///|
/// Copies `said` (and its files) by `who` (`email`) from chat `thread` to those of its Slack and Feishu threads named in
/// `to`; what did not go is said in the chat. (The threads are copied to one after another: their order is no part of
/// it, as the TypeScript's go at once.)
pub async fn cc(w : World, thread : J, who : String, email : String, said : String, files : J, to : Array[J]) -> Unit {
  let picked = []
  try {
    while true {
      try {
        let all = arr_of(Some(w.with_threads_j(t => t.cc_threads(thread.to_json())))).unwrap_or([])
        for o in all {
          let id = at(at(Some(o), "thread"), "id").unwrap_or(Null)
          if jincludes(to, id) {
            picked.push(o)
          }
        }
        break
      } catch {
        Thrown("CcSessionsUnavailable", _) as e => {
          if !w.has("prepareCcSessions") {
            raise e
          }
          w.hub("prepareCcSessions", [at(Some(w.thrown.val), "sessions").unwrap_or(Null)]) |> ignore
        }
        e => raise e
      }
    }
  } catch {
    e => {
      let m = thrown_message(e)
      w.log("warn", "hub", "copy destinations could not be prepared", jo([("thread", thread), ("error", js(m))]))
      say_failure(w, thread, "Slack/Feishu", m)
      return
    }
  }
  for o in picked {
    let target = at(Some(o), "thread")
    let connect = str_of(at(Some(o), "connect")).unwrap_or("")
    try {
      let user = (try {
        let u = w.chat(connect, "userOf", [js(email)])
        str_of(Some(u))
      } catch {
        _ => None
      })
      let named = match user {
        Some(u) =>
          match str_of(Some(w.chat(connect, "mention", [js(u)]))) {
            Some(m) => m
            None => "<@\{u}>"
          }
        None => if who == email { who } else { "\{who} (\{email})" }
      }
      let text = cc_text(w.words, w.lang.val, named, said)
      let ts = w.chat(connect, "post", [thread_ref(target), js(text), files])
      w.store_insert_message(message_j(at(target, "id").unwrap_or(Null), ts, station_author, station_author, text, Some(files)))
      |> ignore
    } catch {
      e => {
        let m = thrown_message(e)
        w.log(
          "warn",
          "hub",
          "a message was not copied to a thread of its chat",
          jo([("thread", thread), ("to", at(target, "id").unwrap_or(Null)), ("error", js(m))]),
        )
        let surface = str_of(at(target, "surface")).unwrap_or("")
        let place = if starts(surface, "feishu:") {
          "Feishu"
        } else if starts(surface, "group:") {
          "group"
        } else {
          "Slack"
        }
        say_failure(w, thread, place, m)
      }
    }
  }
}
