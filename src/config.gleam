import gleam/string
import envoy

pub type Env {
  DatabaseUrl
  SecretKey
  Environment
}

fn env_to_string(env: Env) -> String {
  case env {
    SecretKey -> "SECRET_KEY_BASE"
    DatabaseUrl -> "DATABASE_URL"
    Environment -> "ENVIRONMENT"
  }
}

pub fn get_env(env: Env) -> String {
  let assert Ok(val) = env |> env_to_string |> envoy.get
  val
}

pub fn is_dev() -> Bool {
  case get_env(Environment) |> string.lowercase {
    "dev" | "development" -> True
    _ -> False
  }
}