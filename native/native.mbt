///|
pub suberror NativeError {
  NativeError(String)
} derive(Debug)

///|
pub impl Show for NativeError with fn to_string(self) {
  let NativeError(message) = self
  message
}

///|
#borrow(request)
extern "C" fn system_call(request : Bytes) -> Bytes = "as_system_call"

///|
pub fn call(request : Json) -> Json raise {
  unwrap(system_call(@utf8.encode(request.stringify())))
}

///|
fn unwrap(bytes : Bytes) -> Json raise {
  match @json.parse(@utf8.decode(bytes)) {
    { "ok": value, .. } => value
    { "error": String(message), .. } => raise NativeError(message)
    _ => raise NativeError("invalid native response")
  }
}

///|
#external
pub type Database

///|
#borrow(path)
extern "C" fn open_raw(path : Bytes, writable : Bool) -> Database = "as_db_open"

///|
extern "C" fn valid(db : Database) -> Bool = "as_db_valid"

///|
extern "C" fn open_error() -> Bytes = "as_db_error"

///|
pub fn open(path : String, writable~ : Bool) -> Database raise {
  let db = open_raw(@utf8.encode(path), writable)
  if !valid(db) {
    raise NativeError(@utf8.decode(open_error()))
  }
  db
}

///|
#borrow(request)
extern "C" fn query_raw(db : Database, request : Bytes) -> Bytes = "as_db_query"

///|
pub fn Database::query(
  self : Database,
  sql : String,
  args? : Array[Json] = [],
) -> Array[Json] raise {
  let response = unwrap(
    query_raw(
      self,
      @utf8.encode(
        Json::object({ "sql": sql.to_json(), "args": args.to_json() }).stringify(),
      ),
    ),
  )
  match response {
    Array(rows) => rows
    _ => raise NativeError("invalid SQLite result")
  }
}

///|
pub fn Database::exec(
  self : Database,
  sql : String,
  args? : Array[Json] = [],
) -> Unit raise {
  ignore(self.query(sql, args~))
}

///|
pub extern "C" fn Database::close(self : Database) -> Unit = "as_db_close"

///|
#borrow(message)
extern "C" fn stderr_raw(message : Bytes) -> Unit = "as_stderr"

///|
pub fn stderr(message : String) -> Unit {
  stderr_raw(@utf8.encode(message + "\n"))
}

///|
pub extern "C" fn exit(code : Int) -> Unit = "exit"
