// `String.prototype.localeCompare` as these parts use it (an app's name, a bundle id): ICU's root collation.

///|
/// `a.localeCompare(b)`: below, at or above 0.
pub fn locale_compare(a : String, b : String) -> Int {
  @jsjson.locale_compare(a, b)
}
