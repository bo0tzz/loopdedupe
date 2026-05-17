SELECT target_item_id,
       relevance_score,
       i.title,
       i.state,
       i.state_reason
FROM item_rerank_cache c
         JOIN items i ON i.github_id = c.target_item_id
WHERE c.source_item_id = $1
ORDER BY c.relevance_score DESC
LIMIT 10;
