///|
let profile_help : String =
  #|  ankerscale profile init [--db PATH]
  #|  ankerscale profile [--at DATE] [--json] [--db PATH]
  #|  ankerscale profile history [--json] [--db PATH]
  #|  ankerscale profile set [--birth-date DATE] [--sex male|female] [--height-cm CM] [--mode normal|athlete] [--from DATE] [--db PATH]
  #|  ankerscale profile correct ID [--sex male|female] [--height-cm CM] [--mode normal|athlete] [--db PATH]
  #|  ankerscale profile correct --birth-date DATE [--db PATH]
  #|
  #|Use init for interactive setup. EOF or Ctrl+C cancels without saving a profile.
  #|Initial set requires birth date, sex, height and mode. Height is a positive integer in cm.
  #|Later sets inherit omitted settings at --from (default: now).
  #|Corrections affect only the selected period; birth-date corrections affect all periods.
  #|Date inputs use UTC; date-only values mean midnight UTC. Birth dates use YYYY-MM-DD.
  #|Displayed timestamps use config timezone.
  #|Displayed age is completed years at --at (default: now), not the SDK year difference.

///|
fn parse_profile_options(args : Array[String]) -> Options raise {
  let (command, rest) = if args.is_empty() || args[0].has_prefix("--") {
    ("show", args)
  } else {
    (args[0], args[1:].to_owned())
  }
  let allowed = match command {
    "show" => ["db", "at"]
    "history" | "init" => ["db"]
    "set" => ["db", "birth-date", "sex", "height-cm", "mode", "from"]
    "correct" => ["db", "birth-date", "sex", "height-cm", "mode"]
    _ => raise UsageError("unknown profile command: \{command}")
  }
  let spec = @argparse.Command(
    "ankerscale profile \{command}",
    options=allowed.map(name => @argparse.OptionArg(name, long=name)),
    flags=if command == "show" || command == "history" {
      [@argparse.FlagArg("json", long="json")]
    } else {
      []
    },
    positionals=if command == "correct" {
      [@argparse.PositionArg("id", num_args=@argparse.ValueRange(upper=1))]
    } else {
      []
    },
    disable_help_subcommand=true,
  )
  let parsed = spec.parse(argv=rest) catch {
    error => raise UsageError(error.to_string())
  }
  let values : Map[String, String] = Map([])
  for key, entries in parsed.values {
    if key != "id" {
      values["--" + key] = entries[0]
    }
  }
  for flag in ["--at", "--from"] {
    if values.get(flag) is Some(value) {
      values[flag] = date(value)
    }
  }
  if values.get("--birth-date") is Some(value) {
    if value.length() != 10 {
      raise UsageError("birth date must be YYYY-MM-DD")
    }
    ignore(date(value))
    if value > string_field(os("now"), "utc")[0:10].to_owned() {
      raise UsageError("birth date cannot be in the future")
    }
  }
  {
    command,
    values,
    positional: parsed.values.get_or_default("id", []),
    json: parsed.flags.get_or_default("json", false),
  }
}

///|
fn profile_patch(options : Options) -> ProfilePatch raise {
  let sex = options.values.get("--sex")
  if sex is Some(value) && value != "male" && value != "female" {
    raise UsageError("sex must be male or female")
  }
  let mode = options.values.get("--mode")
  if mode is Some(value) && value != "normal" && value != "athlete" {
    raise UsageError("mode must be normal or athlete")
  }
  let height_cm = options.values
    .get("--height-cm")
    .map(value => {
      let height = @string.parse_int(value) catch {
        _ => raise UsageError("height-cm must be a positive integer")
      }
      if height <= 0 {
        raise UsageError("height-cm must be a positive integer")
      }
      height
    })
  { sex, height_cm, mode, }
}

///|
fn profile_text(value : Json, timezone? : Int = 0) -> String raise {
  if value is Null {
    return "No profile at this time. Use ankerscale profile set to add one."
  }
  "Birth date: \{string_field(value, "birth_date")}\n" +
  "Age: \{int_field(value, "age")} (at \{display_date(string_field(value, "at"), timezone)})\n" +
  "Sex: \{string_field(value, "sex")}\n" +
  "Height: \{int_field(value, "height_cm")} cm\n" +
  "Mode: \{string_field(value, "mode")}\n" +
  "Profile: \{int_field(value, "id")} (from \{display_date(string_field(value, "effective_from"), timezone)}, until \{profile_until_text(value, timezone~)})"
}

///|
fn profile_until_text(value : Json, timezone? : Int = 0) -> String raise {
  match field(value, "until") {
    Null => "open-ended"
    String(until) => display_date(until, timezone)
    _ => raise DataError("invalid profile end time")
  }
}

///|
fn profile_cli(args : Array[String]) -> Unit raise {
  if args.contains("--help") || args == ["help"] {
    println(profile_help)
    return
  }
  let options = parse_profile_options(args)
  let timezone = if options.json { 0 } else { read_timezone() }
  let patch = profile_patch(options)
  let birth_date = options.values.get("--birth-date")
  let mut id : Int64? = None
  if options.command == "set" && patch.is_empty() && birth_date is None {
    raise UsageError("set requires at least one profile setting")
  }
  if options.command == "correct" {
    if !options.positional.is_empty() {
      let value = @string.parse_int64(options.positional[0]) catch {
        _ => raise UsageError("profile history ID must be a positive integer")
      }
      if value <= 0 {
        raise UsageError("profile history ID must be a positive integer")
      }
      id = Some(value)
    }
    if (id is Some(_) && (birth_date is Some(_) || patch.is_empty())) ||
      (id is None && (birth_date is None || !patch.is_empty())) {
      raise UsageError(
        "correct requires either ID with settings or --birth-date DATE",
      )
    }
  }
  let path = match options.values.get("--db") {
    Some(path) => path
    None => string_field(os("paths"), "db")
  }
  let writable = options.command == "set" ||
    options.command == "correct" ||
    options.command == "init"
  with_db(path, writable~, collector_lock=false, db => {
    if !writable {
      db.exec("BEGIN")
    }
    defer (if !writable { db.exec("ROLLBACK") })
    match options.command {
      "init" => profile_init(db, timezone)
      "show" => {
        let at = match options.values.get("--at") {
          Some(at) => at
          None => string_field(os("now"), "utc")
        }
        let value = profile_show(db, at)
        println(
          if options.json {
            value.stringify()
          } else {
            profile_text(value, timezone~)
          },
        )
      }
      "history" => {
        let rows = profile_history(db)
        if options.json {
          println(rows.to_json().stringify())
        } else if rows.is_empty() {
          println("No profile history.")
        } else {
          let cells = rows.map(row => {
            [
              int_field(row, "id").to_string(),
              display_date(string_field(row, "effective_from"), timezone),
              profile_until_text(row, timezone~),
              string_field(row, "sex"),
              int_field(row, "height_cm").to_string(),
              string_field(row, "mode"),
            ]
          })
          println(
            text_table(
              ["ID", "From", "Until", "Sex", "Height (cm)", "Mode"],
              cells,
              right_aligned=[0, 4],
            ),
          )
        }
      }
      "set" => {
        let from = match options.values.get("--from") {
          Some(from) => from
          None => string_field(os("now"), "utc")
        }
        let saved_id = profile_set(db, birth_date, from, patch)
        println(
          "Saved profile \{saved_id} from \{display_date(from, timezone)}.",
        )
      }
      "correct" => {
        profile_correct(db, id, birth_date, patch)
        println(
          match id {
            Some(id) => "Corrected profile \{id}."
            None => "Corrected birth date for all profile periods."
          },
        )
      }
      _ => raise UsageError("unknown profile command: \{options.command}")
    }
  })
}

///|
fn prompt_profile_value(
  flag : String,
  prompt : String,
  birth_date : String?,
) -> String? raise {
  while true {
    @native.stderr(prompt)
    let line = os("read_line")
    check_interrupted()
    let value = match line {
      Null => return None
      String(value) => value.trim().to_owned()
      _ => raise DataError("invalid input response")
    }
    let value = match (flag, value) {
      ("--sex", "1") => "male"
      ("--sex", "2") => "female"
      ("--mode", "1") => "normal"
      ("--mode", "2") => "athlete"
      ("--from", "") => string_field(os("now"), "utc")
      _ => value
    }
    try {
      let options = parse_profile_options(["set", flag + "=" + value])
      ignore(profile_patch(options))
      let normalized = options.values[flag]
      if flag == "--from" &&
        birth_date is Some(birth) &&
        birth > normalized[0:10].to_owned() {
        raise UsageError("profile cannot start before the birth date")
      }
      return Some(normalized)
    } catch {
      UsageError(message) => @native.stderr(message)
      error => raise error
    }
  } nobreak {
    None
  }
}

///|
fn profile_init(db : @native.Database, timezone : Int) -> Unit raise {
  if profile_birth_date(db) is Some(_) {
    raise UsageError(
      "profile already initialized; use profile set or profile correct",
    )
  }
  ignore(os("signals"))
  @native.stderr("Set up your profile. Use Ctrl+D or Ctrl+C to cancel.")
  let args = ["set"]
  let mut birth_date : String? = None
  for
    pair in [
      ("--birth-date", "Birth date (YYYY-MM-DD):"),
      ("--sex", "Sex (1: male, 2: female):"),
      ("--height-cm", "Height (whole cm):"),
      ("--mode", "Mode (1: normal, 2: athlete):"),
      ("--from", "Effective from (UTC date or timestamp; Enter for now):"),
    ] {
    let (flag, prompt) = pair
    let value = match prompt_profile_value(flag, prompt, birth_date) {
      None => {
        println("Profile setup cancelled.")
        return
      }
      Some(value) => value
    }
    if flag == "--birth-date" {
      birth_date = Some(value)
    }
    args.push(flag)
    args.push(value)
  }
  let options = parse_profile_options(args)
  let from = required(options, "--from")
  let id = profile_set(db, birth_date, from, profile_patch(options))
  println("Saved profile \{id} from \{display_date(from, timezone)}.")
}
