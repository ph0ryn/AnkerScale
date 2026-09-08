///|
test "state diagnostic explains discovery and preserves errors" {
  assert_eq(
    diagnostic_text("state", {
      "device": "scale-a",
      "phase": "Scanning",
      "attempt": 0,
      "error": null,
    }),
    "scale-a: Searching for the scale",
  )
  assert_eq(
    diagnostic_text("state", {
      "device": "scale-a",
      "phase": "Backoff",
      "attempt": 2,
      "error": "Connection failed",
    }),
    "scale-a: Waiting to retry — Connection failed",
  )
}

///|
test "service startup is not reported as successful or stopped" {
  let status : Json = {
    "registration": "enabled",
    "writer_active": false,
    "writer_pid": null,
    "devices": [
      {
        "id": "scale-a",
        "name": "eufy T9120",
        "phase": "Inactive",
        "last_error": null,
      },
    ],
    "last_saved": null,
    "last_event": null,
    "database": "/data/records.sqlite3",
    "database_exists": false,
    "log": "/data/collector.log",
  }
  let output = service_text(status, "start")
  assert_true(
    output.contains("start requested; running process not yet confirmed"),
  )
  assert_true(output.contains("Waiting for collector startup"))
  assert_true(!output.contains("Not running"))
  assert_true(service_text(status, "status").contains("Collector: not running"))
  let fields : Map[String, Json] = @json.from_json(status)
  fields["registration"] = "requires_approval".to_json()
  assert_true(
    service_text(fields.to_json(), "start").contains("approval required"),
  )
  fields["writer_active"] = true.to_json()
  fields["writer_pid"] = (123).to_json()
  assert_true(
    service_text(fields.to_json(), "status").contains("running (PID 123)"),
  )
}

///|
test "device errors show the message without transport bookkeeping" {
  assert_eq(
    diagnostic_text("disconnected", {
      "device": "scale-a",
      "message": "Connection lost",
      "seq": 65,
      "mono_ms": 123456,
      "failed": true,
    }),
    "scale-a: disconnected — Connection lost",
  )
}
