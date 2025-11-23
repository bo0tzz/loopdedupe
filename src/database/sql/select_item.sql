SELECT github_id, number, title, body, state, state_reason, url
FROM items
WHERE github_id = $1;