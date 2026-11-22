// Timing constants and curves shared by node-based send flights (`message_words_node`, `composer_node`, `new_chat`).

///|
/// What flies to the `i`th quote of the message words are sent to (as file_key says a file: "upload:<id>").
pub fn quote_key(i : Int) -> String {
  quote_prefix + i.to_string()
}

///|
/// What flies to the picture in the `i`th quote: each quote has its own picture even when several name one file.
pub fn quote_picture_key(i : Int) -> String {
  quote_picture_prefix + i.to_string()
}

///|
let quote_picture_prefix : String = "quote-picture:"

///|
/// Whether `key` is what flies to a quote's own picture (quote_picture_key's).
pub fn is_quote_picture_key(key : String) -> Bool {
  key.has_prefix(quote_picture_prefix)
}

///|
let quote_prefix : String = "quote:"

///|
/// How long the words take to their place, the share of it they fly (the rest they settle), and from when they
/// settle (FLY, SETTLE).
pub let flight_ms : Double = 600.0

///|
/// How long the words wait over the field for their row; it not come by then, they go.
pub let flight_wait_ms : Double = 2000.0

///|
let flight_fly : Double = 0.8

///|
let flight_settle : Double = 0.24

///|
/// Legacy no-op kept for callers in `sfpages/new_chat.mbt`.
pub fn flight_carry_gone(_from : String) -> Unit {
  ()
}

///|
pub fn flight_across(p : Double, desk : Bool) -> Double {
  @ui.Flight.at(dmin(dmin(p / fly_share(desk), 1.0) / 0.88, 1.0))
}

///|
pub fn flight_up(p : Double, desk : Bool) -> Double {
  @ui.Flight.at(dmax((dmin(p / fly_share(desk), 1.0) - 0.12) / 0.88, 0.0))
}

///|
/// The desktop's flight is the web's: 520 ms, flown the whole of it, its bubble's ground and
/// its time coming in as it goes across; the phone's 600, flown over 80%, settling from 24%.
pub fn flight_len(desk : Bool) -> Double {
  if desk {
    flight_desk_ms
  } else {
    flight_ms
  }
}

///|
pub let flight_desk_ms : Double = 520.0

///|
/// How long the composer words were sent from takes to come down once they let go of it, its room with it
/// (composer_hold): words sent's own, set with their flight's (sf/motion.mbt kind 4), not a Move's by its way.
pub let sent_down_ms : Double = 300.0

///|
pub fn fly_share(desk : Bool) -> Double {
  if desk {
    1.0
  } else {
    flight_fly
  }
}

///|
/// How settled it is (its time and the rest of its row coming in), and how much of its bubble's ground shows.
pub fn flight_settled(p : Double, desk : Bool) -> Double {
  if desk {
    return flight_across(p, desk)
  }
  @ui.Out.at(dclamp((p - flight_settle) / (1.0 - flight_settle), 0.0, 1.0))
}

///|
pub fn flight_ground(p : Double, desk : Bool) -> Double {
  if desk {
    return flight_across(p, desk)
  }
  dclamp((p - flight_settle) / (flight_fly - flight_settle), 0.0, 1.0)
}

///|
/// How long words sent take over a way `points` far: as their flight takes over a sent message's usual way
/// (flight_len, 200 points: from a phone's field across to its bubble), longer or shorter as a Move of it is
/// (@ui.move_ms: the further the longer, not in proportion).
pub fn flight_way_ms(desk : Bool, points : Double) -> Double {
  (flight_len(desk) * @ui.move_ms(points) / @ui.move_ms(flight_way_points)).round()
}

///|
/// The longest words sent take to their place, however far (a phone's flight over a Move's longest way): any flight is
/// over by then.
pub let flight_most_ms : Double = (flight_ms * @ui.move_most_ms / @ui.move_ms(flight_way_points)).round()

///|
/// A sent message's usual way from where it was typed to its bubble (points): what flight_len is the length of.
let flight_way_points : Double = 200.0

///|
/// How long a new chat's first words take to their place (as long as any words sent: flight_len), from how long after
/// their row is laid out (on a phone).
pub let flight_carry_ms : Double = flight_desk_ms

///|
pub let flight_carry_after_ms : Double = 90.0

///|
/// Words sent from a chat's composer made as nodes, by the chat (its composer's key): the moment they were sent
/// (sent_out_told).
let sent_out_told_at : Map[String, Double] = Map([])

///|
/// Words sent from chat `chat`'s composer made as nodes at `at` (its node's cause's moment): its field's hint and caret
/// away for sent_out_away_ms from then.
pub fn sent_out_told(chat : String, at : Double) -> Unit {
  sent_out_told_at[chat] = at
}

///|
/// How long the field's hint and caret are away as words are sent from a chat's page made as nodes: till their flight
/// (flight_desk_ms, linear from the press) is half way up and out of it (flight_up at 0.5), the first
/// moment it is, as near as the clock's numbers tell.
pub fn sent_out_away_ms() -> Double {
  let mut lo = 0.0
  let mut hi = 1.0
  for _ in 0..<60 {
    let mid = lo + (hi - lo) / 2.0
    if flight_up(mid, true) >= 0.5 {
      hi = mid
    } else {
      lo = mid
    }
  }
  hi * flight_desk_ms
}

///|
/// How long the composer's ground keeps the shape it had as words were sent from it on a chat's page made as nodes,
/// before it comes down with the list: till what flies out of it begins its rise (`sent_up_late` of `flight_desk_ms`).
pub let sent_out_hold_ms : Double = 0.12 * flight_desk_ms

///|
/// What sent_out_told kept, forgotten as a run starts.
pub fn sent_out_reset() -> Unit {
  sent_out_told_at.clear()
}
