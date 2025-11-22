import pog
import gleam/dynamic/decode
import gleam/json
import gleam/time/duration
import m25

pub opaque type EmbeddingsJob {
  EmbeddingsJob(item_id: Int)
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

pub fn queue_spec() {
  m25.Queue(
    name: "embeddings",
    max_concurrency: 4,
    input_to_json: embeddings_job_to_json,
    input_decoder: embeddings_job_decoder(),
    output_to_json: json.string,
    output_decoder: decode.string,
    error_to_json: json.string,
    error_decoder: decode.string,
    handler_function: handle_embeddings_job,
    default_job_timeout: duration.minutes(20),
    poll_interval: 5000,
    heartbeat_interval: 3000,
    allowed_heartbeat_misses: 3,
    executor_init_timeout: 1000,
    reserved_timeout: 300_000,
  )
}

fn handle_embeddings_job(
  embeddings_job: EmbeddingsJob,
) -> Result(String, String) {
  todo("get item from db")
  todo("query api for embedding")
  todo("insert embedding row")
}

pub fn enqueue(conn: pog.Connection, item_id: Int) {
  let job = m25.new_job(EmbeddingsJob(item_id:))
  m25.enqueue(conn, queue_spec(), job)
}
