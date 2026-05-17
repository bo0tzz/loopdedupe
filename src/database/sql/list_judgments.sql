SELECT j.source_item_id,
       j.target_item_id,
       j.verdict,
       j.judged_at,
       s.number       AS source_number,
       s.title        AS source_title,
       s.item_type    AS source_item_type,
       s.state        AS source_state,
       s.state_reason AS source_state_reason,
       s.author_login AS source_author,
       t.number       AS target_number,
       t.title        AS target_title,
       t.item_type    AS target_item_type,
       t.state        AS target_state,
       t.state_reason AS target_state_reason,
       t.author_login AS target_author
FROM pair_judgments j
         JOIN items s ON s.github_id = j.source_item_id
         JOIN items t ON t.github_id = j.target_item_id
ORDER BY j.judged_at DESC
LIMIT 200;
