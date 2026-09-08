///|
fn timezone_minutes(value : String) -> Int raise {
  fn invalid() -> Int raise {
    raise UsageError(
      "timezone must be a signed UTC offset from -12:00 to +14:00 (for example +9 or +05:30)",
    )
  }
  if value.length() < 2 || (value[0] != '+' && value[0] != '-') {
    return invalid()
  }
  let parts = value[1:].split(":").to_array()
  if parts.length() > 2 || parts[0].length() < 1 || parts[0].length() > 2 {
    return invalid()
  }
  for part in parts {
    for c in part {
      if c < '0' || c > '9' {
        return invalid()
      }
    }
  }
  let hours = @string.parse_int(parts[0].to_owned())
  let minutes = if parts.length() == 2 {
    if parts[1].length() != 2 {
      return invalid()
    }
    @string.parse_int(parts[1].to_owned())
  } else {
    0
  }
  let total = (hours * 60 + minutes) * (if value[0] == '-' { -1 } else { 1 })
  if minutes >= 60 || total < -720 || total > 840 {
    return invalid()
  }
  total
}

///|
fn timezone_text(minutes : Int) -> String {
  let absolute = Int::abs(minutes)
  let hours = (absolute / 60).to_string()
  let remainder = (absolute % 60).to_string()
  (if minutes < 0 { "-" } else { "+" }) +
  "0".repeat(2 - hours.length()) +
  hours +
  ":" +
  "0".repeat(2 - remainder.length()) +
  remainder
}

///|
fn read_timezone() -> Int raise {
  match os("config_read") {
    Null => 0
    value => {
      let version : Int = @json.from_json(field(value, "version"))
      if version != 1 {
        raise DataError("unsupported config.json version")
      }
      timezone_minutes(string_field(value, "timezone")) catch {
        error => raise DataError("invalid config.json: \{error}")
      }
    }
  }
}

///|
fn config_cli(args : Array[String]) -> Unit raise {
  if args == ["--help"] || args == ["help"] {
    println(
      "ankerscale config timezone [OFFSET]\nShow the current offset, or set it (for example +9, -5, +05:30). Default: +00:00.",
    )
    return
  }
  if args.is_empty() || args[0] != "timezone" || args.length() > 2 {
    raise UsageError("usage: ankerscale config timezone [OFFSET]")
  }
  let minutes = if args.length() == 1 {
    read_timezone()
  } else {
    let minutes = timezone_minutes(args[1])
    ignore(
      @native.call({
        "op": "config_write",
        "value": { "version": 1, "timezone": timezone_text(minutes) },
      }),
    )
    minutes
  }
  println(timezone_text(minutes))
}

///|
fn display_date(value : String, timezone : Int) -> String raise {
  @json.from_json(
    @native.call({ "op": "date", "value": value, "display_offset": timezone }),
  )
}

///|
fn filter_date(value : String) -> String raise {
  if value.length() != 10 {
    return date(value)
  }
  let timezone = read_timezone()
  @json.from_json(
    @native.call({ "op": "date", "value": value, "input_offset": timezone }),
  ) catch {
    error => raise UsageError(error.to_string())
  }
}
