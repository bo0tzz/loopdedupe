-- Cosine candidates for the cache-miss path on /items/N: top edges above
-- $2, with each candidate resolved through the duplicate_of chain to its
-- canonical, dead-ends filtered, and chain-collapse deduped (keep best
-- cosine across all chain members landing on the same canonical).
--
-- We resolve at the cosine stage (before rerank) so that:
--   - rerank scores are computed against the canonical's body, not an
--     intermediate's body, and stored against the canonical id
--   - dead-end and judged pairs are dropped before paying the rerank cost
WITH all_edges AS (
    SELECT target_item_id AS orig_id, similarity
    FROM item_similarity_edges
    WHERE source_item_id = $1 AND similarity >= $2

    UNION

    SELECT source_item_id AS orig_id, similarity
    FROM item_similarity_edges
    WHERE target_item_id = $1 AND similarity >= $2
),
chain_seed AS (
    SELECT DISTINCT orig_id FROM all_edges
),
chain AS (
    WITH RECURSIVE walk(orig_id, current_id, depth) AS (
        SELECT orig_id, orig_id, 0 FROM chain_seed
        UNION ALL
        SELECT w.orig_id, target.github_id, w.depth + 1
        FROM walk w
                 JOIN items source ON source.github_id = w.current_id
                 JOIN items target ON target.number = source.duplicate_of_number
                                  AND target.item_type = source.item_type
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
           ae.similarity,
           canon.title, canon.body, canon.state, canon.state_reason
    FROM all_edges ae
             JOIN canonical c ON c.orig_id = ae.orig_id
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
           canonical_id, similarity, title, body, state, state_reason
    FROM resolved
    ORDER BY canonical_id, similarity DESC
)
-- Top-200 cosine candidates feed into rerank. Bench (N=81 captured-canon
-- ground truth): at top-50 the canonical falls outside the candidate set
-- in ~25% of cases (and unconditional rank-1 rate is 35%); at top-200 we
-- catch the canonical 92% of the time and unconditional rank-1 climbs
-- to ~45%. Rerank is one HTTP call regardless of K; only the payload
-- grows.
SELECT canonical_id AS target_item_id,
       similarity,
       title,
       body,
       state,
       state_reason
FROM deduped
ORDER BY similarity DESC
LIMIT 200;
