///|
priv struct MeasurementProfiles {
  birth_date : String?
  periods : Array[Json]
}

///|
fn MeasurementProfiles::load(
  db : @native.Database,
) -> MeasurementProfiles raise {
  { birth_date: profile_birth_date(db), periods: profile_history(db), }
}

///|
fn MeasurementProfiles::at(
  self : MeasurementProfiles,
  at : String,
) -> Json? raise {
  // profile_history is newest first; the first matching start owns this instant.
  for row in self.periods {
    if string_field(row, "effective_from") <= at {
      return Some(row)
    }
  }
  None
}

///|
let composition_keys : Array[String] = [
  "bmi", "body_fat_percent", "water_percent", "muscle_percent", "bone_percent", "basal_metabolism_kcal",
  "visceral_fat_level", "lean_mass_kg", "fat_mass_kg", "bone_mass_kg", "muscle_mass_kg",
]

///|
let measurement_keys : Array[String] = [
  "id", "device_id", "received_at", "measured_at", "weight_centi_kg", "impedance",
  "encrypted_impedance", "fat_mode", "origin", "raw_id", ..composition_keys, "profile_id",
  "composition_age", "composition_method", "composition_error",
]

///|
fn MeasurementProfiles::enrich(
  self : MeasurementProfiles,
  row : Json,
) -> Json raise {
  let fields : Map[String, Json] = @json.from_json(row)
  for key in composition_keys {
    fields[key] = Json::null()
  }
  fields["profile_id"] = Json::null()
  fields["composition_age"] = Json::null()
  fields["composition_method"] = "besthealth-v1".to_json()
  fields["composition_error"] = Json::null()
  let at = match field(row, "measured_at") {
    String(value) => value
    Null => string_field(row, "received_at")
    _ => raise DataError("invalid measurement date")
  }
  let (birth_date, profile) = match (self.birth_date, self.at(at)) {
    (Some(birth_date), Some(profile)) => (birth_date, profile)
    _ => {
      fields["composition_error"] = (if self.birth_date is None {
        "Profile is unset. Run ankerscale profile init"
      } else {
        "No profile at this measurement time. Use ankerscale profile set --from DATE"
      }).to_json()
      return fields.to_json()
    }
  }
  let age = @string.parse_int(at[0:4]) - @string.parse_int(birth_date[0:4])
  fields["profile_id"] = field(profile, "id")
  fields["composition_age"] = age.to_json()
  let sex = string_field(profile, "sex")
  let mode = string_field(profile, "mode")
  if (sex != "male" && sex != "female") ||
    (mode != "normal" && mode != "athlete") {
    raise DataError("invalid saved profile sex or mode")
  }
  let reading : @protocol.Reading = {
    weight_centi_kg: @json.from_json(field(row, "weight_centi_kg")),
    impedance: @json.from_json(field(row, "impedance")),
    encrypted_impedance: @json.from_json(field(row, "encrypted_impedance")),
    fat_mode: @json.from_json(field(row, "fat_mode")),
  }
  let height : Int = @json.from_json(field(profile, "height_cm"))
  match
    @protocol.body_composition(
      reading,
      height,
      age,
      male=sex == "male",
      athlete=mode == "athlete",
    ) {
    Err(reason) => fields["composition_error"] = reason.to_json()
    Ok(value) => {
      let tenths = [
        value.bmi,
        value.body_fat,
        value.water,
        value.muscle_rate,
        value.bone_rate,
        value.basal_metabolism * 10,
        value.visceral_fat * 10,
        value.lean_mass,
        value.fat_mass,
        value.bone_mass,
        value.muscle_mass,
      ]
      for i in 0..<composition_keys.length() {
        fields[composition_keys[i]] = (tenths[i].to_double() / 10.0).to_json()
      }
    }
  }
  fields.to_json()
}
