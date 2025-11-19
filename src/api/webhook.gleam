import api/router.{type Context}
import config
import database/issue
import github/types
import github/webhook
import gleam/http.{Post}
import gleam/json
import gleam/list
import gleam/result
import snag
import wisp.{type Request, type Response}

fn invalid_sig() {
  wisp.response(401) |> wisp.string_body("invalid signature")
}

pub fn handle(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)

  //TODO: middleware for sig validation?
  let signature = case list.key_find(req.headers, "x-hub-signature-256") {
    Ok(sig) -> sig
    Error(_) -> "" // TODO: Serve invalid_sig()
  }

  use body <- wisp.require_string_body(req)

  let secret = config.get_env(config.SecretKey)
  case config.is_dev() || webhook.validate_signature(body, signature, secret) {
    True -> process_webhook(body, ctx)
    False -> invalid_sig()
  }
}

fn process_webhook(body: String, ctx: Context) -> Response {
  case parse_and_upsert_webhook(body, ctx) {
    Ok(_) -> wisp.response(200) |> wisp.string_body("OK")
    Error(e) -> snag.line_print(e) |> wisp.bad_request
  }
}

//TODO: Move to svc layer?
fn parse_and_upsert_webhook(body: String, ctx: Context) {
  use webhook <- result.try(
    json.parse(body, types.issue_webhook_decoder())
    |> snag.replace_error("failed to decode webhook"),
  )
  issue.upsert(ctx.db, webhook.issue) |> snag.replace_error("failed to insert")
}
