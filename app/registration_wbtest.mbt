///|
fn registration_advertisement(
  id : String,
  name? : String = "eufy T9120",
  services? : Array[String] = [],
) -> Json {
  {
    "event": "device",
    "device": id,
    "name": name,
    "services": services,
    "rssi": -70,
  }
}

///|
fn registration_callback(kind : String, id : String, attempt : Int) -> Json {
  { "event": kind, "device": id, "attempt": attempt }
}

///|
fn registration_profile(id : String, attempt : Int, write? : Int = 4) -> Json {
  {
    "event": "profile",
    "device": id,
    "attempt": attempt,
    "name": "eufy T9120",
    "services": [
      {
        "uuid": "FFF0",
        "characteristics": [
          { "uuid": "FFF4", "properties": 16 },
          { "uuid": "FFF1", "properties": write },
        ],
      },
    ],
  }
}

///|
test "registration connects on discovery and retains approval after disconnection" {
  let scan = RegistrationScan::new(10, Set([]), 0)
  assert_eq(scan.handle({ "event": "power", "state": 5 }, 0), [
    { "op": "ble_scan" },
  ])
  assert_eq(
    scan.handle(
      {
        "event": "device",
        "device": "scale-a",
        "name": "eufy T9120",
        "services": ["FFF0", "1812"],
        "rssi": -70,
      },
      100,
    ),
    [{ "op": "ble_connect", "device": "scale-a", "attempt": 1 }],
  )
  assert_eq(
    scan.handle(
      { "event": "connected", "device": "scale-a", "attempt": 1 },
      200,
    ),
    [{ "op": "ble_discover", "device": "scale-a", "attempt": 1 }],
  )
  assert_eq(
    scan.handle(
      {
        "event": "profile",
        "device": "scale-a",
        "attempt": 1,
        "name": "eufy T9120",
        "services": [
          {
            "uuid": "FFF0",
            "characteristics": [
              { "uuid": "FFF4", "properties": 16 },
              { "uuid": "FFF1", "properties": 4 },
            ],
          },
        ],
      },
      300,
    ),
    [{ "op": "ble_disconnect", "device": "scale-a", "attempt": 1 }],
  )
  assert_eq(scan.choices().length(), 0)
  assert_eq(
    scan.handle(
      { "event": "disconnected", "device": "scale-a", "attempt": 1 },
      400,
    ),
    [],
  )
  assert_eq(scan.tick(10000), [{ "op": "ble_stop_scan" }])
  assert_true(scan.finished())
  // Returning to the PC after the scale sleeps needs no further BLE operation.
  assert_eq(scan.tick(60000), [])
  assert_eq(scan.choices().map(c => c.name), ["eufy T9120"])
}

///|
test "registration checks two scales immediately and isolates a rejected profile" {
  let scan = RegistrationScan::new(10, Set([]), 0)
  ignore(scan.handle({ "event": "power", "state": 5 }, 0))
  assert_eq(scan.handle(registration_advertisement("a"), 100), [
    { "op": "ble_connect", "device": "a", "attempt": 1 },
  ])
  assert_eq(scan.handle(registration_advertisement("b"), 110), [
    { "op": "ble_connect", "device": "b", "attempt": 2 },
  ])
  assert_eq(scan.handle(registration_advertisement("a"), 120), [])
  ignore(scan.handle(registration_callback("connected", "a", 1), 200))
  ignore(scan.handle(registration_callback("connected", "b", 2), 210))
  assert_eq(scan.handle(registration_profile("b", 1), 220), [])
  assert_eq(scan.handle(registration_profile("a", 1, write=8), 300), [
    { "op": "ble_disconnect", "device": "a", "attempt": 1 },
  ])
  assert_eq(scan.handle(registration_profile("b", 2), 310), [
    { "op": "ble_disconnect", "device": "b", "attempt": 2 },
  ])
  ignore(scan.handle(registration_callback("disconnected", "a", 1), 400))
  ignore(scan.handle(registration_callback("disconnected", "b", 2), 410))
  ignore(scan.tick(10000))
  assert_true(scan.finished())
  assert_eq(scan.choices().map(c => c.id), ["b"])
  match scan.seen.get("a").unwrap().phase {
    Rejected(message) => {
      assert_true(message.contains("FFF1 write without response"))
      assert_true(message.contains("\"properties\":8"))
    }
    _ => fail("bad profile was accepted")
  }
}

///|
test "registration skips known devices and merges unnamed advertisements" {
  let scan = RegistrationScan::new(10, Set(["known"]), 0)
  ignore(scan.handle({ "event": "power", "state": 5 }, 0))
  assert_eq(scan.handle(registration_advertisement("known"), 100), [])
  assert_eq(
    scan.handle(
      registration_advertisement("other", name="eufy T9148", services=["FFF0"]),
      100,
    ),
    [],
  )
  assert_eq(scan.handle(registration_advertisement("unknown", name=""), 100), [])
  assert_eq(
    scan.handle(
      registration_advertisement("unknown", name="", services=["FFF0"]),
      200,
    ),
    [{ "op": "ble_connect", "device": "unknown", "attempt": 3 }],
  )
  assert_eq(scan.choices().map(c => c.id), ["known"])
}

///|
test "registration finishes checks discovered near the search deadline" {
  let scan = RegistrationScan::new(1, Set([]), 0)
  ignore(scan.handle({ "event": "power", "state": 5 }, 0))
  ignore(scan.handle(registration_advertisement("a"), 900))
  assert_eq(scan.tick(1000), [{ "op": "ble_stop_scan" }])
  assert_false(scan.finished())
  assert_eq(scan.handle(registration_advertisement("late"), 1001), [])
  ignore(scan.handle(registration_callback("connected", "a", 1), 1100))
  ignore(scan.handle(registration_profile("a", 1), 1200))
  assert_false(scan.finished())
  ignore(scan.handle(registration_callback("disconnected", "a", 1), 1300))
  assert_true(scan.finished())
  assert_eq(scan.choices().map(c => c.id), ["a"])
}

///|
test "registration cancellation has one shared deadline and cannot save approvals" {
  let scan = RegistrationScan::new(10, Set([]), 0)
  ignore(scan.handle({ "event": "power", "state": 5 }, 0))
  ignore(scan.handle(registration_advertisement("a"), 100))
  ignore(scan.handle(registration_advertisement("b"), 110))
  let commands = scan.abort("operation cancelled", 200)
  assert_eq(commands.length(), 3)
  assert_eq(
    commands.filter(c => string_field(c, "op") == "ble_disconnect").length(),
    2,
  )
  assert_eq(scan.abort("operation cancelled", 300), [])
  assert_false(scan.finished())
  ignore(scan.tick(5200))
  assert_true(scan.finished())
  assert_eq(scan.failure, Some("operation cancelled"))
  assert_eq(scan.choices().length(), 0)
}

///|
test "registration rejects late shared failure after successful verification" {
  let scan = RegistrationScan::new(1, Set([]), 0)
  ignore(scan.handle({ "event": "power", "state": 5 }, 0))
  ignore(scan.handle(registration_advertisement("a"), 100))
  ignore(scan.handle(registration_callback("connected", "a", 1), 200))
  ignore(scan.handle(registration_profile("a", 1), 300))
  ignore(scan.handle(registration_callback("disconnected", "a", 1), 400))
  ignore(scan.handle({ "event": "fatal", "message": "queue overflow" }, 400))
  assert_true(scan.finished())
  assert_eq(scan.failure, Some("queue overflow"))
  assert_eq(scan.choices().length(), 0)
}

///|
test "registration times out power, connection, and discovery without approving" {
  let waiting = RegistrationScan::new(1, Set([]), 0)
  ignore(waiting.tick(30000))
  assert_true(waiting.finished())
  assert_true(waiting.failure is Some(_))
  for connected in [false, true] {
    let scan = RegistrationScan::new(1, Set([]), 0)
    ignore(scan.handle({ "event": "power", "state": 5 }, 0))
    ignore(scan.handle(registration_advertisement("a"), 100))
    if connected {
      ignore(scan.handle(registration_callback("connected", "a", 1), 200))
    }
    ignore(scan.tick(1000))
    assert_eq(scan.tick(10200), [
      { "op": "ble_disconnect", "device": "a", "attempt": 1 },
    ])
    ignore(scan.handle(registration_callback("disconnected", "a", 1), 10300))
    assert_true(scan.finished())
    assert_eq(scan.choices().length(), 0)
  }
}
