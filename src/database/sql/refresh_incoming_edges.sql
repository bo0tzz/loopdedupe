-- Edges other items computed towards this one carry a similarity taken
-- against its previous embedding; recompute them against the current one.
UPDATE item_similarity_edges s
SET similarity = 1 - (src.embedding <=> tgt.embedding)
FROM item_embeddings src,
     item_embeddings tgt
WHERE s.target_item_id = $1
  AND src.item_id = s.source_item_id
  AND tgt.item_id = $1;
