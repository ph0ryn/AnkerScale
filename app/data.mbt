///|
pub suberror UsageError {
  UsageError(String)
} derive(Debug)

///|
pub impl Show for UsageError with fn to_string(self) {
  let UsageError(message) = self
  message
}

///|
pub suberror DataError {
  DataError(String)
} derive(Debug)

///|
pub impl Show for DataError with fn to_string(self) {
  let DataError(message) = self
  message
}

///|
fn field(value : Json, key : String) -> Json raise {
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(v) => v
        None => raise DataError("missing field: \{key}")
      }
    _ => raise DataError("expected object")
  }
}

///|
fn string_field(value : Json, key : String) -> String raise {
  @json.from_json(field(value, key))
}

///|
fn int_field(value : Json, key : String) -> Int64 raise {
  let number : Double = @json.from_json(field(value, key))
  number.to_int64()
}

///|
fn os(op : String) -> Json raise {
  @native.call({ "op": op })
}

///|
fn date(value : String) -> String raise {
  @json.from_json(@native.call({ "op": "date", "value": value })) catch {
    error => raise UsageError(error.to_string())
  }
}

///|
fn hex_decode(value : String) -> Bytes raise {
  if value.length() % 2 != 0 {
    raise DataError("hex must contain complete bytes")
  }
  let result = FixedArray::make(value.length() / 2, b'\x00')
  for i in 0..<result.length() {
    let mut number = 0
    for j in 0..<2 {
      let c = value[i * 2 + j].to_int()
      let n = if c >= 48 && c <= 57 {
        c - 48
      } else if c >= 97 && c <= 102 {
        c - 87
      } else if c >= 65 && c <= 70 {
        c - 55
      } else {
        raise DataError("invalid hex digit")
      }
      number = number * 16 + n
    }
    result[i] = number.to_byte()
  }
  Bytes::from_array(result)
}

///|
fn hex_encode(bytes : Bytes) -> String {
  let out = StringBuilder()
  for byte in bytes {
    out.write_char(
      "0123456789abcdef"[byte.to_int() >> 4].to_int().unsafe_to_char(),
    )
    out.write_char(
      "0123456789abcdef"[byte.to_int() & 15].to_int().unsafe_to_char(),
    )
  }
  out.to_string()
}

///|
struct Incoming {
  device : String
  name : String
  session : String
  seq : Int
  utc : String
  mono_ms : Double
  service : String
  characteristic : String
  hex : String
} derive(FromJson)

///|
fn schema(db : @native.Database, writable~ : Bool) -> Unit raise {
  let version = int_field(db.query("PRAGMA user_version")[0], "user_version")
  let application = int_field(
    db.query("PRAGMA application_id")[0],
    "application_id",
  )
  if version == 0 && application == 0 && writable {
    if !db
      .query("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
      .is_empty() {
      raise DataError("refusing to initialize an unrelated database")
    }
    db.exec("BEGIN IMMEDIATE")
    errdefer db.exec("ROLLBACK")
    db.exec(
      "CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, services TEXT NOT NULL, first_seen TEXT NOT NULL, last_seen TEXT NOT NULL)",
    )
    db.exec(
      "CREATE TABLE raw_packets (id INTEGER PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id), run_id TEXT NOT NULL, session TEXT NOT NULL, sequence INTEGER NOT NULL, direction TEXT NOT NULL CHECK(direction IN ('rx','tx')), received_at TEXT NOT NULL, mono_ms INTEGER NOT NULL, service TEXT NOT NULL, characteristic TEXT NOT NULL, hex TEXT NOT NULL, origin TEXT NOT NULL CHECK(origin IN ('ble','replay')), parser_version TEXT NOT NULL, kind TEXT NOT NULL, error TEXT, UNIQUE(run_id,session,sequence,direction))",
    )
    db.exec(
      "CREATE TABLE measurements (id INTEGER PRIMARY KEY, raw_id INTEGER NOT NULL UNIQUE REFERENCES raw_packets(id), weight_centi_kg INTEGER NOT NULL CHECK(weight_centi_kg>=0), impedance INTEGER NOT NULL, encrypted_impedance INTEGER NOT NULL, fat_mode INTEGER NOT NULL, measured_at TEXT)",
    )
    db.exec(
      "CREATE INDEX raw_device_time ON raw_packets(device_id, received_at)",
    )
    db.exec("CREATE INDEX raw_run_sequence ON raw_packets(run_id,device_id,id)")
    db.exec(
      "CREATE TABLE events (id INTEGER PRIMARY KEY, run_id TEXT NOT NULL, received_at TEXT NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL)",
    )
    db.exec("PRAGMA application_id=1095975756")
    db.exec("PRAGMA user_version=1")
    db.exec("COMMIT")
  } else if version != 1 || application != 1095975756 {
    raise DataError("unsupported database schema or application ID")
  }
  db.exec("PRAGMA foreign_keys=ON")
  if writable {
    let mode = string_field(
      db.query("PRAGMA journal_mode=WAL")[0],
      "journal_mode",
    )
    if mode != "wal" {
      raise DataError("SQLite WAL mode is required")
    }
    db.exec("PRAGMA synchronous=FULL")
  }
}

///|
/// Policy and the atomic write live here; the native binding only executes SQL.
fn ingest(
  db : @native.Database,
  incoming : Incoming,
  run_id : String,
  origin : String,
  direction? : String = "rx",
) -> Bool raise {
  let payload = hex_decode(incoming.hex)
  let parsed = if direction == "rx" &&
    incoming.name == "eufy T9120" &&
    incoming.service == "FFF0" &&
    incoming.characteristic == "FFF4" {
    @protocol.parse_t9120(payload)
  } else {
    @protocol.Unknown
  }
  let kind = match parsed {
    Stable(_) => "stable"
    Dynamic(_) => "dynamic"
    Overload => "overload"
    HistoryCandidate => "history_candidate"
    Control(_) => "control"
    Unknown => "unknown"
    Invalid(_) => "invalid"
  }
  let error : Json = match parsed {
    Invalid(message) => message.to_json()
    _ => Json::null()
  }
  db.exec("BEGIN IMMEDIATE")
  errdefer db.exec("ROLLBACK")
  db.exec(
    "INSERT INTO devices VALUES (?,?,'[]',?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,last_seen=excluded.last_seen",
    args=[
      incoming.device.to_json(),
      incoming.name.to_json(),
      incoming.utc.to_json(),
      incoming.utc.to_json(),
    ],
  )
  let previous = db.query(
    "SELECT hex,mono_ms,kind FROM raw_packets WHERE run_id=? AND device_id=? AND direction='rx' AND kind IN ('stable','dynamic','overload') ORDER BY id DESC LIMIT 1",
    args=[run_id.to_json(), incoming.device.to_json()],
  )
  let duplicate = match parsed {
    Stable(current) =>
      if previous.is_empty() {
        false
      } else {
        let last = previous[0]
        let delta = incoming.mono_ms - int_field(last, "mono_ms").to_double()
        if delta < 0 || delta >= 500 || string_field(last, "kind") != "stable" {
          false
        } else {
          match @protocol.parse_t9120(hex_decode(string_field(last, "hex"))) {
            Stable(previous) =>
              previous.weight_centi_kg == current.weight_centi_kg &&
              previous.impedance == current.impedance &&
              previous.encrypted_impedance == current.encrypted_impedance
            _ => false
          }
        }
      }
    _ => false
  }
  db.exec(
    "INSERT INTO raw_packets(device_id,run_id,session,sequence,direction,received_at,mono_ms,service,characteristic,hex,origin,parser_version,kind,error) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    args=[
      incoming.device.to_json(),
      run_id.to_json(),
      incoming.session.to_json(),
      incoming.seq.to_json(),
      direction.to_json(),
      incoming.utc.to_json(),
      incoming.mono_ms.to_json(),
      incoming.service.to_json(),
      incoming.characteristic.to_json(),
      hex_encode(payload).to_json(),
      origin.to_json(),
      "t9120/1".to_json(),
      kind.to_json(),
      error,
    ],
  )
  let mut saved = false
  if parsed is Stable(reading) && !duplicate {
    db.exec(
      "INSERT INTO measurements(raw_id,weight_centi_kg,impedance,encrypted_impedance,fat_mode) VALUES(last_insert_rowid(),?,?,?,?)",
      args=[
        reading.weight_centi_kg.to_json(),
        reading.impedance.to_json(),
        reading.encrypted_impedance.to_json(),
        reading.fat_mode.to_json(),
      ],
    )
    saved = true
  }
  db.exec("COMMIT")
  saved
}

///|
fn[T] with_db(
  path : String,
  writable~ : Bool,
  action : (@native.Database) -> T raise,
) -> T raise {
  if writable {
    ignore(@native.call({ "op": "prepare_directory", "path": path }))
    ignore(@native.call({ "op": "lock", "path": path + ".lock" }))
  }
  defer (if writable {
    ignore(
      os("unlock") catch {
        e => {
          @native.stderr(e.to_string())
          Json::null()
        }
      },
    )
  })
  let db = @native.open(path, writable~)
  defer db.close()
  schema(db, writable~)
  action(db)
}
