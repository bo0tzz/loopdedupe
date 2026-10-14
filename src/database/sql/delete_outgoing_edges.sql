-- Clear an item's own kNN edges before recomputing them, so a re-embedded
-- item doesn't keep neighbours that only matched its old text.
DELETE FROM item_similarity_edges WHERE source_item_id = $1;
