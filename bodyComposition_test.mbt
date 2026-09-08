///|
fn composition_reading(
  weight_centi_kg : Int,
  encoded_impedance : Int,
) -> @ankerscale.Reading {
  {
    weight_centi_kg,
    impedance: 500,
    encrypted_impedance: encoded_impedance,
    fat_mode: 0,
  }
}

///|
fn assert_composition(
  weight_centi_kg : Int,
  encoded_impedance : Int,
  height_cm : Int,
  age : Int,
  male~ : Bool,
  athlete~ : Bool,
  expected : @ankerscale.BodyComposition,
) -> Unit raise {
  match
    @ankerscale.body_composition(
      composition_reading(weight_centi_kg, encoded_impedance),
      height_cm,
      age,
      male~,
      athlete~,
    ) {
    Ok(value) => assert_eq(value, expected)
    Err(_) => assert_true(false)
  }
}

///|
test "BestHealth computes male normal and athlete branches" {
  // Expected values are from an independent float32 evaluation of
  // docs/protocol/bodyComposition.md, not from body_composition itself.
  assert_composition(7000, 0xe80300, 175, 30, male=true, athlete=false, {
    bmi: 228,
    body_fat: 192,
    water: 553,
    muscle_rate: 768,
    bone_rate: 40,
    basal_metabolism: 1525,
    visceral_fat: 9,
    lean_mass: 566,
    fat_mass: 134,
    bone_mass: 28,
    muscle_mass: 538,
  })
  assert_composition(7000, 0xe80300, 175, 30, male=true, athlete=true, {
    bmi: 228,
    body_fat: 136,
    water: 592,
    muscle_rate: 821,
    bone_rate: 43,
    basal_metabolism: 1620,
    visceral_fat: 7,
    lean_mass: 605,
    fat_mass: 95,
    bone_mass: 30,
    muscle_mass: 575,
  })
}

///|
test "BestHealth uses the age fifty female branch and athlete outputs" {
  assert_composition(5500, 0xe80300, 160, 50, male=false, athlete=false, {
    bmi: 214,
    body_fat: 279,
    water: 493,
    muscle_rate: 685,
    bone_rate: 36,
    basal_metabolism: 1052,
    visceral_fat: 5,
    lean_mass: 397,
    fat_mass: 153,
    bone_mass: 20,
    muscle_mass: 377,
  })
  assert_composition(6500, 0xb00400, 165, 30, male=false, athlete=true, {
    bmi: 238,
    body_fat: 324,
    water: 483,
    muscle_rate: 635,
    bone_rate: 42,
    basal_metabolism: 1331,
    visceral_fat: 4,
    lean_mass: 440,
    fat_mass: 210,
    bone_mass: 27,
    muscle_mass: 413,
  })
}

///|
test "BestHealth keeps weight and height correction boundaries" {
  // Male correction: R < 610, while R = 610 is unchanged.
  assert_composition(6090, 0xe80300, 170, 30, male=true, athlete=false, {
    bmi: 210,
    body_fat: 162,
    water: 574,
    muscle_rate: 796,
    bone_rate: 43,
    basal_metabolism: 1393,
    visceral_fat: 6,
    lean_mass: 511,
    fat_mass: 98,
    bone_mass: 26,
    muscle_mass: 485,
  })
  assert_composition(6100, 0xe80300, 170, 30, male=true, athlete=false, {
    bmi: 211,
    body_fat: 145,
    water: 586,
    muscle_rate: 813,
    bone_rate: 43,
    basal_metabolism: 1394,
    visceral_fat: 6,
    lean_mass: 522,
    fat_mass: 88,
    bone_mass: 26,
    muscle_mass: 496,
  })

  // Female correction: 50.0 and 60.0 kg are the unadjusted values.
  assert_composition(4990, 0xe80300, 165, 30, male=false, athlete=false, {
    bmi: 183,
    body_fat: 187,
    water: 557,
    muscle_rate: 771,
    bone_rate: 42,
    basal_metabolism: 1122,
    visceral_fat: 1,
    lean_mass: 406,
    fat_mass: 93,
    bone_mass: 21,
    muscle_mass: 385,
  })
  assert_composition(5000, 0xe80300, 165, 30, male=false, athlete=false, {
    bmi: 183,
    body_fat: 204,
    water: 545,
    muscle_rate: 754,
    bone_rate: 42,
    basal_metabolism: 1123,
    visceral_fat: 1,
    lean_mass: 398,
    fat_mass: 102,
    bone_mass: 21,
    muscle_mass: 377,
  })
  assert_composition(6000, 0xe80300, 165, 30, male=false, athlete=false, {
    bmi: 220,
    body_fat: 282,
    water: 491,
    muscle_rate: 678,
    bone_rate: 40,
    basal_metabolism: 1225,
    visceral_fat: 4,
    lean_mass: 431,
    fat_mass: 169,
    bone_mass: 24,
    muscle_mass: 407,
  })
  assert_composition(6010, 0xe80300, 165, 30, male=false, athlete=false, {
    bmi: 220,
    body_fat: 311,
    water: 491,
    muscle_rate: 650,
    bone_rate: 40,
    basal_metabolism: 1226,
    visceral_fat: 4,
    lean_mass: 415,
    fat_mass: 186,
    bone_mass: 24,
    muscle_mass: 391,
  })

  // Female height correction: H = 160 is unchanged, H > 160 is scaled.
  assert_composition(6500, 0xe80300, 160, 30, male=false, athlete=false, {
    bmi: 253,
    body_fat: 380,
    water: 442,
    muscle_rate: 583,
    bone_rate: 37,
    basal_metabolism: 1278,
    visceral_fat: 7,
    lean_mass: 403,
    fat_mass: 247,
    bone_mass: 24,
    muscle_mass: 379,
  })
  assert_composition(6500, 0xe80300, 161, 30, male=false, athlete=false, {
    bmi: 250,
    body_fat: 357,
    water: 459,
    muscle_rate: 604,
    bone_rate: 38,
    basal_metabolism: 1278,
    visceral_fat: 7,
    lean_mass: 418,
    fat_mass: 232,
    bone_mass: 25,
    muscle_mass: 393,
  })
}

///|
test "SDK fixed outputs do not recalculate dependent values" {
  // The fixed body-fat and water values are 66.0% and 72.0%, but fat,
  // lean, and muscle values retain the pre-override Q calculation.
  assert_composition(3000, 0xe80300, 190, 20, male=false, athlete=false, {
    bmi: 83,
    body_fat: 660,
    water: 720,
    muscle_rate: 870,
    bone_rate: 80,
    basal_metabolism: 971,
    visceral_fat: 1,
    lean_mass: 285,
    fat_mass: 15,
    bone_mass: 24,
    muscle_mass: 261,
  })
  assert_composition(3000, 0xe80300, 190, 20, male=false, athlete=true, {
    bmi: 83,
    body_fat: 660,
    water: 720,
    muscle_rate: 863,
    bone_rate: 87,
    basal_metabolism: 977,
    visceral_fat: 1,
    lean_mass: 285,
    fat_mass: 15,
    bone_mass: 26,
    muscle_mass: 259,
  })
  assert_composition(10000, 0xe80300, 90, 20, male=true, athlete=false, {
    bmi: 1234,
    body_fat: 660,
    water: 720,
    muscle_rate: 442,
    bone_rate: 21,
    basal_metabolism: 2124,
    visceral_fat: 44,
    lean_mass: 463,
    fat_mass: 537,
    bone_mass: 21,
    muscle_mass: 442,
  })
  assert_composition(10000, 0xe80300, 90, 20, male=true, athlete=true, {
    bmi: 1234,
    body_fat: 660,
    water: 720,
    muscle_rate: 569,
    bone_rate: 23,
    basal_metabolism: 2314,
    visceral_fat: 38,
    lean_mass: 592,
    fat_mass: 408,
    bone_mass: 23,
    muscle_mass: 569,
  })
}

///|
test "BestHealth impedance decoding handles sentinel and negative truncation" {
  assert_eq(@ankerscale.decode_impedance(0xffffff), 0xffff)
  // (mixed - mask) is -1; integer division must truncate toward zero.
  assert_eq(@ankerscale.decode_impedance(0x1000), 0)
  assert_eq(@ankerscale.decode_impedance(0x10ff), 65026)
  assert_eq(@ankerscale.decode_impedance(0xe80300), 500)
  assert_eq(@ankerscale.decode_impedance(0xb00400), 600)
}

///|
test "BestHealth rejects impedance values outside the documented ranges" {
  let valid = composition_reading(7000, 0xe80300)
  assert_true(
    @ankerscale.body_composition(
      { ..valid, impedance: 0, },
      175,
      30,
      male=true,
      athlete=false,
    )
    is Err(_),
  )
  assert_true(
    @ankerscale.body_composition(
      { ..valid, impedance: 65535, },
      175,
      30,
      male=true,
      athlete=false,
    )
    is Err(_),
  )
  assert_true(
    @ankerscale.body_composition(
      { ..valid, encrypted_impedance: -1, },
      175,
      30,
      male=true,
      athlete=false,
    )
    is Err(_),
  )
  assert_true(
    @ankerscale.body_composition(
      { ..valid, encrypted_impedance: 0x1000000, },
      175,
      30,
      male=true,
      athlete=false,
    )
    is Err(_),
  )
  // 199 and 1201 ohms are just outside the decoded 200..1200 range.
  assert_true(
    @ankerscale.body_composition(
      { ..valid, encrypted_impedance: 0x8e0100, },
      175,
      30,
      male=true,
      athlete=false,
    )
    is Err(_),
  )
  assert_true(
    @ankerscale.body_composition(
      { ..valid, encrypted_impedance: 0x620900, },
      175,
      30,
      male=true,
      athlete=false,
    )
    is Err(_),
  )
}
