///|
test "collector subscribes before timed writes and ignores stale connections" {
  let c = @ankerscale.Controller::new("device")
  assert_eq(c.handle(PoweredOn, 0, 0), [Scan])
  assert_eq(c.handle(Found("device"), 0, 10), [StopScan, Connect("device", 1)])
  assert_eq(c.handle(Connected, 99, 15), [])
  assert_eq(c.handle(Connected, 1, 20), [Discover])
  assert_eq(c.handle(Profile(true), 1, 30), [Subscribe])
  assert_eq(c.handle(Subscribed, 1, 40), [])
  assert_eq(c.handle(Tick, 1, 239), [])
  assert_eq(c.handle(Tick, 1, 240), [SetUnit])
  assert_eq(c.handle(Tick, 1, 640), [SetTime])
  assert_eq(c.handle(Tick, 1, 1240), [RequestHistory])
}

///|
test "stop cancels pending initialization and prevents reconnect" {
  let c = @ankerscale.Controller::new("device")
  ignore(c.handle(PoweredOn, 0, 0))
  ignore(c.handle(Found("device"), 0, 1))
  ignore(c.handle(Connected, 1, 2))
  ignore(c.handle(Profile(true), 1, 3))
  ignore(c.handle(Subscribed, 1, 4))
  assert_eq(c.handle(Stop, 1, 5), [StopScan, Disconnect])
  assert_eq(c.handle(Tick, 1, 500), [])
  assert_eq(c.handle(Disconnected, 1, 600), [])
  assert_eq(c.phase, @ankerscale.Stopped)
  assert_eq(c.handle(PoweredOn, 0, 700), [])
}

///|
test "unsupported profile never receives initialization" {
  let c = @ankerscale.Controller::new("device")
  ignore(c.handle(PoweredOn, 0, 0))
  ignore(c.handle(Found("device"), 0, 1))
  ignore(c.handle(Connected, 1, 2))
  assert_eq(c.handle(Profile(false), 1, 3), [StopScan, Disconnect])
  assert_true(c.failure is Some(_))
  assert_eq(c.handle(Subscribed, 1, 4), [])
}

///|
test "connection timeout cancels before bounded retry" {
  let c = @ankerscale.Controller::new("device")
  ignore(c.handle(PoweredOn, 0, 0))
  ignore(c.handle(Found("device"), 0, 1))
  assert_eq(c.handle(Tick, 1, 10001), [Disconnect])
  assert_eq(c.handle(Disconnected, 1, 10002), [])
  assert_eq(c.handle(Tick, 1, 11002), [Scan])
}

///|
test "a scan command failure retries instead of claiming to scan forever" {
  let c = @ankerscale.Controller::new("device")
  ignore(c.handle(PoweredOn, 0, 0))
  assert_eq(c.handle(Failed, 0, 1), [])
  assert_eq(c.phase, @ankerscale.Backoff)
  assert_eq(c.handle(Tick, 0, 1001), [Scan])
}

///|
test "Bluetooth loss waits for power and does not connect to a different scale" {
  let c = @ankerscale.Controller::new("device")
  ignore(c.handle(PoweredOn, 0, 0))
  assert_eq(c.handle(Found("another device"), 0, 1), [])
  ignore(c.handle(Found("device"), 0, 2))
  assert_eq(c.handle(PoweredOff, 0, 3), [StopScan])
  assert_eq(c.handle(Connected, 1, 4), [])
  assert_eq(c.handle(Tick, 1, 50000), [])
  assert_eq(c.handle(PoweredOn, 0, 50001), [Scan])
}

///|
test "cancel timeout terminates and retains the original failure" {
  let c = @ankerscale.Controller::new("device")
  ignore(c.handle(PoweredOn, 0, 0))
  ignore(c.handle(Found("device"), 0, 1))
  ignore(c.handle(Fatal("queue overflow"), 0, 2))
  ignore(c.handle(Tick, 1, 5002))
  assert_eq(c.phase, @ankerscale.Stopped)
  assert_eq(c.failure, Some("queue overflow"))
}

///|
test "multiple scales connect independently without stopping another scan" {
  let c = @ankerscale.Collector::new(["a", "b"])
  assert_eq(c.handle(PoweredOn, "", 0, 0), [@ankerscale.CollectionCommand::Scan])
  assert_eq(c.handle(Found("a"), "", 0, 1), [Device("a", 1, Connect("a", 1))])
  let second = c.handle(Found("b"), "", 0, 2)
  assert_true(second.contains(Device("b", 2, Connect("b", 2))))
  assert_eq(c.handle(Connected, "a", 1, 3), [Device("a", 1, Discover)])
  assert_eq(c.handle(Connected, "b", 2, 4), [Device("b", 2, Discover)])
  assert_eq(c.handle(Connected, "b", 1, 5), [])
  assert_eq(c.handle(Profile(true), "a", 1, 6), [Device("a", 1, Subscribe)])
  assert_eq(c.handle(Profile(true), "b", 2, 7), [Device("b", 2, Subscribe)])
  ignore(c.handle(Subscribed, "a", 1, 8))
  ignore(c.handle(Subscribed, "b", 2, 9))
  assert_eq(c.controllers["a"].phase, @ankerscale.Measuring)
  assert_eq(c.controllers["b"].phase, @ankerscale.Measuring)
  let writes = c.handle(Tick, "", 0, 209)
  assert_true(writes.contains(Device("a", 1, SetUnit)))
  assert_true(writes.contains(Device("b", 2, SetUnit)))
}

///|
test "registration changes retire only removed devices and never reuse attempts" {
  let c = @ankerscale.Collector::new(["a"])
  ignore(c.handle(PoweredOn, "", 0, 0))
  ignore(c.handle(Found("a"), "", 0, 1))
  assert_eq(c.update_devices(["a", "b"], 2), [
    @ankerscale.CollectionCommand::Scan,
  ])
  ignore(c.handle(Found("b"), "", 0, 3))
  assert_eq(c.update_devices(["b"], 4), [Device("a", 1, Disconnect)])
  assert_eq(c.handle(Connected, "a", 1, 5), [])
  ignore(c.update_devices(["a", "b"], 6))
  ignore(c.handle(Disconnected, "a", 1, 7))
  assert_eq(c.handle(Found("a"), "", 0, 8), [
    Device("a", 3, Connect("a", 3)),
    StopScan,
  ])
  assert_eq(c.handle(Connected, "a", 1, 9), [])
  assert_eq(c.controllers["b"].attempt, 2)
}

///|
test "a bad scale does not stop another scale and unregistered devices are ignored" {
  let c = @ankerscale.Collector::new(["a", "b"])
  ignore(c.handle(PoweredOn, "", 0, 0))
  assert_eq(c.handle(Found("unregistered"), "", 0, 1), [])
  ignore(c.handle(Found("a"), "", 0, 2))
  ignore(c.handle(Found("b"), "", 0, 3))
  ignore(c.handle(Connected, "a", 1, 4))
  ignore(c.handle(Connected, "b", 2, 5))
  assert_eq(c.handle(Profile(false), "a", 1, 6), [Device("a", 1, Disconnect)])
  ignore(c.handle(Disconnected, "a", 1, 7))
  assert_eq(c.handle(Profile(true), "b", 2, 8), [Device("b", 2, Subscribe)])
  assert_false(c.stopping)
  assert_eq(c.failure, None)
}

///|
test "removing every device waits for new registrations without busy polling" {
  let c = @ankerscale.Collector::new(["a", "b"])
  ignore(c.handle(PoweredOn, "", 0, 0))
  assert_eq(c.update_devices([], 1), [@ankerscale.CollectionCommand::StopScan])
  assert_eq(c.handle(Found("a"), "", 0, 2), [])
  assert_false(c.stopping)
  assert_eq(c.wait_ms(3), 1000)
  assert_eq(c.update_devices(["b"], 4), [@ankerscale.CollectionCommand::Scan])
}

///|
test "global stop cancels all connections within one shared deadline" {
  let c = @ankerscale.Collector::new(["a", "b"])
  ignore(c.handle(PoweredOn, "", 0, 0))
  ignore(c.handle(Found("a"), "", 0, 1))
  ignore(c.handle(Found("b"), "", 0, 2))
  let actions = c.handle(Stop, "", 0, 3)
  assert_true(actions.contains(Device("a", 1, Disconnect)))
  assert_true(actions.contains(Device("b", 2, Disconnect)))
  assert_eq(c.handle(Connected, "a", 1, 4), [])
  ignore(c.handle(Tick, "", 0, 5003))
  assert_true(c.stopped())
  assert_true(c.failure is Some(_))
  assert_eq(c.handle(PoweredOn, "", 0, 6000), [])
}

///|
test "retry refreshes discovery even while another device is still being scanned" {
  let c = @ankerscale.Collector::new(["a", "b"])
  ignore(c.handle(PoweredOn, "", 0, 0))
  ignore(c.handle(Found("a"), "", 0, 1))
  ignore(c.handle(Disconnected, "a", 1, 2))
  assert_eq(c.handle(Tick, "", 0, 1002), [@ankerscale.CollectionCommand::Scan])
  assert_eq(c.update_devices(["a", "b", "c"], 1003), [
    @ankerscale.CollectionCommand::Scan,
  ])
}
