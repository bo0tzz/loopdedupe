import api/dashboard
import api/items
import api/webhook
import config
import gleam/http.{Get, Post}
import gleam/option
import jobs/backfill
import jobs/discussion_backfill
import mist
import types.{type Context}
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn supervised(ctx: Context) {
  let secret = config.get_env(config.SecretKey)

  let handler = handle_request(_, ctx)

  wisp_mist.handler(handler, secret)
  |> mist.new
  |> mist.port(8000)
  |> mist.supervised
}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use <- wisp.log_request(req)

  case req.method, wisp.path_segments(req) {
    Post, ["api", "webhooks", "github"] -> webhook.handle(req, ctx)
    Get, ["api", "items"] -> items.list(ctx)
    Get, ["api", "items", id] -> items.get(ctx, id)
    Get, ["api", "items", id, "similar"] -> items.get_similar(ctx, id)
    Post, ["api", "backfill"] -> start_backfill(ctx)
    Post, ["api", "backfill", "discussions"] -> start_discussion_backfill(ctx)
    Get, [] -> dashboard.index(ctx)
    Get, ["dashboard", "stats"] -> dashboard.stats_fragment(ctx)
    Get, ["items", id] -> dashboard.item_detail(ctx, id)
    _, _ -> wisp.not_found()
  }
}

fn start_backfill(ctx: Context) -> Response {
  case backfill.enqueue(ctx, option.None) {
    Ok(_) -> wisp.response(200) |> wisp.string_body("backfill started")
    Error(_) -> wisp.internal_server_error()
  }
}

fn start_discussion_backfill(ctx: Context) -> Response {
  case discussion_backfill.enqueue(ctx, option.None) {
    Ok(_) ->
      wisp.response(200) |> wisp.string_body("discussion backfill started")
    Error(_) -> wisp.internal_server_error()
  }
}
