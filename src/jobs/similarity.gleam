import database/embeddings
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/result
import gleam/string
import gleam/time/duration
import m25
import pog
import snag

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
    max_concurrency: 4,
    input_to_json: similarity_job_to_json,
    input_decoder: similarity_job_decoder(),
    output_to_json: json.string,
    output_decoder: decode.string,
    error_to_json: similarity_job_error_to_json,
    error_decoder: similarity_job_error_decoder(),
    handler_function: handle_similarity_job(conn, _),
    default_job_timeout: duration.minutes(20),
    poll_interval: 5000,
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
  use pog.Returned(rows, _) <- result.try(
    embeddings.compute_edges(conn, similarity_job.item_id)
    |> result.map_error(fn(err) { string.inspect(err) |> map_string_to_error() }),
  )
  Ok(int.to_string(rows) <> " similarity edges inserted")
}

pub fn enqueue(conn: pog.Connection, item_id: Int) {
  let job = m25.new_job(SimilarityJob(item_id:))
  m25.enqueue(conn, queue_spec(conn), job)
}
