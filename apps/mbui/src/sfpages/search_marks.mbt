// A search's words marked in the message it opened a chat at: the chat opens with the message's top under the bar, its
// first word put in the list's middle when it lies low (past 80% of the page); each of the words in it is bold with a
// hand-drawn stroke under it, drawn in one after another, kept for as long as the chat shows. In the chat's own find,
// every match is coloured in with a highlighter, still, and only the occurrence the reader is at has the stroke, drawn
// in as they get there.

///|
/// The last staggered stroke; any further strokes draw in with it.
let found_last_step : Int = 12

///|
/// How long the strokes are drawn in for.
pub let found_draw_ms : Double = @sf.strokes_ms(found_last_step)

