WITH all_edges AS (
    SELECT target_item_id, similarity
    FROM item_similarity_edges
    WHERE source_item_id = $1
      AND similarity >= $2

    UNION

    SELECT source_item_id, similarity
    FROM item_similarity_edges
    WHERE target_item_id = $1
      AND similarity >= $2
)
SELECT
    ae.target_item_id,
    ae.similarity,
    i.title,
    i.body,
    i.state,
    i.state_reason
FROM all_edges ae
         JOIN items i ON i.github_id = ae.target_item_id
WHERE NOT EXISTS (
    SELECT 1 FROM pair_judgments j
    WHERE j.source_item_id = LEAST($1::bigint, ae.target_item_id)
      AND j.target_item_id = GREATEST($1::bigint, ae.target_item_id)
      AND j.verdict = 'not_duplicate'
)
ORDER BY ae.similarity DESC
LIMIT 50;
