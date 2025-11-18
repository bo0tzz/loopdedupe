import config
import database/repository
import gleam/erlang/process
import gleam/http.{Get}
import gleam/json
import mist
import pog
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub type Context {
  Context(db: pog.Connection)
}

pub fn supervised(db_name: process.Name(pog.Message)) {
  let secret = config.get_env(config.SecretKey)
  let db = pog.named_connection(db_name)
  let ctx = Context(db:)
  let handler = fn(req) { handle_request(req, ctx) }

  wisp_mist.handler(handler, secret)
  |> mist.new
  |> mist.port(8000)
  |> mist.supervised
}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  case req.method, wisp.path_segments(req) {
    Get, ["api", "repository"] -> list_repositories(ctx)
    _, _ -> wisp.not_found()
  }
}

fn list_repositories(ctx: Context) -> Response {
  case repository.list(ctx.db) {
    Ok(result) -> {
      let j = json.array(result, of: repository.to_json)
      wisp.json_response(json.to_string(j), 200)
    }
    Error(_) -> wisp.internal_server_error()
  }
}
