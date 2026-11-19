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

///|
test "JValue::to_json: what @json.parse reads of JSON.stringify's text" {
  let k = (s : String) => @jsjson.units(s)
  let lone : @jsjson.JValue = Str([0x61, 0xd800, 0x62])
  let cases : Array[@jsjson.JValue] = [
    Null,
    Bool(true),
    Num(1.5),
    Num(-3.0),
    Str(k("é😀\u{2028}\"\\\n")),
    Arr([Num(1.0), Null, Arr([]), Obj([])]),
    Obj([(k("b"), Num(1.0)), (k("10"), Str(k("x"))), (k("2"), Bool(false)), (k("a"), Obj([(k("z"), Null)]))]),
    Obj([(k("a"), Num(1.0)), (k("b"), Num(2.0)), (k("a"), Num(3.0))]),
  ]
  for v in cases {
    let reread = @json.parse(@jsjson.stringify(v))
    assert_eq(v.to_json().stringify(), reread.stringify())
    assert_true(v.to_json() == reread)
  }
  let dup = @jsjson.JValue::Obj([(k("a"), Num(1.0)), (k("b"), Num(2.0)), (k("a"), Num(3.0))])
  inspect(dup.to_json().stringify(), content="{\"a\":3,\"b\":2}")
  inspect(@jsjson.JValue::Obj([(k("b"), Num(1.0)), (k("10"), Num(2.0)), (k("2"), Num(3.0))]).to_json().stringify(), content="{\"2\":3,\"10\":2,\"b\":1}")
  // a lone surrogate kept (raw_text), not U+FFFD, in a key too: @json.parse refuses the `\ud800` JSON.stringify
  // writes of it, so stringify and @json.parse again gives nothing there
  match lone.to_json() {
    String(s) => inspect(@jsjson.units(s), content="[97, 55296, 98]")
    _ => fail("not a string")
  }
  let keyed : @jsjson.JValue = Obj([(k("x") + [0xd800], lone)])
  assert_true((try Some(@json.parse(@jsjson.stringify(keyed))) catch { _ => None }) is None)
  assert_eq(@jsjson.stringify(@jsjson.JValue::of_json(keyed.to_json())), @jsjson.stringify(keyed))
  // NaN and the infinities as null, as JSON.stringify writes them
  let odd = @jsjson.JValue::Arr([Num(@double.not_a_number), Num(@double.infinity), Num(@double.neg_infinity)])
  inspect(odd.to_json().stringify(), content="[null,null,null]")
  assert_true(odd.to_json() == @json.parse(@jsjson.stringify(odd)))
}

///|
test "JValue::of_json: what JSON.parse reads of the JSON's text, keys in the map's order" {
  let cases : Array[Json] = [
    Json::null(),
    Json::boolean(false),
    Json::number(-0.25),
    Json::string("é😀"),
    Json::string(@jsjson.raw_text([0x61, 0xd800, 0x62])),
    [1, "x", [true, Json::null()], {}],
    { "b": 1, "a": { "z": [Json::null()] }, "c": "s" },
  ]
  for j in cases {
    let v = @jsjson.JValue::of_json(j)
    assert_eq(@jsjson.stringify(v), @jsjson.stringify(@jsjson.parse(j.stringify())))
    assert_eq(v.to_json().stringify(), j.stringify())
  }
  match @jsjson.JValue::of_json(Json::string(@jsjson.raw_text([0x61, 0xd800, 0x62]))) {
    Str(u) => inspect(u, content="[97, 55296, 98]")
    _ => fail("not a string")
  }
  // insertion order kept where JSON.stringify would put integer keys first
  let v = @jsjson.JValue::of_json({ "b": 1, "10": 2, "2": 3 })
  inspect(@jsjson.jval_keys_of(v), content="[b, 10, 2]")
  inspect(@jsjson.stringify(v), content="{\"2\":3,\"10\":2,\"b\":1}")
}

///|
test "JValue's makers and readers" {
  let o = @jsjson.JValue::of_object([
    ("s", @jsjson.JValue::of_string("é")),
    ("d", @jsjson.JValue::of_double(1.5)),
    ("i", @jsjson.JValue::of_int(-2)),
    ("b", @jsjson.JValue::of_bool(true)),
    ("a", @jsjson.JValue::of_array([@jsjson.JValue::Null])),
    ("ss", @jsjson.JValue::of_strings(["x", "y"])),
    ("o", @jsjson.JValue::of_opt_string(Some("z"))),
    ("n", @jsjson.JValue::of_opt_string(None)),
    ("s", @jsjson.JValue::of_string("second")),
  ])
  inspect(
    @jsjson.stringify(o),
    content="{\"s\":\"é\",\"d\":1.5,\"i\":-2,\"b\":true,\"a\":[null],\"ss\":[\"x\",\"y\"],\"o\":\"z\",\"n\":null,\"s\":\"second\"}",
  )
  let v = Some(o)
  // a repeated key's first entry, as JValue::get
  inspect(@jsjson.jval_str_of(@jsjson.jval_at(v, "s")), content="Some(é)")
  inspect(@jsjson.jval_at(v, "none") is None, content="true")
  inspect(@jsjson.jval_at(Some(@jsjson.JValue::Arr([])), "s") is None, content="true")
  inspect(@jsjson.jval_at(None, "s") is None, content="true")
  inspect(@jsjson.jval_num_of(@jsjson.jval_at(v, "i")), content="Some(-2)")
  inspect(@jsjson.jval_num_of(@jsjson.jval_at(v, "s")), content="None")
  inspect(@jsjson.jval_bool_of(@jsjson.jval_at(v, "b")), content="Some(true)")
  inspect(@jsjson.jval_bool_of(@jsjson.jval_at(v, "d")), content="None")
  inspect(@jsjson.jval_arr_of(@jsjson.jval_at(v, "ss")).map(a => a.length()), content="Some(2)")
  inspect(@jsjson.jval_arr_of(@jsjson.jval_at(v, "o")) is None, content="true")
  let ss = @jsjson.jval_at(v, "ss")
  inspect(@jsjson.jval_str_of(@jsjson.jval_at_i(ss, 1)), content="Some(y)")
  inspect(@jsjson.jval_at_i(ss, 2) is None, content="true")
  inspect(@jsjson.jval_at_i(ss, -1) is None, content="true")
  inspect(@jsjson.jval_at_i(v, 0) is None, content="true")
  // a lone surrogate's text as U+FFFD
  inspect(@jsjson.jval_str_of(Some(Str([0xd800]))), content="Some(\u{fffd})")
  inspect(@jsjson.jval_keys_of(o), content="[s, d, i, b, a, ss, o, n, s]")
  inspect(@jsjson.jval_keys_of(Null), content="[]")
  inspect(@jsjson.jval_is_true(Some(Bool(true))), content="true")
  inspect(@jsjson.jval_is_true(Some(Num(1.0))), content="false")
  inspect(@jsjson.jval_is_true(None), content="false")
}

///|
test "JValue's changes as JavaScript makes them" {
  let k = (s : String) => @jsjson.units(s)
  let o : @jsjson.JValue = Obj([(k("a"), Num(1.0)), (k("b"), Num(2.0)), (k("a"), Num(3.0))])
  // `o[k] = v`: the first of a repeated key in its place, a new one at the end, the value given kept as it was
  inspect(@jsjson.stringify(@jsjson.jval_set(o, "a", Null)), content="{\"a\":null,\"b\":2,\"a\":3}")
  inspect(@jsjson.stringify(@jsjson.jval_set(o, "c", Null)), content="{\"a\":1,\"b\":2,\"a\":3,\"c\":null}")
  inspect(@jsjson.stringify(o), content="{\"a\":1,\"b\":2,\"a\":3}")
  inspect(@jsjson.stringify(@jsjson.jval_set(Num(1.0), "c", Null)), content="1")
  inspect(@jsjson.stringify(@jsjson.jval_set_or_new(Num(1.0), "c", Null)), content="{\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_set_or_new(o, "b", Bool(true))), content="{\"a\":1,\"b\":true,\"a\":3}")
  // `delete o[k]`: each entry of it
  inspect(@jsjson.stringify(@jsjson.jval_del(o, "a")), content="{\"b\":2}")
  inspect(@jsjson.stringify(@jsjson.jval_del(Str(k("x")), "a")), content="\"x\"")
  // `{ ...a, ...b }`
  let b : @jsjson.JValue = Obj([(k("b"), Str(k("B"))), (k("c"), Null)])
  inspect(@jsjson.stringify(@jsjson.jval_spread(o, b)), content="{\"a\":1,\"b\":\"B\",\"a\":3,\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_spread(Null, b)), content="{\"b\":\"B\",\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_spread(b, Arr([Num(1.0)]))), content="{\"b\":\"B\",\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_spread(Num(1.0), Str(k("s")))), content="{}")
  // `!!v` and `v == null`
  let vs : Array[@jsjson.JValue?] = [
    None,
    Some(Null),
    Some(Bool(false)),
    Some(Bool(true)),
    Some(Num(0.0)),
    Some(Num(-0.0)),
    Some(Num(@double.not_a_number)),
    Some(Num(2.0)),
    Some(Str([])),
    Some(Str(k("0"))),
    Some(Arr([])),
    Some(Obj([])),
  ]
  inspect(vs.map(@jsjson.jval_truthy), content="[false, false, false, true, false, false, false, true, false, true, true, true]")
  inspect(vs.map(@jsjson.jval_nullish), content="[true, true, false, false, false, false, false, false, false, false, false, false]")
}
