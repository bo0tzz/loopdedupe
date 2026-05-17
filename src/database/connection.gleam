import cigogne
import cigogne/config as cig_config
import config as env
import gleam/option
import gleam/otp/actor.{Started}
import gleam/otp/supervision
import gleam/result
import pog
import types.{type Context}

pub fn supervised(
  ctx: Context,
) -> supervision.ChildSpecification(pog.Connection) {
  let db_url = env.get_env(env.DatabaseUrl)
  let assert Ok(cfg) = pog.url_config(ctx.db_name, db_url)
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
    cig_config.Config(
      cig_config.ConnectionDbConfig(conn),
      cig_config.default_mig_table_config,
      cig_config.MigrationsConfig("loopdedupe", option.None, [], option.None),
    )
  use engine <- result.try(cigogne.create_engine(cfg))
  cigogne.apply_all(engine)
}
