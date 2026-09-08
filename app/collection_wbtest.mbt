///|
test "profile approval requires the verified name, service, and properties together" {
  fn profile(
    name : String,
    service : String,
    notify : Int,
    write : Int,
  ) -> Json {
    {
      "name": name,
      "services": [
        {
          "uuid": service,
          "characteristics": [
            { "uuid": "FFF4", "properties": notify },
            { "uuid": "FFF1", "properties": write },
          ],
        },
      ],
    }
  }
  assert_true(verified_profile(profile("eufy T9120", "FFF0", 16, 4)))
  assert_false(verified_profile(profile("eufy T9148", "FFF0", 16, 4)))
  assert_false(verified_profile(profile("eufy T9120", "FFB0", 16, 4)))
  assert_false(verified_profile(profile("eufy T9120", "FFF0", 2, 4)))
  assert_false(verified_profile(profile("eufy T9120", "FFF0", 16, 8)))
}
