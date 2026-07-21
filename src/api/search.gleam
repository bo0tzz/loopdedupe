//// Ad-hoc similarity search — take arbitrary input text, embed it,
//// cosine-top-N against item_embeddings, rerank, and return the strongest
//// candidates. Same pipeline as the item drill-in; the difference is the
//// input isn't an existing item but a caller-supplied string. Two
//// front-ends:
////
////   POST /api/search   → JSON in, JSON out (used by the Discord bot)
////   GET/POST /search   → HTML search page (used from the browser)
////
//// No rerank cache — free-form queries don't have a stable key worth
//// caching against. Every call pays for one voyage embed + one rerank
//// (~$0.001).

import api/dashboard
import database/embeddings
import database/item
import database/sql
import embeddings/voyage
import github/types as github
import gleam/dynamic/decode
import gleam/float
import gleam/http.{Get, Post}
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import logging
import pog
import snag
import types.{type Context}
import wisp.{type Request, type Response}

// --- HTTP handlers ----------------------------------------------------------

pub fn handle_api(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use body <- wisp.require_string_body(req)
  case json.parse(body, search_request_decoder()) {
    Error(_) ->
      wisp.bad_request(
        "expected JSON body with 'text' OR 'title'+'body' string fields",
      )
    Ok(query_text) ->
      case do_search(ctx, query_text) {
        Ok(hits) ->
          github.suggested_duplicates_to_json(github.SuggestedDuplicates(
            items: hits,
          ))
          |> json.to_string
          |> wisp.json_response(200)
        Error(reason) -> {
          logging.log(logging.Warning, "search failed: " <> reason)
          wisp.internal_server_error()
        }
      }
  }
}

pub fn handle_ui(req: Request, ctx: Context) -> Response {
  case req.method {
    Get -> render(option.None, option.None)
    Post -> {
      use body <- wisp.require_form(req)
      case list.key_find(body.values, "q") {
        Ok(q) if q != "" ->
          case do_search(ctx, q) {
            Ok(hits) -> render(option.Some(q), option.Some(Ok(hits)))
            Error(e) -> render(option.Some(q), option.Some(Error(e)))
          }
        _ -> render(option.None, option.None)
      }
    }
    _ -> wisp.method_not_allowed(allowed: [Get, Post])
  }
}

// --- Core pipeline ----------------------------------------------------------

fn do_search(
  ctx: Context,
  query_text: String,
) -> Result(List(github.SuggestedDuplicate), String) {
  use #(embedding, _) <- result.try(
    voyage.embed(query_text, model: voyage.Voyage4Large)
    |> result.map_error(fn(e) { "embed: " <> snag.line_print(e) }),
  )
  use pog.Returned(_, rows) <- result.try(
    sql.search_by_vector(ctx.db, embeddings.format_vector(embedding))
    |> result.map_error(fn(e) { "cosine: " <> string.inspect(e) }),
  )
  case rows {
    [] -> Ok([])
    _ -> Ok(rerank_and_take(query_text, rows, 10))
  }
}

/// Rerank the chain-resolved cosine candidates against the query text.
/// Falls back to cosine ordering if the rerank API call fails so the
/// caller still gets a useful response.
fn rerank_and_take(
  query_text: String,
  cosine: List(sql.SearchByVectorRow),
  take: Int,
) -> List(github.SuggestedDuplicate) {
  let docs = list.map(cosine, fn(r) { r.title <> "\n\n" <> r.body })
  case voyage.rerank(query_text, docs) {
    Ok(scored) -> {
      let indexed = list.index_map(cosine, fn(row, i) { #(i, row) })
      scored
      |> list.filter_map(fn(s) {
        case list.key_find(indexed, s.index) {
          Ok(row) -> Ok(to_suggested(row, s.score))
          Error(_) -> Error(Nil)
        }
      })
      |> list.sort(fn(a, b) { float.compare(b.similarity, a.similarity) })
      |> list.take(take)
    }
    Error(e) -> {
      logging.log(
        logging.Warning,
        "search rerank fell back to cosine: " <> snag.line_print(e),
      )
      cosine
      |> list.take(take)
      |> list.map(fn(row) { to_suggested(row, row.similarity) })
    }
  }
}

fn to_suggested(
  row: sql.SearchByVectorRow,
  score: Float,
) -> github.SuggestedDuplicate {
  github.SuggestedDuplicate(
    similarity: score,
    number: row.number,
    item_type: item.sql_into_item_type(row.item_type),
    title: row.title,
    state: item.sql_into_state(row.state),
    state_reason: item.sql_into_state_reason(row.state_reason),
  )
}

// Freeform 'text' OR structured 'title' (+ optional 'body' concatenated
// the same way we embed items). Failing to provide either is a decode
// failure so we 400 the request.
fn search_request_decoder() -> decode.Decoder(String) {
  use text <- decode.optional_field("text", "", decode.string)
  use title <- decode.optional_field("title", "", decode.string)
  use body <- decode.optional_field("body", "", decode.string)
  case text, title, body {
    "", "", "" -> decode.failure("", "text or title required")
    _, "", "" -> decode.success(text)
    _, t, "" -> decode.success(t)
    _, t, b -> decode.success(t <> "\n\n" <> b)
  }
}

// --- UI --------------------------------------------------------------------

fn render(
  q: option.Option(String),
  outcome: option.Option(Result(List(github.SuggestedDuplicate), String)),
) -> Response {
  let value = case q {
    option.Some(s) -> dashboard.escape(s)
    option.None -> ""
  }
  let results = case outcome {
    option.None -> ""
    option.Some(Error(reason)) ->
      "<p class=\"muted\">search failed: " <> dashboard.escape(reason) <> "</p>"
    option.Some(Ok([])) -> "<p class=\"muted\">no candidates.</p>"
    option.Some(Ok(items)) ->
      "<h3>Top candidates</h3>" <> dashboard.candidates_table(items)
  }
  wisp.html_response(
    dashboard.page("loopdedupe · search", [
      "<h2>Search</h2>",
      "<p class=\"muted\">Paste a title, body, or freeform description and see the strongest matches in the corpus. Same pipeline as the per-item drill-in — chain-resolved to canonicals, dead-ends filtered.</p>",
      "<form method=\"post\" action=\"/search\" class=\"search-form\">",
      "<textarea name=\"q\" rows=\"6\" placeholder=\"describe the issue…\">"
        <> value
        <> "</textarea>",
      "<button type=\"submit\">search</button>",
      "</form>",
      results,
    ]),
    200,
  )
}
