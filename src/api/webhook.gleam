import api/middleware
import api/types.{type Context}
import database/item
import github/types as github
import gleam/http.{Post}
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import snag
import wisp.{type Request, type Response}

pub fn handle(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use <- wisp.require_content_type(req, "application/json")
  use body <- wisp.require_string_body(req)
  log_request(req.headers, body)
  use <- middleware.require_github_signature(req.headers, body)

  case parse_and_upsert_webhook(body, ctx) {
    Ok(_) -> wisp.response(200) |> wisp.string_body("OK")
    Error(e) -> snag.line_print(e) |> wisp.bad_request
  }
}

fn log_request(headers: List(#(String, String)), body: String) {
  let headers =
    list.fold(headers, "", fn(headers, header) {
      let #(k, v) = header
      string.concat([headers, "\n", k, ": ", v])
    })
  string.concat([headers, "\n\n", body]) |> wisp.log_info()
}

//TODO: Move to svc layer?
fn parse_and_upsert_webhook(body: String, ctx: Context) {
//  use webhook <- result.try(
//    json.parse(body, github.issue_webhook_decoder())
//    |> snag.replace_error("failed to decode webhook")
//  )
  let assert Ok(webhook) = json.parse(body, github.issue_webhook_decoder())
  item.upsert(ctx.db, webhook.issue) |> snag.replace_error("failed to insert")
}
