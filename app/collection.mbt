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
      if uuid == "FFF1" && (properties & 12) != 0 {
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
fn send(command : @protocol.CollectionCommand) -> Unit raise {
  let (device, attempt, action) = match command {
    Scan => {
      ignore(os("ble_scan"))
      return
    }
    StopScan => {
      ignore(os("ble_stop_scan"))
      return
    }
    Device(device, attempt, action) => (device, attempt, action)
  }
  let request : Json = match action {
    Scan | StopScan =>
      raise DataError("device controller cannot own the shared scan")
    Connect(_, _) => { "op": "ble_connect" }
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
  let fields : Map[String, Json] = @json.from_json(request)
  fields["device"] = device.to_json()
  fields["attempt"] = attempt.to_json()
  ignore(@native.call(fields.to_json()))
}

///|
priv struct DeviceState {
  phase : @protocol.Phase
  attempt : Int
  error : String?
} derive(Eq)

///|
priv struct Collection {
  db : @native.Database
  run_id : String
  controller : @protocol.Collector
  states : Map[String, DeviceState]
}

///|
fn Collection::log_state(
  self : Collection,
  device : String,
  state : DeviceState,
) -> Unit raise {
  let error : Json = match state.error {
    Some(message) => message.to_json()
    None => Json::null()
  }
  let detail : Json = {
    "device": device,
    "phase": @debug.to_string(state.phase),
    "attempt": state.attempt,
    "error": error,
  }
  event_log(self.db, self.run_id, "state", detail)
  @native.stderr(detail.stringify())
}

///|
fn Collection::record_states(self : Collection) -> Unit raise {
  for device in self.states.keys().to_array() {
    if !self.controller.controllers.contains(device) {
      let previous = self.states[device]
      self.log_state(device, { ..previous, phase: @protocol.Stopped, })
      self.states.remove(device)
    }
  }
  for device, controller in self.controller.controllers {
    let error = match controller.failure {
      Some(_) => controller.failure
      None => controller.last_error
    }
    let state : DeviceState = {
      phase: controller.phase,
      attempt: controller.attempt,
      error,
    }
    if self.states.get(device) != Some(state) {
      self.log_state(device, state)
      if state.error is Some(message) &&
        self.states.get(device).map(previous => previous.error) !=
        Some(state.error) {
        event_log(self.db, self.run_id, "device_error", {
          "device": device,
          "attempt": state.attempt,
          "message": message,
        })
      }
      self.states[device] = state
    }
  }
}

///|
fn Collection::execute(
  self : Collection,
  commands : Array[@protocol.CollectionCommand],
) -> Unit raise {
  let mut pending = commands
  let mut index = 0
  self.record_states()
  while index < pending.length() {
    if @json.from_json(os("stopping")) && !self.controller.stopping {
      pending = self.controller.handle(
        Stop,
        "",
        0,
        number_field(os("now"), "mono_ms"),
      )
      index = 0
      self.record_states()
      continue
    }
    let command = pending[index]
    index += 1
    if self.controller.stopping {
      match command {
        StopScan | Device(_, _, Disconnect) => ()
        _ => continue
      }
    }
    send(command) catch {
      error => {
        let now = number_field(os("now"), "mono_ms")
        let (device, attempt) = match command {
          Device(device, attempt, _) => (device, attempt)
          _ => ("", 0)
        }
        let detail : Json = {
          "device": device,
          "attempt": attempt,
          "message": error.to_string(),
        }
        event_log(
          self.db,
          self.run_id,
          if device.is_empty() {
            "command_error"
          } else {
            "device_error"
          },
          detail,
        )
        @native.stderr(detail.stringify())
        let recovery = match command {
          Scan => self.controller.handle(Failed, "", 0, now)
          Device(_, _, Disconnect) | StopScan =>
            self.controller.handle(Fatal(error.to_string()), "", 0, now)
          Device(_, _, _) =>
            self.controller.handle(Failed, device, attempt, now)
        }
        pending = pending + recovery
        self.record_states()
      }
    }
  }
}

///|
fn Collection::advance(
  self : Collection,
  event : @protocol.CollectionEvent,
  device : String,
  attempt : Int,
) -> Unit raise {
  let now = number_field(os("now"), "mono_ms")
  if @json.from_json(os("stopping")) && !self.controller.stopping {
    self.execute(self.controller.handle(Stop, "", 0, now))
  }
  self.execute(self.controller.handle(event, device, attempt, now))
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
          "\{incoming.utc}  \{incoming.device}  \{@protocol.weight_text(value.weight_centi_kg)} kg",
        )
      }
    }
  } else {
    event_log(db, run_id, kind, event)
    if kind == "failed" ||
      event is { "event": String("disconnected"), "failed": True, .. } {
      event_log(db, run_id, "device_error", event)
    }
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
fn collect(db : @native.Database, initial : Registry) -> Unit raise {
  let run_id : String = @json.from_json(os("uuid"))
  let collection : Collection = {
    db,
    run_id,
    controller: @protocol.Collector::new(
      initial.devices.map(device => device.id),
    ),
    states: Map([]),
  }
  let mut registry = initial
  let mut reload_at = number_field(os("now"), "mono_ms") + 1000
  ignore(
    @native.call({
      "op": "ble_start",
      "devices": registry.devices.map(device => device.id),
    }),
  )
  let mut closed = false
  let mut pending : Array[Json] = []
  let mut processed = 0
  defer {
    // A storage failure is fatal. Retain any uncommitted notifications on stderr
    // instead of pretending that closing the transport saved them.
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
  event_log(db, run_id, "started", {
    "devices": registry.devices,
    "pid": os("pid"),
  })
  collection.record_states()
  while !collection.controller.stopped() {
    let now = number_field(os("now"), "mono_ms")
    if @json.from_json(os("stopping")) {
      collection.advance(Stop, "", 0)
    }
    if now >= reload_at && !collection.controller.stopping {
      let next = read_registry(allow_legacy=registry.source != "current") catch {
        error => {
          collection.advance(
            Fatal("cannot reload device registrations: \{error}"),
            "",
            0,
          )
          continue
        }
      }
      if next.source == "missing" {
        collection.advance(Fatal("device registration file disappeared"), "", 0)
      } else {
        if next.devices != registry.devices {
          ignore(
            @native.call({
              "op": "ble_targets",
              "devices": next.devices.map(device => device.id),
            }),
          )
          collection.execute(
            collection.controller.update_devices(
              next.devices.map(device => device.id),
              now,
            ),
          )
          event_log(db, run_id, "registrations_changed", {
            "devices": next.devices,
          })
        }
        registry = next
      }
      reload_at = now + 1000
    }
    if collection.controller.stopped() {
      break
    }
    let wait = collection.controller.wait_ms(now)
    let timeout = if collection.controller.stopping {
      wait
    } else {
      wait.min((reload_at - now).max(0).to_int())
    }
    pending = @json.from_json(
      @native.call({ "op": "ble_poll", "timeout_ms": timeout }),
    )
    processed = 0
    for event in pending {
      save_event(db, run_id, event)
      processed += 1
      let attempt : Int = @json.from_json(field(event, "attempt"))
      let device = match event {
        { "device": String(device), .. } => device
        _ => ""
      }
      collection.advance(collection_event(event), device, attempt)
    }
    collection.advance(Tick, "", 0)
  }
  pending = @json.from_json(os("ble_close"))
  processed = 0
  closed = true
  let mut failure = collection.controller.failure
  for event in pending {
    save_event(db, run_id, event)
    processed += 1
    if string_field(event, "event") == "fatal" {
      failure = Some(string_field(event, "message"))
    }
  }
  let error : Json = match failure {
    Some(message) => message.to_json()
    None => Json::null()
  }
  event_log(db, run_id, "stopped", { "error": error })
  if failure is Some(message) {
    raise DataError(message)
  }
}
