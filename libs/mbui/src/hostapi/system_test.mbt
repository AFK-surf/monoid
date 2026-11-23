///|
test "system_said parses cellular network state alongside network changes" {
  assert_eq(@hostapi.system_said("{\"cellular\":true}"), [@hostapi.SystemSaid::Cellular(true)])
  assert_eq(@hostapi.system_said("{\"cellular\":false}"), [@hostapi.SystemSaid::Cellular(false)])
  assert_eq(@hostapi.system_said("{\"network\":true,\"cellular\":true}"), [
    @hostapi.SystemSaid::Network,
    @hostapi.SystemSaid::Cellular(true),
  ])
  assert_eq(@hostapi.system_said("{\"cellular\":\"yes\"}"), [])
}
