///|
fn service_status() -> Unit raise {
  let probe = os("service_probe")
  let values : Map[String, Json] = @json.from_json(probe)
  if @json.from_json(field(probe, "config_exists")) {
    values["configuration"] = os("service_config_read")
  }
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
    }) catch {
      error => {
        values["storage_error"] = error.to_string().to_json()
        println(values.to_json().stringify())
        raise DataError("cannot inspect storage: \{error}")
      }
    }
  } else {
    values["last_saved"] = Json::null()
    values["last_event"] = Json::null()
  }
  println(values.to_json().stringify())
}

///|
fn service(options : Options) -> Unit raise {
  if options.positional.length() != 1 {
    raise UsageError("service requires start, stop, or status")
  }
  let command = options.positional[0]
  if command != "start" && options.values.contains("--device") {
    raise UsageError("--device is only valid for service start")
  }
  match command {
    "status" => service_status()
    "start" => {
      let target = required(options, "--device")
      let probe = os("service_probe")
      let status = string_field(probe, "registration")
      if status == "enabled" || status == "requires_approval" {
        let config = os("service_config_read")
        if string_field(config, "device") != target {
          raise UsageError(
            "stop the service before selecting a different device",
          )
        }
        if status == "enabled" {
          ignore(os("service_kickstart"))
        }
      } else {
        if @json.from_json(field(probe, "writer_active")) {
          raise DataError(
            "stop the foreground collector before registering the service",
          )
        }
        ignore(@native.call({ "op": "service_config_write", "device": target }))
        ignore(os("service_register"))
      }
      service_status()
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
      service_status()
    }
    "run" => {
      ignore(os("service_log"))
      let config = os("service_config_read")
      let target = device_id(string_field(config, "device"))
      let path = string_field(os("paths"), "db")
      with_db(path, writable=true, db => collect(db, target))
    }
    _ => raise UsageError("service requires start, stop, or status")
  }
}
