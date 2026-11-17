// What the station needs of a chat platform, as far as it is the station's own logic (station/src/sessions/chat.ts):
// the mark a station's own words end with, a message split for Slack's size, a tool call said for the status line.

///|
/// What a station's own words in a thread end with as they are posted (U+2063), and nothing an agent posts does.
pub let notice_mark : String = "\u{2063}"

///|
pub fn mark_notice(text : String) -> String {
  if ends(text, notice_mark) {
    text
  } else {
    text + notice_mark
  }
}

///|
pub fn is_notice(text : String) -> Bool {
  ends(trim_end(text), notice_mark)
}

///|
/// `callApi`: a surface without an API refuses.
pub async fn call_api(w : World, connect : String, method : String, params : J) -> J {
  if w.hub("chatHasApi", [js(connect)]) is Bool(false) {
    raise fail_("\{method}: this conversation has no API")
  }
  w.ask("chat.api", [js(connect), js(method), params])
}

///|
/// Splits text for Slack's message size, preferring paragraph, then line boundaries; lengths in code points.
pub fn split_for_slack(text : String, limit : Int) -> Array[String] {
  let chunks = []
  let mut rest = chars(text)
  while rest.length() > limit {
    let window = rest[0:@cmp.minimum(limit, rest.length() - 1) + 1].to_array()
    let last = (needle : Array[String]) => {
      let mut i = window.length() - needle.length()
      let mut found : Int? = None
      while i >= 0 {
        let mut same = true
        for k in 0..<needle.length() {
          if window[i + k] != needle[k] {
            same = false
            break
          }
        }
        if same {
          found = Some(i)
          break
        }
        i -= 1
      }
      found
    }
    let half = limit.to_double() / 2.0
    let mut cut = last(["\n", "\n"]).unwrap_or(0)
    if cut.to_double() < half {
      cut = last(["\n"]).unwrap_or(0)
    }
    if cut.to_double() < half {
      cut = limit
    }
    chunks.push(rest[0:@cmp.minimum(cut, rest.length())].to_array().join(""))
    let mut next = cut
    while next < rest.length() && rest[next] == "\n" {
      next += 1
    }
    rest = if next >= rest.length() { [] } else { rest[next:].to_array() }
  }
  if rest.length() > 0 || chunks.length() == 0 {
    chunks.push(rest.join(""))
  }
  chunks
}

///|
/// A tool call in words for the status line, by the tool's name, in the station's language.
pub fn tool_status(words : Words, lang : String, tool : String) -> String {
  let low = lower(tool)
  let mut name = low
  if starts(low, "mcp__") {
    let rest = slice(low, 5)
    let at = index_of(rest, "__")
    name = if at >= 0 { slice(rest, at + 2) } else { low }
  }
  let n = name
  let any = (ps : Array[String]) => ps.iter().any(p => starts(n, p))
  let key = if any(["read", "grep", "glob", "ls", "list", "view", "search_files", "stat"]) {
    "station.status.readingFiles"
  } else if any(["edit", "multiedit", "write", "apply_patch", "notebookedit", "delete", "copy"]) {
    "station.status.editingFiles"
  } else if any(["bash", "shell", "exec", "exec_command", "local_shell", "unified_exec", "run"]) {
    "station.status.runningCommand"
  } else if any(["websearch", "web_search", "search_query", "image_query"]) {
    "station.status.searchingWeb"
  } else if any(["webfetch", "fetch", "browse"]) {
    "station.status.readingWeb"
  } else if any(["task", "agent", "spawn"]) {
    "station.status.delegating"
  } else if any(["slack"]) {
    "station.status.readingSlack"
  } else if any(["chat_", "feishu"]) {
    "station.status.readingChat"
  } else if any(["todowrite", "update_plan", "plan"]) {
    "station.status.planning"
  } else {
    "station.status.working"
  }
  words.tr(lang, key)
}

///|
/// A conversation address as the agent sees and names it (agents/instructions.ts `threadAddress`).
pub fn thread_address(channel : String, thread_ts : String) -> String {
  "\{channel}/\{thread_ts}"
}

///|
fn all_in(s : String, ok : (Int) -> Bool) -> Bool {
  if s == "" {
    return false
  }
  for i in 0..<s.length() {
    if !ok(s.unsafe_charcode_at(i)) {
      return false
    }
  }
  true
}

///|
fn alnum(c : Int) -> Bool {
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
}

///|
/// agents/instructions.ts `parseThreadAddress`.
pub fn parse_thread_address(value : String) -> (String, String)? {
  let v = trim(value)
  let at = index_of(v, "/")
  if at < 0 {
    return None
  }
  let channel = slice(v, 0, b=at)
  let ts = slice(v, at + 1)
  let feishu_ts = if starts(ts, "omt_") {
    all_in(slice(ts, 4), alnum)
  } else if starts(ts, "om_") {
    all_in(slice(ts, 3), alnum)
  } else {
    false
  }
  if starts(channel, "oc_") && all_in(slice(channel, 3), alnum) && feishu_ts {
    return Some((channel, ts))
  }
  if channel.length() == 16 && all_in(channel, c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) && ts == channel {
    return Some((channel, ts))
  }
  let dot = index_of(ts, ".")
  if dot < 0 {
    return None
  }
  let secs = slice(ts, 0, b=dot)
  let micros = slice(ts, dot + 1)
  let digit = (c : Int) => c >= '0' && c <= '9'
  let ok = all_in(channel, c => (c >= 'A' && c <= 'Z') || digit(c)) && all_in(secs, digit) && all_in(micros, digit)
  if ok {
    Some((channel, ts))
  } else {
    None
  }
}
