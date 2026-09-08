///|
priv struct Candidate {
  id : String
  mut name : String
  services : Set[String]
  mut rssi : Int
}

///|
fn Candidate::matches(self : Candidate) -> Bool {
  self.name == "eufy T9120" ||
  (self.name.is_empty() && self.services.contains("FFF0"))
}

///|
fn scan_candidates(seconds : Int) -> Array[Candidate] raise {
  let seen : Map[String, Candidate] = Map([])
  let mut scanning = false
  let mut deadline = number_field(os("now"), "mono_ms") + 30000
  @native.stderr("Wake your scales. Waiting for Bluetooth (up to 30 seconds).")
  while number_field(os("now"), "mono_ms") < deadline {
    check_interrupted()
    let events : Array[Json] = @json.from_json(
      @native.call({ "op": "ble_poll", "timeout_ms": 1000 }),
    )
    for event in events {
      match collection_event(event) {
        PoweredOn =>
          if !scanning {
            ignore(os("ble_scan"))
            scanning = true
            deadline = number_field(os("now"), "mono_ms") +
              seconds.to_double() * 1000
            @native.stderr("Scanning for \{seconds} seconds...")
          }
        PoweredOff =>
          if scanning {
            raise DataError(
              "Bluetooth was turned off during registration; retry when it is on",
            )
          }
        Fatal(message) => raise DataError(message)
        Found(id) => {
          let name = string_field(event, "name")
          let rssi : Int = @json.from_json(field(event, "rssi"))
          let candidate = match seen.get(id) {
            Some(candidate) => candidate
            None => {
              let candidate = { id, name, rssi, services: Set([]), }
              seen[id] = candidate
              candidate
            }
          }
          if !name.is_empty() {
            candidate.name = name
          }
          candidate.rssi = rssi
          let services : Array[String] = @json.from_json(
            field(event, "services"),
          )
          for service in services {
            candidate.services.add(service)
          }
        }
        _ => ()
      }
    }
  }
  check_interrupted()
  if !scanning {
    raise DataError(
      "Bluetooth was not powered on before the registration deadline",
    )
  }
  ignore(os("ble_stop_scan"))
  let candidates = seen
    .values()
    .filter(candidate => candidate.matches())
    .to_array()
  candidates.sort_by((a, b) => a.id.compare(b.id))
  candidates
}

///|
fn disconnect_registration(id : String, attempt : Int) -> Unit raise {
  ignore(
    @native.call({ "op": "ble_disconnect", "device": id, "attempt": attempt }),
  )
  let deadline = number_field(os("now"), "mono_ms") + 5000
  while number_field(os("now"), "mono_ms") < deadline {
    let mut finished = false
    let events : Array[Json] = @json.from_json(
      @native.call({ "op": "ble_poll", "timeout_ms": 1000 }),
    )
    for event in events {
      match collection_event(event) {
        Disconnected =>
          if string_field(event, "device") == id &&
            int_field(event, "attempt") == attempt.to_int64() {
            finished = true
          }
        PoweredOff => finished = true
        Fatal(message) => raise DataError(message)
        _ => ()
      }
    }
    if finished {
      return
    }
  }
  raise DataError(
    "Bluetooth cancellation timed out for \{id}; registration unchanged",
  )
}

///|
fn verify_registration(id : String, attempt : Int) -> RegisteredDevice raise {
  check_interrupted()
  ignore(
    @native.call({ "op": "ble_connect", "device": id, "attempt": attempt }),
  )
  let mut needs_cancel = true
  defer (if needs_cancel {
    disconnect_registration(id, attempt) catch {
      error => @native.stderr(error.to_string())
    }
  })
  let mut stage = "connection"
  let mut deadline = number_field(os("now"), "mono_ms") + 10000
  while number_field(os("now"), "mono_ms") < deadline {
    check_interrupted()
    let mut verified_name : String? = None
    let events : Array[Json] = @json.from_json(
      @native.call({ "op": "ble_poll", "timeout_ms": 1000 }),
    )
    for event in events {
      match collection_event(event) {
        PoweredOff => {
          needs_cancel = false
          raise DataError("Bluetooth was turned off; registration unchanged")
        }
        Fatal(message) => raise DataError(message)
        _ => ()
      }
      if event
        is { "device": String(device), "attempt": Number(generation, ..), .. } &&
        device == id &&
        generation == attempt.to_double() {
        match collection_event(event) {
          Connected =>
            if stage == "connection" {
              ignore(
                @native.call({
                  "op": "ble_discover",
                  "device": id,
                  "attempt": attempt,
                }),
              )
              stage = "GATT discovery"
              deadline = number_field(os("now"), "mono_ms") + 10000
            }
          Profile(verified) =>
            if stage == "GATT discovery" {
              if !verified {
                raise DataError(
                  "unsupported device name or GATT profile for \{id}; registration unchanged",
                )
              }
              verified_name = Some(string_field(event, "name"))
            }
          Disconnected => {
            needs_cancel = false
            if verified_name is None {
              raise DataError(
                "device \{id} disconnected before verification; registration unchanged",
              )
            }
          }
          Failed =>
            raise DataError(
              "Bluetooth verification failed for \{id}; registration unchanged",
            )
          _ => ()
        }
      }
    }
    if verified_name is Some(name) {
      // A fatal event may follow the profile in the same poll. Validate the
      // entire batch, and attempt an explicit cancellation only once.
      if needs_cancel {
        needs_cancel = false
        disconnect_registration(id, attempt)
      }
      return { id, name, }
    }
  }
  raise DataError("\{stage} timed out for \{id}; registration unchanged")
}

///|
fn register(options : Options) -> Unit raise {
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
  with_registry_lock(() => {
    let registry = read_registry()
    let registered : Set[String] = Set(
      registry.devices.map(device => device.id),
    )
    ignore(os("ble_start"))
    let mut closed = false
    defer (if !closed {
      ignore(
        os("ble_close") catch {
          error => {
            @native.stderr(error.to_string())
            Json::null()
          }
        },
      )
    })
    let candidates = scan_candidates(seconds)
    if candidates.is_empty() {
      println(
        "No matching scales found. Wake a scale and run ankerscale register again.",
      )
    }
    for i, candidate in candidates {
      let device = { id: candidate.id, name: candidate.name, }
      let suffix = if registered.contains(candidate.id) {
        "  [registered]"
      } else {
        ""
      }
      println(
        "\{i + 1}. \{display_device(device)}  \{candidate.rssi} dBm\{suffix}",
      )
    }
    let selected = if candidates.is_empty() {
      []
    } else {
      select_devices(candidates.length())
    }
    let added : Array[RegisteredDevice] = []
    for i in selected {
      let candidate = candidates[i]
      if !registered.contains(candidate.id) {
        @native.stderr(
          "Verifying \{display_device({ id: candidate.id, name: candidate.name })}...",
        )
        added.push(verify_registration(candidate.id, i + 1))
      }
    }
    let pending : Array[Json] = @json.from_json(os("ble_close"))
    closed = true
    for event in pending {
      if collection_event(event) is Fatal(message) {
        raise DataError(message)
      }
    }
    if added.is_empty() {
      if !candidates.is_empty() {
        println("Registration unchanged.")
      }
      return
    }
    write_registry(registry, registry.devices + added)
    println("Registered \{added.length()} device(s).")
  })
}
