//// Posting and listing comments on GitHub, used by the bot reply flow.
//// Issues and PRs share the REST issues API (a PR conversation comment IS
//// an issue comment); discussions have no REST comment surface so those
//// go through GraphQL.

import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import snag
import squall

const repo_base = "https://api.github.com/repos/immich-app/immich"

fn rest_request(token: String, method: http.Method, url: String) {
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { snag.new("failed to build request: " <> url) }),
  )
  req
  |> request.set_method(method)
  |> request.set_header("authorization", "bearer " <> token)
  |> request.set_header("accept", "application/vnd.github+json")
  |> request.set_header("x-github-api-version", "2022-11-28")
  |> Ok
}

/// Post a comment on an issue or PR (same endpoint for both).
pub fn post_issue_comment(
  token: String,
  number: Int,
  body: String,
) -> Result(Nil, snag.Snag) {
  let url = repo_base <> "/issues/" <> int.to_string(number) <> "/comments"
  use req <- result.try(rest_request(token, Post, url))
  let req =
    req
    |> request.set_header("content-type", "application/json")
    |> request.set_body(
      json.object([#("body", json.string(body))]) |> json.to_string,
    )
  use resp <- result.try(httpc.send(req) |> snag.map_error(string.inspect))
  case resp.status {
    201 -> Ok(Nil)
    code ->
      snag.error(
        "post comment: expected 201, got "
        <> int.to_string(code)
        <> ": "
        <> resp.body,
      )
  }
}

/// Bodies of up to 100 comments on an issue/PR, for the already-replied
/// marker check. Best effort — threads longer than a page could in theory
/// hide a marker, at worst causing one duplicate reply on a retry.
pub fn list_issue_comment_bodies(
  token: String,
  number: Int,
) -> Result(List(String), snag.Snag) {
  let url =
    repo_base <> "/issues/" <> int.to_string(number) <> "/comments?per_page=100"
  use req <- result.try(rest_request(token, Get, url))
  use resp <- result.try(httpc.send(req) |> snag.map_error(string.inspect))
  case resp.status {
    200 -> {
      let decoder =
        decode.list({
          use body <- decode.field("body", decode.string)
          decode.success(body)
        })
      json.parse(resp.body, decoder)
      |> result.map_error(fn(e) {
        snag.new("list comments decode: " <> string.inspect(e))
      })
    }
    code -> snag.error("list comments: got " <> int.to_string(code))
  }
}

/// Post a top-level comment on a discussion. Takes the discussion's
/// GraphQL node id (from the webhook payload) — the REST-style numeric id
/// can't be used with the addDiscussionComment mutation.
pub fn post_discussion_comment(
  client: squall.Client,
  discussion_node_id: String,
  body: String,
) -> Result(Nil, snag.Snag) {
  let mutation =
    "
    mutation AddComment($discussionId: ID!, $body: String!) {
      addDiscussionComment(input: {discussionId: $discussionId, body: $body}) {
        comment { id }
      }
    }
  "
  use req <- result.try(
    squall.prepare_request(
      client,
      mutation,
      json.object([
        #("discussionId", json.string(discussion_node_id)),
        #("body", json.string(body)),
      ]),
    )
    |> snag.map_error(string.inspect),
  )
  use resp <- result.try(httpc.send(req) |> snag.map_error(string.inspect))
  case resp.status {
    200 ->
      case string.contains(resp.body, "\"errors\"") {
        False -> Ok(Nil)
        True -> snag.error("addDiscussionComment errors: " <> resp.body)
      }
    code -> snag.error("addDiscussionComment: got " <> int.to_string(code))
  }
}

/// Bodies of the last 100 comments on a discussion, for the marker check.
pub fn list_discussion_comment_bodies(
  client: squall.Client,
  number: Int,
) -> Result(List(String), snag.Snag) {
  let query =
    "
    query DiscussionComments($number: Int!) {
      repository(owner: \"immich-app\", name: \"immich\") {
        discussion(number: $number) {
          comments(last: 100) { nodes { body } }
        }
      }
    }
  "
  use req <- result.try(
    squall.prepare_request(
      client,
      query,
      json.object([#("number", json.int(number))]),
    )
    |> snag.map_error(string.inspect),
  )
  use resp <- result.try(httpc.send(req) |> snag.map_error(string.inspect))
  let decoder =
    decode.at(
      ["data", "repository", "discussion", "comments", "nodes"],
      decode.list({
        use body <- decode.field("body", decode.string)
        decode.success(body)
      }),
    )
  json.parse(resp.body, decoder)
  |> result.map_error(fn(e) {
    snag.new("discussion comments decode: " <> string.inspect(e))
  })
}

/// The invisible marker embedded in every bot reply, keyed by the comment
/// that triggered it. Retry-safety: before posting, scan the thread for
/// the marker — if the previous attempt's POST landed but the job died
/// before completing, the retry finds it and skips.
pub fn reply_marker(comment_id: Int) -> String {
  "<!-- loopdedupe:reply:" <> int.to_string(comment_id) <> " -->"
}

pub fn already_replied(bodies: List(String), comment_id: Int) -> Bool {
  let marker = reply_marker(comment_id)
  list.any(bodies, string.contains(_, marker))
}
