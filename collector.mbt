///|
pub(all) enum Phase {
  WaitingPower
  Scanning
  Connecting
  Discovering
  Subscribing
  Measuring
  Disconnecting
  Backoff
  Stopping
  Stopped
} derive(Eq, Debug)

///|
pub(all) enum CollectionEvent {
  PoweredOn
  PoweredOff
  Found(String)
  Connected
  Profile(Bool)
  Subscribed
  Received
  Disconnected
  Failed
  Fatal(String)
  Tick
  Stop
} derive(Eq, Debug)

///|
pub(all) enum Action {
  Scan
  StopScan
  Connect(String, Int)
  Discover
  Subscribe
  SetUnit
  SetTime
  RequestHistory
  Disconnect
} derive(Eq, Debug)

///|
/// The controller owns deadlines and policy, independently of CoreBluetooth.
pub struct Controller {
  target : String
  mut phase : Phase
  mut attempt : Int
  mut failure : String?
  mut deadline : Double
  mut subscribed_at : Double
  mut write_step : Int
  mut retry_ms : Double
  mut powered : Bool
}

///|
pub fn Controller::new(target : String) -> Controller {
  {
    target,
    phase: WaitingPower,
    attempt: 0,
    failure: None,
    deadline: 0,
    subscribed_at: 0,
    write_step: 0,
    retry_ms: 1000,
    powered: false,
  }
}

///|
fn Controller::stop(self : Controller, now : Double) -> Array[Action] {
  match self.phase {
    Stopping | Stopped => []
    WaitingPower | Scanning | Backoff => {
      self.phase = Stopped
      [StopScan]
    }
    _ => {
      self.phase = Stopping
      self.deadline = now + 5000
      [StopScan, Disconnect]
    }
  }
}

///|
fn Controller::retry(self : Controller, now : Double) -> Unit {
  self.phase = if self.powered { Backoff } else { WaitingPower }
  self.deadline = now + self.retry_ms
  self.retry_ms = (self.retry_ms * 2).min(30000)
}

///|
/// Non-global events carry an attempt number so an old callback cannot advance
/// a later connection. Cancellation must finish before a retry is scheduled.
pub fn Controller::handle(
  self : Controller,
  event : CollectionEvent,
  attempt : Int,
  now : Double,
) -> Array[Action] {
  if self.phase == Stopped {
    return []
  }
  match event {
    Stop => return self.stop(now)
    Fatal(message) => {
      self.failure = Some(message)
      return self.stop(now)
    }
    PoweredOn => {
      self.powered = true
      if self.phase == WaitingPower {
        self.phase = Scanning
        return [Scan]
      }
      return []
    }
    PoweredOff => {
      self.powered = false
      if self.phase == Stopping {
        self.phase = Stopped
      } else {
        self.phase = WaitingPower
      }
      return [StopScan]
    }
    Found(device) => {
      if self.phase == Scanning && device == self.target {
        self.phase = Connecting
        self.attempt += 1
        self.deadline = now + 10000
        return [StopScan, Connect(device, self.attempt)]
      }
      return []
    }
    Tick => ()
    _ => if attempt != self.attempt { return [] }
  }
  match event {
    Connected =>
      if self.phase == Connecting {
        self.phase = Discovering
        self.deadline = now + 10000
        [Discover]
      } else {
        []
      }
    Profile(verified) =>
      if self.phase == Discovering {
        if verified {
          self.phase = Subscribing
          self.deadline = now + 10000
          [Subscribe]
        } else {
          self.failure = Some(
            "unsupported device name or GATT profile; initialization was not sent",
          )
          self.stop(now)
        }
      } else {
        []
      }
    Subscribed =>
      if self.phase == Subscribing {
        self.phase = Measuring
        self.subscribed_at = now
        self.write_step = 0
        self.deadline = now + 30000
        []
      } else {
        []
      }
    Received => {
      if self.phase == Measuring {
        self.deadline = now + 30000
        self.retry_ms = 1000
      }
      []
    }
    Disconnected => {
      if self.phase == Stopping {
        self.phase = Stopped
      } else if self.phase != WaitingPower &&
        self.phase != Backoff &&
        self.phase != Scanning {
        self.retry(now)
      }
      []
    }
    Failed =>
      if self.phase == Connecting || self.phase == Scanning {
        self.retry(now)
        []
      } else if self.phase == Discovering ||
        self.phase == Subscribing ||
        self.phase == Measuring {
        self.phase = Disconnecting
        self.deadline = now + 5000
        [Disconnect]
      } else {
        []
      }
    Tick => {
      if self.phase == Backoff && now >= self.deadline {
        self.phase = Scanning
        return [Scan]
      }
      if (self.phase == Stopping || self.phase == Disconnecting) &&
        now >= self.deadline {
        if self.failure is None {
          self.failure = Some("Bluetooth cancellation timed out")
        }
        self.phase = Stopped
        return []
      }
      if self.phase == Connecting ||
        self.phase == Discovering ||
        self.phase == Subscribing ||
        self.phase == Measuring {
        if now >= self.deadline ||
          (self.phase == Measuring && now - self.subscribed_at >= 120000) {
          self.phase = Disconnecting
          self.deadline = now + 5000
          return [Disconnect]
        }
      }
      if self.phase == Measuring {
        let due : Double = match self.write_step {
          0 => 200
          1 => 600
          _ => 1200
        }
        if self.write_step < 3 && now >= self.subscribed_at + due {
          let action = match self.write_step {
            0 => SetUnit
            1 => SetTime
            _ => RequestHistory
          }
          self.write_step += 1
          return [action]
        }
      }
      []
    }
    _ => []
  }
}

///|
/// A one-second ceiling lets signal handling run without busy polling.
pub fn Controller::wait_ms(self : Controller, now : Double) -> Int {
  let until = if self.phase == Measuring && self.write_step < 3 {
    self.subscribed_at +
    (match self.write_step {
      0 => 200
      1 => 600
      _ => 1200
    })
  } else if self.phase == WaitingPower || self.phase == Scanning {
    now + 1000
  } else {
    self.deadline
  }
  (until - now).max(0).min(1000).to_int()
}
