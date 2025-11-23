import jobs/setup
import api/router
import pog
import gleam/otp/static_supervisor
import database/connection
import gleam/erlang/process
import wisp

pub fn main() {
  wisp.configure_logger()
  let db_name = process.new_name("database")
  let assert Ok(_) = start_supervisor(db_name)

  process.sleep_forever()
}

fn start_supervisor(db_name: process.Name(pog.Message)) {
  static_supervisor.new(static_supervisor.RestForOne)
  |> static_supervisor.add(connection.supervised(db_name))
  |> static_supervisor.add(setup.supervised(db_name))
  |> static_supervisor.add(router.supervised(db_name))
  |> static_supervisor.start()
}
