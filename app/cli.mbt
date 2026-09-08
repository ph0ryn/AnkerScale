///|
let help : String =
  #|AnkerScale — local BLE scale recorder for macOS
  #|
  #|  ankerscale register [--seconds 10]
  #|  ankerscale devices [--json]
  #|  ankerscale unregister
  #|  ankerscale config timezone [OFFSET]
  #|  ankerscale profile init [--db PATH]
  #|  ankerscale profile [--at DATE] [--json] [--db PATH]
  #|  ankerscale profile history [--json] [--db PATH]
  #|  ankerscale profile set [--birth-date DATE] [--sex male|female] [--height-cm CM] [--mode normal|athlete] [--from DATE] [--db PATH]
  #|  ankerscale profile correct [ID] [--birth-date DATE] [--sex male|female] [--height-cm CM] [--mode normal|athlete] [--db PATH]
  #|  ankerscale collect [--db PATH]
  #|  ankerscale latest [--db PATH] [--json]
  #|  ankerscale history [--since DATE] [--until DATE] [--device UUID] [--limit 100] [--all | --columns LIST] [--json] [--db PATH]
  #|  ankerscale export --format csv|json [--since DATE] [--until DATE] [--device UUID] [--db PATH]
  #|  ankerscale logs [--limit 100] [--db PATH] [--json]
  #|  ankerscale service start [--json]
  #|  ankerscale service stop|status [--json]
  #|  ankerscale replay FILE.jsonl --db PATH
  #|
  #|--since is inclusive; --until is exclusive. Date-only filters use the configured timezone.
  #|Explicit Z timestamps, JSON and CSV use UTC. Live measurements have no device timestamp.
  #|Replay writes explicit test data; use a separate database.
  #|History columns: weight,bmi,body-fat,water,muscle-rate,bone-rate,bmr,visceral-fat,lean,fat,bone,muscle.
  #|Default: weight,bmi,body-fat,muscle. Dates are always shown. --all/--columns are text-only.

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
    "history" =>
      ["--db", "--since", "--until", "--device", "--limit", "--columns"]
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
    options=allowed.map(flag => {
      @argparse.OptionArg(
        flag[2:],
        long=flag[2:],
        about=if flag == "--columns" {
          "Comma-separated metrics in display order (text only); see ankerscale --help for names"
        } else {
          ""
        },
      )
    }),
    flags=if command == "latest" ||
      command == "history" ||
      command == "devices" ||
      command == "service" ||
      command == "logs" {
      [
        @argparse.FlagArg("json", long="json"),
        ..if command == "history" {
          [
            @argparse.FlagArg(
              "all",
              long="all",
              about="Show all 12 measurements (text only)",
            ),
          ]
        } else {
          []
        },
      ]
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
  if parsed.flags.get_or_default("all", false) {
    values["--all"] = "true"
  }
  let options = { command, positional, values, json, }
  if command == "history" {
    ignore(history_columns(options))
  }
  for key in ["--since", "--until"] {
    if values.get(key) is Some(value) {
      values[key] = filter_date(value)
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
  db.exec("BEGIN")
  defer db.exec("ROLLBACK")
  let profiles = MeasurementProfiles::load(db)
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
    if format == "csv" {
      println(measurement_keys.join(","))
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
        let row = profiles.enrich(row)
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
  } else {
    let rows = db
      .query(
        query + order + " LIMIT ?",
        args=params + [(if latest { 1 } else { limit(options) }).to_json()],
      )
      .map(row => profiles.enrich(row))
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
      let timezone = read_timezone()
      let format_date = value => display_date(value, timezone)
      println(
        if latest {
          measurement_detail(rows[0], format_date~)
        } else {
          let columns = if !options.values.contains("--all") &&
            !options.values.contains("--columns") &&
            !rows.any(row => !(field(row, "profile_id") is Null)) {
            [measurement_columns[0]]
          } else {
            history_columns(options)
          }
          measurement_table(rows, timezone~, columns~, format_date~)
        },
      )
    }
  }
}

///|
fn csv(row : Json) -> String raise {
  let parts = measurement_keys.map(key => {
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
  if args[0] == "profile" {
    profile_cli(args[1:].to_owned())
    return
  }
  if args[0] == "config" {
    config_cli(args[1:].to_owned())
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
        let timezone = if options.json { 0 } else { read_timezone() }
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
              "\{display_date(string_field(row, "received_at"), timezone)}  \{diagnostic_text(string_field(row, "kind"), record["detail"])}"
            },
          )
        }
      })
    _ => raise UsageError("unknown command: \{options.command}")
  }
}
