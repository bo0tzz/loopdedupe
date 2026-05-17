SELECT c.target_item_id,
       c.relevance_score,
       i.title,
       i.state,
       i.state_reason
FROM item_rerank_cache c
         JOIN items i ON i.github_id = c.target_item_id
WHERE c.source_item_id = $1
  AND NOT EXISTS (
    SELECT 1 FROM pair_judgments j
    WHERE j.source_item_id = LEAST($1::bigint, c.target_item_id)
      AND j.target_item_id = GREATEST($1::bigint, c.target_item_id)
      AND j.verdict = 'not_duplicate'
  )
ORDER BY c.relevance_score DESC
LIMIT 10;
