SELECT EXISTS (
    SELECT 1 FROM item_rerank_cache WHERE source_item_id = $1
) AS cached;
