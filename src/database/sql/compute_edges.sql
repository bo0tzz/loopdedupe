-- Recomputes the outgoing similarity edges for one item. Idempotent via
-- ON CONFLICT so this can re-run for an existing source.
--
-- kNN=200 (up from 50): at 50, ~20% of ground-truth dupe pairs were cut by
-- the limit despite scoring well above threshold. 200 keeps the storage
-- bounded but recovers the long tail.
--
-- Threshold=0.65 (down from 0.7): Voyage's noise floor median is ~0.62,
-- so 0.65 sits just above noise and catches the few real dupes scoring
-- between 0.6 and 0.7. False-positive pairs at this level get filtered
-- by the candidates-feed's "at least one open" / chain-resolution logic.
WITH item_embedding AS (SELECT embedding
                        FROM item_embeddings
                        WHERE item_id = $1),
     similar_items AS (SELECT e.item_id,
                              1 - (e.embedding <=> (SELECT embedding FROM item_embedding)) as similarity
                       FROM item_embeddings e
                       WHERE e.item_id != $1
                       ORDER BY e.embedding <=> (SELECT embedding FROM item_embedding)
                       LIMIT 200)
INSERT
INTO item_similarity_edges
    (source_item_id, target_item_id, similarity, edge_type)
SELECT $1,
       item_id,
       similarity,
       'computed'
FROM similar_items
WHERE similarity >= 0.65
ON CONFLICT (source_item_id, target_item_id)
DO UPDATE SET similarity = EXCLUDED.similarity, edge_type = EXCLUDED.edge_type
