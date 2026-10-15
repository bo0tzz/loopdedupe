-- Stored rerank scores for /items/N, one per (source, target) pair. Scores
-- only depend on the two items' text, so they outlive any change to the
-- edges; which of them get shown is decided by suggest_duplicates.sql.
SELECT target_item_id, relevance_score
FROM item_rerank_cache
WHERE source_item_id = $1;
