import api/types
import database/item
import github/types as github
import gleam/int
import gleam/json
import wisp.{type Request, type Response}

pub fn list(ctx: types.Context) -> Response {
  case item.list(ctx.db) {
    Ok(list) -> {
      json.array(list, of: github.issue_to_json)
      |> json.to_string()
      |> wisp.json_response(200)
    }
    Error(_) -> wisp.internal_server_error()
  }
}

pub fn get(ctx: types.Context, id: String) -> Response {
  let assert Ok(item_id) = int.parse(id)
  case item.select(ctx.db, item_id) {
    Error(_) -> wisp.internal_server_error()
    Ok(item) -> {
      github.issue_to_json(item) |> json.to_string() |> wisp.json_response(200)
    }
  }
}

pub fn get_similar(ctx: types.Context, id: String) -> Response {
  let assert Ok(item_id) = int.parse(id)
  case item.suggest_duplicates(ctx.db, item_id) {
    Ok(sugg) ->
      github.suggested_duplicates_to_json(sugg)
      |> json.to_string()
      |> wisp.json_response(200)
    Error(_) -> wisp.internal_server_error()
  }
}
