import api/middleware
import api/router.{type Context}
import database/issue
import github/types
import gleam/http.{Post}
import gleam/json
import gleam/result
import snag
import wisp.{type Request, type Response}

pub fn handle(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use <- wisp.require_content_type(req, "application/json")
  use body <- wisp.require_string_body(req)
  use <- middleware.require_github_signature(req.headers, body)

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
