import gleam/float
import gleam/list
import gleam/string
import pog

pub fn insert_embedding(
  db: pog.Connection,
  item_id: Int,
  embedding: List(Float),
  model: String,
) {
  let embedding_str =
    "["
    <> {
      embedding
      |> list.map(float.to_string)
      |> string.join(",")
    }
    <> "]"

  "INSERT INTO item_embeddings (item_id, embedding, model) VALUES ($1, $2::text::vector, $3);"
  |> pog.query()
  |> pog.parameter(pog.int(item_id))
  |> pog.parameter(pog.text(embedding_str))
  |> pog.parameter(pog.text(model))
  |> pog.execute(db)
}
