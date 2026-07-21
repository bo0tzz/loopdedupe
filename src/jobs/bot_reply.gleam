//// Bot reply job: a maintainer mentioned the bot in a comment on an
//// issue, PR, or discussion. Search the corpus with the parent item's
//// title+body and post the strongest candidates back as a comment.
////
//// Always uses the ad-hoc search path (not the per-item cached one): a
//// mention on a brand-new issue races the embedding/similarity queues,
//// and the ad-hoc path only needs the corpus, not the item's own edges.
//// The parent item is filtered out of the results instead.

import api/search
import github/auth
import github/comments
import github/types as github
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/time/duration
import logs
import m25
import snag
import types.{type Context}

/// Candidates scoring below this rerank floor aren't worth showing.
const score_floor = 0.5

const max_suggestions = 5

pub type BotReplyJob {
  BotReplyJob(
    // "issue" | "pr" | "discussion" — which surface to post the reply on.
    kind: String,
    number: Int,
    comment_id: Int,
    title: String,
    body: String,
    discussion_node_id: option.Option(String),
  )
}

pub opaque type BotReplyError {
  BotReplyError(message: String)
}

fn bot_reply_job_to_json(job: BotReplyJob) -> json.Json {
  let BotReplyJob(
    kind:,
    number:,
    comment_id:,
    title:,
    body:,
    discussion_node_id:,
  ) = job
  json.object([
    #("kind", json.string(kind)),
    #("number", json.int(number)),
    #("comment_id", json.int(comment_id)),
    #("title", json.string(title)),
    #("body", json.string(body)),
    #("discussion_node_id", json.nullable(discussion_node_id, json.string)),
  ])
}

fn bot_reply_job_decoder() -> decode.Decoder(BotReplyJob) {
  use kind <- decode.field("kind", decode.string)
  use number <- decode.field("number", decode.int)
  use comment_id <- decode.field("comment_id", decode.int)
  use title <- decode.field("title", decode.string)
  use body <- decode.field("body", decode.string)
  use discussion_node_id <- decode.field(
    "discussion_node_id",
    decode.optional(decode.string),
  )
  decode.success(BotReplyJob(
    kind:,
    number:,
    comment_id:,
    title:,
    body:,
    discussion_node_id:,
  ))
}

fn error_to_json(error: BotReplyError) -> json.Json {
  let BotReplyError(message:) = error
  json.object([#("message", json.string(message))])
}

fn error_decoder() -> decode.Decoder(BotReplyError) {
  use message <- decode.field("message", decode.string)
  decode.success(BotReplyError(message:))
}

pub fn queue_spec(ctx: Context) {
  m25.Queue(
    name: "bot_reply",
    max_concurrency: 2,
    input_to_json: bot_reply_job_to_json,
    input_decoder: bot_reply_job_decoder(),
    output_to_json: json.string,
    output_decoder: decode.string,
    error_to_json: error_to_json,
    error_decoder: error_decoder(),
    handler_function: handle(ctx, _),
    default_job_timeout: duration.minutes(2),
    poll_interval: 1000,
    heartbeat_interval: 3000,
    allowed_heartbeat_misses: 3,
    executor_init_timeout: 1000,
    reserved_timeout: 300_000,
  )
}

pub fn enqueue(ctx: Context, job: BotReplyJob) {
  let m25_job =
    m25.new_job(job)
    |> m25.retry(2, option.Some(duration.seconds(30)))
    |> m25.unique_key("bot:reply:" <> int.to_string(job.comment_id))
  m25.enqueue(ctx.db, queue_spec(ctx), m25_job)
}

pub fn handle(ctx: Context, job: BotReplyJob) -> Result(String, BotReplyError) {
  use <- logs.log_errors()

  // Retry-safety: skip if a previous attempt's reply already landed.
  use existing <- result.try(
    list_thread_bodies(ctx, job)
    |> result.map_error(fn(e) { BotReplyError(snag.line_print(e)) }),
  )
  case comments.already_replied(existing, job.comment_id) {
    True -> Ok("already replied")
    False -> {
      use hits <- result.try(
        search.do_search(ctx, job.title <> "\n\n" <> job.body)
        |> result.map_error(BotReplyError),
      )
      let hits =
        hits
        |> list.filter(fn(h) {
          h.number != job.number && h.similarity >=. score_floor
        })
        |> list.take(max_suggestions)
      let body = render_reply(hits, job.comment_id)
      use _ <- result.try(
        post(ctx, job, body)
        |> result.map_error(fn(e) { BotReplyError(snag.line_print(e)) }),
      )
      Ok(int.to_string(list.length(hits)) <> " suggestions posted")
    }
  }
}

fn list_thread_bodies(
  ctx: Context,
  job: BotReplyJob,
) -> Result(List(String), snag.Snag) {
  case job.kind {
    "discussion" ->
      comments.list_discussion_comment_bodies(auth.client(ctx.auth), job.number)
    _ ->
      comments.list_issue_comment_bodies(
        auth.current_token(ctx.auth),
        job.number,
      )
  }
}

fn post(
  ctx: Context,
  job: BotReplyJob,
  body: String,
) -> Result(Nil, snag.Snag) {
  case job.kind, job.discussion_node_id {
    "discussion", option.Some(node_id) ->
      comments.post_discussion_comment(auth.client(ctx.auth), node_id, body)
    "discussion", option.None -> snag.error("discussion reply without node id")
    _, _ ->
      comments.post_issue_comment(
        auth.current_token(ctx.auth),
        job.number,
        body,
      )
  }
}

fn render_reply(
  hits: List(github.SuggestedDuplicate),
  comment_id: Int,
) -> String {
  let content = case hits {
    [] ->
      "No sufficiently similar items found — nothing in the corpus scored above "
      <> format_percent(score_floor)
      <> "."
    _ ->
      "Possibly related items:\n\n"
      <> {
        list.map(hits, fn(h) {
          let #(path, kind_label) = case h.item_type {
            github.Issue -> #("issues", "issue")
            github.Discussion -> #("discussions", "discussion")
          }
          // redirect.github.com resolves to the same page but doesn't
          // register a cross-reference, so the linked threads don't get
          // "mentioned this" timeline entries for every bot suggestion.
          "- **"
          <> format_percent(h.similarity)
          <> "** [#"
          <> int.to_string(h.number)
          <> " — "
          <> h.title
          <> "](https://redirect.github.com/immich-app/immich/"
          <> path
          <> "/"
          <> int.to_string(h.number)
          <> ") · "
          <> state_label(h, kind_label)
        })
        |> string.join("\n")
      }
  }
  content
  <> "\n\n<sub>Semantic similarity via loopdedupe · mention me to re-run</sub>\n"
  <> comments.reply_marker(comment_id)
}

fn state_label(h: github.SuggestedDuplicate, kind: String) -> String {
  case h.state, h.state_reason {
    github.Open, _ -> "open " <> kind
    github.Closed, option.Some(github.Duplicate) ->
      "closed " <> kind <> " (duplicate)"
    github.Closed, option.Some(github.NotPlanned) ->
      "closed " <> kind <> " (not planned)"
    github.Closed, _ -> "closed " <> kind
  }
}

fn format_percent(f: Float) -> String {
  float.to_precision(f *. 100.0, 1) |> float.to_string <> "%"
}
