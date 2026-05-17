import database/item
import github/types as github
import gleam/int
import gleam/json
import types.{type Context}
import wisp.{type Response}

pub fn list(ctx: Context) -> Response {
  case item.list(ctx.db) {
    Ok(list) -> {
      json.array(list, of: github.item_to_json)
      |> json.to_string()
      |> wisp.json_response(200)
    }
    Error(_) -> wisp.internal_server_error()
  }
}

pub fn get(ctx: Context, id: String) -> Response {
  let assert Ok(item_id) = int.parse(id)
  case item.select(ctx.db, item_id) {
    Error(_) -> wisp.internal_server_error()
    Ok(item) -> {
      github.item_to_json(item) |> json.to_string() |> wisp.json_response(200)
    }
  }
}

pub fn get_similar(ctx: Context, id: String) -> Response {
  let assert Ok(item_id) = int.parse(id)
  case item.suggest_duplicates(ctx.db, item_id) {
    Ok(sugg) ->
      github.suggested_duplicates_to_json(sugg)
      |> json.to_string()
      |> wisp.json_response(200)
    Error(_) -> wisp.internal_server_error()
  }
}
