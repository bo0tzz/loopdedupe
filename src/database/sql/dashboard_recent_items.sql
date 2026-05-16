SELECT github_id,
       number,
       item_type,
       title,
       state,
       state_reason,
       url,
       github_created_at
FROM items
ORDER BY github_created_at DESC
LIMIT $1;
