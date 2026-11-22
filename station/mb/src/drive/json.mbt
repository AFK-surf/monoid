// Values as JSON, for what the drive answers.

///|
priv trait ToJ {
  j(Self) -> Json
}

///|
impl ToJ for String with j(self) {
  Json::string(self)
}

///|
impl ToJ for Bool with j(self) {
  Json::boolean(self)
}

///|
impl ToJ for Double with j(self) {
  Json::number(self)
}

///|
fn[T : ToJ] j(x : T) -> Json {
  ToJ::j(x)
}
