import config
import gleam/bool
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import logging
import snag

pub type EmbedModel {
  Voyage3Large
  Voyage35
  Voyage4Large
}

pub fn embed_model_to_string(model: EmbedModel) -> String {
  case model {
    Voyage3Large -> "voyage-3-large"
    Voyage35 -> "voyage-3.5"
    Voyage4Large -> "voyage-4-large"
  }
}

fn embed_model_decoder() -> decode.Decoder(EmbedModel) {
  use variant <- decode.then(decode.string)
  case variant {
    "voyage-3-large" -> decode.success(Voyage3Large)
    "voyage-3.5" -> decode.success(Voyage35)
    "voyage-4-large" -> decode.success(Voyage4Large)
    _ -> decode.failure(Voyage3Large, "EmbedModel")
  }
}

fn embed_model_to_json(embed_model: EmbedModel) -> json.Json {
  embed_model_to_string(embed_model) |> json.string()
}

type OutputDimension {
  Dim2048
  Dim1024
}

fn output_dimension_to_json(output_dimension: OutputDimension) -> json.Json {
  case output_dimension {
    Dim2048 -> json.int(2048)
    Dim1024 -> json.int(1024)
  }
}

type EmbedRequest {
  EmbedRequest(
    input: List(String),
    model: EmbedModel,
    truncation: Bool,
    output_dimension: OutputDimension,
    // Per Voyage docs, embedding quality improves on retrieval tasks when
    // we tell the model what role the input plays. For symmetric dedup
    // both sides are documents, so we pin to "document" — null/generic
    // would give the model less signal.
    input_type: String,
  )
}

fn embed_request_to_json(embed_request: EmbedRequest) -> json.Json {
  let EmbedRequest(input:, model:, truncation:, output_dimension:, input_type:) =
    embed_request
  json.object([
    #("input", json.array(input, json.string)),
    #("model", embed_model_to_json(model)),
    #("truncation", json.bool(truncation)),
    #("output_dimension", output_dimension_to_json(output_dimension)),
    #("input_type", json.string(input_type)),
  ])
}

pub type Embedding {
  Embedding(index: Int, embedding: List(Float))
}

fn embedding_decoder() -> decode.Decoder(Embedding) {
  use object <- decode.field("object", decode.string)
  case object {
    "embedding" -> Nil
    other ->
      logging.log(logging.Warning, "expected embedding but got " <> other)
  }
  use index <- decode.field("index", decode.int)
  use embedding <- decode.field("embedding", decode.list(decode.float))
  decode.success(Embedding(index:, embedding:))
}

type EmbedResponse {
  EmbedResponse(model: EmbedModel, data: List(Embedding))
}

fn embed_response_decoder() -> decode.Decoder(EmbedResponse) {
  use object <- decode.field("object", decode.string)
  case object {
    "list" -> Nil
    other -> logging.log(logging.Warning, "expected list but got " <> other)
  }
  use model <- decode.field("model", embed_model_decoder())
  use data <- decode.field("data", decode.list(embedding_decoder()))
  decode.success(EmbedResponse(model:, data:))
}

fn expect_json_response(
  resp: response.Response(String),
  continue: fn(EmbedResponse) -> Result(a, snag.Snag),
) -> Result(a, snag.Snag) {
  use <- bool.lazy_guard(resp.status != 200, fn() {
    let error =
      snag.new(
        "expected 200 but got "
        <> int.to_string(resp.status)
        <> ": "
        <> resp.body,
      )
    logging.log(logging.Warning, snag.line_print(error))
    Error(error)
  })
  let content_type = response.get_header(resp, "content-type")
  case content_type {
    Ok("application/json") -> {
      case json.parse(resp.body, embed_response_decoder()) {
        Ok(embeddings) -> continue(embeddings)
        Error(err) -> snag.error(string.inspect(err))
      }
    }
    Ok(other) -> snag.error("wrong content type: " <> other)
    Error(e) -> snag.error(string.inspect(e))
  }
}

// --- rerank ----------------------------------------------------------------
//
// Two-stage retrieval pattern: get top-N candidates by embedding cosine,
// then rerank with the actual texts via a heavier model. Cosine on
// voyage-3-large is fast and ~good; rerank-2.5 reads the full content and
// rescores for semantic relevance, fixing the cases where two items have
// similar embedding vectors but represent different concerns.

pub type RerankResult {
  RerankResult(index: Int, score: Float)
}

fn rerank_request_body(query: String, documents: List(String)) -> String {
  json.object([
    #("query", json.string(query)),
    #("documents", json.array(documents, json.string)),
    #("model", json.string("rerank-2.5")),
    // Only covers the per-pair context limits (8k query, 32k query+doc).
    // The per-request token cap is on us; see rerank_batches.
    #("truncation", json.bool(True)),
  ])
  |> json.to_string()
}

fn rerank_response_decoder() -> decode.Decoder(List(RerankResult)) {
  let result_decoder = {
    use index <- decode.field("index", decode.int)
    use score <- decode.field("relevance_score", decode.float)
    decode.success(RerankResult(index:, score:))
  }
  use data <- decode.field("data", decode.list(result_decoder))
  decode.success(data)
}

// Voyage counts a rerank request as query_tokens × documents +
// Σ document_tokens and 400s the whole call past 600k. We have no
// tokenizer, so cost is estimated at 2 bytes/token: this corpus measures
// ~2.9 chars/token (markdown templates, pasted logs), and multibyte scripts
// spend more bytes per token than ASCII does, so the estimate errs high.
const rerank_batch_byte_budget = 1_000_000

/// The query is clamped too, not just documents: it's billed once per
/// document, so an unclamped 10k-char issue body against 200 candidates
/// alone blows the cap. One cut for both sides also means an item reads the
/// same to the model whether it's the query or a candidate.
fn clamp_rerank_text(text: String) -> String {
  string.slice(text, 0, 4000)
}

/// Rescores documents against the query, best first. Indices refer to
/// positions in `documents`.
pub fn rerank(
  query: String,
  documents: List(String),
) -> Result(List(RerankResult), snag.Snag) {
  let query = clamp_rerank_text(query)
  let documents = list.map(documents, clamp_rerank_text)
  // Each (query, document) pair is scored independently, so splitting a
  // call into batches doesn't change the scores, only the request count.
  use scored <- result.map(
    rerank_batches(query, documents, rerank_batch_byte_budget)
    |> list.try_map(fn(batch) {
      let #(offset, batch_documents) = batch
      use scored <- result.map(rerank_request(query, batch_documents))
      list.map(scored, fn(r) { RerankResult(..r, index: r.index + offset) })
    }),
  )
  list.flatten(scored)
  |> list.sort(fn(a, b) { float.compare(b.score, a.score) })
}

/// Splits documents into batches whose estimated cost stays within
/// `byte_budget`, each tagged with the index of its first document. A
/// document that alone exceeds the budget still gets a batch of its own.
pub fn rerank_batches(
  query: String,
  documents: List(String),
  byte_budget: Int,
) -> List(#(Int, List(String))) {
  let query_bytes = string.byte_size(query)
  let #(batches, current, start, _) =
    list.index_fold(documents, #([], [], 0, 0), fn(acc, document, i) {
      let #(batches, current, start, used) = acc
      let cost = query_bytes + string.byte_size(document)
      case current {
        [_, ..] if used + cost > byte_budget -> #(
          [#(start, list.reverse(current)), ..batches],
          [document],
          i,
          cost,
        )
        _ -> #(batches, [document, ..current], start, used + cost)
      }
    })
  case current {
    [] -> list.reverse(batches)
    _ -> list.reverse([#(start, list.reverse(current)), ..batches])
  }
}

fn rerank_request(
  query: String,
  documents: List(String),
) -> Result(List(RerankResult), snag.Snag) {
  let request_body = rerank_request_body(query, documents)
  let key = config.get_env(config.VoyageApiKey)

  use base_req <- result.try(
    request.to("https://api.voyageai.com/v1/rerank")
    |> result.map_error(fn(_) { snag.new("failed to create rerank request") }),
  )
  let req =
    request.set_method(base_req, http.Post)
    |> request.set_header("authorization", "bearer " <> key)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(request_body)

  use resp <- result.try(httpc.send(req) |> snag.map_error(string.inspect))
  use <- bool.lazy_guard(resp.status != 200, fn() {
    snag.error(
      "rerank: expected 200 but got "
      <> int.to_string(resp.status)
      <> ": "
      <> resp.body,
    )
  })
  json.parse(resp.body, rerank_response_decoder())
  |> result.map_error(fn(e) {
    snag.new("rerank: decode failed: " <> string.inspect(e))
  })
}

pub fn embed(
  text: String,
  model model: EmbedModel,
) -> Result(#(List(Float), EmbedModel), snag.Snag) {
  let request_body =
    EmbedRequest(
      input: [text],
      model: model,
      // Without it, anything past the model's context 400s on every attempt
      // and the item never gets an embedding at all.
      truncation: True,
      output_dimension: Dim2048,
      input_type: "document",
    )
    |> embed_request_to_json
    |> json.to_string()

  let key = config.get_env(config.VoyageApiKey)
  use base_req <- result.try(
    request.to("https://api.voyageai.com/v1/embeddings")
    |> result.map_error(fn(_) { snag.new("failed to create base request") }),
  )
  let req =
    request.set_method(base_req, http.Post)
    |> request.set_header("authorization", "bearer " <> key)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(request_body)

  use resp <- result.try(httpc.send(req) |> snag.map_error(string.inspect))
  use embeddings <- expect_json_response(resp)

  use embedding <- result.try(
    list.first(embeddings.data)
    |> snag.replace_error("no embedding in response"),
  )
  Ok(#(embedding.embedding, embeddings.model))
}
