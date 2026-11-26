// A station shown by its mark wherever it is shown, one way: its own mark (station_mark_node's) where it has one,
// else this machine's monitor or a station's server, never nothing; as big and in the ink of where it stands
// (StationMarkAt), faint while it is away; and among others to choose from (a pick, a menu), each by that same mark.

///|
/// Where a station's mark stands, each with its one size and ink.
pub(all) enum StationMarkAt {
  /// a row of a list, a side or a section, a chooser's button: 16, in the words' ink
  Row
  /// a small label beside words (a composer's chip, a card's foot, a chat's row end): 14, muted
  Chip
  /// in a line of small words (a reference's chip, a peek's line, a tag): 11, muted
  Inline
}

///|
/// How big a station's mark is where it stands.
pub fn station_mark_side(at : StationMarkAt) -> Double {
  match at {
    Row => 16.0
    Chip => 14.0
    Inline => 11.0
  }
}

///|
/// The ink a station's mark is drawn in where it stands (one of no colour of its own), faint while it is away.
pub fn station_mark_ink(at : StationMarkAt, faint : Bool) -> Int64 {
  if faint {
    @sf.theme().p.subtle
  } else {
    match at {
      Row => @sf.theme().p.text
      Chip | Inline => @sf.theme().p.muted
    }
  }
}

///|
/// Station `address`'s mark (its `emoji` and `icon`) in `parent` where it stands (`at`), as each says now: its own
/// where it has one, else this machine's monitor or a station's server; in the ink of the words beside it (`words`,
/// where they are not the ink `at` has), faint while `faint` says it is away. A picture put up is asked for on `stint`.
#callsite(autofill(loc))
pub fn station_mark_at_node(
  parent : @view.View,
  address : () -> String,
  emoji : () -> String,
  icon : () -> String,
  at : StationMarkAt,
  words? : () -> Int64,
  faint? : () -> Bool = fn() { false },
  stint? : () -> Int = fn() { 0 },
  loc~ : SourceLoc,
) -> Unit {
  let side = station_mark_side(at)
  let ink = fn() {
    match words {
      Some(w) if !faint() => w()
      _ => station_mark_ink(at, faint())
    }
  }
  parent.pick(loc~, at_once=true, fn() {
    if @sf.has_station_mark(emoji(), icon()) {
      0
    } else if address() != "" && address() == this_machine() {
      1
    } else {
      2
    }
  }, fn(m, which) {
    match which {
      0 => @sf.station_mark_node(m, emoji, icon, side, ink, stint)
      1 => @sf.icon_node(m, "monitor", side, By(ink)) |> ignore
      _ => @sf.icon_node(m, "server", side, By(ink)) |> ignore
    }
  })
}

///|
/// A station among others to choose from (a pick's or a menu's choice): by `key` (its address, or what the list
/// chosen from names it by: its `address` then given apart), its name, and its mark as station_mark_at_node draws it
/// (a menu's size, the words' ink, faint as its words are where it cannot be chosen); what it has to say in `value` (its room, how it is reached) and why it cannot be
/// chosen in `note`.
pub fn station_choice(
  key : String,
  name : String,
  emoji : String,
  icon : String,
  address? : String = key,
  value? : String = "",
  note? : String = "",
  disabled? : Bool = false,
) -> @sf.Choice {
  @sf.choice(
    key,
    name,
    note~,
    value~,
    disabled~,
    mark=@sf.ChoiceMark::OfStation(emoji, icon, address != "" && address == this_machine(), fn() {
      station_mark_ink(Row, disabled)
    }),
  )
}

///|
/// Station `address`'s mark (its emoji and its icon) as `stations` (its workspace's, station_marks' or stations_of's)
/// name it: none where they do not, its fallback then station_mark_at_node's or station_choice's.
pub fn station_mark_in(stations : Array[Station], address : String) -> (String, String) {
  match stations.iter().find_first(fn(s) { s.address == address }) {
    Some(s) => (s.emoji, s.icon)
    None => ("", "")
  }
}
