import api/router
import database/connection
import github/auth
import gleam/erlang/process
import gleam/otp/static_supervisor
import jobs/setup
import logging
import pog
import types.{type Context, Context}
import wisp

pub fn main() {
  logging.configure()
  wisp.configure_logger()
  let db_name = process.new_name("database")
  let db = pog.named_connection(db_name)
  let auth_name = process.new_name("github_auth")

  let ctx = Context(db_name:, db:, auth: auth_name)

  let assert Ok(_) = start_supervisor(ctx)

  process.sleep_forever()
}

fn start_supervisor(ctx: Context) {
  static_supervisor.new(static_supervisor.RestForOne)
  |> static_supervisor.add(connection.supervised(ctx))
  |> static_supervisor.add(auth.supervised(ctx.auth))
  |> static_supervisor.add(setup.supervised(ctx))
  |> static_supervisor.add(router.supervised(ctx))
  |> static_supervisor.start()
}
