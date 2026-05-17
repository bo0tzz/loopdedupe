INSERT INTO pair_judgments (source_item_id, target_item_id, verdict)
VALUES (LEAST($1::bigint, $2::bigint), GREATEST($1::bigint, $2::bigint), $3)
ON CONFLICT (source_item_id, target_item_id, verdict) DO NOTHING;
