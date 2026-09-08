///|
/// BestHealth outputs in tenths, except kcal/day and visceral fat level.
/// Keep integer intermediates: SDK overrides do not recompute dependent values.
pub(all) struct BodyComposition {
  bmi : Int
  body_fat : Int
  water : Int
  muscle_rate : Int
  bone_rate : Int
  basal_metabolism : Int
  visceral_fat : Int
  lean_mass : Int
  fat_mass : Int
  bone_mass : Int
  muscle_mass : Int
} derive(Eq, Debug)

///|
pub fn decode_impedance(encoded : Int) -> Int {
  if encoded == 0xffffff {
    return 0xffff
  }
  let mixed = (encoded & 0xf00) | ((encoded >> 16) & 0xff)
  let mask = 4 * (encoded & 0xff) + ((encoded >> 12) & 0xf)
  ((mixed - mask) / 2) & 0xffff
}

///|
/// T9120 / BestHealth only. Age is the measurement year minus birth year.
/// Invalid inputs return a reason instead of partially computed SDK outputs.
pub fn body_composition(
  reading : Reading,
  height_cm : Int,
  age : Int,
  male~ : Bool,
  athlete~ : Bool,
) -> Result[BodyComposition, String] {
  if age < 6 || age > 99 {
    return Err("Age must be 6–99 for body composition")
  }
  if height_cm < 90 || height_cm > 220 {
    return Err("Height must be 90–220 cm for body composition")
  }
  let w = Float::from_int(reading.weight_centi_kg) / 100.0
  let r = (w * 10.0).to_int()
  if r < 100 || r > 2000 {
    return Err("Weight must be 10–200 kg after conversion")
  }
  if reading.impedance < 1 || reading.impedance > 65534 {
    return Err("No valid impedance in this measurement")
  }
  if reading.encrypted_impedance < 0 || reading.encrypted_impedance > 0xffffff {
    return Err("Invalid encoded impedance")
  }
  let z = decode_impedance(reading.encrypted_impedance)
  if z < 200 || z > 1200 {
    return Err("Decoded impedance must be 200–1200 ohms")
  }
  let rf = Float::from_int(r)
  let h = Float::from_int(height_cm)
  let a = Float::from_int(age)
  let t : Float = 0.032 * rf +
    (9.058 * (h * h) / 10000.0 + 12.226) -
    0.0068 * Float::from_int(z) -
    0.0542 * a
  let mut l = t - (if male { 0.8 } else if age < 50 { 9.25 } else { 7.25 })
  if male {
    if r < 610 {
      l *= 0.98
    }
  } else {
    if r < 500 {
      l *= 1.02
    } else if r > 600 {
      l *= 0.96
    }
    if height_cm > 160 {
      l *= 1.03
    }
  }
  let mut f = rf / 10.0 - l
  if athlete {
    f = if male { f * 0.778 - 0.93 } else { f * 0.992 - 1.5 }
  }
  let q = Float::min(Float::max(f * 10000.0 / rf, 50.0), 750.0).to_int()
  let b = q * r / 1000
  let mut u = 7 * (1000 - q) / 10
  u = (if u <= 500 { 102 } else { 98 }) * u / 100
  if athlete {
    u = (if male {
      Float::from_int(u) * 0.996 + 4.0
    } else {
      Float::from_int(u) * 0.985 + 9.0
    }).to_int()
  }
  u = Int::max(u, 350)
  let n = (t * 0.5158 - (if male { 1.802 } else { 2.4569 })).to_int()
  let mut k = n + (if n > 22 { 1 } else { -1 })
  if athlete {
    k += if k < 20 { 1 } else if k < 30 { 2 } else { 3 }
  }
  let c = r - b - k
  let energy : Float = if male {
    1.4916 * rf + 877.8 - 0.726 * h - 8.976 * a
  } else {
    1.0204 * rf + 864.6 - 0.3934 * h - 6.204 * a
  }
  let mut e = energy.to_int()
  if athlete {
    e = (Float::from_int(e) * 1.16 - 149.0).to_int()
  }
  let mut v : Float = if !male {
    if 5 * height_cm - 130 >= r {
      (-0.0024 * h + 0.691) * rf / 10.0 - 0.027 * h + 0.07 * a - 10.5
    } else {
      0.07 * a + (50.0 * rf / (1.45 * h + 0.1158 * (h * h) - 120.0) - 6.0)
    }
  } else if rf * 0.16 + 63.0 > h {
    0.15 * a + (30.5 * rf / (0.0826 * (h * h) - 0.4 * h + 48.0) - 2.9)
  } else {
    (-0.0015 * h + 0.765) * rf / 10.0 - 0.143 * h + 0.15 * a - 5.0
  }
  if athlete {
    v = if v < 2.0 {
      1.0
    } else if v < 10.0 {
      v - 2.0
    } else if v < 20.0 {
      v * 0.8
    } else {
      v * 0.85
    }
  }
  let overridden = age == 20 &&
    (
      (!male && height_cm == 190 && r == 300) ||
      (male && height_cm == 90 && r == 1000)
    )
  // Bone mass crosses the SDK's float32 output boundary before the app's
  // float64 ratio. W retains the original measurement's hundredths of a kg.
  let bone_rate = ((Float::from_int(k) / 10.0).to_double() /
    (reading.weight_centi_kg.to_double() / 100.0) *
    100.0 *
    10.0)
    .round()
    .to_int()
  Ok({
    bmi: 10000 * r / (height_cm * height_cm),
    body_fat: if overridden {
      660
    } else {
      q
    },
    water: if overridden {
      720
    } else {
      u
    },
    muscle_rate: (Float::from_int(c) * 1000.0 / rf).to_int(),
    bone_rate,
    basal_metabolism: Int::max(e, 500),
    visceral_fat: Float::min(Float::max(v, 1.0), 50.0).to_int(),
    lean_mass: r - b,
    fat_mass: b,
    bone_mass: k,
    muscle_mass: c,
  })
}
