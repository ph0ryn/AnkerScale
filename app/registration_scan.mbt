///|
priv enum RegistrationPhase {
  Seen
  Registered
  Connecting(Double)
  Discovering(Double)
  Disconnecting(Result[String, String], Double)
  Verified
  Rejected(String)
}

///|
priv struct Candidate {
  id : String
  mut name : String
  services : Set[String]
  mut rssi : Int
  attempt : Int
  mut phase : RegistrationPhase
}

///|
fn Candidate::matches(self : Candidate) -> Bool {
  self.name == "eufy T9120" ||
  (self.name.is_empty() && self.services.contains("FFF0"))
}

///|
fn Candidate::pending(self : Candidate) -> Bool {
  match self.phase {
    Connecting(_) | Discovering(_) | Disconnecting(_, _) => true
    _ => false
  }
}

///|
fn Candidate::command(self : Candidate, op : String) -> Json {
  { "op": op, "device": self.id, "attempt": self.attempt }
}

///|
fn Candidate::cancel(
  self : Candidate,
  result : Result[String, String],
  now : Double,
) -> Array[Json] {
  match self.phase {
    Connecting(_) | Discovering(_) => {
      self.phase = Disconnecting(result, now + 5000)
      [self.command("ble_disconnect")]
    }
    _ => []
  }
}

///|
// Discovery, verification, and disconnection finish before selection. No
// registration action subscribes to notifications or sends initialization.
priv struct RegistrationScan {
  seen : Map[String, Candidate]
  registered : Set[String]
  seconds : Int
  mut started : Bool
  mut searching : Bool
  mut deadline : Double
  mut failure : String?
}

///|
fn RegistrationScan::new(
  seconds : Int,
  registered : Set[String],
  now : Double,
) -> RegistrationScan {
  {
    seen: Map([]),
    registered,
    seconds,
    started: false,
    searching: true,
    deadline: now + 30000,
    failure: None,
  }
}

///|
fn RegistrationScan::abort(
  self : RegistrationScan,
  message : String,
  now : Double,
) -> Array[Json] {
  if self.failure is None {
    self.failure = Some(message)
  }
  let commands : Array[Json] = []
  if self.searching && self.started {
    commands.push({ "op": "ble_stop_scan" })
  }
  self.searching = false
  for _, candidate in self.seen {
    commands.append(candidate.cancel(Err(message), now))
  }
  commands
}

///|
fn RegistrationScan::tick(self : RegistrationScan, now : Double) -> Array[Json] {
  let commands : Array[Json] = []
  if self.searching && now >= self.deadline {
    if !self.started {
      return self.abort(
        "Bluetooth was not powered on before the registration deadline", now,
      )
    }
    self.searching = false
    commands.push({ "op": "ble_stop_scan" })
  }
  for _, candidate in self.seen {
    match candidate.phase {
      Connecting(deadline) if now >= deadline =>
        commands.append(candidate.cancel(Err("connection timed out"), now))
      Discovering(deadline) if now >= deadline =>
        commands.append(candidate.cancel(Err("GATT discovery timed out"), now))
      Disconnecting(_, deadline) if now >= deadline => {
        let message = "Bluetooth cancellation timed out for \{candidate.id}"
        candidate.phase = Rejected(message)
        commands.append(self.abort(message, now))
      }
      _ => ()
    }
  }
  commands
}

///|
fn RegistrationScan::handle(
  self : RegistrationScan,
  event : Json,
  now : Double,
) -> Array[Json] raise {
  let commands = self.tick(now)
  let kind = collection_event(event)
  match kind {
    PoweredOn =>
      if self.searching && !self.started {
        self.started = true
        self.deadline = now + self.seconds.to_double() * 1000
        commands.push({ "op": "ble_scan" })
      }
    PoweredOff =>
      if self.started {
        commands.append(
          self.abort("Bluetooth was turned off; registration unchanged", now),
        )
      }
    Fatal(message) => commands.append(self.abort(message, now))
    Found(id) =>
      if self.started && self.searching {
        let name = string_field(event, "name")
        let rssi : Int = @json.from_json(field(event, "rssi"))
        let candidate = match self.seen.get(id) {
          Some(candidate) => candidate
          None => {
            let candidate = {
              id,
              name,
              rssi,
              services: Set([]),
              attempt: self.seen.length() + 1,
              phase: Seen,
            }
            self.seen[id] = candidate
            candidate
          }
        }
        // Once verified, retain the name obtained during GATT discovery.
        if !name.is_empty() && candidate.phase is Seen {
          candidate.name = name
        }
        candidate.rssi = rssi
        let services : Array[String] = @json.from_json(field(event, "services"))
        for service in services {
          candidate.services.add(service)
        }
        if candidate.phase is Seen && candidate.matches() {
          if self.registered.contains(id) {
            candidate.phase = Registered
          } else {
            candidate.phase = Connecting(now + 10000)
            commands.push(candidate.command("ble_connect"))
          }
        }
      }
    _ =>
      if event is { "device": String(id), "attempt": Number(attempt, ..), .. } &&
        self.seen.get(id) is Some(candidate) &&
        attempt == candidate.attempt.to_double() {
        match (kind, candidate.phase) {
          (Connected, Connecting(_)) => {
            candidate.phase = Discovering(now + 10000)
            commands.push(candidate.command("ble_discover"))
          }
          (Profile(verified), Discovering(_)) => {
            let result = if verified {
              Ok(string_field(event, "name"))
            } else {
              let observed : Json = {
                "name": field(event, "name"),
                "services": field(event, "services"),
              }
              Err(
                "expected eufy T9120 with FFF0, FFF4 notify/indicate, and writable FFF1; received \{observed.stringify()}",
              )
            }
            commands.append(candidate.cancel(result, now))
          }
          (Disconnected, Disconnecting(result, _)) =>
            match result {
              Ok(name) => {
                candidate.name = name
                candidate.phase = Verified
              }
              Err(message) => candidate.phase = Rejected(message)
            }
          (Disconnected, Connecting(_) | Discovering(_)) =>
            candidate.phase = Rejected(
              "disconnected before verification completed",
            )
          (Failed, _) =>
            commands.append(
              candidate.cancel(Err(string_field(event, "message")), now),
            )
          _ => ()
        }
      }
  }
  commands
}

///|
fn RegistrationScan::finished(self : RegistrationScan) -> Bool {
  !self.searching && self.seen.values().all(c => !c.pending())
}

///|
fn RegistrationScan::choices(self : RegistrationScan) -> Array[Candidate] {
  if self.failure is Some(_) {
    return []
  }
  let candidates = self.seen
    .values()
    .filter(c => c.phase is (Verified | Registered))
    .to_array()
  candidates.sort_by((a, b) => a.id.compare(b.id))
  candidates
}
