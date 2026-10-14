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
  let embedding_str = format_vector(embedding)

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

/// Replace an item's outgoing kNN edges: upsert the current top-200 above the
/// edge threshold and drop the ones that fell out of it. One statement, so it's
/// atomic without a transaction, and the two halves touch disjoint rows.
///
/// Only rows the item owns (source_item_id = item) are written. Edges other
/// items hold towards it keep the similarity they computed against its previous
/// embedding until they're recomputed themselves; reads take the higher of the
/// two directions, so that only shows after a substantial rewrite. Refreshing
/// those here too made concurrent jobs lock each other's rows in opposite
/// order, which during the first startup reconcile meant 4× the job time,
/// transactions past their deadline, and a deadlock.
///
/// Written against pog rather than squirrel for the timeout: pgo's 5s default
/// covers waiting for a connection as well as running, and a burst on a slow
/// disk put the tail right at it.
pub fn compute_edges(
  db: pog.Connection,
  item_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  "WITH item_embedding AS (SELECT embedding FROM item_embeddings WHERE item_id = $1),
        similar_items AS (SELECT e.item_id,
                                 1 - (e.embedding <=> (SELECT embedding FROM item_embedding)) AS similarity
                          FROM item_embeddings e
                          WHERE e.item_id != $1
                          ORDER BY e.embedding <=> (SELECT embedding FROM item_embedding)
                          LIMIT 200),
        kept AS (SELECT item_id, similarity FROM similar_items WHERE similarity >= 0.55),
        dropped AS (DELETE FROM item_similarity_edges
                    WHERE source_item_id = $1
                      AND target_item_id NOT IN (SELECT item_id FROM kept))
   INSERT INTO item_similarity_edges (source_item_id, target_item_id, similarity, edge_type)
   SELECT $1, item_id, similarity, 'computed' FROM kept
   ON CONFLICT (source_item_id, target_item_id)
   DO UPDATE SET similarity = EXCLUDED.similarity, edge_type = EXCLUDED.edge_type"
  |> pog.query
  |> pog.parameter(pog.int(item_id))
  |> pog.timeout(30_000)
  |> pog.execute(db)
}

/// Serialise a vector to pgvector's text form so it can be passed as a
/// text parameter and cast on the server (`$1::text::vector`). Public so
/// the ad-hoc search endpoint can format query vectors the same way.
pub fn format_vector(embedding: List(Float)) -> String {
  "["
  <> {
    embedding
    |> list.map(float.to_string)
    |> string.join(",")
  }
  <> "]"
}
