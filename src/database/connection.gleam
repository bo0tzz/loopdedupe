import gleam/otp/static_supervisor
import cigogne
import cigogne/config
import envoy
import gleam/erlang/process
import gleam/option
import gleam/result
import pog

pub fn supervised(supervisor: static_supervisor.Builder) {
  let name = process.new_name("database")
  use url <- result.try(envoy.get("DATABASE_URL"))
  use cfg <- result.try(pog.url_config(name, url))
  let supervisor = static_supervisor.add(supervisor, pog.supervised(cfg))
  Ok(#(supervisor, name))
}

pub fn migrate(conn: pog.Connection) {
  let cfg =
    config.Config(
      config.ConnectionDbConfig(conn),
      config.default_mig_table_config,
      config.MigrationsConfig("loopdedupe", option.None, [], option.None),
    )
  use engine <- result.try(cigogne.create_engine(cfg))
  cigogne.apply_all(engine)
}

pub fn init(db: process.Name(pog.Message)) {
  let conn = pog.named_connection(db)
  let assert Ok(_) = migrate(conn)
  conn
}