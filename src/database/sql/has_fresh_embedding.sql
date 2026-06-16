-- True iff we already have a usable embedding for this item — same model
-- AND written after the item's last GitHub update, so the title/body that
-- went into the vector can't be stale. Used as the short-circuit at the
-- top of the embedding job so a re-backfill on an unchanged item doesn't
-- pay for a voyage API call only to fail the duplicate-key insert.
--
-- Slight over-firing: github_updated_at moves on any update including
-- labels/comments/etc that don't affect what we embed. The cost is one
-- redundant voyage call on those events; cheap compared to a content-
-- hash column + migration.
SELECT EXISTS (
    SELECT 1
    FROM item_embeddings e
             JOIN items i ON i.github_id = e.item_id
    WHERE e.item_id = $1
      AND e.model = $2
      AND e.created_at >= i.github_updated_at
) AS has_fresh_embedding;
