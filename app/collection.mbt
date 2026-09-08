///|
fn number_field(value : Json, key : String) -> Double raise {
  @json.from_json(field(value, key))
}

///|
fn device_id(value : String) -> String raise {
  @json.from_json(@native.call({ "op": "validate_device", "device": value })) catch {
    e => raise UsageError(e.to_string())
  }
}

///|
fn verified_profile(event : Json) -> Bool raise {
  if string_field(event, "name") != "eufy T9120" {
    return false
  }
  let services : Array[Json] = @json.from_json(field(event, "services"))
  for service in services {
    if string_field(service, "uuid") != "FFF0" {
      continue
    }
    let chars : Array[Json] = @json.from_json(field(service, "characteristics"))
    let mut notify = false
    let mut write = false
    for characteristic in chars {
      let properties : Int = @json.from_json(
        field(characteristic, "properties"),
      )
      let uuid = string_field(characteristic, "uuid")
      if uuid == "FFF4" && (properties & 48) != 0 {
        notify = true
      }
      if uuid == "FFF1" && (properties & 4) != 0 {
        write = true
      }
    }
    if notify && write {
      return true
    }
  }
  false
}

///|
fn event_log(
  db : @native.Database,
  run_id : String,
  kind : String,
  detail : Json,
) -> Unit raise {
  let utc = match detail {
    { "utc": String(value), .. } => value
    _ => string_field(os("now"), "utc")
  }
  db.exec(
    "INSERT INTO events(run_id,received_at,kind,detail) VALUES(?,?,?,?)",
    args=[
      run_id.to_json(),
      utc.to_json(),
      kind.to_json(),
      detail.stringify().to_json(),
    ],
  )
}

///|
fn send(action : @protocol.Action) -> Unit raise {
  let request : Json = match action {
    Scan => { "op": "ble_scan" }
    StopScan => { "op": "ble_stop_scan" }
    Connect(device, attempt) =>
      { "op": "ble_connect", "device": device, "attempt": attempt }
    Discover => { "op": "ble_discover" }
    Subscribe =>
      { "op": "ble_subscribe", "service": "FFF0", "characteristic": "FFF4" }
    Disconnect => { "op": "ble_disconnect" }
    SetUnit | SetTime | RequestHistory => {
      let payload = match action {
        SetUnit => @protocol.unit_command()
        RequestHistory => b"\xf2\x00"
        _ => {
          let calendar : Array[Int] = @json.from_json(field(os("now"), "local"))
          @protocol.time_command(
            calendar[0],
            calendar[1],
            calendar[2],
            calendar[3],
            calendar[4],
            calendar[5],
          )
        }
      }
      {
        "op": "ble_write",
        "service": "FFF0",
        "characteristic": "FFF1",
        "hex": hex_encode(payload),
      }
    }
  }
  ignore(@native.call(request))
}

///|
fn drive(
  db : @native.Database,
  run_id : String,
  controller : @protocol.Controller,
  event : @protocol.CollectionEvent,
  attempt : Int,
  now : Double,
) -> Unit raise {
  let previous = controller.phase
  let actions = if @json.from_json(os("stopping")) {
    controller.handle(Stop, controller.attempt, now) +
    controller.handle(event, attempt, now)
  } else {
    controller.handle(event, attempt, now)
  }
  if previous != controller.phase {
    let detail : Json = {
      "phase": @debug.to_string(controller.phase),
      "attempt": controller.attempt,
    }
    event_log(db, run_id, "state", detail)
    @native.stderr(detail.stringify())
  }
  for action in actions {
    send(action) catch {
      error => {
        event_log(db, run_id, "command_error", { "message": error.to_string() })
        @native.stderr(error.to_string())
        let recovery = controller.handle(
          @protocol.Failed,
          controller.attempt,
          now,
        )
        for command in recovery {
          send(command)
        }
        break
      }
    }
  }
}

///|
fn save_event(
  db : @native.Database,
  run_id : String,
  event : Json,
) -> Unit raise {
  let kind = string_field(event, "event")
  if kind == "packet" {
    let incoming : Incoming = @json.from_json(event)
    if ingest(
        db,
        incoming,
        run_id,
        "ble",
        direction=string_field(event, "direction"),
      ) {
      let reading = @protocol.parse_t9120(hex_decode(incoming.hex))
      if reading is Stable(value) {
        println(
          "\{incoming.utc}  \{@protocol.weight_text(value.weight_centi_kg)} kg",
        )
      }
    }
  } else {
    event_log(db, run_id, kind, event)
    if kind == "profile" || kind == "device" {
      db.exec(
        "INSERT INTO devices VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,services=excluded.services,last_seen=excluded.last_seen",
        args=[
          field(event, "device"),
          field(event, "name"),
          field(event, "services").stringify().to_json(),
          field(event, "utc"),
          field(event, "utc"),
        ],
      )
    }
  }
}

///|
fn collection_event(event : Json) -> @protocol.CollectionEvent raise {
  match string_field(event, "event") {
    "power" =>
      match int_field(event, "state") {
        5 => PoweredOn
        3 =>
          Fatal(
            "Bluetooth permission denied; allow AnkerScale in System Settings > Privacy & Security > Bluetooth",
          )
        2 => Fatal("Bluetooth LE is unsupported on this host")
        _ => PoweredOff
      }
    "device" => Found(string_field(event, "device"))
    "connected" => Connected
    "profile" => Profile(verified_profile(event))
    "subscribed" => Subscribed
    "packet" =>
      if string_field(event, "direction") == "rx" {
        Received
      } else {
        Tick
      }
    "disconnected" => Disconnected
    "failed" => Failed
    "fatal" => Fatal(string_field(event, "message"))
    _ => raise DataError("unknown Bluetooth event")
  }
}

///|
fn collect(db : @native.Database, target : String) -> Unit raise {
  let run_id : String = @json.from_json(os("uuid"))
  let controller = @protocol.Controller::new(target)
  ignore(@native.call({ "op": "ble_start", "device": target }))
  let mut closed = false
  let mut pending : Array[Json] = []
  let mut processed = 0
  defer {
    // A storage failure is fatal. Stop OS activity and report any pending raw
    // on stderr so it is not silently discarded when the database is unusable.
    if !closed {
      let remaining : Array[Json] = @json.from_json(os("ble_close")) catch {
        error => {
          @native.stderr(error.to_string())
          []
        }
      }
      pending = pending[processed:].to_owned() + remaining
      processed = 0
    }
    if processed < pending.length() {
      @native.stderr(
        Json::object({ "uncommitted_events": pending[processed:].to_json() }).stringify(),
      )
    }
  }
  event_log(db, run_id, "started", { "device": target })
  while controller.phase != @protocol.Stopped {
    let now = number_field(os("now"), "mono_ms")
    if @json.from_json(os("stopping")) {
      drive(db, run_id, controller, Stop, controller.attempt, now)
    }
    if controller.phase == @protocol.Stopped {
      break
    }
    pending = @json.from_json(
      @native.call({ "op": "ble_poll", "timeout_ms": controller.wait_ms(now) }),
    )
    processed = 0
    for event in pending {
      save_event(db, run_id, event)
      processed += 1
      let attempt : Int = @json.from_json(field(event, "attempt"))
      drive(
        db,
        run_id,
        controller,
        collection_event(event),
        attempt,
        number_field(os("now"), "mono_ms"),
      )
    }
    drive(
      db,
      run_id,
      controller,
      Tick,
      controller.attempt,
      number_field(os("now"), "mono_ms"),
    )
  }
  pending = @json.from_json(os("ble_close"))
  processed = 0
  closed = true
  let mut failure = controller.failure
  for event in pending {
    save_event(db, run_id, event)
    processed += 1
    if string_field(event, "event") == "fatal" {
      failure = Some(string_field(event, "message"))
    }
  }
  event_log(db, run_id, "stopped", { "error": failure })
  if failure is Some(message) {
    raise DataError(message)
  }
}

///|
fn devices(options : Options) -> Unit raise {
  let seconds = match options.values.get("--seconds") {
    None => 10
    Some(value) =>
      @string.parse_int(value) catch {
        _ => raise UsageError("seconds must be from 1 to 300")
      }
  }
  if seconds < 1 || seconds > 300 {
    raise UsageError("seconds must be from 1 to 300")
  }
  ignore(@native.call({ "op": "ble_start" }))
  defer ignore(
    os("ble_close") catch {
      error => {
        @native.stderr(error.to_string())
        Json::null()
      }
    },
  )
  let start = number_field(os("now"), "mono_ms")
  let seen : Set[String] = Set([])
  let mut powered = false
  while number_field(os("now"), "mono_ms") - start < seconds.to_double() * 1000 {
    let events : Array[Json] = @json.from_json(
      @native.call({ "op": "ble_poll", "timeout_ms": 1000 }),
    )
    for event in events {
      match collection_event(event) {
        PoweredOn => {
          powered = true
          ignore(os("ble_scan"))
        }
        PoweredOff => {
          powered = false
          @native.stderr("Waiting for Bluetooth to be powered on.")
        }
        Fatal(message) => raise DataError(message)
        Found(id) =>
          if !seen.contains(id) {
            seen.add(id)
            println(event.stringify())
          }
        _ => ()
      }
    }
  }
  if !powered {
    raise DataError("Bluetooth was not powered on before the scan deadline")
  }
  @native.stderr(
    "Found \{seen.length()} devices. Select the scale UUID with --device.",
  )
}
