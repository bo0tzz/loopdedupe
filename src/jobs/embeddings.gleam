import database/embeddings
import database/item
import embeddings/local
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option
import gleam/result
import gleam/string
import gleam/time/duration
import jobs/similarity
import logs
import m25
import pog
import snag

pub type EmbeddingsJob {
  EmbeddingsJob(item_id: Int)
}

pub opaque type EmbeddingsJobError {
  EmbeddingsJobError(message: String)
}

fn map_string_to_error(string: String) -> EmbeddingsJobError {
  EmbeddingsJobError(string)
}

fn map_snag_to_error(snag: snag.Snag) -> EmbeddingsJobError {
  snag.line_print(snag) |> map_string_to_error()
}

fn embeddings_job_error_to_json(
  embeddings_job_error: EmbeddingsJobError,
) -> json.Json {
  let EmbeddingsJobError(message:) = embeddings_job_error
  json.object([
    #("message", json.string(message)),
  ])
}

fn embeddings_job_error_decoder() -> decode.Decoder(EmbeddingsJobError) {
  use message <- decode.field("message", decode.string)
  decode.success(EmbeddingsJobError(message:))
}

fn embeddings_job_to_json(embeddings_job: EmbeddingsJob) -> json.Json {
  let EmbeddingsJob(item_id:) = embeddings_job
  json.object([
    #("item_id", json.int(item_id)),
  ])
}

fn embeddings_job_decoder() -> decode.Decoder(EmbeddingsJob) {
  use item_id <- decode.field("item_id", decode.int)
  decode.success(EmbeddingsJob(item_id:))
}

pub fn queue_spec(conn: pog.Connection) {
  m25.Queue(
    name: "embeddings",
    max_concurrency: 4,
    input_to_json: embeddings_job_to_json,
    input_decoder: embeddings_job_decoder(),
    output_to_json: json.string,
    output_decoder: decode.string,
    error_to_json: embeddings_job_error_to_json,
    error_decoder: embeddings_job_error_decoder(),
    handler_function: handle_embeddings_job(conn, _),
    default_job_timeout: duration.minutes(1),
    poll_interval: 5000,
    heartbeat_interval: 3000,
    allowed_heartbeat_misses: 3,
    executor_init_timeout: 1000,
    reserved_timeout: 300_000,
  )
}

pub fn handle_embeddings_job(
  conn: pog.Connection,
  embeddings_job: EmbeddingsJob,
) -> Result(String, EmbeddingsJobError) {
  use <- logs.log_errors()
  use item <- result.try(
    item.select(conn, embeddings_job.item_id)
    |> result.map_error(fn(s) { EmbeddingsJobError(snag.line_print(s)) }),
  )

  let embed_text = "# " <> item.title <> "\n\n" <> item.body
  use #(embedding, model) <- result.try(
    local.embed(embed_text) |> result.map_error(map_snag_to_error),
  )

  let model_name = local.embed_model_to_string(model)

  use pog.Returned(rows, _) <- result.try(
    embeddings.insert_embedding(conn, item.github_id, embedding, model_name)
    |> result.map_error(fn(err) { string.inspect(err) |> map_string_to_error() }),
  )

  let _ = similarity.enqueue(conn, embeddings_job.item_id)
  Ok(int.to_string(rows) <> " embedding rows inserted")
}

pub fn enqueue(conn: pog.Connection, item_id: Int) {
  let job =
    m25.new_job(EmbeddingsJob(item_id:))
    |> m25.retry(3, option.Some(duration.seconds(30)))
    // Dedupe per item — the unique index on m25.job covers all non-failed,
    // non-cancelled statuses, so this no-ops while a job is pending/running
    // or has already succeeded, but still allows retries after a real
    // failure since failed rows are excluded from the index.
    |> m25.unique_key("embeddings:" <> int.to_string(item_id))
  case m25.enqueue(conn, queue_spec(conn), job) {
    Ok(_) -> Ok(Nil)
    // unique_key collision: a non-finished or already-succeeded job exists
    // for this item. That's exactly the desired outcome — no extra work
    // gets enqueued, and we don't want to roll back the surrounding
    // transaction over a successful no-op.
    Error(m25.JobRecordFetchQueryError(pog.ConstraintViolated(_, _, _))) ->
      Ok(Nil)
    Error(e) -> Error(e)
  }
}
