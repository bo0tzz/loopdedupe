import database/embeddings
import database/sql
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option
import gleam/result
import gleam/string
import gleam/time/duration
import logs
import m25
import pog

pub type SimilarityJob {
  SimilarityJob(item_id: Int)
}

pub opaque type SimilarityJobError {
  SimilarityJobError(message: String)
}

fn map_string_to_error(string: String) -> SimilarityJobError {
  SimilarityJobError(string)
}

fn similarity_job_error_to_json(
  similarity_job_error: SimilarityJobError,
) -> json.Json {
  let SimilarityJobError(message:) = similarity_job_error
  json.object([
    #("message", json.string(message)),
  ])
}

fn similarity_job_error_decoder() -> decode.Decoder(SimilarityJobError) {
  use message <- decode.field("message", decode.string)
  decode.success(SimilarityJobError(message:))
}

fn similarity_job_to_json(similarity_job: SimilarityJob) -> json.Json {
  let SimilarityJob(item_id:) = similarity_job
  json.object([
    #("item_id", json.int(item_id)),
  ])
}

fn similarity_job_decoder() -> decode.Decoder(SimilarityJob) {
  use item_id <- decode.field("item_id", decode.int)
  decode.success(SimilarityJob(item_id:))
}

pub fn queue_spec(conn: pog.Connection) {
  m25.Queue(
    name: "similarity",
    // Local kNN plus the edge rewrite in one transaction, so every running
    // job holds a pool connection until it finishes. Kept well under the
    // pool size so the other queues and HTTP still get one.
    max_concurrency: 8,
    input_to_json: similarity_job_to_json,
    input_decoder: similarity_job_decoder(),
    output_to_json: json.string,
    output_decoder: decode.string,
    error_to_json: similarity_job_error_to_json,
    error_decoder: similarity_job_error_decoder(),
    handler_function: handle_similarity_job(conn, _),
    default_job_timeout: duration.minutes(1),
    poll_interval: 500,
    heartbeat_interval: 3000,
    allowed_heartbeat_misses: 3,
    executor_init_timeout: 1000,
    reserved_timeout: 300_000,
  )
}

pub fn handle_similarity_job(
  conn: pog.Connection,
  similarity_job: SimilarityJob,
) -> Result(String, SimilarityJobError) {
  use <- logs.log_errors()
  let item_id = similarity_job.item_id
  // One transaction so a drill-in never sees the item mid-recompute with its
  // own edges cleared, and caches that half-empty candidate list.
  use rows <- result.try(
    pog.transaction(conn, fn(conn) {
      use _ <- result.try(sql.delete_outgoing_edges(conn, item_id))
      use pog.Returned(rows, _) <- result.try(embeddings.compute_edges(
        conn,
        item_id,
      ))
      use _ <- result.try(sql.refresh_incoming_edges(conn, item_id))
      use _ <- result.try(sql.prune_incoming_edges(conn, item_id))
      Ok(rows)
    })
    |> result.map_error(fn(err) { string.inspect(err) |> map_string_to_error() }),
  )
  // The cached rerank list was ranked from the old edges.
  let _ = sql.invalidate_rerank_cache(conn, item_id)
  Ok(int.to_string(rows) <> " similarity edges inserted")
}

/// `version` is the embedded text's content version (see
/// embeddings.content_version): one recompute per version of the item, for
/// the same reason the embeddings queue keys on it.
pub fn enqueue(conn: pog.Connection, item_id: Int, version: String) {
  let job =
    m25.new_job(SimilarityJob(item_id:))
    |> m25.retry(3, option.Some(duration.seconds(30)))
    |> m25.unique_key("similarity:" <> int.to_string(item_id) <> ":" <> version)
  case m25.enqueue(conn, queue_spec(conn), job) {
    Ok(_) -> Ok(Nil)
    // A non-failed/non-cancelled job for this version already exists. That's
    // exactly the dedup we want — treat as success.
    Error(m25.JobRecordFetchQueryError(pog.ConstraintViolated(_, _, _))) ->
      Ok(Nil)
    Error(e) -> Error(e)
  }
}
