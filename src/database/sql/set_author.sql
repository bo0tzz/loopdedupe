UPDATE items
SET author_login = $2
WHERE github_id = $1;
