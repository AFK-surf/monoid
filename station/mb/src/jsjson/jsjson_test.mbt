test "JavaScript's reading and writing" {
  let v = parse("{\"vault\":\"a\\ud800b\",\"b\":1,\"vault\":\"second\",\"k\\u0000x\":[1.5,true,null],\"10\":2,\"2\":{\"z\":1e400}}")
  inspect(stringify(v), content="{\"2\":{\"z\":null},\"10\":2,\"vault\":\"second\",\"b\":1,\"k\\u0000x\":[1.5,true,null]}")
  let w = parse("{\"vault\":\"a\\ud800b\"}")
  match w.get("vault") {
    Some(Str(s)) => {
      inspect(units(s), content="[97, 55296, 98]")
      inspect(stringify(Str(s)), content="\"a\\ud800b\"")
      inspect(sanitize_str(s), content="a\u{fffd}b")
      inspect(text(units(s)), content="a\u{fffd}b")
      inspect(utf16le(units(s)), content="[97, 0, 0, 216, 98, 0]")
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
  let lone : @jsjson.JValue = Str(@jsjson.raw_text([0x61, 0xd800, 0x62]))
  let cases : Array[@jsjson.JValue] = [
    Null,
    Bool(true),
    Num(1.5),
    Num(-3.0),
    Str("é😀\u{2028}\"\\\n"),
    Arr([Num(1.0), Null, Arr([]), Obj([])]),
    Obj([("b", Num(1.0)), ("10", Str("x")), ("2", Bool(false)), ("a", Obj([("z", Null)]))]),
    Obj([("a", Num(1.0)), ("b", Num(2.0)), ("a", Num(3.0))]),
  ]
  for v in cases {
    let reread = @json.parse(@jsjson.stringify(v))
    assert_eq(v.to_json().stringify(), reread.stringify())
    assert_true(v.to_json() == reread)
  }
  let dup = @jsjson.JValue::Obj([("a", Num(1.0)), ("b", Num(2.0)), ("a", Num(3.0))])
  inspect(dup.to_json().stringify(), content="{\"a\":3,\"b\":2}")
  inspect(@jsjson.JValue::Obj([("b", Num(1.0)), ("10", Num(2.0)), ("2", Num(3.0))]).to_json().stringify(), content="{\"2\":3,\"10\":2,\"b\":1}")
  // a lone surrogate kept, not U+FFFD, in a key too: @json.parse refuses the `\ud800` JSON.stringify
  // writes of it, so stringify and @json.parse again gives nothing there
  match lone.to_json() {
    String(s) => inspect(@jsjson.units(s), content="[97, 55296, 98]")
    _ => fail("not a string")
  }
  let keyed : @jsjson.JValue = Obj([("x" + @jsjson.raw_text([0xd800]), lone)])
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
    Str(s) => inspect(@jsjson.units(s), content="[97, 55296, 98]")
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
  inspect(@jsjson.jval_str_of(Some(Str(@jsjson.raw_text([0xd800])))), content="Some(\u{fffd})")
  inspect(@jsjson.jval_keys_of(o), content="[s, d, i, b, a, ss, o, n, s]")
  inspect(@jsjson.jval_keys_of(Null), content="[]")
  inspect(@jsjson.jval_is_true(Some(Bool(true))), content="true")
  inspect(@jsjson.jval_is_true(Some(Num(1.0))), content="false")
  inspect(@jsjson.jval_is_true(None), content="false")
}

///|
test "JValue's changes as JavaScript makes them" {
  let o : @jsjson.JValue = Obj([("a", Num(1.0)), ("b", Num(2.0)), ("a", Num(3.0))])
  // `o[k] = v`: the first of a repeated key in its place, a new one at the end, the value given kept as it was
  inspect(@jsjson.stringify(@jsjson.jval_set(o, "a", Null)), content="{\"a\":null,\"b\":2,\"a\":3}")
  inspect(@jsjson.stringify(@jsjson.jval_set(o, "c", Null)), content="{\"a\":1,\"b\":2,\"a\":3,\"c\":null}")
  inspect(@jsjson.stringify(o), content="{\"a\":1,\"b\":2,\"a\":3}")
  inspect(@jsjson.stringify(@jsjson.jval_set(Num(1.0), "c", Null)), content="1")
  inspect(@jsjson.stringify(@jsjson.jval_set_or_new(Num(1.0), "c", Null)), content="{\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_set_or_new(o, "b", Bool(true))), content="{\"a\":1,\"b\":true,\"a\":3}")
  // `delete o[k]`: each entry of it
  inspect(@jsjson.stringify(@jsjson.jval_del(o, "a")), content="{\"b\":2}")
  inspect(@jsjson.stringify(@jsjson.jval_del(Str("x"), "a")), content="\"x\"")
  // `{ ...a, ...b }`
  let b : @jsjson.JValue = Obj([("b", Str("B")), ("c", Null)])
  inspect(@jsjson.stringify(@jsjson.jval_spread(o, b)), content="{\"a\":1,\"b\":\"B\",\"a\":3,\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_spread(Null, b)), content="{\"b\":\"B\",\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_spread(b, Arr([Num(1.0)]))), content="{\"b\":\"B\",\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_spread(Num(1.0), Str("s"))), content="{}")
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
    Some(Str("")),
    Some(Str("0")),
    Some(Arr([])),
    Some(Obj([])),
  ]
  inspect(vs.map(@jsjson.jval_truthy), content="[false, false, false, true, false, false, false, true, false, true, true, true]")
  inspect(vs.map(@jsjson.jval_nullish), content="[true, true, false, false, false, false, false, false, false, false, false, false]")
}

///|
test "JValue extended ops: at_last, at_path, text, arr, entries, js_str, js_num, safe_int, to_json_lossy" {
  let o : @jsjson.JValue = Obj([
    ("a", Num(1.0)),
    ("b", Obj([("c", Str("hi")), ("c", Str("last"))])),
    ("a", Num(2.0)),
  ])
  inspect(@jsjson.jval_num_of(@jsjson.jval_at(Some(o), "a")), content="Some(1)")
  inspect(@jsjson.jval_num_of(@jsjson.jval_at_last(Some(o), "a")), content="Some(2)")
  inspect(@jsjson.jval_str_of(@jsjson.jval_at_path(Some(o), ["b", "c"])), content="Some(hi)")
  inspect(@jsjson.jval_str_of(@jsjson.jval_at_path_last(Some(o), ["b", "c"])), content="Some(last)")
  inspect(@jsjson.jval_text(Some(Str("ok"))), content="ok")
  inspect(@jsjson.jval_text(Some(Num(1.0))), content="")
  inspect(@jsjson.jval_arr(Some(Arr([Num(1.0)]))).length(), content="1")
  inspect(@jsjson.jval_arr(Some(Null)).length(), content="0")
  inspect(@jsjson.jval_entries(Some(o)).length(), content="3")
  inspect(@jsjson.jval_entries(Some(Null)).length(), content="0")
  // String(v)
  inspect(@jsjson.jval_js_str(None), content="undefined")
  inspect(@jsjson.jval_js_str(Some(Null)), content="null")
  inspect(@jsjson.jval_js_str(Some(Arr([Null]))), content="")
  inspect(@jsjson.jval_js_str(Some(Arr([Num(1.0), Null, Str("x")]))), content="1,,x")
  inspect(@jsjson.jval_js_str(Some(Obj([]))), content="[object Object]")
  // Number(v)
  inspect(@jsjson.jval_js_num(None).is_nan(), content="true")
  inspect(@jsjson.jval_js_num(Some(Null)), content="0")
  inspect(@jsjson.jval_js_num(Some(Bool(true))), content="1")
  inspect(@jsjson.jval_js_num(Some(Str(""))), content="0")
  inspect(@jsjson.jval_js_num(Some(Str(" \t\n"))), content="0")
  inspect(@jsjson.jval_js_num(Some(Str("007"))), content="7")
  inspect(@jsjson.jval_js_num(Some(Arr([]))), content="0")
  inspect(@jsjson.jval_js_num(Some(Arr([Null]))), content="0")
  inspect(@jsjson.jval_js_num(Some(Arr([Str("42")]))), content="42")
  inspect(@jsjson.jval_js_num(Some(Arr([Num(1.0), Num(2.0)]))).is_nan(), content="true")
  // is_integer / safe_int
  inspect(@jsjson.jval_is_integer(Some(Num(42.0))), content="true")
  inspect(@jsjson.jval_is_integer(Some(Num(42.5))), content="false")
  inspect(@jsjson.jval_safe_int(Some(Num(9007199254740991.0))), content="true")
  inspect(@jsjson.jval_safe_int(Some(Num(9007199254740992.0))), content="false")
  // to_json_lossy replaces lone surrogate with U+FFFD
  let lone : @jsjson.JValue = Str(@jsjson.raw_text([0x61, 0xd800, 0x62]))
  inspect(lone.to_json_lossy().stringify(), content="\"a\u{fffd}b\"")
  inspect(@jsjson.jval_try_parse("{bad}") is None, content="true")
  inspect(@jsjson.jval_try_parse("{\"x\":1}") is Some(_), content="true")
}

///|
test "JV in-place put/delete, raw parse, jat, jkeys, jvalues, js_round, string helpers" {
  // raw parse keeps lone surrogates
  let raw = @jsjson.jv_parse_raw("{\"s\":\"a\\ud800b\"}")
  match raw.get("s") {
    Some(Str(s)) => inspect(@jsjson.units(s), content="[97, 55296, 98]")
    _ => fail("expected string")
  }
  inspect(@jsjson.try_parse_raw("{") is None, content="true")
  // in-place put & delete preserve JS key order (integer keys ascending first)
  let o = @jsjson.JV::Obj([])
  o.put("b", @jsjson.jint(1))
  o.put("10", @jsjson.jint(10))
  o.put("2", @jsjson.jint(2))
  o.put("b", @jsjson.jint(9))
  inspect(@jsjson.jkeys(o), content="[2, 10, b]")
  inspect(@jsjson.jvalues(o).length(), content="3")
  o.delete("10")
  inspect(@jsjson.jkeys(o), content="[2, b]")
  // jat
  let a = @jsjson.jarr([@jsjson.jint(10), @jsjson.jint(20)])
  inspect(@jsjson.jnumber(@jsjson.jat(Some(a), 1)), content="Some(20)")
  inspect(@jsjson.jat(Some(a), -1) is None, content="true")
  inspect(@jsjson.jat(Some(a), 2) is None, content="true")
  // js_round: JS Math.round semantics
  inspect(@jsjson.js_round(0.5), content="1")
  inspect(@jsjson.js_round(0.49999999999999994), content="0")
  inspect(@jsjson.js_round(-0.5), content="0")
  inspect(@jsjson.js_round(-0.5).reinterpret_as_uint64() == (-0.0 : Double).reinterpret_as_uint64(), content="true")
  inspect(@jsjson.js_round(-0.6), content="-1")
  inspect(@jsjson.js_round(4503599627370497.0), content="4503599627370497")
  inspect(@jsjson.js_round(@double.not_a_number).is_nan(), content="true")
  inspect(@jsjson.js_round(@double.infinity).is_inf(), content="true")
  // js_slice / js_index_of / js_last_index_of / js_split
  inspect(@jsjson.js_slice("abcdef", 1, end=4), content="bcd")
  inspect(@jsjson.js_slice("abcdef", -2), content="ef")
  inspect(@jsjson.js_slice("abcdef", 4, end=2), content="")
  inspect(@jsjson.js_index_of("ababa", "ba"), content="1")
  inspect(@jsjson.js_index_of("ababa", "ba", from=2), content="3")
  inspect(@jsjson.js_index_of("abc", "", from=10), content="3")
  inspect(@jsjson.js_last_index_of("ababa", "ba"), content="3")
  inspect(@jsjson.js_split("a,,b,", ","), content="[a, , b, ]")
  inspect(@jsjson.js_split("ab", ""), content="[a, b]")
}

///|
test "jval_* and json_* top-level helpers" {
  let o = @jsjson.jval_obj([
    ("s", @jsjson.jval_str("hi")),
    ("empty", @jsjson.jval_str("")),
    ("n", @jsjson.jval_num(2.5)),
    ("nan", @jsjson.jval_num(@double.not_a_number)),
    ("i", @jsjson.jval_int(7)),
    ("b", @jsjson.jval_bool(true)),
    ("a", @jsjson.jval_array([@jsjson.jval_str("x"), @jsjson.jval_int(1)])),
    ("ss", @jsjson.jval_strs(["a", "b"])),
    ("opt", @jsjson.jval_opt_str(None)),
  ])
  inspect(@jsjson.jval_is_record(Some(o)), content="true")
  inspect(@jsjson.jval_is_obj(Some(o)), content="true")
  inspect(@jsjson.jval_is_arr(Some(o)), content="false")
  inspect(@jsjson.jval_is_arr(@jsjson.jval_at(Some(o), "a")), content="true")
  inspect(@jsjson.jval_is_obj(@jsjson.jval_at(Some(o), "a")), content="true")
  inspect(@jsjson.jval_is_record(@jsjson.jval_at(Some(o), "a")), content="false")
  inspect(@jsjson.jval_nonempty(@jsjson.jval_at(Some(o), "s")), content="Some(hi)")
  inspect(@jsjson.jval_nonempty(@jsjson.jval_at(Some(o), "empty")), content="None")
  inspect(@jsjson.jval_finite(@jsjson.jval_at(Some(o), "n")), content="Some(2.5)")
  inspect(@jsjson.jval_finite(@jsjson.jval_at(Some(o), "nan")), content="None")
  inspect(@jsjson.jval_finite_or_zero(@jsjson.jval_at(Some(o), "n")), content="2.5")
  inspect(@jsjson.jval_finite_or_zero(@jsjson.jval_at(Some(o), "nan")), content="0")
  inspect(@jsjson.jval_num_text_of(@jsjson.jval_num(1.5)), content="1.5")
  inspect(@jsjson.jval_num_text_of(@jsjson.jval_str("x")), content="\"x\"")
  inspect(@jsjson.jval_stringify_num(@double.not_a_number), content="null")
  inspect(@jsjson.jval_stringify_num(42.0), content="42")
  inspect(@jsjson.jval_str_eq(@jsjson.jval_at(Some(o), "s"), "hi"), content="true")
  inspect(@jsjson.jval_str_eq(@jsjson.jval_at(Some(o), "s"), "no"), content="false")
  inspect(@jsjson.jval_str_at(Some(o), "s"), content="Some(hi)")
  inspect(@jsjson.jval_num_at(Some(o), "i"), content="Some(7)")
  inspect(@jsjson.jval_bool_at(Some(o), "b"), content="Some(true)")
  inspect(@jsjson.jval_arr_at(Some(o), "ss").map(a => a.length()), content="Some(2)")
  inspect(@jsjson.jval_strings_of(@jsjson.jval_at(Some(o), "a")), content="[x]")
  inspect(@jsjson.jval_same_opt(None, None), content="true")
  inspect(@jsjson.jval_same_opt(Some(@jsjson.jval_int(1)), Some(@jsjson.jval_num(1.0))), content="true")
  inspect(@jsjson.jval_quote("a\"b"), content="\"a\\\"b\"")
  inspect(@jsjson.js_less("a", "b"), content="true")
  inspect(@jsjson.js_less("b", "a"), content="false")
  inspect(@jsjson.jval_keys(o).length(), content="9")
  inspect(@jsjson.jval_to_json(@jsjson.jval_of_json(@jsjson.json_int(3))).stringify(), content="3")
  inspect(@jsjson.jval_to_json_lossy(@jsjson.jval_str("ok")).stringify(), content="\"ok\"")

  let j = @jsjson.json_obj([
    ("s", @jsjson.json_str("hi")),
    ("n", @jsjson.json_num(3.5)),
    ("nan", @jsjson.json_num_js(@double.not_a_number)),
    ("i", @jsjson.json_int(5)),
    ("i64", @jsjson.json_int64(9L)),
    ("b", @jsjson.json_bool(false)),
    ("a", @jsjson.json_arr([@jsjson.json_str("p"), @jsjson.json_int(2)])),
    ("ss", @jsjson.json_strs(["u", "v"])),
    ("opt", @jsjson.json_opt_str(None)),
  ])
  inspect(@jsjson.json_is_obj(Some(j)), content="true")
  inspect(@jsjson.json_is_objectish(Some(j)), content="true")
  inspect(@jsjson.json_field(j, "s") == Some(@jsjson.json_str("hi")), content="true")
  inspect(@jsjson.json_str_at(Some(j), "s"), content="Some(hi)")
  inspect(@jsjson.json_num_at(Some(j), "n"), content="Some(3.5)")
  inspect(@jsjson.json_bool_at(Some(j), "b"), content="Some(false)")
  inspect(@jsjson.json_arr_at(Some(j), "ss").map(a => a.length()), content="Some(2)")
  inspect(@jsjson.json_strings_of(@jsjson.json_at(Some(j), "a")), content="[p]")
  inspect(@jsjson.json_finite(@jsjson.json_at(Some(j), "n")), content="Some(3.5)")
  inspect(@jsjson.json_finite(@jsjson.json_at(Some(j), "nan")), content="None")
  inspect(@jsjson.jval_or_null(None) is Null, content="true")
  inspect(@jsjson.jval_str_raw_of(Some(@jsjson.jval_str("ab"))), content="Some(ab)")
  inspect(@jsjson.jval_js_str_raw(@jsjson.jval_int(9)), content="9")
  inspect(@jsjson.json_stringify(@jsjson.json_int(4)), content="4")
  inspect(@jsjson.json_stringify_pretty(@jsjson.json_arr([@jsjson.json_int(1)])), content="[\n  1\n]")
  inspect(@jsjson.json_js_str(Some(@jsjson.json_arr([@jsjson.json_int(1), Json::null(), @jsjson.json_str("a")]))), content="1,,a")
  inspect(@jsjson.json_items(@jsjson.json_at(Some(j), "a")).length(), content="2")
  inspect(@jsjson.json_str_field(j, "s"), content="Some(hi)")
  inspect(@jsjson.json_num_field(j, "n"), content="Some(3.5)")
  inspect(@jsjson.json_bool_field(j, "b"), content="false")
  inspect(@jsjson.json_arr_field(j, "ss").map(a => a.length()), content="Some(2)")
  inspect(@jsjson.json_truthy(Some(@jsjson.json_str("x"))), content="true")
  inspect(@jsjson.json_truthy(Some(@jsjson.json_str(""))), content="false")
  inspect(@jsjson.json_nullish(None), content="true")
  inspect(@jsjson.json_same_opt(Some(@jsjson.json_int(1)), Some(@jsjson.json_num(1.0))), content="true")
  inspect(@jsjson.js_trunc(-2.9), content="-2")
  inspect(@jsjson.js_trunc(2.9), content="2")
  inspect(@jsjson.js_uniq(["b", "a", "b"]), content="[b, a]")
  inspect(@jsjson.js_all_digits("123"), content="true")
  inspect(@jsjson.js_all_digits(""), content="false")
  inspect(@jsjson.js_upper_ascii("aB1"), content="AB1")
  inspect(@jsjson.js_split_lines("a\r\nb\nc"), content="[a, b, c]")
  inspect(@jsjson.js_slice_to("abcdef", 3), content="abc")
  inspect(@jsjson.js_slice_to("abc", -1), content="")
  inspect(@jsjson.js_slice_to("abc", 0), content="")
  inspect(@jsjson.js_replace_all("a-b-c", "-", "/"), content="a/b/c")
  inspect(@jsjson.js_utf8_len("é"), content="2")
  inspect(@jsjson.js_utf8_len("😀"), content="4")
  inspect(@jsjson.js_utf8_len(@jsjson.raw_text([0x61, 0xd800, 0x62])), content="5")
  inspect(@jsjson.js_starts("abc", "ab"), content="true")
  inspect(@jsjson.js_ends("abc", "bc"), content="true")
  inspect(@jsjson.js_includes("abc", "b"), content="true")
}


///|
test "js_iso and js_iso_checked" {
  assert_eq(js_iso(0.0), "1970-01-01T00:00:00.000Z")
  assert_eq(js_iso(-0.5), "1970-01-01T00:00:00.000Z")
  assert_eq(js_iso(-1.0), "1969-12-31T23:59:59.999Z")
  assert_eq(js_iso_checked(0.0), Some("1970-01-01T00:00:00.000Z"))
  assert_eq(js_iso_checked(8.64e15), Some("+275760-09-13T00:00:00.000Z"))
  assert_eq(js_iso_checked(8.64e15 + 1.0), None)
  assert_eq(js_iso_checked(@double.not_a_number), None)
  assert_eq(js_iso_checked(@double.infinity), None)
}

///|
test "js_parse_iso and js_date_parse" {
  assert_eq(js_parse_iso("1970"), Some(0.0))
  assert_eq(js_parse_iso("1970-01"), Some(0.0))
  assert_eq(js_parse_iso("1970-01-01"), Some(0.0))
  assert_eq(js_parse_iso("1970-01-01T00:00:00.000Z"), Some(0.0))
  assert_eq(js_parse_iso("1970-01-01T00:00:00.123456Z"), Some(123.0))
  assert_eq(js_parse_iso("1970-01-01T01:00:00+01:00"), Some(0.0))
  assert_eq(js_parse_iso("1970-01-01T01:00:00+0100"), Some(0.0))
  assert_eq(js_parse_iso("1970-01-01T24:00:00.000Z"), Some(86_400_000.0))
  assert_eq(js_parse_iso("1970-01-01T24:00:01Z"), None)
  assert_eq(js_parse_iso("-000000-01-01"), None)
  assert_eq(js_parse_iso("2026-02-30", strict_day=true), None)
  assert_eq(js_parse_iso("2026-02-30", strict_day=false) is Some(_), true)
  assert_eq(js_parse_iso("1970-01-01T02:00:00", tz_offset_ms=_ => 7_200_000.0), Some(0.0))
  assert_eq(js_date_parse("1970-01-01 00:00:00Z"), Some(0.0))
  assert_eq(js_date_parse("Thu, 01 Jan 1970 00:00:00 GMT"), Some(0.0))
  assert_eq(js_date_parse("not a date"), None)
}

///|
test "locale_compare, without_mentions, is_well_formed" {
  assert_eq(locale_compare("a", "B"), -1)
  assert_eq(locale_compare("a", "A"), -1)
  assert_eq(locale_compare("A", "a"), 1)
  assert_eq(locale_compare("_a", "0a"), -1)
  assert_eq(locale_compare("0a", "a"), -1)
  assert_eq(without_mentions("<@U123> hello <@B9>"), " hello ")
  assert_eq(without_mentions("<@bad> <@> ok"), "<@bad> <@> ok")
  assert_true(is_well_formed("hello 😀"))
  match try_parse_raw("\"a\\ud800b\"") {
    Some(Str(s)) => assert_false(is_well_formed(s))
    _ => fail("expected string")
  }
}

///|
/// What `put` one key at a time gives: what `jobj` and the parser must give for an object of any size.
fn put_each(fields : Array[(String, JValue)]) -> JValue {
  let o = JValue::Obj([])
  for f in fields {
    o.put(f.0, f.1)
  }
  o
}

///|
/// An object's fields in the order it holds them (stringify orders them again: this does not).
fn held(v : JValue) -> String {
  match v {
    Obj(entries) => entries.map(e => e.0 + "=" + stringify(e.1)).join(",")
    _ => "not an object"
  }
}

///|
test "a big object's repeated keys: each in its first place with its last value, integer-like keys first" {
  let fields : Array[(String, JValue)] = []
  for i in 0..<20 {
    fields.push(("k\{i}", Num(i.to_double())))
  }
  // (repeats of a key before the map and after it, integer-like keys among them, repeated too)
  fields.push(("k3", Str("late")))
  fields.push(("7", Bool(true)))
  fields.push(("k19", Str("last")))
  fields.push(("2", Null))
  fields.push(("07", Num(7.0)))
  fields.push(("7", Bool(false)))
  fields.push(("k0", Str("again")))
  let want = stringify(put_each(fields))
  inspect(
    want,
    content="{\"2\":null,\"7\":false,\"k0\":\"again\",\"k1\":1,\"k2\":2,\"k3\":\"late\",\"k4\":4,\"k5\":5,\"k6\":6,\"k7\":7,\"k8\":8,\"k9\":9,\"k10\":10,\"k11\":11,\"k12\":12,\"k13\":13,\"k14\":14,\"k15\":15,\"k16\":16,\"k17\":17,\"k18\":18,\"k19\":\"last\",\"07\":7}",
  )
  assert_eq(stringify(@jsjson.jobj(fields)), want)
  assert_eq(held(@jsjson.jobj(fields)), held(put_each(fields)))
  let text = "{" + fields.map(f => "\"\{f.0}\":\{stringify(f.1)}").join(",") + "}"
  assert_eq(stringify(parse(text)), want)
  // (as read, the object keeps the order the text gave its keys; the map's places are those of the scan's)
  match parse(text) {
    Obj(entries) => {
      assert_eq(entries.length(), 23)
      assert_eq(entries[3].0 + "=" + stringify(entries[3].1), "k3=\"late\"")
      assert_eq(entries[20].0 + "=" + stringify(entries[20].1), "7=false")
      assert_eq(entries[22].0 + "=" + stringify(entries[22].1), "07=7")
    }
    _ => fail("not an object")
  }
  // (under the map's size, the same)
  let small = fields[0:5].to_array() + [("k1", Str("x")), ("3", Null)]
  assert_eq(held(@jsjson.jobj(small)), held(put_each(small)))
}

///|
test "an object of 5,000 keys read and put together whole" {
  let fields : Array[(String, JValue)] = []
  for i in 0..<5000 {
    let key = if i % 7 == 0 { "\{(5000 - i) * 3}" } else { "h\{i}" }
    fields.push((key, Num(i.to_double())))
  }
  // (repeats of keys already there)
  for i in 0..<100 {
    fields.push(("h\{i * 7 + 1}", Str("again")))
  }
  let want = stringify(put_each(fields))
  assert_eq(stringify(@jsjson.jobj(fields)), want)
  assert_eq(held(@jsjson.jobj(fields)), held(put_each(fields)))
  let text = "{" + fields.map(f => "\"\{f.0}\":\{stringify(f.1)}").join(",") + "}"
  let v = parse(text)
  assert_eq(stringify(v), want)
  inspect(v.keys().length(), content="5000")
}
