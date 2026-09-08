///|
pub(all) enum CollectionCommand {
  Scan
  StopScan
  Device(String, Int, Action)
} derive(Eq, Debug)

///|
/// One shared scan and independent device controllers. Retiring connections
/// finish cancellation before a registration of the same UUID can replace them.
pub struct Collector {
  controllers : Map[String, Controller]
  priv mut targets : Set[String]
  priv retiring : Set[String]
  priv mut next_attempt : Int
  priv mut powered : Bool
  priv mut scanning : Bool
  priv mut rescan : Bool
  mut stopping : Bool
  mut failure : String?
}

///|
pub fn Collector::new(devices : Array[String]) -> Collector {
  let controllers : Map[String, Controller] = Map([])
  for id in devices {
    controllers[id] = Controller::new(id)
  }
  {
    controllers,
    targets: Set(devices),
    retiring: Set([]),
    next_attempt: 0,
    powered: false,
    scanning: false,
    rescan: false,
    stopping: false,
    failure: None,
  }
}

///|
fn Collector::dispatch(
  self : Collector,
  controller : Controller,
  event : CollectionEvent,
  attempt : Int,
  now : Double,
  commands : Array[CollectionCommand],
) -> Unit {
  let previous = controller.phase
  let deadline = controller.deadline
  for action in controller.handle(event, attempt, now) {
    match action {
      Scan => self.rescan = true
      StopScan => () // Scan ownership belongs to the collector.
      Connect(id, _) => {
        self.next_attempt += 1
        controller.attempt = self.next_attempt
        commands.push(
          Device(id, controller.attempt, Connect(id, controller.attempt)),
        )
      }
      _ => commands.push(Device(controller.target, controller.attempt, action))
    }
  }
  if event == Tick &&
    (previous == Stopping || previous == Disconnecting) &&
    now >= deadline &&
    controller.phase == Stopped &&
    self.failure is None {
    self.failure = Some(
      "Bluetooth cancellation timed out for \{controller.target}",
    )
  }
}

///|
fn Collector::stop_all(
  self : Collector,
  now : Double,
  commands : Array[CollectionCommand],
) -> Unit {
  self.stopping = true
  for _, controller in self.controllers {
    self.dispatch(controller, Stop, controller.attempt, now, commands)
  }
}

///|
fn Collector::synchronize(
  self : Collector,
  now : Double,
  commands : Array[CollectionCommand],
) -> Unit {
  if self.failure is Some(_) && !self.stopping {
    self.stop_all(now, commands)
  }
  for id in self.retiring.to_array() {
    if self.controllers[id].phase == Stopped {
      self.controllers.remove(id)
      self.retiring.remove(id)
    }
  }
  if !self.stopping {
    for id in self.targets {
      if !self.controllers.contains(id) {
        let controller = Controller::new(id)
        self.controllers[id] = controller
        if self.powered {
          self.dispatch(controller, PoweredOn, 0, now, commands)
        }
      }
    }
  }
  let wanted = !self.stopping &&
    self.powered &&
    self.controllers.values().any(controller => controller.phase == Scanning)
  if wanted != self.scanning || (wanted && self.rescan) {
    self.scanning = wanted
    commands.push(if wanted { Scan } else { StopScan })
  }
  self.rescan = false
}

///|
pub fn Collector::update_devices(
  self : Collector,
  devices : Array[String],
  now : Double,
) -> Array[CollectionCommand] {
  if self.stopping {
    return []
  }
  self.targets = Set(devices)
  let commands : Array[CollectionCommand] = []
  for id, controller in self.controllers {
    if !self.targets.contains(id) {
      self.retiring.add(id)
      self.dispatch(controller, Stop, controller.attempt, now, commands)
    }
  }
  self.synchronize(now, commands)
  commands
}

///|
/// Device callbacks are routed by UUID and generation. The empty device string
/// is reserved for shared transport events and clock ticks.
pub fn Collector::handle(
  self : Collector,
  event : CollectionEvent,
  device : String,
  attempt : Int,
  now : Double,
) -> Array[CollectionCommand] {
  if self.stopped() {
    return []
  }
  let commands : Array[CollectionCommand] = []
  match event {
    Stop => self.stop_all(now, commands)
    Fatal(message) => {
      if self.failure is None {
        self.failure = Some(message)
      }
      self.stop_all(now, commands)
    }
    PoweredOn | PoweredOff | Tick => {
      if event == PoweredOn {
        self.powered = true
      } else if event == PoweredOff {
        self.powered = false
      }
      for _, controller in self.controllers {
        self.dispatch(controller, event, controller.attempt, now, commands)
      }
    }
    Found(id) =>
      if !self.stopping &&
        self.targets.contains(id) &&
        !self.retiring.contains(id) {
        if self.controllers.get(id) is Some(controller) {
          self.dispatch(controller, event, 0, now, commands)
        }
      }
    Failed =>
      if device.is_empty() {
        self.scanning = false
        for _, controller in self.controllers {
          if controller.phase == Scanning {
            self.dispatch(controller, Failed, controller.attempt, now, commands)
          }
        }
      } else if self.controllers.get(device) is Some(controller) {
        self.dispatch(controller, event, attempt, now, commands)
      }
    _ =>
      if self.controllers.get(device) is Some(controller) {
        self.dispatch(controller, event, attempt, now, commands)
      }
  }
  self.synchronize(now, commands)
  commands
}

///|
pub fn Collector::stopped(self : Collector) -> Bool {
  self.stopping &&
  self.controllers.values().all(controller => controller.phase == Stopped)
}

///|
pub fn Collector::wait_ms(self : Collector, now : Double) -> Int {
  let mut wait = 1000
  for _, controller in self.controllers {
    if controller.phase != Stopped {
      wait = wait.min(controller.wait_ms(now))
    }
  }
  wait
}
