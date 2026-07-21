-- Read rerank scores for /items/N, resolving each cached candidate through
-- the duplicate_of chain to its canonical. Mirrors the chain-walk used by
-- dashboard_top_pairs but applied per-source. Dead-ends (chains landing on
-- a state_reason='duplicate' item with no further canonical) and the
-- source-itself self-loop are filtered out, and multiple chain-members
-- collapsing on the same canonical dedupe to one row keeping the highest
-- rerank score.
WITH cached_targets AS (
    SELECT target_item_id, relevance_score
    FROM item_rerank_cache
    WHERE source_item_id = $1
),
chain_seed AS (
    SELECT DISTINCT target_item_id AS orig_id FROM cached_targets
),
chain AS (
    WITH RECURSIVE walk(orig_id, current_id, depth) AS (
        SELECT orig_id, orig_id, 0 FROM chain_seed
        UNION ALL
        SELECT w.orig_id, target.github_id, w.depth + 1
        FROM walk w
                 JOIN items source ON source.github_id = w.current_id
                 JOIN items target ON target.number = source.duplicate_of_number
        WHERE source.duplicate_of_number IS NOT NULL AND w.depth < 10
    )
    SELECT * FROM walk
),
canonical AS (
    SELECT DISTINCT ON (orig_id) orig_id, current_id AS canonical_id
    FROM chain ORDER BY orig_id, depth DESC
),
resolved AS (
    SELECT c.canonical_id,
           ct.relevance_score,
           canon.number,
           canon.item_type,
           canon.title, canon.state, canon.state_reason
    FROM cached_targets ct
             JOIN canonical c ON c.orig_id = ct.target_item_id
             JOIN items canon ON canon.github_id = c.canonical_id
    WHERE c.canonical_id != $1
      AND canon.state_reason IS DISTINCT FROM 'duplicate'
      AND NOT EXISTS (
        SELECT 1 FROM pair_judgments j
        WHERE j.source_item_id = LEAST($1::bigint, c.canonical_id)
          AND j.target_item_id = GREATEST($1::bigint, c.canonical_id)
          AND j.verdict = 'not_duplicate'
      )
),
deduped AS (
    SELECT DISTINCT ON (canonical_id)
           canonical_id, relevance_score, number, item_type, title, state, state_reason
    FROM resolved
    ORDER BY canonical_id, relevance_score DESC
)
SELECT canonical_id AS target_item_id,
       relevance_score,
       number,
       item_type,
       title,
       state,
       state_reason
FROM deduped
ORDER BY relevance_score DESC
LIMIT 10;
