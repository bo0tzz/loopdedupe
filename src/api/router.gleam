import api/types
import api/webhook
import config
import database/item
import github/types as github
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/json
import mist
import pog
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn supervised(db_name: process.Name(pog.Message)) {
  let secret = config.get_env(config.SecretKey)
  let db = pog.named_connection(db_name)
  let ctx = types.Context(db:)
  let handler = fn(req) { handle_request(req, ctx) }

  wisp_mist.handler(handler, secret)
  |> mist.new
  |> mist.port(8000)
  |> mist.supervised
}

pub fn handle_request(req: Request, ctx: types.Context) -> Response {
  case req.method, wisp.path_segments(req) {
    Post, ["api", "webhooks", "github"] -> webhook.handle(req, ctx)
    Get, ["api", "items"] -> list_items(ctx)
    _, _ -> wisp.not_found()
  }
}

fn list_items(ctx: types.Context) -> Response {
  case item.list(ctx.db) {
    Ok(list) -> {
      json.array(list, of: github.issue_to_json)
      |> json.to_string()
      |> wisp.json_response(200)
    }
    Error(_) -> wisp.internal_server_error()
  }
}
