-- Resolves each side of every similarity edge through the duplicate_of chain
-- to its canonical, then filters to actionable pairs.
--
-- Chain walk: items.duplicate_of_number (per-repo number of the canonical) →
-- items.number (lookup). Dangling refs (PRs, cross-repo, typos) drop out of
-- the join naturally because the target won't be in items.
--
-- A pair is actionable when:
--   - the two canonicals differ (otherwise the edge just connects two
--     instances of the same logical issue),
--   - at least one canonical is open (the maintainer can do something),
--   - the pair isn't already recorded as a known dupe in item_duplicates.
--
-- We still drop pairs where either side is state_reason='duplicate' WITHOUT a
-- captured duplicate_of_number — those are dupes we know about but can't
-- resolve. They reappear once the canonical is captured.
WITH RECURSIVE chain(orig_id, current_id, depth) AS (
    SELECT github_id, github_id, 0
    FROM items

    UNION ALL

    SELECT c.orig_id, target.github_id, c.depth + 1
    FROM chain c
             JOIN items source ON source.github_id = c.current_id
             JOIN items target ON target.number = source.duplicate_of_number
    WHERE source.duplicate_of_number IS NOT NULL
      AND c.depth < 10
),
canonical AS (
    SELECT DISTINCT ON (orig_id) orig_id, current_id AS canonical_id
    FROM chain
    ORDER BY orig_id, depth DESC
)
SELECT e.similarity,
       src_can.canonical_id AS source_id,
       src_info.number      AS source_number,
       src_info.title       AS source_title,
       src_info.item_type   AS source_item_type,
       src_info.state       AS source_state,
       src_info.state_reason AS source_state_reason,
       e.source_item_id     AS source_original_id,
       tgt_can.canonical_id AS target_id,
       tgt_info.number      AS target_number,
       tgt_info.title       AS target_title,
       tgt_info.item_type   AS target_item_type,
       tgt_info.state       AS target_state,
       tgt_info.state_reason AS target_state_reason,
       e.target_item_id     AS target_original_id
FROM item_similarity_edges e
         JOIN canonical src_can ON src_can.orig_id = e.source_item_id
         JOIN canonical tgt_can ON tgt_can.orig_id = e.target_item_id
         JOIN items src_info ON src_info.github_id = src_can.canonical_id
         JOIN items tgt_info ON tgt_info.github_id = tgt_can.canonical_id
WHERE src_can.canonical_id != tgt_can.canonical_id
  AND (src_info.state = 'open' OR tgt_info.state = 'open')
  AND src_info.state_reason IS DISTINCT FROM 'duplicate'
  AND tgt_info.state_reason IS DISTINCT FROM 'duplicate'
  AND NOT EXISTS (SELECT 1
                  FROM item_duplicates d
                  WHERE (d.source_item_id = src_can.canonical_id AND d.target_item_id = tgt_can.canonical_id)
                     OR (d.source_item_id = tgt_can.canonical_id AND d.target_item_id = src_can.canonical_id))
ORDER BY e.similarity DESC
LIMIT $1;
