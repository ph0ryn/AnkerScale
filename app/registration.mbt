///|
fn send_registration_commands(
  scan : RegistrationScan,
  commands : Array[Json],
) -> Unit raise {
  for command in commands {
    let op = string_field(command, "op")
    if op == "ble_scan" {
      @native.stderr(
        "Scanning for \{scan.seconds} seconds. Wake your scales now; each will be checked as soon as it is found.",
      )
    } else if op == "ble_connect" {
      @native.stderr("Verifying \{string_field(command, "device")}...")
    }
    ignore(@native.call(command)) catch {
      error => {
        let now = number_field(os("now"), "mono_ms")
        let follow_up = if (op == "ble_connect" || op == "ble_discover") &&
          scan.seen.get(string_field(command, "device")) is Some(candidate) {
          candidate.cancel(Err(error.to_string()), now)
        } else {
          scan.abort(error.to_string(), now)
        }
        send_registration_commands(scan, follow_up)
      }
    }
  }
}

///|
fn poll_registration(scan : RegistrationScan) -> Unit raise {
  let events : Array[Json] = @json.from_json(
    @native.call({ "op": "ble_poll", "timeout_ms": 1000 }),
  )
  for event in events {
    send_registration_commands(
      scan,
      scan.handle(event, number_field(os("now"), "mono_ms")),
    )
  }
  send_registration_commands(
    scan,
    scan.tick(number_field(os("now"), "mono_ms")),
  )
}

///|
fn scan_candidates(
  seconds : Int,
  registered : Set[String],
) -> Array[Candidate] raise {
  let scan = RegistrationScan::new(
    seconds,
    registered,
    number_field(os("now"), "mono_ms"),
  )
  @native.stderr("Waiting for Bluetooth (up to 30 seconds).")
  // Cancel all outstanding checks together, preserving the original error.
  errdefer (try {
    send_registration_commands(
      scan,
      scan.abort("registration interrupted", number_field(os("now"), "mono_ms")),
    )
    while !scan.finished() {
      poll_registration(scan)
    }
  } catch {
    cleanup_error => @native.stderr(cleanup_error.to_string())
  })
  while !scan.finished() {
    check_interrupted()
    poll_registration(scan)
  }
  if scan.failure is Some(message) {
    raise DataError(message)
  }
  let rejected = scan.seen
    .values()
    .filter(c => c.phase is Rejected(_))
    .to_array()
  rejected.sort_by((a, b) => a.id.compare(b.id))
  for candidate in rejected {
    if candidate.phase is Rejected(message) {
      @native.stderr(
        "Could not verify \{display_device({ id: candidate.id, name: candidate.name })}: \{message}",
      )
    }
  }
  scan.choices()
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
    let candidates = scan_candidates(seconds, registered)
    // No live connection or pending callback may cross the user-input boundary.
    let pending : Array[Json] = @json.from_json(os("ble_close"))
    closed = true
    for event in pending {
      if collection_event(event) is Fatal(message) {
        raise DataError(message)
      }
    }
    check_interrupted()
    if candidates.is_empty() {
      println(
        "No verified scales found. Run ankerscale register again, then wake your scales while it scans.",
      )
      return
    }
    println(
      "Checks complete. You can select devices even if the scales have turned off.",
    )
    for i, candidate in candidates {
      let device = { id: candidate.id, name: candidate.name, }
      let suffix = if registered.contains(candidate.id) {
        "  [registered]"
      } else {
        "  [verified]"
      }
      println(
        "\{i + 1}. \{display_device(device)}  \{candidate.rssi} dBm\{suffix}",
      )
    }
    let selected = select_devices(candidates.length())
    let added : Array[RegisteredDevice] = []
    for i in selected {
      let candidate = candidates[i]
      if !registered.contains(candidate.id) {
        added.push({ id: candidate.id, name: candidate.name, })
      }
    }
    if added.is_empty() {
      println("Registration unchanged.")
      return
    }
    write_registry(registry, registry.devices + added)
    println("Registered \{added.length()} device(s).")
  })
}
