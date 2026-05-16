SELECT e.source_item_id,
       e.target_item_id,
       e.similarity,
       src.number       AS source_number,
       src.title        AS source_title,
       src.item_type    AS source_item_type,
       src.state        AS source_state,
       src.state_reason AS source_state_reason,
       tgt.number       AS target_number,
       tgt.title        AS target_title,
       tgt.item_type    AS target_item_type,
       tgt.state        AS target_state,
       tgt.state_reason AS target_state_reason
FROM item_similarity_edges e
         JOIN items src ON src.github_id = e.source_item_id
         JOIN items tgt ON tgt.github_id = e.target_item_id
WHERE NOT EXISTS (SELECT 1
                  FROM item_duplicates d
                  WHERE (d.source_item_id = e.source_item_id AND d.target_item_id = e.target_item_id)
                     OR (d.source_item_id = e.target_item_id AND d.target_item_id = e.source_item_id))
  -- At least one side must be actionable (open); pairs of two already-closed
  -- items are dead weight in the review feed.
  AND (src.state = 'open' OR tgt.state = 'open')
  -- Items closed as duplicate are dupes of something else. Long-term these
  -- should be resolved through item_duplicates to their canonical and the
  -- canonical proposed instead — left as a TODO once duplicateOf capture
  -- and chain resolution land. For now we just hide them to keep the
  -- candidates feed signal-heavy.
  AND src.state_reason IS DISTINCT FROM 'duplicate'
  AND tgt.state_reason IS DISTINCT FROM 'duplicate'
ORDER BY e.similarity DESC
LIMIT $1;
