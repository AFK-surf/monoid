///|
test "a refusal's text is its words, not its type's name" {
  let e : Error = @gate.PeerRefused("not a station of this workspace")
  assert_eq(e.to_string(), "not a station of this workspace")
  let r : Error = @gate.Refused("refused as asked")
  assert_eq("\{r}", "refused as asked")
  let h : Error = @gate.HttpRefusal(502, "no answer", true)
  assert_eq(h.to_string(), "no answer")
}
