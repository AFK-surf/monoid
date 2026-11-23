///|
test "a script's appsaid: what the app's own native call says from there on, as a host comes to say it" {
  let t = Tester::new(fn(c) { c.text("said: " + @hostapi.app_said("probe")) |> ignore }, w=300.0, h=100.0)
  t.set_app_said("probe", "before")
  t.draw()
  assert_true(t.find("said: before") is Some(_))
  let logs = t.drive("appsaid probe {\"doing\":\"x y\"}\nexit")
  assert_true(logs.iter().any(fn(line) { line == "EXIT 0" }), msg=logs.join("\n"))
  t.draw()
  assert_true(t.find("said: {\"doing\":\"x y\"}") is Some(_))
}

///|
test "a script's appsaid with no text to say fails, saying how it is written" {
  let t = Tester::new(fn(c) { c.text("Present") |> ignore })
  let logs = t.drive("appsaid probe\nexit")
  assert_true(logs.iter().any(fn(line) { line == "EXIT 1" }), msg=logs.join("\n"))
  assert_true(logs.iter().any(fn(line) { line.contains("appsaid: NAME TEXT") }), msg=logs.join("\n"))
}
