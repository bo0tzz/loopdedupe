import config
import gleam/bool
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import snag

pub type EmbedModel {
  Voyage3Large
  Voyage35
}

pub fn embed_model_to_string(model: EmbedModel) -> String {
  case model {
    Voyage3Large -> "voyage-3-large"
    Voyage35 -> "voyage-3.5"
  }
}

fn embed_model_decoder() -> decode.Decoder(EmbedModel) {
  use variant <- decode.then(decode.string)
  case variant {
    "voyage-3-large" -> decode.success(Voyage3Large)
    "voyage-3.5" -> decode.success(Voyage35)
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
  )
}

fn embed_request_to_json(embed_request: EmbedRequest) -> json.Json {
  let EmbedRequest(input:, model:, truncation:, output_dimension:) =
    embed_request
  json.object([
    #("input", json.array(input, json.string)),
    #("model", embed_model_to_json(model)),
    #("truncation", json.bool(truncation)),
    #("output_dimension", output_dimension_to_json(output_dimension)),
  ])
}

pub type Embedding {
  Embedding(index: Int, embedding: List(Float))
}

fn embedding_decoder() -> decode.Decoder(Embedding) {
  use object <- decode.field("object", decode.string)
  case object {
    "embedding" -> ""
    other -> echo "expected embedding but got " <> other
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
    "list" -> ""
    other -> echo "expected list but got " <> other
  }
  use model <- decode.field("model", embed_model_decoder())
  use data <- decode.field("data", decode.list(embedding_decoder()))
  decode.success(EmbedResponse(model:, data:))
}

fn expect_json_response(
  resp: response.Response(String),
  continue: fn(EmbedResponse) -> Result(a, snag.Snag),
) -> Result(a, snag.Snag) {
  use <- bool.guard(
    resp.status != 200,
    snag.error("expected 200 but got " <> int.to_string(resp.status)),
  )
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

pub fn embed(text: String) -> Result(#(List(Float), EmbedModel), snag.Snag) {
  let request_body =
    EmbedRequest(
      input: [text],
      model: Voyage3Large,
      truncation: False,
      output_dimension: Dim2048,
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
