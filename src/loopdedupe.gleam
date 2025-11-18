// src/app.gleam
import database/connection
import envoy
import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/result
import mist
import wisp
import wisp/wisp_mist

pub fn main() {
  wisp.configure_logger()
  let assert Ok(#(_, db)) = start_supervisor()

  let assert Ok(secret) = envoy.get("SECRET_KEY_BASE")

  let assert Ok(_) =
    wisp_mist.handler(handle_request, secret)
    |> mist.new
    |> mist.port(8000)
    |> mist.start

  process.sleep_forever()
}

fn start_supervisor() {
  let supervisor = static_supervisor.new(static_supervisor.RestForOne)
  use #(supervisor, db) <- result.try(connection.supervised(supervisor))

  let supervisor = static_supervisor.start(supervisor)
  let conn = connection.init(db)

  Ok(#(supervisor, conn))
}

fn handle_request(_req: wisp.Request) -> wisp.Response {
  wisp.response(200)
  |> wisp.string_body("Hello!")
}
