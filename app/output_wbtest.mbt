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
test "service status describes collector and approval state" {
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
  assert_true(service_text(status).contains("Collector: not running"))
  let fields : Map[String, Json] = @json.from_json(status)
  fields["registration"] = "requires_approval".to_json()
  assert_true(service_text(fields.to_json()).contains("approval required"))
  fields["writer_active"] = true.to_json()
  fields["writer_pid"] = (123).to_json()
  assert_true(service_text(fields.to_json()).contains("running (PID 123)"))
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

///|
test "startup waits for the launched service to own the writer lock" {
  assert_true(
    !service_completed(
      "start",
      { "registration": "enabled", "writer_active": false, "writer_pid": null },
      (123).to_json(),
    ),
  )
  assert_true(
    !service_completed(
      "start",
      { "registration": "enabled", "writer_active": true, "writer_pid": 456 },
      (123).to_json(),
    ),
  )
  assert_true(
    service_completed(
      "start",
      { "registration": "enabled", "writer_active": true, "writer_pid": 123 },
      (123).to_json(),
    ),
  )
}

///|
test "stop waits for both writer exit and unregistration" {
  assert_true(
    !service_completed(
      "stop",
      { "registration": "enabled", "writer_active": false },
      Json::null(),
    ),
  )
  assert_true(
    !service_completed(
      "stop",
      { "registration": "not_registered", "writer_active": true },
      Json::null(),
    ),
  )
  assert_true(
    service_completed(
      "stop",
      { "registration": "not_registered", "writer_active": false },
      Json::null(),
    ),
  )
}

///|
test "approval and missing definitions cannot report completion" {
  let approval = service_completed(
    "start",
    { "registration": "requires_approval", "writer_active": false },
    (123).to_json(),
  ).to_string() catch {
    error => error.to_string()
  }
  assert_true(approval.contains("Approval required"))
  let missing = service_completed(
    "stop",
    { "registration": "not_found", "writer_active": false },
    Json::null(),
  ).to_string() catch {
    error => error.to_string()
  }
  assert_true(missing.contains("service definition not found"))
}
