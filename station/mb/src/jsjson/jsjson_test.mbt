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

///|
test "JV: JavaScript's values with MoonBit's strings, keys in JavaScript's order" {
  let v = @jsjson.jv_parse("{\"b\":1,\"10\":\"x\",\"2\":[true,null,\"\\u00e9\"],\"a\":{\"k\":2.5}}")
  inspect(@jsjson.jv_stringify(v), content="{\"2\":[true,null,\"é\"],\"10\":\"x\",\"b\":1,\"a\":{\"k\":2.5}}")
  inspect(@jsjson.jstr(@jsjson.jget(Some(v), "10")), content="Some(x)")
  inspect(@jsjson.jnumber(@jsjson.jget(@jsjson.jget(Some(v), "a"), "k")), content="Some(2.5)")
  inspect(@jsjson.jitems(v.get("2")).length(), content="3")
  let o = @jsjson.jobj([("z", @jsjson.js("1")), ("3", @jsjson.jint(3)), ("1", @jsjson.jbool(true))])
  inspect(@jsjson.jv_stringify(o), content="{\"1\":true,\"3\":3,\"z\":\"1\"}")
  inspect(@jsjson.jv_stringify(@jsjson.jdel(@jsjson.jset(o, "z", @jsjson.jnum(0.5)), "3")), content="{\"1\":true,\"z\":0.5}")
  inspect(@jsjson.jv_js_string(Some(@jsjson.jarr([@jsjson.jnum(1.0), @jsjson.JV::Null, @jsjson.js("s")]))), content="1,,s")
  inspect(@jsjson.try_parse("{") is None, content="true")
}

///|
test "JV: undefined left out, @json.Json both ways" {
  let o = @jsjson.jobj([("a", @jsjson.jundef), ("b", @jsjson.jnum(1.0))]).filter_undef()
  inspect(@jsjson.jv_stringify(o), content="{\"b\":1}")
  inspect(@jsjson.defined(@jsjson.jundef) is None, content="true")
  let j : Json = { "b": 1, "7": [true, "x"], "n": Json::null() }
  let v = @jsjson.JV::of_json(j)
  inspect(@jsjson.jv_stringify(v), content="{\"7\":[true,\"x\"],\"b\":1,\"n\":null}")
  inspect(v.to_json().stringify(), content="{\"7\":[true,\"x\"],\"b\":1,\"n\":null}")
  inspect(@jsjson.JV::Num(@double.not_a_number).to_json().stringify(), content="null")
  let js = @jsjson.JV::to_js(v)
  inspect(@jsjson.JV::of_js(js) == v, content="true")
}
