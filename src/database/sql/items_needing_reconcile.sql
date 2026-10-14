-- Items the embed → similarity pipeline left behind, for the startup
-- reconcile pass:
--   - no embedding: every attempt failed (Voyage timeouts, oversized input)
--     and nothing re-queued it
--   - embedding older than the item's last update
--   - embedding but not a single edge in either direction: an embed attempt
--     whose insert committed but reported a timeout, so the retry skipped
--     straight past the similarity step
-- Re-queueing is deduped by content-versioned unique keys, so items that are
-- legitimately edgeless (nothing within the edge threshold) or only got a
-- comment or label since their embedding cost one no-op enqueue per startup.
SELECT i.github_id,
       i.title,
       i.body,
       e.item_id IS NOT NULL AND e.created_at >= i.github_updated_at AS has_fresh_embedding
FROM items i
         LEFT JOIN item_embeddings e ON e.item_id = i.github_id
WHERE e.item_id IS NULL
   OR e.created_at < i.github_updated_at
   OR (NOT EXISTS (SELECT 1 FROM item_similarity_edges s WHERE s.source_item_id = i.github_id)
       AND NOT EXISTS (SELECT 1 FROM item_similarity_edges s WHERE s.target_item_id = i.github_id));
