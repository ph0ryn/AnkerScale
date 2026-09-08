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
