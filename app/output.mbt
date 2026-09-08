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
fn service_text(
  value : Json,
  format_date? : (String) -> String raise = value => value,
) -> String raise {
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
        "  Last recorded error: \{format_date(string_field(error, "received_at"))} — \{diagnostic_text("error", field(error, "detail"))}",
      )
    }
  }
  lines.push(
    match field(value, "last_saved") {
      Null => "Last saved measurement: none"
      saved => {
        let weight : Int = @json.from_json(field(saved, "weight_centi_kg"))
        "Last saved measurement: \{@protocol.weight_text(weight)} kg at \{format_date(string_field(saved, "received_at"))} [\{string_field(saved, "origin")}]"
      }
    },
  )
  if field(value, "last_event") is event && event != Json::null() {
    lines.push(
      "Last recorded event: \{format_date(string_field(event, "received_at"))}  \{diagnostic_text(string_field(event, "kind"), @json.parse(string_field(event, "detail")))}",
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
fn measurement_table(
  rows : Array[Json],
  timezone? : Int = 0,
  columns~ : Array[MeasurementColumn],
  format_date? : (String) -> String raise = value => value,
) -> String raise {
  let headers = [
    "Date (UTC\{timezone_text(timezone)})",
    ..columns.map(column => column.label),
  ]
  let cells = rows.map(row => {
    [
      format_date(string_field(row, "received_at")),
      ..columns.map(column => measurement_value(row, column)),
    ]
  })
  let reasons : Array[String] = []
  for row in rows {
    if field(row, "composition_error") is String(reason) &&
      !reasons.contains(reason) {
      reasons.push(reason)
    }
  }
  text_table(
    headers,
    cells,
    right_aligned=Array::makei(columns.length(), i => i + 1),
  ) +
  (if reasons.is_empty() {
    ""
  } else {
    let marker = if columns.any(column => column.name != "weight") {
      " (—)"
    } else {
      ""
    }
    "\nBody composition unavailable\{marker}: " + reasons.join("; ") + "."
  })
}

///|
priv struct MeasurementColumn {
  name : String
  key : String
  label : String
  decimals : Int
}

///|
let measurement_columns : Array[MeasurementColumn] = [
  { name: "weight", key: "weight_centi_kg", label: "Weight (kg)", decimals: 2, },
  { name: "bmi", key: "bmi", label: "BMI", decimals: 1, },
  {
    name: "body-fat",
    key: "body_fat_percent",
    label: "Body fat (%)",
    decimals: 1,
  },
  { name: "water", key: "water_percent", label: "Water (%)", decimals: 1, },
  {
    name: "muscle-rate",
    key: "muscle_percent",
    label: "Muscle (%)",
    decimals: 1,
  },
  { name: "bone-rate", key: "bone_percent", label: "Bone (%)", decimals: 1, },
  {
    name: "bmr",
    key: "basal_metabolism_kcal",
    label: "BMR (kcal/day)",
    decimals: 0,
  },
  {
    name: "visceral-fat",
    key: "visceral_fat_level",
    label: "Visceral fat (level)",
    decimals: 0,
  },
  { name: "lean", key: "lean_mass_kg", label: "Lean mass (kg)", decimals: 1, },
  { name: "fat", key: "fat_mass_kg", label: "Fat (kg)", decimals: 1, },
  { name: "bone", key: "bone_mass_kg", label: "Bone (kg)", decimals: 1, },
  { name: "muscle", key: "muscle_mass_kg", label: "Muscle (kg)", decimals: 1, },
]

///|
fn history_columns(options : Options) -> Array[MeasurementColumn] raise {
  let all = options.values.contains("--all")
  let selected = options.values.get("--columns")
  if all && selected is Some(_) {
    raise UsageError("use either --all or --columns")
  }
  if options.json && (all || selected is Some(_)) {
    raise UsageError(
      "--all and --columns apply only to text output; --json includes all fields",
    )
  }
  if all {
    return measurement_columns
  }
  let names = match selected {
    None => ["weight", "bmi", "body-fat", "muscle"]
    Some(value) =>
      value.split(",").map(part => part.trim().to_owned()).collect()
  }
  let columns : Array[MeasurementColumn] = []
  for name in names {
    let column = match
      measurement_columns.iter().find_first(column => column.name == name) {
      None =>
        raise UsageError(
          "unknown column '\{name}'; choose from " +
          measurement_columns.map(column => column.name).join(","),
        )
      Some(column) => column
    }
    if columns.any(column => column.name == name) {
      raise UsageError("duplicate column: \{name}")
    }
    columns.push(column)
  }
  columns
}

///|
fn measurement_value(row : Json, column : MeasurementColumn) -> String raise {
  let value = field(row, column.key)
  if value is Null {
    return "—"
  }
  if column.decimals == 2 {
    @protocol.weight_text(@json.from_json(value))
  } else {
    let number : Double = @json.from_json(value)
    if column.decimals == 0 {
      number.to_int().to_string()
    } else {
      let tenths = (number * 10.0).round().to_int()
      "\{if tenths < 0 { "-" } else { "" }}\{Int::abs(tenths) / 10}.\{Int::abs(tenths) % 10}"
    }
  }
}

///|
fn measurement_detail(
  row : Json,
  format_date? : (String) -> String raise = value => value,
) -> String raise {
  let lines = ["Received: \{format_date(string_field(row, "received_at"))}"]
  let columns = if field(row, "composition_error") is String(_) {
    [measurement_columns[0]]
  } else {
    measurement_columns
  }
  for column in columns {
    lines.push("\{column.label}: \{measurement_value(row, column)}")
  }
  if field(row, "composition_error") is String(reason) {
    lines.push("Body composition unavailable: \{reason}.")
  }
  lines.join("\n")
}

///|
fn text_table(
  headers : Array[String],
  cells : Array[Array[String]],
  right_aligned~ : Array[Int],
) -> String {
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
      if right_aligned.contains(column) {
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
