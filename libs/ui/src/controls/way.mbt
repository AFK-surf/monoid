// A way to where something is (the web's crumbs: the files page's on a phone, the folder picker's, the station
// picker's): the places over it, each a way back to it, in a line that neither scrolls nor wraps.

///|
/// How a way looks: its line, each step's box, a step's words and the last's (where it is), the chevrons between and
/// their ink.
pub(all) struct WayLook {
  line : @ui.Style
  step : @ui.Style
  words : @ui.TextStyle
  here : @ui.TextStyle
  chevron : Double
  chevron_ink : Int64
}

///|
/// A step and the chevron before it, in a line.
// kept across runs: a value (no field of it changes)
let way_part : @ui.Style = @ui.css("row align=ACenter")

///|
/// The last's words: cut short only where they alone have not the room.
// kept across runs: a value (no field of it changes)
let way_last : @ui.TextStyle = @ui.text_style(w=Cut)

///|
/// What stands for those that left the line.
pub let way_more : String = "…"
