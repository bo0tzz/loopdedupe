import database/item
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

pub type BackfillJob {
  BackfillJob(cursor: option.Option(String))
}

fn backfill_job_to_json(backfill_job: BackfillJob) -> json.Json {
  let BackfillJob(cursor:) = backfill_job
  json.object([
    #("cursor", case cursor {
      option.None -> json.null()
      option.Some(value) -> json.string(value)
    }),
  ])
}

fn backfill_job_decoder() -> decode.Decoder(BackfillJob) {
  use cursor <- decode.field("cursor", decode.optional(decode.string))
  decode.success(BackfillJob(cursor:))
}

pub opaque type BackfillJobError {
  BackfillJobError(message: String)
}

fn map_string_to_error(string: String) -> BackfillJobError {
  BackfillJobError(string)
}

fn map_error(error: a) -> BackfillJobError {
  BackfillJobError(string.inspect(error))
}

fn backfill_job_error_to_json(backfill_job_error: BackfillJobError) -> json.Json {
  let BackfillJobError(message:) = backfill_job_error
  json.object([
    #("message", json.string(message)),
  ])
}

fn backfill_job_error_decoder() -> decode.Decoder(BackfillJobError) {
  use message <- decode.field("message", decode.string)
  decode.success(BackfillJobError(message:))
}

pub fn queue_spec(ctx: Context) {
  m25.Queue(
    name: "backfill",
    max_concurrency: 4,
    input_to_json: backfill_job_to_json,
    input_decoder: backfill_job_decoder(),
    output_to_json: json.string,
    output_decoder: decode.string,
    error_to_json: backfill_job_error_to_json,
    error_decoder: backfill_job_error_decoder(),
    handler_function: handle_backfill_job(ctx, _),
    default_job_timeout: duration.minutes(1),
    poll_interval: 5000,
    heartbeat_interval: 3000,
    allowed_heartbeat_misses: 3,
    executor_init_timeout: 1000,
    reserved_timeout: 300_000,
  )
}

pub fn handle_backfill_job(
  ctx: Context,
  backfill_job: BackfillJob,
) -> Result(String, BackfillJobError) {
  use <- logs.log_errors()

  use items <- result.try(
    graphql.list_items(ctx.github_client, backfill_job.cursor)
    |> result.map_error(map_string_to_error),
  )
  let _ =
    pog.transaction(ctx.db, fn(conn) {
      use _ <- result.try(
        list.map(items.items, item.upsert(conn, _))
        |> result.all()
        |> result.map_error(map_error),
      )
      use _ <- result.try(
        list.map(items.items, fn(item) {
          embeddings.enqueue(conn, item.github_id)
        })
        |> result.all()
        |> result.map_error(map_error),
      )

      case items.page_info.cursor {
        option.Some("") -> Ok(Nil)
        option.Some(cursor) ->
          enqueue_with_conn(conn, ctx, option.Some(cursor))
          |> result.replace(Nil)
          |> result.map_error(map_error)
        option.None -> Ok(Nil)
      }
    })

  Ok("backfilled")
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
    m25.new_job(BackfillJob(cursor:))
    |> m25.retry(3, option.Some(duration.seconds(30)))
  m25.enqueue(conn, queue_spec(ctx), job)
}
