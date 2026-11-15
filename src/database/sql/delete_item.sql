-- For an item that left the repo or the tracked category. Its embedding,
-- edges, rerank scores and judgments go with it (ON DELETE CASCADE). The
-- type is part of the key because issue ids and discussion ids are separate
-- sequences.
DELETE FROM items WHERE github_id = $1 AND item_type = $2;
