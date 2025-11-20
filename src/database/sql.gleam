//// This module contains the code to run the sql queries defined in
//// `./src/database/sql`.
//// > 🐿️ This module was generated automatically using v4.6.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import pog

/// A row you get from running the `list_items` query
/// defined in `./src/database/sql/list_items.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListItemsRow {
  ListItemsRow(
    github_id: Int,
    number: Int,
    item_type: ItemType,
    title: String,
    body: String,
    state: GithubState,
    state_reason: Option(GithubStateReason),
    url: String,
  )
}

/// Runs the `list_items` query
/// defined in `./src/database/sql/list_items.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_items(
  db: pog.Connection,
) -> Result(pog.Returned(ListItemsRow), pog.QueryError) {
  let decoder = {
    use github_id <- decode.field(0, decode.int)
    use number <- decode.field(1, decode.int)
    use item_type <- decode.field(2, item_type_decoder())
    use title <- decode.field(3, decode.string)
    use body <- decode.field(4, decode.string)
    use state <- decode.field(5, github_state_decoder())
    use state_reason <- decode.field(
      6,
      decode.optional(github_state_reason_decoder()),
    )
    use url <- decode.field(7, decode.string)
    decode.success(ListItemsRow(
      github_id:,
      number:,
      item_type:,
      title:,
      body:,
      state:,
      state_reason:,
      url:,
    ))
  }

  "SELECT * FROM items;"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `upsert_item` query
/// defined in `./src/database/sql/upsert_item.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn upsert_item(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: ItemType,
  arg_4: String,
  arg_5: String,
  arg_6: GithubState,
  arg_7: GithubStateReason,
  arg_8: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "INSERT INTO items (github_id, number, item_type, title, body, state, state_reason, url)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (github_id) DO UPDATE
    SET number       = EXCLUDED.number,
        title        = EXCLUDED.title,
        body         = EXCLUDED.body,
        state        = EXCLUDED.state,
        state_reason = EXCLUDED.state_reason,
        url          = EXCLUDED.url;"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(item_type_encoder(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(github_state_encoder(arg_6))
  |> pog.parameter(github_state_reason_encoder(arg_7))
  |> pog.parameter(pog.text(arg_8))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

// --- Enums -------------------------------------------------------------------

/// Corresponds to the Postgres `github_state` enum.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GithubState {
  Closed
  Open
}

fn github_state_decoder() -> decode.Decoder(GithubState) {
  use github_state <- decode.then(decode.string)
  case github_state {
    "closed" -> decode.success(Closed)
    "open" -> decode.success(Open)
    _ -> decode.failure(Closed, "GithubState")
  }
}

fn github_state_encoder(github_state) -> pog.Value {
  case github_state {
    Closed -> "closed"
    Open -> "open"
  }
  |> pog.text
}/// Corresponds to the Postgres `github_state_reason` enum.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GithubStateReason {
  Duplicate
  NotPlanned
  Reopened
  Completed
}

fn github_state_reason_decoder() -> decode.Decoder(GithubStateReason) {
  use github_state_reason <- decode.then(decode.string)
  case github_state_reason {
    "duplicate" -> decode.success(Duplicate)
    "not_planned" -> decode.success(NotPlanned)
    "reopened" -> decode.success(Reopened)
    "completed" -> decode.success(Completed)
    _ -> decode.failure(Duplicate, "GithubStateReason")
  }
}

fn github_state_reason_encoder(github_state_reason) -> pog.Value {
  case github_state_reason {
    Duplicate -> "duplicate"
    NotPlanned -> "not_planned"
    Reopened -> "reopened"
    Completed -> "completed"
  }
  |> pog.text
}/// Corresponds to the Postgres `item_type` enum.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ItemType {
  Discussion
  Issue
}

fn item_type_decoder() -> decode.Decoder(ItemType) {
  use item_type <- decode.then(decode.string)
  case item_type {
    "discussion" -> decode.success(Discussion)
    "issue" -> decode.success(Issue)
    _ -> decode.failure(Discussion, "ItemType")
  }
}

fn item_type_encoder(item_type) -> pog.Value {
  case item_type {
    Discussion -> "discussion"
    Issue -> "issue"
  }
  |> pog.text
}
