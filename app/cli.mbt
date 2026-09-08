///|
let help : String =
  #|AnkerScale — local BLE scale recorder for macOS
  #|
  #|  ankerscale register [--seconds 10]
  #|  ankerscale devices [--json]
  #|  ankerscale unregister
  #|  ankerscale collect [--db PATH]
  #|  ankerscale latest [--db PATH] [--json]
  #|  ankerscale history [--since DATE] [--until DATE] [--device UUID] [--limit 100] [--json] [--db PATH]
  #|  ankerscale export --format csv|json [--since DATE] [--until DATE] [--device UUID] [--db PATH]
  #|  ankerscale logs [--limit 100] [--db PATH] [--json]
  #|  ankerscale service start [--json]
  #|  ankerscale service stop|status [--json]
  #|  ankerscale replay FILE.jsonl --db PATH
  #|
  #|Dates use UTC. --since is inclusive; --until is exclusive.
  #|Date-only values mean midnight UTC. Live measurements have no device timestamp.
  #|Replay writes explicit test data; use a separate database.

///|
priv struct Options {
  command : String
  positional : Array[String]
  values : Map[String, String]
  json : Bool
}

///|
fn parse_options(args : Array[String]) -> Options raise {
  let command = args[0]
  let values : Map[String, String] = Map([])
  let allowed = match command {
    "latest" => ["--db"]
    "history" => ["--db", "--since", "--until", "--device", "--limit"]
    "export" => ["--db", "--since", "--until", "--device", "--format"]
    "logs" => ["--db", "--limit"]
    "replay" => ["--db"]
    "collect" => ["--db"]
    "register" => ["--seconds"]
    "devices" | "unregister" => []
    "service" => []
    _ => raise UsageError("unknown command: \{command}")
  }
  let spec = @argparse.Command(
    "ankerscale \{command}",
    options=allowed.map(flag => @argparse.OptionArg(flag[2:], long=flag[2:])),
    flags=if command == "latest" ||
      command == "history" ||
      command == "devices" ||
      command == "service" ||
      command == "logs" {
      [@argparse.FlagArg("json", long="json")]
    } else {
      []
    },
    positionals=if command == "replay" || command == "service" {
      [
        @argparse.PositionArg(
          "argument",
          num_args=@argparse.ValueRange::single(),
        ),
      ]
    } else {
      []
    },
    disable_help_subcommand=true,
  )
  let parsed = spec.parse(argv=args[1:]) catch {
    error => raise UsageError(error.to_string())
  }
  for key, entries in parsed.values {
    if key != "argument" {
      values["--" + key] = entries[0]
    }
  }
  let positional = parsed.values.get_or_default("argument", [])
  let json = parsed.flags.get_or_default("json", false)
  let options = { command, positional, values, json, }
  for key in ["--since", "--until"] {
    if values.get(key) is Some(value) {
      values[key] = date(value)
    }
  }
  if values.get("--since") is Some(since) &&
    values.get("--until") is Some(until) &&
    since >= until {
    raise UsageError("since must be earlier than until")
  }
  if values.get("--device") is Some(value) {
    values["--device"] = device_id(value)
  }
  if values.contains("--limit") {
    ignore(limit(options))
  }
  if command == "export" {
    let format = required(options, "--format")
    if format != "csv" && format != "json" {
      raise UsageError("format must be csv or json")
    }
  }
  options
}

///|
fn limit(options : Options) -> Int raise {
  match options.values.get("--limit") {
    None => 100
    Some(s) => {
      let n = @string.parse_int(s) catch {
        _ => raise UsageError("limit must be an integer from 1 to 10000")
      }
      if n < 1 || n > 10000 {
        raise UsageError("limit must be from 1 to 10000")
      }
      n
    }
  }
}

///|
fn required(options : Options, key : String) -> String raise {
  match options.values.get(key) {
    Some(value) => value
    None => raise UsageError("required option: \{key}")
  }
}

///|
fn history(db : @native.Database, options : Options) -> Unit raise {
  let mut where_sql = " WHERE 1=1"
  let params : Array[Json] = []
  for
    pair in [
      ("--since", " AND r.received_at>=?"),
      ("--until", " AND r.received_at<?"),
      ("--device", " AND r.device_id=?"),
    ] {
    let (flag, clause) = pair
    if options.values.get(flag) is Some(value) {
      where_sql += clause
      params.push(value.to_json())
    }
  }
  let latest = options.command == "latest"
  let exporting = options.command == "export"
  let format = if exporting {
    required(options, "--format")
  } else if options.json {
    "json"
  } else {
    "text"
  }
  let columns = "m.id,r.device_id,r.received_at,m.measured_at,m.weight_centi_kg,m.impedance,m.encrypted_impedance,m.fat_mode,r.origin,m.raw_id"
  let query = "SELECT \{columns} FROM measurements m JOIN raw_packets r ON r.id=m.raw_id" +
    where_sql
  let order = if !exporting {
    " ORDER BY r.received_at DESC,m.id DESC"
  } else {
    " ORDER BY r.received_at,m.id"
  }
  if exporting {
    db.exec("BEGIN")
    errdefer db.exec("ROLLBACK")
    if format == "csv" {
      println(
        "id,device_id,received_at,measured_at,weight_centi_kg,impedance,encrypted_impedance,fat_mode,origin,raw_id",
      )
    } else {
      println("[")
    }
    let mut offset = 0
    let mut first = true
    while true {
      let rows = db.query(
        query + order + " LIMIT 500 OFFSET ?",
        args=params + [offset.to_json()],
      )
      for row in rows {
        if format == "csv" {
          println(csv(row))
        } else {
          if !first {
            println(",")
          }
          println(row.stringify())
          first = false
        }
      }
      if rows.length() < 500 {
        break
      }
      offset += 500
    }
    if format == "json" {
      println("]")
    }
    db.exec("COMMIT")
  } else {
    let rows = db.query(
      query + order + " LIMIT ?",
      args=params + [(if latest { 1 } else { limit(options) }).to_json()],
    )
    if options.json {
      println(
        (if latest {
          if rows.is_empty() {
            Json::null()
          } else {
            rows[0]
          }
        } else {
          rows.to_json()
        }).stringify(),
      )
    } else if rows.is_empty() {
      println("No measurements.")
    } else {
      for row in rows {
        let weight : Int = @json.from_json(field(row, "weight_centi_kg"))
        println(
          "\{string_field(row, "received_at")}  \{@protocol.weight_text(weight)} kg  \{string_field(row, "device_id")}  [\{string_field(row, "origin")}]",
        )
      }
    }
  }
}

///|
fn csv(row : Json) -> String raise {
  let fields = [
    "id", "device_id", "received_at", "measured_at", "weight_centi_kg", "impedance",
    "encrypted_impedance", "fat_mode", "origin", "raw_id",
  ]
  let parts = fields.map(key => {
    match field(row, key) {
      Null => ""
      String(value) => "\"" + value.replace(old="\"", new="\"\"") + "\""
      value => value.stringify()
    }
  })
  parts.join(",")
}

///|
fn replay(db : @native.Database, path : String) -> Unit raise {
  let text : String = @json.from_json(
    @native.call({ "op": "read", "path": path }),
  )
  let run_id : String = @json.from_json(os("uuid"))
  let mut count = 0
  let mut previous : Double = -1
  for line in text.split("\n") {
    if line.trim().is_empty() {
      continue
    }
    let record : Incoming = @json.from_json(@json.parse(line))
    if record.mono_ms < 0 ||
      record.mono_ms > 9007199254740991.0 ||
      record.mono_ms.to_int64().to_double() != record.mono_ms ||
      record.mono_ms < previous ||
      record.seq < 0 {
      raise DataError("replay requires monotonic nonnegative time and sequence")
    }
    previous = record.mono_ms
    let normalized = { ..record, utc: date(record.utc), }
    if ingest(db, normalized, run_id, "replay") {
      count += 1
    }
  }
  println("Recorded \{count} measurements (replay).")
}

///|
pub fn run(args : Array[String]) -> Unit raise {
  if args.is_empty() || args == ["--help"] || args == ["help"] {
    println(help)
    return
  }
  let options = parse_options(args)
  ignore(os("signals"))
  let path = match options.values.get("--db") {
    Some(path) => path
    None => string_field(os("paths"), "db")
  }
  match options.command {
    "service" => service(options)
    "devices" => devices(options)
    "register" => register(options)
    "unregister" => unregister()
    "collect" => {
      let registry = read_registry()
      require_registered(registry)
      with_db(path, writable=true, db => collect(db, registry))
    }
    "replay" => {
      ignore(required(options, "--db"))
      if options.positional.length() != 1 {
        raise UsageError("replay requires one JSONL file")
      }
      with_db(path, writable=true, db => replay(db, options.positional[0]))
    }
    "latest" | "history" | "export" =>
      with_db(path, writable=false, db => history(db, options))
    "logs" =>
      with_db(path, writable=false, db => {
        for
          row in db.query(
            "SELECT 'collector' AS source,received_at,kind,detail FROM events UNION ALL SELECT 'packet' AS source,received_at,kind,json_object('raw_id',id,'device',device_id,'session',session,'direction',direction,'service',service,'characteristic',characteristic,'hex',hex,'parser_version',parser_version,'error',error,'origin',origin) AS detail FROM raw_packets ORDER BY received_at DESC LIMIT ?",
            args=[limit(options).to_json()],
          ) {
          let record : Map[String, Json] = @json.from_json(row)
          record["detail"] = @json.parse(string_field(row, "detail"))
          println(
            if options.json {
              record.to_json().stringify()
            } else {
              "\{string_field(row, "received_at")}  \{diagnostic_text(string_field(row, "kind"), record["detail"])}"
            },
          )
        }
      })
    _ => raise UsageError("unknown command: \{options.command}")
  }
}
