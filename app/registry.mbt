///|
priv struct RegisteredDevice {
  id : String
  name : String
} derive(Eq, FromJson, ToJson)

///|
priv struct Registry {
  devices : Array[RegisteredDevice]
  source : String
}

///|
fn read_registry(allow_legacy? : Bool = true) -> Registry raise {
  let record = @native.call({
    "op": "registry_read",
    "allow_legacy": allow_legacy,
  })
  let source = string_field(record, "source")
  let devices : Array[RegisteredDevice] = match source {
    "missing" => []
    "legacy" =>
      [{ id: string_field(field(record, "value"), "device"), name: "", }]
    "current" => {
      let value = field(record, "value")
      let version : Int = @json.from_json(field(value, "version"))
      if version != 1 {
        raise DataError("unsupported devices.json version")
      }
      @json.from_json(field(value, "devices"))
    }
    _ => raise DataError("unknown registry source")
  }
  let seen : Set[String] = Set([])
  let normalized = devices.map(device => {
    let id : String = @json.from_json(
      @native.call({ "op": "validate_device", "device": device.id }),
    )
    if seen.contains(id) {
      raise DataError("duplicate device in devices.json: \{id}")
    }
    seen.add(id)
    { id, name: device.name, }
  })
  { devices: normalized, source, }
}

///|
fn check_interrupted() -> Unit raise {
  if @json.from_json(os("stopping")) {
    raise DataError("operation cancelled")
  }
}

///|
fn write_registry(
  previous : Registry,
  devices : Array[RegisteredDevice],
) -> Unit raise {
  check_interrupted()
  ignore(
    @native.call({
      "op": "registry_write",
      "value": { "version": 1, "devices": devices },
    }),
  )
  if previous.source == "legacy" {
    @native.stderr("Migrated service.json registration to devices.json.")
  }
}

///|
fn[T] with_registry_lock(action : () -> T raise) -> T raise {
  ignore(os("registry_lock"))
  defer ignore(
    os("registry_unlock") catch {
      error => {
        @native.stderr(error.to_string())
        Json::null()
      }
    },
  )
  action()
}

///|
fn require_registered(registry : Registry) -> Unit raise {
  if registry.devices.is_empty() {
    raise UsageError("No devices registered. Run ankerscale register first.")
  }
}

///|
fn display_device(device : RegisteredDevice) -> String {
  let name = if device.name.is_empty() { "Unknown model" } else { device.name }
  "\{name}  \{device.id}"
}

///|
fn devices(options : Options) -> Unit raise {
  let registry = read_registry()
  if options.json {
    println(registry.devices.to_json().stringify())
  } else if registry.devices.is_empty() {
    println("No devices registered. Run ankerscale register to add a scale.")
  } else {
    for i, device in registry.devices {
      println("\{i + 1}. \{display_device(device)}")
    }
  }
}

///|
fn select_devices(count : Int) -> Array[Int] raise {
  @native.stderr("Select device numbers separated by commas (Enter to cancel):")
  let line = os("read_line")
  check_interrupted()
  let text = match line {
    Null => return []
    String(value) => value.trim().to_owned()
    _ => raise DataError("invalid input response")
  }
  if text.is_empty() {
    return []
  }
  let seen : Set[Int] = Set([])
  let selected : Array[Int] = []
  for token in text.split(",") {
    let index = @string.parse_int(token.trim().to_owned()) catch {
      _ =>
        raise UsageError(
          "select numbers from 1 to \{count}, separated by commas",
        )
    }
    if index < 1 || index > count {
      raise UsageError("select numbers from 1 to \{count}")
    }
    if !seen.contains(index) {
      seen.add(index)
      selected.push(index - 1)
    }
  }
  selected
}

///|
fn unregister() -> Unit raise {
  with_registry_lock(() => {
    let registry = read_registry()
    if registry.devices.is_empty() {
      println("No devices registered.")
      return
    }
    for i, device in registry.devices {
      println("\{i + 1}. \{display_device(device)}")
    }
    let selected = select_devices(registry.devices.length())
    if selected.is_empty() {
      println("Registration unchanged.")
      return
    }
    let removed : Set[String] = Set(selected.map(i => registry.devices[i].id))
    write_registry(
      registry,
      registry.devices.filter(device => !removed.contains(device.id)),
    )
    println(
      "Unregistered \{removed.length()} device(s). Saved measurements are retained.",
    )
  })
}
