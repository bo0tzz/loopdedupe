-- Resolves each side of every similarity edge through the duplicate_of chain
-- to its canonical, then filters and deduplicates to actionable pairs.
--
-- Performance strategy: we don't run the full pipeline over all ~2M edges.
-- Instead we pre-filter to the top-K most-similar edges (the universe the
-- dashboard could actually surface), then resolve / filter / dedup only
-- those. The over-fetch factor of ~20x keeps a buffer for pairs that
-- collapse via canonical resolution or get filtered out.
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
-- We still drop pairs where either side is state_reason='duplicate' WITHOUT
-- a captured duplicate_of_number — those are dupes we know about but can't
-- resolve. They reappear once the canonical is captured.
WITH top_edges AS (
    -- Over-fetch generously: with both directions stored per pair, chain
    -- resolution collapse, and the state-based filters, the survival rate
    -- can be ~2-5%. 10k edges at >=0.80 gives enough buffer to comfortably
    -- yield the top-50 the dashboard wants.
    SELECT source_item_id, target_item_id, similarity
    FROM item_similarity_edges
    WHERE similarity >= 0.80
    ORDER BY similarity DESC
    LIMIT 10000
),
relevant_ids AS (
    SELECT source_item_id AS id FROM top_edges
    UNION
    SELECT target_item_id FROM top_edges
),
chain_seed AS (
    SELECT DISTINCT id AS orig_id
    FROM relevant_ids
),
chain AS (
    WITH RECURSIVE walk(orig_id, current_id, depth) AS (
        SELECT orig_id, orig_id, 0 FROM chain_seed
        UNION ALL
        SELECT w.orig_id, target.github_id, w.depth + 1
        FROM walk w
                 JOIN items source ON source.github_id = w.current_id
                 JOIN items target ON target.number = source.duplicate_of_number
        WHERE source.duplicate_of_number IS NOT NULL
          AND w.depth < 10
    )
    SELECT * FROM walk
),
canonical AS (
    SELECT DISTINCT ON (orig_id) orig_id, current_id AS canonical_id
    FROM chain
    ORDER BY orig_id, depth DESC
),
resolved AS (
    SELECT e.similarity,
           src_can.canonical_id                                                AS source_id,
           src_info.number                                                     AS source_number,
           src_info.title                                                      AS source_title,
           src_info.item_type                                                  AS source_item_type,
           src_info.state                                                      AS source_state,
           src_info.state_reason                                               AS source_state_reason,
           src_info.author_login                                               AS source_author,
           e.source_item_id                                                    AS source_original_id,
           tgt_can.canonical_id                                                AS target_id,
           tgt_info.number                                                     AS target_number,
           tgt_info.title                                                      AS target_title,
           tgt_info.item_type                                                  AS target_item_type,
           tgt_info.state                                                      AS target_state,
           tgt_info.state_reason                                               AS target_state_reason,
           tgt_info.author_login                                               AS target_author,
           e.target_item_id                                                    AS target_original_id,
           LEAST(src_can.canonical_id, tgt_can.canonical_id)                   AS pair_lo,
           GREATEST(src_can.canonical_id, tgt_can.canonical_id)                AS pair_hi
    FROM top_edges e
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
      -- Maintainer-dismissed pairs stay dismissed. Stored canonical-ordered
      -- so we don't need an OR here — LEAST/GREATEST matches both directions.
      AND NOT EXISTS (SELECT 1
                      FROM pair_judgments j
                      WHERE j.source_item_id = LEAST(src_can.canonical_id, tgt_can.canonical_id)
                        AND j.target_item_id = GREATEST(src_can.canonical_id, tgt_can.canonical_id)
                        AND j.verdict = 'not_duplicate')
),
deduped AS (
    SELECT DISTINCT ON (pair_lo, pair_hi) *
    FROM resolved
    ORDER BY pair_lo, pair_hi, similarity DESC
)
SELECT similarity,
       source_id, source_number, source_title, source_item_type,
       source_state, source_state_reason, source_author, source_original_id,
       target_id, target_number, target_title, target_item_type,
       target_state, target_state_reason, target_author, target_original_id
FROM deduped
ORDER BY similarity DESC
LIMIT $1;
