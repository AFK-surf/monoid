// What an agent is doing, said in the Feishu chat it works for (station/src/feishu/status.ts, 「工作中」): a card
// posted as the turn starts, following the agent's steps at most once a second, and once the turn is over saying how
// long it took and where its steps can be read. The card is a CardKit entity, changed by its id as often as needed;
// where the app may not make those (no cardkit:card:write), a card message changed in place instead. A turn for a
// message that did not call the bot shows no card until it does more than think and read the chat; a turn that said
// nothing takes its card back.
//
// The line itself (connects/status.ts `StatusLine`): one per thread, changed at most once an interval (the first
// change at once), one change at a time and in order, only the latest of those said meanwhile, cleared ("") once the
// turn ends. Its timers run on the runtime it is made on (the surface's).

///|
pub let min_interval_ms : Int = 1_000

///|
/// connects/status.ts `StatusLine`: `show` says a status (`""`: the turn ended) at a time, and whether it was shown.
pub struct StatusLine {
  priv interval : Int
  priv rt : @effect.Runtime
  priv show : async (String, Int64) -> Bool
  /// The message that started the work, and the session's page in still.fail (where there is one), as last said.
  mut message_ts : String?
  mut page : String?
  priv mut shown : String
  priv mut wanted : String
  /// When it last changed (never, at first: the first change goes at once, whatever the clock says).
  priv mut last_at : Int64?
  priv mut timer : Bool
  priv mut sending : @effect.Deferred[Unit]?
}

///|
pub fn StatusLine::new(
  rt : @effect.Runtime,
  interval : Int,
  show : async (String, Int64) -> Bool,
) -> StatusLine {
  {
    interval,
    rt,
    show,
    message_ts: None,
    page: None,
    shown: "",
    wanted: "",
    last_at: None,
    timer: false,
    sending: None,
  }
}

///|
pub fn StatusLine::say(
  self : StatusLine,
  status : String,
  message_ts? : String? = None,
  page? : String? = None,
) -> Unit {
  if message_ts is Some(_) {
    self.message_ts = message_ts
  }
  if page is Some(_) {
    self.page = page
  }
  self.wanted = status
  if self.timer {
    return
  }
  self.timer = true
  ignore(
    self.rt.fork_daemon("feishu status", on_error=_ => self.timer = false, async fn() {
      let now = @effect.now()
      let wait = if status == "" {
        0L
      } else {
        match self.last_at {
          Some(at) => @cmp.maximum(0L, at + self.interval.to_int64() - now)
          None => 0L
        }
      }
      @effect.sleep(wait.to_int())
      self.due(@effect.now())
    }),
  )
}

///|
async fn StatusLine::due(self : StatusLine, now : Int64) -> Unit {
  self.timer = false
  if self.wanted == self.shown {
    return
  }
  self.last_at = Some(now)
  let was = self.shown
  let next = self.wanted
  // Shown as it goes: said again meanwhile, it does not go twice; not shown after all, it goes with the next.
  self.shown = next
  let before = self.sending
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.sending = Some(mine)
  match before {
    Some(d) => ignore(d.wait()) catch { _ => () }
    None => ()
  }
  let ok = try {
    let shown = (self.show)(next, now)
    if !shown && self.shown == next {
      self.shown = was
    }
    None
  } catch {
    e => Some(e)
  }
  ignore(mine.succeed(()))
  match ok {
    Some(e) => raise e
    None => ()
  }
}

///|
/// What the line needs of its surface: calls of the OpenAPI, a card posted where the thread is (its message id), and
/// whether a message called the bot (an @, a direct message, a card's answer).
pub(all) struct StatusCalls {
  api : async (String, String, JV?) -> JV
  send : async (String, String) -> String
  called : (String) -> Bool
}

///|
priv struct StatusCard {
  id : String?
  message : String?
  mut sequence : Int
}

///|
/// One thread's line. `say("")` ends it.
pub struct FeishuStatus {
  line : StatusLine
  priv calls : StatusCalls
  priv words : Words
  priv log : Log
  priv lang : String
  /// The card of the turn now (its entity, or its message where there is none), and how many times it changed.
  priv mut card : StatusCard?
  priv mut started_at : Int64?
  /// The agent posted in the thread during this turn.
  priv mut said : Bool
  /// The app may not make CardKit cards: messages stand in.
  priv mut no_entities : Bool
}

///|
pub fn FeishuStatus::new(
  rt : @effect.Runtime,
  calls : StatusCalls,
  words : Words,
  log : Log,
  lang? : String,
) -> FeishuStatus {
  let lang = match lang {
    Some(l) => l
    None => (words.station_lang)()
  }
  let me : Ref[FeishuStatus?] = Ref(None)
  let line = StatusLine::new(rt, min_interval_ms, async fn(status, now) {
    match me.val {
      Some(s) => s.show(status, now)
      None => true
    }
  })
  let s : FeishuStatus = {
    line,
    calls,
    words,
    log,
    lang,
    card: None,
    started_at: None,
    said: false,
    no_entities: false,
  }
  me.val = Some(s)
  s
}

///|
pub fn FeishuStatus::say(
  self : FeishuStatus,
  status : String,
  message_ts? : String? = None,
  page? : String? = None,
) -> Unit {
  self.line.say(status, message_ts~, page~)
}

///|
/// The agent posts in the thread.
pub fn FeishuStatus::spoke(self : FeishuStatus) -> Unit {
  self.said = true
}

///|
/// Whether a turn doing this may still be one that lets a message by: what the agent does before it says nothing.
fn FeishuStatus::idle(self : FeishuStatus, status : String) -> Bool {
  let lang = (self.words.station_lang)()
  status == tr0(self.words, lang, "station.status.thinking") ||
  status == tr0(self.words, lang, "station.status.readingChat")
}

///|
async fn FeishuStatus::show(
  self : FeishuStatus,
  status : String,
  now : Int64,
) -> Bool {
  try {
    if status == "" {
      let card = self.card
      let said = self.said
      let started_at = self.started_at.unwrap_or(now)
      self.card = None
      self.said = false
      self.started_at = None
      match card {
        Some(c) =>
          if said || !self.take_back(c) {
            self.change(
              c,
              done_card(
                self.words,
                (now - started_at).to_double(),
                self.line.page,
                self.lang,
              ),
            )
          }
        None => ()
      }
      return true
    }
    if self.started_at is None {
      self.started_at = Some(now)
    }
    match self.card {
      None => {
        if self.idle(status) &&
          (match self.line.message_ts {
            None => true
            Some(ts) => !(self.calls.called)(ts)
          }) {
          return true
        }
        self.card = Some(self.open(working_card(status)))
        return true
      }
      Some(c) => self.change(c, working_card(status))
    }
  } catch {
    e =>
      self.log.warn(
        "feishu",
        "could not say the agent's status in Feishu",
        jobj([("error", Some(js(error_words(e))))]),
      )
  }
  true
}

///|
async fn FeishuStatus::open(self : FeishuStatus, card : JV) -> StatusCard {
  if !self.no_entities {
    let made = try {
      let made = (self.calls.api)(
        "POST",
        "/open-apis/cardkit/v1/cards",
        Some(
          jobj([
            ("type", Some(js("card_json"))),
            ("data", Some(js(stringify(card)))),
          ]),
        ),
      )
      let id = match jget(jget(Some(made), "data"), "card_id") {
        Some(Str(i)) if i != "" => i
        _ => raise FeishuError("feishu gave no card_id")
      }
      Ok({
        id: Some(id),
        message: Some((self.calls.send)("interactive", entity(id))),
        sequence: 0,
      })
    } catch {
      e => Err(e)
    }
    match made {
      Ok(c) => return c
      Err(e) => {
        self.log.info(
          "feishu",
          "status as a card message: no card entities here",
          jobj([("error", Some(js(error_words(e))))]),
        )
        self.no_entities = true
      }
    }
  }
  {
    id: None,
    message: Some((self.calls.send)("interactive", inline(card))),
    sequence: 0,
  }
}

///|
/// The card's message recalled: whether it went (Feishu may refuse one too old: it stays, saying the turn is over).
async fn FeishuStatus::take_back(self : FeishuStatus, card : StatusCard) -> Bool {
  guard card.message is Some(message) else { return false }
  try {
    ignore(
      (self.calls.api)(
        "DELETE",
        "/open-apis/im/v1/messages/\{encode_uri_component(message)}",
        None,
      ),
    )
    true
  } catch {
    e => {
      self.log.info(
        "feishu",
        "status card not recalled",
        jobj([("error", Some(js(error_words(e))))]),
      )
      false
    }
  }
}

///|
async fn FeishuStatus::change(
  self : FeishuStatus,
  at : StatusCard,
  card : JV,
) -> Unit {
  match (at.id, at.message) {
    (Some(id), _) => {
      at.sequence += 1
      ignore(
        (self.calls.api)(
          "PUT",
          "/open-apis/cardkit/v1/cards/\{id}",
          Some(
            jobj([
              (
                "card",
                Some(
                  jobj([
                    ("type", Some(js("card_json"))),
                    ("data", Some(js(stringify(card)))),
                  ]),
                ),
              ),
              ("sequence", Some(jint(at.sequence))),
            ]),
          ),
        ),
      )
    }
    (None, Some(message)) =>
      ignore(
        (self.calls.api)(
          "PATCH",
          "/open-apis/im/v1/messages/\{message}",
          Some(jobj([("content", Some(js(inline(card))))])),
        ),
      )
    (None, None) => ()
  }
}
