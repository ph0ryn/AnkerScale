///|
fn phase_text(phase : String) -> String {
  match phase {
    "WaitingPower" => "Waiting for Bluetooth"
    "Scanning" => "Searching for the scale"
    "Connecting" => "Connecting"
    "Discovering" => "Checking scale services"
    "Subscribing" => "Enabling measurement notifications"
    "Measuring" => "Ready to receive measurements"
    "Disconnecting" => "Disconnecting"
    "Backoff" => "Waiting to retry"
    "Stopping" => "Stopping"
    "Stopped" | "Inactive" => "Not running"
    "Unknown" => "Waiting for device status"
    _ => phase
  }
}

///|
fn detail_text(value : Json) -> String {
  match value {
    Null => "none"
    String(value) => value
    Object(fields) => {
      let keys = fields.keys().to_array()
      keys.sort()
      keys.map(key => "\{key}: \{detail_text(fields[key])}").join("; ")
    }
    Array(values) => values.map(detail_text).join(", ")
    _ => value.stringify()
  }
}

///|
fn diagnostic_text(kind : String, detail : Json) -> String raise {
  if kind == "state" {
    let message = "\{string_field(detail, "device")}: \{phase_text(string_field(detail, "phase"))}"
    return match field(detail, "error") {
      Null => message
      error => "\{message} — \{detail_text(error)}"
    }
  }
  if detail is { "message": String(message), .. } {
    return match detail {
      { "device": String(device), .. } => "\{device}: \{kind} — \{message}"
      _ => "\{kind}: \{message}"
    }
  }
  "\{kind}: \{detail_text(detail)}"
}

///|
fn service_text(value : Json) -> String raise {
  let registration = string_field(value, "registration")
  let active : Bool = @json.from_json(field(value, "writer_active"))
  let lines : Array[String] = []
  lines.push(
    match registration {
      "enabled" => "Login service: enabled"
      "requires_approval" =>
        "Login service: approval required. Allow AnkerScale in System Settings > General > Login Items."
      "not_registered" => "Login service: not registered"
      "not_found" => "Login service: not found"
      _ => "Login service: \{registration}"
    },
  )
  lines.push(
    if active {
      "Collector: running (PID \{detail_text(field(value, "writer_pid"))})"
    } else {
      "Collector: not running"
    },
  )
  let devices : Array[Json] = @json.from_json(field(value, "devices"))
  for device in devices {
    let phase = phase_text(string_field(device, "phase"))
    lines.push(
      "\{string_field(device, "name")} (\{string_field(device, "id")}): \{phase}",
    )
    if field(device, "last_error") is error && error != Json::null() {
      lines.push(
        "  Last recorded error: \{string_field(error, "received_at")} — \{diagnostic_text("error", field(error, "detail"))}",
      )
    }
  }
  lines.push(
    match field(value, "last_saved") {
      Null => "Last saved measurement: none"
      saved => {
        let weight : Int = @json.from_json(field(saved, "weight_centi_kg"))
        "Last saved measurement: \{@protocol.weight_text(weight)} kg at \{string_field(saved, "received_at")} [\{string_field(saved, "origin")}]"
      }
    },
  )
  if field(value, "last_event") is event && event != Json::null() {
    lines.push(
      "Last recorded event: \{string_field(event, "received_at")}  \{diagnostic_text(string_field(event, "kind"), @json.parse(string_field(event, "detail")))}",
    )
  }
  lines.push(
    "Database: \{string_field(value, "database")}" +
    (if @json.from_json(field(value, "database_exists")) {
      ""
    } else {
      " (not created yet)"
    }),
  )
  lines.push("Diagnostic log: \{string_field(value, "log")}")
  if value is { "storage_error": error, .. } {
    lines.push("Storage error: \{detail_text(error)}")
  }
  lines.join("\n")
}

///|
fn measurement_table(rows : Array[Json]) -> String raise {
  let headers = [
    "Received (UTC)", "Weight (kg)", "Impedance", "Device", "Origin",
  ]
  let cells = rows.map(row => {
    let weight : Int = @json.from_json(field(row, "weight_centi_kg"))
    let impedance : Int = @json.from_json(field(row, "impedance"))
    [
      string_field(row, "received_at"),
      @protocol.weight_text(weight),
      impedance.to_string(),
      string_field(row, "device_id"),
      string_field(row, "origin"),
    ]
  })
  let widths = headers.map(header => header.length())
  for row in cells {
    for column, value in row {
      widths[column] = Int::max(widths[column], value.length())
    }
  }
  fn render(row : Array[String]) -> String {
    row
    .mapi((column, value) => {
      let padding = " ".repeat(widths[column] - value.length())
      if column == 1 || column == 2 {
        padding + value
      } else {
        value + padding
      }
    })
    .join("  ")
  }
  let lines = [
    render(headers),
    widths.map(width => "-".repeat(width)).join("  "),
  ]
  for row in cells {
    lines.push(render(row))
  }
  lines.join("\n")
}
