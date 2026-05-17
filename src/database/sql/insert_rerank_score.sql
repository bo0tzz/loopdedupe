INSERT INTO item_rerank_cache (source_item_id, target_item_id, relevance_score)
VALUES ($1, $2, $3)
ON CONFLICT (source_item_id, target_item_id)
DO UPDATE SET relevance_score = EXCLUDED.relevance_score,
              computed_at     = now();
