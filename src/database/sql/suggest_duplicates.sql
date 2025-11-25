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
    i.state,
    i.state_reason
FROM all_edges ae
         JOIN items i ON i.github_id = ae.target_item_id
ORDER BY ae.similarity DESC
LIMIT 10;