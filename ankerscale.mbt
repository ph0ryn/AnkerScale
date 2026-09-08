///|
pub(all) struct Reading {
  weight_centi_kg : Int
  impedance : Int
  encrypted_impedance : Int
  fat_mode : Int
} derive(Eq, Debug)

///|
pub(all) enum Packet {
  Stable(Reading)
  Dynamic(Reading)
  Overload
  HistoryCandidate
  Control(Int)
  Unknown
  Invalid(String)
} derive(Eq, Debug)

///|
/// No unverified history or malformed packet is promoted to a measurement.
pub fn parse_t9120(bytes : Bytes) -> Packet {
  if bytes.length() == 0 {
    return Invalid("empty notification")
  }
  if bytes[0] != 0xcf {
    return if bytes.length() == 2 && bytes[0] >= 0xf1 && bytes[0] <= 0xf3 {
      Control(bytes[0].to_int())
    } else {
      Unknown
    }
  }
  if bytes.length() == 18 {
    return HistoryCandidate
  }
  if bytes.length() != 11 {
    return Invalid("live packet must contain 11 bytes")
  }
  let checksum = bytes.iter().take(10).fold(init=0, (a, b) => a ^ b.to_int())
  if checksum != bytes[10].to_int() {
    return Invalid("checksum mismatch")
  }
  let reading = {
    weight_centi_kg: bytes[3].to_int() | (bytes[4].to_int() << 8),
    impedance: bytes[1].to_int() | (bytes[2].to_int() << 8),
    encrypted_impedance: bytes[5].to_int() |
    (bytes[6].to_int() << 8) |
    (bytes[7].to_int() << 16),
    fat_mode: bytes[8].to_int() >> 4,
  }
  match bytes[9].to_int() {
    0 => Stable(reading)
    1 => Dynamic(reading)
    2 => Overload
    _ => Invalid("unknown measurement status")
  }
}

///|
pub fn unit_command() -> Bytes {
  b"\xfd\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfd"
}

///|
/// Calendar validation belongs to the caller supplying the system local time.
pub fn time_command(
  year : Int,
  month : Int,
  day : Int,
  hour : Int,
  minute : Int,
  second : Int,
) -> Bytes {
  Bytes::from_array([
    0xf1,
    (year >> 8).to_byte(),
    (year & 255).to_byte(),
    month.to_byte(),
    day.to_byte(),
    hour.to_byte(),
    minute.to_byte(),
    second.to_byte(),
  ])
}

///|
pub fn weight_text(centi_kg : Int) -> String {
  let fraction = centi_kg % 100
  "\{centi_kg / 100}.\{if fraction < 10 { "0" } else { "" }}\{fraction}"
}
