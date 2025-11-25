import api/router
import database/connection
import github/graphql
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

  let github_client = graphql.new_client()

  let ctx = Context(db_name:, db:, github_client:)

  let assert Ok(_) = start_supervisor(ctx)

  process.sleep_forever()
}

fn start_supervisor(ctx: Context) {
  static_supervisor.new(static_supervisor.RestForOne)
  |> static_supervisor.add(connection.supervised(ctx))
  |> static_supervisor.add(setup.supervised(ctx))
  |> static_supervisor.add(router.supervised(ctx))
  |> static_supervisor.start()
}
