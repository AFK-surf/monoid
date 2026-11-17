test "JavaScript's reading and writing" {
  let v = parse("{\"vault\":\"a\\ud800b\",\"b\":1,\"vault\":\"second\",\"k\\u0000x\":[1.5,true,null],\"10\":2,\"2\":{\"z\":1e400}}")
  inspect(stringify(v), content="{\"2\":{\"z\":null},\"10\":2,\"vault\":\"second\",\"b\":1,\"k\\u0000x\":[1.5,true,null]}")
  let w = parse("{\"vault\":\"a\\ud800b\"}")
  match w.get("vault") {
    Some(Str(s)) => {
      inspect(s, content="[97, 55296, 98]")
      inspect(stringify(Str(s)), content="\"a\\ud800b\"")
      inspect(text(s), content="a\u{fffd}b")
      inspect(utf16le(s), content="[97, 0, 0, 216, 98, 0]")
    }
    _ => fail("no vault")
  }
  let bad = (t : String) => (try Some(parse(t)) catch { _ => None }) is None
  inspect(bad("{\"a\":1,}"), content="true")
  inspect(bad("[01]"), content="true")
}

///|
test "written as bytes, what JSON.stringify writes as UTF-8, a line's ends escaped" {
  let v = parse(
    "{\"a\":\"x\\ud83d\\ude00y\\ud800z\\u2028\\u2029\\u0001\\\"\\\\\\n\",\"2\":[1.5,-0,1e21,null,true,{}],\"é\":\"ü中\"}",
  )
  let out = @buffer.new()
  write_utf8(out, v)
  let said = stringify(v).replace_all(old="\u{2028}", new="\\u2028").replace_all(old="\u{2029}", new="\\u2029")
  inspect(out.to_bytes() == @utf8.encode(said), content="true")
  inspect(stringify(parse(@utf8.decode(out.to_bytes()))) == stringify(v), content="true")
}
