//// Backfill loop for GitHub discussions (feature-request category only).
////
//// Structurally identical to jobs/backfill.gleam — same cursor-chaining,
//// same upsert + duplicate-of capture, same out-of-transaction embedding
//// enqueue — but reads from a different GraphQL endpoint and tags the
//// rows with item_type='discussion' so the dashboard can distinguish.
////
//// Lives in its own queue so that a discussion-side failure or rate-limit
//// hiccup doesn't poison the issues chain (or vice versa). Two separate
//// chains, two separate cursors.

import database/item
import database/sql
import github/graphql
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/time/duration
import jobs/embeddings
import logs
import m25
import pog
import types.{type Context}

pub type DiscussionBackfillJob {
  DiscussionBackfillJob(cursor: option.Option(String))
}

fn job_to_json(job: DiscussionBackfillJob) -> json.Json {
  let DiscussionBackfillJob(cursor:) = job
  json.object([
    #("cursor", case cursor {
      option.None -> json.null()
      option.Some(value) -> json.string(value)
    }),
  ])
}

fn job_decoder() -> decode.Decoder(DiscussionBackfillJob) {
  use cursor <- decode.field("cursor", decode.optional(decode.string))
  decode.success(DiscussionBackfillJob(cursor:))
}

pub opaque type DiscussionBackfillError {
  DiscussionBackfillError(message: String)
}

fn map_string_to_error(s: String) -> DiscussionBackfillError {
  DiscussionBackfillError(s)
}

fn map_error(error: a) -> DiscussionBackfillError {
  DiscussionBackfillError(string.inspect(error))
}

fn error_to_json(err: DiscussionBackfillError) -> json.Json {
  let DiscussionBackfillError(message:) = err
  json.object([#("message", json.string(message))])
}

fn error_decoder() -> decode.Decoder(DiscussionBackfillError) {
  use message <- decode.field("message", decode.string)
  decode.success(DiscussionBackfillError(message:))
}

pub fn queue_spec(ctx: Context) {
  m25.Queue(
    name: "discussion_backfill",
    max_concurrency: 4,
    input_to_json: job_to_json,
    input_decoder: job_decoder(),
    output_to_json: json.string,
    output_decoder: decode.string,
    error_to_json: error_to_json,
    error_decoder: error_decoder(),
    handler_function: handle_job(ctx, _),
    default_job_timeout: duration.minutes(1),
    poll_interval: 500,
    heartbeat_interval: 3000,
    allowed_heartbeat_misses: 3,
    executor_init_timeout: 1000,
    reserved_timeout: 300_000,
  )
}

pub fn handle_job(
  ctx: Context,
  job: DiscussionBackfillJob,
) -> Result(String, DiscussionBackfillError) {
  use <- logs.log_errors()

  use page <- result.try(
    graphql.list_discussions(ctx.github_client, job.cursor)
    |> result.map_error(map_string_to_error),
  )

  use _ <- result.try(
    pog.transaction(ctx.db, fn(conn) {
      use _ <- result.try(
        list.map(page.items, fn(bi) {
          item.upsert(conn, sql.Discussion, bi.item)
        })
        |> result.all()
        |> result.map_error(map_error),
      )
      use _ <- result.try(
        list.map(page.items, fn(bi) {
          item.apply_duplicate_of(
            conn,
            bi.item.github_id,
            bi.duplicate_of_number,
          )
        })
        |> result.all()
        |> result.map_error(map_error),
      )
      list.map(page.items, fn(bi) {
        item.apply_author(conn, bi.item.github_id, bi.author_login)
      })
      |> result.all()
      |> result.map_error(map_error)
    })
    |> result.map_error(map_error),
  )

  use _ <- result.try(
    list.map(page.items, fn(bi) { embeddings.enqueue(ctx.db, bi.item.github_id) })
    |> result.all()
    |> result.map_error(map_error),
  )

  case page.page_info.cursor {
    option.Some("") -> Ok("backfilled")
    option.None -> Ok("backfilled")
    option.Some(cursor) -> {
      use _ <- result.try(
        enqueue(ctx, option.Some(cursor))
        |> result.map_error(map_error),
      )
      Ok("backfilled")
    }
  }
}

pub fn enqueue(ctx: Context, cursor: option.Option(String)) {
  enqueue_with_conn(ctx.db, ctx, cursor)
}

pub fn enqueue_with_conn(
  conn: pog.Connection,
  ctx: Context,
  cursor: option.Option(String),
) {
  let job =
    m25.new_job(DiscussionBackfillJob(cursor:))
    |> m25.retry(3, option.Some(duration.seconds(30)))
  m25.enqueue(conn, queue_spec(ctx), job)
}
