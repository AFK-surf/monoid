// adb/tool.ts: adb_devices (the phones people shared with every agent of this station), phone_use and phone_send, as
// the agents are told of them and what they answer.

///|
/// A tool as declared: its name, what it does, its parameters.
pub fn tool_decl(name : String, description : String, schema : J) -> J {
  jo([
    ("name", js(name)),
    ("description", js(description)),
    ("inputSchema", schema),
  ])
}

///|
fn schema_prop(kind : String, description : String) -> J {
  jo([("type", js(kind)), ("description", js(description))])
}

///|
fn schema_obj(props : Array[(String, J)], required? : Array[String]) -> J {
  let fs = [("type", js("object")), ("properties", jo(props))]
  if required is Some(req) {
    fs.push(("required", jsa(req)))
  }
  fs.push(("additionalProperties", jb(false)))
  jo(fs)
}

///|
pub let adb_devices_decl : J = tool_decl(
  "adb_devices",
  "The Android phones people shared with every agent of this station (an app from before chats' grants; a phone granted to a chat with phone_use is that chat's alone and not listed here), each with the adb serial it is reached at on this machine (127.0.0.1:<port>), its model, owner and whether adb is connected. To ask for a phone, use phone_use.",
  schema_obj([]),
)

///|
/// What the agent is told: the phones, how to use them, and how to ask for one.
pub fn listed(phones : Array[J]) -> String {
  let ask = "To use the phone of the person you work for, ask with phone_use: its card in your chat is how they grant it, to this chat alone. Never post a link to 共享调试 to ask for it."
  if phones.length() == 0 {
    return "No phone is shared with this station now. \{ask}"
  }
  let mut text = "\{pretty(ja(phones))}\n\n"
  text = text +
    "Use a phone with `adb -s <serial> …` (adb is this machine's). adb \"connected\" is ready; \"unpaired\" means its person still has to pair it with this station, on its 共享调试 page in the still.fail app on the phone (where a link to it opens); after `adb kill-server` run `adb connect <serial>` again. A phone is its owner's: use it for what they asked, and it goes when they stop sharing it. "
  text + ask
}

///|
pub let phone_use_decl : J = tool_decl(
  "phone_use",
  "Ask to debug the Android phone of the person you work for (whoever started this chat) with adb. A card in your chat says your reason; they approve it in the still.fail app for this chat, for a time, or refuse it. It does not wait: you are told in this session when it is decided, and only a grant counts, not a yes written in the chat. Called again once granted, it says how the phone is reached now (its adb server and serial, this chat's alone). Skill stillfail-jobs (Devices) says more.",
  schema_obj([
    ("reason", schema_prop("string", "What you will do on the phone and why (shown on the card).")),
    ("reask", schema_prop("boolean", "The existing request is still needed but its card is no longer pending: post a new card for the same request.")),
    ("done", schema_prop("boolean", "Hand the phone back: end this chat's grant (or its request still pending). reason is not needed with it.")),
  ]),
)

///|
pub let phone_send_decl : J = tool_decl(
  "phone_send",
  "Put a file of this machine on the phone granted to this chat (phone_use), much faster and surer than adb push over the phone's link: the phone fetches it the way it downloads a chat's file. Answers its path on the phone, in the app's own folder, which this chat's adb shell reads; pm cannot read there, so install an APK from a copy: adb … shell 'cp <path> /data/local/tmp/a.apk && pm install -r /data/local/tmp/a.apk'. Cut short (the link went), call it again: it goes on from what the phone has. Waits until the file is there.",
  schema_obj(
    [("path", schema_prop("string", "The file: an absolute path, or one in your workspace."))],
    required=["path"],
  ),
)

///|
/// `new Date(ms).toISOString()`.
pub fn iso_time(ms : Double) -> String {
  @time.format_iso_ms(ms.floor().to_int64())
}

///|
/// How a granted phone is reached now: its owner's phones lent here (`serials`), each in the grant's adb server
/// (`port`). `gone`: when the phone was last offered no longer and why. `display`: the chat's own screen on the phone,
/// or why it could not be made.
pub fn reached(
  serials : Array[J],
  port : Int?,
  gone~ : J = Null,
  display~ : J = Null,
) -> String {
  if serials.length() == 0 || port is None {
    let since = if truthy(Some(gone)) {
      let ended = text_of(at(Some(gone), "ended"))
      let why = if ended == "stopped" {
        "its app ended the share: its 共享调试 switch turned off, say"
      } else {
        "its link went: \{js_text(get(gone, "ended"))}"
      }
      " It stopped being offered \{iso_time(num_of(at(Some(gone), "at")).unwrap_or(0.0))} (\{why})."
    } else {
      ""
    }
    return "Granted, but the phone is not lent to this station right now.\{since} Its app lends it by itself while a grant is live and its 共享调试 switch is on (started again with the phone, kept up in the background); call phone_use again in a minute. Only if it stays away, ask its person to turn on 共享调试 in the app's settings on the phone (设置 › 共享调试), saying what this says."
  }
  let port = port.unwrap()
  let lines = [
    "Granted. Use this chat's adb server, with -P on every adb command (the station's own adb, 5037, does not have the phone; another server is turned away; run from under this session or its own directory, others are refused):",
  ]
  for p in serials {
    let device = if truthy(at(Some(p), "device")) {
      js_text(get(p, "device"))
    } else {
      "phone"
    }
    lines.push(
      "- \{device}: adb -P \{port} -s \{js_text(get(p, "serial"))} … (adb \{js_text(get(p, "adb"))})",
    )
  }
  lines.push(
    "To put a file on the phone, use phone_send, not adb push (much slower over the phone's link, begun again from nothing when it breaks).",
  )
  lines.push(
    "adb \"connected\" is ready; \"unpaired\": the phone needs pairing, and its card in your chat shows its person how (a card under it, in the still.fail app on the phone): leave it to the card, do not send them to the phone's settings, and you are told in this session when it connects. Never adb kill-server on it. A phone is its owner's: use it for what they asked.",
  )
  if truthy(Some(display)) {
    lines.push("")
    lines.push(displayed(display))
  }
  lines.join("\n")
}

///|
/// How the agent works on the chat's own screen of the phone (or why there is none).
pub fn displayed(display : J) -> String {
  if has(display, "failed") {
    return "This chat's own screen on the phone could not be made (\{js_text(get(display, "failed"))}), so only the phone's own screen is there, which its person may be using: ask them in the chat before you operate it (installing, reading logs and other commands that touch no screen need no asking). Call phone_use again to try again."
  }
  let f = (k : String) => js_text(get(display, k))
  let id = f("id")
  [
    "This chat has a screen of its own on the phone: display \{id} (\{f("width")}x\{f("height")}, density \{f("density")}), apart from the phone's own screen, which its person keeps using. Work on it, not on theirs, unless they ask:",
    "- Start an app on it: `adb … shell am start --display \{id} -n <package>/<activity>` (or `-a android.intent.action.MAIN -c android.intent.category.LAUNCHER <package>`; `cmd package resolve-activity --brief <package>` names its activity). An app is on one screen at a time: one the person has open moves over, so prefer apps they are not using.",
    "- Touch and type there: `adb … shell input -d \{id} tap <x> <y>`, `swipe`, `text`, `keyevent BACK` (it has no navigation bar and shows no keyboard: `text` types into the field it focused, ASCII only).",
    "- Its picture: `adb … exec-out screencap -d \{f("surface")} -p > shot.png` (the id screencap takes for it), then look at the file.",
    "It closes with the apps on it when you hand the phone back (phone_use done: true, do that once finished), when the grant ends, or after \{num_text(idle_ms / 60000.0)} minutes of no adb use; phone_use makes a new one then. While it is up, the phone's notification names this chat.",
  ].join("\n")
}

///|
/// phone_use over the grants, and how a granted phone is reached (`reach`).
pub async fn phone_use(
  grants : PhoneGrants,
  reach : async (String, String) -> String,
  session : String,
  args : J,
) -> String {
  if at(Some(args), "done") is Some(Bool(true)) {
    let ended = grants.release(session)
    return if ended.length() == 0 {
      "This chat holds no phone grant or request: nothing to hand back."
    } else {
      "Handed back: \{ended.map(r => "\{r.id()} (\{r.owner()}'s phone)").join(", ")}. adb no longer reaches it; ask with phone_use again if you need it later."
    }
  }
  let reason = str_of(at(Some(args), "reason")).unwrap_or("")
  let mut r = grants.ask(
    session,
    reason,
    reask=at(Some(args), "reask") is Some(Bool(true)),
  )
  if r.status() == "pending" {
    let pending = grants.card_pending(r)
    r = grants.get(r.id()).unwrap_or(r)
    if r.status() == "pending" && pending == Some(false) {
      return "The phone request \{r.id()} is still pending, but its card is no longer pending. If it is still needed, call phone_use again with the same reason and reask: true."
    }
  }
  if r.status() == "granted" {
    return reach(r.owner(), r.id())
  }
  said(r)
}
