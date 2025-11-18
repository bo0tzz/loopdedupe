import cigogne
import cigogne/config
import envoy
import gleam/erlang/process
import gleam/option
import gleam/otp/actor.{Started}
import gleam/otp/supervision
import gleam/result
import pog

pub fn supervised(
  name: process.Name(pog.Message),
) -> supervision.ChildSpecification(pog.Connection) {
  let assert Ok(db_url) = envoy.get("DATABASE_URL")
  let assert Ok(cfg) = pog.url_config(name, db_url)
  let start = fn() {
    let res = pog.start(cfg)

    case res {
      Ok(Started(_pid, connection)) -> {
        let assert Ok(Nil) = migrate(connection)
        Nil
      }
      Error(_) -> Nil
    }

    res
  }
  supervision.supervisor(start)
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
