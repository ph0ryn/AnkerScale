///|
// The real CLI with an isolated filesystem and a scripted OS transport.
fn main {
  let args = @env.args()
  @app.run(args[1:].to_owned()) catch {
    @app.UsageError(message) => {
      @native.stderr(message)
      @native.exit(2)
    }
    error => {
      @native.stderr(error.to_string())
      @native.exit(1)
    }
  }
}
