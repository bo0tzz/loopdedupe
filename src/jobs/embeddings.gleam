import database/embeddings
import database/item
import database/sql
import embeddings/voyage
import github/types as github
import gleam/bit_array
import gleam/crypto
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
    // Tier-1 Voyage has 2000 RPM headroom; even at ~500ms latency per
    // request, 8 concurrent workers stays well under (~960 RPM ceiling).
    // Bump if the queue isn't draining fast enough and there's no 429.
    max_concurrency: 8,
    input_to_json: embeddings_job_to_json,
    input_decoder: embeddings_job_decoder(),
    output_to_json: json.string,
    output_decoder: decode.string,
    error_to_json: embeddings_job_error_to_json,
    error_decoder: embeddings_job_error_decoder(),
    handler_function: handle_embeddings_job(conn, _),
    default_job_timeout: duration.minutes(1),
    poll_interval: 500,
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

  let model = voyage.Voyage4Large
  let model_name = voyage.embed_model_to_string(model)

  // Short-circuit if we already have an up-to-date embedding for this
  // item under the current model. Cheap DB check; avoids paying for a
  // voyage call on every re-backfill of unchanged items.
  use outcome <- result.try(
    case sql.has_fresh_embedding(conn, item.github_id, model_name) {
      Ok(pog.Returned(_, [sql.HasFreshEmbeddingRow(True)])) ->
        Ok("skipped — already embedded")
      _ -> embed_and_store(conn, item, model, model_name)
    },
  )
  // Queued from the skip path too: when an insert commits but reports a
  // timeout, the retry finds a fresh embedding and lands here without ever
  // having reached a similarity step. Deduped per content version, so for
  // an unchanged item this is a no-op.
  use _ <- result.try(
    similarity.enqueue(
      conn,
      item.github_id,
      content_version(item.title, item.body),
    )
    |> result.map_error(fn(err) { string.inspect(err) |> map_string_to_error() }),
  )
  Ok(outcome)
}

fn embed_and_store(
  conn: pog.Connection,
  item: github.Item,
  model: voyage.EmbedModel,
  model_name: String,
) -> Result(String, EmbeddingsJobError) {
  // Raw body input. Stripping the template was tuned for E5-Mistral-7B
  // (and we then carried it forward into voyage-3-large), where template
  // overlap collapsed unrelated issues into a narrow ~97%-similar cone.
  // voyage-4-large is robust enough that template noise barely moves the
  // noise floor (bench: random-pair p95 +0.005 stripped vs raw), and
  // raw input gives a small lift on true-pair separation, especially in
  // the hardest-quartile (sparse-canonical) cases. Same reasoning as the
  // rerank-side strip-removal (see database/item.gleam build_text).
  let embed_text = item.title <> "\n\n" <> item.body
  use #(embedding, _) <- result.try(
    voyage.embed(embed_text, model:)
    |> result.map_error(map_snag_to_error),
  )

  use pog.Returned(rows, _) <- result.try(
    embeddings.insert_embedding(conn, item.github_id, embedding, model_name)
    |> result.map_error(fn(err) { string.inspect(err) |> map_string_to_error() }),
  )

  Ok(int.to_string(rows) <> " embedding rows inserted")
}

/// Deduped per content version rather than per item: the unique index on
/// m25.job covers every non-failed, non-cancelled status, so a per-item key
/// meant an item's first successful embedding was its last, and edits were
/// never re-embedded. Keyed on the text, re-backfills and label or comment
/// events still no-op against the job that already ran for it, while an
/// actual edit gets a job of its own. Failed rows are excluded from the
/// index, so retries after a real failure still go through. An exact revert
/// to earlier text matches that text's finished job and keeps the newer
/// embedding until the next edit.
pub fn enqueue(
  conn: pog.Connection,
  item_id: Int,
  title: String,
  body: String,
) {
  let job =
    m25.new_job(EmbeddingsJob(item_id:))
    |> m25.retry(3, option.Some(duration.seconds(30)))
    |> m25.unique_key(
      "embeddings:"
      <> int.to_string(item_id)
      <> ":"
      <> content_version(title, body),
    )
  case m25.enqueue(conn, queue_spec(conn), job) {
    Ok(_) -> Ok(Nil)
    // unique_key collision: a non-finished or already-succeeded job exists
    // for this version of the item. That's exactly the desired outcome — no extra work
    // gets enqueued, and we don't want to roll back the surrounding
    // transaction over a successful no-op.
    Error(m25.JobRecordFetchQueryError(pog.ConstraintViolated(_, _, _))) ->
      Ok(Nil)
    Error(e) -> Error(e)
  }
}

/// Short fingerprint of the text an item is embedded from, for job dedupe
/// keys.
pub fn content_version(title: String, body: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(title <> "\n\n" <> body))
  |> bit_array.base16_encode
  |> string.slice(0, 16)
}
