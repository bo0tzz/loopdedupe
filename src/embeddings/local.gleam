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
  MistralF16
}

pub fn embed_model_to_string(model: EmbedModel) -> String {
  case model {
    MistralF16 ->
      "second-state_E5-Mistral-7B-Instruct-Embedding-GGUF_e5-mistral-7b-instruct-f16"
  }
}

fn embed_model_decoder() -> decode.Decoder(EmbedModel) {
  use variant <- decode.then(decode.string)
  case variant {
    "second-state_E5-Mistral-7B-Instruct-Embedding-GGUF_e5-mistral-7b-instruct-f16" ->
      decode.success(MistralF16)
    _ -> decode.failure(MistralF16, "EmbedModel")
  }
}

fn embed_model_to_json(embed_model: EmbedModel) -> json.Json {
  embed_model_to_string(embed_model) |> json.string()
}

type EmbedRequest {
  EmbedRequest(input: List(String), model: EmbedModel)
}

fn embed_request_to_json(embed_request: EmbedRequest) -> json.Json {
  let EmbedRequest(input:, model:) = embed_request
  json.object([
    #("input", json.array(input, json.string)),
    #("model", embed_model_to_json(model)),
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
  use <- bool.lazy_guard(resp.status != 200, fn() {
    let error = snag.new("expected 200 but got " <> int.to_string(resp.status))
    echo snag.line_print(error)
    echo resp.body
    Error(error)
  })
  let content_type = response.get_header(resp, "content-type")
  case content_type {
    // TODO: Handle ; separators
    Ok("application/json" <> _) -> {
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
    EmbedRequest(input: [text], model: MistralF16)
    |> embed_request_to_json
    |> json.to_string()

  use base_req <- result.try(
    request.to("http://192.168.1.13:8080/v1/embeddings")
    |> result.map_error(fn(_) { snag.new("failed to create base request") }),
  )
  let req =
    request.set_method(base_req, http.Post)
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
