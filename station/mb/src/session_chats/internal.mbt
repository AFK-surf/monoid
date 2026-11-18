// The station's own chat (station/src/sessions/internal.ts): conversations on its pages, one more chat platform to the
// agent. Every chat lives in one channel; its thread_ts is its address; the messages are the store's.

///|
/// The connect id the station's own chat goes by (store/rows.ts STILLFAIL_CONNECT).
pub let internal_connect : String = "chat"

///|
pub let internal_channel : String = "CHAT"

///|
let former_channel : String = "EMBER"

///|
pub fn is_internal_channel(channel : String) -> Bool {
  channel == internal_channel || channel == former_channel
}

///|
pub let chat_key_prefix : String = "chat"

///|
/// A chat's session key from its id: the one already made with `made`, else a new one.
pub fn chat_key(id : String, made? : (String) -> Bool = _ => false) -> String {
  for p in [internal_connect, chat_key_prefix] {
    let k = "\{p}:\{id}"
    if made(k) {
      return k
    }
  }
  "\{chat_key_prefix}:\{id}"
}

///|
/// `sessions/<its key's first part>/<the rest>/workspace` under the station's data (path.join's way: one separator).
pub fn chat_workspace(data_dir : String, key : String, sep? : String = "/") -> String {
  let at = index_of(key, ":")
  join_path([data_dir, "sessions", slice(key, 0, b=at), slice(key, at + 1), "workspace"], sep~)
}

///|
pub let internal_bot_user : String = "UEMBER"

///|
/// The ts handed out last, in microseconds: they only go up within the program.
let last_micros : Ref[Double] = Ref::new(0.0)

///|
/// A Slack-style timestamp ("seconds.micros") at `now_ms`, strictly increasing within the program.
pub fn next_ts_at(now_ms : Double) -> String {
  let next = @cmp.maximum(last_micros.val + 1.0, now_ms * 1000.0)
  last_micros.val = next
  let secs = (next / 1000000.0).floor()
  let micros = next - secs * 1000000.0
  let m = num_text(micros)
  let pad = StringBuilder::new()
  for _ in m.length()..<6 {
    pad.write_char('0')
  }
  "\{num_text(secs)}.\{pad}\{m}"
}

///|
/// The ts handed out last (for a harness that runs both).
pub fn reset_ts(micros : Double) -> Unit {
  last_micros.val = micros
}

///|
/// An internal chat's post: nothing to send anywhere, only the ts it is recorded under (`InternalChat.post`).
pub fn internal_post(channel : String, thread_ts : String, now_ms : Double) -> String raise Thrown {
  if !is_internal_channel(channel) {
    raise fail_("no still.fail chat \{channel}/\{thread_ts}")
  }
  next_ts_at(now_ms)
}

///|
/// `InternalChat.userName`: a page user's name ("local": 管理员), none for the bot.
pub fn internal_user_name(user : String) -> String? {
  if user == internal_bot_user {
    None
  } else if user == "local" {
    Some("管理员")
  } else {
    Some(user)
  }
}

///|
/// path.join's way with absolute and relative parts (no `..` resolved but what join resolves: `.` and empty parts).
pub fn join_path(parts : Array[String], sep? : String = "/") -> String {
  let joined = parts.filter(p => p != "").join(sep)
  if joined == "" {
    return "."
  }
  normalize_path(joined, sep~)
}

///|
/// path.normalize (POSIX).
pub fn normalize_path(p : String, sep? : String = "/") -> String {
  if p == "" {
    return "."
  }
  let absolute = starts(p, sep)
  let trailing = ends(p, sep)
  let out : Array[String] = []
  for part in split(p, sep) {
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if out.length() > 0 && out[out.length() - 1] != ".." {
        out.pop() |> ignore
      } else if !absolute {
        out.push("..")
      }
      continue
    }
    out.push(part)
  }
  let mut body = out.join(sep)
  if body == "" && !absolute {
    body = "."
  }
  if trailing && body != "" && body != "." {
    body = body + sep
  } else if trailing && body == "." {
    body = "." + sep
  }
  if absolute {
    sep + body
  } else {
    body
  }
}
