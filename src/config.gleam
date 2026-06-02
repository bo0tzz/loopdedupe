import envoy
import gleam/result
import gleam/string

pub type Env {
  DatabaseUrl
  SecretKey
  Environment
  GithubWebhookSecret
  GithubToken
  GithubAppId
  GithubAppInstallationId
  GithubAppPrivateKey
  VoyageApiKey
}

fn env_to_string(env: Env) -> String {
  case env {
    SecretKey -> "SECRET_KEY_BASE"
    DatabaseUrl -> "DATABASE_URL"
    Environment -> "ENVIRONMENT"
    GithubWebhookSecret -> "GITHUB_WEBHOOK_SECRET"
    VoyageApiKey -> "VOYAGE_API_KEY"
    GithubToken -> "GITHUB_TOKEN"
    GithubAppId -> "GITHUB_APP_ID"
    GithubAppInstallationId -> "GITHUB_APP_INSTALLATION_ID"
    GithubAppPrivateKey -> "GITHUB_APP_PRIVATE_KEY"
  }
}

pub fn get_env(env: Env) -> String {
  let assert Ok(val) = env |> env_to_string |> envoy.get
  val
}

pub fn try_env(env: Env) -> Result(String, Nil) {
  env |> env_to_string |> envoy.get
}

pub fn is_dev() -> Bool {
  case get_env(Environment) |> string.lowercase {
    "dev" | "development" -> True
    _ -> False
  }
}

// True iff the full set of GitHub App env vars is present. Used by the auth
// module to decide between App-installation-token mode and plain PAT mode.
// All three are required for App mode; any missing → fall back to PAT.
pub fn has_github_app_config() -> Bool {
  let app_id = try_env(GithubAppId)
  let install_id = try_env(GithubAppInstallationId)
  let key = try_env(GithubAppPrivateKey)
  result.is_ok(app_id) && result.is_ok(install_id) && result.is_ok(key)
}
