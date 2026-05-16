SELECT github_id, number, title, body, state, state_reason, url, github_created_at, github_updated_at
FROM items
WHERE github_id = $1;
