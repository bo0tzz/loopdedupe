-- Drop refreshed incoming edges that fell below compute_edges' threshold.
DELETE FROM item_similarity_edges WHERE target_item_id = $1 AND similarity < 0.55;
