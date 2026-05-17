DELETE FROM pair_judgments
WHERE source_item_id = LEAST($1::bigint, $2::bigint)
  AND target_item_id = GREATEST($1::bigint, $2::bigint)
  AND verdict = $3;
