// src/app.gleam
import wisp/wisp_mist
import gleam/erlang/process
import mist
import wisp
import envoy

pub fn main() {
  wisp.configure_logger()

  let assert Ok(secret) = envoy.get("SECRET_KEY_BASE")

  let assert Ok(_) =
  wisp_mist.handler(handle_request, secret)
  |> mist.new
  |> mist.port(8000)
  |> mist.start

  process.sleep_forever()
}

fn handle_request(_req: wisp.Request) -> wisp.Response {
  wisp.response(200)
  |> wisp.string_body("Hello!")
}