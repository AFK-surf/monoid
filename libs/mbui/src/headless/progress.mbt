// The progress bar: how far some work has come, read out a progress bar called by its label with where it is between
// its least and its most and its words (`value_text`), or with no number while how far is not known (`value` None:
// indeterminate). It takes no press and no focus. `finishing`: the work done, the look running the bar to its end (a
// page loaded): read out and read as whole from then, however far `value` said, so the look's last run and what a
// screen reader hears agree. Controlled (headless.mbt, State): `value` and `finishing` are its caller's; nothing of it is
// kept here.

///|
/// A progress bar as its look reads it: each a reading, followed where a binding reads it.
pub struct Progress {
  priv now : () -> Double?
  priv min : Double
  priv max : Double
  priv ending : () -> Bool
}

///|
/// Its value now, held within its range; none while how far is not known (and not finishing). Finishing, its most.
pub fn Progress::value(self : Progress) -> Double? {
  if (self.ending)() {
    return Some(self.max)
  }
  match (self.now)() {
    Some(v) => Some(slider_clamp(v, self.min, self.max))
    None => None
  }
}

///|
/// How far along its range it is now (`0.0` at its least … `1.0` at its most); `0.0` while indeterminate, `1.0` while
/// finishing.
pub fn Progress::part(self : Progress) -> Double {
  let span = self.max - self.min
  match self.value() {
    Some(v) if span > 0.0 => slider_clamp((v - self.min) / span, 0.0, 1.0)
    Some(_) => 1.0
    None => 0.0
  }
}

///|
/// Whether how far it has come is not known now (`value` None, not finishing): a look's running stripe.
pub fn Progress::indeterminate(self : Progress) -> Bool {
  self.value() is None
}

///|
/// Whether the work is done and the bar runs to its end (as its caller says).
pub fn Progress::finishing(self : Progress) -> Bool {
  (self.ending)()
}

///|
/// How a progress bar's value is read out by default: the share of its range, a whole percent.
fn progress_percent(v : Double, min : Double, max : Double) -> String {
  let span = max - min
  let share = if span > 0.0 { slider_clamp((v - min) / span, 0.0, 1.0) } else { 1.0 }
  (share * 100.0).round().to_int().to_string() + "%"
}

///|
/// A progress bar in `parent` (`parent` itself where `in_node`), called `label`, at `value()` along `min` … `max` (None:
/// how far is not known), read out by `value_text` (by default a whole percent of its range); `finishing` while the
/// work is done and the look runs it to its end. `look` is run once as it is made, given its node and what it reads of
/// it: all that is drawn of it and how it is laid out. Its node is made at `loc` (`made_for` where a library's part over
/// it was asked for), as the button's is. The node.
#callsite(autofill(loc))
pub fn progress(
  parent : @view.View,
  value : () -> Double?,
  look : (@view.View, Progress) -> Unit,
  min? : Double = 0.0,
  max? : Double = 100.0,
  value_text? : (Double) -> String,
  label? : () -> String = fn() { "" },
  finishing? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let p : Progress = { now: value, min, max, ending: finishing }
  let text_of = match value_text {
    Some(f) => f
    None => fn(v : Double) { progress_percent(v, min, max) }
  }
  let setup = fn(v : @view.View) {
    look(v, p)
    v.says(By(fn() {
      match p.value() {
        Some(at) => Some(@view.said(ProgressBar, label=label(), value=text_of(at), range=(min, at, max)))
        None => Some(@view.said(ProgressBar, label=label()))
      }
    }))
    |> ignore
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}
