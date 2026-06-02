//// GitHub authentication, with two modes selected by environment:
////
////   1. PAT mode — GITHUB_TOKEN is set; we just hand it back on every
////      request. No refresh needed.
////   2. App mode — GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID +
////      GITHUB_APP_PRIVATE_KEY are all set. We mint short-lived JWTs from
////      the App's private key, exchange them for installation access
////      tokens against /app/installations/$ID/access_tokens, and cache
////      those tokens until shortly before they expire (~1 hour lifetime).
////
//// App mode wins if its full set of env vars is present. The cache + the
//// refresh-on-expiry logic lives in a supervised actor; call sites get
//// the current token via `current_token` or a ready-built `squall.Client`
//// via `client`.

import config
import github/jwt
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Subject}
import gleam/http.{Post}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/option.{type Option}
import gleam/otp/actor.{Started}
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/time/timestamp
import logging
import squall

pub type Msg {
  GetToken(reply_to: Subject(String))
}

type State {
  PatState(token: String)
  AppState(
    app_id: Int,
    installation_id: Int,
    private_key_pem: String,
    cached: Option(CachedToken),
  )
}

type CachedToken {
  CachedToken(token: String, expires_at_unix: Int)
}

/// Refresh ~5 min before expiry so we never hand out a near-expired token.
const refresh_buffer_seconds = 300

pub fn supervised(name: Name(Msg)) -> supervision.ChildSpecification(Nil) {
  let start = fn() {
    let state = initial_state()
    actor.new(state)
    |> actor.named(name)
    |> actor.on_message(handle_message)
    |> actor.start
    |> result.map(fn(started) { Started(started.pid, Nil) })
  }
  supervision.worker(start)
}

fn initial_state() -> State {
  case config.has_github_app_config() {
    True -> {
      let assert Ok(app_id) = int.parse(config.get_env(config.GithubAppId))
      let assert Ok(installation_id) =
        int.parse(config.get_env(config.GithubAppInstallationId))
      AppState(
        app_id:,
        installation_id:,
        private_key_pem: config.get_env(config.GithubAppPrivateKey),
        cached: option.None,
      )
    }
    False -> PatState(token: config.get_env(config.GithubToken))
  }
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    GetToken(reply_to) -> {
      let #(token, new_state) = get_or_refresh(state)
      process.send(reply_to, token)
      actor.continue(new_state)
    }
  }
}

fn get_or_refresh(state: State) -> #(String, State) {
  case state {
    PatState(token) -> #(token, state)
    AppState(_, _, _, option.Some(c)) ->
      case c.expires_at_unix > now_unix() + refresh_buffer_seconds {
        True -> #(c.token, state)
        False -> refresh(state)
      }
    AppState(_, _, _, option.None) -> refresh(state)
  }
}

fn refresh(state: State) -> #(String, State) {
  case state {
    PatState(_) -> #("", state)
    AppState(app_id, installation_id, private_key_pem, cached) ->
      case mint_installation_token(app_id, installation_id, private_key_pem) {
        Ok(fresh) -> #(
          fresh.token,
          AppState(app_id, installation_id, private_key_pem, option.Some(fresh)),
        )
        Error(reason) -> {
          logging.log(
            logging.Warning,
            "installation token refresh failed: " <> reason,
          )
          // Fall back to whatever we have cached. If nothing is cached the
          // call site gets an empty string and the request 401s — better
          // than crashing the actor on a transient GitHub blip.
          case cached {
            option.Some(c) -> #(c.token, state)
            option.None -> #("", state)
          }
        }
      }
  }
}

fn mint_installation_token(
  app_id: Int,
  installation_id: Int,
  private_key_pem: String,
) -> Result(CachedToken, String) {
  let token = jwt.github_app_jwt(app_id:, private_key_pem:, iat: now_unix())
  let url =
    "https://api.github.com/app/installations/"
    <> int.to_string(installation_id)
    <> "/access_tokens"
  use req <- result.try(
    request.to(url) |> result.map_error(fn(_) { "failed to build request" }),
  )
  let req =
    req
    |> request.set_method(Post)
    |> request.set_header("authorization", "Bearer " <> token)
    |> request.set_header("accept", "application/vnd.github+json")
    |> request.set_header("x-github-api-version", "2022-11-28")
    |> request.set_body("")
  use resp <- result.try(
    httpc.send(req) |> result.map_error(fn(_) { "http call failed" }),
  )
  case resp.status {
    201 -> parse_installation_response(resp.body)
    code ->
      Error(
        "non-201 from /access_tokens: "
        <> int.to_string(code)
        <> " — "
        <> resp.body,
      )
  }
}

fn parse_installation_response(body: String) -> Result(CachedToken, String) {
  let decoder = {
    use token <- decode.field("token", decode.string)
    use expires_at <- decode.field("expires_at", decode.string)
    decode.success(#(token, expires_at))
  }
  use #(token, expires_at_iso) <- result.try(
    json.parse(body, decoder)
    |> result.map_error(fn(e) { "json parse: " <> string.inspect(e) }),
  )
  use ts <- result.try(
    timestamp.parse_rfc3339(expires_at_iso)
    |> result.map_error(fn(_) { "bad expires_at: " <> expires_at_iso }),
  )
  let #(secs, _) = timestamp.to_unix_seconds_and_nanoseconds(ts)
  Ok(CachedToken(token:, expires_at_unix: secs))
}

fn now_unix() -> Int {
  let #(secs, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  secs
}

// --- Public API -------------------------------------------------------------

/// Block-and-call the auth actor for a currently-valid GitHub API token.
/// Cheap path (cache hit) returns immediately; cache miss triggers one
/// HTTP roundtrip to GitHub for the installation token. PAT mode never
/// blocks beyond a message send.
pub fn current_token(name: Name(Msg)) -> String {
  process.call_forever(process.named_subject(name), GetToken)
}

/// Per-call squall client built from the current token. Cheaper than
/// keeping a long-lived Client struct — refresh-by-rebuild keeps the
/// App-mode token current.
pub fn client(name: Name(Msg)) -> squall.Client {
  squall.new_with_auth("https://api.github.com/graphql", current_token(name))
}
