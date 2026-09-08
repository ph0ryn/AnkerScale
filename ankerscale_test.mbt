///|
test "T9120 stable packet matches observed scale reading" {
  let result = @ankerscale.parse_t9120(
    b"\xcf\xe8\x12\xb4\x14\xb3\xb6\x9f\x00\x00\x0f",
  )
  assert_true(
    result
    is Stable(
      {
        weight_centi_kg: 5300,
        impedance: 4840,
        encrypted_impedance: 10466995,
        ..
      }
    ),
  )
}

///|
test "invalid and unverified packets cannot become measurements" {
  assert_true(@ankerscale.parse_t9120(b"\xcf") is Invalid(_))
  assert_true(
    @ankerscale.parse_t9120(b"\xcf\xe8\x12\xb4\x14\xb3\xb6\x9f\x00\x00\x00")
    is Invalid(_),
  )
  assert_true(
    @ankerscale.parse_t9120(b"\xcf\xe8\x12\xb4\x14\xb3\xb6\x9f\x00\x01\x0e")
    is Dynamic(_),
  )
  assert_true(
    @ankerscale.parse_t9120(b"\xcf\xe8\x12\xb4\x14\xb3\xb6\x9f\x00\x02\x0d")
    is Overload,
  )
  assert_true(
    @ankerscale.parse_t9120(b"\xcf\xe8\x12\xb4\x14\xb3\xb6\x9f\x00\x03\x0c")
    is Invalid(_),
  )
  assert_true(
    @ankerscale.parse_t9120(
      b"\xcf\xe8\x12\xb4\x14\xb3\xb6\x9f\x00\x00\x0f\x07\xea\x09\x08\x00\x00\x00",
    )
    is HistoryCandidate,
  )
  assert_true(@ankerscale.parse_t9120(b"\xac\x02") is Unknown)
  assert_true(@ankerscale.parse_t9120(b"\xf3\x00") is Control(_))
}

///|
test "initialization uses documented byte order and checksum" {
  assert_eq(
    @ankerscale.unit_command(),
    b"\xfd\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfd",
  )
  assert_eq(
    @ankerscale.time_command(2026, 6, 20, 23, 51, 20),
    b"\xf1\x07\xea\x06\x14\x17\x33\x14",
  )
}
