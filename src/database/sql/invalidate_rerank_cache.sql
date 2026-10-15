-- A rerank score reads both texts, so an edit stales the item's pairs on
-- either side.
DELETE FROM item_rerank_cache WHERE source_item_id = $1 OR target_item_id = $1;
