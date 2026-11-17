///|
test "strings as JavaScript's" {
  inspect(
    @jsjson.raw_text(lower(units("ÀB İ ΑΣ@Σ ΣΑ"))),
    content="àb i̇ ας@σ σα",
  )
  inspect(
    @jsjson.raw_text(cut_points(units("a😀b😀c"), 3)),
    content="a😀b",
  )
  inspect(trim(units("\u{3000} x \u{feff}")).length(), content="1")
  inspect(email_like(units("a@b")), content="true")
  inspect(email_like(units("a@@b")), content="false")
  inspect(email_like(units("@b")), content="false")
  inspect(
    @jsjson.stringify(
      Arr([
        Num(0.1),
        Num(1.0e21),
        Num(-0.0),
        Num(1.5e-7),
        Num(123.456),
        Num(5.0e-324),
        Num(12345678901234567890.0),
      ]),
    ),
    content="[0.1,1e+21,0,1.5e-7,123.456,5e-324,12345678901234567000]",
  )
}
