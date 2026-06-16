import database/sql
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

  // ON CONFLICT DO UPDATE so a content-change re-embed (title/body
  // edited on GitHub) overwrites the stale vector. The has_fresh_embedding
  // check upstream short-circuits the voyage call when the item hasn't
  // changed, so we only reach this UPDATE branch when re-embedding is
  // actually warranted.
  "INSERT INTO item_embeddings (item_id, embedding, model)
   VALUES ($1, $2::text::vector, $3)
   ON CONFLICT (item_id) DO UPDATE
       SET embedding  = EXCLUDED.embedding,
           model      = EXCLUDED.model,
           created_at = NOW();"
  |> pog.query()
  |> pog.parameter(pog.int(item_id))
  |> pog.parameter(pog.text(embedding_str))
  |> pog.parameter(pog.text(model))
  |> pog.execute(db)
}

pub fn compute_edges(db: pog.Connection, item_id: Int) {
  sql.compute_edges(db, item_id)
}
