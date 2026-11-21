// Unit tests for profiles_overview helpers (ov_refill_minutes zero-allocation scanner).

///|
fn ov_refill_minutes_ref(s : String) -> Int {
  if s == "" {
    return 999999
  }
  let chars = s.to_array()
  let len = chars.length()
  let mut i = 0
  let mut total = 0
  let mut matched = false
  while i < len {
    let ch = chars[i]
    if ch >= '0' && ch <= '9' {
      let mut n = 0
      while i < len && chars[i] >= '0' && chars[i] <= '9' {
        n = n * 10 + (chars[i].to_int() - '0'.to_int())
        i += 1
      }
      while i < len && chars[i] == ' ' {
        i += 1
      }
      if i < len {
        let u = chars[i]
        if u == '天' || u == 'd' || u == 'D' {
          total += n * 1440
          matched = true
        } else if u == '小' || u == 'h' || u == 'H' {
          total += n * 60
          matched = true
        } else if u == '分' || u == 'm' || u == 'M' {
          total += n
          matched = true
        }
      }
    } else {
      i += 1
    }
  }
  if matched {
    @cmp.maximum(1, total)
  } else if s.contains("即将") || s.contains("now") || s.contains("soon") {
    1
  } else {
    999999
  }
}

///|
test "ov_refill_minutes: zero-alloc scanner matches reference across zh/en/edge inputs" {
  let cases : Array[(String, Int)] = [
    ("", 999999),
    ("3天", 4320),
    ("2 天 4 小时", 3120),
    ("1天 2 小时 5 分", 1565),
    ("2小时30分后重置", 150),
    ("14h", 840),
    ("2d 3h 15m", 3075),
    ("1D 2H 30M", 1590),
    ("45分", 45),
    ("45 分", 45),
    ("0分", 1),
    ("0m", 1),
    ("即将", 1),
    ("即将重置", 1),
    ("soon", 1),
    ("resets soon", 1),
    ("now", 1),
    ("未知", 999999),
    ("never", 999999),
    ("123", 999999),
    ("12x", 999999),
  ]
  for c in cases {
    let (input, expected) = c
    let got = ov_refill_minutes(input)
    let ref_val = ov_refill_minutes_ref(input)
    assert_eq(got, expected, msg="input=\{Repr(input)}")
    assert_eq(got, ref_val, msg="input=\{Repr(input)} vs ref")
  }
}
