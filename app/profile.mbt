///|
priv struct ProfilePatch {
  sex : String?
  height_cm : Int?
  mode : String?
}

///|
fn ProfilePatch::is_empty(self : ProfilePatch) -> Bool {
  self.sex is None && self.height_cm is None && self.mode is None
}

///|
let profile_periods : String = "SELECT id,effective_from,lead(effective_from) OVER (ORDER BY effective_from) AS until,sex,height_cm,mode FROM profile_history"

///|
fn profile_birth_date(db : @native.Database) -> String? raise {
  // Read-only inspection of a v1 database must not migrate it.
  if int_field(db.query("PRAGMA user_version")[0], "user_version") == 1 {
    return None
  }
  let rows = db.query("SELECT birth_date FROM person WHERE id=1")
  if rows.is_empty() {
    None
  } else {
    Some(string_field(rows[0], "birth_date"))
  }
}

///|
fn profile_at(db : @native.Database, at : String) -> Json? raise {
  let rows = db.query(
    "SELECT * FROM (\{profile_periods}) WHERE effective_from<=? ORDER BY effective_from DESC LIMIT 1",
    args=[at.to_json()],
  )
  if rows.is_empty() {
    None
  } else {
    Some(rows[0])
  }
}

///|
fn profile_age(birth_date : String, at : String) -> Int raise {
  let years = @string.parse_int(at[0:4]) - @string.parse_int(birth_date[0:4])
  // February 29 birthdays advance on March 1 in non-leap years.
  years - (if at[5:10] < birth_date[5:10] { 1 } else { 0 })
}

///|
fn profile_show(db : @native.Database, at : String) -> Json raise {
  let birth_date = match profile_birth_date(db) {
    None => return Json::null()
    Some(value) => value
  }
  let row = match profile_at(db, at) {
    None => return Json::null()
    Some(row) => row
  }
  let fields : Map[String, Json] = @json.from_json(row)
  fields["birth_date"] = birth_date.to_json()
  fields["at"] = at.to_json()
  fields["age"] = profile_age(birth_date, at).to_json()
  fields.to_json()
}

///|
fn profile_history(db : @native.Database) -> Array[Json] raise {
  if profile_birth_date(db) is None {
    return []
  }
  db.query("SELECT * FROM (\{profile_periods}) ORDER BY effective_from DESC")
}

///|
fn profile_values(patch : ProfilePatch, base : Json?) -> Array[Json] raise {
  let changes = [
    ("sex", patch.sex.map(value => value.to_json())),
    ("height_cm", patch.height_cm.map(value => value.to_json())),
    ("mode", patch.mode.map(value => value.to_json())),
  ]
  changes.map(pair => {
    let (key, value) = pair
    match (value, base) {
      (Some(value), _) => value
      (None, Some(row)) => field(row, key)
      (None, None) =>
        raise UsageError(
          "no profile at this date; specify --sex, --height-cm and --mode",
        )
    }
  })
}

///|
fn profile_set(
  db : @native.Database,
  birth_date : String?,
  from : String,
  patch : ProfilePatch,
) -> Int64 raise {
  db.exec("BEGIN IMMEDIATE")
  errdefer db.exec("ROLLBACK")
  let existing_birth_date = profile_birth_date(db)
  let birth = match (existing_birth_date, birth_date) {
    (None, None) => raise UsageError("initial profile requires --birth-date")
    (Some(_), Some(_)) =>
      raise UsageError(
        "use profile correct --birth-date DATE to correct the birth date",
      )
    (None, Some(value)) | (Some(value), None) => value
  }
  if birth > from[0:10].to_owned() {
    raise UsageError("profile cannot start before the birth date")
  }
  if !db
    .query("SELECT id FROM profile_history WHERE effective_from=?", args=[
      from.to_json(),
    ])
    .is_empty() {
    raise UsageError(
      "a profile already starts at this time; use profile correct ID",
    )
  }
  let values = profile_values(patch, profile_at(db, from))
  if existing_birth_date is None {
    db.exec("INSERT INTO person(id,birth_date) VALUES(1,?)", args=[
      birth.to_json(),
    ])
  }
  db.exec(
    "INSERT INTO profile_history(effective_from,sex,height_cm,mode) VALUES(?,?,?,?)",
    args=[from.to_json(), ..values],
  )
  let id = int_field(db.query("SELECT last_insert_rowid() AS id")[0], "id")
  db.exec("COMMIT")
  id
}

///|
fn profile_correct(
  db : @native.Database,
  id : Int64?,
  birth_date : String?,
  patch : ProfilePatch,
) -> Unit raise {
  db.exec("BEGIN IMMEDIATE")
  errdefer db.exec("ROLLBACK")
  if profile_birth_date(db) is None {
    raise UsageError("no profile; use profile set first")
  }
  match (id, birth_date) {
    (None, Some(birth_date)) => {
      let first = db.query(
        "SELECT effective_from FROM profile_history ORDER BY effective_from LIMIT 1",
      )
      if !first.is_empty() &&
        birth_date > string_field(first[0], "effective_from")[0:10].to_owned() {
        raise UsageError("birth date cannot be after the first profile starts")
      }
      db.exec("UPDATE person SET birth_date=? WHERE id=1", args=[
        birth_date.to_json(),
      ])
    }
    (Some(id), None) => {
      let rows = db.query("SELECT * FROM profile_history WHERE id=?", args=[
        id.to_json(),
      ])
      if rows.is_empty() {
        raise UsageError("profile history ID not found: \{id}")
      }
      let values = profile_values(patch, Some(rows[0]))
      db.exec(
        "UPDATE profile_history SET sex=?,height_cm=?,mode=? WHERE id=?",
        args=[..values, id.to_json()],
      )
    }
    _ =>
      raise UsageError(
        "correct requires either ID with settings or --birth-date DATE",
      )
  }
  db.exec("COMMIT")
}
