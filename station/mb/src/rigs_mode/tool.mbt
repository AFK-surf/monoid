// station_use (rigs/tool.ts): how a chat's agent asks for one of the workspace's stations that only run tasks (a rig:
// requests.mbt), and hands it back.

///|
pub let rig_use_name : String = "station_use"

///|
pub let rig_use_description : String = "Ask to use a station of this workspace that only runs tasks (station_list says mode: \"tasks\" for it, with whose it is and whether this chat may use it). A whole station needs no asking, nor one whose owner turned 免批准 on. A card in your chat says your reason, and its owner (not necessarily the person you work for) approves it for this chat, for a time, or refuses it. It does not wait: you are told in this session when it is decided, and only a grant counts, not a yes written in the chat. Once granted, use it as any station, by its name, until the grant ends: what this chat runs there is stopped then. Skill stillfail-jobs (Another station) says more."

///|
/// `RIG_USE`: the tool as it is declared (name, description, inputSchema).
pub fn rig_use() -> Json {
  let str_prop = (description : String) => jobj([("type", jstr("string")), ("description", jstr(description))])
  jobj([
    ("name", jstr(rig_use_name)),
    ("description", jstr(rig_use_description)),
    (
      "inputSchema",
      jobj([
        ("type", jstr("object")),
        (
          "properties",
          jobj([
            ("station", str_prop("The tasks-only station: its name from station_list (any case), or its id.")),
            ("reason", str_prop("What you will run there and why (shown on the card to its owner).")),
            (
              "timeout",
              jobj([
                ("type", jstr("object")),
                (
                  "description",
                  jstr(
                    "How long the grant should last (the owner may choose another): idle (ends once this chat has not used that station that long) or fixed, in whole minutes from 1 minute to 30 days. Default: idle, 1 hour.",
                  ),
                ),
                (
                  "properties",
                  jobj([
                    ("kind", jobj([("type", jstr("string")), ("enum", jarr([jstr("idle"), jstr("fixed")]))])),
                    ("seconds", jobj([("type", jstr("integer"))])),
                  ]),
                ),
                ("required", jarr([jstr("kind"), jstr("seconds")])),
                ("additionalProperties", jbool(false)),
              ]),
            ),
            (
              "done",
              jobj([
                ("type", jstr("boolean")),
                (
                  "description",
                  jstr(
                    "Hand it back: end this chat's grant of it (or its request still pending). With no station named, every one this chat holds.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        ("additionalProperties", jbool(false)),
      ]),
    ),
  ])
}

///|
/// What the tool asks (rigs/tool.ts `RigUse`): a request asked (or the one already open said again), and every grant
/// handed back.
pub(all) struct RigUse {
  ask : async (String, String, String, Json?) -> String
  done : async (String, String) -> String
}

///|
/// The tool run for `session` with `args` (rigs/tool.ts `rigTools`' `run`): what the agent is told.
pub async fn rig_use_run(use_ : RigUse, session : String, args : Json) -> String {
  let a = Some(args)
  let rig = match get(a, "station") {
    Some(String(s)) => js_trim(s)
    _ => ""
  }
  if get(a, "done") is Some(True) {
    return (use_.done)(session, rig)
  }
  if rig == "" {
    raise Thrown("Error", "station is required (its name from station_list)")
  }
  let t = get(a, "timeout")
  let timeout = if is_objectish(t) {
    let out = []
    put(out, "kind", get(t, "kind"))
    put(out, "seconds", get(t, "seconds"))
    Some(jobj(out))
  } else {
    None
  }
  let reason = match get(a, "reason") {
    Some(String(s)) => s
    _ => ""
  }
  (use_.ask)(session, rig, reason, timeout)
}
