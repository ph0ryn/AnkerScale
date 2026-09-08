///|
fn service_status(options : Options) -> Unit raise {
  let registry = read_registry()
  let probe = os("service_probe")
  let active : Bool = @json.from_json(field(probe, "writer_active"))
  let values : Map[String, Json] = @json.from_json(probe)
  values["configuration"] = { "version": 1, "devices": registry.devices }
  values["registry_source"] = registry.source.to_json()
  values["devices"] = registry.devices
    .map(device => {
      let result : Json = {
        "id": device.id,
        "name": device.name,
        "phase": if active {
          "Unknown"
        } else {
          "Inactive"
        },
        "last_state": Json::null(),
        "last_error": Json::null(),
      }
      result
    })
    .to_json()
  values["last_saved"] = Json::null()
  values["last_event"] = Json::null()
  if @json.from_json(field(probe, "database_exists")) {
    let path = string_field(probe, "database")
    with_db(path, writable=false, db => {
      let saved = db.query(
        "SELECT r.received_at,m.weight_centi_kg,r.origin FROM measurements m JOIN raw_packets r ON r.id=m.raw_id ORDER BY r.id DESC LIMIT 1",
      )
      let events = db.query(
        "SELECT received_at,kind,detail FROM events ORDER BY id DESC LIMIT 1",
      )
      values["last_saved"] = if saved.is_empty() {
        Json::null()
      } else {
        saved[0]
      }
      values["last_event"] = if events.is_empty() {
        Json::null()
      } else {
        events[0]
      }
      let runs = db.query(
        "SELECT run_id,detail FROM events WHERE kind='started' ORDER BY id DESC LIMIT 1",
      )
      let run_id = if runs.is_empty() {
        ""
      } else {
        string_field(runs[0], "run_id")
      }
      let current_writer = !runs.is_empty() &&
        active &&
        @json.parse(string_field(runs[0], "detail"))
        is { "pid": Number(pid, ..), .. } &&
        field(probe, "writer_pid") == pid.to_json()
      values["devices"] = registry.devices
        .map(device => {
          let states = db.query(
            "SELECT run_id,received_at,detail FROM events WHERE kind='state' AND json_extract(detail,'$.device')=? ORDER BY id DESC LIMIT 1",
            args=[device.id.to_json()],
          )
          let errors = db.query(
            "SELECT received_at,detail FROM events WHERE kind='device_error' AND json_extract(detail,'$.device')=? ORDER BY id DESC LIMIT 1",
            args=[device.id.to_json()],
          )
          let mut phase = if active { "Unknown" } else { "Inactive" }
          let last_state : Json = if states.is_empty() {
            Json::null()
          } else {
            let row = states[0]
            let detail = @json.parse(string_field(row, "detail"))
            if current_writer && string_field(row, "run_id") == run_id {
              phase = string_field(detail, "phase")
            }
            { "received_at": field(row, "received_at"), "detail": detail }
          }
          let last_error : Json = if errors.is_empty() {
            Json::null()
          } else {
            let row = errors[0]
            {
              "received_at": field(row, "received_at"),
              "detail": @json.parse(string_field(row, "detail")),
            }
          }
          let result : Json = {
            "id": device.id,
            "name": device.name,
            "phase": phase,
            "last_state": last_state,
            "last_error": last_error,
          }
          result
        })
        .to_json()
    }) catch {
      error => {
        values["storage_error"] = error.to_string().to_json()
        println(
          if options.json {
            values.to_json().stringify()
          } else {
            service_text(values.to_json())
          },
        )
        raise DataError("cannot inspect storage: \{error}")
      }
    }
  }
  println(
    if options.json {
      values.to_json().stringify()
    } else {
      service_text(values.to_json())
    },
  )
}

///|
fn service_action_result(options : Options) -> Unit raise {
  if options.json {
    service_status(options)
  } else {
    println(
      if options.positional[0] == "start" {
        "Service started."
      } else {
        "Service stopped."
      },
    )
  }
}

///|
fn service(options : Options) -> Unit raise {
  if options.positional.length() != 1 {
    raise UsageError("service requires start, stop, or status")
  }
  let command = options.positional[0]
  match command {
    "status" => service_status(options)
    "start" => {
      with_registry_lock(() => {
        let registry = read_registry()
        require_registered(registry)
        let probe = os("service_probe")
        let status = string_field(probe, "registration")
        if status != "enabled" &&
          status != "requires_approval" &&
          @json.from_json(field(probe, "writer_active")) {
          raise DataError(
            "stop the foreground collector before registering the service",
          )
        }
        if registry.source == "legacy" {
          write_registry(registry, registry.devices)
        }
        if status != "enabled" && status != "requires_approval" {
          ignore(os("service_register"))
        }
      })
      // Approval must be granted before launchctl can start the agent.
      ignore(service_completed("start", os("service_probe"), Json::null()))
      let pid = os("service_kickstart")
      wait_for_service("start", pid)
      service_action_result(options)
    }
    "stop" => {
      let probe = os("service_probe")
      let status = string_field(probe, "registration")
      if status != "not_registered" && status != "not_found" {
        if status == "enabled" {
          let signalled : Bool = @json.from_json(os("service_signal"))
          if signalled {
            let deadline = number_field(os("now"), "mono_ms") + 10000
            while @json.from_json(field(os("service_probe"), "writer_active")) {
              if number_field(os("now"), "mono_ms") >= deadline {
                raise DataError(
                  "collector did not finish saving before the stop deadline; service remains registered",
                )
              }
              ignore(os("service_wait"))
            }
          }
        }
        ignore(os("service_unregister"))
      }
      wait_for_service("stop", Json::null())
      service_action_result(options)
    }
    "run" => {
      ignore(os("service_log"))
      let registry = read_registry()
      if registry.source == "missing" {
        raise DataError(
          "No device registration file. Run ankerscale register first.",
        )
      }
      let path = string_field(os("paths"), "db")
      with_db(path, writable=true, db => collect(db, registry))
    }
    _ => raise UsageError("service requires start, stop, or status")
  }
}

///|
fn service_completed(command : String, probe : Json, pid : Json) -> Bool raise {
  let registration = string_field(probe, "registration")
  if registration == "not_found" {
    raise DataError(
      "service definition not found; check ankerscale service status",
    )
  }
  let active : Bool = @json.from_json(field(probe, "writer_active"))
  if command == "start" {
    if registration == "requires_approval" {
      raise DataError(
        "Approval required. Allow AnkerScale in System Settings > General > Login Items, then run ankerscale service start again.",
      )
    }
    if registration != "enabled" {
      raise DataError(
        "service did not become enabled; check ankerscale service status",
      )
    }
    return active && pid != Json::null() && field(probe, "writer_pid") == pid
  }
  registration == "not_registered" && !active
}

///|
fn wait_for_service(command : String, pid : Json) -> Unit raise {
  let deadline = number_field(os("now"), "mono_ms") + 10000
  while true {
    let probe = os("service_probe")
    if service_completed(command, probe, pid) &&
      (command == "stop" || service_initialized(probe, pid)) {
      return
    }
    if number_field(os("now"), "mono_ms") >= deadline {
      raise DataError(
        "service \{command} did not complete within 10 seconds; check ankerscale service status and collector.log",
      )
    }
    ignore(os("service_wait"))
  }
}

///|
fn service_initialized(probe : Json, pid : Json) -> Bool raise {
  if !@json.from_json(field(probe, "database_exists")) {
    return false
  }
  let db = @native.open(string_field(probe, "database"), writable=false)
  defer db.close()
  // A fresh database may still be inside its schema creation transaction.
  if int_field(db.query("PRAGMA user_version")[0], "user_version") == 0 {
    return false
  }
  schema(db, writable=false)
  let runs = db.query(
    "SELECT detail FROM events WHERE kind='started' ORDER BY id DESC LIMIT 1",
  )
  !runs.is_empty() &&
  field(@json.parse(string_field(runs[0], "detail")), "pid") == pid &&
  service_completed("start", os("service_probe"), pid)
}
