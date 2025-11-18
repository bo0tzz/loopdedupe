//// This module contains the code to run the sql queries defined in
//// `./src/database/sql`.
//// > 🐿️ This module was generated automatically using v4.6.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/timestamp.{type Timestamp}
import pog

/// A row you get from running the `list_repositories` query
/// defined in `./src/database/sql/list_repositories.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListRepositoriesRow {
  ListRepositoriesRow(
    github_id: Int,
    owner: String,
    name: String,
    created_at: Timestamp,
  )
}

/// Runs the `list_repositories` query
/// defined in `./src/database/sql/list_repositories.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_repositories(
  db: pog.Connection,
) -> Result(pog.Returned(ListRepositoriesRow), pog.QueryError) {
  let decoder = {
    use github_id <- decode.field(0, decode.int)
    use owner <- decode.field(1, decode.string)
    use name <- decode.field(2, decode.string)
    use created_at <- decode.field(3, pog.timestamp_decoder())
    decode.success(ListRepositoriesRow(github_id:, owner:, name:, created_at:))
  }

  "SELECT github_id, owner, name, created_at
FROM repositories
ORDER BY created_at DESC;"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}
